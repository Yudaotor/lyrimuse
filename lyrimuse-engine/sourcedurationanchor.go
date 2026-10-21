package main

import "math"

// 有锚点时源自报曲长的收紧判定(scoreTermSourceDurationNearMiss)。判据与全库回放见 09 章决策 310。
//
// 锚点同时间轴那两项批级判定(timelineAnchorEligible):自报曲长跟本地差不超过 1.5 秒、正文末句没被判
// 对不上。这一轮有别的源的锚点时,自报曲长跟本地差超过 sourceDurationNearMissTolerance、且至少差
// sourceDurationNearMissMinSecs 秒的候选扣 sourceDurationNearMissPenalty 分:同一首歌已经有曲库报出了
// 本地这次录音的长度,差出这么多的那份多半挂在现场版、混音版、另一次剪辑上。超过
// sourceDurationMismatchTolerance 的已经由 sourceDurationOff 扣过,这里不重复扣。
//   - 只扣不加:时长对得上的候选不加分(加分方向见 sourceDurationMismatchPenalty 的注释,别改成加分)。
//   - 播放器本地歌词与跟当前播放器同源的候选不扣:它们挂在正在放的这一份音频上。
//   - 绝对秒数下限挡短曲:十几秒的片段差 1 秒取整就过了比例。
const (
	sourceDurationNearMissTolerance = 0.05
	sourceDurationNearMissMinSecs   = 4.0
	sourceDurationNearMissPenalty   = 400
)

// sourceDurationNearMiss:自报曲长 reported 跟本地 local 的差落在收紧档里(比例超过
// sourceDurationNearMissTolerance、不超过 sourceDurationMismatchTolerance,且不少于 sourceDurationNearMissMinSecs 秒)。
func sourceDurationNearMiss(reported, local float64) bool {
	diff := math.Abs(reported - local)
	ratio := diff / math.Max(reported, local)
	return ratio > sourceDurationNearMissTolerance && ratio <= sourceDurationMismatchTolerance && diff >= sourceDurationNearMissMinSecs
}

// sourceDurationNearMissApplies:这份候选的自报曲长落在收紧档里、且不是挂在正在放的这份音频上的歌词。
// 有没有锚点另判;首轮先上屏不看锚点,直接用它挡(earlyLyricsVerdict)。
func sourceDurationNearMissApplies(r scoredLyricCandidateResult, durationSecs float64) bool {
	if r.Score < 0 || r.Lyrics == "" || !sourceDurationNearMiss(r.SourceReportedDurationSecs, durationSecs) {
		return false
	}
	return !isPlayerLocalLyricSource(r.Source) && scoreTermPoints(r.ScoreTerms, scoreTermNativeSource) == 0
}

// applySourceDurationNearMissPenalty 给有锚点时自报曲长差出收紧档的候选扣分,并记一条
// scoreTermSourceDurationNearMiss。两条流水线都要调,排在 applyTimelineOffsetPenalty 之前:
// 时间轴那两项要看的是这一步扣完之后谁赢。
func applySourceDurationNearMissPenalty(results []scoredLyricCandidateResult, durationSecs float64) {
	if durationSecs <= 0 {
		return
	}
	anchored := false
	for _, r := range results {
		if r.Score >= 0 && r.Lyrics != "" && timelineAnchorEligible(r, durationSecs) {
			anchored = true
			break
		}
	}
	if !anchored {
		return
	}
	for i, r := range results {
		if !sourceDurationNearMissApplies(r, durationSecs) {
			continue
		}
		results[i].Score = max(r.Score-sourceDurationNearMissPenalty, 1) // 跟 scoreLyricCandidateDetailed 末尾同一条夹底纪律
		results[i].ScoreTerms = append(results[i].ScoreTerms, scoreTerm{Kind: scoreTermSourceDurationNearMiss, Points: -sourceDurationNearMissPenalty})
	}
}
