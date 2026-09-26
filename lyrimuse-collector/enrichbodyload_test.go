package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func testFullEnrichEntries() map[string]enrichEntry {
	return map[string]enrichEntry{
		"周杰伦|晴天|叶惠美": {CoverURL: "https://example.com/a.jpg", Lyrics: "[00:01.00]故事的小黄花",
			LyricsTr: "[00:01.00]tr", LyricsRoma: "[00:01.00]roma", LyricsYRC: "[1000,500](1000,500,0)故",
			LyricsSource: "netease", LyricsSourcesSeen: []string{"netease", "qq"},
			LyricsDecision: &lyricsDecision{Path: "first-resolve"}},
		"Coldplay|Yellow|Parachutes": {Lyrics: "[00:02.00]Look at the stars", LyricsSource: "qq"},
		"方大同|手拖手|":                   {PlainLyrics: "纯文本", Unknown: map[string]json.RawMessage{"future": json.RawMessage(`1`)}},
		"Nobody|Instrumental|":       {CoverURL: "https://example.com/b.jpg", Instrumental: true},
	}
}

// writeLeanForTest 按第二步要写的形状写:正文小文件 + 精简条目。
func writeLeanForTest(t *testing.T, full map[string]enrichEntry, dir string) map[string]enrichEntry {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	lean := map[string]enrichEntry{}
	for k, e := range full {
		crc := enrichBodyCRC(e)
		if crc != 0 {
			writeTestBody(t, dir, k, enrichBody{CRC: crc, Lyrics: e.Lyrics, LyricsTr: e.LyricsTr,
				LyricsRoma: e.LyricsRoma, LyricsYRC: e.LyricsYRC, PlainLyrics: e.PlainLyrics})
		}
		lean[k] = leanForIndex(e, crc)
	}
	return lean
}

func writeTestBody(t *testing.T, dir, key string, b enrichBody) {
	t.Helper()
	data, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, decisionSidecarName(key)), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestHydrateEnrichBodiesRoundTrip(t *testing.T) {
	full := testFullEnrichEntries()
	dir := t.TempDir()
	lean := writeLeanForTest(t, full, dir)
	if lean["周杰伦|晴天|叶惠美"].LyricsYRC != "" || lean["周杰伦|晴天|叶惠美"].BodyCRC == 0 {
		t.Fatal("测试前提:精简条目不带逐字、带校验值")
	}
	st := hydrateEnrichBodies(lean, dir)
	if !reflect.DeepEqual(lean, full) {
		t.Errorf("补回正文之后跟完整条目不一致:\n got %#v\nwant %#v", lean, full)
	}
	if st.lean != 3 || st.restored != 3 || st.newer != 0 || st.missing != 0 {
		t.Errorf("stats = %+v", st)
	}
}

func TestHydrateEnrichBodiesLeavesFullEntriesAlone(t *testing.T) {
	full := testFullEnrichEntries()
	dir := t.TempDir()
	// 目录里有一份内容不同的小文件,但条目是完整格式(没有 body_crc):不看小文件。
	writeTestBody(t, dir, "Coldplay|Yellow|Parachutes", enrichBody{CRC: enrichBodyCRC(enrichEntry{Lyrics: "别的"}), Lyrics: "别的"})
	got := testFullEnrichEntries()
	if st := hydrateEnrichBodies(got, dir); st.lean != 0 || !reflect.DeepEqual(got, full) {
		t.Errorf("完整条目被改了: %+v", st)
	}
}

func TestHydrateEnrichBodiesMissingOrDamagedFile(t *testing.T) {
	full := testFullEnrichEntries()
	dir := t.TempDir()
	lean := writeLeanForTest(t, full, dir)
	if err := os.Remove(filepath.Join(dir, decisionSidecarName("周杰伦|晴天|叶惠美"))); err != nil {
		t.Fatal(err)
	}
	// 校验值对不上内容的小文件等于没有。
	writeTestBody(t, dir, "Coldplay|Yellow|Parachutes", enrichBody{CRC: 12345, Lyrics: "被截断的"})
	st := hydrateEnrichBodies(lean, dir)
	if st.missing != 2 || st.restored != 1 {
		t.Errorf("stats = %+v", st)
	}
	jay := lean["周杰伦|晴天|叶惠美"]
	if jay.Lyrics != full["周杰伦|晴天|叶惠美"].Lyrics || jay.LyricsYRC != "" || jay.LyricsTr != "" || jay.BodyCRC != 0 || jay.BodyFields != 0 {
		t.Errorf("小文件缺失时应该只留主缓存里的主歌词、清掉校验值: %#v", jay)
	}
	if got := lean["Coldplay|Yellow|Parachutes"].Lyrics; got != full["Coldplay|Yellow|Parachutes"].Lyrics {
		t.Errorf("损坏的小文件不能顶掉主缓存里的主歌词: %q", got)
	}
}

// 先写正文小文件、再写主缓存,两步之间被打断:小文件是新的,主缓存记的校验值是旧的。用小文件。
func TestHydrateEnrichBodiesPrefersNewerSideFile(t *testing.T) {
	full := testFullEnrichEntries()
	dir := t.TempDir()
	lean := writeLeanForTest(t, full, dir)
	newer := enrichEntry{Lyrics: "[00:02.00]Look at the stars (fixed)", LyricsTr: "[00:02.00]看星星"}
	writeTestBody(t, dir, "Coldplay|Yellow|Parachutes", enrichBody{CRC: enrichBodyCRC(newer), Lyrics: newer.Lyrics, LyricsTr: newer.LyricsTr})
	st := hydrateEnrichBodies(lean, dir)
	if st.newer != 1 {
		t.Errorf("stats = %+v", st)
	}
	if got := lean["Coldplay|Yellow|Parachutes"]; got.Lyrics != newer.Lyrics || got.LyricsTr != newer.LyricsTr {
		t.Errorf("没用更新的那份小文件: %#v", got)
	}
}

// 命令行子命令的只读加载也要补回正文,且不设 enrichPath(不会写盘)。
func TestLoadEnrichCacheReadOnlyHydratesLeanEntries(t *testing.T) {
	oldCache, oldPath := enrichCache, enrichPath
	t.Cleanup(func() { enrichCache, enrichPath = oldCache, oldPath })
	enrichPath = ""

	full := testFullEnrichEntries()
	cfg := t.TempDir()
	path := filepath.Join(cfg, clientName+"-enrich-cache.json")
	lean := writeLeanForTest(t, full, enrichBodiesDirFor(path))
	data, err := json.Marshal(lean)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	loadEnrichCacheReadOnly(path)
	if !reflect.DeepEqual(enrichCache, full) {
		t.Errorf("只读加载没补回正文:\n got %#v", enrichCache)
	}
	if enrichPath != "" {
		t.Error("只读加载不该设 enrichPath")
	}
}
