package main

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
)

const kanaBackfillKey = "A|Song|"

func kanaBackfillEntry() enrichEntry {
	return enrichEntry{Lyrics: bt("[00:01.10]君と\n[00:02.10]明日へ\n"), LyricsRoma: bt("[00:01.10]kimi to\n[00:02.10]asu e"), LyricsSource: "netease"}
}

// withKanaBackfillFakes:搜索和 helper 换成假的;search / regen 为 nil 时被调到就报错。
func withKanaBackfillFakes(t *testing.T, search func(ctx context.Context) []scoredLyricCandidateResult, regen func(lyrics, stored, kana string) (string, error)) {
	t.Helper()
	setFeatureForTest(t, func(f *featureFlags) {
		f.LyricsSources = map[string]bool{"qq": true, "kugou": true, "lrclib": false, "netease": true}
	})
	savedSearch, savedRegen := kanaBackfillSearch, staleRomaRegenerator
	t.Cleanup(func() { kanaBackfillSearch, staleRomaRegenerator = savedSearch, savedRegen })
	kanaBackfillSearch = func(ctx context.Context, _, _, _ string, _ float64) []scoredLyricCandidateResult {
		if search == nil {
			t.Error("不该补问")
			return nil
		}
		return search(ctx)
	}
	staleRomaRegenerator = func(lyrics, stored, kana string) (string, error) {
		if regen == nil {
			t.Error("不该重算罗马音")
			return "", nil
		}
		return regen(lyrics, stored, kana)
	}
}

func TestNeedsLyricsKanaBackfill(t *testing.T) {
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"qq": true} })
	base := kanaBackfillEntry()
	if !needsLyricsKanaBackfill(base) {
		t.Error("没问过带标注的源的日文歌该补")
	}
	checked := base
	checked.LyricsKanaChecked = lyricsKanaVersion
	if needsLyricsKanaBackfill(checked) {
		t.Error("问过、也没借到的不再来")
	}
	checked.LyricsKana = "[kana:1きみ]\n[00:00.00]君と"
	if !needsLyricsKanaBackfill(checked) {
		t.Error("有借来的标注、罗马音是存着的那份:该交给 helper 核一次")
	}
	manual := checked
	manual.ManualLyrics = true
	if needsLyricsKanaBackfill(manual) {
		t.Error("手改过的不动罗马音")
	}
	for name, e := range map[string]enrichEntry{
		"自带标注":  {Lyrics: bt("[kana:1きみ]\n[00:01.00]君と\n")},
		"中文歌":   {Lyrics: bt("[00:01.00]我爱你中国\n")},
		"没有待标字": {Lyrics: bt("[00:01.00]きみと\n")},
		"纯音乐":   {Lyrics: base.Lyrics, Instrumental: true},
	} {
		if needsLyricsKanaBackfill(e) {
			t.Errorf("%s 不该补", name)
		}
	}
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"netease": true} })
	if needsLyricsKanaBackfill(base) {
		t.Error("带标注的源全关着时不补问")
	}
}

// 只问开着的带标注的源;借到就存、记成问过,罗马音按借来的标注重算后换上。
func TestBackfillLyricsKana(t *testing.T) {
	var asked []string
	var gotKana string
	withKanaBackfillFakes(t, func(ctx context.Context) []scoredLyricCandidateResult {
		for s := range lyricSourceOnlyFrom(ctx) {
			asked = append(asked, s)
		}
		return []scoredLyricCandidateResult{{Source: "qq", Score: 1100, Lyrics: kanaDonorSample}}
	}, func(lyrics, stored, kana string) (string, error) {
		gotKana = kana
		return "[00:01.10]kimi to\n[00:02.10]ashita e", nil
	})
	enrichCache = map[string]enrichEntry{kanaBackfillKey: kanaBackfillEntry()}
	enrichInflight[kanaBackfillKey] = true
	backfillLyricsKana(kanaBackfillKey, "A", "Song", "", 60)
	slices.Sort(asked)
	if !slices.Equal(asked, []string{"kugou", "qq"}) {
		t.Errorf("该只问开着的带标注的源: %v", asked)
	}
	e := enrichCache[kanaBackfillKey]
	if !strings.HasPrefix(e.LyricsKana, "[kana:1きみ2あした]") || e.LyricsKanaChecked != lyricsKanaVersion || gotKana != e.LyricsKana {
		t.Fatalf("没借上: kana=%q checked=%d helper 拿到 %q", e.LyricsKana, e.LyricsKanaChecked, gotKana)
	}
	if !e.LyricsRoma.EqualString("[00:01.10]kimi to\n[00:02.10]ashita e") {
		t.Errorf("罗马音没换成按借来标注重算的: %q", e.LyricsRoma.String())
	}
	if enrichInflight[kanaBackfillKey] {
		t.Error("补完要清掉 inflight")
	}
}

// 一个候选都没问到:不记成问过;问到了没借到:记成问过、不写标注、不起 helper。
func TestBackfillLyricsKanaOutcomes(t *testing.T) {
	withKanaBackfillFakes(t, func(context.Context) []scoredLyricCandidateResult { return nil }, nil)
	enrichCache = map[string]enrichEntry{kanaBackfillKey: kanaBackfillEntry()}
	backfillLyricsKana(kanaBackfillKey, "A", "Song", "", 60)
	if e := enrichCache[kanaBackfillKey]; e.LyricsKanaChecked != 0 || e.LyricsKana != "" {
		t.Errorf("没问到不该记成问过: %+v", e)
	}
	withKanaBackfillFakes(t, func(context.Context) []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{{Source: "kugou", Score: 900, Lyrics: "[00:01.00]別の歌\n"}}
	}, nil)
	backfillLyricsKana(kanaBackfillKey, "A", "Song", "", 60)
	if e := enrichCache[kanaBackfillKey]; e.LyricsKanaChecked != lyricsKanaVersion || e.LyricsKana != "" || !e.LyricsRoma.Equal(kanaBackfillEntry().LyricsRoma) {
		t.Errorf("问到了没借到:只记成问过: %+v", e)
	}
}

// 已经问过、有借来的标注:不再补问,只让 helper 核罗马音;helper 说不是我们生成的就不动。
func TestBackfillLyricsKanaRomaOnly(t *testing.T) {
	e := kanaBackfillEntry()
	e.LyricsKana, e.LyricsKanaChecked = "[kana:1きみ2あした]\n[00:00.00]君と\n[00:00.00]明日へ", lyricsKanaVersion
	withKanaBackfillFakes(t, nil, func(lyrics, stored, kana string) (string, error) { return "", nil })
	enrichCache = map[string]enrichEntry{kanaBackfillKey: e}
	backfillLyricsKana(kanaBackfillKey, "A", "Song", "", 60)
	if got := enrichCache[kanaBackfillKey]; !got.LyricsRoma.Equal(e.LyricsRoma) || got.LyricsKana != e.LyricsKana {
		t.Errorf("helper 判不是我们生成的,不该动: %+v", got)
	}
	withKanaBackfillFakes(t, nil, func(lyrics, stored, kana string) (string, error) { return "[00:01.10]kimi to\n[00:02.10]ashita e", nil })
	backfillLyricsKana(kanaBackfillKey, "A", "Song", "", 60)
	if got := enrichCache[kanaBackfillKey]; !got.LyricsRoma.EqualString("[00:01.10]kimi to\n[00:02.10]ashita e") {
		t.Errorf("该换成重算的: %q", got.LyricsRoma.String())
	}
}

// 补问这段时间里正文被换了:借来的、重算的都不写,也不记成问过。
func TestBackfillLyricsKanaLyricsChangedMeanwhile(t *testing.T) {
	withKanaBackfillFakes(t, func(context.Context) []scoredLyricCandidateResult {
		enrichMu.Lock()
		e := enrichCache[kanaBackfillKey]
		e.Lyrics = bt("[00:01.10]君と\n[00:02.10]明日へ\n[00:03.10]夢を見た\n")
		enrichCache[kanaBackfillKey] = e
		enrichMu.Unlock()
		return []scoredLyricCandidateResult{{Source: "qq", Score: 1100, Lyrics: kanaDonorSample}}
	}, func(lyrics, stored, kana string) (string, error) { return "[00:01.10]x", nil })
	enrichCache = map[string]enrichEntry{kanaBackfillKey: kanaBackfillEntry()}
	backfillLyricsKana(kanaBackfillKey, "A", "Song", "", 60)
	if e := enrichCache[kanaBackfillKey]; e.LyricsKana != "" || e.LyricsKanaChecked != 0 || !e.LyricsRoma.Equal(kanaBackfillEntry().LyricsRoma) {
		t.Errorf("正文中途被换了还写了: %+v", e)
	}
}

// 播放到时的派发链里有这一路。
func TestLyricsKanaBackfillIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(b), "} else if needsLyricsKanaBackfill(e) && !enrichInflight[key] && kanaBackfillOnce(key) {\n") ||
		!containsCode(string(b), "go backfillLyricsKana(key, artist, title, album, durationSecs)\n") {
		t.Error("trackEnrichment 的派发链缺补借假名标注")
	}
}
