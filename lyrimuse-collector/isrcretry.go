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
// 认可的 Apple Music 候选报的 ISRC 再问它们一次。见 09 章决策 126。
//
// 播放时有 Spotify 给的 ISRC 就用它(playbackISRC,那是正在播的这一条录音),这里只在它为空时补上。

type recordingISRCKey struct{}

// withRecordingISRC 给 ctx 挂上这一轮按 ISRC 直取用的编码。
func withRecordingISRC(ctx context.Context, isrc string) context.Context {
	return context.WithValue(ctx, recordingISRCKey{}, isrc)
}

// lyricSourceISRC:发给 deezer / musixmatch 的 ISRC。播放器给的优先,其次是 ctx 上挂的。
func lyricSourceISRC(ctx context.Context, artist, title, album string) string {
	if code := playbackISRC(artist, title, album); code != "" {
		return code
	}
	code, _ := ctx.Value(recordingISRCKey{}).(string)
	return code
}

// isrcRetryableSources:能按 ISRC 直取的歌词源。
var isrcRetryableSources = []string{"deezer", "musixmatch"}

// isrcRetryPlan:拿哪个 ISRC、去问哪几个源。源:能按 ISRC 直取、启用着、这一轮没给出可用候选、换个身份还
// 值得再问(lyricSourcesWorthAliasRetry 剔掉连不上的、地区受限的)。ISRC:分数最高的那条已被认可(Score >= 0)、
// 带 ISRC、自报时长跟本地对得上的 applemusic 候选。任何一样没有就返回空。
func isrcRetryPlan(ctx context.Context, results []scoredLyricCandidateResult, durationSecs float64) (string, []string) {
	var sources []string
	for _, s := range lyricSourcesWorthAliasRetry(ctx, results) {
		if slices.Contains(isrcRetryableSources, s) {
			sources = append(sources, s)
		}
	}
	if len(sources) == 0 {
		return "", nil
	}
	var picked []scoredLyricCandidateResult
	for _, r := range results {
		if r.Source == "applemusic" && r.ISRC != "" && r.Score >= 0 && sourceDurationFits(durationSecs, r.SourceReportedDurationSecs) {
			picked = append(picked, r)
		}
	}
	if len(picked) == 0 {
		return "", nil
	}
	sort.SliceStable(picked, func(i, j int) bool { return picked[i].Score > picked[j].Score })
	sort.Strings(sources)
	return picked[0].ISRC, sources
}
