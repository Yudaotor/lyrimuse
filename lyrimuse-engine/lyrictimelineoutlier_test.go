package main

import (
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
		{"落单的来自两家", func() []scoredLyricCandidateResult {
			return append(tlOutlierBatch(), tlResult("netease", 1100, 297, tlLRC(20, tlConst(-2200)), ""))
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
