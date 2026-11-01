package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func planOne(t *testing.T, cache map[string]enrichEntry, name, data string) importPlanItem {
	t.Helper()
	plan := planLyricsImport([]importLyricsFile{pathFile(name, data)}, "zh", cache)
	if len(plan.Items) != 1 {
		t.Fatalf("%s: 应一组: %+v", name, plan.Items)
	}
	return plan.Items[0]
}

// 文件里只有 [ti:](没写歌手)时,文件名里的歌手照样用上;只有歌名对上的留到最后。
func TestPlanUsesFileNameArtistWhenTagHasOnlyTitle(t *testing.T) {
	cache := map[string]enrichEntry{
		enrichKey("陈奕迅", "十年", "黑白灰"):  {DurationSecs: 205},
		enrichKey("林宥嘉", "十年", "Live"): {DurationSecs: 210},
	}
	it := planOne(t, cache, "陈奕迅 - 十年.lrc", "[ti:十年]\n[ar:]\n"+lrcBody(4, 40))
	if it.Status != importStatusMatched || it.Key != enrichKey("陈奕迅", "十年", "黑白灰") {
		t.Errorf("应认成陈奕迅那首: %+v", it)
	}
}

// 歌名、歌手里的合作署名只有一边写了也对得上。
func TestPlanMatchesAcrossFeatCredits(t *testing.T) {
	cache := map[string]enrichEntry{
		enrichKey("Calvin Harris", "This Is What You Came For (feat. Rihanna)", "Single"): {DurationSecs: 222},
		enrichKey("Ed Sheeran & Beyoncé", "Perfect Duet", "Single"):                       {DurationSecs: 260},
	}
	for name, want := range map[string]string{
		"Calvin Harris - This Is What You Came For.lrc":               enrichKey("Calvin Harris", "This Is What You Came For (feat. Rihanna)", "Single"),
		"Calvin Harris - This Is What You Came For ft. Rihanna.lrc":   enrichKey("Calvin Harris", "This Is What You Came For (feat. Rihanna)", "Single"),
		"Calvin Harris feat. Rihanna - This Is What You Came For.lrc": enrichKey("Calvin Harris", "This Is What You Came For (feat. Rihanna)", "Single"),
		"Ed Sheeran feat. Beyoncé - Perfect Duet.lrc":                 enrichKey("Ed Sheeran & Beyoncé", "Perfect Duet", "Single"),
	} {
		if it := planOne(t, cache, name, lrcBodyEn(5, 30)); it.Status != importStatusMatched || it.Key != want {
			t.Errorf("%s 应对上: %+v", name, it)
		}
	}
}

// 无空格连字符、全角空格分隔、歌名里带「 - 」的文件名。
func TestPlanFileNameSeparators(t *testing.T) {
	cache := map[string]enrichEntry{
		enrichKey("周杰伦", "晴天", "叶惠美"):                                        {DurationSecs: 269},
		enrichKey("The Beatles", "Let It Be - Remastered 2009", "Let It Be"): {DurationSecs: 243},
	}
	for name, want := range map[string]string{
		"周杰伦-晴天.lrc":                                    enrichKey("周杰伦", "晴天", "叶惠美"),
		"周杰伦\u3000-\u3000晴天.lrc":                        enrichKey("周杰伦", "晴天", "叶惠美"),
		"The Beatles - Let It Be - Remastered 2009.lrc": enrichKey("The Beatles", "Let It Be - Remastered 2009", "Let It Be"),
	} {
		if it := planOne(t, cache, name, lrcBody(4, 50)); it.Status != importStatusMatched || it.Key != want {
			t.Errorf("%s 应对上: %+v", name, it)
		}
	}
	if ids := importStoreIdentities("Ob-La-Di", nil); len(ids) != 0 {
		t.Errorf("硬拆出来的身份不该存进导入库: %+v", ids)
	}
	if ids := importStoreIdentities("Nobody\u3000-\u3000No Such Song", nil); len(ids) == 0 || ids[0].Artist != "Nobody" {
		t.Errorf("全角空格分隔的「歌手 - 歌名」应能存进导入库: %+v", ids)
	}
}

// 放歌时按身份找导入库:存的时候没写「feat. X」,放的这首歌名带着也认。
func TestImportedLyricsBySongAcrossFeatCredit(t *testing.T) {
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	setUpEnrichEditTest(t, importTestCache())
	if err := saveImportedLyrics(importedLyricsRecord{Lyrics: lrcBodyEn(5, 30),
		Identities: []importedIdentity{{Artist: "Calvin Harris", Title: "This Is What You Came For"}}}); err != nil {
		t.Fatal(err)
	}
	if _, ok := importedLyricsFor("Calvin Harris", "This Is What You Came For (feat. Rihanna)", "Single", 0); !ok {
		t.Error("带合作署名的歌名应找到")
	}
	dropImportedLyricsForSong(enrichKey("Calvin Harris", "This Is What You Came For (feat. Rihanna)", "Single"))
	if _, ok := importedLyricsFor("Calvin Harris", "This Is What You Came For", "Single", 0); ok {
		t.Error("删的时候跟读的时候同一套找法,应删掉")
	}
}

// 「只补」:条目只有纯文本时,导入的纯文本不换掉它;带时间轴的照补。改了几首只数请求里的。
func TestImportFillKeepsExistingPlainText(t *testing.T) {
	files := []importLyricsFile{pathFile("P - Plain.txt", "导入的第一行\n导入的第二行"), pathFile("Q - Timed.lrc", lrcBody(4, 30))}
	staging := setUpImportBatch(t, files)
	keyP, keyQ := enrichKey("P", "Plain", "X"), enrichKey("Q", "Timed", "X")
	setUpEnrichEditTest(t, map[string]enrichEntry{
		keyP: {DurationSecs: 100, PlainLyrics: bt("原来的纯文本"), PlainLyricsSource: "user"},
		keyQ: {DurationSecs: 100, PlainLyrics: bt("原来的纯文本"), PlainLyricsSource: "user"},
	})
	ids := map[string]int{}
	for _, g := range groupImportFiles(files) {
		ids[g.Stem] = g.ID
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "import_lyrics_batch", Staging: staging, Mode: importModeFill,
		ImportItems: []importBatchItem{{ID: ids["P - Plain"], Key: keyP}, {ID: ids["Q - Timed"], Key: keyQ}}})
	if !res.OK || res.Changed != 1 {
		t.Fatalf("只该补带时间轴的那首: %+v", res)
	}
	if e, _ := cacheEntry(t, keyP); e.PlainLyrics.String() != "原来的纯文本" {
		t.Errorf("已有的纯文本不该被换掉: %q", e.PlainLyrics.String())
	}
	if e, _ := cacheEntry(t, keyQ); e.LyricsSource != importLyricsSource {
		t.Errorf("只有纯文本的条目应补上带时间轴的: %+v", e)
	}
}

// 监视文件夹存进来的记录记下来源文件,文件删了跟着作废;快照恢复作废快照之后存进来的。
func TestImportedLyricsWatchFilesAndSnapshotDrop(t *testing.T) {
	files := []importLyricsFile{pathFile("sub/Nobody Here - No Such Song.lrc", lrcBodyEn(4, 6))}
	staging := setUpImportBatch(t, files)
	setUpEnrichEditTest(t, importTestCache())
	res := applyEnrichEdit(enrichEditRequest{Op: "import_lyrics_batch", Staging: staging, Mode: importModeLibrary,
		WatchFolder: "/Users/x/Lyrics", ImportItems: []importBatchItem{{ID: 0, Store: true}}})
	if !res.OK || res.Changed != 1 {
		t.Fatalf("应按身份存一份: %+v", res)
	}
	rec, ok := importedLyricsRecordBySong("Nobody Here", "No Such Song", 0)
	if !ok || len(rec.WatchFiles) != 1 || rec.WatchFiles[0] != "/Users/x/Lyrics/sub/Nobody Here - No Such Song.lrc" {
		t.Fatalf("应记下来源文件: %+v", rec)
	}
	if n := dropImportedLyricsFromWatchFiles([]string{"/Users/x/Lyrics/other.lrc"}); n != 0 {
		t.Errorf("别的文件不该连带: %d", n)
	}
	if n := dropImportedLyricsFromWatchFiles([]string{"/Users/x/Lyrics/sub/Nobody Here - No Such Song.lrc"}); n != 1 {
		t.Errorf("来源文件删了应作废: %d", n)
	}
	if _, ok := importedLyricsRecordBySong("Nobody Here", "No Such Song", 0); ok {
		t.Error("作废之后不该再找到")
	}

	if err := saveImportedLyrics(
		importedLyricsRecord{Key: "A|Old|X", Lyrics: lrcBodyEn(4, 6), ImportedAt: 100},
		importedLyricsRecord{Key: "A|New|X", Lyrics: lrcBodyEn(4, 6), ImportedAt: 300},
	); err != nil {
		t.Fatal(err)
	}
	if n := dropImportedLyricsSince(200); n != 1 {
		t.Errorf("只该作废快照之后那份: %d", n)
	}
	if _, ok := importedLyricsRecordFor("A|Old|X"); !ok {
		t.Error("快照之前的不该动")
	}
}

// index.json 读不出来时按记录文件重建,坏的那份留着。
func TestImportedLyricsIndexRebuildsWhenCorrupt(t *testing.T) {
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	setUpEnrichEditTest(t, importTestCache())
	if err := saveImportedLyrics(
		importedLyricsRecord{Key: "A|Song|Album One", Lyrics: lrcBodyEn(4, 6)},
		importedLyricsRecord{Lyrics: lrcBodyEn(4, 6), Identities: []importedIdentity{{Artist: "Z", Title: "Zed"}}},
	); err != nil {
		t.Fatal(err)
	}
	index := filepath.Join(importedLyricsDir(), "index.json")
	if err := os.WriteFile(index, []byte("{broken"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, ok := importedLyricsRecordFor("A|Song|Album One"); !ok {
		t.Error("按 key 存的应还找得到")
	}
	if _, ok := importedLyricsRecordBySong("Z", "Zed", 0); !ok {
		t.Error("按身份存的应还找得到")
	}
	if _, err := os.Stat(index + ".corrupt"); err != nil {
		t.Errorf("坏的那份应留着: %v", err)
	}
}

// 「锁定」时同一首歌的其他写法跟着改,改了几首只数请求里的那一首。
func TestImportManualCountsOnlyRequestedKeys(t *testing.T) {
	const a, b = "X|Song|A", "X|Song|B"
	setUpSongShareTest(t, map[string]enrichEntry{
		a: {Song: "s1", Lyrics: bt(songShareLRC("a")), LyricsSource: "qq"},
		b: {Song: "s1", Lyrics: bt(songShareLRC("b")), LyricsSource: "qq"},
	}, true)
	if err := os.MkdirAll(importStagingDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	staging := filepath.Join(importStagingDir(), "s.json")
	data, _ := json.Marshal(importStagingRequest{Files: []importLyricsFile{pathFile("X - Song.lrc", lrcBodyEn(5, 20))}})
	if err := os.WriteFile(staging, data, 0o644); err != nil {
		t.Fatal(err)
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "import_lyrics_batch", Staging: staging, Mode: importModeManual,
		ImportItems: []importBatchItem{{ID: 0, Key: a}}})
	if !res.OK || res.Changed != 1 {
		t.Fatalf("只该数请求里那一首: %+v", res)
	}
	if got, _ := cacheEntry(t, b); !got.ManualLyrics {
		t.Fatalf("同一首歌的另一种写法应跟着改(不然这条测不到计数): %+v", got)
	}
}
