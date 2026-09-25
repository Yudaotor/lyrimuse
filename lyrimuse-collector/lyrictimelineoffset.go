package main

import (
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// 候选时间轴整体平移的批级判定(scoreTermTimelineOffset)。判据与参数的全库依据见
// docs/features/09-lyrics-resolution.md 决策 82。
//
// 锚点 = 自报曲长与本地相差不超过 timelineAnchorDurationToleranceSecs 的候选。两份时间轴按正文
// LCS 配对后分三类(classifyTimelines):对齐、整体平移(带方向)、判不了。
//   - 锚点之间只要有一对平移了 timelineAnchorConflictMs 以上,整批不判:时长都对得上的几家
//     自己分成两派时,哪派对得上本地判不了。
//   - 至少要有一对来自不同信源家族、彼此对齐的锚点;它们与所有跟它们对齐的锚点组成基准组。
//   - 非锚点候选与基准组里至少两家同向平移 timelineOffsetPenaltyMs 以上、且不与任何锚点对齐,
//     扣 timelineOffsetPenalty 分。
//   - 扣完之后的第一名必须是基准组成员或与基准组某家对齐,否则整批撤销:这一步只在能把冠军
//     交给核实过对得上的那份时才动手。
const (
	timelineAnchorDurationToleranceSecs = 1.5
	timelineAnchorConflictMs            = 1500
	timelineOffsetPenaltyMs             = 2500
	// 对齐:中位偏移在 timelineNearMs 以内,且至少 timelineMinShare 的配对行落在中位偏移
	// ±timelineNearMs 内(两家之间恒定的几百毫秒差算对齐)。平移:中位偏移够大,且至少
	// timelineMinShare 的配对行同侧偏出 timelineNearMs(前后两段偏移量不同的也算)。占比这一条
	// 区分"整首平移"和"重复副歌配错行"。配对不足 timelineOffsetMinMatched 行或不到较短一份的
	// 一半时判不了。
	timelineOffsetMinMatched = 8
	timelineNearMs           = 1000
	timelineMinShare         = 0.8
	timelineOffsetPenalty    = 600
)

var lrcOffsetTagRe = regexp.MustCompile(`\[offset:\s*([+-]?\d+)\s*\]`)

// lrcOffsetTagMs 与 App 侧 LRCParser.parseOffsetMs 同一口径:取第一个 [offset:] 标签,正数表示
// 歌词整体提前显示;解析不出或绝对值超过 10 秒返回 0。两边必须同步改。
func lrcOffsetTagMs(lrc string) int {
	m := lrcOffsetTagRe.FindStringSubmatch(lrc)
	if m == nil {
		return 0
	}
	v, err := strconv.Atoi(m[1])
	if err != nil || v > 10000 || v < -10000 {
		return 0
	}
	return v
}

type timelineLine struct {
	ms   int
	norm string
}

// displayedTimeline 是 App 实际拿来显示的那条时间轴,口径与 LyricsSyncEngine.load 一致:有逐字轴、
// 且逐字行数不少于整行 LRC 的一半时按逐字轴的行首,否则按整行 LRC;[offset:] 先取 LRC 里的,
// 为 0 再取 YRC 里的。只看整行 LRC 会冤枉"整行 LRC 错开、逐字轴是对的"的候选。
func displayedTimeline(lrc, yrc string) []timelineLine {
	off := lrcOffsetTagMs(lrc)
	if off == 0 {
		off = lrcOffsetTagMs(yrc)
	}
	lrcLines := timelineLines(lrc, off)
	if yrc == "" {
		return lrcLines
	}
	var words []timelineLine
	for _, h := range yrcLineHeads(yrc) {
		if isCreditLine(h.text) {
			continue
		}
		if n := normTimelineText(h.text); n != "" {
			words = append(words, timelineLine{ms: h.ms - off, norm: n})
		}
	}
	if len(words) == 0 || len(words)*2 < len(lrcLines) {
		return lrcLines
	}
	sort.SliceStable(words, func(i, j int) bool { return words[i].ms < words[j].ms })
	return words
}

// timelineLines 把 LRC 展开成按显示时刻排序的(毫秒, 归一化正文):一行多戳按戳展开,已扣掉
// offsetMs;署名行与归一化后为空的行不参与。
func timelineLines(lrc string, offsetMs int) []timelineLine {
	var out []timelineLine
	for _, line := range strings.Split(lrc, "\n") {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) == 0 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || isCreditLine(text) {
			continue
		}
		n := normTimelineText(text)
		if n == "" {
			continue
		}
		for _, s := range stamps {
			out = append(out, timelineLine{ms: lrcStampMs(s) - offsetMs, norm: n})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ms < out[j].ms })
	return out
}

// timelineRelation 是 classifyTimelines 的结论。
type timelineRelation int

const (
	timelineUndecided timelineRelation = iota
	timelineAligned
	timelineShiftedLater   // a 整体比 b 晚
	timelineShiftedEarlier // a 整体比 b 早
)

// classifyTimelines 按正文 LCS 配对两份时间轴,判 a 相对 b 是对齐、整体平移 minShiftMs 以上,
// 还是判不了。
func classifyTimelines(a, b []timelineLine, minShiftMs int) timelineRelation {
	an := make([]string, len(a))
	for i, l := range a {
		an[i] = l.norm
	}
	bn := make([]string, len(b))
	for i, l := range b {
		bn[i] = l.norm
	}
	var d []int
	for i, j := range timelineLCSAlign(an, bn) {
		if j >= 0 {
			d = append(d, a[i].ms-b[j].ms)
		}
	}
	short := min(len(a), len(b))
	if len(d) < timelineOffsetMinMatched || len(d)*2 < short {
		return timelineUndecided
	}
	sorted := append([]int(nil), d...)
	sort.Ints(sorted)
	med := sorted[len(sorted)/2]
	aroundMedian, later, earlier := 0, 0, 0
	for _, x := range d {
		if x-med < timelineNearMs && med-x < timelineNearMs {
			aroundMedian++
		}
		if x >= timelineNearMs {
			later++
		} else if x <= -timelineNearMs {
			earlier++
		}
	}
	share := func(n int) float64 { return float64(n) / float64(len(d)) }
	switch {
	case med < timelineNearMs && -med < timelineNearMs && share(aroundMedian) >= timelineMinShare:
		return timelineAligned
	case med >= minShiftMs && share(later) >= timelineMinShare:
		return timelineShiftedLater
	case med <= -minShiftMs && share(earlier) >= timelineMinShare:
		return timelineShiftedEarlier
	}
	return timelineUndecided
}

// applyTimelineOffsetPenalty 给时间轴整体平移到另一个母带上的候选扣 timelineOffsetPenalty 分,
// 并记一条 scoreTermTimelineOffset。必须在全部候选打完分之后、applyWordTimingTitleOverride
// 与排序之前调用:它改分,那一步要看的是改完之后谁赢。两条流水线(rankLyricSourceResults、
// mergeLyricCandidateRounds)都要调,判定口径才一致。
func applyTimelineOffsetPenalty(results []scoredLyricCandidateResult, durationSecs float64) {
	if durationSecs <= 0 {
		return
	}
	lines := make([][]timelineLine, len(results))
	var anchors, others []int
	for i, r := range results {
		if r.Score < 0 || r.Lyrics == "" {
			continue
		}
		lines[i] = displayedTimeline(r.Lyrics, r.LyricsYRC)
		if r.SourceReportedDurationSecs > 0 && math.Abs(r.SourceReportedDurationSecs-durationSecs) <= timelineAnchorDurationToleranceSecs {
			anchors = append(anchors, i)
		} else {
			others = append(others, i)
		}
	}
	if len(anchors) < 2 || len(others) == 0 {
		return
	}
	baseline := map[int]bool{}
	for x := 0; x < len(anchors); x++ {
		for y := x + 1; y < len(anchors); y++ {
			a, b := anchors[x], anchors[y]
			switch classifyTimelines(lines[a], lines[b], timelineAnchorConflictMs) {
			case timelineShiftedLater, timelineShiftedEarlier:
				return
			case timelineAligned:
				if lyricSourceConsensusFamily(results[a].Source) != lyricSourceConsensusFamily(results[b].Source) {
					baseline[a], baseline[b] = true, true
				}
			}
		}
	}
	if len(baseline) == 0 {
		return
	}
	for _, a := range anchors {
		for b := range baseline {
			if a != b && classifyTimelines(lines[a], lines[b], timelineAnchorConflictMs) == timelineAligned {
				baseline[a] = true
			}
		}
	}
	alignedWithBaseline := func(i int) bool {
		if baseline[i] {
			return true
		}
		for b := range baseline {
			if classifyTimelines(lines[i], lines[b], timelineOffsetPenaltyMs) == timelineAligned {
				return true
			}
		}
		return false
	}
	var penalized []int
	for _, i := range others {
		later, earlier, aligned := 0, 0, false
		for _, a := range anchors {
			switch classifyTimelines(lines[i], lines[a], timelineOffsetPenaltyMs) {
			case timelineAligned:
				aligned = true
			case timelineShiftedLater:
				if baseline[a] {
					later++
				}
			case timelineShiftedEarlier:
				if baseline[a] {
					earlier++
				}
			}
		}
		if aligned || (later > 0 && earlier > 0) || later+earlier < 2 {
			continue
		}
		penalized = append(penalized, i)
	}
	if len(penalized) == 0 {
		return
	}
	scores := make([]int, len(results))
	for i, r := range results {
		scores[i] = r.Score
	}
	for _, i := range penalized {
		scores[i] = max(scores[i]-timelineOffsetPenalty, 1) // 跟 scoreLyricCandidateDetailed 末尾同一条夹底纪律
	}
	top := -1
	for i := range results {
		if results[i].Score >= 0 && (top == -1 || scores[i] > scores[top]) {
			top = i
		}
	}
	if top == -1 || !alignedWithBaseline(top) {
		return
	}
	for _, i := range penalized {
		results[i].Score = scores[i]
		results[i].ScoreTerms = append(results[i].ScoreTerms, scoreTerm{Kind: scoreTermTimelineOffset, Points: -timelineOffsetPenalty})
	}
}
