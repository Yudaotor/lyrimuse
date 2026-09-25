package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 外文只有署名行 / 抬头行的中文歌:执行时这些行会被剔掉、一行不剩,触发判断也必须判不用翻,
// 否则每 6 小时白跑一次、三次后把重试额度用光。
func TestNeedsTranslationBackfillSkipsCreditOnlyForeignLines(t *testing.T) {
	saved := features()
	defer func() { setFeatures(saved) }()
	featuresRef().LyricsMachineTranslation = true
	featuresRef().LyricsTranslationLanguage = "zh"

	key := enrichKey("方大同", "南音", "Soulboy")
	creditOnly := enrichEntry{Lyrics: "[00:00.50]南音 - 方大同\n[00:01.00]制作人 : 方大同/Edward Chan/Charles Lee\n" +
		"[00:10.00]让我们唱一首南音\n[00:15.00]慢慢地走"}
	if needsTranslationBackfill(creditOnly, key) {
		t.Fatal("外文只有署名行时不该起机翻")
	}
	if work := selectTranslationWork(creditOnly.Lyrics, "zh-CN", "方大同", "南音"); len(work.uniqueTexts) != 0 {
		t.Fatalf("执行侧同样一行不送: %v", work.uniqueTexts)
	}
	withLyric := creditOnly
	withLyric.Lyrics += "\n[00:20.00]It represent my heart"
	if !needsTranslationBackfill(withLyric, key) {
		t.Fatal("有真歌词外文行时要翻")
	}
}

// 端上翻译成功返回、但几乎全是原样吐回来的行:退到网络翻译,而不是直接当成"没翻出来"记一次失败。
func TestOnDeviceUntranslatedFallsBackToNetwork(t *testing.T) {
	saved := onDeviceTranslator
	onDeviceTranslator = func(_ context.Context, _ string, lines []string) ([]string, error) {
		return append([]string(nil), lines...), nil // 全部原样
	}
	t.Cleanup(func() { onDeviceTranslator = saved })
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		var out []string
		for _, l := range strings.Split(r.PostForm.Get("q"), "\n") {
			out = append(out, "译:"+l)
		}
		fmt.Fprint(w, googleReply(t, out))
	})
	lrc := "[00:01.00]one\n[00:02.00]two\n[00:03.00]three"
	res, err := machineTranslateLRCWithBase(context.Background(), http.DefaultClient, "http://127.0.0.1:1", lrc, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.lrc, "译:one") {
		t.Fatalf("端上翻空之后该用 Google 的结果, got %q", res.lrc)
	}

	// 端上真翻出来了就直接用,不再打网络。
	onDeviceTranslator = func(_ context.Context, _ string, lines []string) ([]string, error) {
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = "端:" + l
		}
		return out, nil
	}
	res, err = machineTranslateLRCWithBase(context.Background(), http.DefaultClient, "http://127.0.0.1:1", lrc, "zh-CN", "", "")
	if err != nil || !strings.Contains(res.lrc, "端:one") {
		t.Fatalf("端上翻成了就用端上的: %q %v", res.lrc, err)
	}
}

// 运行中改译文语言(热重读,不重启):旧语言的机翻清掉、导出的 .tr.lrc 删掉;社区译文不动。
func TestTranslationLanguageHotReloadClearsStaleMachineTranslations(t *testing.T) {
	machine := enrichKey("Utada", "First Love", "")
	community := enrichKey("Other", "Song", "")
	lyricsDir, _ := setUpEnrichEditTest(t, map[string]enrichEntry{
		machine:   {Lyrics: "[00:01.00]hello", LyricsTr: "[00:01.00]hello en", LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "en", TS: 1},
		community: {Lyrics: "[00:01.00]hi", LyricsTr: "[00:01.00]嗨", LyricsTrLang: "zh", TS: 1},
	})
	exportLyricsFilesFor(machine, community)
	trFiles := func() []string {
		m, _ := filepath.Glob(filepath.Join(lyricsDir, "*.tr.lrc"))
		return m
	}
	if n := len(trFiles()); n != 2 {
		t.Fatalf("前置:两份译文文件都该导出, got %d", n)
	}

	path := filepath.Join(t.TempDir(), "features.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_translation_language":"en"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	setFeaturesPath(path)
	if err := os.WriteFile(path, []byte(`{"lyrics_translation_language":"zh-Hans"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	featuresCheckedAt.Store(time.Now().Add(-2 * featuresReloadInterval).UnixNano())
	_ = features()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if e, _ := cacheEntry(t, machine); e.LyricsTr == "" && len(trFiles()) == 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if e, _ := cacheEntry(t, machine); e.LyricsTr != "" || e.LyricsTrSource != "" {
		t.Fatalf("旧语言的机翻该清掉: %+v", e)
	}
	if e, _ := cacheEntry(t, community); e.LyricsTr == "" {
		t.Fatal("社区译文不该动")
	}
	if n := len(trFiles()); n != 1 {
		t.Fatalf("机翻那份 .tr.lrc 该删掉,剩 %d 份", n)
	}
}
