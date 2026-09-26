package main

import "math"

// MV 的歌词要是当初按 **MV 自己的时长**选的,就按「时长未知」重选一次。
//
// 正在播的 MV 交给歌词解析的时长是 0(snapshot.lyricsDurationSecs),但同一首歌的条目可能早就在别处按视频时长
// 解析过了 —— 最常见的是网页播放队列的待播预取:那时它还没开播、认不出是 MV,队列里报的视频时长直接进了打分,
// 时长项把长度相近的另一个版本(混音 / 加长版)抬上去、把歌曲原版判成负分。条目一旦落盘,播放时缓存命中,
// 换不回来(见 02 章决策 49 追加)。
//
// 判据:poller 每拍把正在播的 MV 的视频时长记成提示;条目的 ResolvedDurationSecs(这份歌词是按多少秒选的)
// 跟它差不到 musicVideoDurationMatchSecs,就说明这份歌词是冲着视频长度选的。重选走 retryLyricsUpgrade
// (时长传 0),基准分的换算见 lyricsBaselineForUnknownDuration。

const (
	musicVideoDurationHintCap = 256
	// 条目记的时长与视频时长在这之内就算「按视频时长选的」。队列报整秒、MediaSession 报小数,
	// 实测同一支 MV 283 vs 282.181。
	musicVideoDurationMatchSecs = 2.0
)

var musicVideoDurationHints = map[string]float64{}

// noteMusicVideoDuration 记下正在播的 MV 的视频时长(秒)。key 与 enrichKey 同一套归一化。
func noteMusicVideoDuration(artist, title, album string, videoSecs float64) {
	if videoSecs <= 0 {
		return
	}
	key := enrichKey(artist, title, album)
	if key == "" {
		return
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if len(musicVideoDurationHints) >= musicVideoDurationHintCap {
		musicVideoDurationHints = map[string]float64{}
	}
	musicVideoDurationHints[key] = videoSecs
}

// lyricsChosenByVideoDuration:这条条目的歌词是不是按正在播的这支 MV 的视频时长选出来的。纯函数。
func lyricsChosenByVideoDuration(e enrichEntry, videoSecs float64) bool {
	if e.Lyrics == "" || e.ResolvedDurationSecs <= 0 || videoSecs <= 0 {
		return false
	}
	return math.Abs(e.ResolvedDurationSecs-videoSecs) <= musicVideoDurationMatchSecs
}

// musicVideoLyricsStaleLocked:trackEnrichment 命中缓存时问一句。**调用方必须持有 enrichMu**。
func musicVideoLyricsStaleLocked(key string, e enrichEntry) bool {
	return lyricsChosenByVideoDuration(e, musicVideoDurationHints[key])
}

// lyricsBaselineForUnknownDuration:这一轮按「时长未知」打分、而现存那份的分数是带着时长那一项算出来的,
// 两个分数不可比(时长吻合一项就值几百分,按未知重打谁都够不着旧分)。换成现存那份**在这一轮里**的分;
// 这一轮它的源应答了、却没再给出同一份正文(按未知时长它不再是候选),基准就是 0;它的源这一轮没应答,
// 不下结论(同 rescoreDecidable:一次偶发超时不该把人换到更差的一份)。
func lyricsBaselineForUnknownDuration(e enrichEntry, scored []scoredLyricCandidateResult) (baseline int, comparable bool) {
	for i := range scored {
		if scored[i].Source == e.LyricsSource && scored[i].Lyrics == e.Lyrics {
			return scored[i].Score, true
		}
	}
	for _, s := range lyricSourcesResponded(scored) {
		if s == e.LyricsSource {
			return 0, true
		}
	}
	return 0, false
}
