package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// 对**本机真实 enrich 缓存**跑一遍重挂,只报告不写盘 —— 落地前确认"会改哪些、改成什么样"。
// 用 LYRICTIMELINE_DRYRUN=1 门控,不设置时跳过,不影响日常 go test。
//
//	LYRICTIMELINE_DRYRUN=1 go test -run TestLyricTimelineDryRun -v .
func boolStr(b bool) string {
	if b {
		return "T"
	}
	return "F"
}

func TestLyricTimelineDryRun(t *testing.T) {
	if os.Getenv("LYRICTIMELINE_DRYRUN") == "" {
		t.Skip("LYRICTIMELINE_DRYRUN 未设置,跳过真实缓存 dry-run")
	}
	home, _ := os.UserHomeDir()
	raw, err := os.ReadFile(filepath.Join(home, ".config", "lyrimuse", "lyrimuse-enrich-cache.json"))
	if err != nil {
		t.Skipf("读不到缓存: %v", err)
	}
	var cache map[string]struct {
		Lyrics               string  `json:"lyrics"`
		LyricsTr             string  `json:"lyrics_tr"`
		LyricsRoma           string  `json:"lyrics_roma"`
		LyricsYRC            string  `json:"lyrics_yrc"`
		LyricsSource         string  `json:"lyrics_source"`
		ManualLyrics         bool    `json:"manual_lyrics"`
		DurationSecs         float64 `json:"duration_secs"`
		ResolvedDurationSecs float64 `json:"resolved_duration_secs"`
	}
	if err := json.Unmarshal(raw, &cache); err != nil {
		t.Fatalf("解析缓存: %v", err)
	}
	type hit struct {
		key, src           string
		oldLast, newLast   float64
		trMoved, romaMoved bool
		dur                float64
	}
	var hits []hit
	dual, manual := 0, 0
	bySrc := map[string]int{}
	for k, e := range cache {
		if e.Lyrics == "" || e.LyricsYRC == "" {
			continue
		}
		dual++
		if e.ManualLyrics {
			manual++
			continue
		}
		dur := e.DurationSecs
		if dur <= 0 {
			dur = e.ResolvedDurationSecs
		}
		newLyrics, remap, ok := rehangLRCOnYRC(e.Lyrics, e.LyricsYRC, dur, true)
		if !ok {
			continue
		}
		oldLast, _ := lastLRCTimestampSecs(e.Lyrics)
		newLast, _ := lastLRCTimestampSecs(newLyrics)
		_, trMoved := remapLRCTimestamps(e.LyricsTr, remap)
		_, romaMoved := remapLRCTimestamps(e.LyricsRoma, remap)
		hits = append(hits, hit{k, e.LyricsSource, oldLast, newLast, trMoved, romaMoved, dur})
		bySrc[e.LyricsSource]++
		// 幂等自检:改过的内容再跑一遍必须是空操作,否则每次开机都会重写整份缓存。
		if _, _, again := rehangLRCOnYRC(newLyrics, e.LyricsYRC, dur, true); again {
			t.Errorf("非幂等: %s", k)
		}
	}
	sort.Slice(hits, func(i, j int) bool {
		di := hits[i].newLast - hits[i].oldLast
		dj := hits[j].newLast - hits[j].oldLast
		if di < 0 {
			di = -di
		}
		if dj < 0 {
			dj = -dj
		}
		return di > dj
	})
	t.Logf("双轴条目 %d(其中 manual_lyrics 跳过 %d),会被重挂 %d 条; 按源: %v", dual, manual, len(hits), bySrc)
	better, worse, same := 0, 0, 0
	for _, h := range hits {
		verdict := "曲长未知"
		if h.dur > 0 {
			od, nd := h.oldLast-h.dur, h.newLast-h.dur
			if od < 0 {
				od = -od
			}
			if nd < 0 {
				nd = -nd
			}
			switch {
			case nd < od-0.5:
				verdict, better = "更贴合曲长 ✓", better+1
			case nd > od+0.5:
				verdict, worse = "离曲长更远 ⚠", worse+1
			default:
				verdict, same = "基本不变", same+1
			}
			verdict += " fits " + boolStr(durationFits(h.oldLast, h.dur)) + "→" + boolStr(durationFits(h.newLast, h.dur))
		}
		t.Logf("  末句 %7.2f→%7.2f 曲长%7.2f %-24s tr=%-5v %-11s %s", h.oldLast, h.newLast, h.dur, verdict, h.trMoved, h.src, h.key)
	}
	t.Logf("末句相对曲长: 更贴合 %d / 更远 %d / 基本不变 %d", better, worse, same)
}
