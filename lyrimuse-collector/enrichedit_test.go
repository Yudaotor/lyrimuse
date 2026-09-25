package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setUpEnrichEditTest 准备一个临时配置目录(缓存、歌词目录、废纸篓),测试结束全部还原。
func setUpEnrichEditTest(t *testing.T, entries map[string]enrichEntry) (lyrics, trash string) {
	t.Helper()
	resetFeaturesForTest(t)
	setFeatures(featureFlags{})
	root := t.TempDir()
	home := filepath.Join(root, "home")
	trash = filepath.Join(home, ".Trash")
	if err := os.MkdirAll(trash, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	lyrics = filepath.Join(root, "lyrics")
	if err := os.MkdirAll(lyrics, 0o755); err != nil {
		t.Fatal(err)
	}
	savedDir, savedCache, savedPath, savedDirty := lyricsDir(), enrichCache, enrichPath, enrichDirty
	savedEditDir, savedRestore := enrichEditDir, enrichRestorePath
	t.Cleanup(func() {
		enrichMu.Lock()
		setLyricsDir(savedDir)
		enrichCache, enrichPath, enrichDirty = savedCache, savedPath, savedDirty
		enrichMu.Unlock()
		enrichEditDir, enrichRestorePath = savedEditDir, savedRestore
	})
	enrichMu.Lock()
	setLyricsDir(lyrics)
	enrichCache = entries
	enrichPath = filepath.Join(root, "enrich-cache.json")
	enrichMu.Unlock()
	return lyrics, trash
}

func cacheEntry(t *testing.T, key string) (enrichEntry, bool) {
	t.Helper()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	e, ok := enrichCache[key]
	return e, ok
}

func strPtr(s string) *string { return &s }
func intPtr(n int) *int       { return &n }

var editKey = enrichKey("Edit Artist", "Edit Song", "Edit Album")

func TestSaveEditClearsTranslationBookkeepingWhenTranslationChanges(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {
		Lyrics: "[00:01.00]old", LyricsTr: "[00:01.00]旧译文", LyricsTrLang: "en", LyricsTrSource: "machine",
		TranslationTS: 123, TranslationRetryCount: 2,
	}})
	res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]old", Tr: "[00:01.00]新译文"})
	if !res.OK {
		t.Fatalf("res=%+v", res)
	}
	e, _ := cacheEntry(t, editKey)
	if e.LyricsTrLang != "" || e.LyricsTrSource != "" || e.TranslationTS != 0 || e.TranslationRetryCount != 0 {
		t.Errorf("换了译文,描述旧译文的四个字段应清掉 got %+v", e)
	}

	e.LyricsTrLang = "zh"
	enrichMu.Lock()
	enrichCache[editKey] = e
	enrichMu.Unlock()
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]changed", Tr: "[00:01.00]新译文"})
	if e, _ := cacheEntry(t, editKey); e.LyricsTrLang != "zh" {
		t.Errorf("译文没变就不该清译文语言 got %q", e.LyricsTrLang)
	}
}

func TestSaveEditDropsRomanizationThatDescribesOldLyrics(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {Lyrics: "[00:01.00]旧", LyricsRoma: "[00:01.00]kyu"}})
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]新", Roma: "[00:01.00]kyu"})
	if e, _ := cacheEntry(t, editKey); e.LyricsRoma != "" {
		t.Errorf("正文改了、罗马音原样交回,应清掉 got %q", e.LyricsRoma)
	}
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]再改", Roma: "[00:01.00]mine"})
	if e, _ := cacheEntry(t, editKey); e.LyricsRoma != "[00:01.00]mine" {
		t.Errorf("用户自己改了罗马音就照他的来 got %q", e.LyricsRoma)
	}
}

func TestSaveEditOptionalFields(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {
		Lyrics: "[00:01.00]x", LyricsYRC: "yrc-old", LyricsSourceChoice: "qq", LyricsScore: 5, LyricsScoringVersion: 3,
		LyricsSource: "qq", ManualPickSHA: "abc",
	}})
	// 可选字段都不传:source_choice / yrc / 打分都不动;source 为空 = 清掉;指纹清掉。
	applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]y", MarkManual: true})
	e, _ := cacheEntry(t, editKey)
	if e.LyricsSourceChoice != "qq" || e.LyricsYRC != "yrc-old" || e.LyricsScore != 5 || e.LyricsScoringVersion != 3 {
		t.Errorf("没传的可选字段不该动 got %+v", e)
	}
	if e.LyricsSource != "" || e.ManualPickSHA != "" || !e.ManualLyrics {
		t.Errorf("source 空 = 清掉、非采纳清指纹、mark_manual 置上 got source=%q sha=%q manual=%v", e.LyricsSource, e.ManualPickSHA, e.ManualLyrics)
	}

	// 显式传:空 source_choice / 空 yrc = 清掉;打分成对写;采纳留指纹;判决两槽一起写。
	applyEnrichEdit(enrichEditRequest{
		Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]picked", Source: "netease",
		SourceChoice: strPtr(""), YRC: strPtr(""), Score: intPtr(9), ScoringVersion: intPtr(4),
		FromManualPick: true, Decision: json.RawMessage(`{"path":"manual","winner":"netease"}`),
		ResolvedDurationSecs: 201.5, SourcesSeen: []string{"netease"},
	})
	e, _ = cacheEntry(t, editKey)
	if e.LyricsSourceChoice != "" || e.LyricsYRC != "" || e.LyricsScore != 9 || e.LyricsScoringVersion != 4 {
		t.Errorf("显式传的字段没生效 got %+v", e)
	}
	if e.ManualPickSHA == "" || e.ManualPickSHA != manualPickFingerprint("[00:01.00]picked") {
		t.Errorf("采纳候选应按新正文留指纹 got %q", e.ManualPickSHA)
	}
	if e.ManualLyrics {
		t.Error("采纳候选(mark_manual=false)不该置 manual_lyrics")
	}
	if e.LyricsDecision == nil || e.LyricsDecision != e.LyricsDecisionApplied || e.LyricsDecision.Winner != "netease" {
		t.Errorf("判决两槽应一起写成同一份 got %+v / %+v", e.LyricsDecision, e.LyricsDecisionApplied)
	}
	if e.ResolvedDurationSecs != 201.5 || len(e.LyricsSourcesSeen) != 1 {
		t.Errorf("时长 / 看过的源没写 got %+v", e)
	}
}

// 保存之后:存盘、导出的歌词文件带 [manual:1] 头。
func TestSaveEditPersistsAndExports(t *testing.T) {
	lyrics, _ := setUpEnrichEditTest(t, map[string]enrichEntry{})
	res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]hello", MarkManual: true, Source: "manual"})
	if !res.OK || res.Changed != 1 {
		t.Fatalf("res=%+v", res)
	}
	body, err := os.ReadFile(filepath.Join(lyrics, "Edit Artist - Edit Song - Edit Album.lrc"))
	if err != nil || !strings.Contains(string(body), "[manual:1]") || !strings.Contains(string(body), "hello") {
		t.Errorf("导出文件不对 err=%v body=%q", err, body)
	}
	disk, err := os.ReadFile(enrichPath)
	if err != nil || !strings.Contains(string(disk), "hello") {
		t.Errorf("没存盘 err=%v", err)
	}
}

func TestSetManualLockFlipsOnlyOriginalPicks(t *testing.T) {
	picked := "[00:01.00]picked"
	stillOriginal := enrichKey("A", "Original", "X")
	replaced := enrichKey("A", "Replaced", "X")
	never := enrichKey("A", "Never", "X")
	lyrics, _ := setUpEnrichEditTest(t, map[string]enrichEntry{
		stillOriginal: {Lyrics: picked, ManualPickSHA: manualPickFingerprint(picked)},
		replaced:      {Lyrics: "[00:01.00]auto upgraded", ManualPickSHA: manualPickFingerprint(picked)},
		never:         {Lyrics: picked},
	})
	res := applyEnrichEdit(enrichEditRequest{Op: "set_manual_lock", Value: true})
	if res.Changed != 1 {
		t.Fatalf("只有指纹对得上的那条该翻 changed=%d", res.Changed)
	}
	if e, _ := cacheEntry(t, stillOriginal); !e.ManualLyrics {
		t.Error("指纹对得上的那条没锁上")
	}
	if e, _ := cacheEntry(t, replaced); e.ManualLyrics {
		t.Error("内容已被换掉的不该锁")
	}
	body, _ := os.ReadFile(filepath.Join(lyrics, "A - Original - X.lrc"))
	if !strings.Contains(string(body), "[manual:1]") {
		t.Errorf("锁定要连文件头一起重写,不然下次启动被导入改回去 body=%q", body)
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_manual_lock", Value: true}); res.Changed != 0 {
		t.Errorf("已经是目标状态的不再计数 changed=%d", res.Changed)
	}
}

func TestDeleteTrashesFilesAndSkipsUnknownKeys(t *testing.T) {
	other := enrichKey("Other", "Song", "Album")
	lyrics, trash := setUpEnrichEditTest(t, map[string]enrichEntry{
		editKey: {Lyrics: "[00:01.00]bye"},
		other:   {Lyrics: "[00:01.00]stay"},
	})
	exportLyricsFiles()
	res := applyEnrichEdit(enrichEditRequest{Op: "delete", Keys: []string{editKey, "No|Such|Key"}})
	if !res.OK || res.Changed != 1 {
		t.Fatalf("只删真的在的 res=%+v", res)
	}
	if _, ok := cacheEntry(t, editKey); ok {
		t.Error("条目还在")
	}
	if _, err := os.Stat(filepath.Join(lyrics, "Edit Artist - Edit Song - Edit Album.lrc")); !os.IsNotExist(err) {
		t.Errorf("歌词文件应挪走 err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(trash, "Edit Artist - Edit Song - Edit Album.lrc")); err != nil {
		t.Errorf("歌词文件应进废纸篓 err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(lyrics, "Other - Song - Album.lrc")); err != nil {
		t.Errorf("别的歌的文件不该动 err=%v", err)
	}
}

func TestClearAllEmptiesCacheAndLyricsFilesOnly(t *testing.T) {
	lyrics, _ := setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {Lyrics: "[00:01.00]x"}})
	exportLyricsFiles()
	if err := os.WriteFile(filepath.Join(lyrics, "notes.txt"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "clear_all"})
	if !res.OK {
		t.Fatalf("res=%+v", res)
	}
	enrichMu.Lock()
	n := len(enrichCache)
	enrichMu.Unlock()
	if n != 0 {
		t.Errorf("缓存应清空 剩 %d", n)
	}
	entries, _ := os.ReadDir(lyrics)
	if len(entries) != 1 || entries[0].Name() != "notes.txt" {
		t.Errorf("只清歌词文件,别的文件留着 got %v", entries)
	}
	var disk map[string]json.RawMessage
	raw, _ := os.ReadFile(enrichPath)
	_ = json.Unmarshal(raw, &disk)
	if len(disk) != 0 {
		t.Errorf("盘上也要是空的 got %d 条", len(disk))
	}
}

func TestAdoptRestoreImportsLyricsFiles(t *testing.T) {
	lyrics, _ := setUpEnrichEditTest(t, map[string]enrichEntry{})
	enrichRestorePath = ""
	file := lyricsFileHeader("Restored", "Song", "Album", "", false) + "[00:01.00]restored line"
	if err := os.WriteFile(filepath.Join(lyrics, "Restored - Song - Album.lrc"), []byte(file), 0o644); err != nil {
		t.Fatal(err)
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "adopt_restore"})
	if !res.OK {
		t.Fatalf("res=%+v", res)
	}
	if e, ok := cacheEntry(t, enrichKey("Restored", "Song", "Album")); !ok || !strings.Contains(e.Lyrics, "restored line") {
		t.Errorf("铺回去的歌词文件应收进缓存 got %+v ok=%v", e, ok)
	}
}

// 请求目录:处理完删请求、写结果;太老的请求不执行;坏请求回一个带错误的结果。
func TestProcessEnrichEditRequests(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {Lyrics: "[00:01.00]x"}})
	enrichEditDir = t.TempDir()
	write := func(name, body string, age time.Duration) {
		path := filepath.Join(enrichEditDir, name)
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		at := time.Now().Add(-age)
		_ = os.Chtimes(path, at, at)
	}
	write("0001-ok.json", `{"op":"set_instrumental","key":"`+editKey+`","value":true}`, 0)
	write("0002-stale.json", `{"op":"delete","keys":["`+editKey+`"]}`, 2*enrichEditStaleAfter)
	write("0003-bad.json", `{not json`, 0)

	processEnrichEditRequests()

	readResult := func(id string) (enrichEditResult, bool) {
		data, err := os.ReadFile(filepath.Join(enrichEditDir, id+".result.json"))
		if err != nil {
			return enrichEditResult{}, false
		}
		var r enrichEditResult
		_ = json.Unmarshal(data, &r)
		return r, true
	}
	if r, ok := readResult("0001-ok"); !ok || !r.OK || r.ID != "0001-ok" {
		t.Errorf("正常请求应回 ok 结果 got %+v ok=%v", r, ok)
	}
	if e, ok := cacheEntry(t, editKey); !ok || !e.Instrumental {
		t.Error("过期的删除请求不该执行,正常请求应生效")
	}
	if _, ok := readResult("0002-stale"); ok {
		t.Error("过期请求不该回结果(App 早已报了失败)")
	}
	if r, ok := readResult("0003-bad"); !ok || r.OK || r.Error == "" {
		t.Errorf("坏请求应回带错误的结果 got %+v", r)
	}
	for _, name := range []string{"0001-ok.json", "0002-stale.json", "0003-bad.json"} {
		if _, err := os.Stat(filepath.Join(enrichEditDir, name)); !os.IsNotExist(err) {
			t.Errorf("%s 处理后应删掉", name)
		}
	}
}

// 跟 Swift 侧 ManualPickLock.shouldFlip 同一判据:没留痕 / 内容换过 / 已是目标状态,都不翻。
func TestManualPickShouldFlip(t *testing.T) {
	l := "[00:01.00]a"
	sha := manualPickFingerprint(l)
	cases := []struct {
		sha, lyrics     string
		locked, locking bool
		want            bool
	}{
		{sha, l, false, true, true},
		{sha, l, true, false, true},
		{sha, l, true, true, false},
		{"", l, false, true, false},
		{sha, "[00:01.00]b", false, true, false},
	}
	for i, c := range cases {
		if got := manualPickShouldFlip(c.sha, c.lyrics, c.locked, c.locking); got != c.want {
			t.Errorf("case %d got %v want %v", i, got, c.want)
		}
	}
}

// 超长 key 在加长度上限之前导出过截断前的长文件名,删除时也要一起挪走,不然下次启动被导入复活。
func TestDeleteAlsoTrashesUntruncatedLegacyFile(t *testing.T) {
	longKey := strings.Repeat("A", 140) + "|" + strings.Repeat("B", 60) + "|专辑"
	lyrics, _ := setUpEnrichEditTest(t, map[string]enrichEntry{longKey: {Lyrics: "[00:01.00]x"}})
	artist, title, album := splitEnrichKey(longKey)
	legacy := filepath.Join(lyrics, sanitizeLyricsFilenameUntruncated(longKey)+".lrc")
	if err := os.WriteFile(legacy, []byte(lyricsFileHeader(artist, title, album, "", false)+"[00:01.00]x"), 0o644); err != nil {
		t.Skipf("文件系统不收这么长的名字: %v", err)
	}
	applyEnrichEdit(enrichEditRequest{Op: "delete", Keys: []string{longKey}})
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Errorf("截断前的长名字文件应一起挪走 err=%v", err)
	}
}
