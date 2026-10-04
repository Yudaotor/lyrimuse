package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// 手改过 = 锁定着、正文已经不是原样采纳的那份候选。没锁、或者锁着但正文还是采纳时那一份,都不算。
func TestLyricsHandEdited(t *testing.T) {
	lyrics := "[00:01.00]一\n[00:02.00]二"
	for _, c := range []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"没锁", enrichEntry{Lyrics: lyrics}, false},
		{"锁着、没有采纳指纹", enrichEntry{Lyrics: lyrics, ManualLyrics: true}, true},
		{"锁着、正文还是采纳的那份", enrichEntry{Lyrics: lyrics, ManualLyrics: true, ManualPickSHA: manualPickFingerprint(lyrics)}, false},
		{"锁着、采纳之后又改过", enrichEntry{Lyrics: lyrics + "\n[00:03.00]三", ManualLyrics: true, ManualPickSHA: manualPickFingerprint(lyrics)}, true},
	} {
		if got := c.e.lyricsHandEdited(); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 采纳候选:背景人声与译文语言换成候选自己的,背景人声记成按当前解析器取过,演唱者标注清掉「补过」重新问。
// 不是采纳候选的保存照旧:正文一换背景人声清掉,译文一换语言清掉。
func TestApplySaveEditAdoptCarriesCandidateExtras(t *testing.T) {
	bg, lang := "[1000,500](1000,500,0)ooh", "zh-Hant"
	e := enrichEntry{Lyrics: "[00:01.00]旧", LyricsTr: "[00:01.00]old", LyricsTrLang: "en", LyricsBG: "old-bg", LyricsSpeakersChecked: lyricsSpeakersVersion}
	req := enrichEditRequest{Lyrics: "[00:01.00]新", Tr: "[00:01.00]新的譯文", Source: "amll", MarkManual: true, FromManualPick: true, BG: &bg, TrLang: &lang}
	if err := applySaveEdit(&e, req); err != nil {
		t.Fatal(err)
	}
	if e.LyricsBG != bg || e.LyricsBGChecked != lyricsBGParserVersion {
		t.Errorf("背景人声该换成候选的: %q checked=%d", e.LyricsBG, e.LyricsBGChecked)
	}
	if e.LyricsTrLang != lang {
		t.Errorf("译文语言该换成候选的: %q", e.LyricsTrLang)
	}
	if e.LyricsSpeakersChecked != 0 {
		t.Errorf("演唱者标注该重新问: checked=%d", e.LyricsSpeakersChecked)
	}
	if e.lyricsHandEdited() {
		t.Error("原样采纳的候选不算手改")
	}

	e = enrichEntry{Lyrics: "[00:01.00]旧", LyricsTr: "[00:01.00]old", LyricsTrLang: "en", LyricsBG: "old-bg", LyricsBGChecked: lyricsBGParserVersion}
	if err := applySaveEdit(&e, enrichEditRequest{Lyrics: "[00:01.00]手改", Tr: "[00:01.00]改", MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsBG != "" || e.LyricsTrLang != "" {
		t.Errorf("手改保存:背景人声与译文语言都该清掉: bg=%q lang=%q", e.LyricsBG, e.LyricsTrLang)
	}
}

// 采纳候选时罗马音过一遍自动选中时的规则:粤语歌的普通话拼音清掉、补上粤拼,台语歌的罗马音清掉。
// 手改保存不动罗马音。
func TestApplySaveEditAdoptRomaRules(t *testing.T) {
	pinyin := "[00:01.00]wo ai ni zhong guo shi jie"
	adopt := func(lang, roma string) enrichEntry {
		e := enrichEntry{SongLanguage: lang, Lyrics: "[00:01.00]舊", LyricsRoma: "x"}
		if err := applySaveEdit(&e, enrichEditRequest{Lyrics: "[00:01.00]我愛你", Roma: roma, MarkManual: true, FromManualPick: true}); err != nil {
			t.Fatal(err)
		}
		return e
	}
	if e := adopt(songLanguageCantonese, pinyin); e.LyricsRoma == "" || e.LyricsRoma == pinyin {
		t.Errorf("粤语歌:普通话拼音该换成粤拼: %q", e.LyricsRoma)
	}
	if e := adopt(songLanguageHokkien, pinyin); e.LyricsRoma != "" {
		t.Errorf("台语歌:罗马音该清掉: %q", e.LyricsRoma)
	}
	if e := adopt(songLanguageMandarin, pinyin); e.LyricsRoma != pinyin {
		t.Errorf("国语歌:罗马音照留: %q", e.LyricsRoma)
	}
	e := enrichEntry{SongLanguage: songLanguageCantonese, Lyrics: "[00:01.00]舊"}
	if err := applySaveEdit(&e, enrichEditRequest{Lyrics: "[00:01.00]我愛你", Roma: pinyin, MarkManual: true}); err != nil {
		t.Fatal(err)
	}
	if e.LyricsRoma != pinyin {
		t.Errorf("手改保存不动罗马音: %q", e.LyricsRoma)
	}
}

// 原样采纳的候选照常补背景人声与演唱者标注;手改过的不补。
func TestBackfillsCoverAdoptedCandidates(t *testing.T) {
	adopted := func(e enrichEntry) enrichEntry {
		e.ManualLyrics, e.ManualPickSHA = true, manualPickFingerprint(e.Lyrics)
		return e
	}
	handEdited := func(e enrichEntry) enrichEntry {
		e.ManualLyrics, e.ManualPickSHA = true, ""
		return e
	}
	bg := enrichEntry{Lyrics: "[00:01.00]一", LyricsSource: "amll"}
	if !needsBackgroundVocalsBackfill(adopted(bg)) {
		t.Error("原样采纳的 amll 候选该补背景人声")
	}
	if needsBackgroundVocalsBackfill(handEdited(bg)) {
		t.Error("手改过的不补背景人声")
	}
	sp := spkBackfillEntry()
	if !needsLyricSpeakersBackfill(adopted(sp), "A & B", "Song") {
		t.Error("原样采纳的候选该补演唱者标注")
	}
	if needsLyricSpeakersBackfill(handEdited(sp), "A & B", "Song") {
		t.Error("手改过的不补演唱者标注")
	}
}

// 采纳候选的两个字段两侧同名:App 解码候选读的键 = 引擎候选的 JSON 名,App 交给 save_edit 的键 = 编辑请求的 JSON 名。
func TestAdoptExtrasFieldNamesMatchTheApp(t *testing.T) {
	tag := func(v any, field string) string {
		f, ok := reflect.TypeOf(v).FieldByName(field)
		if !ok {
			t.Fatalf("没有字段 %s", field)
		}
		return strings.Split(f.Tag.Get("json"), ",")[0]
	}
	read := func(rel string) string {
		b, err := os.ReadFile("../lyrimuse/Sources/lyrimuse/LyricsManager/" + rel)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	service, store := read("LyricsSearchService.swift"), read("EnrichCacheStore.swift")
	for _, f := range []string{"LyricsBG", "LyricsTrLang"} {
		if k := tag(scoredLyricCandidateResult{}, f); !strings.Contains(service, `"`+k+`"`) {
			t.Errorf("LyricsSearchService.swift 没按 %q 解码候选的 %s", k, f)
		}
	}
	for _, f := range []string{"BG", "TrLang"} {
		if k := tag(enrichEditRequest{}, f); !strings.Contains(store, `fields["`+k+`"]`) {
			t.Errorf("EnrichCacheStore.swift 的 saveEdit 没按 %q 交 %s", k, f)
		}
	}
}
