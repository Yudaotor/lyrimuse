package main

import (
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// 候选时间轴整体平移的批级判定(scoreTermTimelineOffset)。判据与参数的全库依据见 09 章决策 82、213、218。
//
// 锚点见 timelineAnchorEligible。两份时间轴按正文 LCS 配对后分三类(classifyTimelines):对齐、
// 整体平移(带方向)、判不了。
//   - 锚点之间有一对平移了 timelineAnchorConflictMs 以上:有一派来自足够多家时,派外的锚点逐家跟它比,
//     见 timelineAnchorOutliers;时长都对得上的几家自己分成两派时,哪派对得上本地判不了,整批不判。
//   - 锚点之间没有冲突时,至少要有一对来自不同信源家族、彼此对齐的锚点;它们与所有跟它们对齐的
//     锚点组成基准组。
//   - 非锚点候选与基准组里至少两家同向平移 timelineOffsetPenaltyMs 以上、且不与任何(没被判落单的)
//     锚点对齐,扣 timelineOffsetPenalty 分;落单的锚点同扣。
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
	// 配对时两行算同一句:正文相同,或较短一行至少 timelinePrefixMinRunes 个字、不短于较长一行的
	// timelinePrefixMinShare,且是较长一行的开头(见 timelineLinesMatch)。
	timelinePrefixMinRunes = 4
	timelinePrefixMinShare = 0.3
	// 锚点之间起冲突时:对齐成一派的锚点至少来自 timelineAnchorOutlierMinFamilies 家(时间轴是同一份的
	// 几家算一家),落单的那一家至少跟其中 timelineAnchorOutlierMinShifted 家同向平移,才判它错开。
	timelineAnchorOutlierMinFamilies = 3
	timelineAnchorOutlierMinShifted  = 2
	// 同一份时间轴:配对行里至少 timelineCopyMinShare 落在 timelineCopyToleranceMs 以内。酷狗 / 酷我 / QQ
	// 常是逐行同一时刻的副本,不算几家各自对的轴。
	timelineCopyToleranceMs = 30
	timelineCopyMinShare    = 0.9
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
// 行首的演唱者标签(「v1：」「男：」,见 lyricSpeakerLabels)不算正文,剥掉再配对,同 lyricConsensusBody。
func displayedTimeline(lrc, yrc string) []timelineLine {
	off := lrcOffsetTagMs(lrc)
	if off == 0 {
		off = lrcOffsetTagMs(yrc)
	}
	speakers := lyricSpeakerLabels(lrc)
	lrcLines := timelineLines(lrc, off, speakers)
	if yrc == "" {
		return lrcLines
	}
	var words []timelineLine
	for _, h := range yrcLineHeads(yrc) {
		if isCreditLine(h.text) {
			continue
		}
		if n := normTimelineText(timelineSungText(h.text, speakers)); n != "" {
			words = append(words, timelineLine{ms: h.ms - off, norm: n})
		}
	}
	if len(words) == 0 || len(words)*2 < len(lrcLines) {
		return lrcLines
	}
	sort.SliceStable(words, func(i, j int) bool { return words[i].ms < words[j].ms })
	return words
}

// timelineSungText:去掉行首的演唱者标签(speakers 是这一份认出的标签)。
func timelineSungText(text string, speakers map[string]bool) string {
	if label, rest, ok := lyricSplitLabel(text); ok && speakers[label] {
		return rest
	}
	return text
}

// timelineLines 把 LRC 展开成按显示时刻排序的(毫秒, 归一化正文):一行多戳按戳展开,已扣掉
// offsetMs;署名行与归一化后为空的行不参与,行首的演唱者标签剥掉(timelineSungText)。
func timelineLines(lrc string, offsetMs int, speakers map[string]bool) []timelineLine {
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
		n := normTimelineText(timelineSungText(text, speakers))
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

// timelineAnchorEligible:能当锚点的候选。自报曲长与本地相差不超过 timelineAnchorDurationToleranceSecs,
// 且没有因为末句跟曲长对不上被扣分(durationOff / durationOvershoot):正文自己说明它不是这一次录音时,
// 自报的曲长不算数。时间轴的两项批级判定(这里和 applyTimelineIntrusionPenalty)共用。见 09 章决策 218。
func timelineAnchorEligible(r scoredLyricCandidateResult, durationSecs float64) bool {
	return r.SourceReportedDurationSecs > 0 &&
		math.Abs(r.SourceReportedDurationSecs-durationSecs) <= timelineAnchorDurationToleranceSecs &&
		scoreTermPoints(r.ScoreTerms, scoreTermDurationOff) == 0 &&
		scoreTermPoints(r.ScoreTerms, scoreTermDurationOvershoot) == 0
}

// timelineLinesMatch:配对时 a、b 两行算不算同一句。各家分行不同(一句拆成两行、两句并成一行)时,
// 拆开的第一段跟整句同一时刻开始,按开头相同配上;拆出来的后半段配不上,不参与比较。见 09 章决策 218。
func timelineLinesMatch(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	if a == b {
		return true
	}
	short, long := a, b
	if len(short) > len(long) {
		short, long = long, short
	}
	n := utf8.RuneCountInString(short)
	return n >= timelinePrefixMinRunes &&
		float64(n) >= timelinePrefixMinShare*float64(utf8.RuneCountInString(long)) &&
		strings.HasPrefix(long, short)
}

// classifyTimelines 按正文 LCS 配对两份时间轴(两行算不算同一句见 timelineLinesMatch),判 a 相对 b
// 是对齐、整体平移 minShiftMs 以上,还是判不了。
func classifyTimelines(a, b []timelineLine, minShiftMs int) timelineRelation {
	var d []int
	for i, j := range timelineLCSAlignFunc(len(a), len(b), func(i, j int) bool { return timelineLinesMatch(a[i].norm, b[j].norm) }) {
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
		if timelineAnchorEligible(r, durationSecs) {
			anchors = append(anchors, i)
		} else {
			others = append(others, i)
		}
	}
	if len(anchors) < 2 {
		return
	}
	baseline, outliers, ok := timelineAnchorBaseline(results, lines, anchors)
	if !ok {
		return
	}
	isOutlier := map[int]bool{}
	for _, o := range outliers {
		isOutlier[o] = true
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
	penalized := append([]int(nil), outliers...)
	for _, i := range others {
		later, earlier, aligned := 0, 0, false
		for _, a := range anchors {
			if isOutlier[a] {
				continue
			}
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

// timelineAnchorBaseline 定基准组:锚点之间没有平移 timelineAnchorConflictMs 以上的冲突时,基准组是彼此对齐、
// 来自不同信源家族的锚点和跟它们对齐的锚点,没有落单的;有冲突时交给 timelineAnchorOutliers。ok=false 整批不判。
func timelineAnchorBaseline(results []scoredLyricCandidateResult, lines [][]timelineLine, anchors []int) (baseline map[int]bool, outliers []int, ok bool) {
	rel := map[[2]int]timelineRelation{}
	conflict := false
	for x := 0; x < len(anchors); x++ {
		for y := x + 1; y < len(anchors); y++ {
			a, b := anchors[x], anchors[y]
			r := classifyTimelines(lines[a], lines[b], timelineAnchorConflictMs)
			rel[[2]int{a, b}] = r
			rel[[2]int{b, a}] = classifyTimelines(lines[b], lines[a], timelineAnchorConflictMs)
			if r == timelineShiftedLater || r == timelineShiftedEarlier {
				conflict = true
			}
		}
	}
	if conflict {
		return timelineAnchorOutliers(results, lines, anchors, rel)
	}
	baseline = map[int]bool{}
	for x := 0; x < len(anchors); x++ {
		for y := x + 1; y < len(anchors); y++ {
			a, b := anchors[x], anchors[y]
			if rel[[2]int{a, b}] == timelineAligned && lyricSourceConsensusFamily(results[a].Source) != lyricSourceConsensusFamily(results[b].Source) {
				baseline[a], baseline[b] = true, true
			}
		}
	}
	if len(baseline) == 0 {
		return nil, nil, false
	}
	for _, a := range anchors {
		for b := range baseline {
			if a != b && rel[[2]int{a, b}] == timelineAligned {
				baseline[a] = true
			}
		}
	}
	return baseline, nil, true
}

// timelineAnchorOutliers:锚点之间有冲突时,先定基准组,派外的锚点再逐家跟它比。
//   - 时间轴是同一份的几家算一家(同一信源家族,或逐行同一时刻,见 timelinesIdentical);彼此对齐的锚点连成一派。
//   - 来自家数最多的那一派要有 timelineAnchorOutlierMinFamilies 家以上、家数不能跟别的派打平,它就是基准组;
//     基准组内部不能有互相平移的。
//   - 基准组之外的派只能各是一家(两家以上自己对齐成派 = 分成两派,哪派对得上本地判不了)。
//   - 派外的锚点跟基准组里 timelineAnchorOutlierMinShifted 家以上同向平移、不跟任何一家反向,判它错开;
//     跟基准组哪家都判不了、只跟一家平移、两个方向都有的,这一家判不了,留着不动。错开的有几家都照判:
//     它们彼此也对不上,动摇不了基准组。
//   - 判错开的里有跟当前播放器同源的那份时整批不判(同源歌词是对着这个播放器的音频做的,
//     它错开说明这一版母带跟别家不同)。
//
// 见 09 章决策 213、218。
func timelineAnchorOutliers(results []scoredLyricCandidateResult, lines [][]timelineLine, anchors []int, rel map[[2]int]timelineRelation) (baseline map[int]bool, outliers []int, ok bool) {
	family := map[int]int{}
	camp := map[int]int{}
	for _, a := range anchors {
		family[a], camp[a] = a, a
	}
	root := func(m map[int]int, x int) int {
		for m[x] != x {
			m[x] = m[m[x]]
			x = m[x]
		}
		return x
	}
	join := func(m map[int]int, a, b int) { m[root(m, a)] = root(m, b) }
	for x := 0; x < len(anchors); x++ {
		for y := x + 1; y < len(anchors); y++ {
			a, b := anchors[x], anchors[y]
			if lyricSourceConsensusFamily(results[a].Source) == lyricSourceConsensusFamily(results[b].Source) || timelinesIdentical(lines[a], lines[b]) {
				join(family, a, b)
				join(camp, a, b)
			}
			if rel[[2]int{a, b}] == timelineAligned {
				join(camp, a, b)
			}
		}
	}
	camps := map[int][]int{}
	for _, a := range anchors {
		r := root(camp, a)
		camps[r] = append(camps[r], a)
	}
	families := func(members []int) int {
		seen := map[int]bool{}
		for _, m := range members {
			seen[root(family, m)] = true
		}
		return len(seen)
	}
	best, bestFamilies, tie := -1, 0, false
	for r, members := range camps {
		switch f := families(members); {
		case f > bestFamilies:
			best, bestFamilies, tie = r, f, false
		case f == bestFamilies:
			tie = true
		}
	}
	if tie || bestFamilies < timelineAnchorOutlierMinFamilies {
		return nil, nil, false
	}
	baseline = map[int]bool{}
	for _, m := range camps[best] {
		baseline[m] = true
	}
	for r, members := range camps {
		if r != best && families(members) > 1 {
			return nil, nil, false
		}
	}
	for _, a := range camps[best] {
		for _, b := range camps[best] {
			if r := rel[[2]int{a, b}]; a != b && (r == timelineShiftedLater || r == timelineShiftedEarlier) {
				return nil, nil, false
			}
		}
	}
	for _, a := range anchors {
		if baseline[a] {
			continue
		}
		later, earlier := map[int]bool{}, map[int]bool{}
		for _, b := range camps[best] {
			switch rel[[2]int{a, b}] {
			case timelineShiftedLater:
				later[root(family, b)] = true
			case timelineShiftedEarlier:
				earlier[root(family, b)] = true
			}
		}
		if len(later) > 0 && len(earlier) > 0 || len(later)+len(earlier) < timelineAnchorOutlierMinShifted {
			continue
		}
		if scoreTermPoints(results[a].ScoreTerms, scoreTermNativeSource) > 0 {
			return nil, nil, false
		}
		outliers = append(outliers, a)
	}
	if len(outliers) == 0 {
		return nil, nil, false
	}
	return baseline, outliers, true
}

// timelinesIdentical:两份显示轴按正文配对后,至少 timelineCopyMinShare 的配对行相差不到 timelineCopyToleranceMs ——
// 同一份上游时间轴的副本。配对不足 timelineOffsetMinMatched 行或不到较短一份的一半时不算。
func timelinesIdentical(a, b []timelineLine) bool {
	an := make([]string, len(a))
	for i, l := range a {
		an[i] = l.norm
	}
	bn := make([]string, len(b))
	for i, l := range b {
		bn[i] = l.norm
	}
	matched, near := 0, 0
	for i, j := range timelineLCSAlign(an, bn) {
		if j < 0 {
			continue
		}
		matched++
		if d := a[i].ms - b[j].ms; d <= timelineCopyToleranceMs && d >= -timelineCopyToleranceMs {
			near++
		}
	}
	if matched < timelineOffsetMinMatched || matched*2 < min(len(a), len(b)) {
		return false
	}
	return float64(near) >= timelineCopyMinShare*float64(matched)
}
