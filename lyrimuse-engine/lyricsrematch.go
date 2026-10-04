package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sync"
	"time"
)

// 「重新自动匹配」(歌词管理详情页那颗按钮):App 写一份请求,这里对那一首跑一次手动重评。跑的就是后台那两个函数 ——
// 有词走 rescoreLyricsWith,没词走 retryLyricsUpgradeWith(firstFill)—— 只带上 lyricsRescoreOpts 里那几处手动的放宽;
// 选冠军、换不换、写哪些字段、落盘导出通知全在那两个函数里,这里只管接请求、报进度、写结论。
//
// 通道,形制同补空扫描(lyricsfillsweep.go 头注):
//   - 请求 lyricsRematchRequestPath:App 写一份 JSON,{"id","key"} 开一轮,{"id","cancel":true} 停掉那一轮。
//     这里每 lyricsRematchRequestCheckInterval 看一次,读到就消费掉。
//   - 状态 lyricsRematchStatusPath:带着请求的 id。跑着时报几个歌词源回了话,跑完写结论(lyricsRematchResult)。
//
// 一次只跑一首。补空扫描 / 全量扫库在跑时不接(两边会抢同一批源的限流额度),这首正在别处搜索时也不接,结论都是 busy;
// App 在补搜跑着时把按钮置灰,busy 只在两边恰好撞上时出现。

const lyricsRematchRequestCheckInterval = 500 * time.Millisecond

// 结论码,App 侧 LyricsRematch.Outcome 逐一对应。
const (
	lyricsRematchChanged        = "changed"          // 正文、逐字或来源换了
	lyricsRematchUnchanged      = "unchanged"        // 算下来还是现在这一份
	lyricsRematchNotDecidable   = "not_decidable"    // 当前歌词的来源这一轮没应答,没动(见 rescoreDecidable)
	lyricsRematchKeptWordTiming = "kept_word_timing" // 冠军没有逐字、现在这份有,没换(见 rescoreWouldLoseWordTiming)
	lyricsRematchInstrumental   = "instrumental"     // 没有可用候选,有源说这首是纯音乐,标上了
	lyricsRematchPlainText      = "plain_text"       // 没有带时间轴的候选,收下了一份纯文本兜底
	lyricsRematchNoCandidate    = "no_candidate"     // 连上了歌词源,没有一个能用的候选
	lyricsRematchOffline        = "offline"          // 一个歌词源都没连上
	lyricsRematchBusy           = "busy"             // 补空扫描 / 全量扫库在跑,或这首正在别处搜索
	lyricsRematchMissing        = "missing"          // 缓存里没有这一首
	lyricsRematchEdited         = "edited"           // 搜的这段时间里这一首被改过,这一轮的结果没用
	lyricsRematchCancelled      = "cancelled"        // App 停掉了,或进程在退出
)

// lyricsRematchResult 是一轮手动重评的结论。
type lyricsRematchResult struct {
	Outcome string `json:"outcome"`
	// Winner / WinnerScore:changed / unchanged 时是此刻的歌词源和分数;kept_word_timing 时是没采用的那个冠军。
	Winner      string `json:"winner,omitempty"`
	WinnerScore int    `json:"winnerScore,omitempty"`
	// Previous / HadLyrics:跑之前的歌词源、有没有词。
	Previous  string `json:"previous,omitempty"`
	HadLyrics bool   `json:"hadLyrics,omitempty"`
	// changed 时正文、逐字各自换没换;两个都没换就是只换了来源。
	TextChanged   bool `json:"textChanged,omitempty"`
	TimingChanged bool `json:"timingChanged,omitempty"`
}

// lyricsRematchStatus 是写给 App 看的状态。Done / Total:几个歌词源回了话 / 一共几个,追加轮(别名轮等)从 0 重数。
type lyricsRematchStatus struct {
	ID         string               `json:"id"`
	Key        string               `json:"key"`
	Running    bool                 `json:"running"`
	Done       int                  `json:"done,omitempty"`
	Total      int                  `json:"total,omitempty"`
	StartedAt  int64                `json:"startedAt"`
	UpdatedAt  int64                `json:"updatedAt"`
	FinishedAt int64                `json:"finishedAt,omitempty"`
	Result     *lyricsRematchResult `json:"result,omitempty"`
}

type lyricsRematchRequest struct {
	ID     string `json:"id"`
	Key    string `json:"key"`
	Cancel bool   `json:"cancel"`
}

// lyricsRescoreOpts 是手动重评跟后台两条路径(rescoreLyrics / retryLyricsUpgrade)的差别,零值就是后台那一套。
//   - manual:人工修正过的条目照跑;用户选定的源不管,全源重选;这一轮之后当前这份就是算法选的(换上了冠军,或冠军
//     就是当前这份)时,人工修正与选定源两个标记一起清掉。决策记录标成 manual-rematch。
//   - progress:每个歌词源回话时报一次进度。
//   - result:非 nil 时写回这一轮的结论。
type lyricsRescoreOpts struct {
	manual   bool
	progress func(done, total int)
	result   *lyricsRematchResult
}

// sourceChoice:这一轮只在哪个源里挑冠军,空串 = 全源。
func (o lyricsRescoreOpts) sourceChoice(choice string) string {
	if o.manual {
		return ""
	}
	return choice
}

func (o lyricsRescoreOpts) decisionPath(background string) string {
	if o.manual {
		return lyricsDecisionPathManualRematch
	}
	return background
}

func (o lyricsRescoreOpts) onUpdate() lyricSearchUpdateFunc {
	if o.progress == nil {
		return nil
	}
	return func(_ neteaseInfo, _ []scoredLyricCandidateResult, done, total int) { o.progress(done, total) }
}

// report 写一个不必看动手前后的结论(条目没了、期间被改过)。
func (o lyricsRescoreOpts) report(outcome string) {
	if o.result != nil {
		*o.result = lyricsRematchResult{Outcome: outcome}
	}
}

func (o lyricsRescoreOpts) finish(f lyricsRematchFacts) {
	if o.result != nil {
		*o.result = lyricsRematchOutcome(f)
	}
}

// lyricsRematchFacts:一轮跑完、写回缓存那一刻的事实。before / after 是这一轮动手前后的条目。
type lyricsRematchFacts struct {
	before, after  enrichEntry
	picked         *scoredLyricCandidateResult
	reached        bool // 连上过至少一个联网的歌词源;只用来说清楚没有结论是不是因为断网
	decidable      bool // 见 rescoreDecidable;补空那条路没有这道闸,恒为 true
	keptWordTiming bool // 有冠军,但换过去会丢掉逐字,留着当前这份
}

// lyricsRematchOutcome 按动手前后的条目定结论:真换了就是 changed,不管是哪一步换的(跨专辑对齐也算)。
func lyricsRematchOutcome(f lyricsRematchFacts) lyricsRematchResult {
	b, a := f.before, f.after
	r := lyricsRematchResult{Previous: b.LyricsSource, HadLyrics: b.Lyrics != ""}
	switch {
	case a.Lyrics != b.Lyrics || a.LyricsYRC != b.LyricsYRC || a.LyricsSource != b.LyricsSource:
		r.Outcome = lyricsRematchChanged
		r.Winner, r.WinnerScore = a.LyricsSource, a.LyricsScore
		r.TextChanged, r.TimingChanged = a.Lyrics != b.Lyrics, a.LyricsYRC != b.LyricsYRC
	case !f.decidable && !f.reached:
		r.Outcome = lyricsRematchOffline
	case !f.decidable:
		r.Outcome = lyricsRematchNotDecidable
	case f.picked == nil || a.Lyrics == "":
		// 没有冠军,或没词的条目冠军够不上(分数不高于 0,见 lyricsUpgradeBaseline)。
		switch {
		case a.Instrumental && !b.Instrumental:
			r.Outcome = lyricsRematchInstrumental
		case a.PlainLyrics != b.PlainLyrics:
			r.Outcome = lyricsRematchPlainText
		case !f.reached:
			r.Outcome = lyricsRematchOffline
		default:
			r.Outcome = lyricsRematchNoCandidate
		}
	case f.keptWordTiming:
		r.Outcome = lyricsRematchKeptWordTiming
		r.Winner, r.WinnerScore = f.picked.Source, f.picked.Score
	default:
		r.Outcome = lyricsRematchUnchanged
		r.Winner, r.WinnerScore = a.LyricsSource, a.LyricsScore
	}
	return r
}

var (
	lyricsRematchRequestPath string
	lyricsRematchStatusPath  string

	lyricsRematchMu sync.Mutex
	// 正在跑的那一轮:请求 id(空 = 没有在跑的)、停掉它的函数、它收尾时关掉的 channel。
	lyricsRematchID     string
	lyricsRematchCancel context.CancelFunc
	lyricsRematchDone   chan struct{}

	// lyricsRematchRun 对一首跑一次手动重评。单测换成假的。
	lyricsRematchRun = runLyricsRematchOne
)

// setLyricsRematchPaths 在 main() 启动时调一次,顺带清掉上一个进程留下的请求和状态(理由同 setLyricsFillPaths)。
func setLyricsRematchPaths() {
	lyricsRematchRequestPath = configFilePath(clientName + "-lyrics-rematch-request.json")
	lyricsRematchStatusPath = configFilePath(clientName + "-lyrics-rematch-status.json")
	_ = os.Remove(lyricsRematchRequestPath)
	_ = os.Remove(lyricsRematchStatusPath)
}

// startLyricsRematchWatcher 由 run() 单开一个 goroutine,ctx 取消时退出。每一轮另起 goroutine 跑,这个循环一直转着读请求,
// 跑到一半的「停止」才看得到。
func startLyricsRematchWatcher(ctx context.Context) {
	if lyricsRematchRequestPath == "" {
		return
	}
	poll := time.NewTicker(lyricsRematchRequestCheckInterval)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-poll.C:
			req, ok := readLyricsRematchRequest()
			switch {
			case !ok:
			case req.Cancel:
				cancelLyricsRematch(req.ID)
			default:
				go runLyricsRematch(ctx, req)
			}
		}
	}
}

// readLyricsRematchRequest 读一次请求文件并无条件消费掉(一次性信号,同 readLyricsFillRequest)。
func readLyricsRematchRequest() (lyricsRematchRequest, bool) {
	data, err := claimRequestFile(lyricsRematchRequestPath)
	if err != nil {
		return lyricsRematchRequest{}, false
	}
	return parseLyricsRematchRequest(data)
}

func parseLyricsRematchRequest(data []byte) (lyricsRematchRequest, bool) {
	var req lyricsRematchRequest
	if err := json.Unmarshal(data, &req); err != nil || req.ID == "" || (!req.Cancel && req.Key == "") {
		slog.Warn("lyrics rematch: ignoring malformed request", "err", err)
		return lyricsRematchRequest{}, false
	}
	return req, true
}

// cancelLyricsRematch 停掉 id 那一轮;那一轮已经跑完、或在跑的是别的一轮,什么都不做。
func cancelLyricsRematch(id string) {
	lyricsRematchMu.Lock()
	defer lyricsRematchMu.Unlock()
	if lyricsRematchID == id && lyricsRematchCancel != nil {
		lyricsRematchCancel()
	}
}

// lyricsFillSweepBusy:补空扫描 / 全量扫库此刻有一轮在跑。
func lyricsFillSweepBusy() bool {
	lyricsFillSweepMu.Lock()
	defer lyricsFillSweepMu.Unlock()
	return lyricsFillSweepRunning
}

// runLyricsRematch 跑一轮并把结论写进状态文件。
//
// 来的时候还有一轮在跑:App 一次只等一轮,换了一首就不要那一轮了(它的「停止」还可能被这份新请求盖掉、根本没送到),
// 所以先停掉那一轮、等它收尾再开这一轮。
func runLyricsRematch(parent context.Context, req lyricsRematchRequest) {
	var mu sync.Mutex
	status := lyricsRematchStatus{ID: req.ID, Key: req.Key, StartedAt: time.Now().Unix()}
	finish := func(r lyricsRematchResult) {
		mu.Lock()
		defer mu.Unlock()
		status.Running = false
		status.FinishedAt = time.Now().Unix()
		status.Result = &r
		writeLyricsRematchStatus(status)
		slog.Info("lyrics rematch: done", "key", req.Key, "outcome", r.Outcome)
	}
	lyricsRematchMu.Lock()
	for lyricsRematchID != "" {
		slog.Info("lyrics rematch: superseding the running round", "key", req.Key)
		lyricsRematchCancel()
		prev := lyricsRematchDone
		lyricsRematchMu.Unlock()
		<-prev
		lyricsRematchMu.Lock()
	}
	if lyricsFillSweepBusy() {
		lyricsRematchMu.Unlock()
		finish(lyricsRematchResult{Outcome: lyricsRematchBusy})
		return
	}
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})
	lyricsRematchID, lyricsRematchCancel, lyricsRematchDone = req.ID, cancel, done
	lyricsRematchMu.Unlock()

	mu.Lock()
	status.Running = true
	writeLyricsRematchStatus(status)
	mu.Unlock()
	slog.Info("lyrics rematch: start", "key", req.Key)
	result := lyricsRematchRun(ctx, req.Key, func(done, total int) {
		mu.Lock()
		defer mu.Unlock()
		if !status.Running {
			return
		}
		status.Done, status.Total = done, total
		writeLyricsRematchStatus(status)
	})

	cancel()
	finish(result)
	lyricsRematchMu.Lock()
	lyricsRematchID, lyricsRematchCancel, lyricsRematchDone = "", nil, nil
	lyricsRematchMu.Unlock()
	close(done)
}

// runLyricsRematchOne 对 key 跑一次手动重评。时长取法同全量扫库(lyricsFullScanOne)。搜索带 withManualLyricSearch
// (有人在等,别名补查几轮并发),不降成后台优先级。
func runLyricsRematchOne(ctx context.Context, key string, progress func(done, total int)) lyricsRematchResult {
	artist, title, album := splitEnrichKey(key)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	busy := enrichInflight[key]
	if ok && !busy {
		enrichInflight[key] = true
	}
	enrichMu.Unlock()
	switch {
	case !ok:
		return lyricsRematchResult{Outcome: lyricsRematchMissing}
	case busy:
		return lyricsRematchResult{Outcome: lyricsRematchBusy}
	}
	duration := e.ResolvedDurationSecs
	if duration <= 0 {
		duration = e.DurationSecs
	}
	var result lyricsRematchResult
	opts := lyricsRescoreOpts{manual: true, progress: progress, result: &result}
	// 两个函数自己负责清 enrichInflight、落盘、导出、通知重推。
	if e.Lyrics == "" {
		retryLyricsUpgradeWith(withManualLyricSearch(ctx), key, artist, title, album, duration, true, opts)
	} else {
		rescoreLyricsWith(withManualLyricSearch(ctx), key, artist, title, album, duration, opts)
	}
	// 当场落盘再报结论:没换词时那两个函数只排了一次记账补写(常驻进程里最多晚一分钟),App 拿到结论就重读。
	flushEnrichSave()
	// 只有搜到一半被停时两个函数不写结论。
	if result.Outcome == "" {
		result.Outcome = lyricsRematchCancelled
	}
	return result
}

func writeLyricsRematchStatus(s lyricsRematchStatus) {
	if lyricsRematchStatusPath == "" {
		return
	}
	s.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	if err := writeFileAtomic(lyricsRematchStatusPath, data); err != nil {
		slog.Warn("lyrics rematch: status write failed", "err", err)
	}
}
