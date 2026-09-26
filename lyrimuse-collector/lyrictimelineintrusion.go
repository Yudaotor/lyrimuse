package main

import "math"

// 候选时间轴在间奏里多出一段的批级判定(scoreTermTimelineIntrusion)。判据与参数的全库依据见
// docs/features/09-lyrics-resolution.md 决策 98。
//
// 参照组 = 除被检查的这份之外、自报曲长与本地相差不超过 timelineAnchorDurationToleranceSecs 的候选,
// 且至少来自两个信源家族(lyricSourceConsensusFamily)。
//   - 共同空档:参照组每一家的显示轴在两句之间都没有行、长度不少于 timelineIntrusionMinGapMs 的区间
//     (各家空档求交集)。只看两句之间:第一句之前、最后一句之后各家收不收前奏人声 / 片尾 ad-lib 差别很大。
//   - 被检查的这份在共同空档里(两端各让 timelineIntrusionEdgeMs)有不少于 timelineIntrusionMinLines 句,
//     且其中至少一半的正文在参照组别处出现过 —— 把别处的歌词复制进了间奏。署名行不参与
//     (displayedTimeline 已经滤掉)。只看行数不看正文会误伤各家不收的和声 / ad-lib。
//   - 扣 timelineIntrusionPenalty 分。扣完之后的第一名必须是没被扣分的参照候选(自报曲长对得上),
//     否则整批撤销:只在能把冠军交给一份核实过的轴时才动手。
//   - 参照组自己在那段有行(比如别的源镜像了同一份错轴),就没有共同空档,整批不判。
const (
	timelineIntrusionMinGapMs = 12000
	timelineIntrusionEdgeMs   = 1500
	timelineIntrusionMinLines = 3
	timelineIntrusionPenalty  = 600
)

type timelineGap struct{ from, to int }

// timelineInnerGaps:一条显示轴相邻两句之间不短于 minMs 的空档。
func timelineInnerGaps(lines []timelineLine, minMs int) []timelineGap {
	var out []timelineGap
	for i := 1; i < len(lines); i++ {
		if lines[i].ms-lines[i-1].ms >= minMs {
			out = append(out, timelineGap{lines[i-1].ms, lines[i].ms})
		}
	}
	return out
}

// intersectTimelineGaps:两组空档的交集里不短于 minMs 的部分。
func intersectTimelineGaps(a, b []timelineGap, minMs int) []timelineGap {
	var out []timelineGap
	for _, x := range a {
		for _, y := range b {
			lo, hi := max(x.from, y.from), min(x.to, y.to)
			if hi-lo >= minMs {
				out = append(out, timelineGap{lo, hi})
			}
		}
	}
	return out
}

// timelineIntrudes:cand 有没有在参照组的共同空档里塞进一段参照组别处的歌词。纯函数。
func timelineIntrudes(cand []timelineLine, refs [][]timelineLine) bool {
	if len(refs) < 2 {
		return false
	}
	var common []timelineGap
	refText := map[string]bool{}
	for i, r := range refs {
		for _, l := range r {
			refText[l.norm] = true
		}
		g := timelineInnerGaps(r, timelineIntrusionMinGapMs)
		if i == 0 {
			common = g
		} else {
			common = intersectTimelineGaps(common, g, timelineIntrusionMinGapMs)
		}
		if len(common) == 0 {
			return false
		}
	}
	for _, g := range common {
		inside, copied := 0, 0
		for _, l := range cand {
			if l.ms > g.from+timelineIntrusionEdgeMs && l.ms < g.to-timelineIntrusionEdgeMs {
				inside++
				if refText[l.norm] {
					copied++
				}
			}
		}
		if copied >= timelineIntrusionMinLines && copied*2 >= inside {
			return true
		}
	}
	return false
}

// applyTimelineIntrusionPenalty 给在间奏里多出一段歌词的候选扣 timelineIntrusionPenalty 分,并记一条
// scoreTermTimelineIntrusion。调用位置同 applyTimelineOffsetPenalty(紧跟在它后面):两条流水线都要调,
// 且在 applyWordTimingTitleOverride 与排序之前。
func applyTimelineIntrusionPenalty(results []scoredLyricCandidateResult, durationSecs float64) {
	if durationSecs <= 0 {
		return
	}
	lines := make([][]timelineLine, len(results))
	anchor := make([]bool, len(results))
	for i, r := range results {
		if r.Score < 0 || r.Lyrics == "" {
			continue
		}
		lines[i] = displayedTimeline(r.Lyrics, r.LyricsYRC)
		anchor[i] = r.SourceReportedDurationSecs > 0 &&
			math.Abs(r.SourceReportedDurationSecs-durationSecs) <= timelineAnchorDurationToleranceSecs &&
			len(lines[i]) >= timelineOffsetMinMatched
	}
	penalized := map[int]bool{}
	for i := range results {
		if len(lines[i]) == 0 {
			continue
		}
		var refs [][]timelineLine
		families := map[string]bool{}
		for j := range results {
			if j != i && anchor[j] {
				refs = append(refs, lines[j])
				families[lyricSourceConsensusFamily(results[j].Source)] = true
			}
		}
		if len(families) < 2 {
			continue
		}
		if timelineIntrudes(lines[i], refs) {
			penalized[i] = true
		}
	}
	if len(penalized) == 0 {
		return
	}
	scores := make([]int, len(results))
	for i, r := range results {
		scores[i] = r.Score
		if penalized[i] {
			scores[i] = max(r.Score-timelineIntrusionPenalty, 1) // 跟 scoreLyricCandidateDetailed 末尾同一条夹底纪律
		}
	}
	top := -1
	for i := range results {
		if results[i].Score >= 0 && (top == -1 || scores[i] > scores[top]) {
			top = i
		}
	}
	if top == -1 || !anchor[top] || penalized[top] {
		return
	}
	for i := range penalized {
		results[i].Score = scores[i]
		results[i].ScoreTerms = append(results[i].ScoreTerms, scoreTerm{Kind: scoreTermTimelineIntrusion, Points: -timelineIntrusionPenalty})
	}
}
