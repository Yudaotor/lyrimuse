package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withLyricsWordFormats(t *testing.T, fs ...lyricsWordFormat) {
	t.Helper()
	saved := lyricsWordFormatsApplied.Load()
	lyricsWordFormatsApplied.Store(&fs)
	t.Cleanup(func() { lyricsWordFormatsApplied.Store(saved) })
}

func lyricsWordFilesSample() enrichEntry {
	return enrichEntry{
		LyricsSource: "qq",
		Lyrics:       bt("[00:01.00]你好吗\n[00:04.00]早了"),
		LyricsYRC:    bt("[1000,2500](1000,500,0)你(1500,500,0)好(2000,1000,0)吗\n[4000,1500](4000,550,0)早(4550,500,0)了"),
		LyricsBG:     bt("[1000,2500](1600,800,0)(ooh)"),
		DurationSecs: 200,
	}
}

func lyricsWordCacheEntry(key string) enrichEntry {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	return enrichCache[key]
}

// 主格式 + 副本都写;读回来不算改过(没有状态记录、按内容比也一样);主格式那份被改了才采纳,改副本不认;
// TTML 带着背景人声,改了它连背景人声一起采纳。
func TestLyricsWordFormatsExportAndImport(t *testing.T) {
	key := "A|Song|"
	sample := lyricsWordFilesSample()
	dir := withExportFixture(t, map[string]enrichEntry{key: sample})
	withLyricsWordFormats(t, lyricsWordTTML, lyricsWordQRC)
	exportLyricsFiles()
	base := filepath.Join(dir, sanitizeLyricsFilename(key))
	files := dirContents(t, dir)
	name := filepath.Base(base)
	if _, ok := files[name+".yrc"]; ok {
		t.Errorf("设置里没有 YRC,不写 .yrc: %v", keysOf(files))
	}
	if !strings.Contains(files[name+".ttml"], `ttm:role="x-bg"`) || files[name+".qrc"] == "" || files[name+".lrc"] == "" {
		t.Fatalf("主格式、副本、逐行都要写: %v", keysOf(files))
	}

	importLyricsFrom(dir, false)
	if e := lyricsWordCacheEntry(key); !e.LyricsYRC.Equal(sample.LyricsYRC) || !e.LyricsBG.Equal(sample.LyricsBG) || e.ManualLyrics {
		t.Fatalf("导出的那份读回来不算改过: %q / %q", e.LyricsYRC, e.LyricsBG)
	}

	// 改副本(QRC):不认。
	in := lyricsWordInputOf(key, sample, sample.LyricsYRC.String())
	in.yrc = strings.Replace(in.yrc, "早", "晚", 1)
	if err := os.WriteFile(base+".qrc", sealLyricsWordFile(lyricsWordQRC, encodeLyricsWordText(lyricsWordQRC, in)), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	if e := lyricsWordCacheEntry(key); strings.Contains(e.LyricsYRC.String(), "晚") {
		t.Errorf("副本被改了不该采纳: %q", e.LyricsYRC)
	}

	// 改主格式(TTML):逐字和背景人声都照文件来。
	ttml := strings.Replace(files[name+".ttml"], ">早<", ">晚<", 1)
	ttml = strings.Replace(ttml, ">(ooh)<", ">(ah)<", 1)
	if err := os.WriteFile(base+".ttml", []byte(ttml), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	e := lyricsWordCacheEntry(key)
	if !strings.Contains(e.LyricsYRC.String(), "(4000,550,0)晚") || !strings.Contains(e.LyricsBG.String(), "(ah)") {
		t.Errorf("主格式改了要采纳,背景人声跟着文件: %q / %q", e.LyricsYRC, e.LyricsBG)
	}
}

// 换格式:写新格式、删掉不再要的格式的文件;文件夹里只有别的格式(用户自己放进来的)也读得进来。
func TestLyricsWordFormatSwitchAndForeignFile(t *testing.T) {
	key := "A|Song|"
	sample := lyricsWordFilesSample()
	dir := withExportFixture(t, map[string]enrichEntry{key: sample})
	withLyricsWordFormats(t, lyricsWordYRC)
	exportLyricsFiles()
	name := sanitizeLyricsFilename(key)
	if _, ok := dirContents(t, dir)[name+".yrc"]; !ok {
		t.Fatal("默认写 .yrc")
	}
	withLyricsWordFormats(t, lyricsWordKRC)
	exportLyricsFiles()
	files := dirContents(t, dir)
	if _, ok := files[name+".yrc"]; ok {
		t.Errorf("换成 KRC 之后 .yrc 要删掉: %v", keysOf(files))
	}
	if !strings.HasPrefix(files[name+".krc"], "krc1") {
		t.Errorf("没写出加密的 .krc: %v", keysOf(files))
	}

	// 另一首歌:缓存里没有,文件夹里只有一份 TTML。
	other := "B|Other|"
	in := lyricsWordInputOf(other, sample, sample.LyricsYRC.String())
	if err := os.WriteFile(filepath.Join(dir, sanitizeLyricsFilename(other)+".ttml"), []byte(encodeLyricsWordText(lyricsWordTTML, in)), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	e := lyricsWordCacheEntry(other)
	if !e.LyricsYRC.Equal(sample.LyricsYRC) || !e.LyricsBG.Equal(sample.LyricsBG) || e.LyricsSource != "qq" {
		t.Errorf("只有 TTML 的也读进来: %q / %q / %q", e.LyricsYRC, e.LyricsBG, e.LyricsSource)
	}
}

// 有状态记录时,没动过的逐字文件第二次导出不再编码,重启(记录从盘上读回)之后也一样;缓存变了才重写。
func TestLyricsWordFilesSkipUnchanged(t *testing.T) {
	sample := lyricsWordFilesSample()
	dir := withLyricsFileStateEnv(t)
	key := "A|Song|"
	withEnrichCache(t, map[string]enrichEntry{key: sample})
	withLyricsWordFormats(t, lyricsWordQRC, lyricsWordTTML)
	encodes := func(f func()) int64 {
		before := lyricsWordFileEncodes.Load()
		f()
		return lyricsWordFileEncodes.Load() - before
	}
	if n := encodes(exportLyricsFiles); n != 2 {
		t.Fatalf("第一次导出两种格式各编一次: %d", n)
	}
	if n := encodes(exportLyricsFiles); n != 0 {
		t.Errorf("没变的不再编: %d", n)
	}
	resetLyricsFileStateForTest()
	if n := encodes(exportLyricsFiles); n != 0 {
		t.Errorf("重启后从记录里认得: %d", n)
	}
	enrichMu.Lock()
	e := enrichCache[key]
	e.LyricsYRC = bt(strings.Replace(e.LyricsYRC.String(), "早", "晚", 1))
	enrichCache[key] = e
	enrichMu.Unlock()
	if n := encodes(exportLyricsFiles); n != 2 {
		t.Errorf("缓存变了重写: %d", n)
	}
	plain, _ := openLyricsWordFile(lyricsWordQRC, []byte(dirContents(t, dir)[sanitizeLyricsFilename(key)+".qrc"]))
	if !strings.Contains(plain, "晚(4000,550)") {
		t.Errorf("重写成新内容: %q", plain)
	}
}

func keysOf(m map[string]string) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

// 主格式在默认先后里排得靠后也以它为准:副本改了不认。
func TestLyricsWordPrimaryFormatWinsOverEarlierCopy(t *testing.T) {
	key := "A|Song|"
	sample := lyricsWordFilesSample()
	dir := withExportFixture(t, map[string]enrichEntry{key: sample})
	withLyricsWordFormats(t, lyricsWordKRC, lyricsWordTTML)
	exportLyricsFiles()
	base := filepath.Join(dir, sanitizeLyricsFilename(key))
	ttml := strings.Replace(dirContents(t, dir)[filepath.Base(base)+".ttml"], ">早<", ">晚<", 1)
	if err := os.WriteFile(base+".ttml", []byte(ttml), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	if e := lyricsWordCacheEntry(key); strings.Contains(e.LyricsYRC.String(), "晚") {
		t.Errorf("主格式是 KRC,改 TTML 副本不认: %q", e.LyricsYRC)
	}
}

// 增强 LRC 只到百分之一秒:导出的那份读回来按内容比是同一份,缓存里的毫秒不会被舍掉。
func TestLyricsWordLossyFormatKeepsCache(t *testing.T) {
	key := "A|Song|"
	sample := lyricsWordFilesSample()
	sample.LyricsYRC = bt("[1003,2497](1003,507,0)你(1510,493,0)好(2003,997,0)吗")
	sample.LyricsBG = bodyText{}
	dir := withExportFixture(t, map[string]enrichEntry{key: sample})
	withLyricsWordFormats(t, lyricsWordELRC)
	exportLyricsFiles()
	importLyricsFrom(dir, false)
	if e := lyricsWordCacheEntry(key); !e.LyricsYRC.Equal(sample.LyricsYRC) {
		t.Errorf("没改过的增强 LRC 不该把缓存换成舍过的时间: %q", e.LyricsYRC)
	}
}

// 换主格式时先按旧的导入:旧主格式文件里的手改收进缓存,再换,新主格式那份就算早就在文件夹里(之前存过副本)也不会盖掉它。
func TestSwitchLyricsWordFormatsAdoptsOldPrimaryFirst(t *testing.T) {
	key := "A|Song|"
	sample := lyricsWordFilesSample()
	dir := withExportFixture(t, map[string]enrichEntry{key: sample})
	resetFeaturesForTest(t)
	savedReady := lyricsDirSwitchReady.Load()
	t.Cleanup(func() { lyricsDirSwitchReady.Store(savedReady) })
	lyricsDirSwitchReady.Store(true)
	withLyricsWordFormats(t, lyricsWordTTML, lyricsWordQRC)
	exportLyricsFiles()
	base := filepath.Join(dir, sanitizeLyricsFilename(key))
	ttml := strings.Replace(dirContents(t, dir)[filepath.Base(base)+".ttml"], ">早<", ">晚<", 1)
	if err := os.WriteFile(base+".ttml", []byte(ttml), 0o644); err != nil {
		t.Fatal(err)
	}
	next := []lyricsWordFormat{lyricsWordQRC}
	setFeatures(featureFlags{LyricsWordFormats: next})
	switchLyricsWordFormats(next)
	if e := lyricsWordCacheEntry(key); !strings.Contains(e.LyricsYRC.String(), "晚") {
		t.Errorf("旧主格式里的手改要先收进来: %q", e.LyricsYRC)
	}
	files := dirContents(t, dir)
	if _, ok := files[filepath.Base(base)+".ttml"]; ok {
		t.Errorf("不再要的格式删掉: %v", keysOf(files))
	}
	plain, _ := openLyricsWordFile(lyricsWordQRC, []byte(files[filepath.Base(base)+".qrc"]))
	if !strings.Contains(plain, "晚(4000,550)") {
		t.Errorf("新主格式按收进来的内容重写: %q", plain)
	}
}
