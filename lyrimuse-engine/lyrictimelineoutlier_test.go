package main

import (
	"fmt"
	"strings"
	"testing"
)

// 时长都对得上的五家:四个信源彼此对齐,Musixmatch 整首晚 1.8s、分数最高。
func tlOutlierBatch() []scoredLyricCandidateResult {
	return []scoredLyricCandidateResult{
		tlResult("musixmatch", 1227, 297, tlLRC(20, tlConst(1800)), tlYRC(20, tlConst(1800))),
		tlResult("qq", 1223, 297, tlLRC(20, tlConst(0)), tlYRC(20, tlConst(0))),
		tlResult("applemusic", 1222, 297.4, tlLRC(20, tlConst(-300)), ""),
		tlResult("lrclib", 823, 297, tlLRC(20, tlConst(-200)), ""),
		tlResult("migu", 1205, 297.4, tlLRC(20, tlConst(300)), ""),
	}
}

func TestApplyTimelineOffsetPenaltyAnchorOutlier(t *testing.T) {
	results := tlOutlierBatch()
	applyTimelineOffsetPenalty(results, 297)
	if p := tlPenalized(results); !p["musixmatch"] || len(p) != 1 {
		t.Fatalf("只有 Musixmatch 该吃 timelineOffset,实际 %v", p)
	}
	if results[0].Score != 1227-timelineOffsetPenalty {
		t.Fatalf("Musixmatch 应扣 %d,实际分数 %d", timelineOffsetPenalty, results[0].Score)
	}
	if top := pickTop(results); top != "qq" {
		t.Fatalf("扣完之后冠军应是对齐的 QQ,实际 %s", top)
	}
}

func pickTop(results []scoredLyricCandidateResult) string {
	best := -1
	for i := range results {
		if results[i].Score >= 0 && (best == -1 || results[i].Score > results[best].Score) {
			best = i
		}
	}
	if best == -1 {
		return ""
	}
	return results[best].Source
}

func TestApplyTimelineOffsetPenaltyAnchorOutlierGuards(t *testing.T) {
	cases := []struct {
		name  string
		batch func() []scoredLyricCandidateResult
	}{
		{"对面只有两家", func() []scoredLyricCandidateResult { return tlOutlierBatch()[:3] }},
		{"时间轴是同一份的几家算一家", func() []scoredLyricCandidateResult {
			return []scoredLyricCandidateResult{
				tlResult("musixmatch", 1227, 297, tlLRC(20, tlConst(1800)), ""),
				tlResult("qq", 1223, 297, tlLRC(20, tlConst(0)), ""),
				tlResult("kugou", 1223, 297, tlLRC(20, tlConst(0)), ""),
				tlResult("kuwo", 1223, 297, tlLRC(20, tlConst(0)), ""),
				tlResult("applemusic", 1222, 297.4, tlLRC(20, tlConst(-300)), ""),
			}
		}},
		{"分成两派", func() []scoredLyricCandidateResult {
			return append(tlOutlierBatch(), tlResult("netease", 1100, 297, tlLRC(20, tlConst(1900)), ""))
		}},
		{"落单的是跟播放器同源的那份", func() []scoredLyricCandidateResult {
			r := tlOutlierBatch()
			r[0].ScoreTerms = []scoreTerm{{Kind: scoreTermNativeSource, Points: 250}}
			return r
		}},
		{"只跟一家平移", func() []scoredLyricCandidateResult {
			return []scoredLyricCandidateResult{
				tlResult("musixmatch", 1227, 297, tlLRC(20, tlConst(1600)), ""),
				tlResult("qq", 1223, 297, tlLRC(20, tlConst(0)), ""),
				tlResult("applemusic", 1222, 297, tlLRC(20, tlConst(400)), ""),
				tlResult("lrclib", 823, 297, tlLRC(20, tlConst(450)), ""),
				tlResult("migu", 1205, 297, tlLRC(20, tlConst(500)), ""),
			}
		}},
		{"另一派里有一家跟基准组判不了", func() []scoredLyricCandidateResult {
			return []scoredLyricCandidateResult{
				tlResult("musixmatch", 1227, 297, tlLRC(20, tlConst(1800)), ""),
				tlResult("netease", 1100, 297, tlLRC(20, tlConst(1150)), ""),
				tlResult("qq", 1223, 297, tlLRC(20, tlConst(0)), ""),
				tlResult("applemusic", 1222, 297, tlLRC(20, tlConst(-300)), ""),
				tlResult("lrclib", 823, 297, tlLRC(20, tlConst(-200)), ""),
				tlResult("migu", 1205, 297, tlLRC(20, tlConst(100)), ""),
			}
		}},
		{"对齐的那一派内部首尾平移", func() []scoredLyricCandidateResult {
			return []scoredLyricCandidateResult{
				tlResult("musixmatch", 1227, 297, tlLRC(20, tlConst(-2600)), ""),
				tlResult("qq", 1223, 297, tlLRC(20, tlConst(0)), ""),
				tlResult("applemusic", 1222, 297, tlLRC(20, tlConst(900)), ""),
				tlResult("lrclib", 823, 297, tlLRC(20, tlConst(1800)), ""),
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			results := c.batch()
			before := make([]int, len(results))
			for i := range results {
				before[i] = results[i].Score
			}
			applyTimelineOffsetPenalty(results, 297)
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

// 基准组外有两家各自错开(彼此也对不上):两家都罚,冠军交给基准组。
func TestApplyTimelineOffsetPenaltyJudgesEachOutlier(t *testing.T) {
	results := append(tlOutlierBatch(), tlResult("netease", 1100, 297, tlLRC(20, tlConst(-2200)), ""))
	applyTimelineOffsetPenalty(results, 297)
	if p := tlPenalized(results); !p["musixmatch"] || !p["netease"] || len(p) != 2 {
		t.Fatalf("Musixmatch、网易云都该吃 timelineOffset,实际 %v", p)
	}
	if top := pickTop(results); top != "qq" {
		t.Fatalf("扣完之后冠军应是对齐的 QQ,实际 %s", top)
	}
}

// 只跟基准组一家平移的锚点判不了,留着不动,也不挡住别家错开的被罚。
func TestApplyTimelineOffsetPenaltyUndecidedOutlierDoesNotBlock(t *testing.T) {
	results := []scoredLyricCandidateResult{
		tlResult("musixmatch", 1100, 297, tlLRC(20, tlConst(1600)), ""),
		tlResult("netease", 1300, 297, tlLRC(20, tlConst(-2500)), ""),
		tlResult("qq", 1223, 297, tlLRC(20, tlConst(0)), ""),
		tlResult("applemusic", 1222, 297, tlLRC(20, tlConst(400)), ""),
		tlResult("lrclib", 823, 297, tlLRC(20, tlConst(450)), ""),
		tlResult("migu", 1205, 297, tlLRC(20, tlConst(500)), ""),
	}
	applyTimelineOffsetPenalty(results, 297)
	if p := tlPenalized(results); !p["netease"] || len(p) != 1 {
		t.Fatalf("只有网易云该吃 timelineOffset,实际 %v", p)
	}
	if top := pickTop(results); top != "qq" {
		t.Fatalf("扣完之后冠军应是对齐的 QQ,实际 %s", top)
	}
}

// 自报曲长对得上、但末句跟曲长对不上被扣过分的候选不当锚点:它跟 Musixmatch 对齐也凑不成另一派,
// 自己按非锚点判。
func TestApplyTimelineOffsetPenaltyDurationOffIsNotAnchor(t *testing.T) {
	for _, kind := range []string{scoreTermDurationOff, scoreTermDurationOvershoot} {
		kugou := tlResult("kugou", 700, 297, tlLRC(20, tlConst(2400)), "")
		kugou.ScoreTerms = []scoreTerm{{Kind: kind, Points: -500}}
		if timelineAnchorEligible(kugou, 297) {
			t.Fatalf("%s:不该当锚点", kind)
		}
		results := append(tlOutlierBatch(), kugou)
		applyTimelineOffsetPenalty(results, 297)
		if p := tlPenalized(results); !p["musixmatch"] || !p["kugou"] || len(p) != 2 {
			t.Fatalf("%s:Musixmatch、酷狗都该吃 timelineOffset,实际 %v", kind, p)
		}
	}
}

// tlSplitLRC 跟 tlLRC 同正文,但每句拆成两行,后半句晚 2 秒。
func tlSplitLRC(n int, shift func(k int) int) string {
	var b strings.Builder
	for k := 0; k < n; k++ {
		ms := 10000 + k*5000 + shift(k)
		fmt.Fprintf(&b, "[%02d:%02d.%02d]line number %s\n", ms/60000, (ms/1000)%60, (ms%1000)/10, tlWord(k))
		ms += 2000
		fmt.Fprintf(&b, "[%02d:%02d.%02d]here\n", ms/60000, (ms/1000)%60, (ms%1000)/10)
	}
	return b.String()
}

// 一家把每句拆成两行时,拆开的第一段按开头配上整句,两个方向都判得出对齐和平移。
func TestClassifyTimelinesAcrossLineSplits(t *testing.T) {
	whole := displayedTimeline(tlLRC(20, tlConst(0)), "")
	for _, c := range []struct {
		shift int
		want  timelineRelation
	}{{0, timelineAligned}, {1800, timelineShiftedLater}} {
		split := displayedTimeline(tlSplitLRC(20, tlConst(c.shift)), "")
		if got := classifyTimelines(split, whole, timelineAnchorConflictMs); got != c.want {
			t.Errorf("拆行的一份平移 %dms:got %v, want %v", c.shift, got, c.want)
		}
		rev := map[timelineRelation]timelineRelation{timelineAligned: timelineAligned, timelineShiftedLater: timelineShiftedEarlier}[c.want]
		if got := classifyTimelines(whole, split, timelineAnchorConflictMs); got != rev {
			t.Errorf("整句的一份对拆行的平移 %dms:got %v, want %v", c.shift, got, rev)
		}
	}
}

func TestTimelineLinesMatch(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"风走了只留下一条街的叶落", "风走了只留下一条街的叶落", true},
		{"你好吗", "你好吗我很好", false},                 // 不到 4 个字
		{"可笑吗我删", "可笑吗我删访问记录的时候有多慌张你说的话", false}, // 不到较长一行的三成
		{"逼着自己早点睡", "逼着自己早点睡能不能再做一个有你的美梦", true},
		{"我删访问记录的时候", "可笑吗我删访问记录的时候有多慌张", false}, // 不是开头
		{"", "", false},
	}
	for _, c := range cases {
		if got := timelineLinesMatch(c.a, c.b); got != c.want {
			t.Errorf("timelineLinesMatch(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
		if got := timelineLinesMatch(c.b, c.a); got != c.want {
			t.Errorf("timelineLinesMatch(%q, %q) = %v, want %v", c.b, c.a, got, c.want)
		}
	}
}

// 落单的锚点被判掉之后,只跟它对齐的非锚点照样按基准组判。
func TestApplyTimelineOffsetPenaltyIgnoresOutlierForNonAnchors(t *testing.T) {
	results := append(tlOutlierBatch(), tlResult("netease", 1300, 310, tlLRC(20, tlConst(4600)), ""),
		tlResult("soda", 1250, 310, tlLRC(20, tlConst(4500)), ""))
	results[0].Lyrics, results[0].LyricsYRC = tlLRC(20, tlConst(4000)), tlYRC(20, tlConst(4000))
	applyTimelineOffsetPenalty(results, 297)
	if p := tlPenalized(results); !p["musixmatch"] || !p["netease"] || !p["soda"] || len(p) != 3 {
		t.Fatalf("Musixmatch、网易云、汽水都该吃 timelineOffset,实际 %v", p)
	}
}

// 行首的演唱者标签(「v1：」)不算正文:带标签的一份跟不带的一份逐行配得上、判成对齐。
func TestDisplayedTimelineSkipsSpeakerLabels(t *testing.T) {
	plain := tlLRC(20, tlConst(0))
	labeled := strings.ReplaceAll(plain, "]line", "]v1：line")
	labeledYRC := strings.ReplaceAll(tlYRC(20, tlConst(0)), ",0)line", ",0)v1：line")
	for name, got := range map[string][]timelineLine{
		"LRC": displayedTimeline(labeled, ""),
		"YRC": displayedTimeline(labeled, labeledYRC),
	} {
		want := displayedTimeline(plain, "")
		if len(got) != len(want) {
			t.Fatalf("%s:行数 %d,want %d", name, len(got), len(want))
		}
		for i := range got {
			if got[i].norm != want[i].norm {
				t.Fatalf("%s 第 %d 行正文 %q,want %q", name, i, got[i].norm, want[i].norm)
			}
		}
		if r := classifyTimelines(got, want, timelineAnchorConflictMs); r != timelineAligned {
			t.Fatalf("%s:带标签的一份应判成对齐,got %v", name, r)
		}
	}
}

func TestTimelinesIdentical(t *testing.T) {
	base := displayedTimeline(tlLRC(20, tlConst(0)), "")
	if !timelinesIdentical(base, displayedTimeline(tlLRC(20, tlConst(20)), "")) {
		t.Error("逐行只差 20ms 应算同一份")
	}
	if timelinesIdentical(base, displayedTimeline(tlLRC(20, tlConst(150)), "")) {
		t.Error("整首差 150ms 是各自对的轴,不算同一份")
	}
	if timelinesIdentical(base, displayedTimeline(tlLRC(5, tlConst(0)), "")) {
		t.Error("配对行数不够不判")
	}
}
