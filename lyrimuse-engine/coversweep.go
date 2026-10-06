package main

import (
	"context"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 后台补封面:有词、没封面、外围字段一次都没补过的条目,不等它被播到,在后台各走一次外围补全
// (backfillPeripheralFields:条目有词时只单查网易云拿封面和链接,QQ / Apple 各查各的,不重搜歌词)。
// 从歌词文件夹导入时新建的条目(importLyricsFromOpts)只带歌词,是这里补的主要对象。见 09 章决策 195。
//
// 进程起来 coverSweepInitialDelay 后跑一遍,之后每 coverSweepInterval 一遍。一遍里逐条串行,两首之间隔
// coverSweepGap;轮到一条时有别的歌在解析(enrichInflight 非空)先等它,最多等 coverSweepYieldMax。
// 每条最多在这里补一次:补过一次 PeripheralRetryCount 就不是 0 了,之后照旧等播放时再试。
// 一条补完一个请求都没成功时不算补过(见 backfillPeripheralFields 记次数那一行),等 coverSweepOfflineWait
// 再补下一条;连续 coverSweepOfflineLimit 条都这样就停下这一遍,coverSweepOfflineRetry 后再来。

const (
	coverSweepInitialDelay = 10 * time.Minute
	coverSweepInterval     = 6 * time.Hour
	coverSweepOfflineRetry = 10 * time.Minute
	coverSweepOfflineLimit = 5
	coverSweepGap          = 30 * time.Second
	coverSweepOfflineWait  = 75 * time.Second
	coverSweepYieldPoll    = 2 * time.Second
	coverSweepYieldMax     = 5 * time.Minute
)

var (
	// coverSweepWait 等 d,ctx 取消时立刻返回。单测换成不等。
	coverSweepWait = func(ctx context.Context, d time.Duration) {
		select {
		case <-ctx.Done():
		case <-time.After(d):
		}
	}
	// coverSweepBackfill 补一条;coverSweepNetworkRound 观察这一条发出去的请求成没成。单测都换成假的。
	coverSweepBackfill     = backfillPeripheralFields
	coverSweepNetworkRound = beginNetworkRound
)

// startCoverSweeper 由 run() 单开一个 goroutine,ctx 取消时退出。
func startCoverSweeper(ctx context.Context) {
	delay := coverSweepInitialDelay
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay = coverSweepInterval
		if runCoverSweep(ctx).offline {
			delay = coverSweepOfflineRetry
		}
	}
}

// coverSweepPass 是一遍的结果。offline:连续 coverSweepOfflineLimit 条一个请求都没成功,这一遍提前停下了。
type coverSweepPass struct {
	candidates, filled, missed, skipped int
	offline                             bool
}

// runCoverSweep 跑一遍。
func runCoverSweep(ctx context.Context) coverSweepPass {
	enrichMu.Lock()
	keys := coverSweepCandidatesLocked()
	enrichMu.Unlock()
	pass := coverSweepPass{candidates: len(keys)}
	if len(keys) == 0 {
		return pass
	}
	slog.Info("cover sweep: start", "candidates", len(keys))
	offlineStreak := 0
	var wait time.Duration
	for _, key := range keys {
		if wait > 0 {
			coverSweepWait(ctx, wait)
		}
		coverSweepYield(ctx)
		if ctx.Err() != nil {
			break
		}
		wait = coverSweepGap
		switch coverSweepOne(ctx, key) {
		case coverSweepSkipped:
			pass.skipped++
			wait = 0
		case coverSweepFilled:
			pass.filled++
			offlineStreak = 0
		case coverSweepMissed:
			pass.missed++
			offlineStreak = 0
		case coverSweepOffline:
			offlineStreak++
			wait = coverSweepOfflineWait
		}
		if offlineStreak >= coverSweepOfflineLimit {
			pass.offline = true
			slog.Warn("cover sweep: no request got through, stopping this pass", "streak", offlineStreak, "key", key)
			break
		}
	}
	slog.Info("cover sweep: done", "candidates", pass.candidates, "filled", pass.filled, "missed", pass.missed,
		"skipped", pass.skipped, "offline", pass.offline)
	return pass
}

// coverSweepYield 等别的解析都跑完(enrichInflight 空了)再补下一条,最多等 coverSweepYieldMax。
func coverSweepYield(ctx context.Context) {
	for i := 0; i < int(coverSweepYieldMax/coverSweepYieldPoll) && ctx.Err() == nil; i++ {
		enrichMu.Lock()
		busy := len(enrichInflight) > 0
		enrichMu.Unlock()
		if !busy {
			return
		}
		coverSweepWait(ctx, coverSweepYieldPoll)
	}
}

// coverSweepEligibleLocked:这一条现在该不该在后台补一次封面。只挑补的时候不重搜歌词的(有词、手改过或标了纯音乐,
// 同 peripheralBackfillSkipsLyrics),没词的归补空扫描(lyricsfillsweep.go);key 里没有歌手的不补。调用方持有 enrichMu。
func coverSweepEligibleLocked(key string, e enrichEntry) bool {
	artist, title, _ := splitEnrichKey(key)
	return artist != "" && title != "" && e.CoverURL == "" && e.PeripheralRetryCount == 0 &&
		peripheralBackfillSkipsLyrics(e) && !enrichInflight[key] && peripheralBackfillWindowOpen(e)
}

// coverSweepCandidatesLocked 挑出这一遍要补的 key,按歌手、专辑、key 排(同一张专辑的挨着补)。调用方持有 enrichMu。
func coverSweepCandidatesLocked() []string {
	var keys []string
	for key, e := range enrichCache {
		if coverSweepEligibleLocked(key, e) {
			keys = append(keys, key)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		ai, _, bi := splitEnrichKey(keys[i])
		aj, _, bj := splitEnrichKey(keys[j])
		if ai != aj {
			return ai < aj
		}
		if bi != bj {
			return bi < bj
		}
		return keys[i] < keys[j]
	})
	return keys
}

// coverSweepTitle 去掉 key 标题段的时长消歧后缀(enrichKeyDurationVariant 加的 ~durN),拿曲名本身去查。
func coverSweepTitle(title string) string {
	i := strings.LastIndex(title, "~dur")
	if i <= 0 {
		return title
	}
	if n, err := strconv.Atoi(title[i+len("~dur"):]); err != nil || n < 2 {
		return title
	}
	return title[:i]
}

// coverSweepOutcome:一条补完的结果。
type coverSweepOutcome int

const (
	coverSweepSkipped coverSweepOutcome = iota // 轮到时已经不该补了(播放时补上了、被删了、正在别处解析),没发请求
	coverSweepFilled                           // 补上了封面
	coverSweepMissed                           // 请求有成功的,还是没有封面
	coverSweepOffline                          // 一个请求都没成功
)

// coverSweepOne 补一条。进门再核一遍资格:挑候选到轮到它可能隔了几个小时。
func coverSweepOne(ctx context.Context, key string) coverSweepOutcome {
	artist, title, album := splitEnrichKey(key)
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok || !coverSweepEligibleLocked(key, e) {
		enrichMu.Unlock()
		return coverSweepSkipped
	}
	dur := e.ResolvedDurationSecs
	if dur <= 0 {
		dur = e.DurationSecs
	}
	enrichInflight[key] = true
	enrichMu.Unlock()
	round := coverSweepNetworkRound()
	// 同步跑:backfillPeripheralFields 自己清 enrichInflight、落盘、通知重推。
	coverSweepBackfill(withBackgroundOutbound(ctx), key, artist, coverSweepTitle(title), album, dur)
	attempts, failures := round()
	enrichMu.Lock()
	filled := enrichCache[key].CoverURL != ""
	enrichMu.Unlock()
	switch {
	case filled:
		return coverSweepFilled
	case !lyricsRoundConfirmsNoResult(attempts, failures):
		return coverSweepOffline
	}
	return coverSweepMissed
}
