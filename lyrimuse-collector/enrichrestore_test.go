package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// 写一份待采纳文件到临时目录,返回路径。fields 是 key → 字段名 → 已经是 JSON 的值。
func writeRestoreFile(t *testing.T, dir string, blob map[string]map[string]any) string {
	t.Helper()
	data, err := json.Marshal(blob)
	if err != nil {
		t.Fatalf("marshal restore blob: %v", err)
	}
	path := filepath.Join(dir, "lyrimuse-enrich-restore.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write restore file: %v", err)
	}
	return path
}

func resetEnrichForRestoreTest(t *testing.T, dir string) {
	t.Helper()
	saved, savedPath, savedDirty := enrichCache, enrichPath, enrichDirty
	t.Cleanup(func() { enrichCache, enrichPath, enrichDirty = saved, savedPath, savedDirty })
	enrichCache = map[string]enrichEntry{}
	enrichPath = filepath.Join(dir, "lyrimuse-enrich-cache.json")
	enrichDirty = false
}

// 全新机器那条路径:缓存里压根没有这个 key,备份里的字段应该原样建出来。
func TestAdoptEnrichRestoreCreatesMissingEntries(t *testing.T) {
	dir := t.TempDir()
	resetEnrichForRestoreTest(t, dir)
	path := writeRestoreFile(t, dir, map[string]map[string]any{
		"周杰伦|枫|十一月的萧邦": {
			// lyrics_decision 是嵌套对象(见 decision.go 的 lyricsDecision),整块搬运。
			"lyrics_decision": map[string]any{
				"path":              "rescore",
				"scoring_version":   9,
				"winner":            "netease",
				"applied":           true,
				"sources_responded": []string{"netease", "qq", "kugou"},
			},
			"lyrics_scoring_version": 9,
			"canonical_artist":       "周杰伦",
			"cover_url":              "https://example.invalid/a.jpg",
			"plain_lyrics":           "没有时间戳的纯文本",
		},
	})

	adoptEnrichRestore(path)

	e, ok := enrichCache["周杰伦|枫|十一月的萧邦"]
	if !ok {
		t.Fatal("备份里的条目应该被新建出来")
	}
	// 决策存档是历史快照、重新解析只会写一份今天的 —— 这是这次修复最核心的那一类。
	if e.LyricsDecision == nil {
		t.Fatal("LyricsDecision 应该被搬过来")
	}
	if e.LyricsDecision.Winner != "netease" || e.LyricsDecision.Path != "rescore" {
		t.Errorf("LyricsDecision = %+v, want winner=netease path=rescore", *e.LyricsDecision)
	}
	if len(e.LyricsDecision.SourcesResponded) != 3 {
		t.Errorf("嵌套数组也要完整搬过来, SourcesResponded = %v", e.LyricsDecision.SourcesResponded)
	}
	// 这一项是这次修复的核心动机之一:丢了会让全库排进"按新规则重选"的队列。
	if e.LyricsScoringVersion != 9 {
		t.Errorf("LyricsScoringVersion = %d, want 9", e.LyricsScoringVersion)
	}
	if e.CanonicalArtist != "周杰伦" {
		t.Errorf("CanonicalArtist = %q, want 周杰伦", e.CanonicalArtist)
	}
	// plain_lyrics 此前不在任何备份里(没有对应的导出文件),必须跟着 meta 走。
	if e.PlainLyrics != "没有时间戳的纯文本" {
		t.Errorf("PlainLyrics = %q, want 没有时间戳的纯文本", e.PlainLyrics)
	}
	if !enrichDirty && !fileExistsForTest(enrichPath) {
		t.Error("采纳之后应该标脏或者已经落盘")
	}
}

// 合并粒度必须是字段级:备份里没有的字段(尤其六个歌词字段)不许把本机的值清掉。
func TestAdoptEnrichRestoreKeepsFieldsAbsentFromBackup(t *testing.T) {
	dir := t.TempDir()
	resetEnrichForRestoreTest(t, dir)
	const key = "方大同|特别的人|危险世界"
	// 本机这条已经有歌词(importLyricsFromFiles 灌进来的那种),还有一个备份里没有的字段。
	enrichCache[key] = enrichEntry{
		Lyrics:       "[00:01.00]本机正文",
		LyricsYRC:    "本机逐字",
		LyricsSource: "kugou",
		ManualLyrics: true,
		SpotifyURL:   "https://example.invalid/only-local",
	}
	path := writeRestoreFile(t, dir, map[string]map[string]any{
		key: {
			"lyrics_decision":  map[string]any{"winner": "kugou", "path": "first-resolve"},
			"canonical_artist": "方大同",
		},
	})

	adoptEnrichRestore(path)

	e := enrichCache[key]
	// 备份里有的赢。
	if e.LyricsDecision == nil || e.LyricsDecision.Winner != "kugou" {
		t.Errorf("LyricsDecision 没被搬过来: %+v", e.LyricsDecision)
	}
	if e.CanonicalArtist != "方大同" {
		t.Errorf("CanonicalArtist = %q, want 方大同", e.CanonicalArtist)
	}
	// 备份里没有的一个都不许动 —— 六个歌词字段的权威源是 lyrics/ 文件族。
	if e.Lyrics != "[00:01.00]本机正文" {
		t.Errorf("Lyrics 被动过: %q", e.Lyrics)
	}
	if e.LyricsYRC != "本机逐字" {
		t.Errorf("LyricsYRC 被动过: %q", e.LyricsYRC)
	}
	if e.LyricsSource != "kugou" {
		t.Errorf("LyricsSource 被动过: %q", e.LyricsSource)
	}
	if !e.ManualLyrics {
		t.Error("ManualLyrics 被动过,应该保持 true")
	}
	// 本机自己解析出来、备份里没有的东西也不该被抹掉。
	if e.SpotifyURL != "https://example.invalid/only-local" {
		t.Errorf("SpotifyURL 被抹掉了: %q", e.SpotifyURL)
	}
}

// 采纳成功要改名,而且不能被下一次启动重复采纳。
func TestAdoptEnrichRestoreRenamesAfterSuccess(t *testing.T) {
	dir := t.TempDir()
	resetEnrichForRestoreTest(t, dir)
	path := writeRestoreFile(t, dir, map[string]map[string]any{
		"a|b|c": {"canonical_artist": "A"},
	})

	adoptEnrichRestore(path)

	if fileExistsForTest(path) {
		t.Error("采纳成功之后原文件不该还在(会被下次启动重复采纳)")
	}
	if !fileExistsForTest(path + enrichRestoreSuffix) {
		t.Error("应该改名成 .applied 留一条人工找回的路,而不是直接删掉")
	}
	// 再跑一次:文件已经不在了,应该完全无操作、不 panic。
	// (enrichEntry 含切片字段、不能直接 != 比较,挑一个标量字段看就够。)
	before := enrichCache["a|b|c"].CanonicalArtist
	adoptEnrichRestore(path)
	if got := enrichCache["a|b|c"].CanonicalArtist; got != before {
		t.Errorf("文件不存在时不该改动缓存, CanonicalArtist = %q, want %q", got, before)
	}
}

// 解不出来的文件:原样留着(那是用户搬家时唯一一份决策数据),缓存一个字节都不许动。
func TestAdoptEnrichRestoreKeepsUnparseableFile(t *testing.T) {
	dir := t.TempDir()
	resetEnrichForRestoreTest(t, dir)
	enrichCache["keep|me|intact"] = enrichEntry{CanonicalArtist: "原值"}
	path := filepath.Join(dir, "lyrimuse-enrich-restore.json")
	if err := os.WriteFile(path, []byte("{ 这不是 JSON"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	adoptEnrichRestore(path)

	if !fileExistsForTest(path) {
		t.Error("解析失败时不该删掉/改名这份文件")
	}
	if e := enrichCache["keep|me|intact"]; e.CanonicalArtist != "原值" {
		t.Errorf("解析失败时缓存不该被改动,CanonicalArtist = %q", e.CanonicalArtist)
	}
	if len(enrichCache) != 1 {
		t.Errorf("解析失败时不该新建条目,len(enrichCache) = %d", len(enrichCache))
	}
}

// 空 key / 空字段表要跳过,不能在缓存里留下垃圾条目。
func TestAdoptEnrichRestoreSkipsEmpty(t *testing.T) {
	dir := t.TempDir()
	resetEnrichForRestoreTest(t, dir)
	path := writeRestoreFile(t, dir, map[string]map[string]any{
		"":      {"canonical_artist": "空 key"},
		"a|b|c": {},
		"good":  {"canonical_artist": "留下"},
	})

	adoptEnrichRestore(path)

	if _, ok := enrichCache[""]; ok {
		t.Error("空 key 不该进缓存")
	}
	if _, ok := enrichCache["a|b|c"]; ok {
		t.Error("字段表为空的条目不该进缓存")
	}
	if e := enrichCache["good"]; e.CanonicalArtist != "留下" {
		t.Errorf("正常条目应该照常采纳,got %q", e.CanonicalArtist)
	}
}

func fileExistsForTest(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
