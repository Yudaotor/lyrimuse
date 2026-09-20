package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// 一次性核查工具:拿真实的 enrich 缓存跑真实的 Last.fm,看编目匹配会把哪些歌改写成什么。
// 只在显式设了 LASTFM_CATALOG_AUDIT=1 时跑(要打网络、要读本机配置)。
func TestCatalogAuditAgainstRealLastfm(t *testing.T) {
	if os.Getenv("LASTFM_CATALOG_AUDIT") != "1" {
		t.Skip("set LASTFM_CATALOG_AUDIT=1 to run")
	}
	home, _ := os.UserHomeDir()
	cfgDir := filepath.Join(home, ".config", "lyrimuse")

	var cfg map[string]any
	raw, err := os.ReadFile(filepath.Join(cfgDir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	apiKey, _ := cfg["lastfm_api_key"].(string)
	if apiKey == "" {
		t.Fatal("no lastfm_api_key")
	}

	var cache map[string]struct {
		DurationSecs float64 `json:"duration_secs"`
	}
	raw, err = os.ReadFile(filepath.Join(cfgDir, "lyrimuse-enrich-cache.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &cache); err != nil {
		t.Fatal(err)
	}

	type sample struct {
		artist, title string
		duration      float64
	}
	var all []sample
	for key, v := range cache {
		parts := strings.Split(key, "|")
		if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
			continue
		}
		all = append(all, sample{artist: parts[0], title: parts[1], duration: v.DurationSecs})
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].artist != all[j].artist {
			return all[i].artist < all[j].artist
		}
		return all[i].title < all[j].title
	})
	rand.New(rand.NewSource(20260920)).Shuffle(len(all), func(i, j int) { all[i], all[j] = all[j], all[i] })

	// 只查一首:LASTFM_CATALOG_AUDIT_ONE="歌手|曲名|曲长秒"。
	if one := os.Getenv("LASTFM_CATALOG_AUDIT_ONE"); one != "" {
		f := strings.Split(one, "|")
		if len(f) < 2 {
			t.Fatalf("格式应为 歌手|曲名|曲长秒,got %q", one)
		}
		var dur float64
		if len(f) > 2 {
			fmt.Sscanf(f[2], "%f", &dur)
		}
		all = []sample{{artist: f[0], title: f[1], duration: dur}}
	}

	n := 60
	if v := os.Getenv("LASTFM_CATALOG_AUDIT_N"); v != "" {
		fmt.Sscanf(v, "%d", &n)
	}
	if n > len(all) {
		n = len(all)
	}

	saved := lastfmCatalogPath
	t.Cleanup(func() { lastfmCatalogPath = saved })
	lastfmCatalogPath = filepath.Join(t.TempDir(), "audit.json")

	col := newLastfmCatalogMatcher(apiKey)
	if col == nil {
		t.Fatal("matcher nil")
	}

	var rewrote, kept, deferred, failed int
	for i, s := range all[:n] {
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		gotArtist, gotTrack, _ := col.resolve(ctx, s.artist, s.title, s.duration, scopeAll)
		cancel()
		d, cached := col.cache[strings.TrimSpace(s.artist)+"\n"+strings.TrimSpace(s.title)]
		switch {
		case !cached:
			failed++
			fmt.Printf("%3d FAIL   %s / %s\n", i, s.artist, s.title)
		case d.Verdict == verdictMatch:
			rewrote++
			fmt.Printf("%3d REWRITE %s / %s  (%.0fs)\n           -> %s / %s   own=%s chosen=%s\n",
				i, s.artist, s.title, s.duration, gotArtist, gotTrack, d.Own.summary(), d.Chosen.summary())
		case d.Verdict == verdictKeep:
			kept++
			fmt.Printf("%3d keep   %s / %s   %s\n", i, s.artist, s.title, d.Own.summary())
		default:
			deferred++
			fmt.Printf("%3d defer  %s / %s   %s\n", i, s.artist, s.title, d.Own.summary())
		}
		time.Sleep(150 * time.Millisecond)
	}
	fmt.Printf("\n=== %d 首:改写 %d / 原样 %d / 判不了 %d / 查不成 %d ===\n", n, rewrote, kept, deferred, failed)
}
