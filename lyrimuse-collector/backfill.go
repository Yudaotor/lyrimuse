package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Last.fm 历史回填 —— 把本地收听日志(listenlog.go)里还没提交过的收听补到 Last.fm。
//
// ## 这个功能能做到什么、做不到什么
//
// 做得到:用户先用了一阵 Lyrimuse、之后才连 Last.fm(或中途断开又重连)的那段空窗,
// 只要是**本地日志开始记录之后**的收听,都能补上。
//
// 做不到两件事,都必须如实告诉用户,不能含糊:
//
//  1. **本功能上线之前的收听补不回来** —— 那时候一次收听只流向 Last.fm / ListenBrainz /
//     网页中继三个都需要账号的地方,没连账号就等于没落盘。数据不存在,不是"存了没发"。
//  2. **Last.fm 只接受约两周内的时间戳**。更老的会被服务端 ignore(现有 lastfm.go 的
//     call() 里那条注释就写了 accepted=0 的成因之一是"时间戳超两周")。所以回填的有效
//     窗口是最近两周,不是"整份历史"。超窗的条目会被标记成 skippedTooOld,不会反复重试,
//     UI 上单独报数,不混进"已补"里假装成功。
//
// ## 为什么这里的每个决定都偏向"宁可少补一条"
//
// scrobble 一旦落进 Last.fm 就**基本删不掉**(只能在网页上一条一条手动删)。所以一次
// 重复提交等于永久污染用户的听歌历史。下面所有"失败怎么办"的选择一律取保守分支:
// 超时不重发、限流直接中止、未知的 ignore 码按未接受处理、拿不到回执的条目进隔离区。
const (
	// track.scrobble 官方上限:一次最多 50 条。
	backfillBatchSize = 50
	// 批间隔。官方 TOS 明确警告"持续每秒多次调用可能导致账号被停用",这里给足余量。
	backfillBatchPause = 2 * time.Second
	// Last.fm 接受的最大回溯时长。官方文档没给确切数字,社区与本仓库既有注释一致指向
	// 两周;取 13 天留一天余量,宁可少补也不要发出去被静默忽略、还占掉一次尝试。
	backfillMaxAge = 13 * 24 * time.Hour
	// 单批请求超时。超时**不重发**(见文件头),所以给得比常规调用宽松些。
	backfillRequestTimeout = 30 * time.Second
)

// backfillItem 是待补清单里的一条,给"未连接"那一栏按歌名列出来用。
//
// 只在 dry-run 时填充:真跑那次的返回值是给"已补 N 条"用的,没必要再把整份清单
// 序列化一遍。
type backfillItem struct {
	UTS    int64   `json:"uts"`
	Artist string  `json:"artist"`
	Title  string  `json:"title"`
	Album  string  `json:"album,omitempty"`
	Dur    float64 `json:"dur,omitempty"`
}

// backfillOutcome 是一次回填的结果,给 UI 用。
type backfillOutcome struct {
	// 待补清单(仅 dry-run 填)。按 uts **降序** —— 界面上最近听的排最前面才顺。
	Items []backfillItem `json:"items,omitempty"`
	// 日志里够格补的总条数(已排除已提交过的、超窗的)。
	Eligible int `json:"eligible"`
	// 服务端确认接受的条数。
	Accepted int `json:"accepted"`
	// 服务端明确忽略的条数(带 ignoredCode)。
	Ignored int `json:"ignored"`
	// 超过 Last.fm 回溯窗口、根本没发的条数。
	SkippedTooOld int `json:"skippedTooOld"`
	// 发出去了但拿不到回执的条数 —— **既不算成功也不算失败**,不会被自动重试。
	Quarantined int `json:"quarantined"`
	// 中止原因(限流/服务不可用/凭据失效)。空 = 跑完了。
	AbortedReason string `json:"abortedReason,omitempty"`
}

// pendingBackfillListens 折叠日志,返回"还没提交过、且在回溯窗口内"的收听,按 uts 升序。
//
// 折叠规则(读侧唯一权威):
//   - t=="l" 收 uts→收听行(同 uts 后来的覆盖先前的)
//   - t=="s" 记 uts 已提交过
//
// 官方指南:"Scrobbles should be sent in order, therefore cached scrobbles should be sent
// before new scrobbles." —— 所以按 uts 升序,不是随便什么顺序。
func pendingBackfillListens(now time.Time) (pending []listenLogLine, tooOld int) {
	lines := readListenLog()
	listens := make(map[int64]listenLogLine, len(lines))
	submitted := make(map[int64]bool, len(lines))
	for _, l := range lines {
		switch l.T {
		case "l":
			if l.UTS > 0 && l.TI != "" {
				listens[l.UTS] = l
				// 记录时就已经镜像给 Last.fm 的,等于已提交 —— 见 listenLogLine.M。
				if l.M == 1 {
					submitted[l.UTS] = true
				}
			}
		case "s":
			if l.UTS > 0 {
				submitted[l.UTS] = true
			}
		case "q":
			// 隔离:发出去了但没拿到回执。**跟已提交一样排除**,绝不自动重试 ——
			// 见 markQuarantined。
			if l.UTS > 0 {
				submitted[l.UTS] = true
			}
		}
	}
	cutoff := now.Add(-backfillMaxAge).Unix()
	for uts, l := range listens {
		if submitted[uts] {
			continue
		}
		// 本地复核一遍"算不算一次收听"—— 不信任日志一定干净(手工编辑过、旧版本写的)。
		if l.DUR > 0 && l.DUR < minTrackSecs {
			continue
		}
		if uts < cutoff {
			tooOld++
			continue
		}
		pending = append(pending, l)
	}
	sort.Slice(pending, func(i, j int) bool { return pending[i].UTS < pending[j].UTS })
	return pending, tooOld
}

// markBackfilled 追加一条回执行。**先写盘再算成功** —— 写不进去就当没提交过,
// 下次会重来(重复提交一条 vs 永久漏掉一条,前者更糟,所以这里必须先落盘)。
//
// ⚠️ 顺序上它必须在**收到服务端确认之后**调用:提前写等于把"发出去了"当成"接受了",
// 而超时那条路径恰恰是发出去了但不知道结果。
func markBackfilled(uts int64) {
	appendListenLogLine(listenLogLine{
		T: "s", V: listenLogSchemaVersion, UTS: uts, AT: time.Now().Unix(),
	})
}

// scrobbleBatchResult 是一批的服务端回执,按 timestamp 索引。
type scrobbleBatchResult struct {
	accepted map[int64]bool
	ignored  map[int64]string // uts -> ignoredMessage
}

// scrobbleBatch 批量提交一批收听。
//
// 回执解析是这里最容易出错的地方,三个坑:
//
//  1. **join key 只能用回执里回显的 timestamp**。artist/track 可能被 Last.fm "corrected"
//     改写(回执里就带 corrected 标记),拿它们比对会漏判;而官方从未承诺 <scrobble> 的
//     顺序等于请求里的下标顺序,所以也不能按位置对应。推论:**同一批内绝不能放两条相同
//     的 timestamp**,否则回执无法区分 —— 上游 pendingBackfillListens 按 uts 去重保证了这点。
//  2. **单条时 scrobble 是对象、多条时是数组**。Last.fm 的 JSON 就是这么不一致,必须两种
//     都能解。
//  3. **未知的 ignoredCode 一律按"未接受"处理**。官方明写"We may add additional ignored
//     codes in the future" —— 把没见过的码当成功是自造漏洞。
func (s *lastfmScrobbler) scrobbleBatch(ctx context.Context, items []listenLogLine) (*scrobbleBatchResult, error) {
	if len(items) == 0 {
		return &scrobbleBatchResult{accepted: map[int64]bool{}, ignored: map[int64]string{}}, nil
	}
	if len(items) > backfillBatchSize {
		return nil, fmt.Errorf("scrobbleBatch: %d items exceeds the %d limit", len(items), backfillBatchSize)
	}

	p := map[string]string{}
	for i, it := range items {
		// 跟单条路径走同一次折叠判定,否则同一首歌两条路提交出去的艺人名会不一致
		// (合唱串折叠的理由见 lastfmcollapse.go)。resolve 内部有 30 天缓存。
		artist := s.collapse.resolve(ctx, it.AR, it.TI)
		idx := strconv.Itoa(i)
		p["artist["+idx+"]"] = artist
		p["track["+idx+"]"] = it.TI
		p["timestamp["+idx+"]"] = strconv.FormatInt(it.UTS, 10)
		if it.AL != "" {
			p["album["+idx+"]"] = it.AL
		}
		if it.DUR > 0 {
			p["duration["+idx+"]"] = strconv.FormatInt(int64(it.DUR), 10)
		}
	}
	// 签名不需要为批量做任何特殊处理:sign() 用 sort.Strings 按字节序排,而官方要求的
	// 正是 ASCII 字节序 —— "artist[0]" / "artist[10]" 这类名字排出来跟官方一致。
	return s.callBatch(ctx, "track.scrobble", p)
}

func (s *lastfmScrobbler) callBatch(ctx context.Context, method string, params map[string]string) (*scrobbleBatchResult, error) {
	p := make(map[string]string, len(params)+3)
	for k, v := range params {
		p[k] = v
	}
	p["method"] = method
	p["api_key"] = s.apiKey
	p["sk"] = s.sk
	form := neturl.Values{}
	for k, v := range p {
		form.Set(k, v)
	}
	form.Set("api_sig", s.sign(p))
	form.Set("format", "json")

	ctx, cancel := context.WithTimeout(ctx, backfillRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://ws.audioscrobbler.com/2.0/", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", clientName)
	resp, err := doHTTPTracked(s.hc, req)
	if err != nil {
		// 网络错误/超时:**发出去了但不知道结果**。绝不重发(重发是最大的自造重复源),
		// 交给调用方把整批标成隔离。
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	// 跟单条路径同样的道理:Last.fm 的应用层错误常以 HTTP 200 + {"error":N} 返回。
	var envelope struct {
		Error     int    `json:"error"`
		Message   string `json:"message"`
		Scrobbles *struct {
			Attr struct {
				Accepted json.Number `json:"accepted"`
				Ignored  json.Number `json:"ignored"`
			} `json:"@attr"`
			Scrobble json.RawMessage `json:"scrobble"`
		} `json:"scrobbles"`
	}
	_ = json.Unmarshal(body, &envelope)
	if envelope.Error != 0 {
		return nil, &lastfmAPIError{Code: envelope.Error, Message: envelope.Message, Method: method}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("lastfm %s: status %d", method, resp.StatusCode)
	}
	if envelope.Scrobbles == nil {
		return nil, fmt.Errorf("lastfm %s: response has no scrobbles element", method)
	}

	out := &scrobbleBatchResult{accepted: map[int64]bool{}, ignored: map[int64]string{}}
	for _, e := range parseScrobbleEntries(envelope.Scrobbles.Scrobble) {
		uts, err := strconv.ParseInt(strings.TrimSpace(e.Timestamp), 10, 64)
		if err != nil || uts <= 0 {
			continue // 回执里的 timestamp 认不出来 → 这条 join 不上,留给隔离逻辑
		}
		code := strings.TrimSpace(e.IgnoredMessage.Code)
		if code == "" || code == "0" {
			out.accepted[uts] = true
			continue
		}
		msg := strings.TrimSpace(e.IgnoredMessage.Text)
		if msg == "" {
			msg = "ignored code " + code
		}
		out.ignored[uts] = msg
	}
	return out, nil
}

// scrobbleEntry 是回执里单条 <scrobble> 的我们关心的部分。
type scrobbleEntry struct {
	Timestamp      string `json:"timestamp"`
	IgnoredMessage struct {
		Code string `json:"code"`
		Text string `json:"#text"`
	} `json:"ignoredMessage"`
}

// parseScrobbleEntries 吞下 Last.fm 那个"一条是对象、多条是数组"的不一致。
func parseScrobbleEntries(raw json.RawMessage) []scrobbleEntry {
	if len(raw) == 0 {
		return nil
	}
	var many []scrobbleEntry
	if err := json.Unmarshal(raw, &many); err == nil {
		return many
	}
	var one scrobbleEntry
	if err := json.Unmarshal(raw, &one); err == nil {
		return []scrobbleEntry{one}
	}
	log.Printf("backfill: could not parse scrobble entries: %s", truncateForLog(raw))
	return nil
}

func truncateForLog(b []byte) string {
	const max = 200
	if len(b) <= max {
		return string(b)
	}
	return string(b[:max]) + "…"
}

// markQuarantined 记一条"发出去了但不知道结果"。
//
// 为什么必须落盘、而且必须跟"已提交"一样被后续回填排除:
//
// 网络超时/连接中断意味着请求**可能已经到了 Last.fm 并落库**,只是回执丢在路上。这时候
// 有两种选择,而它们的代价完全不对称:
//
//   - 下次自动重试 → 如果上次其实成功了,就在用户的听歌历史里造出一条永久删不掉的重复
//   - 就此搁置     → 最多少补一条,用户的历史仍然是干净的
//
// 所以选后者。这些条目不会被自动重试;将来若要救回来,正路是拿 user.getRecentTracks
// 按时间区间对账(那个方法不需要认证),确认服务端确实没有再放行 —— 那部分单独实现。
func markQuarantined(uts int64) {
	appendListenLogLine(listenLogLine{
		T: "q", V: listenLogSchemaVersion, UTS: uts, AT: time.Now().Unix(),
	})
}

// runBackfill 跑一次回填。dryRun=true 时只统计、一个请求都不发。
//
// 中止策略一律"停下来,不退避重试":
//   - 凭据已死(4/9/10/26):重试永远失败
//   - 限流 29:官方 TOS 说持续高频调用可能停用账号,这时候最该做的是立刻停手
//   - 服务暂时不可用(11/16):Last.fm 可能已经落库而回执丢了,重发是最大的自造重复源
//   - 网络错误/超时:同上,整批进隔离
//
// 官方允许重试的错误码白名单只有 11/16(以及 9 在重新授权之后),但即便如此我们也不重试 ——
// 这个功能一次跑完不成功,用户手动再点一次就是了,不值得为它承担重复提交的风险。
func runBackfill(ctx context.Context, s *lastfmScrobbler, dryRun bool) backfillOutcome {
	now := time.Now()
	pending, tooOld := pendingBackfillListens(now)
	out := backfillOutcome{Eligible: len(pending), SkippedTooOld: tooOld}
	// ⚠️ dry-run 的判断必须排在 `s == nil` **之前**。空跑一个请求都不发,压根不需要
	// scrobbler —— 而"还没连账号"恰恰是这个功能最主要的场景:界面要在那个状态下把本地
	// 已记录的清单列出来。顺序反了的话未连接时永远拿不到清单,新功能在主场景下直接失效
	// (2026-08-13 被 TestDryRunReturnsListNewestFirst 抓到)。
	if dryRun {
		// 清单给界面用,最近的排前面(pending 本身是升序,那是提交顺序的要求)。
		out.Items = make([]backfillItem, 0, len(pending))
		for i := len(pending) - 1; i >= 0; i-- {
			l := pending[i]
			out.Items = append(out.Items, backfillItem{
				UTS: l.UTS, Artist: l.AR, Title: l.TI, Album: l.AL, Dur: l.DUR,
			})
		}
		return out
	}
	if s == nil {
		out.AbortedReason = "last.fm not configured"
		return out
	}
	if len(pending) == 0 {
		return out
	}

	log.Printf("backfill: %d listen(s) to submit (%d too old to accept)", len(pending), tooOld)
	for start := 0; start < len(pending); start += backfillBatchSize {
		end := min(start+backfillBatchSize, len(pending))
		batch := pending[start:end]

		res, err := s.scrobbleBatch(ctx, batch)
		if err != nil {
			// 整批状态未知 → 全部进隔离,然后停手。
			for _, it := range batch {
				markQuarantined(it.UTS)
				out.Quarantined++
			}
			out.AbortedReason = err.Error()
			log.Printf("backfill: aborted after quarantining %d listen(s): %v", len(batch), err)
			return out
		}

		for _, it := range batch {
			switch {
			case res.accepted[it.UTS]:
				markBackfilled(it.UTS)
				out.Accepted++
			case res.ignored[it.UTS] != "":
				// 服务端**明确**拒了这条(时间戳超窗、艺人被判无效等)。重试同样会被拒,
				// 所以照样记回执不再重来;但计入 ignored 单独报给用户,不冒充成功。
				markBackfilled(it.UTS)
				out.Ignored++
				log.Printf("backfill: ignored by server: %s - %s (%s)", it.AR, it.TI, res.ignored[it.UTS])
			default:
				// 请求成功了,但这条的回执没回来 —— join 不上就当状态未知。
				markQuarantined(it.UTS)
				out.Quarantined++
			}
		}

		if end < len(pending) {
			select {
			case <-time.After(backfillBatchPause):
			case <-ctx.Done():
				out.AbortedReason = "cancelled"
				return out
			}
		}
	}
	log.Printf("backfill: done — accepted=%d ignored=%d quarantined=%d tooOld=%d",
		out.Accepted, out.Ignored, out.Quarantined, out.SkippedTooOld)
	return out
}
