package main

import (
	"sync"
	"time"
)

// 「暂停时该报哪个位置」—— 跟 Swift 侧 MediaControlClient.pausedPositionSeconds 是同一套
// 规则,两侧必须同时改。那边的完整推导注释不重复搬,这里只记要点:
//
// "暂停时用原始 elapsedTime" 这条既有规则**只对会刷新锚点的源成立**(QQ/网易云/Apple
// Music:暂停本身是一次事件,它们会带着新时间戳重新发布一次 elapsedTime,那个值就是暂停
// 位置)。锚点冻结的源不成立 —— 2026-08-21 实测 Arc(网页播放器,页面没调
// mediaSession.setPositionState):elapsedTime 恒等于 0、timestamp 恒等于开播那一刻,
// 位置全靠 media-control 按墙钟外推的 elapsedTimeNow。于是一按暂停,位置直接变成 0。
//
// collector 这一侧的后果不是"歌词跳回第一句"(那是 App 侧),而是打卡进度:updatePosition
// 会把位置当成 0,影响 listen 的提交判断。
const (
	// 锚点"陈旧"的门槛:一个轮询周期。会刷新锚点的源报暂停那一刻时间戳必然是新鲜的。
	staleAnchorAfterSecs = 2.0
	// 报告值比"播放中最后一次位置"低这么多以上,才判定它不是暂停位置。
	// 3 秒 > 一个轮询周期,正常暂停时两者只差一拍,不会误判。
	frozenAnchorPauseDropSecs = 3.0
)

// pausedPositionSecs 纯函数,单测直接覆盖。两个条件**同时**成立才认为"报告值不是暂停
// 位置",各挡一种误判:
//   - 锚点陈旧 —— 把会刷新锚点的源整个排除在外,也就保住了"向后 seek 之后暂停"这种
//     合法的大幅回退(那时候时间戳是新鲜的)。
//   - 报告值低得离谱 —— 正常暂停两者只差一拍;差出几十秒只可能是报告值压根不是当前位置。
func pausedPositionSecs(reported float64, anchorAge float64, hasAnchorAge bool,
	lastPlaying float64, hasLastPlaying bool) float64 {
	if !hasLastPlaying {
		return reported
	}
	if !hasAnchorAge || anchorAge <= staleAnchorAfterSecs {
		return reported
	}
	if lastPlaying-reported > frozenAnchorPauseDropSecs {
		return lastPlaying
	}
	return reported
}

// mediaControlAnchorAge 把 media-control 的时间戳换成"这份锚点有多旧"(秒)。
// 解不出来返回 false —— 调用方据此退回原样的 elapsedTime,不猜。
func mediaControlAnchorAge(ts string, now time.Time) (float64, bool) {
	if ts == "" {
		return 0, false
	}
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return 0, false
	}
	return now.Sub(t).Seconds(), true
}

// 「同一首曲目播放期间最后一次算出来的位置」。只服务上面那条暂停规则。按曲目记 ——
// 换歌自动作废,不让上一首的位置漏到下一首头上。
var (
	playingPositionMu    sync.Mutex
	playingPositionTrack string
	playingPositionValue float64
	playingPositionKnown bool
)

func rememberedPlayingPosition(track string) (float64, bool) {
	playingPositionMu.Lock()
	defer playingPositionMu.Unlock()
	if !playingPositionKnown || playingPositionTrack != track {
		return 0, false
	}
	return playingPositionValue, true
}

func rememberPlayingPosition(track string, pos float64) {
	playingPositionMu.Lock()
	playingPositionTrack = track
	playingPositionValue = pos
	playingPositionKnown = true
	playingPositionMu.Unlock()
}
