package main

import (
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
)

// 歌曲实体的诊断报告:实体规模、各证据的贡献、被闸与否决挡下的合并,以及要人过目的几类清单。

// songVariantsFromCache 把缓存条目摘成建表用的写法,按键排序。pinned 是校准过时间轴的写法。
func songVariantsFromCache(cache map[string]enrichEntry, pinned map[string]bool) []songVariant {
	keys := make([]string, 0, len(cache))
	for k := range cache {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]songVariant, 0, len(keys))
	for _, k := range keys {
		out = append(out, songVariantOf(k, cache[k], pinned[k]))
	}
	return out
}

// songEntityReport:一次建表的诊断。
type songEntityReport struct {
	variants, entities, multi int
	sizes                     [7]int // 1~5 条、6 条以上(下标 6)
	edgesByKind               map[string]int
	countOnlyByKind           map[string]int
	mergesByKind              map[string]int
	gateDrops                 map[string]int
	vetoes                    map[string]int // 「否决种类 ← 证据种类」
	vetoExamples              map[string][]string
	suspicious                []string
	searchedOnly              []string // 歌名对不上、又只靠检索 id 连着的写法对
	mediumChains              []string
	shareGroups, shareChanges int
	spanOverHalf              []string
	twoManual, twoPins        []string
	wrongLyrics               []string
	timelineShifted           []string
}

const songReportExamples = 3

func (b *songEntityBuild) report() songEntityReport {
	r := songEntityReport{
		variants: len(b.variants), entities: len(b.clusters),
		edgesByKind: map[string]int{}, countOnlyByKind: map[string]int{}, mergesByKind: map[string]int{},
		gateDrops: b.gateDrops, vetoes: map[string]int{}, vetoExamples: map[string][]string{},
	}
	for _, e := range b.edges {
		r.edgesByKind[e.kind]++
		if e.countOnly {
			r.countOnlyByKind[e.kind]++
		}
	}
	for _, i := range b.merged {
		r.mergesByKind[b.edges[i].kind]++
	}
	for _, v := range b.vetoed {
		k := v.reason + " ← " + v.edge.kind
		r.vetoes[k]++
		if len(r.vetoExamples[k]) < songReportExamples {
			ex := b.variants[v.x].key + "  ×  " + b.variants[v.y].key
			if a, c := v.edge.a, v.edge.b; (a != v.x || c != v.y) && (a != v.y || c != v.x) {
				ex += "(边:" + b.variants[a].key + " — " + b.variants[c].key + ")"
			}
			r.vetoExamples[k] = append(r.vetoExamples[k], ex)
		}
	}
	shareMembers := map[int][]int{}
	for ci, members := range b.clusters {
		r.sizes[min(len(members), 6)]++
		if len(members) >= 2 {
			r.multi++
		}
		b.reportEntity(&r, ci, members)
		for _, m := range members {
			shareMembers[b.shareOf[m]] = append(shareMembers[b.shareOf[m]], m)
		}
	}
	for _, ms := range shareMembers {
		if len(ms) < 2 {
			continue
		}
		r.shareGroups++
		bodies := map[string]int{}
		for _, m := range ms {
			if l := strings.TrimSpace(b.variants[m].lyrics); l != "" {
				bodies[l]++
			}
		}
		if len(bodies) >= 2 {
			most := 0
			for _, n := range bodies {
				most = max(most, n)
			}
			total := 0
			for _, n := range bodies {
				total += n
			}
			r.shareChanges += total - most
		}
	}
	return r
}

// reportEntity:一个实体要进清单的几样。
func (b *songEntityBuild) reportEntity(r *songEntityReport, ci int, members []int) {
	if len(members) < 2 {
		return
	}
	vs := b.variants
	families, artists := map[string]bool{}, map[string]bool{}
	lo, hi := math.Inf(1), math.Inf(-1)
	manual, pins := 0, 0
	manualBodies := map[string]bool{}
	for _, m := range members {
		families[vs[m].family] = true
		artists[artistMatchKey(vs[m].primary)] = true
		if d := vs[m].durationSecs; d > 0 {
			lo, hi = math.Min(lo, d), math.Max(hi, d)
		}
		if vs[m].manual {
			manual++
			manualBodies[vs[m].lyrics] = true
		}
		if vs[m].pinned {
			pins++
		}
	}
	summary := b.entitySummary(members)
	if len(members) >= 6 && (len(families) >= 3 || len(artists) >= 3) {
		r.suspicious = append(r.suspicious, summary)
	}
	if hi-lo > 0.5 {
		r.spanOverHalf = append(r.spanOverHalf, fmt.Sprintf("%.2fs  %s", hi-lo, summary))
	}
	if manual >= 2 && len(manualBodies) >= 2 {
		r.twoManual = append(r.twoManual, summary)
	}
	if pins >= 2 {
		r.twoPins = append(r.twoPins, summary)
	}

	// 实体内的边:哪些写法对之间只靠检索 id 连着;有没有强证据;直接相连的写法对。
	inEntity := map[int]bool{}
	for _, m := range members {
		inEntity[m] = true
	}
	parent := map[int]int{}
	for _, m := range members {
		parent[m] = m
	}
	var find func(int) int
	find = func(x int) int {
		for parent[x] != x {
			parent[x] = parent[parent[x]]
			x = parent[x]
		}
		return x
	}
	strong := false
	direct := map[[2]int]bool{}
	for i, e := range b.edges {
		if b.edgeVeto[i] || !inEntity[e.a] || !inEntity[e.b] {
			continue
		}
		direct[[2]int{e.a, e.b}] = true
		if e.strong() {
			strong = true
		}
		if songEvidenceKinds[e.kind].searched {
			continue
		}
		if ra, rb := find(e.a), find(e.b); ra != rb {
			parent[rb] = ra
		}
	}
	for i, x := range members {
		for _, y := range members[i+1:] {
			if find(x) == find(y) {
				continue
			}
			if ok, cross := songTitlesCompatible(vs[x].title, vs[y].title); !ok && !cross {
				r.searchedOnly = append(r.searchedOnly, vs[x].key+"  ↔  "+vs[y].key)
			}
		}
	}
	if !strong && len(members) >= 3 && len(direct) < len(members)*(len(members)-1)/2 {
		r.mediumChains = append(r.mediumChains, summary)
	}

	// 实体内两份正文:用词重合不到一半的(多半是其中一条选错了词)、同一套词时间轴整体平移超过 1 秒的。
	for i, x := range members {
		_, wx := vs[x].lyricsShingles()
		if wx == nil {
			continue
		}
		for _, y := range members[i+1:] {
			_, wy := vs[y].lyricsShingles()
			if wy == nil || vs[x].lyrics == vs[y].lyrics {
				continue
			}
			overlap := songWordOverlap(wx, wy)
			pair := fmt.Sprintf("%s(%s)  ↔  %s(%s)", vs[x].key, vs[x].lyricsSource, vs[y].key, vs[y].lyricsSource)
			if overlap < songLyricsDifferentWordsMax {
				r.wrongLyrics = append(r.wrongLyrics, fmt.Sprintf("%.2f  %s", overlap, pair))
				continue
			}
			if overlap >= songLyricsSameWordsMin {
				if shift, _, ok := songTimelineShift(vs[x].displayedLines(), vs[y].displayedLines()); ok && math.Abs(shift) > 1 {
					r.timelineShifted = append(r.timelineShifted, fmt.Sprintf("%+.2fs  %s", shift, pair))
				}
			}
		}
	}
}

// entitySummary:一个实体一行:写法数,各写法的键(最多 6 条)。
func (b *songEntityBuild) entitySummary(members []int) string {
	var keys []string
	for i, m := range members {
		if i == 6 {
			keys = append(keys, fmt.Sprintf("…另 %d 条", len(members)-6))
			break
		}
		keys = append(keys, b.variants[m].key)
	}
	return fmt.Sprintf("%d 条:%s", len(members), strings.Join(keys, " / "))
}

// writeText 把报告写成给人看的文本。limit:每份清单最多列几条(0 = 全列)。
func (r songEntityReport) writeText(w io.Writer, limit int) {
	fmt.Fprintf(w, "写法 %d 条 → 实体 %d 首,其中多写法 %d 首\n", r.variants, r.entities, r.multi)
	fmt.Fprintf(w, "实体大小:1 条 %d;2 条 %d;3 条 %d;4 条 %d;5 条 %d;6 条以上 %d\n",
		r.sizes[1], r.sizes[2], r.sizes[3], r.sizes[4], r.sizes[5], r.sizes[6])
	songReportCounts(w, "证据边(过了闸的)", r.edgesByKind)
	songReportCounts(w, "其中只当计数用的", r.countOnlyByKind)
	songReportCounts(w, "促成合并", r.mergesByKind)
	songReportCounts(w, "被闸挡下的边", r.gateDrops)
	songReportCounts(w, "被否决的合并(否决 ← 证据)", r.vetoes)
	for _, k := range songSortedKeys(r.vetoExamples) {
		for _, ex := range r.vetoExamples[k] {
			fmt.Fprintf(w, "    %s:%s\n", k, ex)
		}
	}
	fmt.Fprintf(w, "共享组(两条写法以上)%d 个;共享后会换歌词的写法 %d 条\n", r.shareGroups, r.shareChanges)
	songReportList(w, "可疑实体(≥6 条写法、≥3 种歌名或 ≥3 位主歌手)", r.suspicious, limit)
	songReportList(w, "歌名对不上、只靠检索 id 连着的写法对", r.searchedOnly, limit)
	songReportList(w, "只靠中证据串起来的实体", r.mediumChains, limit)
	songReportList(w, "实体内时长跨度超过 0.5 秒", r.spanOverHalf, limit)
	songReportList(w, "实体内两份手改不同", r.twoManual, limit)
	songReportList(w, "实体内两条写法都校准过", r.twoPins, limit)
	songReportList(w, "实体内用词重合不到一半的正文对(多半选错了词)", r.wrongLyrics, limit)
	songReportList(w, "实体内同一套词、时间轴整体平移超过 1 秒", r.timelineShifted, limit)
}

func songReportCounts(w io.Writer, title string, m map[string]int) {
	total := 0
	var parts []string
	for _, k := range songSortedKeys(m) {
		total += m[k]
		parts = append(parts, fmt.Sprintf("%s %d", k, m[k]))
	}
	fmt.Fprintf(w, "%s 共 %d:%s\n", title, total, strings.Join(parts, ";"))
}

func songReportList(w io.Writer, title string, items []string, limit int) {
	fmt.Fprintf(w, "%s:%d\n", title, len(items))
	sorted := append([]string(nil), items...)
	sort.Strings(sorted)
	for i, s := range sorted {
		if limit > 0 && i >= limit {
			fmt.Fprintf(w, "    …另 %d 条\n", len(sorted)-limit)
			break
		}
		fmt.Fprintf(w, "    %s\n", s)
	}
}

func songSortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
