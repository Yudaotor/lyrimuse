package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// 后台「补空扫描」:不等这首歌再被播到,主动给存量的空歌词条目再搜一轮。
//
// 为什么需要(2026-09-05):needsLyricsFirstFill 那条补空路径设计上**只在这首歌再次被播放时**
// 触发(enrich.go trackEnrichment 缓存命中后的分派链)。对"正在听的歌"这是对的——省网络、
// 只修用户真会看到的;但「歌词管理」把全库摊开给用户看,里面躺着的空条目用户不重播就永远
// 不会动。实测 82 条非纯音乐的空条目里,范逸臣《革命》《Dalala-Dila》8-31 首解析时一个源
// 都没应答(偶发网络),五天后手动重搜 QQ 1057 / 971 分——不是没词,是没人再去问过。
//
// 两条触发:
//   - 自动:进程起来 10 分钟后扫一次,之后每 24 小时一次。每轮只处理 needsLyricsFirstFill 为真
//     的(退避到期的)条目、上限 lyricsFillSweepDailyCap 条、两首之间隔 lyricsFillSweepGap ——
//     补空本身是"每条最多每天一次、指数退避"的节奏,这里只是把"要不要问"的时机从"被播到"
//     改成"到点了",不改每条的退避账。
//   - 手动:App 侧(「歌词管理」的「重试无歌词条目」按钮)往 lyricsFillRequestPath 写一个
//     请求文件(见 lyricsFillRequest),这里 2 秒内读到就开一轮,**忽略退避**(用户明确要求
//     现在就搜)、不设条数上限,但仍然只碰"没歌词、没人工修正、没确证纯音乐"的条目。
//     进度写到 lyricsFillStatusPath 给界面看(形制同 collectorstatus.go / lastfm 状态通道:
//     collector 落盘、Swift 按 mtime 读,写失败只记日志)。
//
// 逐条串行、中间留间隔,不并发:Musixmatch 匿名 token 对并发 token.get 会 captcha 限流
// (musixmatch.go 头注),一次性起 80 首等于自己把这个源打哑;而且这批歌用户此刻没在听,
// 没有任何理由跟正在播放的那首抢网络。每条都走现成的 retryLyricsUpgrade(firstFill=true)
// ——补空的写回规则(升级 / 纯音乐标记 / 纯文本兜底 / 决策存档 / 计数与退避)全在那里,
// 这个文件只负责"挑哪些、什么时候、报进度"。

const (
	lyricsFillSweepInitialDelay    = 10 * time.Minute
	lyricsFillSweepInterval        = 24 * time.Hour
	lyricsFillSweepGap             = 15 * time.Second
	lyricsFillSweepDailyCap        = 40
	lyricsFillRequestCheckInterval = 2 * time.Second
)

var (
	lyricsFillRequestPath string
	lyricsFillStatusPath  string

	lyricsFillSweepMu      sync.Mutex
	lyricsFillSweepRunning bool
	lyricsFillSweepCancel  context.CancelFunc
)

// lyricsFillStatus 是写给 App 看的进度。Total 是这一轮开工时挑出的条数;Done 含"跑到一半发现
// 已经不需要(被删/被手改/已有词)而跳过"的;Filled 是这一轮真的补出了结论(拿到歌词、或纯音乐
// 标记、或纯文本兜底)的条数。
type lyricsFillStatus struct {
	Running    bool   `json:"running"`
	Manual     bool   `json:"manual"`
	Total      int    `json:"total"`
	Done       int    `json:"done"`
	Filled     int    `json:"filled"`
	Current    string `json:"current,omitempty"`
	StartedAt  int64  `json:"startedAt"`
	UpdatedAt  int64  `json:"updatedAt"`
	FinishedAt int64  `json:"finishedAt,omitempty"`
	Cancelled  bool   `json:"cancelled,omitempty"`
}

// setLyricsFillPaths 在 main() 启动时调一次。顺带清掉上一次运行遗留的请求/状态文件:请求跟这次
// 进程无关(理由同 setEnrichCancelRequestPath),状态则是上一轮的陈旧进度。
func setLyricsFillPaths() {
	lyricsFillRequestPath = configFilePath(clientName + "-lyrics-fill-request.txt")
	lyricsFillStatusPath = configFilePath(clientName + "-lyrics-fill-status.json")
	_ = os.Remove(lyricsFillRequestPath)
	_ = os.Remove(lyricsFillStatusPath)
}

// startLyricsFillSweeper 由 run() 单开一个 goroutine(跟 startEnrichCancelWatcher 同款),
// ctx 取消时退出。两个节奏合在一个循环里:定时器管自动扫描,ticker 管请求文件。
// 每一轮扫描都另起 goroutine 跑——这个循环必须一直转着读请求文件,否则一轮几十分钟的
// 手动扫描期间用户写下的 "cancel" 要等扫完才被看到,等于没有取消。一次只允许一轮在跑,
// 期间再来的请求由 runLyricsFillSweep 开头那道闸拒掉(并记日志),不排队——用户点两下不该跑两遍。
func startLyricsFillSweeper(ctx context.Context) {
	if lyricsFillRequestPath == "" {
		return
	}
	next := time.NewTimer(lyricsFillSweepInitialDelay)
	defer next.Stop()
	poll := time.NewTicker(lyricsFillRequestCheckInterval)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-next.C:
			go runLyricsFillSweep(ctx, lyricsFillRequest{})
			next.Reset(lyricsFillSweepInterval)
		case <-poll.C:
			req, ok := readLyricsFillRequest()
			if !ok {
				continue
			}
			if req.cancel {
				cancelLyricsFillSweep()
				continue
			}
			go runLyricsFillSweep(ctx, req)
		}
	}
}

// lyricsFillRequest 是请求文件解出来的内容。文件格式(纯文本,App 侧 LyricsManagerView 写):
//   - 一行 "all":全部符合条件的空条目;
//   - 一行 "cancel":停掉正在跑的这一轮;
//   - 否则每行一个缓存 key("artist|title|album",跟 EnrichCacheKeys 同一个 key 空间)。
type lyricsFillRequest struct {
	manual bool
	cancel bool
	all    bool
	keys   map[string]bool
}

func parseLyricsFillRequest(text string) lyricsFillRequest {
	req := lyricsFillRequest{manual: true}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "":
		case line == "all":
			req.all = true
		case line == "cancel":
			req.cancel = true
		default:
			if req.keys == nil {
				req.keys = map[string]bool{}
			}
			req.keys[line] = true
		}
	}
	return req
}

// readLyricsFillRequest 读一次请求文件并无条件消费掉(一次性信号,同 checkEnrichCancelRequest)。
func readLyricsFillRequest() (lyricsFillRequest, bool) {
	data, err := os.ReadFile(lyricsFillRequestPath)
	if err != nil {
		return lyricsFillRequest{}, false
	}
	_ = os.Remove(lyricsFillRequestPath)
	req := parseLyricsFillRequest(string(data))
	if !req.all && !req.cancel && len(req.keys) == 0 {
		return lyricsFillRequest{}, false
	}
	return req, true
}

// lyricsFillSweepCandidates 在锁内挑出这一轮要处理的 key,按字典序排好(确定、可复现)。
// 三道硬闸对两种触发都生效:有歌词的、人工修正过的、确证纯音乐的一律不碰——这跟
// needsLyricsFirstFill 的前三行同一口径。退避只对自动扫描生效;手动请求是用户明确要现在搜。
// 正在飞的(enrichInflight)跳过:那条此刻已经有人在查。
func lyricsFillSweepCandidates(req lyricsFillRequest) []string {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	var keys []string
	for key, e := range enrichCache {
		if req.keys != nil && !req.keys[key] {
			continue
		}
		if e.Lyrics != "" || e.ManualLyrics || e.Instrumental || enrichInflight[key] {
			continue
		}
		if !req.manual && !needsLyricsFirstFill(e) {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if !req.manual && len(keys) > lyricsFillSweepDailyCap {
		keys = keys[:lyricsFillSweepDailyCap]
	}
	return keys
}

func cancelLyricsFillSweep() {
	lyricsFillSweepMu.Lock()
	defer lyricsFillSweepMu.Unlock()
	if lyricsFillSweepRunning && lyricsFillSweepCancel != nil {
		lyricsFillSweepCancel()
	}
}

// runLyricsFillSweep 跑一轮。同一时刻只允许一轮在跑。
func runLyricsFillSweep(parent context.Context, req lyricsFillRequest) {
	lyricsFillSweepMu.Lock()
	if lyricsFillSweepRunning {
		lyricsFillSweepMu.Unlock()
		slog.Info("lyrics fill sweep: already running, ignoring new request", "manual", req.manual)
		return
	}
	ctx, cancel := context.WithCancel(parent)
	lyricsFillSweepRunning = true
	lyricsFillSweepCancel = cancel
	lyricsFillSweepMu.Unlock()
	defer func() {
		cancel()
		lyricsFillSweepMu.Lock()
		lyricsFillSweepRunning = false
		lyricsFillSweepCancel = nil
		lyricsFillSweepMu.Unlock()
	}()

	keys := lyricsFillSweepCandidates(req)
	status := lyricsFillStatus{Running: true, Manual: req.manual, Total: len(keys), StartedAt: time.Now().Unix()}
	writeLyricsFillStatus(status)
	slog.Info("lyrics fill sweep: start", "manual", req.manual, "candidates", len(keys))
	if len(keys) == 0 {
		status.Running = false
		status.FinishedAt = time.Now().Unix()
		writeLyricsFillStatus(status)
		return
	}
	for i, key := range keys {
		if i > 0 {
			select {
			case <-ctx.Done():
			case <-time.After(lyricsFillSweepGap):
			}
		}
		if ctx.Err() != nil {
			status.Cancelled = true
			break
		}
		status.Current = key
		writeLyricsFillStatus(status)
		if lyricsFillSweepOne(key) {
			status.Filled++
		}
		status.Done++
		status.Current = ""
		writeLyricsFillStatus(status)
	}
	status.Running = false
	status.Current = ""
	status.FinishedAt = time.Now().Unix()
	writeLyricsFillStatus(status)
	slog.Info("lyrics fill sweep: done", "manual", req.manual, "total", status.Total, "done", status.Done, "filled", status.Filled, "cancelled", status.Cancelled)
}

// lyricsFillSweepOne 对一条走一次补空,返回这一轮有没有补出结论。进门再核一遍资格:挑候选到
// 轮到它可能隔了几十分钟,期间它可能被播到(自己补上了)、被用户手改/删除。
func lyricsFillSweepOne(key string) bool {
	artist, title, album := splitEnrichKey(key)
	enrichMu.Lock()
	before, ok := enrichCache[key]
	if !ok || before.Lyrics != "" || before.ManualLyrics || before.Instrumental || enrichInflight[key] {
		enrichMu.Unlock()
		return false
	}
	dur := before.ResolvedDurationSecs
	if dur <= 0 {
		dur = before.DurationSecs
	}
	enrichInflight[key] = true
	enrichMu.Unlock()
	// 同步跑:retryLyricsUpgrade 自己负责清 enrichInflight、落盘、导出、通知重推。
	retryLyricsUpgrade(key, artist, title, album, dur, true)
	enrichMu.Lock()
	after := enrichCache[key]
	enrichMu.Unlock()
	return after.Lyrics != "" || after.Instrumental || (after.PlainLyrics != "" && before.PlainLyrics == "")
}

func writeLyricsFillStatus(s lyricsFillStatus) {
	if lyricsFillStatusPath == "" {
		return
	}
	s.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	if err := os.WriteFile(lyricsFillStatusPath, data, 0o644); err != nil {
		slog.Warn("lyrics fill sweep: status write failed", "err", err)
	}
}
