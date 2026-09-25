package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// 一次性核查工具:拿本机真实的编目判定缓存,用**当前**判定逻辑(含扩展搜索)对真实 Last.fm
// 从头再判一遍,打出跟缓存里旧结论的差异。只在显式设了 LASTFM_CATALOG_EXT_REPLAY 时跑
// (要打网络、要读本机配置):
//
//	LASTFM_CATALOG_EXT_REPLAY=defer   只回放旧结论是 defer 的(扩展搜索要救的那批)
//	LASTFM_CATALOG_EXT_REPLAY=settled 只回放 keep / match(核对新逻辑有没有改动已有结论)
//
// 不写任何本机文件:判定缓存写进临时目录,MusicBrainz 别名缓存先复制到临时目录再读。
func TestCatalogExtReplayAgainstRealLastfm(t *testing.T) {
	mode := os.Getenv("LASTFM_CATALOG_EXT_REPLAY")
	if mode != "defer" && mode != "settled" {
		t.Skip("set LASTFM_CATALOG_EXT_REPLAY=defer|settled to run")
	}
	home, _ := os.UserHomeDir()
	cfgDir := filepath.Join(home, ".config", "lyrimuse")

	var cfg map[string]any
	readJSON(t, filepath.Join(cfgDir, "config.json"), &cfg)
	apiKey, _ := cfg["lastfm_scrobble_api_key"].(string)
	if apiKey == "" {
		apiKey, _ = cfg["lastfm_api_key"].(string)
	}
	if apiKey == "" {
		t.Fatal("no lastfm api key")
	}

	// 曲长:enrich 缓存键是 "歌手|曲名|专辑"。
	var enrich map[string]struct {
		DurationSecs float64 `json:"duration_secs"`
	}
	readJSON(t, filepath.Join(cfgDir, "lyrimuse-enrich-cache.json"), &enrich)
	durationOf := func(artist, track string) float64 {
		prefix := artist + "|" + track + "|"
		for k, v := range enrich {
			if strings.HasPrefix(k, prefix) && v.DurationSecs > 0 {
				return v.DurationSecs
			}
		}
		return 0
	}

	tmp := t.TempDir()
	if data, err := os.ReadFile(filepath.Join(cfgDir, "lyrimuse-artist-primary-cache.json")); err == nil {
		copyPath := filepath.Join(tmp, "artist-primary-cache.json")
		if err := os.WriteFile(copyPath, data, 0o644); err != nil {
			t.Fatal(err)
		}
		savedCache, savedPath := mbPrimaryNameCache, mbPrimaryNamePath
		t.Cleanup(func() { mbPrimaryNameCache, mbPrimaryNamePath = savedCache, savedPath })
		loadMBPrimaryNameCache(copyPath)
	}

	var old map[string]lastfmCatalogDecision
	readJSON(t, filepath.Join(cfgDir, "lyrimuse-lastfm-catalog.json"), &old)
	// LASTFM_CATALOG_EXT_REPLAY_ONLY="子串1,子串2":只回放缓存键里含其中某个子串的。
	var only []string
	if v := os.Getenv("LASTFM_CATALOG_EXT_REPLAY_ONLY"); v != "" {
		only = strings.Split(v, ",")
	}
	keys := make([]string, 0, len(old))
	for k, d := range old {
		if (mode == "defer") != (d.Verdict == verdictDefer) {
			continue
		}
		if len(only) > 0 && !containsAny(k, only) {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)

	savedPath := lastfmCatalogPath
	t.Cleanup(func() { lastfmCatalogPath = savedPath })
	lastfmCatalogPath = filepath.Join(tmp, "catalog.json")
	col := newLastfmCatalogMatcher(apiKey)

	var changed, same, failed int
	for i, k := range keys {
		artist, track, _ := strings.Cut(k, "\n")
		prev := old[k]
		dur := durationOf(artist, track)
		scope := scopeAll
		switch prev.Scope {
		case "a":
			scope = matchScope{artist: true}
		case "t":
			scope = matchScope{track: true}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		gotA, gotT, _ := col.resolve(ctx, artist, track, dur, scope)
		cancel()
		d, ok := col.cache[k]
		switch {
		case !ok:
			failed++
			fmt.Printf("%3d FAIL     %s / %s\n", i, artist, track)
		case gotA == orDefault(prev.Artist, artist) && gotT == orDefault(prev.Track, track) && d.Verdict == prev.Verdict:
			same++
			if mode == "defer" {
				fmt.Printf("%3d same     %s / %s  (%.0fs) own=%s\n", i, artist, track, dur, d.Own.summary())
			}
		default:
			changed++
			chosen := "-"
			if d.Chosen != nil {
				chosen = d.Chosen.summary()
			}
			fmt.Printf("%3d CHANGED  %s / %s  (%.0fs)\n             %s %q / %q  ->  %s %q / %q  via=%s\n             own=%s chosen=%s\n",
				i, artist, track, dur, prev.Verdict, orDefault(prev.Artist, artist), orDefault(prev.Track, track),
				d.Verdict, gotA, gotT, orDefault(d.Via, "base"), d.Own.summary(), chosen)
		}
		time.Sleep(120 * time.Millisecond)
	}
	fmt.Printf("\n=== %s: %d 首,改变 %d / 不变 %d / 查不成 %d ===\n", mode, len(keys), changed, same, failed)
}

func readJSON(t *testing.T, path string, v any) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
}

func containsAny(s string, subs []string) bool {
	for _, sub := range subs {
		if sub != "" && strings.Contains(s, sub) {
			return true
		}
	}
	return false
}
