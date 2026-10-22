package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// 外层限定了只问哪几个源(存量补假名)时,补查轮(别名、曲名写法、原产地曲名、ISRC)的名单不越出这几个。
func TestLyricSourcesWorthRetryStaysInsideOuterOnly(t *testing.T) {
	setFeatureForTest(t, func(f *featureFlags) {
		f.LyricsSources = map[string]bool{"qq": true, "kugou": true, "netease": true}
	})
	if all := lyricSourcesWorthRetry(context.Background(), nil); !slices.Contains(all, "netease") {
		t.Fatalf("前提:不限定时网易云在名单里: %v", all)
	}
	got := lyricSourcesWorthRetry(withLyricSourceOnly(context.Background(), []string{"qq", "kugou"}), nil)
	if !slices.Contains(got, "qq") {
		t.Errorf("限定里的源该留着: %v", got)
	}
	for _, s := range got {
		if s != "qq" && s != "kugou" {
			t.Errorf("越出外层限定: %v", got)
		}
	}
}

// 补问带着用户存的检索曲名去搜。
func TestBackfillLyricsKanaKeepsSearchTitle(t *testing.T) {
	var got string
	withKanaBackfillFakes(t, func(ctx context.Context) []scoredLyricCandidateResult {
		got = lyricSearchTitleFor(ctx, "Song")
		return nil
	}, nil)
	enrichCache = map[string]enrichEntry{kanaBackfillKey: kanaBackfillEntry()}
	enrichInflight[kanaBackfillKey] = true
	backfillLyricsKana(withLyricSearchTitle(context.Background(), "Song (Official Audio)"), kanaBackfillKey, "A", "Song", "", 60)
	if got != "Song (Official Audio)" {
		t.Errorf("补问没带检索曲名: %q", got)
	}
}

// 同一进程里同一份标注、正文、罗马音只补一次;标注换了(别的路径新借到)再补一次。
func TestKanaBackfillOnceFollowsFingerprint(t *testing.T) {
	saved := kanaBackfillTried
	kanaBackfillTried = map[string]string{}
	t.Cleanup(func() { kanaBackfillTried = saved })
	e := kanaBackfillEntry()
	if !kanaBackfillOnce("k", e) || kanaBackfillOnce("k", e) {
		t.Fatal("同一份只补一次")
	}
	e.LyricsKana = "[kana:1きみ2あした]\n[00:00.00]君と\n[00:00.00]明日へ"
	if !kanaBackfillOnce("k", e) {
		t.Error("标注换了该再补一次")
	}
}

// 换上的正文对不上旧标注、整份清掉时「问过」作废;这一轮带标注的源出过候选的话照样记上。
func TestRefreshKanaResetsCheckedWhenKanaDropped(t *testing.T) {
	entry := func() enrichEntry {
		return enrichEntry{Lyrics: bt("[00:01.00]全然違う言葉だ\n[00:02.00]別の歌になった"),
			LyricsKana: "[kana:1きみ2あした]\n[00:00.00]君と\n[00:00.00]明日へ", LyricsKanaChecked: lyricsKanaVersion}
	}
	e := entry()
	refreshKana(&e, nil)
	if e.LyricsKana != "" || e.LyricsKanaChecked != 0 {
		t.Errorf("清掉标注后该重新补问: kana=%q checked=%d", e.LyricsKana, e.LyricsKanaChecked)
	}
	e = entry()
	refreshKana(&e, []scoredLyricCandidateResult{{Source: "qq", Score: 100, Lyrics: "[00:01.00]x"}})
	if e.LyricsKanaChecked != lyricsKanaVersion {
		t.Errorf("这一轮问到了带标注的源要记成问过: %d", e.LyricsKanaChecked)
	}
}

// 条目全是不带读音的行(酷狗给署名行的「1」)不算借到;只靠它们凑不够行数,也压不过真带读音的那家。
func TestKanaDonorSkipsLinesWithoutReadings(t *testing.T) {
	lyrics := "[00:01.00]作詞：秋元\n[00:02.00]作曲：山田\n[00:03.00]編曲：佐藤\n[00:04.00]君と\n[00:05.00]明日へ\n"
	credits := scoredLyricCandidateResult{Source: "kugou", Score: 100,
		Lyrics: "[kana:111111111111]\n[00:01.00]作詞：秋元\n[00:02.00]作曲：山田\n[00:03.00]編曲：佐藤\n"}
	if got := kanaDonorLRC(lyrics, "", []scoredLyricCandidateResult{credits}); got != "" {
		t.Errorf("只有空读音的行不该借: %q", got)
	}
	real := scoredLyricCandidateResult{Source: "qq", Score: 100, Lyrics: "[kana:1きみ2あした]\n[00:04.00]君と\n[00:05.00]明日へ\n"}
	if got := kanaDonorLRC(lyrics, "", []scoredLyricCandidateResult{credits, real}); !strings.HasPrefix(got, "[kana:1きみ2あした]") {
		t.Errorf("该借真带读音的那家: %q", got)
	}
}

// 正文自己的 `[kana:]` 对不齐时 App 退回借来的那份,引擎照常借;对得齐才不借。
func TestKanaDonorBorrowsWhenOwnKanaMisaligned(t *testing.T) {
	donor := []scoredLyricCandidateResult{{Source: "qq", Score: 100, Lyrics: kanaDonorSample}}
	misaligned := "[kana:1きみ]\n[00:01.00]君と\n[00:02.00]明日へ\n"
	if got := nextLyricsKana("", misaligned, "", donor); !strings.Contains(got, "2あした") {
		t.Errorf("自带标注对不齐时该借: %q", got)
	}
	if !kanaSongNeedsReading(enrichEntry{Lyrics: bt(misaligned)}) {
		t.Error("自带标注对不齐的歌该补问")
	}
	aligned := "[kana:1きみ2あした]\n[00:01.00]君と\n[00:02.00]明日へ\n"
	if got := nextLyricsKana("", aligned, "", donor); got != "" {
		t.Errorf("自带标注对得齐时不借: %q", got)
	}
}

// 从歌词文件导入换了正文:借来的标注对到新正文上,对不上的行去掉。
func TestImportRefitsBorrowedKana(t *testing.T) {
	const key = "A|Song|"
	lyrics := "[00:01.00]君と\n[00:02.00]明日へ"
	kana := kanaDonorLRC(lyrics, "", []scoredLyricCandidateResult{{Source: "qq", Score: 100, Lyrics: kanaDonorSample}})
	if kana == "" {
		t.Fatal("前提:借得到")
	}
	dir := withExportFixture(t, map[string]enrichEntry{key: {Lyrics: bt(lyrics), LyricsSource: "netease", LyricsKana: kana}})
	exportLyricsFiles()
	path := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")
	orig, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	changed := strings.Replace(strings.Replace(string(orig), "君と", "全然違う", 1), "明日へ", "別の言葉", 1)
	if err := os.WriteFile(path, []byte(changed), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	enrichMu.Lock()
	got := enrichCache[key]
	enrichMu.Unlock()
	if !got.Lyrics.EqualString(strings.Replace(strings.Replace(lyrics, "君と", "全然違う", 1), "明日へ", "別の言葉", 1)) {
		t.Fatalf("前提:正文换成了文件里的: %q", got.Lyrics.String())
	}
	if got.LyricsKana != "" {
		t.Errorf("对不上新正文的借来标注该去掉: %q", got.LyricsKana)
	}
}
