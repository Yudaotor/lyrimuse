package main

import (
	"encoding/json"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
)

func withExportFixture(t *testing.T, cache map[string]enrichEntry) string {
	t.Helper()
	dir := t.TempDir()
	savedDir, savedCache := lyricsDir(), enrichCache
	t.Cleanup(func() {
		enrichMu.Lock()
		setLyricsDir(savedDir)
		enrichCache = savedCache
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	setLyricsDir(dir)
	enrichCache = cache
	enrichMu.Unlock()
	return dir
}

func dirContents(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		out[e.Name()] = string(b)
	}
	return out
}

func exportFixtureCache() map[string]enrichEntry {
	return map[string]enrichEntry{
		"歌手|歌名|专辑":          {Lyrics: "[00:01.00]a", LyricsTr: "[00:01.00]译", LyricsSource: "qq"},
		"Artist|Song|Album": {Lyrics: "[00:01.00]b", LyricsYRC: "{}", LyricsSource: "netease"},
		// 大小写折叠后撞名的一对,两条都要落到带哈希后缀的文件名上。
		"artist|song|album": {Lyrics: "[00:01.00]c", LyricsSource: "kugou"},
		"没歌词|x|y":           {},
	}
}

func TestExportLyricsFilesForMatchesFullExport(t *testing.T) {
	fullDir := withExportFixture(t, exportFixtureCache())
	exportLyricsFiles()
	full := dirContents(t, fullDir)

	incDir := withExportFixture(t, exportFixtureCache())
	for k := range exportFixtureCache() {
		exportLyricsFilesFor(k)
	}
	inc := dirContents(t, incDir)

	if len(full) == 0 {
		t.Fatal("前提:全量导出应产出文件")
	}
	names := func(m map[string]string) []string {
		var s []string
		for k := range m {
			s = append(s, k)
		}
		sort.Strings(s)
		return s
	}
	if fmt.Sprint(names(full)) != fmt.Sprint(names(inc)) {
		t.Fatalf("文件集合不同:\n全量 %v\n增量 %v", names(full), names(inc))
	}
	for name, body := range full {
		if inc[name] != body {
			t.Errorf("%s 内容不同", name)
		}
	}
}

func TestExportLyricsFilesForLeavesOtherEntriesAlone(t *testing.T) {
	dir := withExportFixture(t, exportFixtureCache())
	exportLyricsFiles()
	other := filepath.Join(dir, "歌手 - 歌名 - 专辑.lrc")
	if err := os.WriteFile(other, []byte("手动改过"), 0o644); err != nil {
		t.Fatal(err)
	}
	exportLyricsFilesFor("Artist|Song|Album")
	if b, _ := os.ReadFile(other); string(b) != "手动改过" {
		t.Fatalf("只导出别的条目时不该碰这个文件,实际内容 %q", b)
	}
}

func TestExportLyricsFilesForRenamesWholeCollisionGroup(t *testing.T) {
	cache := map[string]enrichEntry{"Artist|Song|Album": {Lyrics: "[00:01.00]b", LyricsSource: "netease"}}
	dir := withExportFixture(t, cache)
	exportLyricsFiles()
	plain := filepath.Join(dir, "Artist - Song - Album.lrc")
	if _, err := os.Stat(plain); err != nil {
		t.Fatalf("前提:单条时应导出无后缀文件: %v", err)
	}

	enrichMu.Lock()
	enrichCache["artist|song|album"] = enrichEntry{Lyrics: "[00:01.00]c", LyricsSource: "kugou"}
	enrichMu.Unlock()
	exportLyricsFilesFor("artist|song|album")

	if _, err := os.Stat(plain); !os.IsNotExist(err) {
		t.Fatalf("撞名后原来的无后缀文件应被删掉, err=%v", err)
	}
	got := dirContents(t, dir)
	if len(got) != 2 {
		t.Fatalf("两条都应落到带哈希后缀的文件名上,实际 %v", got)
	}
	for _, key := range []string{"Artist|Song|Album", "artist|song|album"} {
		sum := crc32.ChecksumIEEE([]byte(key))
		name := fmt.Sprintf("%s~%06x.lrc", sanitizeLyricsFilename(key), sum&0xFFFFFF)
		if _, ok := got[name]; !ok {
			t.Errorf("缺 %s,实际 %v", name, got)
		}
	}
}

// 锁外 marshal 与并发替换条目同时进行:-race 下不应报竞态,落盘结果应是某个完整快照。
func TestSaveEnrichCacheConcurrentWithCommits(t *testing.T) {
	dir := t.TempDir()
	savedPath, savedCache, savedDirty := enrichPath, enrichCache, enrichDirty
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPath, enrichCache, enrichDirty = savedPath, savedCache, savedDirty
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	enrichPath = filepath.Join(dir, "cache.json")
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()

	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				e := enrichEntry{Lyrics: fmt.Sprintf("[00:01.00]%d-%d", w, i)}
				e.LyricsDecision = &lyricsDecision{Winner: "qq"}
				e.LyricsDecisionApplied = e.LyricsDecision
				enrichMu.Lock()
				enrichCache[fmt.Sprintf("a%d|t%d|b", w, i%7)] = e
				enrichDirty = true
				enrichMu.Unlock()
				saveEnrichCache()
			}
		}(w)
	}
	wg.Wait()
	saveEnrichCache()

	b, err := os.ReadFile(enrichPath)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("落盘文件应是完整 JSON: %v", err)
	}
	if len(m) != 28 {
		t.Fatalf("最后一次落盘应包含全部 28 个键,实际 %d", len(m))
	}
}
