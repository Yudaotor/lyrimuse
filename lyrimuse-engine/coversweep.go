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
// 补一条不当场存盘:每补完 coverSweepSaveEvery 条、以及一遍收尾时要一次存盘,这一次也跟别的歌的改动一样攒着、
// 最多 enrichBackgroundSaveDelay 写(App 每次存盘都要整份重读缓存,见 enrichsave.go);正在播的那首照常当场存。
//
// 一遍开头先不联网补一轮:没封面、存着的歌词判决里胜出的那个源自带封面且专辑逐字对上的,直接补上
// (coverSweepFillFromDecisions,外围补全的次数、节流不管这一步)。
//
// 小设备封面(deviceCoverSmall)排在后面各核一次:先在本机播放器数据、歌词判决的各源候选里找同一张图的清晰版
// (upgradeSmallDeviceCover),找不到、外围补全的上限又没到,再走一次外围补全按远程结果比。每条隔
// coverUpgradeRecheckInterval 才再核(CoverUpgradeCheckTS):新发行的歌要过一阵才进各家曲库。一个请求都没成功的
// 那条不记核过。见 03 章决策 35。

const (
	coverSweepInitialDelay = 2 * time.Minute
	coverSweepInterval     = 6 * time.Hour
	coverSweepOfflineRetry = 10 * time.Minute
	coverSweepOfflineLimit = 5
	coverSweepGap          = 30 * time.Second
	coverSweepOfflineWait  = 75 * time.Second
	coverSweepYieldPoll    = 2 * time.Second
	coverSweepYieldMax     = 5 * time.Minute
	coverSweepSaveEvery    = 10

	coverUpgradeRecheckInterval = 30 * 24 * time.Hour
	// coverUpgradeCheckRules:找清晰版的第几版找法,多了来源就加一(第 2 版加了歌词判决的各源候选,见 03 章决策 36)。
	coverUpgradeCheckRules = 2
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
	// coverSweepUpgradeLocal 在本机播放器数据、歌词判决的各源候选里给小设备封面找清晰版。单测换成假的。
	coverSweepUpgradeLocal = upgradeSmallDeviceCover
	// coverSweepSave 把攒着的改动存盘。单测换成计数。
	coverSweepSave = requestEnrichBackgroundSave
)

type coverSweepDeferSaveKey struct{}

// withCoverSweepDeferredSave 标记这一条的存盘由 runCoverSweep 攒着做,backfillPeripheralFields 见到就不当场存。
func withCoverSweepDeferredSave(ctx context.Context) context.Context {
	return context.WithValue(ctx, coverSweepDeferSaveKey{}, true)
}

func coverSweepSaveDeferred(ctx context.Context) bool {
	v, _ := ctx.Value(coverSweepDeferSaveKey{}).(bool)
	return v
}

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
	candidates, filled, upgraded, missed, skipped int
	offline                                       bool
}

// runCoverSweep 跑一遍:先补没封面的,再核小设备封面。
func runCoverSweep(ctx context.Context) coverSweepPass {
	if n := coverSweepFillFromDecisions(); n > 0 {
		slog.Info("cover sweep: filled from the lyrics winner", "count", n)
		coverSweepSave()
	}
	enrichMu.Lock()
	keys := coverSweepCandidatesLocked()
	enrichMu.Unlock()
	upgrades := coverSweepUpgradeCandidates(time.Now())
	pass := coverSweepPass{candidates: len(keys) + len(upgrades)}
	if pass.candidates == 0 {
		return pass
	}
	slog.Info("cover sweep: start", "candidates", len(keys), "small_device_covers", len(upgrades))
	offlineStreak, unsaved := 0, 0
	var wait time.Duration
	for i := 0; i < pass.candidates; i++ {
		if wait > 0 {
			coverSweepWait(ctx, wait)
		}
		coverSweepYield(ctx)
		if ctx.Err() != nil {
			break
		}
		wait = coverSweepGap
		var key string
		var outcome coverSweepOutcome
		if i < len(keys) {
			key = keys[i]
			outcome = coverSweepOne(ctx, key)
		} else {
			key = upgrades[i-len(keys)]
			outcome = coverSweepUpgradeOne(ctx, key)
		}
		switch outcome {
		case coverSweepSkipped:
			pass.skipped++
			wait = 0
		case coverSweepFilled:
			pass.filled++
			offlineStreak = 0
		case coverSweepUpgraded:
			pass.upgraded++
			offlineStreak = 0
		case coverSweepMissed:
			pass.missed++
			offlineStreak = 0
		case coverSweepOffline:
			offlineStreak++
			wait = coverSweepOfflineWait
		}
		// 没跳过的这条改过条目(补上了封面,或者推进了补全的节流时刻 / 次数)。
		if outcome != coverSweepSkipped {
			if unsaved++; unsaved >= coverSweepSaveEvery {
				coverSweepSave()
				unsaved = 0
			}
		}
		if offlineStreak >= coverSweepOfflineLimit {
			pass.offline = true
			slog.Warn("cover sweep: no request got through, stopping this pass", "streak", offlineStreak, "key", key)
			break
		}
	}
	if unsaved > 0 {
		coverSweepSave()
	}
	slog.Info("cover sweep: done", "candidates", pass.candidates, "filled", pass.filled, "upgraded", pass.upgraded,
		"missed", pass.missed, "skipped", pass.skipped, "offline", pass.offline)
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
	sortCoverSweepKeys(keys)
	return keys
}

// coverSweepUpgradeEligibleLocked:这一条现在该不该在后台核一次小设备封面。设备封面大不大另判(deviceCoverSmall,
// 要读本机文件),不在这里判。调用方持有 enrichMu。
func coverSweepUpgradeEligibleLocked(key string, e enrichEntry, now time.Time) bool {
	artist, title, _ := splitEnrichKey(key)
	return artist != "" && title != "" && e.CoverSource == "device" && !enrichInflight[key] &&
		(e.CoverUpgradeCheckRules < coverUpgradeCheckRules ||
			now.Unix()-e.CoverUpgradeCheckTS >= int64(coverUpgradeRecheckInterval/time.Second))
}

// coverSweepUpgradeCandidates 挑出这一遍要核的小设备封面,顺序同 coverSweepCandidatesLocked。设备封面大不大在锁外量
// (deviceCoverSmall 读本机文件,量过的记着)。
func coverSweepUpgradeCandidates(now time.Time) []string {
	type device struct{ key, url string }
	var devices []device
	enrichMu.Lock()
	for key, e := range enrichCache {
		if coverSweepUpgradeEligibleLocked(key, e, now) {
			devices = append(devices, device{key, e.CoverURL})
		}
	}
	enrichMu.Unlock()
	var keys []string
	for _, d := range devices {
		if deviceCoverSmall(d.url) {
			keys = append(keys, d.key)
		}
	}
	sortCoverSweepKeys(keys)
	return keys
}

// coverSweepFillFromDecisions:没封面的条目里,存着的歌词判决胜出的那个源自带封面、专辑逐字对上的,直接补上
// (winnerCandidateCover;判决明细在旁路文件里,在锁外读)。返回补上几条。
func coverSweepFillFromDecisions() int {
	type pending struct {
		key      string
		decision *lyricsDecision
	}
	var list []pending
	enrichMu.Lock()
	for key, e := range enrichCache {
		if e.CoverURL == "" && e.LyricsDecision != nil && !enrichInflight[key] && !enrichProvisional[key] {
			list = append(list, pending{key, e.LyricsDecision})
		}
	}
	enrichMu.Unlock()
	filled := 0
	for _, p := range list {
		_, _, album := splitEnrichKey(p.key)
		cover, source, coverAlbum := winnerCandidateCover(withDecisionDetails(p.key, p.decision), album)
		if cover == "" {
			continue
		}
		enrichMu.Lock()
		if e, ok := enrichCache[p.key]; ok && e.CoverURL == "" && !enrichInflight[p.key] {
			e.CoverURL, e.CoverSource, e.CoverAlbum = cover, source, coverAlbum
			enrichCache[p.key] = e
			enrichDirty = true
			filled++
		}
		enrichMu.Unlock()
	}
	return filled
}

// sortCoverSweepKeys 按歌手、专辑、key 排(同一张专辑的挨着补)。
func sortCoverSweepKeys(keys []string) {
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
	coverSweepSkipped  coverSweepOutcome = iota // 轮到时已经不该补了(播放时补上了、被删了、正在别处解析),没发请求
	coverSweepFilled                            // 补上了封面
	coverSweepUpgraded                          // 小设备封面换成了同一张图的清晰版
	coverSweepMissed                            // 请求有成功的,还是没有封面(小设备封面:没换成)
	coverSweepOffline                           // 一个请求都没成功
)

// coverSweepUpgradeOne 核一条小设备封面。进门再核一遍资格。
func coverSweepUpgradeOne(ctx context.Context, key string) coverSweepOutcome {
	artist, title, album := splitEnrichKey(key)
	now := time.Now()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	if !ok || !coverSweepUpgradeEligibleLocked(key, e, now) || !deviceCoverSmall(e.CoverURL) {
		enrichMu.Unlock()
		return coverSweepSkipped
	}
	dur := e.ResolvedDurationSecs
	if dur <= 0 {
		dur = e.DurationSecs
	}
	deviceURL, remote := e.CoverURL, peripheralBackfillWindowOpen(e)
	enrichInflight[key] = true
	enrichMu.Unlock()
	bctx := withCoverSweepDeferredSave(withBackgroundOutbound(ctx))
	round := coverSweepNetworkRound()
	// 两步都自己放掉 enrichInflight;第二步之前重新占上。
	upgraded := coverSweepUpgradeLocal(bctx, key, deviceURL, artist, coverSweepTitle(title), album, dur)
	if !upgraded && remote {
		enrichMu.Lock()
		enrichInflight[key] = true
		enrichMu.Unlock()
		coverSweepBackfill(bctx, key, artist, coverSweepTitle(title), album, dur)
	}
	attempts, failures := round()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	cur, ok := enrichCache[key]
	switch {
	case !ok:
		return coverSweepSkipped
	case cur.CoverSource != "device" || cur.CoverURL != deviceURL:
		return coverSweepUpgraded
	case attempts > 0 && !lyricsRoundConfirmsNoResult(attempts, failures):
		return coverSweepOffline
	}
	cur.CoverUpgradeCheckTS, cur.CoverUpgradeCheckRules = now.Unix(), coverUpgradeCheckRules
	enrichCache[key] = cur
	enrichDirty = true
	return coverSweepMissed
}

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
	coverSweepBackfill(withCoverSweepDeferredSave(withBackgroundOutbound(ctx)), key, artist, coverSweepTitle(title), album, dur)
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
