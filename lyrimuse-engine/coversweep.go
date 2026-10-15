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
// 那一轮之前还有两步:同一张专辑已经有一条归属核实过的设备封面、自己的封面归属没核实的,直接换成那张
// (coverSweepBorrowVerifiedSiblings,不联网,不等被播到);存量 QQ 封面没记专辑的,按封面地址里的专辑 mid 查回它在
// QQ 上的专辑名记进 cover_album(coverSweepNameQQCoverAlbums,一个 mid 只查一次),那一轮就判得出它是不是另一张专辑的。
// 见 03 章决策 47。
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
	// coverMissingRetryRules:缺封面的补法第几版,多了一道补查就加一(第 1 版:双语曲名、判决里的歌手写法、Deezer,
	// 03 章决策 37;放宽歌词候选自带的封面、去掉 feat. 署名,决策 38)。
	coverMissingRetryRules = 1
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
	// coverSweepSave 把攒着的改动存盘。单测换成计数。
	coverSweepSave = requestEnrichBackgroundSave
	// coverSweepQQAlbumName 按专辑 mid 查 QQ 上的专辑名。单测换成假的。
	coverSweepQQAlbumName = qqAlbumName
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
		key, cover string
		decision   *lyricsDecision
	}
	var list []pending
	enrichMu.Lock()
	for key, e := range enrichCache {
		if e.LyricsDecision == nil || enrichInflight[key] || enrichProvisional[key] {
			continue
		}
		if _, _, album := splitEnrichKey(key); e.CoverURL == "" || coverOfAnotherAlbum(e, album) {
			list = append(list, pending{key, e.CoverURL, e.LyricsDecision})
		}
	}
	enrichMu.Unlock()
	filled := 0
	for _, p := range list {
		_, _, album := splitEnrichKey(p.key)
		cover, source, coverAlbum := winnerCandidateCover(withDecisionDetails(p.key, p.decision), album)
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
		artist, _, album := splitEnrichKey(key)
		if album != "" {
			simp := toSimplified(album)
			lenders[simp] = append(lenders[simp], lender{key, artist, e})
		}
	}
	for _, ls := range lenders {
		sort.Slice(ls, func(i, j int) bool { return ls[i].key < ls[j].key })
	}
	borrowed := 0
	for key, e := range enrichCache {
		artist, _, album := splitEnrichKey(key)
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
