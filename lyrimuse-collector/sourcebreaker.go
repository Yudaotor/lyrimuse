package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- 歌词源级熔断 / 退避 ----
//
// 2026-09-02 加。八个歌词源并发、20 秒总截止(lyricSearchDeadline),
// 某个源整个哑掉(DNS 污染、TLS 挂死、5xx)时,之前每首歌都要把它等到自己的超时——AGENTS.md
// 里 2026-08-15 Musixmatch DNS 事故的原话就是「每首歌都要把 DNS/TLS 超时白等一遍」。已有的
// 退避都是点状的(网易云端点桶 30s 拒绝冷却、lb.go 的 429 阶梯、Musixmatch 自己换 token),
// 没有「某个源连续失败就在接下来一段时间跳过它」的通用层。
//
// 挂在哪:各源函数把所有错误都吞成空结果、不区分"没查到"和"没查成",唯一集中的地方是
// doHTTPTracked(整个采集器所有对外请求的统一出口),能拿到网络层错误与状态码——所以失败
// 观察挂在那里,按请求主机归到源(lyricSourceForHost);跳过决策挂在
// fetchScoredLyricCandidatesStreaming 每个源 goroutine 的开头(planRound)。
//
// 只统计两类失败:http.Client.Do 本身返回错误(DNS/连接/TLS/超时——请求根本没发出去或
// 没拿到响应)和 5xx;429 单独按 Retry-After 处理。任何拿到响应且状态码 < 500 的请求都算
// 一次成功、立即清零——4xx 一律不算:那是各源自己的业务判定(网易云 body 里的 405、
// Musixmatch 的 401 hint=captcha 都已各自处理),也刻意**不**把
// 401/402/403 当成长期粘性冷却的理由——对没有凭据的源来说,反爬 403 那样处理会让该源永久缺席、界面还不提示。
//
// 三条护栏(理由见 09 章第 41 条):
//   - 连续 2 次失败才开(lyricSourceBreakerTripAfter),不是 1 次:一次网络抖动不该让下一首歌
//     少一个源。网易云一轮最多发 4 个变体,一首歌就够触发;lrclib 单请求要两首歌。
//   - 启用的源**全部**在冷却中时谁也不跳过,照常跑一轮——让 roundLooksNetworkDown 那套
//     "至少 3 次请求全失败 = 断网"的判定接手,别让熔断把断网状态伪装成"这首歌没歌词"。
//   - 被跳过的源记进 lyricSourceRound(经 ctx 传给 enrich.go),落到 lyrics_sources_skipped /
//     决策留痕的 sources_skipped;歌词为空且这一轮有源被跳过时,needsLyricsFirstFill 的补空
//     间隔从 24 小时改成 10 分钟(只对第一次生效)。
//
// 被跳过的源在"哪些源应答了"的口径里就是没应答——这正好接上既有的两条机制:
// needsLyricsRetry 会在 6 小时后重搜(最多 3 次),rescoreDecidable 拒绝在当前源缺席时降级。
// 全部状态在进程内存里,collector 重启归零;search-lyrics 这类一次性 CLI 进程永远不会有
// 冷却态,所以不需要给 Swift 侧加新的失败原因代码。

// lyricSourceBreakerSchedule:第 N 次达到触发阈值之后的冷却时长(N 从 0 起),超出表长封顶
// 在最后一档——上限 5 分钟,成功即清,误熔断的代价有界。
var lyricSourceBreakerSchedule = []time.Duration{
	15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute,
}

const (
	// lyricSourceBreakerTripAfter:连续多少次失败才进入冷却。
	lyricSourceBreakerTripAfter = 2
	// 429 的 Retry-After:没给或解析不出用默认值,给了也封顶,别被一个离谱的头把源关掉一天。
	lyricSourceBreakerRetryAfterDefault = time.Minute
	lyricSourceBreakerRetryAfterMax     = 5 * time.Minute
)

const (
	lyricSourceCooldownReasonNetwork     = "network"
	lyricSourceCooldownReasonServerError = "http_5xx"
	lyricSourceCooldownReasonRateLimited = "http_429"
)

type lyricSourceBreakerState struct {
	until       time.Time
	consecutive int
	reason      string
}

type lyricSourceBreaker struct {
	mu    sync.Mutex
	now   func() time.Time
	state map[string]*lyricSourceBreakerState
}

func newLyricSourceBreaker(now func() time.Time) *lyricSourceBreaker {
	return &lyricSourceBreaker{now: now, state: map[string]*lyricSourceBreakerState{}}
}

// lyricSourceBreakerShared 是常驻采集器用的那一份(进程级)。
var lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)

// lyricSourceForHost 把请求主机归到歌词源名(lyricSourceNames 里的写法);不是歌词源的主机
// (Last.fm / ListenBrainz / MusicBrainz / iTunes / DoH …)返回空串。主机名单来自各源文件里
// 实际请求的域名(2026-09-02 grep 核对);raw.githubusercontent.com 全仓只有 amll 在用。
func lyricSourceForHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.Contains(h, ":") {
		if hostOnly, _, err := net.SplitHostPort(h); err == nil {
			h = hostOnly
		}
	}
	switch {
	case h == "music.163.com" || strings.HasSuffix(h, ".163.com"):
		return "netease"
	case h == "qq.com" || strings.HasSuffix(h, ".qq.com"):
		return "qq"
	case h == "kugou.com" || strings.HasSuffix(h, ".kugou.com"):
		return "kugou"
	case h == "lrclib.net" || strings.HasSuffix(h, ".lrclib.net"):
		return "lrclib"
	case h == "musixmatch.com" || strings.HasSuffix(h, ".musixmatch.com"):
		return "musixmatch"
	case h == "raw.githubusercontent.com":
		return "amll"
	case h == "music.youtube.com":
		return "lyricfind"
	case h == "kuwo.cn" || strings.HasSuffix(h, ".kuwo.cn"):
		return "kuwo"
	}
	return ""
}

// observe 记录一次对外请求的结果。err 是 http.Client.Do 的返回错误(nil = 拿到了响应),
// status 是响应状态码(err != nil 时忽略),retryAfter 是响应的 Retry-After 头原文(可空)。
func (b *lyricSourceBreaker) observe(host string, err error, status int, retryAfter string) {
	source := lyricSourceForHost(host)
	if source == "" {
		return
	}
	// 用户主动取消(enrichcancel.go)会让全部在飞的请求同时以 context.Canceled 失败——
	// 那是用户的动作,不是源的毛病,一次都不算。
	if err != nil && errors.Is(err, context.Canceled) {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	st := b.state[source]
	switch {
	case err != nil || status >= 500:
		reason := lyricSourceCooldownReasonNetwork
		if err == nil {
			reason = lyricSourceCooldownReasonServerError
		}
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		st.consecutive++
		if st.consecutive < lyricSourceBreakerTripAfter {
			return
		}
		idx := st.consecutive - lyricSourceBreakerTripAfter
		if idx >= len(lyricSourceBreakerSchedule) {
			idx = len(lyricSourceBreakerSchedule) - 1
		}
		st.until = now.Add(lyricSourceBreakerSchedule[idx])
		st.reason = reason
		log.Printf("lyrics: source %s cooling down %s (reason=%s consecutive=%d host=%s)",
			source, lyricSourceBreakerSchedule[idx], reason, st.consecutive, host)
	case status == http.StatusTooManyRequests:
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		d := parseLyricSourceRetryAfter(retryAfter)
		st.until = now.Add(d)
		st.reason = lyricSourceCooldownReasonRateLimited
		log.Printf("lyrics: source %s cooling down %s (reason=%s host=%s)", source, d, st.reason, host)
	default:
		if st == nil {
			return
		}
		if st.until.After(now) {
			log.Printf("lyrics: source %s recovered, cooldown cleared (reason=%s)", source, st.reason)
		}
		delete(b.state, source)
	}
}

// parseLyricSourceRetryAfter 只认「秒数」写法;HTTP-date 写法(RFC 7231 允许)用默认值——
// 八个源里没见过谁发日期形态的 Retry-After,不值得为它引入日期解析。
func parseLyricSourceRetryAfter(v string) time.Duration {
	secs, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || secs <= 0 {
		return lyricSourceBreakerRetryAfterDefault
	}
	d := time.Duration(secs) * time.Second
	if d > lyricSourceBreakerRetryAfterMax {
		d = lyricSourceBreakerRetryAfterMax
	}
	return d
}

// lyricSourceRoundPlan:这一轮该跳过的源 → 剩余冷却时长。
type lyricSourceRoundPlan map[string]time.Duration

// planRound 在一轮八源搜索起跑前算一次"谁在冷却中"。启用的源全部都在冷却时返回 nil
// (谁也不跳过,见文件头第二条护栏);未启用的源在不在名单里无所谓——它们的结果本来就会被
// filterEnabledLyricSources 过滤掉,跳过只是少发几个白费的请求。
func (b *lyricSourceBreaker) planRound(sources []string, enabled func(string) bool) lyricSourceRoundPlan {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	plan := lyricSourceRoundPlan{}
	enabledTotal, enabledCooling := 0, 0
	for _, s := range sources {
		isEnabled := enabled(s)
		if isEnabled {
			enabledTotal++
		}
		if st := b.state[s]; st != nil && st.until.After(now) {
			plan[s] = st.until.Sub(now)
			if isEnabled {
				enabledCooling++
			}
		}
	}
	if len(plan) == 0 {
		return nil
	}
	if enabledTotal > 0 && enabledCooling == enabledTotal {
		log.Printf("lyrics: all %d enabled sources are cooling down, running the round anyway", enabledTotal)
		return nil
	}
	return plan
}

// coolingDown 只读地回答某个源现在是不是在冷却中(给诊断/测试用)。
func (b *lyricSourceBreaker) coolingDown(source string) (time.Duration, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	st := b.state[source]
	if st == nil || !st.until.After(b.now()) {
		return 0, false
	}
	return st.until.Sub(b.now()), true
}

// ---- 把"这一轮跳过了谁"从 fetchScoredLyricCandidatesStreaming 传回给写缓存的那几层 ----
//
// 用 context 值而不是改返回值:fetchScoredLyricCandidatesStreaming 在 scoredLyricCandidatesStreaming
// 里为歌手别名 / 标题反查会被调最多 4 次,再往上还有三层调用链(retryLyricsUpgrade /
// rescoreLyrics / resolveTrackEnrichment),逐层加返回值要改六处签名却只为传一份名单;
// 挂在 ctx 上,只有真关心的三个写缓存点各拿一次。没挂(search-lyrics CLI)就什么都不记。

type lyricSourceRound struct {
	mu      sync.Mutex
	skipped map[string]bool
}

type lyricSourceRoundKey struct{}

func withLyricSourceRound(ctx context.Context) (context.Context, *lyricSourceRound) {
	r := &lyricSourceRound{skipped: map[string]bool{}}
	return context.WithValue(ctx, lyricSourceRoundKey{}, r), r
}

func lyricSourceRoundFrom(ctx context.Context) *lyricSourceRound {
	if ctx == nil {
		return nil
	}
	r, _ := ctx.Value(lyricSourceRoundKey{}).(*lyricSourceRound)
	return r
}

// markSkipped / skippedSources 对 nil 接收者都是安全的空操作(CLI 路径没有 round)。
func (r *lyricSourceRound) markSkipped(source string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.skipped[source] = true
	r.mu.Unlock()
}

func (r *lyricSourceRound) skippedSources() []string {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.skipped) == 0 {
		return nil
	}
	out := make([]string, 0, len(r.skipped))
	for s := range r.skipped {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
