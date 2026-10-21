package main

import (
	"context"
	"strings"
	"sync"
	"testing"
)

func TestSplitEnrichKeyForSearch(t *testing.T) {
	for _, c := range []struct{ key, title string }{
		{enrichKeyDurationVariant(enrichKey("Someone", "Song", "Album"), 2), "Song"},
		{enrichKey("Someone", "Song", "Album"), "Song"},
		{enrichKey("Someone", "~dur2", "Album"), "~dur2"},
	} {
		artist, title, album := splitEnrichKeyForSearch(c.key)
		if title != c.title {
			t.Errorf("splitEnrichKeyForSearch(%q) 歌名 = %q,want %q", c.key, title, c.title)
		}
		a, _, b := splitEnrichKey(c.key)
		if artist != a || album != b {
			t.Errorf("splitEnrichKeyForSearch(%q) 歌手 / 专辑 = %q / %q,want %q / %q", c.key, artist, album, a, b)
		}
	}
}

// 补空扫描、全量扫库、手动重新匹配按「~durN」变体 key 重搜:搜的歌名不带标记,写回的是变体那一条,基条目不凭空长出来。
func TestBackgroundResearchSearchesVariantKeyWithoutMarker(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	var mu sync.Mutex
	var searched []string
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		mu.Lock()
		searched = append(searched, title)
		mu.Unlock()
		return musixmatchResult{lrc: rescoreTestNewBody, title: title, artist: artist, durationSecs: 180}
	}
	const old = "[00:05.00]Old line one\n[00:15.00]Old line two"
	for _, c := range []struct {
		name, title string
		entry       enrichEntry
		run         func(key string)
	}{
		{"补空扫描", "Fill Song", enrichEntry{DurationSecs: 180}, func(key string) { lyricsFillSweepOne(context.Background(), key) }},
		{"全量扫库", "Scan Song", enrichEntry{Lyrics: bt(old), LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1, DurationSecs: 180},
			func(key string) { lyricsFullScanOne(context.Background(), key) }},
		{"手动重新匹配", "Rematch Song", enrichEntry{Lyrics: bt(old), LyricsSource: "musixmatch", DurationSecs: 180},
			func(key string) { runLyricsRematchOne(context.Background(), key, nil) }},
	} {
		base := enrichKey(rescoreTestArtist, c.title, "Some Album")
		key := enrichKeyDurationVariant(base, 2)
		enrichMu.Lock()
		enrichCache = map[string]enrichEntry{key: c.entry}
		enrichMu.Unlock()
		mu.Lock()
		searched = nil
		mu.Unlock()
		c.run(key)
		mu.Lock()
		got := append([]string(nil), searched...)
		mu.Unlock()
		if len(got) == 0 {
			t.Errorf("%s:没发搜索", c.name)
		}
		for _, s := range got {
			if strings.Contains(s, "~dur") || s != c.title {
				t.Errorf("%s:搜的歌名 %q,want %q", c.name, s, c.title)
			}
		}
		enrichMu.Lock()
		after := enrichCache[key]
		_, hasBase := enrichCache[base]
		enrichMu.Unlock()
		if !after.Lyrics.EqualString(rescoreTestNewBody) {
			t.Errorf("%s:变体条目没换上新词:%q", c.name, after.Lyrics)
		}
		if hasBase {
			t.Errorf("%s:不该写出基条目", c.name)
		}
	}
}
