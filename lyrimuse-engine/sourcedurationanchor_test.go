package main

import (
	"os"
	"sort"
	"strings"
	"testing"
)

func TestSourceDurationNearMiss(t *testing.T) {
	cases := []struct {
		reported, local float64
		want            bool
	}{
		{213, 189.1, true}, // 现场版,差 11%
		{296, 267, true},   // 混音版,差 10%
		{373, 353.3, true}, // 差 5.3%、19 秒
		{192, 198, false},  // 3%,同一次录音各家取整、去静音的正常差
		{17, 18, false},    // 比例过了,绝对差只有 1 秒
		{57, 60.1, false},  // 5.2%、3.1 秒,不到秒数下限
		{310, 267, false},  // 超过 12% 归 sourceDurationOff
		{0, 200, false},    // 源没报
		{200, 0, false},    // 本地不知道
		{189.08, 189.1, false},
	}
	for _, c := range cases {
		if got := sourceDurationNearMiss(c.reported, c.local); got != c.want {
			t.Errorf("sourceDurationNearMiss(%v, %v) = %v, 想要 %v", c.reported, c.local, got, c.want)
		}
	}
}

func nearMissCand(source string, score int, reported float64, terms ...scoreTerm) scoredLyricCandidateResult {
	return scoredLyricCandidateResult{Source: source, Score: score, SourceReportedDurationSecs: reported, ScoreTerms: terms, Lyrics: "[00:01.00]a"}
}

func TestSourceDurationNearMissPenalizesOtherRecordingWhenAnchored(t *testing.T) {
	results := []scoredLyricCandidateResult{
		nearMissCand("kugou", 1185, 213),
		nearMissCand("netease", 1129, 189.08),
		nearMissCand("deezer", 900, 0),
	}
	applySourceDurationNearMissPenalty(results, 189.1)
	if results[0].Score != 785 || scoreTermPoints(results[0].ScoreTerms, scoreTermSourceDurationNearMiss) != -sourceDurationNearMissPenalty {
		t.Fatalf("差 11%% 的现场版应扣 %d 分并记一项,得到 %d %v", sourceDurationNearMissPenalty, results[0].Score, results[0].ScoreTerms)
	}
	if results[1].Score != 1129 || results[2].Score != 900 {
		t.Fatalf("锚点和没报曲长的候选不该动,得到 %d / %d", results[1].Score, results[2].Score)
	}
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	if results[0].Source != "netease" {
		t.Fatalf("扣完之后应由曲长吻合的那份胜出,得到 %s", results[0].Source)
	}
}

func TestSourceDurationNearMissNeedsAnchor(t *testing.T) {
	cases := map[string][]scoredLyricCandidateResult{
		"没有曲长吻合的候选": {nearMissCand("kugou", 1185, 213), nearMissCand("qq", 1100, 200)},
		"锚点的正文末句对不上曲长": {nearMissCand("kugou", 1185, 213),
			nearMissCand("qq", 700, 189, scoreTerm{Kind: scoreTermDurationOff, Points: -durationMismatchPenalty})},
		"锚点被判不可用": {nearMissCand("kugou", 1185, 213), nearMissCand("qq", -1, 189)},
	}
	for name, results := range cases {
		applySourceDurationNearMissPenalty(results, 189.1)
		if results[0].Score != 1185 {
			t.Errorf("%s:不该扣分,得到 %d", name, results[0].Score)
		}
	}
}

func TestSourceDurationNearMissSparesPlayingAudio(t *testing.T) {
	results := []scoredLyricCandidateResult{
		nearMissCand(lxMusicLocalLyricsSource, 1400, 261),
		nearMissCand("qq", 1300, 261, scoreTerm{Kind: scoreTermNativeSource, Points: 250}),
		nearMissCand("migu", 1200, 280.9),
	}
	applySourceDurationNearMissPenalty(results, 280.7)
	if results[0].Score != 1400 || results[1].Score != 1300 {
		t.Fatalf("播放器本地歌词和同源候选不该扣分,得到 %d / %d", results[0].Score, results[1].Score)
	}
}

func TestSourceDurationNearMissClampsAndSkipsUnknownDuration(t *testing.T) {
	results := []scoredLyricCandidateResult{nearMissCand("kugou", 300, 213), nearMissCand("netease", 900, 189)}
	applySourceDurationNearMissPenalty(results, 0)
	if results[0].Score != 300 {
		t.Fatalf("本地曲长未知时不该动,得到 %d", results[0].Score)
	}
	applySourceDurationNearMissPenalty(results, 189.1)
	if results[0].Score != 1 {
		t.Fatalf("扣分后夹到 1,得到 %d", results[0].Score)
	}
}

// 两条流水线都要接,且排在时间轴平移扣分之前,按源码钉住。
func TestSourceDurationNearMissWiredIntoBothPipelines(t *testing.T) {
	raw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	if n := strings.Count(src, "applySourceDurationNearMissPenalty("); n != 2 {
		t.Fatalf("enrich.go 里要有两处调用,得到 %d", n)
	}
	for _, pair := range []string{
		"applySourceDurationNearMissPenalty(out, durationSecs)\n\tapplyTimelineOffsetPenalty(out, durationSecs)",
		"applySourceDurationNearMissPenalty(results, durationSecs)\n\tapplyTimelineOffsetPenalty(results, durationSecs)",
	} {
		if !containsCode(src, pair) {
			t.Errorf("调用位置要紧挨在时间轴平移扣分之前:%q", pair)
		}
	}
}

// 首轮中途先上屏不看锚点:自报曲长差出收紧档的那份,哪怕单看自己靠得住也要等第一轮收齐。
func TestEarlyLyricsWaitsOnSourceDurationNearMiss(t *testing.T) {
	c := nearMissCand("kugou", 1185, 213,
		scoreTerm{Kind: scoreTermDuration, Points: 277}, scoreTerm{Kind: scoreTermWordTiming, Points: wordTimingPoints},
		scoreTerm{Kind: scoreTermTitleMatch, Points: titleMatchFullPoints})
	all := func(string) bool { return true }
	if got := earlyLyricsVerdict([]scoredLyricCandidateResult{c}, &c, all, true, 189.1); got != earlyLyricsWait {
		t.Fatalf("自报曲长差 11%% 时应接着等,得到 %q", got)
	}
	if got := earlyLyricsVerdict([]scoredLyricCandidateResult{c}, &c, all, true, 0); got == earlyLyricsWait {
		t.Fatal("本地曲长未知时照常先上屏")
	}
	c.SourceReportedDurationSecs = 189
	if got := earlyLyricsVerdict([]scoredLyricCandidateResult{c}, &c, all, true, 189.1); got == earlyLyricsWait {
		t.Fatal("曲长对得上时照常先上屏")
	}
}
