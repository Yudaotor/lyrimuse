//go:build devtools

package main

import (
	"fmt"
	"io"
	"maps"
	"math/rand"
	"slices"
	"sort"
	"time"
)

// `song-entities -check-incremental N`:按本机缓存建一次表,再随机改 N 次(每次从原样改起),每次增量重算一遍、按改完的数据全量
// 建一遍,比两份实体表,打出不一样的、退回全量的次数和增量耗时。只读,不写任何文件。

func runSongEntityIncrementalCheck(src *songEntitySource, n int, w io.Writer) {
	now := time.Now()
	_, table, base := buildSongEntityState(src, nil, now)
	keys := songSortedKeys(src.cache)
	var multi []string
	for _, rec := range table.Songs {
		if len(rec.Variants) > 1 {
			multi = append(multi, rec.Variants...)
		}
	}
	sort.Strings(multi)
	rnd := rand.New(rand.NewSource(1))
	pick := func(i int) string {
		if i%2 == 0 && len(multi) > 0 {
			return multi[rnd.Intn(len(multi))]
		}
		return keys[rnd.Intn(len(keys))]
	}
	changes := []struct {
		name  string
		apply func(c map[string]enrichEntry, k, o string)
	}{
		{"delete", func(c map[string]enrichEntry, k, _ string) { delete(c, k) }},
		{"no-duration", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.DurationSecs = 0; c[k] = e }},
		{"duration+3", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.DurationSecs += 3; c[k] = e }},
		{"no-isrc", func(c map[string]enrichEntry, k, _ string) { e := c[k]; e.ISRCs, e.ISRCLevels = nil, nil; c[k] = e }},
		{"no-lyrics", func(c map[string]enrichEntry, k, _ string) {
			e := c[k]
			e.Lyrics, e.LyricsYRC = bodyText{}, bodyText{}
			c[k] = e
		}},
		{"no-searched-links", func(c map[string]enrichEntry, k, _ string) {
			e := c[k]
			e.NeteaseURL, e.AppleURL, e.QQURL = "", "", ""
			c[k] = e
		}},
		{"new-version", func(c map[string]enrichEntry, k, _ string) {
			e := c[k]
			e.Song, e.SongShare = "", 0
			c[k+" (Deluxe)"] = e
		}},
		{"other-isrc", func(c map[string]enrichEntry, k, o string) {
			e, f := c[k], c[o]
			e.ISRCs, e.ISRCLevels, e.DurationSecs = f.ISRCs, f.ISRCLevels, f.DurationSecs
			c[k] = e
		}},
		{"other-searched-links", func(c map[string]enrichEntry, k, o string) {
			e, f := c[k], c[o]
			e.NeteaseURL, e.AppleURL, e.QQURL = f.NeteaseURL, f.AppleURL, f.QQURL
			c[k] = e
		}},
	}
	var took []time.Duration
	bad, fallback := 0, 0
	for i := 0; i < n; i++ {
		k, o := pick(i), pick(i+1)
		c := changes[i%len(changes)]
		changed := *src
		changed.cache = maps.Clone(src.cache)
		c.apply(changed.cache, k, o)
		st := base.clone()
		start := time.Now()
		up, err := st.update(&changed, now)
		took = append(took, time.Since(start))
		if err != nil {
			fallback++
			fmt.Fprintf(w, "fallback  %s %q: %v\n", c.name, k, err)
			continue
		}
		_, want, _ := buildSongEntityState(&changed, nil, now)
		block := 0
		if up != nil {
			block = len(up.build.variants)
		}
		if diff := songEntityTableDiff(st.table, want); len(diff) > 0 {
			bad++
			fmt.Fprintf(w, "DIFFERENT %s %q: %d variants, e.g. %q\n", c.name, k, len(diff), diff[:min(3, len(diff))])
			continue
		}
		fmt.Fprintf(w, "same      %s %q: block %d, took %v\n", c.name, k, block, took[len(took)-1].Round(time.Microsecond))
	}
	slices.Sort(took)
	if len(took) > 0 {
		fmt.Fprintf(w, "\n%d checks: %d different, %d fell back to a full rebuild; incremental took median %v, max %v\n",
			n, bad, fallback, took[len(took)/2].Round(time.Microsecond), took[len(took)-1].Round(time.Microsecond))
	}
}
