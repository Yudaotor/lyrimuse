package main

import (
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// 同一首歌的几条写法歌词一字不差时机翻只做一次:先借,翻成了再填给别的写法(18 章决策 36)。
func setUpTranslateShareTest(t *testing.T, entries map[string]enrichEntry) *int32 {
	t.Helper()
	var calls int32
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = fakeTranslated("译", lines[i])
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	savedFeatures, savedCache, savedPath, savedBase, savedDir, savedClient, savedInflight :=
		features(), enrichCache, enrichPath, translateBaseURL, lyricsDir(), translateClient, translationInflight
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		enrichCache, enrichPath, translateBaseURL, translateClient, translationInflight =
			savedCache, savedPath, savedBase, savedClient, savedInflight
		setLyricsDir(savedDir)
	})
	featuresRef().LyricsMachineTranslation = true
	featuresRef().LyricsTranslationLanguage = "zh"
	translateBaseURL = srv.URL
	translateClient = srv.Client()
	setLyricsDir("")
	enrichPath = filepath.Join(t.TempDir(), "enrich-cache.json")
	enrichCache = entries
	translationInflight = map[string]bool{}
	return &calls
}

const translateShareLyrics = "[00:01.00]The painful youth\n[00:02.00]I have had"

func TestBackfillTranslationBorrowsFromSameSong(t *testing.T) {
	borrowed := "[00:01.00]痛苦的青春\n[00:02.00]我经历过"
	calls := setUpTranslateShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_1", Lyrics: translateShareLyrics, LyricsTr: borrowed, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"},
		"A|Song|Two": {Song: "s_1", Lyrics: translateShareLyrics, TranslationRetryCount: 2},
	})
	backfillTranslation("A|Song|Two")
	if got := enrichCache["A|Song|Two"]; got.LyricsTr != borrowed || got.LyricsTrSource != lyricsTrSourceMachine ||
		got.LyricsTrLang != "zh-CN" || got.TranslationRetryCount != 0 {
		t.Errorf("借同一首歌、同一份歌词的机翻: %+v", got)
	}
	if atomic.LoadInt32(calls) != 0 {
		t.Errorf("借到了就不发请求: %d", *calls)
	}
}

func TestBackfillTranslationDoesNotBorrowOtherTranslations(t *testing.T) {
	for name, src := range map[string]enrichEntry{
		"别的语言的机翻": {LyricsTr: "[00:01.00]youth ja\n[00:02.00]had ja", LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "ja"},
		"社区译文":    {LyricsTr: "[00:01.00]痛苦的青春\n[00:02.00]我经历过", LyricsTrLang: "zh-CN"},
		"没记语言的机翻": {LyricsTr: "[00:01.00]痛苦的青春\n[00:02.00]我经历过", LyricsTrSource: lyricsTrSourceMachine},
	} {
		t.Run(name, func(t *testing.T) {
			src.Song, src.Lyrics = "s_1", translateShareLyrics
			calls := setUpTranslateShareTest(t, map[string]enrichEntry{
				"A|Song|One": src,
				"A|Song|Two": {Song: "s_1", Lyrics: translateShareLyrics},
			})
			backfillTranslation("A|Song|Two")
			if got := enrichCache["A|Song|Two"]; got.LyricsTr == src.LyricsTr || atomic.LoadInt32(calls) == 0 {
				t.Errorf("不借,自己翻: %+v calls=%d", got, *calls)
			}
		})
	}
}

func TestBackfillTranslationSharesWithSameSong(t *testing.T) {
	community := "[00:01.00]社区的译文\n[00:02.00]第二行"
	setUpTranslateShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_1", Lyrics: translateShareLyrics},
		"A|Song|Two":   {Song: "s_1", Lyrics: translateShareLyrics},
		"A|Song|Three": {Song: "s_1", Lyrics: translateShareLyrics, Instrumental: true},
		"A|Song|Four":  {Song: "s_1", Lyrics: translateShareLyrics, LyricsTr: community, LyricsTrLang: "zh-CN"},
		"A|Song|Five":  {Song: "s_1", Lyrics: "[00:01.00]Another body"},
		"B|Other|One":  {Song: "s_2", Lyrics: translateShareLyrics},
		"C|None|One":   {Lyrics: translateShareLyrics},
	})
	backfillTranslation("A|Song|One")
	tr := enrichCache["A|Song|One"].LyricsTr
	if tr == "" {
		t.Fatal("没翻出来")
	}
	if got := enrichCache["A|Song|Two"]; got.LyricsTr != tr || got.LyricsTrSource != lyricsTrSourceMachine || got.LyricsTrLang != "zh-CN" {
		t.Errorf("同一首歌、同一份歌词的写法跟着用上: %+v", got)
	}
	for k, want := range map[string]string{"A|Song|Three": "", "A|Song|Four": community, "A|Song|Five": "", "B|Other|One": "", "C|None|One": ""} {
		if got := enrichCache[k].LyricsTr; got != want {
			t.Errorf("%s 不动: %q", k, got)
		}
	}
}
