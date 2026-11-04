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

// 歌名、专辑自带「|」的 key:紧挨空白的「|」是字段内容;还有歧义时认单曲专辑以歌名开头、专辑为空,都不是按前两个切。
func TestSplitEnrichKeyFieldsWithPipesInFields(t *testing.T) {
	for _, c := range []struct{ artist, title, album string }{
		{"五月天", "入陣曲", "五月天 | 步步 | 自選作品輯 the Best of 1999-2013"},
		{"Someone", "Song | Live at Budokan", "Live Album"},
		{"AFUSIC & Zoha Waseem", "Dil|Coke Studio Nu.WAV", "Dil | Coke Studio Nu.WAV - Single"},
		{"【中文流行歌曲合輯 Chinese Pop Songs Playlist】", "吉星出租 - 暮色回響『神啊』【動態歌詞|Pinyin Lyrics】【PENGUIN MUSIC】", ""},
		{"Shania Yan", "我期待的不是雪 ( Wo Qi Dai De Bu Shi Xue)|Shania Yan Cover", ""},
		{"Someone", "Song", "Album"},
		{"Someone", "Song", ""},
		{"", "Song", ""},
	} {
		key := enrichKey(c.artist, c.title, c.album)
		a, ti, al := splitEnrichKeyFields(key)
		if a != c.artist || ti != c.title || al != c.album {
			t.Errorf("splitEnrichKeyFields(%q) = %q / %q / %q,want %q / %q / %q", key, a, ti, al, c.artist, c.title, c.album)
		}
	}
	// 分不出的照旧按前两个切
	for _, key := range []string{"有声书|001-七星鲁王宫|盗墓笔记|冠声制作", "a|b"} {
		a, ti, al := splitEnrichKeyFields(key)
		wa, wt, wal := splitEnrichKey(key)
		if a != wa || ti != wt || al != wal {
			t.Errorf("splitEnrichKeyFields(%q) = %q / %q / %q,want 同 splitEnrichKey %q / %q / %q", key, a, ti, al, wa, wt, wal)
		}
	}
	if _, title, _ := splitEnrichKeyForSearch(enrichKeyDurationVariant(enrichKey("Shania Yan", "雪|Shania Yan Cover", ""), 2)); title != "雪|Shania Yan Cover" {
		t.Errorf("变体 key 的歌名 = %q", title)
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
