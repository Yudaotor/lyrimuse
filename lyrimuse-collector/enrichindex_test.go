package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func withTempIndexCache(t *testing.T) string {
	t.Helper()
	dir := withTempDecisionCache(t)
	saved := enrichBodyCRCs
	t.Cleanup(func() { enrichBodyCRCs = saved })
	enrichBodyCRCs = nil
	return dir
}

func readBodyForTest(t *testing.T, key string) (enrichBody, os.FileInfo) {
	t.Helper()
	p := filepath.Join(enrichBodiesDir(), decisionSidecarName(key))
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("body for %q: %v", key, err)
	}
	var body enrichBody
	if err := json.Unmarshal(b, &body); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(p)
	return body, info
}

// 保存后:索引没有四块大正文、带 body_crc(主歌词留着);正文小文件的 crc 跟索引一致;主缓存里没有 body_crc。
func TestSaveWritesLeanIndexAndBodies(t *testing.T) {
	withTempIndexCache(t)
	enrichMu.Lock()
	enrichCache["a|t|b"] = enrichEntry{Lyrics: "[00:01.00]hi", LyricsYRC: "[0,100](0,100,0)hi", LyricsTr: "[00:01.00]你好",
		LyricsRoma: "[00:01.00]ni hao", PlainLyrics: "hi", CoverURL: "https://x/c.jpg", TS: 5}
	enrichCache["empty|t|b"] = enrichEntry{TS: 6}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	raw, err := os.ReadFile(enrichIndexPath())
	if err != nil {
		t.Fatal(err)
	}
	for _, big := range []string{"lyrics_yrc", "lyrics_tr", "lyrics_roma", "plain_lyrics"} {
		if strings.Contains(string(raw), big) {
			t.Fatalf("index must not carry %s: %s", big, raw)
		}
	}
	var idx map[string]enrichEntry
	if err := json.Unmarshal(raw, &idx); err != nil {
		t.Fatal(err)
	}
	got := idx["a|t|b"]
	if got.Lyrics != "[00:01.00]hi" || got.CoverURL != "https://x/c.jpg" || got.BodyCRC == 0 {
		t.Fatalf("index entry keeps lyrics + metadata + body_crc, got %+v", got)
	}
	if got.BodyFields != 128|1|2|4|8 {
		t.Fatalf("body_fields = %d", got.BodyFields)
	}
	if idx["empty|t|b"].BodyCRC != 0 || idx["empty|t|b"].BodyFields != 0 {
		t.Fatal("entry without lyrics has no body_crc / body_fields")
	}
	body, _ := readBodyForTest(t, "a|t|b")
	if body.CRC != got.BodyCRC || body.LyricsYRC != "[0,100](0,100,0)hi" || body.LyricsTr != "[00:01.00]你好" || body.PlainLyrics != "hi" {
		t.Fatalf("body = %+v", body)
	}
	if _, err := os.Stat(filepath.Join(enrichBodiesDir(), decisionSidecarName("empty|t|b"))); !os.IsNotExist(err) {
		t.Fatal("no body file for an entry without lyrics")
	}
	// 主缓存跟索引是同一份精简文件(硬链接)。
	mi, _ := os.Stat(enrichPath)
	ii, _ := os.Stat(enrichIndexPath())
	if !os.SameFile(mi, ii) {
		t.Fatal("index must be a hard link to the main cache")
	}
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// App 侧 EnrichCacheSlim.bodyCRC 的 selftest 钉着同一组输入、同样两个值。
func TestEnrichBodyCRCMatchesApp(t *testing.T) {
	full := enrichEntry{Lyrics: "[00:01.00]你好", LyricsTr: "[00:01.00]hello", LyricsRoma: "[00:01.00]ni hao",
		LyricsYRC: "[1000,500](1000,500,0)你好", PlainLyrics: "你好"}
	if got := enrichBodyCRC(full); got != 857489496 {
		t.Fatalf("crc(full) = %d", got)
	}
	if got := enrichBodyCRC(enrichEntry{Lyrics: "[00:01.00]x"}); got != 2260255535 {
		t.Fatalf("crc(lyrics only) = %d", got)
	}
	if got := enrichBodyFields(enrichEntry{Lyrics: "x", LyricsTr: "y"}); got != 128|2 {
		t.Fatalf("fields = %d", got)
	}
}

// 老格式索引(有 body_crc、没有 body_fields)在启动时重写。
func TestRefreshRewritesOutdatedIndex(t *testing.T) {
	withTempIndexCache(t)
	enrichMu.Lock()
	enrichCache["a|t|b"] = enrichEntry{Lyrics: "[00:01.00]one", LyricsTr: "[00:01.00]壹", TS: 1}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if err := os.WriteFile(enrichIndexPath(), []byte(`{"a|t|b":{"lyrics":"[00:01.00]one","body_crc":7}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if !enrichIndexOutdated(enrichIndexPath()) {
		t.Fatal("index without body_fields must be outdated")
	}
	refreshEnrichIndexAtStartup()
	if enrichIndexOutdated(enrichIndexPath()) {
		t.Fatal("index must be rewritten with body_fields")
	}
}

// 正文没变不重写小文件,变了才重写;重启(校验值表清空)后从旧索引种回,不全量重写。
func TestBodiesRewrittenOnlyWhenChanged(t *testing.T) {
	withTempIndexCache(t)
	enrichMu.Lock()
	enrichCache["a|t|b"] = enrichEntry{Lyrics: "[00:01.00]one", TS: 1}
	enrichCache["c|t|d"] = enrichEntry{Lyrics: "[00:01.00]two", TS: 1}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	_, first := readBodyForTest(t, "a|t|b")
	old := time.Now().Add(-time.Hour)
	for _, k := range []string{"a|t|b", "c|t|d"} {
		os.Chtimes(filepath.Join(enrichBodiesDir(), decisionSidecarName(k)), old, old)
	}
	_ = first

	// 只改 c 的正文、并模拟进程重启(校验值表清空,要从磁盘索引种回)。
	enrichBodyCRCs = nil
	enrichMu.Lock()
	e := enrichCache["c|t|d"]
	e.LyricsTr = "[00:01.00]贰"
	enrichCache["c|t|d"] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	_, aInfo := readBodyForTest(t, "a|t|b")
	if !aInfo.ModTime().Equal(old) {
		t.Fatal("unchanged body must not be rewritten (seeded from the on-disk index)")
	}
	cBody, cInfo := readBodyForTest(t, "c|t|d")
	if cInfo.ModTime().Equal(old) || cBody.LyricsTr != "[00:01.00]贰" {
		t.Fatalf("changed body must be rewritten, got %+v", cBody)
	}
}

// 索引被删(App 改过主缓存)→ 启动时重新生成;没有对应条目的正文文件被清掉。
func TestRefreshEnrichIndexAtStartup(t *testing.T) {
	withTempIndexCache(t)
	enrichMu.Lock()
	enrichCache["a|t|b"] = enrichEntry{Lyrics: "[00:01.00]one", TS: 1}
	enrichCache["gone|t|b"] = enrichEntry{Lyrics: "[00:01.00]bye", TS: 1}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	os.Remove(enrichIndexPath())
	enrichMu.Lock()
	delete(enrichCache, "gone|t|b")
	enrichMu.Unlock()

	refreshEnrichIndexAtStartup()
	if _, err := os.Stat(enrichIndexPath()); err != nil {
		t.Fatal("index must be regenerated at startup")
	}
	if _, err := os.Stat(filepath.Join(enrichBodiesDir(), decisionSidecarName("gone|t|b"))); !os.IsNotExist(err) {
		t.Fatal("orphaned body must be swept")
	}
	readBodyForTest(t, "a|t|b")
}
