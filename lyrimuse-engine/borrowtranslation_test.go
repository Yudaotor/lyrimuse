package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// 日文正文 n 行,时间戳从 startMs 起每行 4 秒;tr 为真时另给一份照这份时间戳写的中文译文。
func borrowJaLyrics(n, startMs int, tr bool) (string, string) {
	var lrc, trb strings.Builder
	for i := 0; i < n; i++ {
		ts := formatLRCTime(startMs + i*4000)
		lrc.WriteString(fmt.Sprintf("%s君の名前を呼んだ%d回目の夜\n", ts, i))
		if tr {
			trb.WriteString(fmt.Sprintf("%s第%d次呼唤你名字的夜晚\n", ts, i))
		}
	}
	return lrc.String(), trb.String()
}

func withTranslationTarget(t *testing.T, lang string) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsTranslationLanguage: lang})
}

func TestBorrowedTranslationMovesOntoOwnStamps(t *testing.T) {
	own, _ := borrowJaLyrics(10, 10000, false)
	donor, donorTr := borrowJaLyrics(10, 10150, true)
	got, ok := borrowedTranslation(own, donor, donorTr)
	if !ok {
		t.Fatal("正文逐行相同,应借到译文")
	}
	lines := strings.Split(got, "\n")
	if len(lines) != 10 || lines[0] != formatLRCTime(10000)+"第0次呼唤你名字的夜晚" || lines[9] != formatLRCTime(46000)+"第9次呼唤你名字的夜晚" {
		t.Fatalf("译文要挂在这一份自己的时间戳下,得到:\n%s", got)
	}
}

func TestBorrowedTranslationNeedsCoverage(t *testing.T) {
	own, _ := borrowJaLyrics(10, 10000, false)
	donor, donorTr := borrowJaLyrics(5, 10000, true) // 只配得上一半
	if _, ok := borrowedTranslation(own, donor, donorTr); ok {
		t.Fatal("配上的行不到六成不该借")
	}
	other := strings.ReplaceAll(donor, "君の名前を呼んだ", "まったく別の歌の")
	if _, ok := borrowedTranslation(own, other, donorTr); ok {
		t.Fatal("正文对不上不该借")
	}
	short, _ := borrowJaLyrics(3, 10000, false)
	shortDonor, shortTr := borrowJaLyrics(3, 10000, true)
	if _, ok := borrowedTranslation(short, shortDonor, shortTr); ok {
		t.Fatalf("不到 %d 行不该借", borrowTranslationMinLines)
	}
}

func TestBorrowedTranslationStampsAndTags(t *testing.T) {
	own := "[offset:300]\n[00:10.00][01:10.00]サビの一行目\n[00:14.00]v1：二行目の歌詞\n[00:18.00]三行目の歌詞\n[00:22.00]作詞：誰か\n[00:26.00]四行目の歌詞\n"
	donor := "[00:10.10][01:10.10]サビの一行目\n[00:14.10]二行目の歌詞\n[00:18.10]三行目の歌詞\n[00:26.10]四行目の歌詞\n"
	// 一行目两个戳都有译文;二行目的译文戳偏了 15ms 仍配得上;三行目偏 60ms 配不上。
	donorTr := "[00:10.10][01:10.10]副歌第一行\n[00:14.11]第二行\n[00:18.16]第三行\n[00:26.10]第四行\n"
	got, ok := borrowedTranslation(own, donor, donorTr)
	if !ok {
		t.Fatal("应借到译文")
	}
	want := "[offset:300]\n[00:10.00]副歌第一行\n[00:14.00]第二行\n[00:26.00]第四行\n[01:10.00]副歌第一行"
	if got != want {
		t.Fatalf("得到:\n%s\n想要:\n%s", got, want)
	}
}

func TestApplyBorrowedTranslations(t *testing.T) {
	withTranslationTarget(t, "zh")
	appleLRC, _ := borrowJaLyrics(10, 10000, false)
	qqLRC, qqTr := borrowJaLyrics(10, 10150, true)
	results := []scoredLyricCandidateResult{
		{Source: "applemusic", Score: 1300, Lyrics: appleLRC},
		{Source: "petitlyrics", Score: 1200, Lyrics: appleLRC},
		{Source: "qq", Score: 1100, Lyrics: qqLRC, LyricsTr: qqTr, LyricsTrLang: "zh"},
	}
	applyBorrowedTranslations(results)
	if results[0].LyricsTrFrom != "qq" || results[0].LyricsTrLang != "zh" || !strings.HasPrefix(results[0].LyricsTr, formatLRCTime(10000)+"第0次") {
		t.Fatalf("冠军应借到 qq 的译文,得到 from=%q lang=%q", results[0].LyricsTrFrom, results[0].LyricsTrLang)
	}
	if results[1].LyricsTrFrom != "qq" {
		t.Fatalf("借来的那份不当供体,第二名也应借 qq 的,得到 %q", results[1].LyricsTrFrom)
	}
	if results[2].LyricsTrFrom != "" || results[2].Score != 1100 || results[0].Score != 1300 {
		t.Fatal("供体自己不动,分数不变")
	}
	if got := lyricsTrSourceFor(&results[0]); got != "borrowed:qq" {
		t.Fatalf("写进条目的来源应是 borrowed:qq,得到 %q", got)
	}
	if got := lyricsTrSourceFor(&results[2]); got != "" {
		t.Fatalf("自带译文的来源是空串,得到 %q", got)
	}
}

func TestApplyBorrowedTranslationsLeavesAlone(t *testing.T) {
	appleLRC, appleTr := borrowJaLyrics(10, 10000, true)
	qqLRC, qqTr := borrowJaLyrics(10, 10150, true)
	zhLRC := strings.Repeat("[00:10.00]我们一起走过的那条长长的街道\n", 1) + "[00:14.00]你说过的话我还一直记在心里面\n[00:18.00]那年夏天的风吹过我们的头发\n[00:22.00]时间走得太快我们都来不及说\n[00:26.00]再见的时候请你不要回头看我\n"
	cases := map[string]struct {
		target string
		r      scoredLyricCandidateResult
	}{
		"没设译文语言":     {"", scoredLyricCandidateResult{Source: "applemusic", Score: 1300, Lyrics: appleLRC}},
		"自带可用译文":     {"zh", scoredLyricCandidateResult{Source: "applemusic", Score: 1300, Lyrics: appleLRC, LyricsTr: appleTr, LyricsTrLang: "zh"}},
		"被判废的候选":     {"zh", scoredLyricCandidateResult{Source: "applemusic", Score: -1, Lyrics: appleLRC}},
		"中文原文不要中文译文": {"zh", scoredLyricCandidateResult{Source: "applemusic", Score: 1300, Lyrics: zhLRC}},
		"目标语言对不上":    {"en", scoredLyricCandidateResult{Source: "applemusic", Score: 1300, Lyrics: appleLRC}},
	}
	for name, c := range cases {
		withTranslationTarget(t, c.target)
		before := c.r
		results := []scoredLyricCandidateResult{c.r, {Source: "qq", Score: 1100, Lyrics: qqLRC, LyricsTr: qqTr, LyricsTrLang: "zh"}}
		applyBorrowedTranslations(results)
		if results[0].LyricsTr != before.LyricsTr || results[0].LyricsTrFrom != "" {
			t.Errorf("%s:不该借,得到 from=%q", name, results[0].LyricsTrFrom)
		}
	}
	withTranslationTarget(t, "zh")
	results := []scoredLyricCandidateResult{
		{Source: "applemusic", Score: 1300, Lyrics: appleLRC},
		{Source: "qq", Score: -1, Lyrics: qqLRC, LyricsTr: qqTr, LyricsTrLang: "zh"},
	}
	applyBorrowedTranslations(results)
	if results[0].LyricsTrFrom != "" {
		t.Error("被判废的候选不当供体")
	}
}

func TestGainBorrowedTranslation(t *testing.T) {
	withTranslationTarget(t, "zh")
	appleLRC, _ := borrowJaLyrics(10, 10000, false)
	_, borrowedTr := borrowJaLyrics(10, 10000, true)
	scored := []scoredLyricCandidateResult{
		{Source: "applemusic", Score: 1300, Lyrics: appleLRC, LyricsTr: borrowedTr, LyricsTrLang: "zh", LyricsTrFrom: "qq"},
	}
	e := enrichEntry{Lyrics: bt(appleLRC), LyricsSource: "applemusic"}
	if !gainBorrowedTranslation(&e, scored) || e.LyricsTr.String() != borrowedTr || e.LyricsTrSource != "borrowed:qq" || e.LyricsTrLang != "zh" {
		t.Fatalf("正文相同、自己没有译文时应补上,得到 source=%q", e.LyricsTrSource)
	}
	if gainBorrowedTranslation(&e, scored) {
		t.Fatal("已有可用译文时不再补")
	}
	other := enrichEntry{Lyrics: bt(appleLRC + "[01:30.00]もう一行\n")}
	if gainBorrowedTranslation(&other, scored) {
		t.Fatal("正文不同不补")
	}
	inst := enrichEntry{Lyrics: bt(appleLRC), Instrumental: true}
	if gainBorrowedTranslation(&inst, scored) {
		t.Fatal("标了纯音乐的不补")
	}
}

// 两条流水线都在排序之后借;把候选写进条目的各处都经 lyricsTrSourceFor,别再写死空串。
func TestBorrowedTranslationWired(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	src := read("enrich.go")
	for _, pair := range []string{
		"sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })\n\tapplyUnmaskedWords(out)\n\tapplyBorrowedTranslations(out)",
		"sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })\n\tapplyUnmaskedWords(results)\n\tapplyBorrowedTranslations(results)",
	} {
		if !containsCode(src, pair) {
			t.Errorf("enrich.go 里要在排序之后借译文:%q", pair)
		}
	}
	if n := strings.Count(src, "gainBorrowedTranslation(&e, scored)"); n != 2 {
		t.Errorf("升级重试与重新打分两处都要补借来的译文,得到 %d 处", n)
	}
	for _, f := range []string{"enrich.go", "provisionallyrics.go", "resynclyricscli.go", "songentityshare.go"} {
		body := read(f)
		if strings.Contains(body, "LyricsTrSource = picked.LyricsTrLang, \"\"") || strings.Contains(body, "LyricsTrSource = c.LyricsTrLang, \"\"") {
			t.Errorf("%s:把候选写进条目时译文来源要经 lyricsTrSourceFor", f)
		}
	}
}

// 两边分行不同:这一份把一句拆成两行时译文挂在第一行;供体拆成两行时两行译文接起来。
func TestBorrowedTranslationAcrossLineSplits(t *testing.T) {
	own := "[00:17.59]朝の窓 開けて\n[00:20.51]見つけた小さな答えは\n[00:23.17]昼下がりの電車でどこかへ消えた\n[00:28.48]何度でも 忘れて覚え直したい\n" +
		"[00:34.04]遠い海まで自転車で走り抜ける\n[00:40.68]笑い合ったりときどき黙ったりできるくらいの\n[00:48.90]ありふれた日々をくれ\n"
	donor := "[00:17.18]朝の窓 開けて 見つけた小さな答えは\n[00:22.84]昼下がりの電車でどこかへ消えた\n[00:28.26]何度でも 忘れて覚え直したい\n" +
		"[00:33.75]遠い海まで自転車で走り抜ける\n[00:39.92]笑い合ったり\n[00:43.10]ときどき黙ったりできるくらいの\n[00:48.56]ありふれた日々をくれ\n"
	donorTr := "[00:17.18]打开清晨的窗 找到的小小答案\n[00:22.84]在午后的电车上不知消失到了哪里\n[00:28.26]想一次次忘掉再重新记起\n" +
		"[00:33.75]骑着自行车奔向遥远的大海\n[00:39.92]能够相视而笑\n[00:43.10]偶尔也能沉默不语\n[00:48.56]给我平凡的日子\n"
	got, ok := borrowedTranslation(own, donor, donorTr)
	if !ok {
		t.Fatal("拼起来逐字相同的应配上")
	}
	want := "[00:17.59]打开清晨的窗 找到的小小答案\n[00:23.17]在午后的电车上不知消失到了哪里\n[00:28.48]想一次次忘掉再重新记起\n" +
		"[00:34.04]骑着自行车奔向遥远的大海\n[00:40.68]能够相视而笑 偶尔也能沉默不语\n[00:48.90]给我平凡的日子"
	if got != want {
		t.Fatalf("得到:\n%s\n想要:\n%s", got, want)
	}
}

func TestBorrowLineGroupsStopsOnMismatch(t *testing.T) {
	line := func(n string) borrowLine { return borrowLine{norm: n} }
	own := []borrowLine{line("ab"), line("cd"), line("xy"), line("ef")}
	donor := []borrowLine{line("abcd"), line("zz"), line("ef")}
	got := borrowLineGroups(own, donor)
	want := []borrowGroup{{0, 2, 0, 1}, {3, 4, 2, 3}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("得到 %v,想要 %v", got, want)
	}
	// 一组最多拼 borrowTranslationMaxGroup 行。
	own = []borrowLine{line("a"), line("b"), line("c"), line("d")}
	donor = []borrowLine{line("abcd")}
	if got := borrowLineGroups(own, donor); len(got) != 0 {
		t.Fatalf("拼满 %d 行还对不上就不配,得到 %v", borrowTranslationMaxGroup, got)
	}
}

// 署名行不算正文行:不去掉的话这一份的行数多出来,配上的不到六成。
func TestBorrowedTranslationIgnoresCreditLines(t *testing.T) {
	lyr, _ := borrowJaLyrics(6, 20000, false)
	own := "[00:01.00]作詞：誰か\n[00:02.00]作曲：誰か\n[00:03.00]編曲：誰か\n[00:04.00]歌：誰か\n[00:05.00]Producer：誰か\n" + lyr
	donor, donorTr := borrowJaLyrics(6, 20000, true)
	if _, ok := borrowedTranslation(own, donor, donorTr); !ok {
		t.Fatal("署名行不该算进行数")
	}
}

// 这一份把每句都拆成两行:覆盖按这一份配上的行数算,不按挂了几行译文算;末尾那段拆开的也要配上。
func TestBorrowedTranslationSplitCoverageAndTail(t *testing.T) {
	var own, donor, donorTr strings.Builder
	for i := 0; i < 4; i++ {
		own.WriteString(fmt.Sprintf("%s前半の歌詞%d\n%s後半の歌詞%d\n", formatLRCTime(10000+i*8000), i, formatLRCTime(14000+i*8000), i))
		donor.WriteString(fmt.Sprintf("%s前半の歌詞%d後半の歌詞%d\n", formatLRCTime(10100+i*8000), i, i))
		donorTr.WriteString(fmt.Sprintf("%s第%d句\n", formatLRCTime(10100+i*8000), i))
	}
	got, ok := borrowedTranslation(own.String(), donor.String(), donorTr.String())
	if !ok {
		t.Fatal("每句拆成两行时应整首配上")
	}
	if !strings.HasSuffix(got, formatLRCTime(34000)+"第3句") {
		t.Fatalf("最后一句也要配上,得到:\n%s", got)
	}
}
