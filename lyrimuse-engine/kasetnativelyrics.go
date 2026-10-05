package main

import (
	"context"
	"slices"
)

// Kaset 自家那个歌词源(lyricfind)按 videoId 取「这一版」的词才拿得到同源加权,按名字搜到的拿不到(09 章决策 174)。
// 那条路上线之前、或者 MV 还没配上音轨版本时解析的条目,自家源一直没按 videoId 比过,重试次数也多半早用完了:每轮记下
// 按哪个 videoId 问了自家源,对不上就带着它重搜一次。见 09 章决策 181。

// kasetNativeLyricsVideoID:这一轮按哪个 videoId 问了 Kaset 自家那个源 —— ctx 上的 videoId 换成它的音轨版本(同
// ytmusicVideoLyric)。ctx 上没有 videoId、lyricfind 关着、这一轮被熔断跳过,或这一轮既没连上它(超时、5xx、429)
// 也没拿到它的候选时为空,下次进程再来。按 videoId 取到的那份在进程内有缓存,再问不发请求,所以给出过候选也算问成了。
// 记进 LyricsNativeVideoID。
func kasetNativeLyricsVideoID(ctx context.Context, round *lyricSourceRound, scored []scoredLyricCandidateResult) string {
	id := youTubeMusicVideoIDFrom(ctx)
	if id == "" || !lyricSourceEnabled("lyricfind") || slices.Contains(round.skippedSources(), "lyricfind") {
		return ""
	}
	if !round.reachedSource("lyricfind") && !slices.Contains(lyricSourcesResponded(scored), "lyricfind") {
		return ""
	}
	return kasetAudioVideoIDFor(id)
}

// kasetLyricsRechecked:这次进程里已经为自家源重搜过的条目。那一轮没问成自家源时不记 LyricsNativeVideoID,光靠
// kasetLyricsWorthRecheck 会每拍都再来一遍。只在 enrichMu 里读写。
var kasetLyricsRechecked = map[string]bool{}

// kasetLyricsRecheckOnce:这个条目这次进程里还没为自家源重搜过就记下、返回 true。调用方持有 enrichMu。
func kasetLyricsRecheckOnce(key string) bool {
	if kasetLyricsRechecked[key] {
		return false
	}
	kasetLyricsRechecked[key] = true
	return true
}

// kasetLyricsWorthRecheck:用 Kaset 放的这首(videoID 是它报的,target 是该按哪个 videoId 问自家源:MV 是配对的音轨版本),
// 词不是自家源给的,而最近一轮评估没按 target 问过它 → 值得带着 videoId 重来一次(retryLyricsUpgrade,分数严格更高才换)。
// 不看重试次数:次数用完的存量条目也给这一次,同一个 target 只来一次。MV 还没读到配对的音轨版本时先不来,按 MV 问取不到
// 带时间轴的那份。手改过、校准过、关了自动升级、lyricfind 关着的都不动。纯函数,单测覆盖。
func kasetLyricsWorthRecheck(e enrichEntry, bundleID, videoID, target string, pinned, autoUpgrade, nativeEnabled bool) bool {
	if bundleID != kasetBundleID || videoID == "" || target == "" || !nativeEnabled {
		return false
	}
	if e.Lyrics == "" || e.ManualLyrics || e.Instrumental || pinned || !autoUpgrade || e.LyricsSource == "lyricfind" {
		return false
	}
	if e.YouTubeMusicMV && target == videoID {
		return false
	}
	return e.LyricsNativeVideoID != target
}
