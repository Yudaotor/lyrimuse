package main

import (
	"math"
	"sort"
)

// 歌曲实体的证据边与否决。登记表在 songentity.go 的 songEvidenceKinds。

// songEdgeBuilder:生成证据边时的状态。seen 去掉同一对写法、同一种证据的重复边(两条写法共用两个 ISRC 只算一条)。
type songEdgeBuilder struct {
	vs    []songVariant
	edges []songEdge
	seen  map[songEdgeKey]bool
	drops map[string]int
	dir   string // 解析决策旁路文件的目录
}

type songEdgeKey struct {
	kind string
	a, b int
}

// songEvidenceEdges:全部写法之间过了闸的证据边,和被闸挡下的边数(键是「证据种类/闸」)。dir 是解析决策旁路文件的目录。
func songEvidenceEdges(vs []songVariant, dir string) ([]songEdge, map[string]int) {
	b := &songEdgeBuilder{vs: vs, seen: map[songEdgeKey]bool{}, drops: map[string]int{}, dir: dir}
	b.idEdges()
	b.familyEdges()
	b.lyricsEdges()
	return b.edges, b.drops
}

func (b *songEdgeBuilder) add(e songEdge) {
	if e.a > e.b {
		e.a, e.b = e.b, e.a
	}
	k := songEdgeKey{e.kind, e.a, e.b}
	if b.seen[k] {
		return
	}
	b.seen[k] = true
	b.edges = append(b.edges, e)
}

func (b *songEdgeBuilder) drop(kind, gate string, n int) {
	if n > 0 {
		b.drops[kind+"/"+gate] += n
	}
}

// songDurationsWithinGate:两边都有时长时差不超过 songEntityDurationGateSecs;known 为 false 表示有一边没有时长。
func songDurationsWithinGate(x, y *songVariant) (ok, known bool) {
	if x.durationSecs <= 0 || y.durationSecs <= 0 {
		return true, false
	}
	return math.Abs(x.durationSecs-y.durationSecs) <= songEntityDurationGateSecs, true
}

// idEdges:同一个 id 的写法两两连边。ISRC、播放器给的 id 是强证据,只过时长闸(缺时长不限);检索配的 id 过 searchedIDEdges。
func (b *songEdgeBuilder) idEdges() {
	groups := map[string][]int{} // 「命名空间 \x1f id」→ 写法
	level := map[string]map[int]songIDLevel{}
	var keys []string
	for i := range b.vs {
		for _, g := range b.vs[i].ids {
			k := g.ns + "\x1f" + g.id
			if groups[k] == nil {
				keys = append(keys, k)
				level[k] = map[int]songIDLevel{}
			}
			if _, dup := level[k][i]; !dup {
				groups[k] = append(groups[k], i)
			}
			if g.level > level[k][i] {
				level[k][i] = g.level
			}
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		members := groups[k]
		if len(members) < 2 {
			continue
		}
		ns, id := splitSongIDKey(k)
		kind := songEvidenceKinds[ns]
		if kind.searched {
			b.searchedIDEdges(ns, id, members)
			continue
		}
		for i := 0; i < len(members); i++ {
			for j := i + 1; j < len(members); j++ {
				x, y := members[i], members[j]
				if ns == songIDISRC && (level[k][x] < songIDVerified || level[k][y] < songIDVerified) {
					b.drop(ns, "unverified", 1)
					continue
				}
				if ok, _ := songDurationsWithinGate(&b.vs[x], &b.vs[y]); !ok {
					b.drop(ns, "duration", 1)
					continue
				}
				b.add(songEdge{kind: ns, a: x, b: y, value: id})
			}
		}
	}
}

func splitSongIDKey(k string) (ns, id string) {
	for i := 0; i < len(k); i++ {
		if k[i] == '\x1f' {
			return k[:i], k[i+1:]
		}
	}
	return k, ""
}

// searchedIDEdges:检索配的 id(Apple 歌曲 id、网易云 id、QQ songmid)先过五道闸才算边。检索会把一首歌配到同一位歌手的
// 另一首、甚至别人的歌上:
//  1. 主歌手相同(songArtistMatch);
//  2. 一个 id 一种歌名:同一位歌手名下这个 id 在同一种文字里折出两种以上写法族歌名,整组不用;
//  3. 时长:两边都有时长时差不超过 songEntityDurationGateSecs,有一边没有时长时要写法族歌名相同;
//  4. 尾巴:有一边带版本尾巴时要写法族歌名相同(「Ten Reasons (Live版)」不连「Ten Reasons」);
//  5. 登记歌名:平台给这个 id 登记的歌名跟写法歌名同一种文字时要对得上,对不上不连;文字不同、或登记歌名不知道时
//     只当计数用(countOnly),不连共享组。
func (b *songEdgeBuilder) searchedIDEdges(ns, id string, members []int) {
	comps := b.artistComponents(members)
	for ci, comp := range comps {
		for _, other := range comps[ci+1:] {
			b.drop(ns, "artist", len(comp)*len(other))
		}
		if len(comp) < 2 {
			continue
		}
		han, latin := map[string]bool{}, map[string]bool{}
		for _, m := range comp {
			if b.vs[m].han {
				han[b.vs[m].family] = true
			} else {
				latin[b.vs[m].family] = true
			}
		}
		if len(han) >= 2 || len(latin) >= 2 {
			b.drop(ns, "one_title", len(comp)*(len(comp)-1)/2)
			continue
		}
		registered := ""
		for _, m := range comp {
			b.vs[m].loadDecisionTitles(b.dir)
			if t := b.vs[m].registered[ns+":"+id]; t != "" {
				registered = t
				break
			}
		}
		for i := 0; i < len(comp); i++ {
			for j := i + 1; j < len(comp); j++ {
				x, y := &b.vs[comp[i]], &b.vs[comp[j]]
				ok, known := songDurationsWithinGate(x, y)
				switch {
				case !ok:
					b.drop(ns, "duration", 1)
					continue
				case !known && x.family != y.family:
					b.drop(ns, "no_duration", 1)
					continue
				case (x.tailed || y.tailed) && x.family != y.family:
					b.drop(ns, "tail", 1)
					continue
				}
				countOnly := registered == ""
				mismatch := false
				for _, v := range []*songVariant{x, y} {
					if registered == "" {
						break
					}
					match, cross := songTitlesCompatible(registered, v.title)
					switch {
					case cross:
						countOnly = true
					case !match:
						mismatch = true
					}
				}
				if mismatch {
					b.drop(ns, "registered", 1)
					continue
				}
				b.add(songEdge{kind: ns, a: comp[i], b: comp[j], value: id, countOnly: countOnly})
			}
		}
	}
}

// artistComponents:按主歌手把一组写法分成几个人(两两 songArtistMatch 连起来)。组内、组间都按写法下标排。
func (b *songEdgeBuilder) artistComponents(members []int) [][]int {
	parent := make([]int, len(members))
	for i := range parent {
		parent[i] = i
	}
	find := func(x int) int {
		for parent[x] != x {
			parent[x] = parent[parent[x]]
			x = parent[x]
		}
		return x
	}
	for i := 0; i < len(members); i++ {
		for j := i + 1; j < len(members); j++ {
			if songArtistMatch(b.vs[members[i]].primary, b.vs[members[j]].primary) {
				if ri, rj := find(i), find(j); ri != rj {
					parent[max(ri, rj)] = min(ri, rj)
				}
			}
		}
	}
	byRoot := map[int][]int{}
	var roots []int
	for i, m := range members {
		r := find(i)
		if byRoot[r] == nil {
			roots = append(roots, r)
		}
		byRoot[r] = append(byRoot[r], m)
	}
	sort.Ints(roots)
	out := make([][]int, 0, len(roots))
	for _, r := range roots {
		out = append(out, byRoot[r])
	}
	return out
}

// songArtistMatch:两个主歌手是不是同一个人:引擎现成的歌手比对(artistMatches),双语写法两半各算一种名字
// (artistNameForms),或 MusicBrainz 身份缓存里是同一个 mbid。不用从歌曲推出来的歌手别名:拿它闸歌曲的边就成了循环。
// 没有歌手的写法跟谁都不算同一个人。
func songArtistMatch(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	if artistMatches(a, b) {
		return true
	}
	for _, fa := range artistNameForms(a) {
		for _, fb := range artistNameForms(b) {
			if artistMatches(fa, fb) {
				return true
			}
		}
	}
	ia, okA := cachedArtistIdentity(a)
	ib, okB := cachedArtistIdentity(b)
	return okA && okB && ia.Mbid != "" && ia.Mbid == ib.Mbid
}

// familyEdges:同一位主歌手、写法族歌名相同、两边都有时长且差不超过闸的写法连边。歌手、歌名两段逐字相同(只差专辑)的
// 那种就是跨专辑复用的判据,单独就能连共享组。
func (b *songEdgeBuilder) familyEdges() {
	buckets := map[string][]int{}
	var keys []string
	for i := range b.vs {
		f := b.vs[i].family
		if f == "" || b.vs[i].durationSecs <= 0 {
			continue
		}
		if buckets[f] == nil {
			keys = append(keys, f)
		}
		buckets[f] = append(buckets[f], i)
	}
	sort.Strings(keys)
	for _, f := range keys {
		ms := buckets[f]
		for i := 0; i < len(ms); i++ {
			for j := i + 1; j < len(ms); j++ {
				x, y := &b.vs[ms[i]], &b.vs[ms[j]]
				if !songArtistMatch(x.primary, y.primary) {
					continue
				}
				if ok, _ := songDurationsWithinGate(x, y); !ok {
					b.drop(songEvidenceFamily, "duration", 1)
					continue
				}
				b.add(songEdge{kind: songEvidenceFamily, a: ms[i], b: ms[j], share: x.artist == y.artist && x.title == y.title})
			}
		}
	}
}

// lyricsEdges:时长 + 歌词(E2)。同一位主歌手(artistMatchKey 相同)名下,两种写法满足:都有时长且按精度分档接近
// (songDurationsClose)、各自的歌词可信、主标题之外不带版本尾巴、跨文字或只差一个字(songOneCharVariant)、正文对得上
// (songLyricsMatch),而且两份歌词各自独立得来(songLyricsIndependent)。正文只在前几样都过了的那一对上才剥:
// 全库每条都剥一遍是几秒 CPU,真要比的只有极少数。
func (b *songEdgeBuilder) lyricsEdges() {
	buckets := map[string][]int{}
	var keys []string
	for i := range b.vs {
		v := &b.vs[i]
		if v.durationSecs <= 0 || v.tailed || v.primary == "" || !v.lyricsTrusted || v.instrumental {
			continue
		}
		k := artistMatchKey(v.primary)
		if buckets[k] == nil {
			keys = append(keys, k)
		}
		buckets[k] = append(buckets[k], i)
	}
	sort.Strings(keys)
	for _, k := range keys {
		ms := buckets[k]
		for i := 0; i < len(ms); i++ {
			for j := i + 1; j < len(ms); j++ {
				x, y := &b.vs[ms[i]], &b.vs[ms[j]]
				if x.family == y.family || (x.han == y.han && !songOneCharVariant(x.family, y.family)) {
					continue
				}
				if !songDurationsClose(x.durationSecs, y.durationSecs) {
					continue
				}
				sx, _ := x.lyricsShingles()
				sy, _ := y.lyricsShingles()
				if sx == nil || sy == nil || !songLyricsMatch(sx, sy) {
					continue
				}
				if !songLyricsIndependent(x, y, b.dir) {
					b.drop(songEvidenceLyrics, "not_independent", 1)
					continue
				}
				b.add(songEdge{kind: songEvidenceLyrics, a: ms[i], b: ms[j], share: true})
			}
		}
	}
}

// songLyricsSourceID:歌词源 → 条目上记的那个平台 id 的命名空间(没有对应 id 的源返回空串)。
var songLyricsSourceID = map[string]string{
	"netease": songIDNeteaseSong, "qq": songIDQQSong, "applemusic": songIDAppleSong,
	"amazon": songIDAmazonASIN, "kkbox": songIDKKBOXSong, "soda": songIDSodaTrack,
}

// songLyricsIndependent:两份歌词是不是各自独立得来的。出自同一个检索条目的不算:同一个源、同一个平台 id;源那边
// 没有 id 可比时,同一个源给出一字不差的两份也算同一个条目。任何一份来自登记歌名对不上的候选也不算(那条写法
// 显示的是另一首歌的词,跟另一首对得上说明不了是同一首)。
func songLyricsIndependent(x, y *songVariant, dir string) bool {
	x.loadDecisionTitles(dir)
	y.loadDecisionTitles(dir)
	if songLyricsFromMismatchedCandidate(x) || songLyricsFromMismatchedCandidate(y) {
		return false
	}
	if x.lyricsSource == "" || x.lyricsSource != y.lyricsSource {
		return true
	}
	if ns := songLyricsSourceID[x.lyricsSource]; ns != "" {
		if a, b := x.id(ns), y.id(ns); a != "" && b != "" {
			return a != b
		}
	}
	return x.lyrics != y.lyrics
}

// songLyricsFromMismatchedCandidate:当前这份歌词的候选在源那边的歌名跟写法歌名同一种文字、却对不上。
func songLyricsFromMismatchedCandidate(v *songVariant) bool {
	if v.winnerTitle == "" {
		return false
	}
	ok, cross := songTitlesCompatible(v.winnerTitle, v.title)
	return !ok && !cross
}

// songIndependentLyricsMatch:两条写法的歌词各自独立得来、正文又对得上。给检索 id 当独立旁证用。
func songIndependentLyricsMatch(x, y *songVariant, dir string) bool {
	sx, _ := x.lyricsShingles()
	sy, _ := y.lyricsShingles()
	return sx != nil && sy != nil && songLyricsMatch(sx, sy) && songLyricsIndependent(x, y, dir)
}

// songPairVeto:两条写法之间有没有否决,有就返回否决种类。strong:连着两边的这条证据是强证据。否决优先于证据,
// 往「分开」那边错:
//   - user_split:用户拆开过;
//   - same_album:同一张专辑里平台歌曲 id 不同。只看专辑与曲目 id 同出一处的:Apple 链接(专辑、曲目在同一个地址里)
//     和播放器给的(Spotify、Amazon、KKBOX、汽水)。QQ 的专辑 mid 是拿检索配上的那首另查的,一条配错就带出一对假的
//     「同专辑不同曲」。强证据只认两边都是播放器给的:检索会把一条写法配到同一张专辑的别的曲目上,拿它推翻 ISRC
//     是倒过来了(见 18 章决策 1);
//   - version:版本词不一致(versionTagsMismatch,不忽略语种)。例外:两边播放器给的 ISRC 相同且时长差不超过
//     songEntityVersionExceptionSecs,或 sameRecordingDespiteVersionTags 成立,或只差专辑名带来的版次词且时长几乎相等
//     (songOnlyAlbumEditionDiffers);伴奏、纯音乐这类无人声版本词不吃例外;
//   - explicit:删减版与不删减版都标明;
//   - vocals:一边明确没有人声、一边明确有;
//   - overshoot:没有时长的写法,歌词末句比对方时长晚 lyricOvershootToleranceSecs 以上;
//   - lyrics_words / lyrics_timeline(只对中证据):两份正文用词重合低于 songLyricsDifferentWordsMax;或用词重合
//     不低于 songLyricsSameWordsMin、时间轴按行对上后整体平移或行间离散超过阈值,两边时长几乎相等时这一条不算
//     (songSameLength)。强证据连着时不否决。
func songPairVeto(x, y *songVariant, strong bool, splits map[string]bool) string {
	if splits[songPairKey(x.key, y.key)] {
		return "user_split"
	}
	if ns := songSameAlbumDifferentTrack(x, y, strong); ns != "" {
		return "same_album:" + ns
	}
	if songVersionVeto(x, y) {
		return "version"
	}
	if explicitnessConflict(x.title, x.album, y.title, y.album) {
		return "explicit"
	}
	// 「明确没有人声」只看两个现成字段,先判它;两边都不是时这条否决不可能成立,不用去剥正文判「有」。
	if nx, ny := x.instrumental || x.instrumentalVersion, y.instrumental || y.instrumentalVersion; nx != ny {
		if vx, vy := x.vocalsKind(), y.vocalsKind(); (vx == songVocalsNone && vy == songVocalsPresent) || (vx == songVocalsPresent && vy == songVocalsNone) {
			return "vocals"
		}
	}
	if songLyricsOvershoot(x, y) || songLyricsOvershoot(y, x) {
		return "overshoot"
	}
	if strong {
		return ""
	}
	_, wx := x.lyricsShingles()
	_, wy := y.lyricsShingles()
	if wx == nil || wy == nil {
		return ""
	}
	overlap := songWordOverlap(wx, wy)
	if overlap < songLyricsDifferentWordsMax {
		return "lyrics_words"
	}
	if overlap >= songLyricsSameWordsMin && !songSameLength(x, y) {
		if shift, spread, ok := songTimelineShift(x.displayedLines(), y.displayedLines()); ok &&
			(math.Abs(shift) > songLyricsShiftMaxSecs || spread > songLyricsSpreadMaxSecs) {
			return "lyrics_timeline"
		}
	}
	return ""
}

// songSameAlbumDifferentTrack:两条写法在同一个平台上是同一张专辑、歌曲 id 却不同,返回是哪个平台;没有返回空串。
// playerOnly:只看播放器给的 id。
func songSameAlbumDifferentTrack(x, y *songVariant, playerOnly bool) string {
	for ns, album := range x.albums {
		if ns == songIDQQSong || y.albums[ns] != album {
			continue
		}
		a, la := x.gradedID(ns)
		b, lb := y.gradedID(ns)
		if playerOnly && (la != songIDPlayer || lb != songIDPlayer) {
			continue
		}
		if a != "" && b != "" && a != b {
			return ns
		}
	}
	return ""
}

func songVersionVeto(x, y *songVariant) bool {
	if !versionTagsMismatch(x.title, x.album, y.title, y.album) {
		return false
	}
	if x.instrumentalVersion || y.instrumentalVersion {
		return true
	}
	if songSameLength(x, y) && songOnlyAlbumEditionDiffers(x, y) {
		return false
	}
	if songSharePlayerISRC(x, y) {
		if ok, known := songDurationsWithinGate(x, y); ok && known && math.Abs(x.durationSecs-y.durationSecs) <= songEntityVersionExceptionSecs {
			return false
		}
	}
	return !sameRecordingDespiteVersionTags(x.title, x.album, x.durationSecs, y.title, y.album, y.durationSecs) &&
		!sameRecordingDespiteVersionTags(y.title, y.album, y.durationSecs, x.title, x.album, x.durationSecs)
}

// songSameLength:两边时长都知道且几乎相等(songSameLengthSecs,任一侧是整秒时 songSameLengthIntegralSecs)。
func songSameLength(x, y *songVariant) bool {
	if x.durationSecs <= 0 || y.durationSecs <= 0 {
		return false
	}
	tol := songSameLengthSecs
	if songIntegralSecs(x.durationSecs) || songIntegralSecs(y.durationSecs) {
		tol = songSameLengthIntegralSecs
	}
	return math.Abs(x.durationSecs-y.durationSecs) <= tol
}

// songAlbumEditionTags:专辑名里这几种版本词说的是版次:加长版专辑多收几首,混音 EP 连原版一起收。
var songAlbumEditionTags = map[string]bool{"extended": true, "remix": true}

// songOnlyAlbumEditionDiffers:两边版本词的差别全是专辑名带来的版次词(songAlbumEditionTags),两边歌名里都没有。
// 删减版与不删减版归 explicit 那条否决。
func songOnlyAlbumEditionDiffers(x, y *songVariant) bool {
	inTitles := versionTagsIn(x.title, y.title)
	for _, p := range [2][2]map[string]bool{{x.versionTags, y.versionTags}, {y.versionTags, x.versionTags}} {
		for tag := range p[0] {
			if !p[1][tag] && (!songAlbumEditionTags[tag] || inTitles[tag]) {
				return false
			}
		}
	}
	return true
}

// songSharePlayerISRC:两边有一个相同的、播放器给的 ISRC。
func songSharePlayerISRC(x, y *songVariant) bool {
	for _, g := range x.ids {
		if g.ns != songIDISRC || g.level != songIDPlayer {
			continue
		}
		for _, h := range y.ids {
			if h.ns == songIDISRC && h.level == songIDPlayer && h.id == g.id {
				return true
			}
		}
	}
	return false
}

// songLyricsOvershoot:x 没有时长、y 有,x 的歌词末句比 y 的时长晚 lyricOvershootToleranceSecs 以上。
func songLyricsOvershoot(x, y *songVariant) bool {
	if x.durationSecs > 0 || y.durationSecs <= 0 {
		return false
	}
	last := songLastLineSecs(x.displayedLines())
	return last > 0 && last > y.durationSecs+lyricOvershootToleranceSecs
}
