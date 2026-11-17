package main

import "slices"

// 同源加分让给对得上的逐字版(scoreTermNativeSourceYield)。判据与全库依据见 09 章决策 374。
//
// 智能算法下,当前第一名是跟正在放的播放器同源、只有逐行的那份,而别家有一份逐字候选同时满足:
//   - 没带 earlyLyricsPenaltyTerms 里的扣分项;
//   - 显示轴跟同源那份对齐(classifyTimelines 判 timelineAligned);
//   - 结尾没缺:同源那份最后一句正文在它的显示轴里配得上,或它最后一句不比同源那份早 timelineNearMs 以上。
//
// 就撤销同源那份的同源加分。撤销后的第一名必须是这样一份逐字候选、且接着的标题否决不会撤掉它的逐字加分,否则整批不动。播放器本地歌词
// (isPlayerLocalLyricSource)不撤;「顺序优先」不比分,这一步不跑。

// applyNativeSourceWordYield 两条流水线(rankLyricSourceResults、mergeLyricCandidateRounds)都要调,排在
// applyDurationNearTie 之后、applyWordTimingTitleOverride 之前:要看的是各项批级扣分之后谁领先,撤销后的结果
// 还要再过逐字加分撤销那一步。
func applyNativeSourceWordYield(results []scoredLyricCandidateResult) {
	if features().LyricsSourceMode == lyricsModePriority {
		return
	}
	scores := make([]int, len(results))
	for i, r := range results {
		scores[i] = r.Score
	}
	n := topScoredIndex(results, scores)
	if n == -1 {
		return
	}
	native := results[n]
	bonus := scoreTermPoints(native.ScoreTerms, scoreTermNativeSource)
	if bonus <= 0 || scoreTermPoints(native.ScoreTerms, scoreTermWordTiming) > 0 || native.Lyrics == "" ||
		isPlayerLocalLyricSource(native.Source) {
		return
	}
	nativeLines := displayedTimeline(native.Lyrics, native.LyricsYRC)
	if len(nativeLines) == 0 {
		return
	}
	scores[n] = max(native.Score-bonus, 1) // 跟 scoreLyricCandidateDetailed 末尾同一条夹底纪律
	top := topScoredIndex(results, scores)
	if top == n || !nativeYieldTarget(results[top], nativeLines) || yieldLosesToTitleOverride(results, n, top, scores[n]) {
		return
	}
	results[n].Score = scores[n]
	results[n].ScoreTerms = append(results[n].ScoreTerms, scoreTerm{Kind: scoreTermNativeSourceYield, Points: -bonus})
}

// yieldLosesToTitleOverride 预演紧跟着的 applyWordTimingTitleOverride:让位之后接班的 top 会被撤掉逐字加分,
// 就别让——不然冠军落到让位前排不上的第三家,或同源那份带着白扣的分照样赢(见 09 章决策 382)。
func yieldLosesToTitleOverride(results []scoredLyricCandidateResult, native, top, nativeScore int) bool {
	trial := make([]scoredLyricCandidateResult, len(results))
	copy(trial, results)
	for i := range trial {
		trial[i].ScoreTerms = slices.Clip(trial[i].ScoreTerms)
	}
	trial[native].Score = nativeScore
	applyWordTimingTitleOverride(trial)
	return scoreTermPoints(trial[top].ScoreTerms, scoreTermWordTimingOverride) < 0
}

// nativeYieldTarget:c 是不是同源加分可以让出去的那种逐字候选(条件见文件头注)。
func nativeYieldTarget(c scoredLyricCandidateResult, nativeLines []timelineLine) bool {
	if c.Lyrics == "" || scoreTermPoints(c.ScoreTerms, scoreTermWordTiming) <= 0 {
		return false
	}
	for _, t := range c.ScoreTerms {
		if earlyLyricsPenaltyTerms[t.Kind] {
			return false
		}
	}
	lines := displayedTimeline(c.Lyrics, c.LyricsYRC)
	return len(lines) > 0 && nativeEndingCovered(lines, nativeLines) &&
		classifyTimelines(lines, nativeLines, timelineOffsetPenaltyMs) == timelineAligned
}

// nativeEndingCovered:同源那份(nativeLines)的最后一句正文在 lines 里按正文配得上(配法同 classifyTimelines),或 lines 的
// 最后一句不比它早 timelineNearMs 以上。两份末尾都留着没认成署名的署名行、而逐字轴把它们挤在一起时,时刻对不上,正文配得上。
func nativeEndingCovered(lines, nativeLines []timelineLine) bool {
	last := len(nativeLines) - 1
	if lines[len(lines)-1].ms > nativeLines[last].ms-timelineNearMs {
		return true
	}
	pairs := timelineLCSAlignFunc(len(nativeLines), len(lines), func(i, j int) bool {
		return timelineLinesMatch(nativeLines[i].norm, lines[j].norm)
	})
	return pairs[last] >= 0
}

// topScoredIndex:按 scores 分数最高、没被判废的那条(同分取靠前的,同排序后的第一名)。没有为 -1。
func topScoredIndex(results []scoredLyricCandidateResult, scores []int) int {
	top := -1
	for i := range results {
		if results[i].Score >= 0 && (top == -1 || scores[i] > scores[top]) {
			top = i
		}
	}
	return top
}
