package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"time"
)

// 导入清单:往 prefetchImportQueuePath 写一批歌(每行一个 JSON:{"artist","title","album","duration"}),引擎在后台照同专辑预取
// 的做法一首首解析歌词、写进缓存,不用真的播放。给批量扩充存量(各国榜单、歌单)用,没有界面入口。
//   - 一次只跑一首,走后台优先级;缓存里已有(含宽松等价的写法)、正在解析的跳过(prefetchKeyFree)。
//   - 起了解析的两首之间隔 prefetchImportGap;有源因为被限流(429)在冷却时,等它冷却完再起下一首:冷却期间正在播的
//     那首也问不了这个源。有小时额度的源(sourcebudget.go)余量不够一首用时,等窗口里腾出余量再起,不让这一首漏问它。
//     一个歌词源都没连上的那首不算数,隔 prefetchImportOfflineWait 再从它接着搜。
//   - 补空扫描 / 全量扫库在跑时让开,等下一次检查。
//   - 进度记在 prefetchImportStatePath(清单内容的指纹 + 跑到第几行):引擎重启后接着跑,清单内容变了从头跑。
//
// 见 09 章决策 326。

var (
	prefetchImportQueuePath string
	prefetchImportStatePath string
)

const (
	// prefetchImportStartDelay:启动后等这么久才开始,不跟启动时的迁移、补核、正在播那首的首轮解析抢。
	prefetchImportStartDelay = 2 * time.Minute
	// prefetchImportCheckInterval:多久看一次清单(没有清单、跑完了、让开了的都在下一次再看)。
	prefetchImportCheckInterval = time.Minute
	prefetchImportGap           = 8 * time.Second
	prefetchImportOfflineWait   = 5 * time.Minute
	// prefetchImportBudgetNeed:起一首之前,有小时额度的源至少要剩这么多个请求。一首平均问 Musixmatch 四次左右,
	// 别名轮、标题反查轮多的到八九次。
	prefetchImportBudgetNeed = 10
)

var (
	// prefetchImportWait 在两首之间 / 断网重试前等待,ctx 取消时立刻返回。单测换成不等。
	prefetchImportWait = func(ctx context.Context, d time.Duration) {
		select {
		case <-ctx.Done():
		case <-time.After(d):
		}
	}
	// prefetchImportRunOne 跑一首。单测换成假的。
	prefetchImportRunOne = prefetchImportOne
	// prefetchImportRateLimited / prefetchImportBudget:起下一首之前要等多久(prefetchImportRateLimitWait /
	// prefetchImportBudgetWait)。单测换成假的。
	prefetchImportRateLimited = prefetchImportRateLimitWait
	prefetchImportBudget      = prefetchImportBudgetWait
)

type prefetchImportItem struct {
	Artist   string  `json:"artist"`
	Title    string  `json:"title"`
	Album    string  `json:"album"`
	Duration float64 `json:"duration"`
}

// prefetchImportState:一份清单的进度。Queued = 起了解析的,Filled = 其中解析完有词的,Skipped = 已有、在途、行写坏了的。
type prefetchImportState struct {
	Fingerprint string `json:"fingerprint"`
	Total       int    `json:"total"`
	Cursor      int    `json:"cursor"`
	Queued      int    `json:"queued"`
	Filled      int    `json:"filled"`
	Skipped     int    `json:"skipped"`
	Finished    bool   `json:"finished,omitempty"`
	UpdatedAt   int64  `json:"updatedAt"`
}

// prefetchImportOutcome:一首跑完的结果。started = 真的起了解析;offline = 起了,但一个歌词源都没连上、也没拿到词。
type prefetchImportOutcome struct {
	started, filled, offline bool
}

func setPrefetchImportPaths() {
	prefetchImportQueuePath = configFilePath(clientName + "-prefetch-import.jsonl")
	prefetchImportStatePath = configFilePath(clientName + "-prefetch-import-state.json")
}

// startPrefetchImporter 由 run() 单开一个 goroutine,ctx 取消时退出。
func startPrefetchImporter(ctx context.Context) {
	if prefetchImportQueuePath == "" {
		return
	}
	prefetchImportWait(ctx, prefetchImportStartDelay)
	ticker := time.NewTicker(prefetchImportCheckInterval)
	defer ticker.Stop()
	for ctx.Err() == nil {
		runPrefetchImport(ctx)
		select {
		case <-ctx.Done():
		case <-ticker.C:
		}
	}
}

// runPrefetchImport 从记下的位置接着跑清单,跑完、让开、断网或 ctx 取消时返回。
func runPrefetchImport(ctx context.Context) {
	data, err := os.ReadFile(prefetchImportQueuePath)
	if err != nil {
		noteFileErr("read", prefetchImportQueuePath, err)
		return
	}
	sum := sha256.Sum256(data)
	fingerprint := hex.EncodeToString(sum[:8])
	items := parsePrefetchImportItems(data)
	st := loadPrefetchImportState()
	if st.Fingerprint != fingerprint {
		st = prefetchImportState{Fingerprint: fingerprint, Total: len(items)}
	}
	if st.Finished {
		return
	}
	for st.Cursor < len(items) {
		if ctx.Err() != nil || prefetchImportShouldYield() {
			savePrefetchImportState(st)
			return
		}
		it := items[st.Cursor]
		if it == nil {
			st.Skipped++
			st.Cursor++
			continue
		}
		if d := max(prefetchImportRateLimited(), prefetchImportBudget()); d > 0 {
			prefetchImportWait(ctx, d)
			continue
		}
		out := prefetchImportRunOne(ctx, *it)
		if ctx.Err() != nil {
			savePrefetchImportState(st)
			return
		}
		if out.offline {
			slog.Info("prefetch import: no lyric source reachable, retrying later", "at", st.Cursor, "of", len(items))
			savePrefetchImportState(st)
			prefetchImportWait(ctx, prefetchImportOfflineWait)
			return
		}
		st.Cursor++
		switch {
		case !out.started:
			st.Skipped++
		case out.filled:
			st.Queued++
			st.Filled++
		default:
			st.Queued++
		}
		if st.Cursor%25 == 0 || st.Cursor == len(items) {
			slog.Info("prefetch import: progress", "done", st.Cursor, "of", len(items), "queued", st.Queued, "filled", st.Filled, "skipped", st.Skipped)
		}
		savePrefetchImportState(st)
		if out.started {
			prefetchImportWait(ctx, prefetchImportGap)
		}
	}
	st.Finished = true
	savePrefetchImportState(st)
}

// prefetchImportShouldYield:补空扫描 / 全量扫库在跑,这一轮让开。
func prefetchImportShouldYield() bool {
	lyricsFillSweepMu.Lock()
	defer lyricsFillSweepMu.Unlock()
	return lyricsFillSweepRunning
}

// prefetchImportRateLimitWait:开着的联网歌词源里因为被限流(429)在冷却的,还要冷却多久(取最长的,熔断器封顶
// lyricSourceBreakerRetryAfterMax);没有返回 0。别的原因(5xx、断网、反爬暂停)不等:那些跟导入的请求量无关,或者一停就是几小时。
func prefetchImportRateLimitWait() time.Duration {
	b := sharedLyricSourceBreaker()
	var wait time.Duration
	for _, src := range enabledNetworkLyricSources() {
		if b.cooldownReason(src) != lyricSourceCooldownReasonRateLimited {
			continue
		}
		if d, ok := b.coolingDown(src); ok && d > wait {
			wait = d
		}
	}
	return wait
}

// prefetchImportBudgetWait:开着的联网歌词源里有小时额度的,要等多久才剩得下 prefetchImportBudgetNeed 个请求(取最长的);
// 都够返回 0。
func prefetchImportBudgetWait() time.Duration {
	g := sharedHostGuard()
	var wait time.Duration
	for _, src := range enabledNetworkLyricSources() {
		if _, d, limited := g.sourceBudgetLeft(src, prefetchImportBudgetNeed); limited && d > wait {
			wait = d
		}
	}
	return wait
}

// parsePrefetchImportItems:每行一首;写坏的行、缺歌手或歌名的行留 nil 占位,行号跟进度对得上。
func parsePrefetchImportItems(data []byte) []*prefetchImportItem {
	var out []*prefetchImportItem
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var it prefetchImportItem
		if err := json.Unmarshal([]byte(line), &it); err != nil {
			out = append(out, nil)
			continue
		}
		it.Artist, it.Title, it.Album = cleanMediaTag(it.Artist), cleanMediaTag(it.Title), cleanMediaTag(it.Album)
		if it.Artist == "" || it.Title == "" {
			out = append(out, nil)
			continue
		}
		out = append(out, &it)
	}
	return out
}

// prefetchImportOne 解析一首,同 prefetchAlbumTracks 的单首:曲名先过 normEnrichTitle,不带播放器、不拿设备封面。
func prefetchImportOne(ctx context.Context, it prefetchImportItem) prefetchImportOutcome {
	key := enrichKey(it.Artist, it.Title, it.Album)
	if !prefetchKeyFree(key, true) {
		return prefetchImportOutcome{}
	}
	roundCtx, round := withLyricSourceRound(ctx)
	resolveEnrichAsync(withBackgroundOutbound(withLyricSearchTitle(roundCtx, lyricSearchTitle(it.Title))), key, it.Artist, normEnrichTitle(it.Title), it.Album, "", it.Duration, false)
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	filled := !e.Lyrics.IsZero()
	return prefetchImportOutcome{started: true, filled: filled, offline: !filled && !round.reachedAny()}
}

func loadPrefetchImportState() prefetchImportState {
	var st prefetchImportState
	data, err := os.ReadFile(prefetchImportStatePath)
	if err != nil {
		noteFileErr("read", prefetchImportStatePath, err)
		return st
	}
	if err := json.Unmarshal(data, &st); err != nil {
		noteFileErr("decode", prefetchImportStatePath, err)
	}
	return st
}

func savePrefetchImportState(st prefetchImportState) {
	st.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(st)
	if err != nil {
		return
	}
	if err := writeFileAtomic(prefetchImportStatePath, data); err != nil {
		slog.Warn("prefetch import: state write failed", "err", err)
	}
}
