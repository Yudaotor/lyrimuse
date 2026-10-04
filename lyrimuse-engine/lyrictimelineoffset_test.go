package main

import (
	"fmt"
	"strings"
	"testing"
)

// tlLRC 造一份 n 行的逐行 LRC:第 k 行正文互不相同,时刻 = 10s + k*5s + shift(k)。
func tlLRC(n int, shift func(k int) int) string {
	var b strings.Builder
	for k := 0; k < n; k++ {
		ms := 10000 + k*5000 + shift(k)
		fmt.Fprintf(&b, "[%02d:%02d.%02d]line number %s here\n", ms/60000, (ms/1000)%60, (ms%1000)/10, tlWord(k))
	}
	return b.String()
}

// tlYRC 造一份与 tlLRC 同正文的逐字数据,行首时刻同样按 shift 平移。
func tlYRC(n int, shift func(k int) int) string {
	var b strings.Builder
	for k := 0; k < n; k++ {
		ms := 10000 + k*5000 + shift(k)
		fmt.Fprintf(&b, "[%d,4000](%d,1000,0)line (%d,1000,0)number (%d,1000,0)%s (%d,1000,0)here\n", ms, ms, ms+1000, ms+2000, tlWord(k), ms+3000)
	}
	return b.String()
}

func tlWord(k int) string {
	words := []string{"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
		"kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"}
	return words[k%len(words)] + strings.Repeat("x", k/len(words))
}

func tlConst(ms int) func(int) int { return func(int) int { return ms } }

func tlResult(source string, score int, srcDur float64, lrc, yrc string) scoredLyricCandidateResult {
	return scoredLyricCandidateResult{Source: source, Score: score, SourceReportedDurationSecs: srcDur, Lyrics: lrc, LyricsYRC: yrc}
}

func tlPenalized(results []scoredLyricCandidateResult) map[string]bool {
	out := map[string]bool{}
	for _, r := range results {
		if scoreTermPoints(r.ScoreTerms, scoreTermTimelineOffset) != 0 {
			out[r.Source] = true
		}
	}
	return out
}

func TestLRCOffsetTagMs(t *testing.T) {
	cases := map[string]int{
		"[offset:500]\n[00:01.00]a":   500,
		"[offset: -242]\n[00:01.00]a": -242,
		"[00:01.00]a":                 0,
		"[offset:20000]\n[00:01.00]a": 0, // 超过 10 秒量级闸,与 App 侧一致当作没有
		"[offset:100]\n[offset:900]":  100,
	}
	for in, want := range cases {
		if got := lrcOffsetTagMs(in); got != want {
			t.Errorf("lrcOffsetTagMs(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestDisplayedTimelinePrefersWordTiming(t *testing.T) {
	lrc := tlLRC(12, tlConst(3000))
	yrc := tlYRC(12, tlConst(0))
	got := displayedTimeline(lrc, yrc)
	if len(got) != 12 || got[0].ms != 10000 {
		t.Fatalf("有逐字轴时应按逐字行首,实际首行 %d ms(共 %d 行)", got[0].ms, len(got))
	}
	// 逐字行数不到整行的一半:App 不用逐字轴,这里也退回整行。
	short := tlYRC(5, tlConst(0))
	if got := displayedTimeline(lrc, short); got[0].ms != 13000 {
		t.Fatalf("逐字行太少时应退回整行 LRC,实际首行 %d ms", got[0].ms)
	}
	// [offset:] 扣在显示时刻上;整行里没有时取逐字里的。
	if got := displayedTimeline("[offset:1000]\n"+lrc, ""); got[0].ms != 12000 {
		t.Fatalf("应扣掉 LRC 的 offset,实际首行 %d ms", got[0].ms)
	}
	if got := displayedTimeline(lrc, "[offset:1000]\n"+yrc); got[0].ms != 9000 {
		t.Fatalf("整行没有 offset 时应取逐字里的,实际首行 %d ms", got[0].ms)
	}
}

func TestClassifyTimelines(t *testing.T) {
	base := displayedTimeline(tlLRC(20, tlConst(0)), "")
	check := func(name string, other string, want timelineRelation) {
		t.Helper()
		if got := classifyTimelines(displayedTimeline(other, ""), base, timelineOffsetPenaltyMs); got != want {
			t.Errorf("%s: got %d, want %d", name, got, want)
		}
	}
	check("恒定 0.8s 差算对齐", tlLRC(20, tlConst(800)), timelineAligned)
	check("整体晚 3s", tlLRC(20, tlConst(3000)), timelineShiftedLater)
	check("整体早 10s", tlLRC(20, tlConst(-10000)), timelineShiftedEarlier)
	// 前半段早 3.5s、后半段早 1.8s:每一行都早,中位数够大,算平移。
	check("前后两段偏移不同", tlLRC(20, func(k int) int {
		if k < 12 {
			return -3500
		}
		return -1800
	}), timelineShiftedEarlier)
	// 30% 的行偏 3s、其余对齐(配错几行的形状):既不够对齐也不够平移,判不了。
	check("少数行偏出判不了", tlLRC(20, func(k int) int {
		if k%10 < 3 {
			return 3000
		}
		return 0
	}), timelineUndecided)
	// 55% 的行偏 5s、其余对齐:中位数够大,但不是整首平移,判不了。
	check("过半但不够八成的行偏出判不了", tlLRC(20, func(k int) int {
		if k%20 < 11 {
			return 5000
		}
		return 0
	}), timelineUndecided)
	// 差 2s:超过对齐的界,不到平移阈值。
	check("2s 恒定差判不了", tlLRC(20, tlConst(2000)), timelineUndecided)
	if got := classifyTimelines(displayedTimeline(tlLRC(6, tlConst(5000)), ""), base, timelineOffsetPenaltyMs); got != timelineUndecided {
		t.Errorf("配对不足 8 行应判不了,实际 %d", got)
	}
}

// 本地 281s;两家自报 281s、彼此对齐;网易云自报 295s、整体晚 10s 且分数最高。
func tlShiftedWinnerBatch() []scoredLyricCandidateResult {
	aligned := tlLRC(20, tlConst(0))
	return []scoredLyricCandidateResult{
		tlResult("netease", 1068, 295, tlLRC(20, tlConst(10000)), tlYRC(20, tlConst(10000))),
		tlResult("soda", 985, 280.77, aligned, tlYRC(20, tlConst(0))),
		tlResult("kugou", 973, 280, tlLRC(20, tlConst(150)), ""),
	}
}

func TestApplyTimelineOffsetPenaltyFires(t *testing.T) {
	results := tlShiftedWinnerBatch()
	applyTimelineOffsetPenalty(results, 281)
	if !tlPenalized(results)["netease"] || len(tlPenalized(results)) != 1 {
		t.Fatalf("只有网易云该吃 timelineOffset,实际 %v", tlPenalized(results))
	}
	if results[0].Score != 1068-timelineOffsetPenalty {
		t.Fatalf("网易云应扣 %d,实际分数 %d", timelineOffsetPenalty, results[0].Score)
	}
}

func TestApplyTimelineOffsetPenaltyGuards(t *testing.T) {
	cases := []struct {
		name   string
		mutate func([]scoredLyricCandidateResult) []scoredLyricCandidateResult
		dur    float64
	}{
		{"曲长未知", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult { return r }, 0},
		{"只有一个锚点", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult {
			r[2].SourceReportedDurationSecs = 0
			return r
		}, 281},
		{"锚点之间自己打架", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult {
			return append(r, tlResult("qq", 900, 281, tlLRC(20, tlConst(4500)), ""))
		}, 281},
		{"对齐的锚点只来自同一信源家族", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult {
			r[1].Source, r[2].Source = lyricSourceDeezer, lyricSourceLyricFind
			return r
		}, 281},
		{"只差在结尾:时间轴对齐的不罚", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult {
			r[0].Lyrics, r[0].LyricsYRC = tlLRC(20, tlConst(0)), tlYRC(20, tlConst(0))
			return r
		}, 281},
		{"整行错开但逐字轴对齐的不罚", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult {
			r[0].LyricsYRC = tlYRC(20, tlConst(0))
			return r
		}, 281},
		{"扣完之后第一名没核实对齐就整批撤销", func(r []scoredLyricCandidateResult) []scoredLyricCandidateResult {
			// 这一家逐行漂移 0~2.85s:既不算对齐,也不算平移,核实不了。
			return append(r, tlResult("lrclib", 1050, 0, tlLRC(20, func(k int) int { return k * 150 }), ""))
		}, 281},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			results := c.mutate(tlShiftedWinnerBatch())
			before := make([]int, len(results))
			for i := range results {
				before[i] = results[i].Score
			}
			applyTimelineOffsetPenalty(results, c.dur)
			if p := tlPenalized(results); len(p) != 0 {
				t.Fatalf("不该罚任何候选,实际 %v", p)
			}
			for i := range results {
				if results[i].Score != before[i] {
					t.Fatalf("%s 的分数不该变:%d 到 %d", results[i].Source, before[i], results[i].Score)
				}
			}
		})
	}
}

func TestApplyTimelineOffsetPenaltySkipsRejected(t *testing.T) {
	results := append(tlShiftedWinnerBatch(), scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true})
	applyTimelineOffsetPenalty(results, 281)
	if results[3].Score != -1 || len(results[3].ScoreTerms) != 0 {
		t.Fatalf("负分标记不该被动过:%+v", results[3])
	}
	if !tlPenalized(results)["netease"] {
		t.Fatal("网易云仍应吃 timelineOffset")
	}
}
