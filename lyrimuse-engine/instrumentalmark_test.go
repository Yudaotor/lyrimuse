package main

import (
	"os"
	"strings"
	"testing"
)

// 存进来一份歌词(采纳候选、手改正文、采纳纯文本)就撤掉纯音乐标记:标记优先于歌词,不撤的话存进来的词也不显示。
// 存的是空正文不撤;没落地的请求不动标记。
func TestSavingLyricsClearsInstrumental(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {TS: 1, Instrumental: true}})
	marked := func() bool {
		e, _ := cacheEntry(t, editKey)
		return e.Instrumental
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey}); !res.OK || !marked() {
		t.Fatalf("存空正文不撤标记: ok=%v marked=%v", res.OK, marked())
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Lyrics: "[00:01.00]词"}); res.OK || !marked() {
		t.Fatalf("没落地的请求不动标记: ok=%v marked=%v", res.OK, marked())
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "save_edit", Key: editKey, Lyrics: "[00:01.00]词", Source: "qq", FromManualPick: true}); !res.OK || marked() {
		t.Fatalf("采纳候选之后撤掉标记: ok=%v marked=%v", res.OK, marked())
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: editKey, Value: true}); !res.OK || !marked() {
		t.Fatalf("重新标上: ok=%v marked=%v", res.OK, marked())
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "save_plain_text", Key: editKey, PlainLyrics: "纯文本", PlainLyricsSource: "lrclib"}); !res.OK || marked() {
		t.Fatalf("采纳纯文本之后撤掉标记: ok=%v marked=%v", res.OK, marked())
	}
}

// 标了纯音乐就不把歌词交给网页 / ListenBrainz(封面、链接照旧);歌词还在条目里。
func TestInstrumentalHidesLyricsFromExport(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]词", LyricsTr: "tr", LyricsRoma: "roma", LyricsYRC: "yrc", LyricsSource: "qq", CoverURL: "https://c/1.jpg"}
	if f := e.fields(); f["lyrics"] == "" || f["lyrics_yrc"] == "" || f["lyrics_source"] != "qq" {
		t.Fatalf("没标纯音乐照常导出: %v", f)
	}
	e.Instrumental = true
	f := e.fields()
	for _, k := range []string{"lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc", "lyrics_source"} {
		if _, ok := f[k]; ok {
			t.Errorf("标了纯音乐不导出 %s", k)
		}
	}
	if f["cover_url"] == "" || e.Lyrics == "" {
		t.Errorf("封面照旧,条目里的歌词留着: %v", f)
	}
	// 只存着歌词的条目:标上之后字段表也不能是空的,空表会让换曲那条 playing_now 当成还没解析、白等 pnPendingMax。
	if f := (enrichEntry{Lyrics: "[00:01.00]词", LyricsSource: "qq", Instrumental: true}).fields(); len(f) == 0 {
		t.Errorf("只存着歌词的条目标了纯音乐,字段表变空了")
	}
}

// 标了纯音乐就不再替它自动搜歌词:首次补全、重新打分、升级重试、按专辑 / 播放器触发的几条升级重查都跳过;
// 机翻补译文、补背景人声、补演唱者标注也不跑。
func TestInstrumentalStopsAutomaticLyricsWork(t *testing.T) {
	setFeatureForTest(t, func(f *featureFlags) {
		f.LyricsMachineTranslation = true
		f.LyricsTranslationLanguage = "zh"
	})
	cases := []struct {
		name string
		e    enrichEntry
		due  func(enrichEntry) bool
	}{
		{"首次补全", enrichEntry{}, needsLyricsFirstFill},
		{"重新打分", enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion - 1},
			func(e enrichEntry) bool { return needsLyricsRescore(e, false, true) }},
		{"升级重试", enrichEntry{Lyrics: "x"},
			func(e enrichEntry) bool { return needsLyricsRetry(e, true, false, true) }},
		{"机翻补译文", enrichEntry{Lyrics: "[00:01.00]hello world"},
			func(e enrichEntry) bool { return needsTranslationBackfill(e, "") }},
		{"补背景人声", enrichEntry{Lyrics: "[00:01.00]x", LyricsSource: "amll"}, needsBackgroundVocalsBackfill},
		{"补演唱者标注", spkBackfillEntry(),
			func(e enrichEntry) bool { return needsLyricSpeakersBackfill(e, "A & B", "Song") }},
		{"专辑登记重查", enrichEntry{Lyrics: "x", YouTubeMusicAlbum: "Album"},
			func(e enrichEntry) bool { return listedAlbumLyricsWorthRecheck(e, "", false, true) }},
		{"KKBOX 本地歌词", enrichEntry{},
			func(e enrichEntry) bool { return kkboxLyricsWorthRecheck(e, kkboxBundleID, false, true, true) }},
		{"Amazon 本地歌词", enrichEntry{},
			func(e enrichEntry) bool { return amazonLyricsWorthRecheck(e, amazonMusicBundleID, false, true, true) }},
		{"Spotify 本地歌词", enrichEntry{},
			func(e enrichEntry) bool { return spotifyLyricsWorthRecheck(e, spotifyBundleID, false, true, true) }},
		{"Kaset 自带歌词", enrichEntry{Lyrics: "x", LyricsSource: "qq"},
			func(e enrichEntry) bool {
				return kasetLyricsWorthRecheck(e, kasetBundleID, "aaaaaaaaaaa", "bbbbbbbbbbb", false, true, true)
			}},
	}
	for _, c := range cases {
		if !c.due(c.e) {
			t.Errorf("%s: 没标纯音乐时该触发(样例不对)", c.name)
		}
		c.e.Instrumental = true
		if c.due(c.e) {
			t.Errorf("%s: 标了纯音乐不该再自动搜", c.name)
		}
	}
}

// 手动重新匹配这一轮换了词(正文、逐字、来源、纯文本)才撤纯音乐标记;没换不动,自动路径永远不撤。
func TestRematchClearsInstrumental(t *testing.T) {
	before := enrichEntry{Lyrics: "[00:01.00]a", LyricsSource: "qq", Instrumental: true}
	with := func(f func(*enrichEntry)) enrichEntry {
		e := before
		f(&e)
		return e
	}
	for _, c := range []struct {
		name   string
		manual bool
		after  enrichEntry
		want   bool
	}{
		{"换了正文", true, with(func(e *enrichEntry) { e.Lyrics = "[00:01.00]b" }), true},
		{"补上逐字", true, with(func(e *enrichEntry) { e.LyricsYRC = "[1000,500]a" }), true},
		{"换了来源", true, with(func(e *enrichEntry) { e.LyricsSource = "kugou" }), true},
		{"采纳纯文本", true, with(func(e *enrichEntry) { e.PlainLyrics = "a" }), true},
		{"没换词", true, before, false},
		{"本来就没标", true, with(func(e *enrichEntry) { e.Instrumental = false; e.Lyrics = "[00:01.00]b" }), false},
		{"自动路径换了词", false, with(func(e *enrichEntry) { e.Lyrics = "[00:01.00]b" }), false},
	} {
		if got := rematchClearsInstrumental(c.manual, before, c.after); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 补空和重新打分两条写回路径都在报结论之前过一遍 rematchClearsInstrumental。
func TestRematchClearsInstrumentalIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	wire := "\tif rematchClearsInstrumental(opts.manual, before, e) {\n\t\te.Instrumental = false\n\t}\n\topts.finish("
	if n := strings.Count(string(b), wire); n != 2 {
		t.Errorf("retryLyricsUpgradeWith / rescoreLyricsWith 报结论前要撤标,接上的有 %d 处", n)
	}
}

// 缓存里还没有这首时不建条目:标上回报失败,撤标什么都不做;有条目照常标。
func TestSetInstrumentalNeedsCachedEntry(t *testing.T) {
	setUpEnrichEditTest(t, map[string]enrichEntry{editKey: {TS: 1}})
	missing := enrichKey("Nobody", "Nothing", "Nowhere")
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: missing, Value: true}); res.OK {
		t.Fatalf("没有条目时标上该回报失败: %+v", res)
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: missing, Value: false}); !res.OK {
		t.Fatalf("没有条目时撤标没什么可撤,该回报成功: %+v", res)
	}
	if _, ok := cacheEntry(t, missing); ok {
		t.Fatal("没有条目时不该建出条目")
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: editKey, Value: true}); !res.OK {
		t.Fatalf("有条目照常标: %+v", res)
	}
	if e, _ := cacheEntry(t, editKey); !e.Instrumental || e.TS != 1 {
		t.Fatalf("标上之后: %+v", e)
	}
}

// 用户撤掉纯音乐标记就记下来,自动加标的路径不再标回去;重新标上时作废。本来没标着的撤标不记。
func TestSetInstrumentalRemembersUserClear(t *testing.T) {
	marked := enrichKey("A", "Marked", "X")
	plain := enrichKey("A", "Plain", "X")
	setUpEnrichEditTest(t, map[string]enrichEntry{
		marked: {Lyrics: "[00:01.00]a", Instrumental: true},
		plain:  {Lyrics: "[00:01.00]b"},
	})
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Keys: []string{marked, plain}, Value: false}); !res.OK {
		t.Fatalf("res=%+v", res)
	}
	if e, _ := cacheEntry(t, marked); e.Instrumental || !e.InstrumentalCleared || e.autoMarksInstrumental() {
		t.Errorf("撤掉的标记要记下来、自动路径不再标: %+v", e)
	}
	if e, _ := cacheEntry(t, plain); e.InstrumentalCleared {
		t.Error("本来就没标的,撤标不算用户说过什么")
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: marked, Value: true}); !res.OK {
		t.Fatalf("res=%+v", res)
	}
	if e, _ := cacheEntry(t, marked); !e.Instrumental || e.InstrumentalCleared {
		t.Errorf("重新标上时撤标的记录作废: %+v", e)
	}
}
