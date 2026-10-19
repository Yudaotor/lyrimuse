package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 常驻进程的形态:enrichPath 设在临时目录(状态记录跟它放一起),歌词文件夹也是临时的。
func withLyricsFileStateEnv(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	lyrics := filepath.Join(root, "lyrics")
	savedPath, savedDir := enrichPath, lyricsDir()
	enrichPath = filepath.Join(root, "cache.json")
	setLyricsDir(lyrics)
	resetLyricsFileStateForTest()
	t.Cleanup(func() {
		enrichPath = savedPath
		setLyricsDir(savedDir)
		resetLyricsFileStateForTest()
	})
	return lyrics
}

func resetLyricsFileStateForTest() {
	lyricsFileStateMu.Lock()
	lyricsFileStateDir, lyricsFileStateFiles, lyricsFileStateReady, lyricsFileStateTrusted = "", nil, false, false
	lyricsFileStateMu.Unlock()
}

// 把文件内容换掉,但大小和修改时间原样改回去 —— 用来证明「记录一致就不读」这条路真的没读文件。
func tamperKeepingStamp(t *testing.T, path, content string) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(content)) != info.Size() {
		t.Fatalf("替换内容要跟原文件一样长: %d vs %d", len(content), info.Size())
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
}

func TestLyricsFileStateSkipsUnchangedFiles(t *testing.T) {
	dir := withLyricsFileStateEnv(t)
	const keyA, keyB = "歌手甲|歌一|专辑", "歌手乙|歌二|专辑"
	withEnrichCache(t, map[string]enrichEntry{
		keyA: {Lyrics: bt("[00:01.00]aaaa"), LyricsTr: bt("[00:01.00]tr-a"), LyricsSource: "kugou"},
		keyB: {Lyrics: bt("[00:01.00]bbbb"), LyricsSource: "qq"},
	})
	exportLyricsFiles()
	pathA := filepath.Join(dir, sanitizeLyricsFilename(keyA)+".lrc")
	pathB := filepath.Join(dir, sanitizeLyricsFilename(keyB)+".lrc")
	if _, err := os.Stat(lyricsFileStatePath()); err != nil {
		t.Fatalf("全量导出后应落盘状态记录: %v", err)
	}

	// 模拟重启:内存里的记录清掉,从盘上重新读。
	resetLyricsFileStateForTest()
	// A:内容换了、大小与修改时间没变 → 按记录判「没动过」,不读、不采纳。
	origA, _ := os.ReadFile(pathA)
	tamperKeepingStamp(t, pathA, string(origA[:len(origA)-4])+"XXXX")
	// B:用户真的改过(修改时间变了)→ 照常读进来。
	origB, _ := os.ReadFile(pathB)
	edited := string(origB[:len(origB)-4]) + "BBBB"
	if err := os.WriteFile(pathB, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Minute)
	_ = os.Chtimes(pathB, future, future)

	if keys := importLyricsFromFiles(); len(keys) != 1 || keys[0] != keyB {
		t.Fatalf("只有改过的 B 该被采纳,采纳了 %q", keys)
	}
	enrichMu.Lock()
	gotA, gotB := enrichCache[keyA].Lyrics, enrichCache[keyB].Lyrics
	enrichMu.Unlock()
	if !gotA.EqualString("[00:01.00]aaaa") {
		t.Fatalf("A 记录一致、不该读: %q", gotA)
	}
	if !gotB.EqualString("[00:01.00]BBBB") {
		t.Fatalf("B 改过、该读进来: %q", gotB)
	}

	// 导出:A 的内容没变、文件记录一致 → 不读不写(被换掉的内容原样留着,证明确实没碰它)。
	exportLyricsFiles()
	if cur, _ := os.ReadFile(pathA); string(cur) == string(origA) {
		t.Fatal("A 记录一致、内容也没变,导出不该重写它")
	}
	// A 的译文删掉:对应的 .tr.lrc 要删,记录也要清。
	enrichMu.Lock()
	e := enrichCache[keyA]
	e.LyricsTr = bodyText{}
	e.Lyrics = bt("[00:01.00]aaab") // 内容变了:要重写
	enrichCache[keyA] = e
	enrichMu.Unlock()
	exportLyricsFiles()
	trPath := filepath.Join(dir, sanitizeLyricsFilename(keyA)+".tr.lrc")
	if _, err := os.Stat(trPath); !os.IsNotExist(err) {
		t.Fatalf("译文清空后 .tr.lrc 应被删掉: %v", err)
	}
	if cur, _ := os.ReadFile(pathA); string(cur) == string(origA) || len(cur) == 0 {
		t.Fatalf("A 内容变了应重写: %q", cur)
	}
	lyricsFileStateMu.Lock()
	_, stale := lyricsFileStateFiles[filepath.Base(trPath)]
	lyricsFileStateMu.Unlock()
	if stale {
		t.Fatal("删掉的文件不该还在记录里")
	}
}

// 目录里的文件名是分解写法(NFD)时,内容没变的文件照样不重写:不然每次启动修改时间都刷成最新。
func TestLyricsExportSkipsUnchangedDecomposedFilenames(t *testing.T) {
	dir := withLyricsFileStateEnv(t)
	const key = "Gareth.T|碧麗宮|THE PROT\u00c9G\u00c9"
	withEnrichCache(t, map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]bik1 lai6"), LyricsSource: "kugou"}})
	exportLyricsFiles()
	composed := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")
	decomposed := filepath.Join(dir, sanitizeLyricsFilename("Gareth.T|碧麗宮|THE PROTE\u0301GE\u0301")+".lrc")
	if err := os.Rename(composed, decomposed); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(decomposed, old, old); err != nil {
		t.Fatal(err)
	}
	if _, ok := listLyricsDir(dir)[filepath.Base(composed)]; !ok {
		t.Fatal("目录列表要能按 NFC 名字查到分解写法的文件")
	}

	// 模拟重启:内存记录清掉,导入再全量导出。
	resetLyricsFileStateForTest()
	importLyricsFromFiles()
	exportLyricsFiles()
	info, err := os.Stat(composed)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(old) {
		t.Fatalf("内容没变的分解写法文件不该被重写,修改时间从 %v 变成了 %v", old, info.ModTime())
	}
}

// 记录是按歌词文件夹区分的:换了文件夹,旧记录一概不认,全量读。
func TestLyricsFileStateIgnoredForOtherDir(t *testing.T) {
	dir := withLyricsFileStateEnv(t)
	const key = "歌手甲|歌一|专辑"
	withEnrichCache(t, map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]aaaa")}})
	exportLyricsFiles()
	path := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")

	other := filepath.Join(filepath.Dir(dir), "lyrics2")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.ReadFile(path)
	info, _ := os.Stat(path)
	copied := filepath.Join(other, filepath.Base(path))
	tampered := string(orig[:len(orig)-4]) + "ZZZZ"
	if err := os.WriteFile(copied, []byte(tampered), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = os.Chtimes(copied, info.ModTime(), info.ModTime()) // 大小、修改时间都跟原文件夹的记录一样
	resetLyricsFileStateForTest()
	if n := len(importLyricsFromDir(other)); n != 1 {
		t.Fatalf("另一个文件夹不该用这边的记录,应读进来并采纳,采纳了 %d 条", n)
	}
}

// 没有 enrichPath(一次性 CLI、单测默认形态)时不读不写记录,导入导出照旧全量比对。
func TestLyricsFileStateDisabledWithoutEnrichPath(t *testing.T) {
	savedPath := enrichPath
	enrichPath = ""
	resetLyricsFileStateForTest()
	t.Cleanup(func() { enrichPath = savedPath; resetLyricsFileStateForTest() })
	if lyricsFileStateEnabled(t.TempDir()) || lyricsFileStatePath() != "" {
		t.Fatal("没有 enrichPath 时不该启用")
	}
}

// 文件里的正文或来源被改过、采纳进来:「现用歌词出处」说的是改之前那一份,清掉;没动过的那条留着。见 11 章决策 136。
func TestLyricsImportDropsStaleAppliedDecision(t *testing.T) {
	dir := withLyricsFileStateEnv(t)
	const kept, body, source = "歌手甲|歌一|专辑", "歌手乙|歌二|专辑", "歌手丙|歌三|专辑"
	applied := func(src string) *lyricsDecision {
		return &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: src, Applied: true}
	}
	withEnrichCache(t, map[string]enrichEntry{
		kept:   {Lyrics: bt("[00:01.00]aaaa"), LyricsSource: "kugou", LyricsDecisionApplied: applied("kugou")},
		body:   {Lyrics: bt("[00:01.00]bbbb"), LyricsSource: "qq", LyricsDecisionApplied: applied("qq")},
		source: {Lyrics: bt("[00:01.00]cccc"), LyricsSource: "qq", LyricsDecisionApplied: applied("qq")},
	})
	exportLyricsFiles()
	resetLyricsFileStateForTest()
	edit := func(key string, change func(string) string) {
		t.Helper()
		path := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")
		orig, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(change(string(orig))), 0o644); err != nil {
			t.Fatal(err)
		}
		future := time.Now().Add(time.Minute)
		_ = os.Chtimes(path, future, future)
	}
	edit(body, func(s string) string { return strings.Replace(s, "bbbb", "BBBB", 1) })
	edit(source, func(s string) string { return strings.Replace(s, "[source:qq]", "[source:netease]", 1) })
	importLyricsFromFiles()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if d := enrichCache[kept].LyricsDecisionApplied; d == nil || d.Winner != "kugou" {
		t.Fatalf("没动过的那条出处不该动,得到 %+v", d)
	}
	if e := enrichCache[body]; !e.Lyrics.EqualString("[00:01.00]BBBB") || e.LyricsDecisionApplied != nil {
		t.Fatalf("正文被文件换了:采纳新正文、清掉出处,得到 %q %+v", e.Lyrics.String(), e.LyricsDecisionApplied)
	}
	if e := enrichCache[source]; e.LyricsSource != "netease" || e.LyricsDecisionApplied != nil {
		t.Fatalf("来源被文件换了:采纳新来源、清掉出处,得到 %q %+v", e.LyricsSource, e.LyricsDecisionApplied)
	}
}

// 存量迁移:出处的胜者跟现用来源对不上的清掉;对得上的、手改的、用户选定来源的、手改副本、纯音乐都不动。见 11 章决策 136。
func TestMigrateStaleAppliedDecisions(t *testing.T) {
	applied := func(src string) *lyricsDecision {
		return &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: src, Applied: true}
	}
	lrc := bt("[00:01.00]aaaa")
	withEnrichCache(t, map[string]enrichEntry{
		"stale":        {Lyrics: lrc, LyricsSource: "kugou", LyricsDecisionApplied: applied("musixmatch")},
		"consistent":   {Lyrics: lrc, LyricsSource: "kugou", LyricsDecisionApplied: applied("kugou")},
		"manual":       {Lyrics: lrc, LyricsSource: "kugou", ManualLyrics: true, LyricsDecisionApplied: applied("qq")},
		"choice":       {Lyrics: lrc, LyricsSource: "kugou", LyricsSourceChoice: "kugou", LyricsDecisionApplied: applied("qq")},
		"origin":       {Lyrics: lrc, LyricsSource: "kugou", LyricsEntityOrigin: "a|b|c", LyricsDecisionApplied: applied("qq")},
		"instrumental": {Lyrics: lrc, LyricsSource: "kugou", Instrumental: true, LyricsDecisionApplied: applied("qq")},
	})
	migrateStaleAppliedDecisions()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for k, e := range enrichCache {
		if cleared, want := e.LyricsDecisionApplied == nil, k == "stale"; cleared != want {
			t.Errorf("%s: 出处清掉=%v,应为 %v", k, cleared, want)
		}
	}
}
