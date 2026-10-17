package main

import (
	"context"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 后台补封面:有词、没封面、外围字段一次都没补过的条目,不等它被播到,在后台各走一次外围补全
// (backfillPeripheralFields:条目有词时只单查网易云拿封面和链接,QQ / Apple 各查各的,不重搜歌词)。
// 从歌词文件夹导入时新建的条目(importLyricsFromOpts)只带歌词,是这里补的主要对象。见 09 章决策 195。
//
// 进程起来 coverSweepInitialDelay 后跑一遍,之后每 coverSweepInterval 一遍。一遍里逐条串行,两首之间隔
// coverSweepGap;轮到一条时有别的歌在解析(enrichInflight 非空)先等它,最多等 coverSweepYieldMax。
// 每条最多在这里补一次:补过一次 PeripheralRetryCount 就不是 0 了,之后照旧等播放时再试。例外是补法换了一版
// (coverMissingRetryRules 加一):按旧版补过的缺封面条目不管补过几次、到没到外围补全的上限,都再补一次。见 03 章决策 38。
// 一条补完自己发的请求一个都没成功时不算补过(只数这一条的,见 withNetworkRound 与 backfillPeripheralFields 记次数那一行),
// 等 coverSweepOfflineWait 再补下一条;连续 coverSweepOfflineLimit 条都这样就停下这一遍,coverSweepOfflineRetry 后再来。
// 补一条不当场存盘:每补完 coverSweepSaveEvery 条、以及一遍收尾时要一次存盘,这一次也跟别的歌的改动一样攒着、
// 最多 enrichBackgroundSaveDelay 写(App 每次存盘都要整份重读缓存,见 enrichsave.go);正在播的那首照常当场存。
//
// 一遍开头先不联网补一轮:没封面、存着的歌词判决里胜出的那个源自带封面且专辑逐字对上的,直接补上
// (coverSweepFillFromDecisions,外围补全的次数、节流不管这一步)。
//
// 这几步按专辑认的都是歌词管理显示的专辑(entryListedAlbum:写法键里没专辑时用 YouTube Music 登记的,见 03 章决策 49)。
//
// 那一轮之前还有两步:同一张专辑已经有一条归属核实过的设备封面、自己的封面归属没核实的,直接换成那张
// (coverSweepBorrowVerifiedSiblings,不联网,不等被播到);存量 QQ 封面没记专辑的,按封面地址里的专辑 mid 查回它在
// QQ 上的专辑名记进 cover_album(coverSweepNameQQCoverAlbums,一个 mid 只查一次),那一轮就判得出它是不是另一张专辑的。
// 见 03 章决策 47。
//
// 那一轮之后,同一张专辑里有核实过的设备封面、各首的封面又不止一个地址的,给整张专辑定一张封面
// (coverSweepSettleAlbumCovers):各首按图比,不止一张图时以 Apple 目录这张专辑的封面为准,Apple 没有这张专辑时用设备封面
// 那张;跟定下的不是同一张图的换成它,定下的记进 CoverSettled,之后设备封面、外围补全都不再换掉它。见 03 章决策 48。
//
// 一遍跑完再重核动态封面结论作废了的条目(封面换过,coverSweepRecheckStaleMotion)。
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
	// coverUpgradeCheckRules:找清晰版的第几版找法,多了来源就加一(第 2 版加了歌词判决的各源候选,见 03 章决策 36;
	// 第 3 版不是同一张图时换成播放器自带的,见 smallDeviceCoverYieldsTo)。
	coverUpgradeCheckRules = 3
	// coverMissingRetryRules:缺封面的补法第几版,多了一道补查就加一(第 1 版:双语曲名、判决里的歌手写法、Deezer,
	// 03 章决策 37;放宽歌词候选自带的封面、去掉 feat. 署名,决策 38)。
	coverMissingRetryRules = 1

	// coverSweepAppleGap:给专辑定封面时两次问 Apple 目录之间隔多久(iTunes Search 按 IP 限流)。coverSettleAppleTries:一张专辑
	// 最多拿几首去问。
	coverSweepAppleGap    = 10 * time.Second
	coverSettleAppleTries = 2
	// coverPictureMemoMax:按地址记着的封面指纹最多几张,满了清空重记。
	coverPictureMemoMax = 4096
)

var (
	// coverSweepWait 等 d,ctx 取消时立刻返回。单测换成不等。
	coverSweepWait = func(ctx context.Context, d time.Duration) {
		select {
		case <-ctx.Done():
		case <-time.After(d):
		}
	}
	// coverSweepBackfill 补一条;coverSweepNetworkRound 给这一条开一轮观察,只数经它返回的 ctx 发出去的请求(别处的请求混进来
	// 会把没问成的条目记成补过)。单测都换成假的。
	coverSweepBackfill     = backfillPeripheralFields
	coverSweepNetworkRound = withNetworkRound
	// coverSweepUpgradeLocal 在本机播放器数据、歌词判决的各源候选里给小设备封面找清晰版。单测换成假的。
	coverSweepUpgradeLocal = upgradeSmallDeviceCover
	// coverSweepRecheckMotion 重核一条作废的动态封面结论,返回写没写。单测换成假的。
	coverSweepRecheckMotion = recheckMotionCoverAgainstCurrentCover
	// coverSweepSave 把攒着的改动存盘。单测换成计数。
	coverSweepSave = requestEnrichBackgroundSave
	// coverSweepQQAlbumName 按专辑 mid 查 QQ 上的专辑名。单测换成假的。
	coverSweepQQAlbumName = qqAlbumName
	// coverSweepCoverImage 取一张封面的缩图;coverSweepAppleCover 问 Apple 目录这首所在专辑的封面,reached 说问到没有。
	// 给专辑定封面那一步用,单测都换成假的。
	coverSweepCoverImage = loadCoverImage
	coverSweepAppleCover = func(ctx context.Context, artist, title, album string, durationSecs float64) (cover, coverAlbum string, reached bool) {
		m, reached := appleMusicMatchCachedReached(ctx, artist, title, album, durationSecs)
		return m.cover, m.album, reached
	}
	// coverSweepAppleAnswered:问 Apple 这一首会不会只读本地(命中缓存、在负缓存窗口里),是的话不用先隔 coverSweepAppleGap。
	coverSweepAppleAnswered = appleMusicMatchAnsweredLocally

	coverPictureMu   sync.Mutex
	coverPictureMemo = map[string]coverPicture{}
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
		offline := runCoverSweep(ctx).offline
		if !offline {
			offline = coverSweepRecheckStaleMotion(ctx).offline
		}
		if offline {
			delay = coverSweepOfflineRetry
		}
	}
}

// coverSweepMotionGap:重核动态封面时两条要取图的之间隔多久。
const coverSweepMotionGap = time.Second

// coverSweepMotionPass:重核动态封面那一遍的结果。rechecked:写下了新结论的条数;dropped:其中摘掉动态封面的;offline:连着
// coverSweepOfflineLimit 条没写下结论、经这一条发出去的请求又全失败了,提前停下了。
type coverSweepMotionPass struct {
	rechecked, dropped int
	offline            bool
}

// coverSweepRecheckStaleMotion:动态封面结论作废的条目(motionVerdictStale:封面后来换过,或结论早于记下对照封面)按现在的封面
// 逐条重核(recheckMotionCoverAgainstCurrentCover),排在补封面那几步之后,核的是这一遍换完的封面。专辑已知没有动态封面、原来那段
// 也不用再比的,只读本地缓存;专辑页没查过的要抓一次页面,有动画要比的要取图。
//
// 离线只看这一条自己的请求(coverSweepNetworkRound):没写下结论、发出去的又全失败了才算一条没查成,连着 coverSweepOfflineLimit
// 条就停。图取到了却比不成(404、解不开的图、设备封面文件没了)、一个请求都没发的,都不算 —— 那是这一条自己的问题,算进去会把
// 整遍判成离线、十分钟后又整遍重来。要取图(专辑已知有动画,或这一条确实发了请求)的两条之间隔 coverSweepMotionGap,每条之前先给
// 在解析的歌让路。见 03 章决策 53。
func coverSweepRecheckStaleMotion(ctx context.Context) coverSweepMotionPass {
	type stale struct {
		key, title, album string
		images, had       bool
	}
	enrichMu.Lock()
	var list []stale
	for key, e := range enrichCache {
		if !motionVerdictStale(e) || enrichInflight[key] || enrichProvisional[key] {
			continue
		}
		artist, title, album := splitEnrichKey(key)
		list = append(list, stale{key, title, album, motionCoverAlbumHasKnownVideo(e, artist, title, album), e.MotionCoverURL != ""})
	}
	enrichMu.Unlock()
	var pass coverSweepMotionPass
	if len(list) == 0 {
		return pass
	}
	sort.Slice(list, func(i, j int) bool { return list[i].key < list[j].key })
	misses, unsaved := 0, 0
	for _, s := range list {
		coverSweepYield(ctx)
		if ctx.Err() != nil {
			break
		}
		rctx, round := coverSweepNetworkRound(ctx)
		wrote := coverSweepRecheckMotion(rctx, s.key, s.title, s.album)
		attempts, failures := round()
		switch {
		case wrote:
			pass.rechecked++
			misses = 0
			enrichMu.Lock()
			if e, ok := enrichCache[s.key]; ok && s.had && e.MotionCoverURL == "" {
				pass.dropped++
			}
			enrichMu.Unlock()
			if unsaved++; unsaved >= coverSweepSaveEvery {
				coverSweepSave()
				unsaved = 0
			}
		case attempts > 0 && failures == attempts:
			if misses++; misses >= coverSweepOfflineLimit {
				pass.offline = true
			}
		case attempts > 0:
			misses = 0
		}
		if pass.offline {
			break
		}
		if s.images || attempts > 0 {
			coverSweepWait(ctx, coverSweepMotionGap)
		}
	}
	if unsaved > 0 {
		coverSweepSave()
	}
	slog.Info("cover sweep: rechecked stale motion covers", "stale", len(list), "rechecked", pass.rechecked,
		"dropped", pass.dropped, "offline", pass.offline)
	return pass
}

// coverSweepPass 是一遍的结果。offlineItems:一个请求都没成功的条数;offline:连续 coverSweepOfflineLimit 条这样,这一遍
// 提前停下了。
type coverSweepPass struct {
	candidates, filled, upgraded, missed, skipped, offlineItems int
	offline                                                     bool
}

// runCoverSweep 跑一遍:先补没封面的,再核小设备封面。
func runCoverSweep(ctx context.Context) coverSweepPass {
	if n := coverSweepBorrowVerifiedSiblings(); n > 0 {
		slog.Info("cover sweep: took the album's verified device cover", "count", n)
		coverSweepSave()
	}
	if n := coverSweepNameQQCoverAlbums(ctx); n > 0 {
		slog.Info("cover sweep: recorded the QQ album of stored QQ covers", "count", n)
		coverSweepSave()
	}
	if n := coverSweepFillFromPlayerCovers(); n > 0 {
		slog.Info("cover sweep: took the player's own cover", "count", n)
		coverSweepSave()
	}
	if n := coverSweepFillFromDecisions(); n > 0 {
		slog.Info("cover sweep: filled from the lyrics winner", "count", n)
		coverSweepSave()
	}
	if n := coverSweepBorrowAlbumSiblings(); n > 0 {
		slog.Info("cover sweep: borrowed the album's cover from a sibling", "count", n)
		coverSweepSave()
	}
	if switched, settled := coverSweepSettleAlbumCovers(ctx); settled > 0 {
		slog.Info("cover sweep: settled album covers", "entries", settled, "switched", switched)
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
			pass.offlineItems++
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
		"missed", pass.missed, "skipped", pass.skipped, "offline_items", pass.offlineItems, "offline", pass.offline)
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
// 同 peripheralBackfillSkipsLyrics),没词的归补空扫描(lyricsfillsweep.go);key 里没有歌手的不补。没补过的按外围补全的
// 上限和节流;补过的只在补法换了一版时再补一次,只看节流。调用方持有 enrichMu。
func coverSweepEligibleLocked(key string, e enrichEntry) bool {
	artist, title, _ := splitEnrichKey(key)
	if artist == "" || title == "" || e.CoverURL != "" || !peripheralBackfillSkipsLyrics(e) || enrichInflight[key] {
		return false
	}
	if e.PeripheralRetryCount == 0 {
		return peripheralBackfillWindowOpen(e)
	}
	return e.CoverMissingRetryRules < coverMissingRetryRules && peripheralBackfillThrottleElapsed(e)
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

// coverSweepFillFromDecisions:没封面、或封面明确是另一张专辑的(coverOfAnotherAlbum)条目里,存着的歌词判决胜出的那个源
// 自带封面、专辑对得上的,直接补上 / 换上(winnerCandidateCover;判决明细在旁路文件里,在锁外读)。换掉旧封面时主色一起清空,
// 不留新封面配旧主色,配了中继的下次外围补全会重算。返回补上 / 换上几条。
func coverSweepFillFromDecisions() int {
	type pending struct {
		key, cover, album string
		decision          *lyricsDecision
	}
	var list []pending
	enrichMu.Lock()
	for key, e := range enrichCache {
		if e.LyricsDecision == nil || enrichInflight[key] || enrichProvisional[key] {
			continue
		}
		if album := entryListedAlbum(key, e); e.CoverURL == "" || coverOfAnotherAlbum(e, album) {
			list = append(list, pending{key, e.CoverURL, album, e.LyricsDecision})
		}
	}
	enrichMu.Unlock()
	filled := 0
	for _, p := range list {
		cover, source, coverAlbum := winnerCandidateCover(withDecisionDetails(p.key, p.decision), p.album)
		if cover == "" || cover == p.cover {
			continue
		}
		enrichMu.Lock()
		if e, ok := enrichCache[p.key]; ok && e.CoverURL == p.cover && !enrichInflight[p.key] {
			if e.CoverURL != "" {
				e.AccentColor = ""
			}
			e.CoverURL, e.CoverSource, e.CoverAlbum = cover, source, coverAlbum
			enrichCache[p.key] = e
			enrichDirty = true
			filled++
		}
		enrichMu.Unlock()
	}
	return filled
}

// coverSweepFillFromPlayerCovers:没封面、或封面明确是另一张专辑的(coverOfAnotherAlbum)条目,记着播放器自带封面
// (player_covers,entryPlayerCover 挑)的直接换上,记成 player、cover_album 记本地专辑,换掉旧封面时主色清空(同
// coverSweepFillFromDecisions)。专辑定下的(coverSettled)不动。纯内存、不联网;排在从歌词判决补之前:自带封面是播放器
// 按这首记的,判决里的候选只是专辑对得上。见 03 章决策 51。返回换了几条。
func coverSweepFillFromPlayerCovers() int {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	filled := 0
	for key, e := range enrichCache {
		if enrichInflight[key] || enrichProvisional[key] {
			continue
		}
		// 专辑定下的,coverOfAnotherAlbum 恒为 false,不动。
		album := entryListedAlbum(key, e)
		if e.CoverURL != "" && !coverOfAnotherAlbum(e, album) {
			continue
		}
		own := entryPlayerCover(e)
		if own == "" || own == e.CoverURL {
			continue
		}
		if e.CoverURL != "" {
			e.AccentColor = ""
		}
		e.CoverURL, e.CoverSource, e.CoverAlbum = own, "player", album
		enrichCache[key] = e
		enrichDirty = true
		filled++
	}
	return filled
}

// coverSweepBorrowAlbumSiblings:没封面、或封面明确是另一张专辑的(coverOfAnotherAlbum)条目,借同一张专辑(歌词管理显示的专辑
// 繁简折叠后相同)、同一位歌手(albumSiblingArtistMatches)里封面属于这张专辑的那条(albumSiblingLends)。出借的按专辑定下的、设备、
// 播放器自带、其它的顺序,同档取 key 小的;cover_album 记出借那条的,主色清空。专辑定下的不动。纯内存、不联网,排在从歌词判决补
// 之后:按专辑统一封面的几步都没补上的才轮到这里。见 03 章决策 51。返回借了几条。
func coverSweepBorrowAlbumSiblings() int {
	type lender struct {
		key, artist string
		e           enrichEntry
		rank        int
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	lenders := map[string][]lender{}
	for key, e := range enrichCache {
		album := entryListedAlbum(key, e)
		if album == "" || !albumSiblingLends(e, album) {
			continue
		}
		artist, _, _ := splitEnrichKey(key)
		simp := toSimplified(album)
		lenders[simp] = append(lenders[simp], lender{key, artist, e, albumSiblingLendRank(e)})
	}
	for _, ls := range lenders {
		sort.Slice(ls, func(i, j int) bool {
			if ls[i].rank != ls[j].rank {
				return ls[i].rank < ls[j].rank
			}
			return ls[i].key < ls[j].key
		})
	}
	borrowed := 0
	for key, e := range enrichCache {
		if enrichInflight[key] || enrichProvisional[key] || coverSettled(e) {
			continue
		}
		album := entryListedAlbum(key, e)
		if album == "" || (e.CoverURL != "" && !coverOfAnotherAlbum(e, album)) {
			continue
		}
		artist, _, _ := splitEnrichKey(key)
		for _, l := range lenders[toSimplified(album)] {
			if l.key == key || !albumSiblingArtistMatches(artist, e.CanonicalArtist, l.artist, l.e.CanonicalArtist) {
				continue
			}
			if l.e.CoverURL != e.CoverURL {
				coverAlbum := l.e.CoverAlbum
				if strings.TrimSpace(coverAlbum) == "" {
					coverAlbum = album
				}
				e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = l.e.CoverURL, l.e.CoverSource, coverAlbum, ""
				enrichCache[key] = e
				borrowed++
			}
			break
		}
	}
	if borrowed > 0 {
		enrichDirty = true
	}
	return borrowed
}

// albumSiblingLends:这条的封面能不能借给专辑 album 的其它曲目:有封面,而且明确属于这张专辑 —— 专辑定下的、设备封面和播放器自带的
// (记的就是本地专辑)、cover_album 有值并对得上(candidateCoverAlbumFits)。cover_album 空着的说不清是哪张,不借。纯函数。
func albumSiblingLends(e enrichEntry, album string) bool {
	if e.CoverURL == "" {
		return false
	}
	if coverSettled(e) || e.CoverSource == "device" || e.CoverSource == "player" {
		return true
	}
	return candidateCoverAlbumFits(e.CoverAlbum, album)
}

// albumSiblingLendRank:出借的先后,小的优先:专辑定下的、设备封面、播放器自带、其它。纯函数。
func albumSiblingLendRank(e enrichEntry) int {
	switch {
	case coverSettled(e):
		return 0
	case e.CoverSource == "device":
		return 1
	case e.CoverSource == "player":
		return 2
	}
	return 3
}

// albumSiblingArtistMatches:借封面的两条是不是同一位歌手:写法键里的歌手对得上(artistMatches),或任一边曲库核实过的官方歌手名
// (canonical_artist)对得上另一边 ——「Khalil Fong」那条的官方名是「方大同」。纯函数。
func albumSiblingArtistMatches(artist, canonical, lenderArtist, lenderCanonical string) bool {
	return artistMatches(artist, lenderArtist) ||
		(canonical != "" && artistMatches(canonical, lenderArtist)) ||
		(lenderCanonical != "" && artistMatches(artist, lenderCanonical)) ||
		(canonical != "" && lenderCanonical != "" && artistMatches(canonical, lenderCanonical))
}

// coverSweepBorrowVerifiedSiblings:封面归属没核实的条目(coverAwaitsVerifiedSibling),同一张专辑已经有一条归属核实过的设备
// 封面时直接换成那张,判据跟 siblingCoverLocked 的 device 档一样(siblingLendsAlbumIdentity、歌手对得上、专辑繁简折叠后相同、
// 有几条可借时取 key 最小的);cover_album 记本地专辑,主色清空(同 coverSweepFillFromDecisions)。已经是同一张图的不动。纯内存、
// 不联网,不等这首被播到才走 coverCanUpgradeToVerifiedSiblingLocked 那条自愈。先按专辑把能借的分好桶再挑:逐条问
// siblingCoverLocked 的话每条都要扫一遍整个缓存。返回换了几条。见 03 章决策 47。
func coverSweepBorrowVerifiedSiblings() int {
	type lender struct {
		key, artist string
		e           enrichEntry
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	lenders := map[string][]lender{}
	for key, e := range enrichCache {
		if !coverSourceLendsAlbumIdentity(e.CoverSource) {
			continue
		}
		artist, _, _ := splitEnrichKey(key)
		if album := entryListedAlbum(key, e); album != "" {
			simp := toSimplified(album)
			lenders[simp] = append(lenders[simp], lender{key, artist, e})
		}
	}
	for _, ls := range lenders {
		sort.Slice(ls, func(i, j int) bool { return ls[i].key < ls[j].key })
	}
	borrowed := 0
	for key, e := range enrichCache {
		artist, _, _ := splitEnrichKey(key)
		album := entryListedAlbum(key, e)
		if !coverAwaitsVerifiedSibling(e, album) || enrichInflight[key] || enrichProvisional[key] {
			continue
		}
		for _, l := range lenders[toSimplified(album)] {
			if !siblingLendsAlbumIdentity(l.e, album) || !artistMatches(l.artist, artist) {
				continue
			}
			if l.e.CoverURL != e.CoverURL {
				e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = l.e.CoverURL, l.e.CoverSource, album, ""
				enrichCache[key] = e
				borrowed++
			}
			break
		}
	}
	if borrowed > 0 {
		enrichDirty = true
	}
	return borrowed
}

// coverSweepNameGap:查存量 QQ 封面的专辑名时两次请求之间隔多久。
const coverSweepNameGap = time.Second

// coverSweepNameQQCoverAlbums:存量 QQ 封面没记专辑的(cover_album 空),按封面地址里的专辑 mid(qqCoverAlbumMid)查回它在
// QQ 上的专辑名记进 cover_album,之后 coverOfAnotherAlbum 才判得出它是不是另一张专辑的。一个 mid 只查一次,两次之间隔
// coverSweepNameGap;QQ 答了没有名字的留空;连着 coverSweepOfflineLimit 个 mid 都没问成就停,下一遍再来。返回记上几条。
// 见 03 章决策 47。
func coverSweepNameQQCoverAlbums(ctx context.Context) int {
	keysByMid := map[string][]string{}
	enrichMu.Lock()
	for key, e := range enrichCache {
		if e.CoverSource != "qq" || e.CoverAlbum != "" {
			continue
		}
		if mid := qqCoverAlbumMid(e.CoverURL); mid != "" {
			keysByMid[mid] = append(keysByMid[mid], key)
		}
	}
	enrichMu.Unlock()
	mids := make([]string, 0, len(keysByMid))
	for mid := range keysByMid {
		mids = append(mids, mid)
	}
	sort.Strings(mids)
	named, unreached := 0, 0
	for i, mid := range mids {
		if i > 0 {
			coverSweepWait(ctx, coverSweepNameGap)
		}
		coverSweepYield(ctx)
		if ctx.Err() != nil {
			break
		}
		name, err := coverSweepQQAlbumName(withBackgroundOutbound(ctx), mid)
		if err != nil {
			if unreached++; unreached >= coverSweepOfflineLimit {
				slog.Warn("cover sweep: QQ album lookups got no answer, stopping", "streak", unreached, "album_mid", mid)
				break
			}
			continue
		}
		unreached = 0
		if name == "" {
			continue
		}
		enrichMu.Lock()
		for _, key := range keysByMid[mid] {
			e, ok := enrichCache[key]
			if !ok || e.CoverSource != "qq" || e.CoverAlbum != "" || qqCoverAlbumMid(e.CoverURL) != mid || enrichInflight[key] {
				continue
			}
			e.CoverAlbum = name
			enrichCache[key] = e
			enrichDirty = true
			named++
		}
		enrichMu.Unlock()
	}
	return named
}

// coverPicture:一张封面的 8×8 指纹(coverFingerprint,不裁边:带黑边的跟不带的算两张)和它是不是补边的长方形图
// (coverContentLetterboxed)。fp 为 0 是没取到或者是纯色图,比不了。
type coverPicture struct {
	fp          uint64
	letterboxed bool
}

// same:两张都比得了,指纹距离在 coverFingerprintMaxDistance 以内。
func (p coverPicture) same(q coverPicture) bool {
	return p.fp != 0 && q.fp != 0 && coverFingerprintDistance(p.fp, q.fp) <= coverFingerprintMaxDistance
}

// coverSweepPicture 取一张封面的 coverPicture,取到的按地址记着(设备封面的文件名就是内容的哈希,远程图地址不变图就不变),
// 纯色图(fp 为 0)也记:再取一次还是它。没取到、解不开的不记。
func coverSweepPicture(ctx context.Context, url string) coverPicture {
	coverPictureMu.Lock()
	p, ok := coverPictureMemo[url]
	coverPictureMu.Unlock()
	if ok {
		return p
	}
	img := coverSweepCoverImage(ctx, url)
	if img == nil {
		return coverPicture{}
	}
	p = coverPicture{coverFingerprint(img), coverContentLetterboxed(img)}
	coverPictureMu.Lock()
	if len(coverPictureMemo) >= coverPictureMemoMax {
		coverPictureMemo = map[string]coverPicture{}
	}
	coverPictureMemo[url] = p
	coverPictureMu.Unlock()
	return p
}

// coverSettleMember:给专辑定封面时的一条:key、key 里的歌手和专辑、读出来时的条目。
type coverSettleMember struct {
	key, artist, album string
	e                  enrichEntry
}

// coverSettleOutcome:一张专辑这一遍定没定下来。
type coverSettleOutcome int

const (
	coverSettleDecided coverSettleOutcome = iota
	// coverSettleUnreached:有图没取到、Apple 没问到,下一遍再定。
	coverSettleUnreached
	// coverSettleUndecided:Apple 没有这张专辑、设备封面那张又是补边的长方形图,不定。
	coverSettleUndecided
)

// coverSettlePlan:一张专辑定下的那张图(ref)、给要换的条目用的那一份(rep)、组里各地址的图(pics),by 记是怎么定的。
type coverSettlePlan struct {
	ref  coverPicture
	rep  enrichEntry
	pics map[string]coverPicture
	by   string
}

// coverSweepSettleAlbumCovers:同一张专辑(歌手对得上、专辑名繁简折叠后相同)里各首的封面不止一个地址的,给整张专辑定一张封面
// (coverSettlePlanFor),跟它不是同一张图的条目换成它,所有条目记下 CoverSettled(见 coverSettled)。没有核实过的设备封面、
// 也没定过的专辑,只在各首其实是同一张图、或 Apple 目录这张专辑的封面跟其中一张是同一张图时定,别的不定(03 章决策 52)。一张专辑
// 有图没取到、Apple 没问到时这一遍不定它;为这张专辑发出去的请求(coverSweepNetworkRound,只数这一张的)又全失败了才算没问成,
// 连着 coverSweepOfflineLimit 张都这样就停。图有回话却比不了(纯色、解不开)、一个请求都没发(本机文件没了)的只是这张专辑自己
// 定不了,不数进去:不然排在前面的几张坏图每一遍都让这一步停在同一处。每张专辑之前先给在解析的歌让路。返回记下几条、其中换了
// 几条。见 03 章决策 48。
//
// 专辑名一样、播放器登记的专辑 id 却不一样的一组(coverSettleAlbumsDiffer,「Greatest Hits」这类)不是一张专辑:不定,先前定下的
// 放开(只清 CoverSettled,封面不动),之后设备封面、外围补全照常能换。
func coverSweepSettleAlbumCovers(ctx context.Context) (switched, settled int) {
	enrichMu.Lock()
	groups, mixed := coverSettleGroupsLocked()
	released := coverSettleReleaseLocked(mixed)
	enrichMu.Unlock()
	if released > 0 {
		slog.Info("cover sweep: released settled covers of same-named different albums", "entries", released)
		coverSweepSave()
	}
	unreached, askedApple := 0, false
	for _, g := range groups {
		coverSweepYield(ctx)
		if ctx.Err() != nil {
			break
		}
		gctx, round := coverSweepNetworkRound(ctx)
		plan, outcome := coverSettlePlanFor(gctx, g, &askedApple)
		if outcome == coverSettleUnreached {
			if attempts, failures := round(); attempts == 0 || failures < attempts {
				continue
			}
			if unreached++; unreached >= coverSweepOfflineLimit {
				slog.Warn("cover sweep: album covers could not be compared, stopping", "streak", unreached, "key", g[0].key)
				break
			}
			continue
		}
		unreached = 0
		if outcome != coverSettleDecided {
			continue
		}
		s, n := coverSettleApply(g, plan)
		settled += s
		switched += n
		if n > 0 {
			slog.Info("cover sweep: settled an album's cover", "key", g[0].key, "by", plan.by, "switched", n, "cover", plan.rep.CoverURL)
		}
	}
	return switched, settled
}

// coverSettleGroupsLocked 把有封面的条目按专辑分组(专辑名繁简折叠后相同、歌手对得上),挑出该定封面的那些组
// (coverSettleGroupDue),组内、组间都按 key 排;mixed 是同名不同专辑的那些组(coverSettleAlbumsDiffer),不进 groups。解析中、
// 提前提交的条目不进组。调用方持有 enrichMu。
func coverSettleGroupsLocked() (groups, mixed [][]coverSettleMember) {
	buckets := map[string][]coverSettleMember{}
	for key, e := range enrichCache {
		if e.CoverURL == "" || enrichInflight[key] || enrichProvisional[key] {
			continue
		}
		artist, _, _ := splitEnrichKey(key)
		if album := entryListedAlbum(key, e); album != "" {
			simp := toSimplified(album)
			buckets[simp] = append(buckets[simp], coverSettleMember{key, artist, album, e})
		}
	}
	for _, ms := range buckets {
		sort.Slice(ms, func(i, j int) bool { return ms[i].key < ms[j].key })
		var byArtist [][]coverSettleMember
		for _, m := range ms {
			placed := false
			for i, g := range byArtist {
				if artistMatches(g[0].artist, m.artist) {
					byArtist[i], placed = append(g, m), true
					break
				}
			}
			if !placed {
				byArtist = append(byArtist, []coverSettleMember{m})
			}
		}
		for _, g := range byArtist {
			switch {
			case coverSettleAlbumsDiffer(g):
				mixed = append(mixed, g)
			case coverSettleGroupDue(g):
				groups = append(groups, g)
			}
		}
	}
	sort.Slice(groups, func(i, j int) bool { return groups[i][0].key < groups[j][0].key })
	return groups, mixed
}

// coverSettleAlbumsDiffer:组里有两条在同一家登记的专辑 id 不一样 —— 汽水、KKBOX、Amazon Music、Spotify 本机数据里给这首记的,
// Kaset 按 YouTube Music 判的(都不是按文字搜出来的;QQ 专辑 mid、Apple 链接是,不看)。专辑名一样、其实是两张专辑,或同一张的
// 两个版本,封面不该统一。拿不出 id 的不算不一样。纯函数。
func coverSettleAlbumsDiffer(g []coverSettleMember) bool {
	seen := map[int]string{}
	for _, m := range g {
		for i, id := range []string{m.e.SodaAlbumID, m.e.KKBOXAlbumID, m.e.AmazonAlbumASIN, m.e.SpotifyAlbumID, m.e.YouTubeMusicAlbumID} {
			if id = strings.TrimSpace(id); id == "" {
				continue
			}
			if prev, ok := seen[i]; ok && prev != id {
				return true
			}
			seen[i] = id
		}
	}
	return false
}

// coverSettleReleaseLocked 把这几组里定下的条目放开(清 CoverSettled,封面不动),返回放开几条。解析中、提前提交的不动。调用方持有
// enrichMu。
func coverSettleReleaseLocked(groups [][]coverSettleMember) int {
	released := 0
	for _, g := range groups {
		for _, m := range g {
			e, ok := enrichCache[m.key]
			if !ok || e.CoverSettled == "" || enrichInflight[m.key] || enrichProvisional[m.key] {
				continue
			}
			e.CoverSettled = ""
			enrichCache[m.key] = e
			released++
		}
	}
	if released > 0 {
		enrichDirty = true
	}
	return released
}

// coverSettleGroupDue:这组该定封面 —— 封面不止一个地址(都是同一个地址就没什么可比的)。没有核实过的设备
// 封面的组也定,怎么定见 coverSettlePlanFor;都定过、地址仍不止一个的(先前同一张图各留各的地址)也再定一次(03 章决策 52)。
func coverSettleGroupDue(g []coverSettleMember) bool {
	urls := map[string]bool{}
	for _, m := range g {
		urls[m.e.CoverURL] = true
	}
	return len(urls) > 1
}

// coverSettlePlanFor 给一组定封面,各首的封面按图比(coverSweepPicture):
//   - 之前定过的:照 key 最小那条定下的那张;
//   - 都是同一张图:就是它;
//   - 不止一张:Apple 目录这张专辑的封面(coverSettleApplePicture)跟组里哪张是同一张图就定哪张;Apple 没有这张专辑、给的是
//     第三张图时,定 key 最小那条核实过的设备封面那张(它是补边的长方形图时不定,组里没有核实过的设备封面时也不定)。
//
// rep 在跟定下的那张是同一张图的条目里按 coverSettleRank 挑。askedApple:这一遍问过 Apple 没有,再问之前先隔 coverSweepAppleGap。
func coverSettlePlanFor(ctx context.Context, g []coverSettleMember, askedApple *bool) (coverSettlePlan, coverSettleOutcome) {
	plan := coverSettlePlan{pics: map[string]coverPicture{}}
	for _, m := range g {
		if _, ok := plan.pics[m.e.CoverURL]; ok {
			continue
		}
		p := coverSweepPicture(withBackgroundOutbound(ctx), m.e.CoverURL)
		if p.fp == 0 {
			return plan, coverSettleUnreached
		}
		plan.pics[m.e.CoverURL] = p
	}
	plan.ref, plan.by = coverSettlePicture(g, plan.pics)
	if plan.by == "" {
		apple, reached := coverSettleApplePicture(ctx, g, plan.pics, askedApple)
		if !reached {
			return plan, coverSettleUnreached
		}
		plan.ref, plan.by = coverSettleFallback(g, plan.pics, apple)
		if plan.by == "" {
			return plan, coverSettleUndecided
		}
	}
	best := -1
	for i, m := range g {
		if !plan.pics[m.e.CoverURL].same(plan.ref) {
			continue
		}
		if best < 0 || coverSettleRank(m.e) < coverSettleRank(g[best].e) {
			best = i
		}
	}
	if best < 0 {
		return plan, coverSettleUndecided
	}
	plan.rep = g[best].e
	return plan, coverSettleDecided
}

// coverSettlePicture:不用问 Apple 就定得下的那两种 —— 之前定过(照 key 最小那条)、都是同一张图;都不是返回空的 by。
func coverSettlePicture(g []coverSettleMember, pics map[string]coverPicture) (coverPicture, string) {
	for _, m := range g {
		if coverSettled(m.e) {
			return pics[m.e.CoverURL], "settled"
		}
	}
	first := pics[g[0].e.CoverURL]
	for _, m := range g {
		if !pics[m.e.CoverURL].same(first) {
			return coverPicture{}, ""
		}
	}
	return first, "same"
}

// coverSettleFallback:组里有跟 Apple 那张是同一张图的就定 Apple 那张;没有时定 key 最小那条核实过的设备封面那张,它是补边的
// 长方形图(不是封面本来的样子)时不定,返回空的 by。
func coverSettleFallback(g []coverSettleMember, pics map[string]coverPicture, apple coverPicture) (coverPicture, string) {
	for _, m := range g {
		if pics[m.e.CoverURL].same(apple) {
			return apple, "apple"
		}
	}
	for _, m := range g {
		if siblingLendsAlbumIdentity(m.e, m.album) {
			if p := pics[m.e.CoverURL]; !p.letterboxed {
				return p, "device"
			}
			break
		}
	}
	return coverPicture{}, ""
}

// coverSettleApplePicture:Apple 目录给这张专辑的封面的图。组里有 Apple 给的、专辑对得上的封面就用它,不再问;否则按 key 顺序
// 拿头 coverSettleAppleTries 首去问(coverSweepAppleCover),专辑对得上(candidateCoverAlbumFits)的才算。Apple 没有这张专辑
// 返回 fp 为 0 的图;没问到、图没取到返回 false。只读本地就答得出的(coverSweepAppleAnswered)不先等 coverSweepAppleGap,
// 也不算问过。
func coverSettleApplePicture(ctx context.Context, g []coverSettleMember, pics map[string]coverPicture, asked *bool) (coverPicture, bool) {
	for _, m := range g {
		if m.e.CoverSource == "apple" && candidateCoverAlbumFits(m.e.CoverAlbum, m.album) {
			return pics[m.e.CoverURL], true
		}
	}
	for i, m := range g {
		if i == coverSettleAppleTries {
			break
		}
		_, title, _ := splitEnrichKey(m.key)
		if !coverSweepAppleAnswered(m.artist, title, m.album) {
			if *asked {
				coverSweepWait(ctx, coverSweepAppleGap)
			}
			*asked = true
		}
		if ctx.Err() != nil {
			return coverPicture{}, false
		}
		cover, coverAlbum, reached := coverSweepAppleCover(withBackgroundOutbound(ctx), m.artist, title, m.album, m.e.DurationSecs)
		if !reached {
			return coverPicture{}, false
		}
		if cover == "" || !candidateCoverAlbumFits(coverAlbum, m.album) {
			continue
		}
		p := coverSweepPicture(withBackgroundOutbound(ctx), cover)
		return p, p.fp != 0
	}
	return coverPicture{}, true
}

// coverSettleRank:定下的那张图有几份地址时,给要换的条目挑哪一份,小的优先:网易云(清晰,国内加载得出来)、够清晰的设备封面、
// 别的 https、其余;同档取 key 小的(调用方按 key 顺序挑)。设备封面大不大要读本机文件,调用方不能持着 enrichMu。
func coverSettleRank(e enrichEntry) int {
	switch {
	case e.CoverSource == "netease":
		return 0
	case e.CoverSource == "device" && !deviceCoverSmall(e.CoverURL):
		return 1
	case strings.HasPrefix(e.CoverURL, "https://"):
		return 2
	}
	return 3
}

// coverSettleApply 按 plan 写回一组:地址不是 plan.rep 那一份的(同一张图也算)换成它(地址、来源、cover_album、主色),都记下
// CoverSettled。读出来之后封面被换过、解析中、提前提交、已经定在 plan.rep 上的不动。返回记下几条、其中换了几条。
func coverSettleApply(g []coverSettleMember, plan coverSettlePlan) (settled, switched int) {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, m := range g {
		e, ok := enrichCache[m.key]
		if !ok || e.CoverURL != m.e.CoverURL || enrichInflight[m.key] || enrichProvisional[m.key] ||
			(coverSettled(e) && e.CoverURL == plan.rep.CoverURL) {
			continue
		}
		// 同一张图、地址不同的也换成定下的那一份:各家给同一张专辑的图版本不同(色调、裁切),按图比算同一张,排在一起仍不统一。
		if e.CoverURL != plan.rep.CoverURL {
			e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor =
				plan.rep.CoverURL, plan.rep.CoverSource, plan.rep.CoverAlbum, plan.rep.AccentColor
			switched++
		}
		e.CoverSettled = e.CoverURL
		enrichCache[m.key] = e
		settled++
	}
	if settled > 0 {
		enrichDirty = true
	}
	return settled, switched
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

// coverSweepUpgradeOne 核一条小设备封面。进门再核一遍资格;设备封面大不大要读本机文件,在锁外量,量完再核一遍封面没换。
func coverSweepUpgradeOne(ctx context.Context, key string) coverSweepOutcome {
	artist, title, album := splitEnrichKey(key)
	now := time.Now()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok || !deviceCoverSmall(e.CoverURL) {
		return coverSweepSkipped
	}
	measured := e.CoverURL
	enrichMu.Lock()
	e, ok = enrichCache[key]
	if !ok || e.CoverURL != measured || !coverSweepUpgradeEligibleLocked(key, e, now) {
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
	bctx, round := coverSweepNetworkRound(withCoverSweepDeferredSave(withBackgroundOutbound(ctx)))
	// 两步都自己放掉 enrichInflight;第二步之前重新占上。
	upgraded := coverSweepUpgradeLocal(bctx, key, deviceURL, artist, coverSweepTitle(title), album, dur)
	if !upgraded && remote {
		enrichMu.Lock()
		taken := enrichInflight[key]
		if !taken {
			enrichInflight[key] = true
		}
		enrichMu.Unlock()
		if taken {
			// 第一步放掉之后别处(换歌那一拍、预取)已经占上了这一条:交给它,这一遍不记核过。
			return coverSweepSkipped
		}
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
	bctx, round := coverSweepNetworkRound(withCoverSweepDeferredSave(withBackgroundOutbound(ctx)))
	// 同步跑:backfillPeripheralFields 自己清 enrichInflight、落盘、通知重推。
	coverSweepBackfill(bctx, key, artist, coverSweepTitle(title), album, dur)
	attempts, failures := round()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	cur, ok := enrichCache[key]
	filled := ok && cur.CoverURL != ""
	if !filled && !lyricsRoundConfirmsNoResult(attempts, failures) {
		return coverSweepOffline
	}
	// 按这一版补法补过了(一个请求都没成功的不算)。
	if ok {
		cur.CoverMissingRetryRules = coverMissingRetryRules
		enrichCache[key] = cur
		enrichDirty = true
	}
	if filled {
		return coverSweepFilled
	}
	return coverSweepMissed
}
