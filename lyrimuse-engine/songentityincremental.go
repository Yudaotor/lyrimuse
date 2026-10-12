package main

import (
	"encoding/binary"
	"errors"
	"hash/maphash"
	"log/slog"
	"maps"
	"math"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 歌曲实体的增量重算(18 章决策 40):缓存落盘之后,只重算变了的写法所在的那一块,不等每天那一次全量建表。
//
// 判据是建表读的那些字段的指纹(songEntityPrintOf):跟上一次建表或增量时的指纹比,变了的、新出现的、没了的写法是这一轮的
// 改动。受影响的范围按这三样收:
//  1. 改动本身,和它在新数据里能连上证据边的写法(按索引找可能连边的写法,拿它们算一遍证据边);
//  2. 改动新旧两份检索 id 所在的整组写法:检索 id 的闸看整组(一个 id 一种歌名、登记歌名),多一条少一条会让组里别的边出现或消失;
//  3. 以上写法在上一份实体表里所在的连通块:实体,加上被否决的边连着的实体(实体表的 vetoed 记着每一条)。
//
// 带否决的贪心合并只看连通块内部的边和顺序(见 songentity.go 文件头),所以这一块单独建表跟全量建表结果逐个实体相同。检索 id 的
// 闸要看整组,块外同组的写法带进来一起建、建完扔掉(它们跟块里的写法之间不能有证据边,有就退回全量建表)。
//
// 不在指纹里的输入变了(目录名字、MusicBrainz 录音、歌手身份缓存、Spotify 本机的演唱语言、用户拆开的写法对)不会触发增量:
// 名字补扫、拆开 / 恢复合并之后本来就全量重建,其余等每天那一次。全量建表时跟增量维护的那份对一遍,划分不一样的记一行日志。

const (
	// songEntityUpdateMax:一轮改动超过这么多条写法就直接全量建表(配置搬家、整批导入)。
	songEntityUpdateMax = 400
)

// songEntityUpdateDelay:缓存落盘之后等这么久再增量重算,把一首歌开播后陆续到的几样信息并成一次。
var songEntityUpdateDelay = 3 * time.Second

var errSongEntityUpdate = errors.New("song entities: incremental update needs a full rebuild")

// songEntityCacheSaved:缓存落盘之后提醒常驻循环增量重算(saveEnrichCacheChecked 发,startSongEntityShadow 收)。只缓冲一个。
var songEntityCacheSaved = make(chan struct{}, 1)

func noteSongEntityCacheSaved() {
	select {
	case songEntityCacheSaved <- struct{}{}:
	default:
	}
}

// songEntityPrint:一条写法里建表读的那些字段。lyrics、yrc 原样留着比(同一份正文是同一个字符串,比较是常数时间),其余合成一个哈希。
type songEntityPrint struct {
	fields      uint64
	lyrics, yrc string
}

var songEntityPrintSeed = maphash.MakeSeed()

// songEntityPrintOf:songVariantOf、songVariantIDs 读的条目字段全在这里,加了读的字段要一起加(有契约测试)。
func songEntityPrintOf(e enrichEntry, pinned bool) songEntityPrint {
	var h maphash.Hash
	h.SetSeed(songEntityPrintSeed)
	var buf [8]byte
	num := func(f float64) {
		binary.LittleEndian.PutUint64(buf[:], math.Float64bits(f))
		h.Write(buf[:])
	}
	str := func(s string) {
		h.WriteString(s)
		h.WriteByte(0)
	}
	flag := func(b bool) {
		if b {
			h.WriteByte(1)
		} else {
			h.WriteByte(0)
		}
	}
	num(e.DurationSecs)
	num(e.ResolvedDurationSecs)
	flag(e.Instrumental)
	flag(e.ManualLyrics)
	flag(pinned)
	str(e.LyricsSource)
	str(e.LyricsEntityOrigin)
	for _, d := range [2]*lyricsDecision{e.LyricsDecision, e.LyricsDecisionApplied} {
		flag(d != nil)
		if d != nil {
			str(d.Path)
			num(float64(d.DecidedAt))
			str(d.Winner)
			flag(d.Applied)
		}
	}
	for _, c := range e.ISRCs {
		str(c)
	}
	h.WriteByte(0xff)
	for _, c := range songSortedKeys(e.ISRCLevels) {
		str(c)
		str(e.ISRCLevels[c])
	}
	h.WriteByte(0xff)
	for _, s := range [...]string{e.SpotifyTrackID, e.AmazonURL, e.KKBOXURL, e.SodaURL, e.YouTubeMusicURL, e.AppleURL,
		e.NeteaseURL, e.QQURL, e.SpotifyAlbumID, e.QQAlbumMid, e.AmazonAlbumASIN, e.KKBOXAlbumID, e.SodaAlbumID} {
		str(s)
	}
	flag(e.YouTubeMusicMV)
	return songEntityPrint{fields: h.Sum64(), lyrics: e.Lyrics, yrc: e.LyricsYRC}
}

// songEntitySource:建表的输入。prepare 在摘完字段之后挂目录名字这类缓存之外的东西,nil 时不挂。
type songEntitySource struct {
	cache   map[string]enrichEntry
	pins    map[string]bool
	splits  map[string]bool
	dir     string
	prepare func(vs []songVariant)
}

// variants:按 keys(必须排好序)摘写法。
func (s *songEntitySource) variants(keys []string) []songVariant {
	vs := make([]songVariant, len(keys))
	for i, k := range keys {
		e := s.cache[k]
		vs[i] = songVariantOf(k, e, s.pins[k])
		songUseOwnLyrics(&vs[i], e)
	}
	if s.prepare != nil {
		s.prepare(vs)
	}
	return vs
}

// songEntityState:一次建表之后留在内存里的东西,增量重算从它出发。index 是索引项 → 写法键,terms 是写法键 → 它的索引项;
// entityOf、linked 从 table 算(写法键 → 实体 id,实体 id → 被否决的边连着的实体 id)。
type songEntityState struct {
	table    *songEntityTableFile
	prints   map[string]songEntityPrint
	index    map[string][]string
	terms    map[string][]string
	entityOf map[string]string
	linked   map[string][]string
	prepare  func(vs []songVariant)
}

// 索引项:id(含 MusicBrainz 录音)、写法族歌名、挂上的目录名字折成的写法族歌名、主歌手。
const (
	songTermID     = "i\x1f"
	songTermFamily = "f\x1f"
	songTermName   = "n\x1f"
	songTermArtist = "a\x1f"
)

func songIDTerm(ns, id string) string { return songTermID + ns + "\x1f" + id }

// songSortedCopy:xs 排好序的一份拷贝。
func songSortedCopy(xs []string) []string {
	out := slices.Clone(xs)
	sort.Strings(out)
	return out
}

// songSearchedIDTerm:t 是检索配的 id 的索引项。
func songSearchedIDTerm(t string) bool {
	rest, ok := strings.CutPrefix(t, songTermID)
	if !ok {
		return false
	}
	ns, _ := splitSongIDKey(rest)
	return songEvidenceKinds[ns].searched
}

// songEntityTerms:写法 v 记进索引的项。
func songEntityTerms(v *songVariant) []string {
	var out []string
	for _, g := range v.ids {
		out = append(out, songIDTerm(g.ns, g.id))
	}
	if v.family != "" {
		out = append(out, songTermFamily+v.family)
	}
	for _, n := range v.catalogNames {
		if f := songFamilyTitle(n.name); f != "" {
			out = append(out, songTermName+f)
		}
	}
	if v.primary != "" {
		out = append(out, songTermArtist+artistMatchKey(v.primary))
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// songEntityProbes:能跟 v 连证据边的写法在索引里会落在哪几项:同一个 id(idEdges);同一个写法族(familyEdges,也是 v 当名字边
// 那一头 x 时的 y);目录名字折成 v 的写法族的(v 当 x);v 的目录名字折成的写法族(v 当 y);同一个主歌手(lyricsEdges)。
// 加一种证据边要在这里补上它的分桶。
func songEntityProbes(v *songVariant) []string {
	var out []string
	for _, g := range v.ids {
		out = append(out, songIDTerm(g.ns, g.id))
	}
	if v.family != "" {
		out = append(out, songTermFamily+v.family, songTermName+v.family)
	}
	for _, n := range v.catalogNames {
		if f := songFamilyTitle(n.name); f != "" {
			out = append(out, songTermFamily+f)
		}
	}
	if v.primary != "" {
		out = append(out, songTermArtist+artistMatchKey(v.primary))
	}
	return out
}

// newSongEntityState:全量建表之后的状态。vs 是这次建表的写法(已经挂过 prepare 的东西)。
func newSongEntityState(table *songEntityTableFile, vs []songVariant, src *songEntitySource) *songEntityState {
	st := &songEntityState{table: table, prints: make(map[string]songEntityPrint, len(src.cache)),
		index: map[string][]string{}, terms: make(map[string][]string, len(vs)), prepare: src.prepare}
	for k, e := range src.cache {
		st.prints[k] = songEntityPrintOf(e, src.pins[k])
	}
	for i := range vs {
		st.indexVariant(&vs[i])
	}
	st.mapTable()
	return st
}

func (st *songEntityState) indexVariant(v *songVariant) {
	st.unindex(v.key)
	terms := songEntityTerms(v)
	st.terms[v.key] = terms
	for _, t := range terms {
		st.index[t] = append(slices.Clip(st.index[t]), v.key)
	}
}

// unindex 去掉 key 的全部索引项。索引里的切片只换新、不原地改(clone 出来的那份共用它们)。
func (st *songEntityState) unindex(key string) {
	for _, t := range st.terms[key] {
		ks := slices.DeleteFunc(slices.Clone(st.index[t]), func(k string) bool { return k == key })
		if len(ks) == 0 {
			delete(st.index, t)
		} else {
			st.index[t] = ks
		}
	}
	delete(st.terms, key)
}

// mapTable:按 table 算 entityOf、linked。
func (st *songEntityState) mapTable() {
	st.entityOf = map[string]string{}
	for id, rec := range st.table.Songs {
		for _, k := range rec.Variants {
			st.entityOf[k] = id
		}
	}
	st.linked = map[string][]string{}
	for _, v := range st.table.Vetoed {
		a, b := st.entityOf[v.A], st.entityOf[v.B]
		if a == "" || b == "" || a == b {
			continue
		}
		st.linked[a] = append(st.linked[a], b)
		st.linked[b] = append(st.linked[b], a)
	}
}

// clone:一份可以独立增量重算的拷贝(table 只读,不拷)。
func (st *songEntityState) clone() *songEntityState {
	c := *st
	c.prints, c.index, c.terms = maps.Clone(st.prints), maps.Clone(st.index), maps.Clone(st.terms)
	return &c
}

// songEntityUpdate:一轮增量重算的结果。build 只有重算的那一块(partial);table 是整份实体表。
type songEntityUpdate struct {
	build            *songEntityBuild
	table            *songEntityTableFile
	changed, removed int
}

// update 按 src 增量重算;没有改动时返回 nil。返回 errSongEntityUpdate 时要全量建表,st 这时可能只改了一半,不能再用。
func (st *songEntityState) update(src *songEntitySource, now time.Time) (*songEntityUpdate, error) {
	prints := make(map[string]songEntityPrint, len(src.cache))
	var changed, removed []string
	for k, e := range src.cache {
		p := songEntityPrintOf(e, src.pins[k])
		prints[k] = p
		if old, ok := st.prints[k]; !ok || old != p {
			changed = append(changed, k)
		}
	}
	for k := range st.prints {
		if _, ok := src.cache[k]; !ok {
			removed = append(removed, k)
		}
	}
	if len(changed)+len(removed) == 0 {
		return nil, nil
	}
	if len(changed)+len(removed) > songEntityUpdateMax {
		return nil, errSongEntityUpdate
	}
	sort.Strings(changed)
	sort.Strings(removed)
	seed := map[string]bool{}
	for _, k := range removed {
		st.unindex(k)
		seed[k] = true
	}
	cv := src.variants(changed)
	isChanged := make(map[string]bool, len(changed))
	for i := range cv {
		st.indexVariant(&cv[i])
		isChanged[cv[i].key] = true
		seed[cv[i].key] = true
	}

	// 1. 改动在新数据里能连上证据边的写法。
	near := maps.Clone(isChanged)
	for i := range cv {
		for _, t := range songEntityProbes(&cv[i]) {
			for _, k := range st.index[t] {
				near[k] = true
			}
		}
	}
	tv := src.variants(songSortedKeys(near))
	edges, _ := songEvidenceEdges(tv, src.dir)
	for _, e := range edges {
		if a, b := tv[e.a].key, tv[e.b].key; isChanged[a] || isChanged[b] {
			seed[a], seed[b] = true, true
		}
	}
	// 2. 改动新旧两份检索 id 所在的整组。旧的那份从上一份实体表里它所在实体记的 id 取(实体的 id 是成员的并集,多带几组无妨)。
	for i := range cv {
		for _, g := range cv[i].ids {
			if songEvidenceKinds[g.ns].searched {
				for _, k := range st.index[songIDTerm(g.ns, g.id)] {
					seed[k] = true
				}
			}
		}
	}
	for _, k := range append(slices.Clone(changed), removed...) {
		rec, ok := st.table.Songs[st.entityOf[k]]
		if !ok {
			continue
		}
		for ns, ids := range rec.IDs {
			if !songEvidenceKinds[ns].searched {
				continue
			}
			for _, r := range ids {
				for _, k2 := range st.index[songIDTerm(ns, r.ID)] {
					seed[k2] = true
				}
			}
		}
	}

	// 3. 上一份实体表里的连通块。
	block, oldIDs := st.blockOf(seed)
	for k := range block {
		if _, ok := src.cache[k]; !ok {
			delete(block, k)
		}
	}
	// 块外同组的写法:检索 id 的闸看整组。
	all := maps.Clone(block)
	for k := range block {
		for _, t := range st.terms[k] {
			if songSearchedIDTerm(t) {
				for _, k2 := range st.index[t] {
					all[k2] = true
				}
			}
		}
	}
	uv := src.variants(songSortedKeys(all))
	full := buildSongEntities(uv, src.splits, src.dir)
	b, ok := full.restrict(func(i int) bool { return block[uv[i].key] })
	if !ok {
		slog.Warn("song entities: incremental block has evidence edges leaving it, rebuilding in full", "block", len(block))
		return nil, errSongEntityUpdate
	}

	// 4. 这一块的实体表,拼回整份。
	oldSub := &songEntityTableFile{Version: songEntityTableVersion, Songs: map[string]songEntityRecord{}}
	for id := range oldIDs {
		if rec, ok := st.table.Songs[id]; ok {
			oldSub.Songs[id] = rec
		}
	}
	songs := map[string]songEntitySeed{}
	for k := range block {
		e := src.cache[k]
		if _, live := st.table.Songs[e.Song]; e.Song != "" && (oldIDs[e.Song] || !live) {
			songs[k] = songEntitySeed{song: e.Song, share: e.SongShare}
		}
	}
	part := b.table(oldSub, songs, now)
	t := &songEntityTableFile{Version: songEntityTableVersion, BuiltAt: now.Unix(), Songs: map[string]songEntityRecord{}}
	for id, rec := range st.table.Songs {
		if !oldIDs[id] {
			t.Songs[id] = rec
		}
	}
	for id, rec := range part.Songs {
		if _, taken := t.Songs[id]; taken {
			return nil, errSongEntityUpdate
		}
		t.Songs[id] = rec
	}
	gone := maps.Clone(block)
	for _, k := range removed {
		gone[k] = true
	}
	for _, v := range st.table.Vetoed {
		if !gone[v.A] && !gone[v.B] {
			t.Vetoed = append(t.Vetoed, v)
		}
	}
	t.Vetoed = append(t.Vetoed, part.Vetoed...)
	t.Redirects = songMergeRedirects(t.Songs, st.table.Redirects, part.Redirects)

	st.table, st.prints = t, prints
	st.mapTable()
	return &songEntityUpdate{build: b, table: t, changed: len(changed), removed: len(removed)}, nil
}

// blockOf:seed 里的写法在上一份实体表里所在的连通块(实体,加上被否决的边连着的实体),和块里的旧实体 id。还没进实体表的
// 写法自己算一块。
func (st *songEntityState) blockOf(seed map[string]bool) (map[string]bool, map[string]bool) {
	keys, ids := map[string]bool{}, map[string]bool{}
	var queue []string
	for k := range seed {
		id := st.entityOf[k]
		if id == "" {
			keys[k] = true
			continue
		}
		if !ids[id] {
			ids[id] = true
			queue = append(queue, id)
		}
	}
	for len(queue) > 0 {
		id := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		for _, k := range st.table.Songs[id].Variants {
			keys[k] = true
		}
		for _, o := range st.linked[id] {
			if !ids[o] {
				ids[o] = true
				queue = append(queue, o)
			}
		}
	}
	return keys, ids
}

// songMergeRedirects:旧表的重定向加上这一块新记的,压平到现在的 id;指向已经不在的 id 的、自己又是现成实体的丢掉。
func songMergeRedirects(songs map[string]songEntityRecord, old, add map[string]string) map[string]string {
	all := maps.Clone(old)
	if all == nil {
		all = map[string]string{}
	}
	maps.Copy(all, add)
	out := map[string]string{}
	for from, to := range all {
		if _, live := songs[from]; live {
			continue
		}
		for range 8 {
			if _, live := songs[to]; live {
				break
			}
			next, ok := all[to]
			if !ok {
				break
			}
			to = next
		}
		if _, live := songs[to]; live {
			out[from] = to
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// restrict:只留 keep 认的写法的那份建表结果(下标重排,partial)。留下的写法跟扔掉的写法之间有证据边、或者一个实体被拆在两边时
// 返回 false:那样留下的这部分跟全量建表不一定一样。
func (b *songEntityBuild) restrict(keep func(i int) bool) (*songEntityBuild, bool) {
	out := &songEntityBuild{splits: b.splits, vetoMemo: map[songVetoKey]string{}, decisionsDir: b.decisionsDir,
		gateDrops: b.gateDrops, partial: true}
	idx := make([]int, len(b.variants))
	for i := range b.variants {
		idx[i] = -1
		if keep(i) {
			idx[i] = len(out.variants)
			out.variants = append(out.variants, b.variants[i])
		}
	}
	edgeIdx := make([]int, len(b.edges))
	for i, e := range b.edges {
		edgeIdx[i] = -1
		ka, kb := idx[e.a] >= 0, idx[e.b] >= 0
		if ka != kb {
			return nil, false
		}
		if !ka {
			continue
		}
		edgeIdx[i] = len(out.edges)
		e.a, e.b = idx[e.a], idx[e.b]
		out.edges = append(out.edges, e)
		out.edgeVeto = append(out.edgeVeto, b.edgeVeto[i])
	}
	for _, i := range b.merged {
		if edgeIdx[i] >= 0 {
			out.merged = append(out.merged, edgeIdx[i])
		}
	}
	for _, v := range b.vetoed {
		if idx[v.edge.a] < 0 {
			continue
		}
		v.edge.a, v.edge.b, v.x, v.y = idx[v.edge.a], idx[v.edge.b], idx[v.x], idx[v.y]
		out.vetoed = append(out.vetoed, v)
	}
	out.entityOf = make([]int, len(out.variants))
	out.shareOf = make([]int, len(out.variants))
	for _, members := range b.clusters {
		var kept []int
		for _, m := range members {
			if idx[m] >= 0 {
				kept = append(kept, idx[m])
			}
		}
		if len(kept) == 0 {
			continue
		}
		if len(kept) != len(members) {
			return nil, false
		}
		for _, m := range kept {
			out.entityOf[m] = len(out.clusters)
		}
		out.clusters = append(out.clusters, kept)
	}
	for i := range b.variants {
		if idx[i] >= 0 {
			out.shareOf[idx[i]] = idx[b.shareOf[i]]
		}
	}
	return out, true
}

// songEntityLive:常驻进程最近一次建表之后的状态(rebuildSongEntityTable 写、updateSongEntityTable 增量改),持
// songEntityRebuildMu 读写。songEntityLivePath 是它对应的实体表路径,换了配置目录(测试)就不用它。
var (
	songEntityLive     *songEntityState
	songEntityLivePath string
)

// songEntityTableDiff:两份实体表按写法比(实体 id、建立时刻不比):同一个实体的写法、同一个共享组的写法、实体的证据边、
// 两头是它的被否决的合并。返回不一样的写法键(排好序),只在一份里有的也算。
func songEntityTableDiff(a, b *songEntityTableFile) []string {
	sa, sb := songEntityTableShape(a), songEntityTableShape(b)
	var out []string
	for k, s := range sa {
		if sb[k] != s {
			out = append(out, k)
		}
	}
	for k := range sb {
		if _, ok := sa[k]; !ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// songEntityTableShape:写法键 → 它在 t 里的样子(songEntityTableDiff 比的那几样拼成一串)。
func songEntityTableShape(t *songEntityTableFile) map[string]string {
	out := map[string]string{}
	vetoes := map[string][]string{}
	for _, v := range t.Vetoed {
		s := strings.Join([]string{v.Reason, v.Kind, v.A, v.B, v.X, v.Y}, "\x1f")
		vetoes[v.A] = append(vetoes[v.A], s)
		vetoes[v.B] = append(vetoes[v.B], s)
	}
	for _, rec := range t.Songs {
		members := songSortedCopy(rec.Variants)
		var edges []string
		for _, e := range rec.Evidence {
			a, b := e.A, e.B
			if b < a {
				a, b = b, a
			}
			edges = append(edges, strings.Join([]string{e.Kind, a, b, e.Value, strconv.FormatBool(e.CountOnly)}, "\x1f"))
		}
		slices.Sort(edges)
		groups := map[int][]string{}
		for i, k := range rec.Variants {
			g := 0
			if i < len(rec.Share) {
				g = rec.Share[i]
			}
			groups[g] = append(groups[g], k)
		}
		entity := strings.Join(members, "\x1e") + "\x1d" + strings.Join(edges, "\x1e")
		for i, k := range rec.Variants {
			g := 0
			if i < len(rec.Share) {
				g = rec.Share[i]
			}
			vs := songSortedCopy(vetoes[k])
			out[k] = entity + "\x1d" + strings.Join(songSortedCopy(groups[g]), "\x1e") + "\x1d" + strings.Join(vs, "\x1e")
		}
	}
	return out
}

// songEntityPrepare:阶段 2 开着时读目录名字、MusicBrainz 录音,返回把它们挂到写法上的函数(增量重算沿用同一份,
// 名字补扫之后全量重建时重读)。阶段 2 关着时返回 nil。
func songEntityPrepare() func(vs []songVariant) {
	if !features().SongEntityPhase2 {
		return nil
	}
	apple, netease, mb := readAppleNames(appleNamesPath()), readNeteaseNames(neteaseNamesPath()), readMBRecordings(mbRecordingsPath())
	return func(vs []songVariant) {
		attachAppleNames(vs, apple)
		attachNeteaseNames(vs, netease)
		attachMBRecordings(vs, mb)
		attachSpotifyLanguages(vs, spotifyLanguagesForVariants(vs))
	}
}

// songEntityLiveSource:常驻进程这一刻的建表输入。持锁只复制缓存。
func songEntityLiveSource(prepare func(vs []songVariant)) *songEntitySource {
	enrichMu.Lock()
	snapshot := maps.Clone(enrichCache)
	enrichMu.Unlock()
	return &songEntitySource{cache: snapshot, pins: lyricsPinnedKeys(), splits: readSongEntityUserSplits(songEntityUserPath()),
		dir: decisionSidecarDir(), prepare: prepare}
}

// songEntitySongs:写法键 → 条目上的 `song`、`song_share`(没有实体 id 的不在里面),给 id、组号延续当种子。
func songEntitySongs(cache map[string]enrichEntry) map[string]songEntitySeed {
	out := map[string]songEntitySeed{}
	for k, e := range cache {
		if e.Song != "" {
			out[k] = songEntitySeed{song: e.Song, share: e.SongShare}
		}
	}
	return out
}

// buildSongEntityState:全量建一次,返回建表结果、实体表和留给增量重算的状态。old 是上一份实体表(id 延续用),可以是 nil。
func buildSongEntityState(src *songEntitySource, old *songEntityTableFile, now time.Time) (*songEntityBuild, *songEntityTableFile, *songEntityState) {
	b := buildSongEntities(src.variants(songSortedKeys(src.cache)), src.splits, src.dir)
	table := b.table(old, songEntitySongs(src.cache), now)
	return b, table, newSongEntityState(table, b.variants, src)
}
