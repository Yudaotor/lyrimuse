package main

import (
	"encoding/json"
	"errors"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 升级重试不给已有歌词的条目打纯音乐标记(播放器自己给的标记除外)/ 挂纯文本兜底;用户撤过纯音乐标记的也不再标(autoMarksInstrumental)。
func TestRetryFallbacksOnlyForEntriesWithoutLyrics(t *testing.T) {
	src := string(mustRead(t, "enrich.go"))
	for _, needle := range []string{
		"if picked == nil && e.autoMarksInstrumental() && (e.Lyrics == \"\" || (playerSaysInstrumental(scored) && sourceChoice == \"\" && !opts.manual)) {",
		"if picked == nil && !e.Instrumental && e.PlainLyrics == \"\" && e.Lyrics == \"\" {",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
}

// 同专辑借封面不排序也要确定:够格的里取 key 最小的那条。
func TestSiblingCoverPicksSmallestKey(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"歌手|b|专辑": {CoverURL: "https://example.invalid/b.jpg", CoverSource: "qq"},
		"歌手|a|专辑": {CoverURL: "https://example.invalid/a.jpg", CoverSource: "qq"},
		"歌手|c|专辑": {CoverURL: "https://example.invalid/c.jpg", CoverSource: "netease"},
	})
	for range 20 {
		enrichMu.Lock()
		url, _ := siblingCoverLocked("", "歌手", "专辑", false)
		enrichMu.Unlock()
		if url != "https://example.invalid/a.jpg" {
			t.Fatalf("got %q", url)
		}
	}
}

// 两个迁移改了内存要置脏,不然那次保存是空操作。
func TestStartupMigrationsMarkDirty(t *testing.T) {
	withTempDecisionCache(t)
	enrichMu.Lock()
	enrichPath = "" // 不落盘:只看脏标记
	enrichCache["a|t|b"] = enrichEntry{CoverSource: "qq", CoverAlbum: "b", CoverURL: "u"}
	enrichCache["a|t2|b"] = enrichEntry{Lyrics: "[00:01.00]x", LyricsSource: "qq", LyricsSourceChoice: "qq"}
	enrichDirty = false
	enrichMu.Unlock()
	migrateBorrowedCoverAlbums()
	if !enrichDirty {
		t.Fatal("migrateBorrowedCoverAlbums 应当置脏")
	}
	enrichMu.Lock()
	enrichDirty = false
	enrichMu.Unlock()
	migrateManualPickMarks()
	if !enrichDirty {
		t.Fatal("migrateManualPickMarks 应当置脏")
	}
}

// 删落选文件的名单里要有截断前的长文件名。
func TestExportedFileNamesIncludeUntruncated(t *testing.T) {
	key := strings.Repeat("长", 60) + "|" + strings.Repeat("歌", 30) + "|专辑"
	long := sanitizeLyricsFilenameUntruncated(key)
	if long == sanitizeLyricsFilename(key) {
		t.Fatal("前提:这个 key 会被截断")
	}
	names := strings.Join(enrichExportedFileNames(key), "\n")
	if !strings.Contains(names, long+".lrc") {
		t.Fatal("缺截断前的长文件名")
	}
}

// 正文小文件:不存在不算错,读不出来要交回错误(常驻进程把它挪到旁边)。
func TestReadEnrichBodyCheckedDistinguishesIOErrors(t *testing.T) {
	dir := t.TempDir()
	if b, err := readEnrichBodyChecked(filepath.Join(dir, "none.json")); b != nil || err != nil {
		t.Fatalf("不存在: %v %v", b, err)
	}
	if b, err := readEnrichBodyChecked(dir); b != nil || err == nil { // 读目录是 I/O 错误
		t.Fatalf("读不出来应当报错: %v %v", b, err)
	}
	p := filepath.Join(dir, "x.json")
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	moveUnreadableBodiesAside([]string{p})
	if matches, _ := filepath.Glob(p + ".unreadable-*"); len(matches) != 1 {
		t.Fatalf("应当挪到旁边: %v", matches)
	}
}

// 硬链接做不成时的索引兜底:正文小文件这次没写成的条目不能带新校验值。
func TestWriteEnrichIndexOnlyLeanForWrittenBodies(t *testing.T) {
	withTempIndexCache(t)
	snapshot := map[string]enrichEntry{"a|t|b": {Lyrics: "[00:01.00]x", LyricsTr: "[00:01.00]译"}}
	crcs := map[string]uint32{"a|t|b": enrichBodyCRC(snapshot["a|t|b"])}
	enrichBodyCRCs = map[string]uint32{} // 这一次一个都没写成
	writeEnrichIndex(snapshot, crcs)
	var idx map[string]map[string]any
	if err := json.Unmarshal(mustRead(t, enrichIndexPath()), &idx); err != nil {
		t.Fatal(err)
	}
	if _, ok := idx["a|t|b"]["body_crc"]; ok || idx["a|t|b"]["lyrics_tr"] == nil {
		t.Fatalf("没写成正文的条目应当整块写进索引: %v", idx["a|t|b"])
	}
}

// save_edit 新建条目时记上解析时刻。
func TestSaveEditOnMissingKeyStampsTS(t *testing.T) {
	withEnrichCache(t, nil)
	enrichMu.Lock()
	out := applyEnrichEditLocked(enrichEditRequest{Op: "save_edit", Key: "a|t|b", Lyrics: "[00:01.00]x"})
	e := enrichCache["a|t|b"]
	enrichMu.Unlock()
	if out.err != nil || e.TS <= 0 {
		t.Fatalf("新建条目应当带 TS: %+v %v", e, out.err)
	}
}

// 「清空」只挪头部认得出的歌词文件;临时文件只认 writeLyricsFileAtomic 的命名;CRLF 文件照样认作这首的。
func TestLyricsDirOnlyTouchesOwnFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, ".Trash"), 0o755); err != nil {
		t.Fatal(err)
	}
	dir := withLyricsDir(t)
	key := "歌手|歌名|专辑"
	crlf := strings.ReplaceAll(lyricsFileHeader("歌手", "歌名", "专辑", "netease", false)+"[00:01.00]x", "\n", "\r\n")
	own := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")
	foreign := filepath.Join(dir, "somebody else.lrc")
	for p, content := range map[string]string{own: crlf, foreign: "not ours"} {
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := lyricsFilesOwnedBy(key); len(got) != 1 || got[0] != own {
		t.Fatalf("CRLF 的文件也是这首的: %v", got)
	}
	trashAllLyricsFiles()
	if _, err := os.Stat(foreign); err != nil {
		t.Fatal("认不出头部的文件不该被清空挪走")
	}
	if _, err := os.Stat(own); !os.IsNotExist(err) {
		t.Fatal("认得出的文件应当进废纸篓")
	}
	for name, want := range map[string]bool{
		"歌 - 名.lrc.tmp.123456": true, "歌 - 名.yrc.tmp.9": true,
		"notes.tmp.txt": false, "backup.tmp.2024.zip": false, "歌 - 名.lrc": false,
	} {
		if got := isLyricsTempFile(name); got != want {
			t.Errorf("isLyricsTempFile(%q) = %v, want %v", name, got, want)
		}
	}
}

// 全量扫库:断网停下时把停在的那首的尝试时刻拨回起点之前;轮到时正在别处解析的算跳过。
func TestFullScanReleaseAndSkippedOutcome(t *testing.T) {
	saved := lyricsFullScanStatePath
	t.Cleanup(func() {
		lyricsFullScanMu.Lock()
		lyricsFullScanStatePath = saved
		lyricsFullScanMu.Unlock()
	})
	path := filepath.Join(t.TempDir(), "fullscan.json")
	data, _ := json.Marshal(lyricsFullScanState{ScoringVersion: lyricsScoringVersion, Active: true, StartedAt: 1000})
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	lyricsFullScanMu.Lock()
	lyricsFullScanStatePath = path
	lyricsFullScanMu.Unlock()
	withEnrichCache(t, map[string]enrichEntry{"a|t|b": {Lyrics: "x", LyricsRescoreTS: 1500, LyricsRetryTS: 900, LyricsFillTS: 1000}})
	releaseLyricsFullScanAttempt("a|t|b")
	e := enrichCache["a|t|b"]
	if e.LyricsRescoreTS != 999 || e.LyricsFillTS != 999 || e.LyricsRetryTS != 900 {
		t.Fatalf("尝试时刻应拨回起点之前: %+v", e)
	}
	enrichMu.Lock()
	enrichInflight["a|t|b"] = true
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		delete(enrichInflight, "a|t|b")
		enrichMu.Unlock()
	})
	if out := lyricsFullScanOne(t.Context(), "a|t|b"); !out.skipped {
		t.Fatalf("在途的应当算跳过: %+v", out)
	}
}

// 补空收尾时有一场全量等着:接着跑。撞上正在跑的那一发全量要记下待续。
func TestFillSweepHandsOffToPendingFullScan(t *testing.T) {
	src := string(mustRead(t, "lyricsfillsweep.go"))
	for _, needle := range []string{
		"if !req.full && lyricsFullScanActive() {",
		"case lyricsFillSweepReschedule <- lyricsFullScanHandoffDelay:",
		"if req.full {\n\t\t\tsetLyricsFullScanActive(true)\n\t\t}",
		"if full {\n\t\t\t\t\treleaseLyricsFullScanAttempt(keys[i])\n\t\t\t\t}",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("lyricsfillsweep.go 缺 %q", needle)
		}
	}
}

// 收听日志写不进去要交回错误(补提交靠它停手)。
func TestAppendListenLogLineReportsErrors(t *testing.T) {
	saved := listenLogPath
	t.Cleanup(func() { listenLogPath = saved })
	listenLogPath = t.TempDir() // 是个目录:打不开来写
	if err := markBackfilledChecked(1); err == nil {
		t.Fatal("写不进去应当报错")
	}
}

// 翻译:行首多个时间标签都算 tag;出错信息里不带整段请求地址。
func TestTranslateLineTagsAndRedactedErrors(t *testing.T) {
	got := parseLRCLines("[00:12.00] [00:45.00]同一句\n[01:00.00]另一句")
	if len(got) != 2 || got[0].tag != "[00:12.00][00:45.00]" || got[0].text != "同一句" {
		t.Fatalf("got %+v", got)
	}
	err := withoutRequestURL(&neturl.Error{Op: "Get", URL: "https://api.mymemory.translated.net/get?q=%E6%AD%8C%E8%AF%8D&de=x%40y.z", Err: errors.New("timeout")})
	if msg := err.Error(); strings.Contains(msg, "q=") || strings.Contains(msg, "de=") || !strings.Contains(msg, "api.mymemory.translated.net") {
		t.Fatalf("got %q", msg)
	}
}
