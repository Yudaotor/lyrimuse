package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// 形状:主歌 → 副歌 → 35 秒间奏 → 副歌再来一遍 → 尾句;出错的那份把副歌复制进了间奏(见 09 章决策 98)。
type tiLine struct {
	sec  float64
	text string
}

func tiLRC(lines []tiLine) string {
	var b strings.Builder
	for _, l := range lines {
		ms := int(l.sec * 1000)
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", ms/60000, (ms/1000)%60, (ms%1000)/10, l.text)
	}
	return b.String()
}

func tiSong(extra ...tiLine) []tiLine {
	var out []tiLine
	for k := 0; k < 8; k++ {
		out = append(out, tiLine{10 + float64(k)*5, "verse line " + tlWord(k)})
	}
	chorus := []string{"hello is it me", "i wonder where you are", "are you somewhere feeling lonely", "let me start by saying"}
	for k, c := range chorus {
		out = append(out, tiLine{50 + float64(k)*5, c})
	}
	for k, c := range chorus {
		out = append(out, tiLine{100 + float64(k)*5, c})
	}
	out = append(out, tiLine{120, "outro one"}, tiLine{125, "outro two"})
	out = append(out, extra...)
	return out
}

// 复制进 65~100 秒间奏的那段副歌。
func tiCopiedChorus() []tiLine {
	return []tiLine{{70, "hello is it me"}, {74, "i wonder where you are"}, {78, "are you somewhere feeling lonely"}, {82, "let me start by saying"}}
}

func tiResult(source string, score int, srcDur float64, lines []tiLine) scoredLyricCandidateResult {
	return scoredLyricCandidateResult{Source: source, Score: score, SourceReportedDurationSecs: srcDur, Lyrics: tiLRC(lines)}
}

func tiPenalized(results []scoredLyricCandidateResult) map[string]bool {
	out := map[string]bool{}
	for _, r := range results {
		if scoreTermPoints(r.ScoreTerms, scoreTermTimelineIntrusion) != 0 {
			out[r.Source] = true
		}
	}
	return out
}

const tiLocal = 130.0

func TestTimelineIntrusionPenalizesCopiedBlockInBreak(t *testing.T) {
	results := []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceKugou, 1237, 130, tiSong()),
		tiResult(lyricSourceNetease, 1211, 130.1, tiSong()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	got := tiPenalized(results)
	if !got[lyricSourceMusixmatch] || len(got) != 1 {
		t.Fatalf("只扣间奏里多出一段的那份,得到 %v", got)
	}
	if results[0].Score != 1247-timelineIntrusionPenalty {
		t.Fatalf("扣 %d 分,得到 %d", timelineIntrusionPenalty, results[0].Score)
	}
}

func TestTimelineIntrusionLeavesUnrelatedLinesAlone(t *testing.T) {
	cases := map[string][]tiLine{
		// 各家不收的和声 / ad-lib:正文不是参照组别处的歌词。
		"ad-lib": {{70, "ooh yeah"}, {74, "oh oh oh"}, {78, "mm hmm"}, {82, "whoa"}},
		// 署名 / 制作名单(displayedTimeline 滤掉)。
		"credits": {{70, "作词：甲"}, {74, "作曲：乙"}, {78, "编曲：丙"}, {82, "制作人：丁"}},
		// 复制来的只有两句。
		"two lines": {{70, "hello is it me"}, {74, "i wonder where you are"}},
		// 复制来的不到一半:3 句原句夹着 4 句别的。
		"minority": {{68, "hello is it me"}, {71, "new words one"}, {74, "i wonder where you are"}, {77, "new words two"},
			{80, "are you somewhere feeling lonely"}, {83, "new words three"}, {86, "new words four"}},
		// 挤在两端的让量里。
		"edges": {{65.5, "hello is it me"}, {66, "i wonder where you are"}, {99, "are you somewhere feeling lonely"}},
	}
	for name, extra := range cases {
		results := []scoredLyricCandidateResult{
			tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(extra...)),
			tiResult(lyricSourceKugou, 1237, 130, tiSong()),
			tiResult(lyricSourceNetease, 1211, 130.1, tiSong()),
		}
		applyTimelineIntrusionPenalty(results, tiLocal)
		if got := tiPenalized(results); len(got) != 0 {
			t.Errorf("%s: 不该扣,得到 %v", name, got)
		}
	}
}

func TestTimelineIntrusionNeedsTwoFamiliesOfReferences(t *testing.T) {
	// 参照只有一家时长对得上(QQ 自报曲长差太多,不算参照)。
	results := []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceKugou, 1237, 130, tiSong()),
		tiResult(lyricSourceQQ, 1100, 150, tiSong()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("只有一家参照不判,得到 %v", got)
	}
	// 两家参照是同一个信源家族(Deezer 与 LyricFind)。
	results = []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceDeezer, 1237, 130, tiSong()),
		tiResult(lyricSourceLyricFind, 1211, 130.1, tiSong()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("参照只来自一个信源家族不判,得到 %v", got)
	}
}

func TestTimelineIntrusionNoCommonBreak(t *testing.T) {
	// 有一家参照镜像了同一份错轴:间奏里不是人人都空,没有共同空档。
	results := []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceLRCLIB, 800, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceKugou, 1237, 130, tiSong()),
		tiResult(lyricSourceNetease, 1211, 130.1, tiSong()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("参照自己在那段有行时不判,得到 %v", got)
	}
	// 空档不到 timelineIntrusionMinGapMs:把间奏缩到 10 秒。
	short := func(extra ...tiLine) []tiLine {
		var out []tiLine
		for _, l := range tiSong(extra...) {
			if l.sec >= 100 {
				l.sec -= 25
			}
			out = append(out, l)
		}
		return out
	}
	results = []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, short(tiLine{67.5, "hello is it me"}, tiLine{69.5, "i wonder where you are"}, tiLine{71.5, "are you somewhere feeling lonely"})),
		tiResult(lyricSourceKugou, 1237, 130, short()),
		tiResult(lyricSourceNetease, 1211, 130.1, short()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("空档太短不判,得到 %v", got)
	}
}

func TestTimelineIntrusionIgnoresIntro(t *testing.T) {
	// 第一句之前的 25 秒各家都没有行:那不是「两句之间」,前奏人声收不收各家不一样。
	late := func(extra ...tiLine) []tiLine {
		var out []tiLine
		for _, l := range tiSong() {
			if l.sec >= 25 {
				out = append(out, l)
			}
		}
		return append(out, extra...)
	}
	intro := []tiLine{{4, "hello is it me"}, {8, "i wonder where you are"}, {12, "are you somewhere feeling lonely"}}
	results := []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, late(intro...)),
		tiResult(lyricSourceKugou, 1237, 130, late()),
		tiResult(lyricSourceNetease, 1211, 130.1, late()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("前奏不判,得到 %v", got)
	}
}

func TestTimelineIntrusionRevertsWhenWinnerUnverified(t *testing.T) {
	// 扣完之后第一名是一份时长对不上的(没核实过的轴):整批撤销。
	results := []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceQQ, 1000, 150, tiSong()),
		tiResult(lyricSourceKugou, 700, 130, tiSong()),
		tiResult(lyricSourceNetease, 650, 130.1, tiSong()),
	}
	applyTimelineIntrusionPenalty(results, tiLocal)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("冠军核实不了时撤销,得到 %v", got)
	}
	if results[0].Score != 1247 {
		t.Errorf("撤销时分数不动,得到 %d", results[0].Score)
	}
}

func TestTimelineIntrusionUnknownDuration(t *testing.T) {
	results := []scoredLyricCandidateResult{
		tiResult(lyricSourceMusixmatch, 1247, 130.4, tiSong(tiCopiedChorus()...)),
		tiResult(lyricSourceKugou, 1237, 130, tiSong()),
		tiResult(lyricSourceNetease, 1211, 130.1, tiSong()),
	}
	applyTimelineIntrusionPenalty(results, 0)
	if got := tiPenalized(results); len(got) != 0 {
		t.Errorf("本地时长未知不判,得到 %v", got)
	}
}

// 两条流水线都要接(同 applyTimelineOffsetPenalty),按源码钉住。
func TestTimelineIntrusionWiredIntoBothPipelines(t *testing.T) {
	raw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	if n := strings.Count(src, "applyTimelineIntrusionPenalty("); n != 2 {
		t.Fatalf("enrich.go 里要有两处调用(rankLyricSourceResults 与 mergeLyricCandidateRounds),得到 %d", n)
	}
	for _, pair := range []string{
		"applyTimelineOffsetPenalty(out, durationSecs)\n\tapplyTimelineIntrusionPenalty(out, durationSecs)\n\tapplyWordTimingTitleOverride(out)",
		"applyTimelineOffsetPenalty(results, durationSecs)\n\tapplyTimelineIntrusionPenalty(results, durationSecs)\n\tapplyWordTimingTitleOverride(results)",
	} {
		if !strings.Contains(src, pair) {
			t.Errorf("调用位置要紧跟在时间轴平移扣分之后、逐字加分撤销之前:%q", pair)
		}
	}
}
