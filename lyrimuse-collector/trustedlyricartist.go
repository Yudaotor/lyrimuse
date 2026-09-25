package main

import (
	"context"
	"log"
	"math"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

// 用户信任进来的其他播放器(不是内置播放器)把**当前这一句歌词**写进 artist 或 title 时的纠正。
//
// 跟酷狗 3.3.2 是同一类坏法(见 kugoulyricartist.go):同一首歌里一个字段每唱一句换一次(开播头几秒
// 还会依次报 `作曲: …` 这类 LRC 制作信息行),另一个字段纹丝不动、里面塞着「歌名 - 歌手」。
// 不管的话每一句歌词都是一次"换歌":歌词缓存里留下一条以歌词为身份的条目、重跑一整轮检索,
// 补空扫描之后还会在这些永远搜不到词的条目上反复重搜。
//
// # 范围
//
// 只管**信任进来的其他播放器**(`!isKnownPlayerBundleID && isTrustedPlayerBundleID`,含配对过的
// 浏览器)。内置播放器的行为都实测过,只有酷狗 3.3.2 会这样,它走 kugoulyricartist.go 那套;
// 两套按 bundle 互斥。
//
// # 不预设格式
//
// 哪个字段在换(artist / title)、身份里歌名歌手谁在前、用哪种破折号,都不假定:
//   - 在换的字段靠观测认(trustedRotField),不变的那个才是装着身份、要拆的字段;
//   - 排列(trustedTitleOrder)按播放器认一次:第一拍在换的那个字段恰好就是其中一段(有的播放器
//     第一拍报的还是真署名),或者拿每种读法去 Apple 曲库对一次(trustedOrderLookup)。只凭字段本身
//     认不出排列 —— 同名专辑(专辑名 = 歌手名)跟同名主打曲(专辑名 = 歌名)在字段上完全对称;
//   - 排列定了之后,歌手取靠近自己那一侧的第一段(歌名在前取最后一个分隔符,歌手在前取第一个):
//     歌名常自带破折号(副标题、版本、`主題曲`),歌手名很少有。身份字段里有两个以上分隔符、拆法
//     不唯一时,这条取段规则只是先顶上,同时逐首问曲库(或看第一拍的真署名)定下是哪一处。
//
// 认不出排列就不拆,身份用这首歌第一次见到的两个字段固定住(一首歌只剩一个 key),宁可拆不出
// 也不拆错。
//
// # 判据只认结构,比酷狗那套严
//
// 同一首歌之内(bundle、专辑、时长不变,且两个字段没有同时变),同一个字段在 trustedLyricArtistWindow
// 内**换了两次**才判定成立。多等一次换值挡的是正常形态:换歌那一拍字段不同步(一个字段先换、
// 下一拍另一个也换,那是真换歌);电台 title 写台名、artist 每首一换(几分钟才换一次,进不了窗口);
// 时长为 0 的直接不参与。
//
// 判定期间第一次换值先按住(沿用这首歌第一次见到的身份),不当换歌 —— 否则那一拍又会被当成一首
// 新歌去搜、再留一条错条目。窗口过了还没换第二次,说明是播放器正常改了一次,放行。
//
// # 纠正落定后撤回错身份
//
// 这首歌用过、后来被纠正顶掉的身份(第一拍的原始身份、排列认出来之前的固定身份)在纠正落定时撤回,
// 见 enrichretract.go。

// trustedLyricArtistWindow:两次换值必须落在这个时长之内,判定才成立;也是第一次换值按住的上限。
const trustedLyricArtistWindow = 30 * time.Second

// trustedLyricArtistDurationTolerance:判"还是同一首"时允许的时长抖动。有的播放器每拍报的
// 时长在小数位上漂,逐位比较会让状态机每拍重置、永远判不出来。
const trustedLyricArtistDurationTolerance = 0.5

// trustedAdoptedMax:一首歌里记多少个用过的身份。正常只有一两个,上限只防异常播放器把它撑大。
const trustedAdoptedMax = 8

// trustedRotField:哪个字段在跟着歌词换。
type trustedRotField int

const (
	rotNone   trustedRotField = iota
	rotArtist                 // artist 在换,title 装着身份
	rotTitle                  // title 在换,artist 装着身份
)

// trustedTitleOrder:身份字段里歌名与歌手的排列。
type trustedTitleOrder int

const (
	titleOrderUnknown     trustedTitleOrder = iota
	titleOrderSongFirst                     // 「歌名 - 歌手」
	titleOrderArtistFirst                   // 「歌手 - 歌名」
)

// trustedIdentity 是一个 (artist, title) 身份。
type trustedIdentity struct {
	artist, title string
}

// trustedLyricArtistState 是这套判定的全部状态。纯函数 advanceTrustedLyricArtist 只读写它的值。
type trustedLyricArtistState struct {
	bundle   string
	album    string
	duration float64
	// refArtist / refTitle:这首歌第一次见到的两个字段(空的后补)。
	refArtist, refTitle string
	// lastArtist / lastTitle:上一拍的两个字段,判"这一拍哪个换了"。
	lastArtist, lastTitle string
	rot                   trustedRotField
	// changes / changedAt:rot 那个字段在当前窗口里换了几次、窗口从哪一刻起算。
	changes   int
	changedAt time.Time
	poisoned  bool
	// startedAt:这首歌第一次被看到的时刻。撤回只收这之后写下的条目。
	startedAt time.Time
	// adopted:这首歌交给过下游的身份;retracted:其中已经撤回过的。由 trustedFixedTrack 维护,
	// 改之前先复制(状态按值传递,别让两份状态共用底层数组 / map)。
	adopted   []trustedIdentity
	retracted map[trustedIdentity]bool
	// fix:判定成立后这一拍给出的纠正,trustedKnownFix 读。
	fix trustedIdentity
}

// advanceTrustedLyricArtist 推进一拍并返回新状态。纯函数。
//
//   - 不在范围内 / 两个字段都空 / 没有时长 → 空状态(不参与);
//   - 换曲目(bundle、时长变了,专辑从一个值变成另一个值,或两个字段同时跟第一次见到的不一样了)
//     到 重新起判,confirmed 非空时直接按已判定起步;
//   - 同一曲目内只有一个字段换了 → 记一次换值;同一个字段窗口里第二次换 → 判定成立,之后本曲一直成立。
func advanceTrustedLyricArtist(prev trustedLyricArtistState, bundle, title, artist, album string, duration float64, eligible bool, confirmed trustedRotField, now time.Time) trustedLyricArtistState {
	if !eligible || duration <= 0 || (title == "" && artist == "") {
		return trustedLyricArtistState{}
	}
	newTrack := prev.bundle != bundle ||
		math.Abs(prev.duration-duration) > trustedLyricArtistDurationTolerance ||
		(prev.album != "" && album != "" && prev.album != album)
	if !newTrack {
		artistMoved := artist != "" && prev.refArtist != "" && artist != prev.refArtist
		titleMoved := title != "" && prev.refTitle != "" && title != prev.refTitle
		newTrack = artistMoved && titleMoved
	}
	if newTrack {
		return trustedLyricArtistState{
			bundle: bundle, album: album, duration: duration,
			refArtist: artist, refTitle: title, lastArtist: artist, lastTitle: title,
			rot: confirmed, poisoned: confirmed != rotNone, startedAt: now,
		}
	}
	next := prev
	if next.album == "" {
		next.album = album
	}
	// 先报一个字段、后补另一个是补全,不是换值。
	if next.refArtist == "" && artist != "" {
		next.refArtist, next.lastArtist = artist, artist
	}
	if next.refTitle == "" && title != "" {
		next.refTitle, next.lastTitle = title, title
	}
	artistChanged := artist != "" && artist != next.lastArtist
	titleChanged := title != "" && title != next.lastTitle
	if artistChanged {
		next.lastArtist = artist
	}
	if titleChanged {
		next.lastTitle = title
	}
	if next.poisoned || artistChanged == titleChanged {
		return next
	}
	f := rotArtist
	if titleChanged {
		f = rotTitle
	}
	if next.rot != f {
		next.rot, next.changes = f, 0
	}
	if next.changes == 0 || now.Sub(next.changedAt) > trustedLyricArtistWindow {
		next.changes, next.changedAt = 1, now
	} else {
		next.changes++
	}
	if next.changes >= 2 {
		next.poisoned = true
	}
	return next
}

// holding:判定期间第一次换值、还在窗口内 —— 先按住,沿用第一次见到的身份。
func (st trustedLyricArtistState) holding(now time.Time) bool {
	return !st.poisoned && st.changes == 1 && now.Sub(st.changedAt) <= trustedLyricArtistWindow
}

// stableAndRef:装着身份的那个字段(不变的)的值,和在换的那个字段第一次见到的值。
func (st trustedLyricArtistState) stableAndRef() (stable, rotRef string) {
	if st.rot == rotTitle {
		return st.refArtist, st.refTitle
	}
	return st.refTitle, st.refArtist
}

var (
	trustedLyricArtistMu    sync.Mutex
	trustedLyricArtistValue trustedLyricArtistState
	// trustedLyricArtistConfirmed:这次运行里判定过的播放器,记的是哪个字段在换。污染是播放器的属性,
	// 判定过一次,之后每首歌第一拍就按已判定处理,不必再等它唱到第三句。
	trustedLyricArtistConfirmed = map[string]trustedRotField{}
	// trustedTitleOrders:认出来的身份字段排列,按播放器记(跟播放器级结论一起持久化)。
	trustedTitleOrders = map[string]trustedTitleOrder{}
	// trustedCatalogInflight / trustedCatalogTried:曲库核对在飞的、核对过的 (播放器, 身份字段) 组合。
	// 一首歌只问一次:没问成(退避 / 限流 / 超时)也等下一首,网络不好时别每拍发一次。
	trustedCatalogInflight = map[string]bool{}
	trustedCatalogTried    = map[string]bool{}
	// trustedSplitResolved:曲库定下来的拆法,按 (播放器, 身份字段) 记。只在拆法不唯一时用得上。
	trustedSplitResolved = map[string]trustedIdentity{}
	// trustedBackground:trustedFixedTrack 起的后台 goroutine(曲库核对、撤回)。单测等它们跑完
	// 再还原包级状态。
	trustedBackground sync.WaitGroup
)

// trustedCatalogLookup 拿身份字段去 Apple 曲库搜一次,返回对得上的读法;reached=false 表示没问成
// (退避 / 限流 / 超时)。单测替换它。
var trustedCatalogLookup = trustedCatalogMatches

// trustedTitleSeps:认的分隔符,两边都要有空格。不带空格的 `-` 不认,它常出现在名字里
// (`Jay-Z`、`Talking-The Power Of Soul`)。
var trustedTitleSeps = []string{" - ", " – ", " — ", " － "}

// trustedSplitCandidate:身份字段在某个分隔符处按某种排列拆出来的一种读法。
type trustedSplitCandidate struct {
	song, artist string
	order        trustedTitleOrder
}

// trustedSplitCandidates 列出每一个分隔符位置 × 两种排列的全部读法,按位置从左到右。
// 两段任一为空的位置不算。
func trustedSplitCandidates(s string) []trustedSplitCandidate {
	var out []trustedSplitCandidate
	for i := 0; i < len(s); i++ {
		for _, sep := range trustedTitleSeps {
			if !strings.HasPrefix(s[i:], sep) {
				continue
			}
			l, r := strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+len(sep):])
			if normLoose(l) == "" || normLoose(r) == "" {
				continue
			}
			out = append(out,
				trustedSplitCandidate{song: l, artist: r, order: titleOrderSongFirst},
				trustedSplitCandidate{song: r, artist: l, order: titleOrderArtistFirst})
		}
	}
	return out
}

// splitTrustedByOrder 按已知排列拆:歌名在前取最后一个分隔符,歌手在前取第一个(歌手名很少自带破折号)。
func splitTrustedByOrder(s string, order trustedTitleOrder) (song, artist string, ok bool) {
	for _, c := range trustedSplitCandidates(s) {
		if c.order != order {
			continue
		}
		song, artist, ok = c.song, c.artist, true
		if order == titleOrderArtistFirst {
			break
		}
	}
	return song, artist, ok
}

// trustedOrderOf:这些读法的排列一致就是它;一种都没有、或两种排列都有,算认不出。
func trustedOrderOf(cands []trustedSplitCandidate) (trustedTitleOrder, bool) {
	found := titleOrderUnknown
	for _, c := range cands {
		if found != titleOrderUnknown && found != c.order {
			return titleOrderUnknown, false
		}
		found = c.order
	}
	return found, found != titleOrderUnknown
}

// trustedUniqueWithOrder:这些读法里排列为 order 的恰好一种,就是它。
func trustedUniqueWithOrder(cands []trustedSplitCandidate, order trustedTitleOrder) (trustedSplitCandidate, bool) {
	var picked trustedSplitCandidate
	n := 0
	for _, c := range cands {
		if c.order == order {
			picked = c
			n++
		}
	}
	return picked, n == 1
}

// trustedMatchRotRef:在换的那个字段第一次见到的值恰好是其中的歌手的读法 —— 有的播放器第一拍
// 报的还是真署名,歌词要等第一句唱出来才顶上去。
func trustedMatchRotRef(cands []trustedSplitCandidate, rotRef string) []trustedSplitCandidate {
	if rotRef == "" {
		return nil
	}
	var out []trustedSplitCandidate
	for _, c := range cands {
		if albumHintArtistTier(rotRef, c.artist, nil) == 0 {
			out = append(out, c)
		}
	}
	return out
}

// trustedMatchesFromResults:曲库结果里有曲名与读法的歌名相等、署名与它的歌手对得上(0 档,含繁简、
// 多歌手子集)的那些读法。
func trustedMatchesFromResults(stable string, results []itunesResult) []trustedSplitCandidate {
	var out []trustedSplitCandidate
	for _, c := range trustedSplitCandidates(stable) {
		song := normLoose(normEnrichTitle(c.song))
		for _, r := range results {
			if normLoose(normEnrichTitle(r.TrackName)) == song && albumHintArtistTier(c.artist, r.ArtistName, nil) == 0 {
				out = append(out, c)
				break
			}
		}
	}
	return out
}

// trustedCatalogMatches 把身份字段里的分隔符换成空格去搜一次(按 appleStorefrontsFor 选的商店),
// 再交给 trustedMatchesFromResults。
func trustedCatalogMatches(ctx context.Context, stable string) (matches []trustedSplitCandidate, reached bool) {
	cands := trustedSplitCandidates(stable)
	if len(cands) == 0 {
		return nil, true
	}
	q := stable
	for _, sep := range trustedTitleSeps {
		q = strings.ReplaceAll(q, sep, " ")
	}
	var results []itunesResult
	for _, country := range appleStorefrontsFor(cands[0].artist, cands[0].song) {
		rs, got := itunesSearch(ctx, neturl.QueryEscape(q), country)
		reached = reached || got
		results = append(results, rs...)
	}
	return trustedMatchesFromResults(stable, results), reached
}

// trustedLyricArtistEligible:这个播放器归不归这套判定管。
func trustedLyricArtistEligible(bundle string) bool {
	return bundle != "" && !isKnownPlayerBundleID(bundle) && isTrustedPlayerBundleID(bundle)
}

// trustedFixedTrack 判定这一拍是不是被歌词顶掉了身份,是就给出该用的署名与曲名。ok=false 表示不必改。
// 调用点同 kugouFixedArtist:原始载荷刚解析出来那一层,传进来的是播放器原样报的值。
func trustedFixedTrack(bundle, title, artist, album string, duration float64) (fixedArtist, fixedTitle string, ok bool) {
	eligible := trustedLyricArtistEligible(bundle)
	now := time.Now()
	trustedLyricArtistMu.Lock()
	next := advanceTrustedLyricArtist(trustedLyricArtistValue, bundle, title, artist, album, duration,
		eligible, trustedLyricArtistConfirmed[bundle], now)
	id := trustedIdentity{artist: artist, title: title}
	var lookup string
	switch {
	case next.poisoned:
		trustedLyricArtistConfirmed[bundle] = next.rot
		id, lookup = resolveTrustedIdentityLocked(&next)
	case next.holding(now):
		id = trustedIdentity{artist: next.refArtist, title: next.refTitle}
	}
	valid := id.artist != "" && id.title != ""
	var retract []string
	if next.bundle != "" && valid {
		retract = noteTrustedAdoptedLocked(&next, id, album)
	}
	if next.poisoned && valid {
		next.fix = id
		publishTrustedFixLocked(bundle, next, id)
	}
	trustedLyricArtistValue = next
	trustedLyricArtistMu.Unlock()
	if lookup != "" {
		trustedBackground.Add(1)
		go func() {
			defer trustedBackground.Done()
			runTrustedCatalogLookup(bundle, lookup)
		}()
	}
	if len(retract) > 0 {
		// 另起 goroutine:撤回要取 enrichMu,别跟调用方手里可能持有的锁串起来。
		trustedBackground.Add(1)
		go func(since time.Time) {
			defer trustedBackground.Done()
			retractEnrichKeys(retract, since)
		}(next.startedAt)
	}
	if !valid || (id.artist == artist && id.title == title) {
		return "", "", false
	}
	return id.artist, id.title, true
}

// resolveTrustedIdentityLocked 给判定成立的这一拍算出身份,返回要交给 runTrustedCatalogLookup 的
// 身份字段(空 = 不用问曲库)。
//
//   - 排列未知:先看第一拍的真署名;还不知道就用第一次见到的两个字段固定住,去曲库问;
//   - 排列已知、只有一种拆法:直接拆;
//   - 排列已知、拆法不唯一:曲库定过就用它,第一拍的真署名能定就用它,都没有就按取段规则先拆、
//     同时去曲库问这一首。问回来跟先拆的不一样,下一拍换过去,先拆的那个身份按撤回收掉。
func resolveTrustedIdentityLocked(st *trustedLyricArtistState) (id trustedIdentity, lookup string) {
	stable, rotRef := st.stableAndRef()
	fallback := trustedIdentity{artist: st.refArtist, title: st.refTitle}
	cands := trustedSplitCandidates(stable)
	if len(cands) == 0 {
		return fallback, ""
	}
	key := st.bundle + "\n" + stable
	byRotRef := trustedMatchRotRef(cands, rotRef)
	order := trustedTitleOrders[st.bundle]
	if order == titleOrderUnknown {
		if o, found := trustedOrderOf(byRotRef); found {
			order = o
			trustedTitleOrders[st.bundle] = o
		}
	}
	if order == titleOrderUnknown {
		return fallback, trustedCatalogKickLocked(key, stable)
	}
	song, artist, _ := splitTrustedByOrder(stable, order)
	positions := 0
	for _, c := range cands {
		if c.order == order {
			positions++
		}
	}
	if positions == 1 {
		return trustedIdentity{artist: artist, title: song}, ""
	}
	if resolved, ok := trustedSplitResolved[key]; ok {
		return resolved, ""
	}
	if c, ok := trustedUniqueWithOrder(byRotRef, order); ok {
		return trustedIdentity{artist: c.artist, title: c.song}, ""
	}
	return trustedIdentity{artist: artist, title: song}, trustedCatalogKickLocked(key, stable)
}

// trustedCatalogKickLocked:这首还没问过曲库、也没在问,就登记成在飞并返回要问的身份字段。
func trustedCatalogKickLocked(key, stable string) string {
	if trustedCatalogInflight[key] || trustedCatalogTried[key] {
		return ""
	}
	trustedCatalogInflight[key] = true
	return stable
}

// runTrustedCatalogLookup 在后台问曲库:排列还不知道就从结果里认(记在播放器上),这一首的拆法能唯一
// 定下来就记下。下一拍 trustedFixedTrack 按它们拆。
func runTrustedCatalogLookup(bundle, stable string) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	matches, reached := trustedCatalogLookup(ctx, stable)
	trustedLyricArtistMu.Lock()
	defer trustedLyricArtistMu.Unlock()
	key := bundle + "\n" + stable
	delete(trustedCatalogInflight, key)
	trustedCatalogTried[key] = true
	order := trustedTitleOrders[bundle]
	if order == titleOrderUnknown {
		if o, found := trustedOrderOf(matches); found {
			order = o
			trustedTitleOrders[bundle] = o
		}
	}
	c, split := trustedUniqueWithOrder(matches, order)
	if split {
		trustedSplitResolved[key] = trustedIdentity{artist: c.artist, title: c.song}
	}
	log.Printf("trusted lyric player: catalog check %q (bundle=%s) reached=%v matches=%d order=%s split=%v",
		stable, bundle, reached, len(matches), trustedOrderName(order), split)
}

// noteTrustedAdoptedLocked 记下这一拍交给下游的身份;判定成立后,之前用过、跟这一拍不同的身份
// 返回成要撤回的缓存 key(每个只撤一次)。
func noteTrustedAdoptedLocked(st *trustedLyricArtistState, id trustedIdentity, album string) []string {
	seen := false
	for _, a := range st.adopted {
		if a == id {
			seen = true
			break
		}
	}
	if !seen && len(st.adopted) < trustedAdoptedMax {
		st.adopted = append(append([]trustedIdentity(nil), st.adopted...), id)
	}
	if !st.poisoned {
		return nil
	}
	var keys []string
	for _, a := range st.adopted {
		if a == id || st.retracted[a] {
			continue
		}
		cp := make(map[trustedIdentity]bool, len(st.retracted)+1)
		for k, v := range st.retracted {
			cp[k] = v
		}
		cp[a] = true
		st.retracted = cp
		keys = append(keys, enrichKey(a.artist, a.title, album))
	}
	return keys
}

// publishTrustedFixLocked 把这一拍的纠正发给 App(见 playerartistfix.go)。适用范围按**不变的那个
// 字段**给:artist 在换时是原样的 title,title 在换时是原样的 artist(title 每句都变,拿它当范围
// App 只对得上一拍)。播放器级结论(哪个字段在换、认出来的排列)跟着一起落盘,重启后恢复。
func publishTrustedFixLocked(bundle string, st trustedLyricArtistState, id trustedIdentity) {
	fix := playerArtistFixState{
		Bundle: bundle, Artist: id.artist, Unreliable: true,
		Order: trustedOrderName(trustedTitleOrders[bundle]),
	}
	if st.rot == rotTitle {
		fix.StableField, fix.RawArtist, fix.FixedTitle = "artist", st.refArtist, id.title
	} else {
		fix.Title = st.refTitle
		if id.title != st.refTitle {
			fix.FixedTitle = id.title
		}
	}
	publishPlayerTrackFix(fix)
}

// trustedKnownFix 只查已经判定下来的结论,自己不判定。给另外再问一次 media-control 的调用点(封面)
// 对齐署名与曲名用,理由同 kugouKnownArtistFix。传播放器原样报的两个字段。
func trustedKnownFix(bundle, rawArtist, rawTitle string) (fixedArtist, fixedTitle string, ok bool) {
	trustedLyricArtistMu.Lock()
	defer trustedLyricArtistMu.Unlock()
	st := trustedLyricArtistValue
	if !st.poisoned || st.bundle != bundle || st.fix.artist == "" {
		return "", "", false
	}
	if st.rot == rotTitle && st.refArtist != rawArtist {
		return "", "", false
	}
	if st.rot != rotTitle && st.refTitle != rawTitle {
		return "", "", false
	}
	return st.fix.artist, st.fix.title, true
}

// restoreTrustedLyricArtistConfirmed 把上一个进程留在 lyrimuse-player-artist-fix.json 里的播放器级
// 结论恢复进这次运行,见 setPlayerArtistFixPath。之后信任被撤销的话,trustedLyricArtistEligible 会把它
// 挡在判定之外,这里不必再查。
func restoreTrustedLyricArtistConfirmed(bundle, stableField, order string) {
	rot := rotArtist
	if stableField == "artist" {
		rot = rotTitle
	}
	trustedLyricArtistMu.Lock()
	trustedLyricArtistConfirmed[bundle] = rot
	if o := trustedOrderFromName(order); o != titleOrderUnknown {
		trustedTitleOrders[bundle] = o
	}
	trustedLyricArtistMu.Unlock()
}

func trustedOrderName(o trustedTitleOrder) string {
	switch o {
	case titleOrderSongFirst:
		return "songFirst"
	case titleOrderArtistFirst:
		return "artistFirst"
	}
	return ""
}

func trustedOrderFromName(s string) trustedTitleOrder {
	switch s {
	case "songFirst":
		return titleOrderSongFirst
	case "artistFirst":
		return titleOrderArtistFirst
	}
	return titleOrderUnknown
}
