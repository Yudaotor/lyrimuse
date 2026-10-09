package main

import (
	"crypto/rand"
	"encoding/hex"
	"sort"
)

// 歌曲实体:同一份录音在各播放器、各发行版上的写法(enrich 缓存的一条条)收拢成的一首。写法照旧是缓存里的条目、
// 原样保留,实体是叠在上面的一层,全部由证据推出来,丢了能从写法表重建。
//
// 认同一首只信结构化证据和时长:先加强证据边(ISRC、播放器给的 id),再加中证据边(检索配的 id、写法族 + 时长、
// 时长 + 歌词),同一强度内按登记顺序、两端写法键排;每加一条边先看两边的簇之间有没有否决,有就不并、记一条
// 被否决的证据。加边顺序固定是因为带否决的贪心合并跟顺序有关:A–B 中证据、B–C 强证据、A–C 有否决时,
// 先加 B–C 得到 {B,C}{A},先加 A–B 就成了 {A,B}{C}。全量建表与增量重算受影响的连通块,结果逐个实体相同。
//
// 实体内部再分共享组:强证据、写法族里歌手歌名逐字相同(跨专辑复用同一口径)、时长 + 歌词,以及有独立旁证的
// 检索 id,把写法连成一组;以后自动选出的歌词只在共享组里同步。规格见 18 章,现在这一阶段的取舍见 18 章决策 1。

const (
	// songEntityDurationGateSecs:两边都有时长时差不超过它才连;实体内全部已知时长的跨度也不超过它。同一份录音被读数
	// 抖动、取整拆开的最多差 1.85 秒,碰巧共用一份歌词的不同版本最少差 2.1 秒(见 crossAlbumReuseToleranceSecs)。
	songEntityDurationGateSecs = crossAlbumReuseToleranceSecs
	// songEntityVersionExceptionSecs:两边播放器给的 ISRC 相同、时长差不超过它时,版本词不对称不算否决。
	songEntityVersionExceptionSecs = 1.5
)

const (
	songEvidenceFamily = "family"
	songEvidenceLyrics = "lyrics"
)

// songEvidenceKind:一种证据的登记:强度、在加边顺序里的位置、是不是检索配的 id(要过检索 id 的闸)。
// 加一种证据只加一条登记,合并算法不动。
type songEvidenceKind struct {
	strong   bool
	order    int
	searched bool
}

var songEvidenceKinds = map[string]songEvidenceKind{
	songIDISRC:         {strong: true, order: 10},
	songIDSpotifyTrack: {strong: true, order: 20},
	songIDAmazonASIN:   {strong: true, order: 21},
	songIDKKBOXSong:    {strong: true, order: 22},
	songIDSodaTrack:    {strong: true, order: 23},
	songIDYouTubeVideo: {strong: true, order: 24},
	songIDAppleSong:    {order: 30, searched: true},
	songIDNeteaseSong:  {order: 31, searched: true},
	songIDQQSong:       {order: 32, searched: true},
	songEvidenceFamily: {order: 40},
	songEvidenceLyrics: {order: 50},
}

// songEdge:一条证据边,a < b 是写法下标(写法按键排序)。
type songEdge struct {
	kind  string
	a, b  int
	value string
	// countOnly:只当计数用、不连共享组(跨文字或登记歌名对不上号的检索 id)。
	countOnly bool
	// share:单独就能把两条写法连进共享组。
	share bool
}

func (e songEdge) strong() bool { return songEvidenceKinds[e.kind].strong }

// songVeto:一次被否决的合并:哪条边、因为哪一对写法、哪种否决。
type songVeto struct {
	reason string
	edge   songEdge
	x, y   int
}

// songEntityBuild:一次建表的结果。
type songEntityBuild struct {
	variants []songVariant
	edges    []songEdge // 过了闸的全部证据边,按加边顺序
	merged   []int      // 促成合并的边(edges 下标)
	vetoed   []songVeto
	// gateDrops:被闸挡下的边,键是「证据种类/闸」。
	gateDrops map[string]int
	clusters  [][]int // 每个实体的写法下标,按键排序;实体按第一条写法的键排序
	entityOf  []int   // 写法 → clusters 下标
	shareOf   []int   // 写法 → 所在共享组的代表写法下标
	edgeVeto  []bool  // edges 下标 → 这条边被否决过
	splits    map[string]bool
	vetoMemo  map[songVetoKey]string
	// decisionsDir:解析决策旁路文件的目录,登记歌名与当前歌词的候选歌名按需从这里读;空串时都当不知道。
	decisionsDir string
}

type songVetoKey struct {
	x, y   int
	strong bool
}

// songPairKey:一对写法键,两个键谁在前都一样。
func songPairKey(a, b string) string {
	if b < a {
		a, b = b, a
	}
	return a + "\x1f" + b
}

// buildSongEntities 按证据把写法收成实体。variants 必须按键排序;userSplits 是用户拆开过的写法对(songPairKey);
// decisionsDir 是解析决策旁路文件的目录。
func buildSongEntities(variants []songVariant, userSplits map[string]bool, decisionsDir string) *songEntityBuild {
	b := &songEntityBuild{variants: variants, splits: userSplits, vetoMemo: map[songVetoKey]string{}, decisionsDir: decisionsDir}
	b.edges, b.gateDrops = songEvidenceEdges(b.variants, decisionsDir)
	sort.SliceStable(b.edges, func(i, j int) bool {
		x, y := b.edges[i], b.edges[j]
		if x.strong() != y.strong() {
			return x.strong()
		}
		if ox, oy := songEvidenceKinds[x.kind].order, songEvidenceKinds[y.kind].order; ox != oy {
			return ox < oy
		}
		if x.a != y.a {
			return x.a < y.a
		}
		if x.b != y.b {
			return x.b < y.b
		}
		return x.value < y.value
	})
	b.edgeVeto = make([]bool, len(b.edges))

	u := newSongUnion(b.variants)
	for i, e := range b.edges {
		ra, rb := u.find(e.a), u.find(e.b)
		if ra == rb {
			continue
		}
		if reason, x, y := b.vetoBetween(u, ra, rb, e); reason != "" {
			b.vetoed = append(b.vetoed, songVeto{reason: reason, edge: e, x: x, y: y})
			b.edgeVeto[i] = true
			continue
		}
		u.union(ra, rb)
		b.merged = append(b.merged, i)
	}

	byRoot := map[int][]int{}
	for i := range b.variants {
		r := u.find(i)
		byRoot[r] = append(byRoot[r], i)
	}
	for _, members := range byRoot {
		sort.Ints(members)
		b.clusters = append(b.clusters, members)
	}
	sort.Slice(b.clusters, func(i, j int) bool { return b.clusters[i][0] < b.clusters[j][0] })
	b.entityOf = make([]int, len(b.variants))
	for ci, members := range b.clusters {
		for _, m := range members {
			b.entityOf[m] = ci
		}
	}
	b.buildShareGroups()
	return b
}

// vetoBetween:两个簇能不能并。不能时返回否决种类和触发它的那一对写法。
func (b *songEntityBuild) vetoBetween(u *songUnion, ra, rb int, e songEdge) (string, int, int) {
	if lo, hi := u.span(ra, rb); lo >= 0 && hi >= 0 && u.dur[hi]-u.dur[lo] > songEntityDurationGateSecs {
		return "duration", lo, hi
	}
	for _, x := range u.members[ra] {
		for _, y := range u.members[rb] {
			if reason := b.pairVeto(x, y, e.strong()); reason != "" {
				return reason, x, y
			}
		}
	}
	return "", -1, -1
}

// pairVeto:x、y 两条写法之间有没有否决。strong:连着两边的这条证据是强证据(歌词那两条否决只对中证据生效)。
func (b *songEntityBuild) pairVeto(x, y int, strong bool) string {
	if x > y {
		x, y = y, x
	}
	k := songVetoKey{x, y, strong}
	if r, ok := b.vetoMemo[k]; ok {
		return r
	}
	r := songPairVeto(&b.variants[x], &b.variants[y], strong, b.splits)
	b.vetoMemo[k] = r
	return r
}

// songUnion:带成员表和时长两端的并查集。lo / hi 是簇里已知时长最短、最长的那条写法,没有已知时长时为 -1。
type songUnion struct {
	parent  []int
	members [][]int
	dur     []float64
	lo, hi  []int
}

func newSongUnion(vs []songVariant) *songUnion {
	n := len(vs)
	u := &songUnion{parent: make([]int, n), members: make([][]int, n), dur: make([]float64, n), lo: make([]int, n), hi: make([]int, n)}
	for i := range vs {
		u.parent[i] = i
		u.members[i] = []int{i}
		u.dur[i] = vs[i].durationSecs
		u.lo[i], u.hi[i] = -1, -1
		if u.dur[i] > 0 {
			u.lo[i], u.hi[i] = i, i
		}
	}
	return u
}

func (u *songUnion) find(x int) int {
	for u.parent[x] != x {
		u.parent[x] = u.parent[u.parent[x]]
		x = u.parent[x]
	}
	return x
}

// span:ra、rb 两个簇并起来之后的时长两端(两个都必须是根)。
func (u *songUnion) span(ra, rb int) (lo, hi int) {
	lo, hi = u.lo[ra], u.hi[ra]
	for _, c := range [2]int{u.lo[rb], u.hi[rb]} {
		if c < 0 {
			continue
		}
		if lo < 0 || u.dur[c] < u.dur[lo] {
			lo = c
		}
		if hi < 0 || u.dur[c] > u.dur[hi] {
			hi = c
		}
	}
	return lo, hi
}

// union 把两个簇并成一个(两个都必须是根)。
func (u *songUnion) union(ra, rb int) {
	lo, hi := u.span(ra, rb)
	if len(u.members[ra]) < len(u.members[rb]) {
		ra, rb = rb, ra
	}
	u.parent[rb] = ra
	u.members[ra] = append(u.members[ra], u.members[rb]...)
	u.members[rb] = nil
	u.lo[ra], u.hi[ra] = lo, hi
}

// buildShareGroups:实体内按能单独连共享组的证据边再并一次。被否决过的边不算。
func (b *songEntityBuild) buildShareGroups() {
	kinds := map[[2]int]map[string]bool{} // 一对写法之间有哪几种全量(不只计数)的中证据
	for i, e := range b.edges {
		if b.edgeVeto[i] || e.countOnly || e.strong() {
			continue
		}
		k := [2]int{e.a, e.b}
		if kinds[k] == nil {
			kinds[k] = map[string]bool{}
		}
		kinds[k][e.kind] = true
	}
	parent := make([]int, len(b.variants))
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(x int) int {
		for parent[x] != x {
			parent[x] = parent[parent[x]]
			x = parent[x]
		}
		return x
	}
	for i, e := range b.edges {
		if b.edgeVeto[i] || b.entityOf[e.a] != b.entityOf[e.b] || !b.shareEligible(e, kinds) {
			continue
		}
		ra, rb := find(e.a), find(e.b)
		if ra != rb {
			if rb < ra {
				ra, rb = rb, ra
			}
			parent[rb] = ra
		}
	}
	b.shareOf = make([]int, len(b.variants))
	for i := range b.variants {
		b.shareOf[i] = find(i)
	}
}

// shareEligible:这条边能不能单独把两条写法连进共享组。强证据、写法族里歌手歌名逐字相同的、时长 + 歌词的可以;
// 检索配的 id 要有一路独立旁证:同一对写法之间另有一种全量的中证据,或者两边歌词各自独立得来又对得上。
func (b *songEntityBuild) shareEligible(e songEdge, kinds map[[2]int]map[string]bool) bool {
	switch {
	case e.countOnly:
		return false
	case e.strong(), e.share:
		return true
	case !songEvidenceKinds[e.kind].searched:
		return false
	}
	if len(kinds[[2]int{e.a, e.b}]) >= 2 {
		return true
	}
	return songIndependentLyricsMatch(&b.variants[e.a], &b.variants[e.b], b.decisionsDir)
}

// songEntityIDs 给这次建出来的实体分 id:跟旧表共有写法最多的旧 id 延续下来(同样多取建立更早的),一个旧 id 只给一个
// 实体;没分到的旧 id 记成重定向,指向拿走它写法最多的那个实体;其余新开。seeds 是写法键 → 旧 id,created 是旧 id → 建立时刻。
func songEntityIDs(clusters [][]string, seeds map[string]string, created map[string]int64, newID func() string) ([]string, map[string]string) {
	type claim struct {
		cluster, shared int
		id              string
	}
	var claims []claim
	for ci, keys := range clusters {
		count := map[string]int{}
		for _, k := range keys {
			if id := seeds[k]; id != "" {
				count[id]++
			}
		}
		for id, n := range count {
			claims = append(claims, claim{cluster: ci, shared: n, id: id})
		}
	}
	sort.Slice(claims, func(i, j int) bool {
		x, y := claims[i], claims[j]
		if x.shared != y.shared {
			return x.shared > y.shared
		}
		if created[x.id] != created[y.id] {
			return created[x.id] < created[y.id]
		}
		if x.id != y.id {
			return x.id < y.id
		}
		return x.cluster < y.cluster
	})
	ids := make([]string, len(clusters))
	taken := map[string]bool{}
	best := map[string]claim{} // 旧 id → 拿走它写法最多的那个实体
	for _, c := range claims {
		if old, ok := best[c.id]; !ok || c.shared > old.shared {
			best[c.id] = c
		}
		if ids[c.cluster] != "" || taken[c.id] {
			continue
		}
		ids[c.cluster], taken[c.id] = c.id, true
	}
	for ci := range ids {
		if ids[ci] == "" {
			ids[ci] = newID()
		}
	}
	redirects := map[string]string{}
	for id, c := range best {
		if !taken[id] {
			redirects[id] = ids[c.cluster]
		}
	}
	return ids, redirects
}

// newSongEntityID:`s_` + 12 位十六进制,随机生成。crypto/rand.Read 总是填满、不返回错误。
func newSongEntityID() string {
	var buf [6]byte
	_, _ = rand.Read(buf[:])
	return "s_" + hex.EncodeToString(buf[:])
}
