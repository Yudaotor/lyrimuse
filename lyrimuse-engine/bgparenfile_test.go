package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func parenBGFileSample(t *testing.T) parenBGSplit {
	t.Helper()
	lrc := "[00:01.00]Kills me slowly (slowly)\n[00:05.00]Turn now (loud), and go\n[00:09.00]No parens here"
	yrc := yrcLine(1000, "Kills me slowly (slowly)") + "\n" + yrcLine(5000, "Turn now (loud), and go") + "\n" + yrcLine(9000, "No parens here")
	sp, ok := splitParenBackground(lrc, yrc)
	if !ok {
		t.Fatal("前提:样本拆得开")
	}
	return sp
}

func TestParenBGFileForm(t *testing.T) {
	sp := parenBGFileSample(t)
	fl, fy := parenBGFileForm("netease", sp.lrc, sp.yrc, sp.bg)
	if !strings.Contains(fl, "[00:01.00]Kills me slowly (slowly)\n") || !strings.Contains(fl, "[00:05.00]Turn now, and go (loud)\n") ||
		!strings.HasSuffix(fl, "[00:09.00]No parens here") {
		t.Errorf("逐行接回行尾: %q", fl)
	}
	if strings.Count(fy, "(slowly)") != 1 || strings.Count(fy, "(loud)") != 1 {
		t.Errorf("逐字接回行尾: %q", fy)
	}
	again, ok := splitParenBackground(fl, fy)
	if !ok || again.lrc != sp.lrc || again.yrc != sp.yrc || !parenBGSameTrack(again.bg, sp.bg) {
		t.Errorf("接回去的再拆一次跟原来一样: %+v", again)
	}
	for _, c := range []struct{ name, source, bg string }{
		{"AMLL / Apple 的背景人声不接", "applemusic", sp.bg},
		{"没有背景人声", "netease", ""},
	} {
		if l, y := parenBGFileForm(c.source, sp.lrc, sp.yrc, c.bg); l != sp.lrc || y != sp.yrc {
			t.Errorf("%s: %q / %q", c.name, l, y)
		}
	}
	// 拆不回缓存里那一份(这里逐行那句的文字跟逐字主句对不上)就原样写。
	odd := strings.Replace(sp.lrc, "Kills me slowly", "Kills me softly", 1)
	if l, y := parenBGFileForm("netease", odd, sp.yrc, sp.bg); l != odd || y != sp.yrc {
		t.Errorf("拆不回来的原样返回: %q / %q", l, y)
	}
}

// 同一句短时间里唱好几遍:按逐行先后配(拆分时的配法)才配得回原来那几行。
func TestParenBGFileFormRepeatedLines(t *testing.T) {
	lrc := "[03:27.74]It's my life (it's my life)\n[03:31.36]It's my life (it's my life)\n[03:46.40]It's my life"
	yrc := yrcLine(209875, "It's my life (it's my life)") + "\n" + yrcLine(212275, "It's my life (it's my life)") + "\n" +
		yrcLine(226875, "It's my life")
	sp, ok := splitParenBackground(lrc, yrc)
	if !ok {
		t.Fatal("前提:样本拆得开")
	}
	fl, fy := parenBGFileForm("deezer", sp.lrc, sp.yrc, sp.bg)
	if fl != lrc {
		t.Errorf("逐行配回原来那两行: %q", fl)
	}
	if again, ok := splitParenBackground(fl, fy); !ok || again.lrc != sp.lrc || again.yrc != sp.yrc {
		t.Errorf("再拆一次跟原来一样: %+v", again)
	}
}

// 前面一行同样的句子原本就没有括号(Malcolm Todd《Sore Throat》):按逐行先后配会被它抢走,拆回来行首的空格没了;
// 按背景人声的先后各配最近的时间戳才配得回去。
func TestParenBGFileFormNeedsNearestStamp(t *testing.T) {
	lrc := "[01:56.48] Goodbye, goodbye, goodbye\n[01:58.90] Goodbye, goodbye, goodbye (oh-oh)\n[02:01.79] Goodbye, goodbye, goodbye (oh-oh)"
	yrc := yrcLine(116480, "Goodbye, goodbye, goodbye") + "\n" + yrcLine(118900, "Goodbye, goodbye, goodbye (oh-oh)") + "\n" +
		yrcLine(121790, "Goodbye, goodbye, goodbye (oh-oh)")
	sp, ok := splitParenBackground(lrc, yrc)
	if !ok {
		t.Fatal("前提:样本拆得开")
	}
	fl, fy := parenBGFileForm("soda", sp.lrc, sp.yrc, sp.bg)
	if !strings.HasPrefix(fl, "[01:56.48] Goodbye, goodbye, goodbye\n") || strings.Count(fl, "(oh-oh)") != 2 {
		t.Errorf("配回后两行: %q", fl)
	}
	if again, ok := splitParenBackground(fl, fy); !ok || again.lrc != sp.lrc || again.yrc != sp.yrc {
		t.Errorf("再拆一次跟原来一样: %+v", again)
	}
}

func TestLyricsFilesKeepParenBackground(t *testing.T) {
	sp := parenBGFileSample(t)
	key := "a|kills|"
	tr := "[00:01.00]慢慢杀死我\n[00:05.00]转身\n[00:09.00]这里没有括号"
	dir := withExportFixture(t, map[string]enrichEntry{
		key: {LyricsSource: "netease", Lyrics: bt(sp.lrc), LyricsYRC: bt(sp.yrc), LyricsBG: bt(sp.bg), LyricsTr: bt(tr), LyricsTrSource: lyricsTrSourceMachine},
	})
	base := filepath.Join(dir, sanitizeLyricsFilename(key))
	oldLRC := lyricsFileHeader("a", "kills", "", "netease", false) + sp.lrc
	if err := os.WriteFile(base+".lrc", []byte(oldLRC), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(base+".lrc", old, old); err != nil {
		t.Fatal(err)
	}
	exportLyricsFiles()
	files := dirContents(t, dir)
	name := filepath.Base(base)
	if !strings.Contains(files[name+".lrc"], "Kills me slowly (slowly)") || !strings.Contains(files[name+".yrc"], "(slowly)") {
		t.Fatalf("文件里写回括号里的背景人声: %q", files[name+".lrc"])
	}
	if st, err := os.Stat(base + ".lrc"); err != nil || !st.ModTime().Equal(old) {
		t.Errorf("只是换成接回去的写法,修改时间不变: %v", st.ModTime())
	}

	importLyricsFrom(dir, false)
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if !e.Lyrics.EqualString(sp.lrc) || !e.LyricsYRC.EqualString(sp.yrc) || !e.LyricsBG.EqualString(sp.bg) ||
		!e.LyricsTr.EqualString(tr) || e.ManualLyrics {
		t.Errorf("导出的那份读回来不算改过: %+v", e)
	}

	edited := strings.Replace(files[name+".lrc"], "No parens here", "Changed by hand", 1)
	if err := os.WriteFile(base+".lrc", []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	enrichMu.Lock()
	e = enrichCache[key]
	enrichMu.Unlock()
	if !strings.Contains(e.Lyrics.String(), "Changed by hand") || !strings.Contains(e.Lyrics.String(), "(slowly)") || !e.LyricsBG.IsZero() {
		t.Errorf("文件真被改了照常采纳,背景人声跟着正文回到括号里: %q / %q", e.Lyrics, e.LyricsBG)
	}
}

// 记录作废时,同步之前导出的旧文件不导入(18 章决策 53):留底那份拆过括号背景人声的,文件里是接回去的写法,同样认得出。
func TestImportSkipsPredatingFileWithParenBackground(t *testing.T) {
	auto := songShareLRC("auto")
	sp := parenBGFileSample(t)
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
	}, true)
	pre := enrichEntry{Lyrics: bt(sp.lrc), LyricsYRC: bt(sp.yrc), LyricsBG: bt(sp.bg), LyricsSource: "kugou"}
	if _, err := writeSongSharePre("A|Song|Two", pre, songOffsetFingerprint(auto, ""), time.Unix(6_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	dir := withLyricsFileStateEnv(t)
	exportLyricsFiles()
	if err := os.Remove(lyricsFileStatePath()); err != nil {
		t.Fatal(err)
	}
	resetLyricsFileStateForTest()
	path := filepath.Join(dir, sanitizeLyricsFilename("A|Song|Two")+".lrc")
	orig, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fileLRC, _ := parenBGFileForm("kugou", sp.lrc, sp.yrc, sp.bg)
	stale := strings.Replace(string(orig), auto, fileLRC, 1)
	if stale == string(orig) || fileLRC == sp.lrc {
		t.Fatal("前提:换成了留底那份接回去的写法")
	}
	if err := os.WriteFile(path, []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Minute)
	_ = os.Chtimes(path, future, future)
	keys := importLyricsFromFiles()
	if two, _ := cacheEntry(t, "A|Song|Two"); !two.Lyrics.EqualString(auto) || slices.Contains(keys, "A|Song|Two") {
		t.Errorf("旧文件不导入: %q keys=%v", two.Lyrics, keys)
	}
}
