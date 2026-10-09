//go:build devtools

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// 歌曲实体的标注集:`song-entities -sample <目录>` 按证据分层抽样、写出待标的 sample.jsonl;`-score <文件>` 拿标好的那份
// 对照当前规则算合错率、漏合率。整份标注集放在仓库外(本机是 ~/.config/lyrimuse-labels/song-entity/):里面是本机的收听样本。
// 改规则时先用旧规则 `-dump` 存一份实体表,改完 `-diff` 列出全库新并、拆开的实体:标注集只是抽样,规则放出来的新合并
// 要逐个过目。
//
// 三层:多写法实体(songLabelEntityQuota 个,只靠中证据连着的、含一中一外写法的优先)、被否决挡下的写法对、单写法实体里
// 歌名或歌手相近的写法对。顺序按键的哈希取,同一份缓存重跑抽到的一样。

const (
	songLabelEntityQuota = 200
	songLabelVetoQuota   = 100
	songLabelNearQuota   = 100
	// 多写法实体里,只靠中证据连着的、含一中一外写法的各最多抽这么多,其余从剩下的实体里补足。
	songLabelMediumOnlyQuota = 70
	songLabelCrossQuota      = 50
	// 被否决的写法对每种否决先各抽这么多,再按哈希补足。
	songLabelPerVetoReason = 15
)

// songLabelItem:标注集的一条。标注:entity 层填 same(全是同一份录音)或 mixed 加 wrong(不属于这首的写法键);
// vetoed、near 层填 same 或 different;判不了填 unsure。
type songLabelItem struct {
	ID       string             `json:"id"`
	Stratum  string             `json:"stratum"`
	Variants []songLabelVariant `json:"variants"`
	Edges    []string           `json:"edges,omitempty"`
	Veto     string             `json:"veto,omitempty"`
	Pairs    []songLabelPair    `json:"pairs,omitempty"`
	Label    string             `json:"label"`
	Wrong    []string           `json:"wrong,omitempty"`
	Note     string             `json:"note,omitempty"`
}

type songLabelVariant struct {
	Key          string   `json:"key"`
	DurationSecs float64  `json:"duration_secs,omitempty"`
	IDs          []string `json:"ids,omitempty"`
	VersionTags  []string `json:"version_tags,omitempty"`
	Vocals       string   `json:"vocals,omitempty"`
	LyricsSource string   `json:"lyrics_source,omitempty"`
	FirstLines   []string `json:"first_lines,omitempty"`
}

// songLabelPair:一对写法的歌词比较。WordOverlap 为 -1 表示有一边没有可比的正文;Shift 只在用词重合不低于
// songLyricsSameWordsMin、按行配得上时有值。
type songLabelPair struct {
	A           string   `json:"a"`
	B           string   `json:"b"`
	WordOverlap float64  `json:"word_overlap"`
	Shift       *float64 `json:"timeline_shift_secs,omitempty"`
}

func songLabelHash(s string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	return h.Sum64()
}

// writeLabelSample 抽样、写出 <dir>/sample.jsonl。
func (b *songEntityBuild) writeLabelSample(dir string) (int, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return 0, err
	}
	var items []songLabelItem
	items = append(items, b.sampleEntities()...)
	items = append(items, b.sampleVetoed()...)
	items = append(items, b.sampleNear()...)
	path := filepath.Join(dir, "sample.jsonl")
	f, err := os.Create(path)
	if err != nil {
		return 0, err
	}
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	for _, it := range items {
		if err := enc.Encode(it); err != nil {
			f.Close()
			return 0, err
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return 0, err
	}
	return len(items), f.Close()
}

func (b *songEntityBuild) sampleEntities() []songLabelItem {
	type cand struct {
		ci   int
		hash uint64
	}
	var medium, cross, rest []cand
	for ci, members := range b.clusters {
		if len(members) < 2 {
			continue
		}
		c := cand{ci, songLabelHash(b.variants[members[0]].key)}
		hasStrong, han, latin := false, false, false
		for _, m := range members {
			if b.variants[m].han {
				han = true
			} else {
				latin = true
			}
		}
		for i, e := range b.edges {
			if !b.edgeVeto[i] && b.entityOf[e.a] == ci && b.entityOf[e.b] == ci && e.strong() {
				hasStrong = true
				break
			}
		}
		switch {
		case !hasStrong:
			medium = append(medium, c)
		case han && latin:
			cross = append(cross, c)
		default:
			rest = append(rest, c)
		}
	}
	byHash := func(cs []cand) {
		sort.Slice(cs, func(i, j int) bool { return cs[i].hash < cs[j].hash })
	}
	byHash(medium)
	byHash(cross)
	byHash(rest)
	var picked []cand
	picked = append(picked, medium[:min(len(medium), songLabelMediumOnlyQuota)]...)
	picked = append(picked, cross[:min(len(cross), songLabelCrossQuota)]...)
	picked = append(picked, rest[:min(len(rest), max(0, songLabelEntityQuota-len(picked)))]...)
	var out []songLabelItem
	for _, c := range picked {
		members := b.clusters[c.ci]
		it := songLabelItem{ID: fmt.Sprintf("entity-%016x", c.hash), Stratum: "entity"}
		in := map[int]bool{}
		for _, m := range members {
			in[m] = true
			it.Variants = append(it.Variants, b.labelVariant(m))
		}
		for i, e := range b.edges {
			if b.edgeVeto[i] || !in[e.a] || !in[e.b] {
				continue
			}
			mark := ""
			if e.countOnly {
				mark = " (只当计数用)"
			}
			it.Edges = append(it.Edges, fmt.Sprintf("%s %s ↔ %s %s%s", e.kind, b.variants[e.a].key, b.variants[e.b].key, e.value, mark))
		}
		for i, x := range members {
			for _, y := range members[i+1:] {
				it.Pairs = append(it.Pairs, b.labelPair(x, y))
			}
		}
		out = append(out, it)
	}
	return out
}

func (b *songEntityBuild) sampleVetoed() []songLabelItem {
	type cand struct {
		v    songVeto
		hash uint64
	}
	seen := map[string]bool{}
	byReason := map[string][]cand{}
	for _, v := range b.vetoed {
		k := songPairKey(b.variants[v.x].key, b.variants[v.y].key)
		if seen[k] {
			continue
		}
		seen[k] = true
		byReason[v.reason] = append(byReason[v.reason], cand{v, songLabelHash(k)})
	}
	var all, picked []cand
	pickedKey := map[uint64]bool{}
	for _, r := range songSortedKeys(byReason) {
		cs := byReason[r]
		sort.Slice(cs, func(i, j int) bool { return cs[i].hash < cs[j].hash })
		for i, c := range cs {
			if i < songLabelPerVetoReason {
				picked = append(picked, c)
				pickedKey[c.hash] = true
			}
			all = append(all, c)
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].hash < all[j].hash })
	for _, c := range all {
		if len(picked) >= songLabelVetoQuota {
			break
		}
		if !pickedKey[c.hash] {
			picked = append(picked, c)
			pickedKey[c.hash] = true
		}
	}
	var out []songLabelItem
	for _, c := range picked {
		v := c.v
		out = append(out, songLabelItem{
			ID: fmt.Sprintf("vetoed-%016x", c.hash), Stratum: "vetoed",
			Variants: []songLabelVariant{b.labelVariant(v.x), b.labelVariant(v.y)},
			Veto:     fmt.Sprintf("%s ← %s(边:%s ↔ %s)", v.reason, v.edge.kind, b.variants[v.edge.a].key, b.variants[v.edge.b].key),
			Pairs:    []songLabelPair{b.labelPair(v.x, v.y)},
		})
	}
	return out
}

// sampleNear:单写法实体之间、同一位主歌手、歌名相近(写法族键互相包含、只差一个字,或一中一外且时长差不超过 2 秒)的写法对。
func (b *songEntityBuild) sampleNear() []songLabelItem {
	buckets := map[string][]int{}
	for _, members := range b.clusters {
		if len(members) != 1 {
			continue
		}
		v := &b.variants[members[0]]
		if v.primary == "" || v.family == "" {
			continue
		}
		buckets[artistMatchKey(v.primary)] = append(buckets[artistMatchKey(v.primary)], members[0])
	}
	type cand struct {
		x, y int
		hash uint64
	}
	var cs []cand
	for _, ms := range buckets {
		for i, x := range ms {
			for _, y := range ms[i+1:] {
				vx, vy := &b.variants[x], &b.variants[y]
				near := false
				switch {
				case vx.han != vy.han:
					near = vx.durationSecs > 0 && vy.durationSecs > 0 && math.Abs(vx.durationSecs-vy.durationSecs) <= songEntityDurationGateSecs
				case vx.family == vy.family, strings.Contains(vx.family, vy.family), strings.Contains(vy.family, vx.family):
					near = true
				default:
					near = songOneCharVariant(vx.family, vy.family)
				}
				if near {
					cs = append(cs, cand{x, y, songLabelHash(songPairKey(vx.key, vy.key))})
				}
			}
		}
	}
	sort.Slice(cs, func(i, j int) bool { return cs[i].hash < cs[j].hash })
	var out []songLabelItem
	for _, c := range cs[:min(len(cs), songLabelNearQuota)] {
		out = append(out, songLabelItem{
			ID: fmt.Sprintf("near-%016x", c.hash), Stratum: "near",
			Variants: []songLabelVariant{b.labelVariant(c.x), b.labelVariant(c.y)},
			Pairs:    []songLabelPair{b.labelPair(c.x, c.y)},
		})
	}
	return out
}

func (b *songEntityBuild) labelVariant(i int) songLabelVariant {
	v := &b.variants[i]
	out := songLabelVariant{Key: v.key, DurationSecs: v.durationSecs, LyricsSource: v.lyricsSource}
	for _, g := range v.ids {
		out.IDs = append(out.IDs, g.ns+":"+g.id+"("+g.level.String()+")")
	}
	for t := range v.versionTags {
		out.VersionTags = append(out.VersionTags, t)
	}
	sort.Strings(out.VersionTags)
	switch v.vocalsKind() {
	case songVocalsNone:
		out.Vocals = "none"
	case songVocalsPresent:
		out.Vocals = "present"
	}
	for _, line := range strings.Split(v.lyrics, "\n") {
		if len(out.FirstLines) == 3 {
			break
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || isCreditLine(text) || !lrcTimestampRe.MatchString(line) {
			continue
		}
		out.FirstLines = append(out.FirstLines, text)
	}
	return out
}

func (b *songEntityBuild) labelPair(x, y int) songLabelPair {
	p := songLabelPair{A: b.variants[x].key, B: b.variants[y].key, WordOverlap: -1}
	_, wx := b.variants[x].lyricsShingles()
	_, wy := b.variants[y].lyricsShingles()
	if wx == nil || wy == nil {
		return p
	}
	p.WordOverlap = math.Round(songWordOverlap(wx, wy)*100) / 100
	if p.WordOverlap >= songLyricsSameWordsMin {
		if shift, _, ok := songTimelineShift(b.variants[x].displayedLines(), b.variants[y].displayedLines()); ok {
			s := math.Round(shift*100) / 100
			p.Shift = &s
		}
	}
	return p
}

// writeLabelScore 读标好的标注集,对照这一次建表的结果算合错率、漏合率,写给人看。比率的分母是判得了的条数;
// 「抽样时」是标的那一刻的状态(并错的实体、被否决挡下的同一首),「现在」按这一次建表算。
func (b *songEntityBuild) writeLabelScore(path string, w io.Writer) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	idx := map[string]int{}
	for i := range b.variants {
		idx[b.variants[i].key] = i
	}
	type tally struct{ labeled, bad, unsure, stillBad int }
	var ent, veto, near tally
	var shareBad int
	var notes []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		var it songLabelItem
		if json.Unmarshal(sc.Bytes(), &it) != nil || it.Label == "" {
			continue
		}
		switch it.Stratum {
		case "entity":
			ent.labeled++
			if it.Label == "unsure" {
				ent.unsure++
				continue
			}
			if it.Label != "mixed" {
				continue
			}
			ent.bad++
			// 不属于这首的写法现在还跟别的写法在不在同一个实体、同一个共享组。
			still, share := false, false
			for _, wk := range it.Wrong {
				wi, ok := idx[wk]
				if !ok {
					continue
				}
				for _, v := range it.Variants {
					if vi, ok := idx[v.Key]; ok && vi != wi && !slices.Contains(it.Wrong, v.Key) {
						if b.entityOf[vi] == b.entityOf[wi] {
							still = true
							if b.shareOf[vi] == b.shareOf[wi] {
								share = true
							}
						}
					}
				}
			}
			if still {
				ent.stillBad++
			}
			if share {
				shareBad++
			}
			notes = append(notes, fmt.Sprintf("并错:%s wrong=%v(现在%s)%s", it.ID, it.Wrong, map[bool]string{true: "仍在一起", false: "已分开"}[still], it.Note))
		case "vetoed", "near":
			t := &veto
			if it.Stratum == "near" {
				t = &near
			}
			t.labeled++
			if it.Label == "unsure" {
				t.unsure++
				continue
			}
			if it.Label != "same" || len(it.Variants) != 2 {
				continue
			}
			t.bad++
			xi, okx := idx[it.Variants[0].Key]
			yi, oky := idx[it.Variants[1].Key]
			now := "现在已并上"
			if okx && oky && b.entityOf[xi] != b.entityOf[yi] {
				t.stillBad++
				now = "现在仍分开"
			}
			notes = append(notes, fmt.Sprintf("漏合:%s %s ↔ %s(%s)%s", it.ID, it.Variants[0].Key, it.Variants[1].Key, now, it.Note))
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	rate := func(bad, n int) string {
		if n == 0 {
			return "-"
		}
		return fmt.Sprintf("%.1f%%", 100*float64(bad)/float64(n))
	}
	fmt.Fprintf(w, "多写法实体:标了 %d 个(判不了 %d),抽样时并错 %d 个;现在仍并着 %d 个,合错率 %s,并错的写法跟别的在同一个共享组 %d 个\n",
		ent.labeled, ent.unsure, ent.bad, ent.stillBad, rate(ent.stillBad, ent.labeled-ent.unsure), shareBad)
	fmt.Fprintf(w, "被否决的写法对:标了 %d 对(判不了 %d),抽样时其实是同一首 %d 对(%s);现在仍分开 %d 对,漏合率 %s\n",
		veto.labeled, veto.unsure, veto.bad, rate(veto.bad, veto.labeled-veto.unsure), veto.stillBad, rate(veto.stillBad, veto.labeled-veto.unsure))
	fmt.Fprintf(w, "相近的单写法对:标了 %d 对(判不了 %d),抽样时其实是同一首 %d 对(%s);现在仍分开 %d 对,漏合率 %s\n",
		near.labeled, near.unsure, near.bad, rate(near.bad, near.labeled-near.unsure), near.stillBad, rate(near.stillBad, near.labeled-near.unsure))
	sort.Strings(notes)
	for _, n := range notes {
		fmt.Fprintln(w, "  "+n)
	}
	return nil
}

// writeClusterDump:每个实体一行,内容是它的写法键(排好序)。
func (b *songEntityBuild) writeClusterDump(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	for _, keys := range b.clusterKeys() {
		if err := enc.Encode(keys); err != nil {
			f.Close()
			return err
		}
	}
	return f.Close()
}

// writeClusterDiff 拿 writeClusterDump 存下的旧实体表对照这一次建表:新并的(旧表里几个实体的写法到了一个实体里)
// 和拆开的(旧表里一个实体的写法分到了几个实体里)。只在一边出现的写法(缓存里新增、删掉的)不算。
func (b *songEntityBuild) writeClusterDiff(path string, w io.Writer) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var old [][]string
	dec := json.NewDecoder(f)
	for {
		var keys []string
		if err := dec.Decode(&keys); err == io.EOF {
			break
		} else if err != nil {
			return err
		}
		old = append(old, keys)
	}
	cur := b.clusterKeys()
	merged, split := songClusterChanges(cur, songClusterIndex(old)), songClusterChanges(old, songClusterIndex(cur))
	fmt.Fprintf(w, "新并的实体 %d 个,拆开的旧实体 %d 个\n", len(merged), len(split))
	for _, l := range merged {
		fmt.Fprintln(w, "  并:"+l)
	}
	for _, l := range split {
		fmt.Fprintln(w, "  拆:"+l)
	}
	return nil
}

func (b *songEntityBuild) clusterKeys() [][]string {
	out := make([][]string, 0, len(b.clusters))
	for _, members := range b.clusters {
		keys := make([]string, 0, len(members))
		for _, m := range members {
			keys = append(keys, b.variants[m].key)
		}
		sort.Strings(keys)
		out = append(out, keys)
	}
	return out
}

func songClusterIndex(clusters [][]string) map[string]int {
	of := map[string]int{}
	for i, keys := range clusters {
		for _, k := range keys {
			of[k] = i
		}
	}
	return of
}

// songClusterChanges:clusters 里每个实体按 of 分块,分成不止一块的列成「块 ‖ 块」。of 里没有的写法跳过。
func songClusterChanges(clusters [][]string, of map[string]int) []string {
	var out []string
	for _, keys := range clusters {
		parts := map[int][]string{}
		var order []int
		for _, k := range keys {
			i, ok := of[k]
			if !ok {
				continue
			}
			if parts[i] == nil {
				order = append(order, i)
			}
			parts[i] = append(parts[i], k)
		}
		if len(order) < 2 {
			continue
		}
		blocks := make([]string, len(order))
		for j, i := range order {
			blocks[j] = strings.Join(parts[i], " / ")
		}
		out = append(out, strings.Join(blocks, " ‖ "))
	}
	return out
}
