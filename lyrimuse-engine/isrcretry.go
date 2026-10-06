package main

import (
	"context"
	"slices"
	"sort"
)

// 按 ISRC 补取未应答的源。
//
// Deezer、Musixmatch 里不少日文 / 韩文歌只登记了罗马字写法(「Kimini Muchuu / Hikaru Utada」),按本地的原文
// 歌名搜不到或过不了名称闸;Musixmatch 的 track.search 还只认它自己那份拼法(连写、长音写法都得一字不差),
// 把原文转成罗马音去搜也搜不到。两家都支持按 ISRC 直取(deezerTrackByISRC / musixmatchTrackByISRC,
// 只过时长闸),而 Apple Music 曲库的 song attributes 自带 ISRC。所以所有轮次跑完、这两家还缺着时,拿已被
// 认可的 Apple Music 候选报的 ISRC 再问它们一次。见 09 章决策 126。amll 没给出可用候选、索引里又有这个 ISRC 时一并问
// (那一轮按 ISRC 在本地索引里找,见 amllIndex.lookup)。
//
// 播放时有 Spotify 给的 ISRC 就用它(playbackISRC,那是正在播的这一条录音),这里只在它为空时补上。

type recordingISRCKey struct{}

// withRecordingISRC 给 ctx 挂上这一轮按 ISRC 直取用的编码。
func withRecordingISRC(ctx context.Context, isrc string) context.Context {
	return context.WithValue(ctx, recordingISRCKey{}, isrc)
}

// lyricSourceISRC:发给 deezer / musixmatch / applemusic / amll 的 ISRC。播放器给的优先(按原样标签查,见
// lyricIdentityFields),其次是 ctx 上挂的(补取那一轮不问 applemusic,所以它拿到的只会是播放器给的)。
func lyricSourceISRC(ctx context.Context, artist, title, album string) string {
	if code := playbackISRC(lyricIdentityFields(ctx, artist, title, album)); code != "" {
		return code
	}
	code, _ := ctx.Value(recordingISRCKey{}).(string)
	return code
}

// isrcRetryableSources:能按 ISRC 直取的歌词源。
var isrcRetryableSources = []string{"deezer", "musixmatch"}

// isrcRetryPlan:拿哪个 ISRC、去问哪几个源。源:能按 ISRC 直取、启用着、这一轮没给出可用候选、换个身份还
// 值得再问(lyricSourcesWorthRetry 剔掉连不上的、地区受限的);amll 还要索引里有这个 ISRC(amllIndex.hasISRC)。
// ISRC 见 acceptedAppleMusicISRC。任何一样没有就返回空。
func isrcRetryPlan(ctx context.Context, results []scoredLyricCandidateResult, durationSecs float64) (string, []string) {
	isrc := acceptedAppleMusicISRC(results, durationSecs)
	if isrc == "" {
		return "", nil
	}
	var sources []string
	for _, s := range lyricSourcesWorthRetry(ctx, results) {
		if slices.Contains(isrcRetryableSources, s) || (s == "amll" && sharedAMLLIndexStore().current().hasISRC(isrc)) {
			sources = append(sources, s)
		}
	}
	if len(sources) == 0 {
		return "", nil
	}
	sort.Strings(sources)
	return isrc, sources
}

// acceptedAppleMusicISRC:acceptedSourceISRC 的 applemusic 那份。
func acceptedAppleMusicISRC(results []scoredLyricCandidateResult, durationSecs float64) string {
	return acceptedSourceISRC(results, "applemusic", durationSecs)
}

// acceptedSourceISRC:source 这个源里分数最高的那条已被认可(Score >= 0)、带 ISRC、自报时长跟本地对得上的候选报的
// ISRC,同分取先出现的;没有返回空。
func acceptedSourceISRC(results []scoredLyricCandidateResult, source string, durationSecs float64) string {
	best := -1
	for i, r := range results {
		if r.Source != source || r.ISRC == "" || r.Score < 0 || !sourceDurationFits(durationSecs, r.SourceReportedDurationSecs) {
			continue
		}
		if best < 0 || r.Score > results[best].Score {
			best = i
		}
	}
	if best < 0 {
		return ""
	}
	return results[best].ISRC
}

// isrcRetryReference:前面几轮已认可的候选的正文。按 ISRC 补取那一轮带回来的候选,正文要跟其中至少一条对得上
// 才并进来,口径同跨源共识(lyricConsensusBody 归一后的 3-gram Jaccard 不低于 lyricConsensusSimThreshold)。
// 按 ISRC 直取不过歌名闸,这是那一轮唯一的身份核对;不看时长,时长照旧交给打分。前面几轮没有正文够长的
// 已认可候选、或者补来的这条正文太短没法比时,照旧收下。见 09 章决策 188。
type isrcRetryReference []map[string]struct{}

func newISRCRetryReference(base []scoredLyricCandidateResult) isrcRetryReference {
	var ref isrcRetryReference
	for _, r := range base {
		if r.Score < 0 {
			continue
		}
		if g := isrcRetryGrams(r.Lyrics); g != nil {
			ref = append(ref, g)
		}
	}
	return ref
}

// isrcRetryGrams:正文归一后的 3-gram;归一后不足 lyricConsensusMinBodyRunes 个字(纯音乐、有歌没词的标记都是空正文)时为 nil。
func isrcRetryGrams(lyrics string) map[string]struct{} {
	body := lyricConsensusBody(lyrics)
	if len([]rune(body)) < lyricConsensusMinBodyRunes {
		return nil
	}
	return lyricGram3Set(body)
}

// similarity:补来的这条候选跟前面几轮最像的那条有多像;没法比时 ok 为 false。
func (ref isrcRetryReference) similarity(r scoredLyricCandidateResult) (best float64, ok bool) {
	if len(ref) == 0 {
		return 0, false
	}
	g := isrcRetryGrams(r.Lyrics)
	if g == nil {
		return 0, false
	}
	for _, x := range ref {
		best = max(best, gramJaccard(g, x))
	}
	return best, true
}

// filter:正文跟前面几轮哪条都对不上的候选挑进 dropped,其余按原顺序留在 kept。
func (ref isrcRetryReference) filter(extra []scoredLyricCandidateResult) (kept, dropped []scoredLyricCandidateResult) {
	for _, r := range extra {
		if s, ok := ref.similarity(r); ok && s < lyricConsensusSimThreshold {
			dropped = append(dropped, r)
			continue
		}
		kept = append(kept, r)
	}
	return kept, dropped
}
