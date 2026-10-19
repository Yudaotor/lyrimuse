//go:build devtools

package main

import (
	"fmt"
	"io"
	"maps"
	"sort"
	"strings"
	"time"
)

// `song-entities -check-sync-stable`:按本机缓存建一次表,把全部共享组在内存里各模拟一次同步(整组自动同步、手改同步各一遍),
// 再建一次表,比两份实体表(实体、共享组、证据边、否决)。同步只能换歌词,不该改分组:证据要是跟着同步结果变,同步就会拆开
// 自己所在的组、来回翻(18 章决策 59)。另按「证据看现在那份歌词」再建一遍当对照。只读,不写任何文件。

// songSimulatedPres:模拟同步时记下的留底(写法键 → 同步之前这条写法自己得来的那份、同步写进去那份的指纹),不写盘。
type songSimulatedPres map[string]songSimulatedPre

type songSimulatedPre struct {
	own    enrichEntry
	synced string
}

// keep:记一条留底。跟 writeSongSharePre 一样只留第一次:同一条写法再被模拟同步时,留的仍是最早那份。
func (p songSimulatedPres) keep(key string, own enrichEntry, synced string) {
	if old, ok := p[key]; ok {
		old.synced = synced
		p[key] = old
		return
	}
	p[key] = songSimulatedPre{own: own, synced: synced}
}

// lookup:换进 songSharePreOf 用:模拟过的写法按记下的那份(歌词还是同步写进去那份才算),其余交给 fallback(nil 时当没有留底)。
func (p songSimulatedPres) lookup(fallback func(string, enrichEntry) (enrichEntry, bool)) func(string, enrichEntry) (enrichEntry, bool) {
	return func(key string, e enrichEntry) (enrichEntry, bool) {
		if s, ok := p[key]; ok {
			if s.synced != songOffsetFingerprint(e.Lyrics.String(), e.LyricsYRC.String()) {
				return enrichEntry{}, false
			}
			return s.own, true
		}
		if fallback == nil {
			return enrichEntry{}, false
		}
		return fallback(key, e)
	}
}

// songSimulateShareSync:按 b(就是按 entries 建的)的共享组模拟一次同步,直接改 entries,返回同步了几组、改了几条。每组的代表是
// 键最小、有词、不是纯音乐的那条。manual 为 true 时代表标成手改原件(只翻手改标记,正文、来源不动,它自己的证据不变),其余
// 写法成它的副本(songShareCopyManual);为 false 时其余写法换成代表那份(songShareCopyPinned:跟着校准、跟上重新匹配那种
// 写法,出处记 song-entity-share)。别的手改原件、纯音乐不动,跟线上一样。改之前这条写法自己得来的那份(songOwnLyricsEntry)
// 交给 keep。
func songSimulateShareSync(b *songEntityBuild, entries map[string]enrichEntry, manual bool, now time.Time,
	keep func(key string, own enrichEntry, synced string)) (groups, changed int) {
	byRoot := map[int][]int{}
	for i := range b.variants {
		byRoot[b.shareOf[i]] = append(byRoot[b.shareOf[i]], i)
	}
	roots := make([]int, 0, len(byRoot))
	for r := range byRoot {
		roots = append(roots, r)
	}
	sort.Ints(roots)
	for _, r := range roots {
		ms := byRoot[r]
		if len(ms) < 2 {
			continue
		}
		rep := ""
		for _, m := range ms {
			if e := entries[b.variants[m].key]; strings.TrimSpace(e.Lyrics.String()) != "" && !e.Instrumental {
				rep = b.variants[m].key
				break
			}
		}
		if rep == "" {
			continue
		}
		src := entries[rep]
		if manual && !src.ManualLyrics {
			src.ManualLyrics = true
			entries[rep] = src
		}
		fp := songOffsetFingerprint(src.Lyrics.String(), src.LyricsYRC.String())
		n := 0
		for _, m := range ms {
			k := b.variants[m].key
			e := entries[k]
			if k == rep || e.Instrumental || songShareManualOriginal(e) {
				continue
			}
			if !manual && e.Lyrics.Equal(src.Lyrics) && e.LyricsYRC.Equal(src.LyricsYRC) {
				continue
			}
			keep(k, songOwnLyricsEntry(k, e), fp)
			if manual {
				songShareCopyManual(&e, src, rep, now)
			} else {
				songShareCopyPinned(&e, src, rep, now)
			}
			entries[k] = e
			n++
		}
		if n > 0 {
			groups++
			changed += n
		}
	}
	return groups, changed
}

func runSongEntitySyncCheck(src *songEntitySource, w io.Writer) {
	now := time.Now()
	saved := songSharePreOf
	defer func() { songSharePreOf = saved }()
	build := func(cache map[string]enrichEntry) (*songEntityBuild, *songEntityTableFile) {
		s := *src
		s.cache = cache
		b := buildSongEntities(s.variants(songSortedKeys(cache)), s.splits, s.dir)
		return b, b.table(nil, nil, now)
	}
	b0, t0 := build(src.cache)
	fmt.Fprintf(w, "同步不改分组:%d 条写法、%d 首\n", len(b0.variants), len(t0.Songs))
	for _, manual := range []bool{false, true} {
		name := "整组自动同步"
		if manual {
			name = "手改同步"
		}
		cache := maps.Clone(src.cache)
		pres := songSimulatedPres{}
		songSharePreOf = pres.lookup(saved)
		groups, changed := songSimulateShareSync(b0, cache, manual, now, pres.keep)
		_, t1 := build(cache)
		diff := songEntityTableDiff(t0, t1)
		songSharePreOf = func(string, enrichEntry) (enrichEntry, bool) { return enrichEntry{}, false }
		_, naive := build(cache)
		naiveDiff := songEntityTableDiff(t0, naive)
		fmt.Fprintf(w, "  %s:同步了 %d 组、改了 %d 条;重建之后跟同步之前不一样的写法 %d 条(对照:证据看现在那份歌词时 %d 条)\n",
			name, groups, changed, len(diff), len(naiveDiff))
		for _, k := range diff[:min(len(diff), 10)] {
			fmt.Fprintf(w, "    %s\n", k)
		}
		songSharePreOf = saved
	}
}
