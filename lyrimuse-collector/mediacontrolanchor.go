package main

import (
	"log"
	"math"
	"strings"
	"sync"
	"time"
)

// 「暂停时该报哪个位置」—— 跟 Swift 侧 MediaControlClient.pausedPositionSeconds 是同一套
// 规则,两侧必须同时改。那边的完整推导注释不重复搬,这里只记要点:
//
// "暂停时用原始 elapsedTime" 这条既有规则**只对会刷新锚点的源成立**(QQ/网易云/Apple
// Music:暂停本身是一次事件,它们会带着新时间戳重新发布一次 elapsedTime,那个值就是暂停
// 位置)。锚点冻结的源不成立 —— 实测 Arc(网页播放器,页面没调
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

// rateOnlyPlayingOverrunSecs:按锚点外推超过曲长多少还当它在播。循环每一遍都会重发锚点,
// 超出曲长还没新锚点就是停了。与 Swift 侧 MediaControlClient.rateOnlyPlayingOverrunSecs 一致。
const rateOnlyPlayingOverrunSecs = 2.0

// effectivePlaying 判这一份读数算不算在播。与 Swift 侧 MediaControlClient.effectivePlaying 同一套规则。
//
// 酷狗单曲循环回到开头时发一份新锚点 elapsed=0,playing 却是 false、playbackRate 仍是 1,之后整遍
// 都不再翻回 true;真暂停时 rate 归 0。只对 playerPlayingFromRate 的播放器按 rate 判,
// 数据见 02 章「酷狗单曲循环报暂停」。
func effectivePlaying(raw mediaControlRawState, now time.Time) bool {
	if raw.Playing || !playerPlayingFromRate[raw.BundleID] || raw.PlaybackRate <= 0 || raw.Duration <= 0 {
		return raw.Playing
	}
	age, ok := mediaControlAnchorAge(raw.Timestamp, now)
	if !ok {
		return false
	}
	position := raw.ElapsedTime + math.Max(0, age)*raw.PlaybackRate
	return position <= raw.Duration+rateOnlyPlayingOverrunSecs
}

// mediaControlAnchorInstant 把 media-control 的锚点时间戳换成锚点时刻。
//
// 带 --micros 时时间戳是精确值(applyMicros 写成固定 6 位小数),原样用。旧的整秒格式
// 恒无小数秒 = floor(真实时刻),取 ts+0.5(中点,误差 ±0.5s)。两种格式靠有没有小数部分
// 区分;精确值再补半秒会凭空偏快,所以这道判断不能省。
func mediaControlAnchorInstant(ts string) (time.Time, bool) {
	if ts == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return time.Time{}, false
	}
	if !strings.Contains(ts, ".") {
		t = t.Add(500 * time.Millisecond)
	}
	return t, true
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

// 「播放中该报哪个位置」—— 跟 Swift 侧 MediaControlClient.livePositionSeconds 的 rate 分支是
// 同一套规则,两侧必须同时改。
//
// rate 正常(>0)用 media-control 自己外推的 elapsedTimeNow:它内部用的是全精度锚点时刻,
// 实测对 Spotify 准到毫秒级(换歌后首拍读数 0.33~0.37s,正好是通知+去抖的延迟)。
// rate 缺失/为 0 时 elapsedTimeNow **不再外推**(实测:Spotify 暂停后恢复播放
// playbackRate 变 null;复测 elapsedTimeNow 2 分 14 秒纹丝不动),只能自己按
// elapsedTime + (now − 锚点时刻) 补算。而 timestamp 恒无小数,直接拿它当锚点时刻会恒偏快
// frac ∈ [0,1)(实测 .914/.724/.560),暂停一下就退回去,还把下一首自然切歌的偏置估计带歪。
// 锚点时刻取 mediaControlAnchorInstant:带 --micros 的精确时间戳原样用;旧的整秒格式按 Swift 侧
// estimatedAnchorInstant 的退化形态取 ts+0.5,误差 ±0.5s(采集器没有事件流、5s 轮询首见必然
// 晚于 1s)。
func playingPositionSecs(elapsedTime, elapsedTimeNow, rate float64, ts string, now time.Time) float64 {
	if rate > 0 {
		return elapsedTimeNow
	}
	if ts == "" {
		return elapsedTimeNow
	}
	anchorAt, ok := mediaControlAnchorInstant(ts)
	if !ok {
		return elapsedTimeNow
	}
	aged := now.Sub(anchorAt).Seconds()
	if aged <= 0 {
		return elapsedTime
	}
	return elapsedTime + aged
}

// ---- Spotify 陈旧锚点重发—— 跟 Swift 侧 MediaControlClient.isStaleAnchorRepublish
// 同一套判据,两侧必须同时改。完整实测记录见那边的注释与 docs/features/02。要点:
// Spotify 会在播放中把 now-playing 信息重发一遍,elapsedTime **逐 ms 不变**、时间戳却换成
// 当下(实测 10.477@:09 → 10.477@:43),MediaRemote/media-control 据此外推的位置一下退回
// 几十秒。签名 = 同一首歌 + elapsed 相等 + 时间戳变了 + 按旧锚点外推还没越过曲长
// (越过曲长的旧锚点已死)。elapsed==0 的重发跟「上一曲」重头播放签名相同,**只对
// playerRepublishesZeroAnchor 里的播放器**判,且要离原锚点 zeroAnchorRepublishWindowSecs 之内
// (两簇的实测分布见 Swift 侧那段注释)。 那张名单不能外扩:连发里哪一个是真起播点各家相反
// (汽水音乐/网易云是第一个,Apple Music 是最后一个),判反 = 整首歌恒定偏移、只有暂停才纠得回来。
// 命中时沿用**原**锚点的时间戳自己外推,不信 elapsedTimeNow。
type playingAnchor struct {
	track   string
	elapsed float64
	ts      string
	at      time.Time // 订正后的锚点时刻,见 mediaControlAnchorInstant
}

var (
	playingAnchorMu        sync.Mutex
	lastPlayingAnchor      *playingAnchor
	lastIgnoredRepublishTS string
)

// elapsed == 0 的重发离原锚点多久之内还算"重发"。跟 Swift 侧 zeroAnchorRepublishWindowSecs 同值。
const zeroAnchorRepublishWindowSecs = 5.0

// bundleID 只用于 elapsed == 0 那条分支的准入;elapsed > 0 的签名是通用的 MediaRemote 行为,
// 不分播放器。
func isStaleAnchorRepublish(last *playingAnchor, track string, elapsed float64, ts string, duration float64, bundleID string, now time.Time) bool {
	if last == nil || ts == "" || last.track != track || last.elapsed != elapsed || last.ts == ts {
		return false
	}
	if elapsed <= 0 {
		if !playerRepublishesZeroAnchor[bundleID] {
			return false
		}
		if republishGapSeconds(last, ts, now) > zeroAnchorRepublishWindowSecs {
			return false
		}
	}
	if duration > 0 && last.elapsed+now.Sub(last.at).Seconds() > duration+1 {
		return false
	}
	return true
}

// republishGapSeconds 这次重发离**原**锚点多久:两个时间戳都解得出就按它们算,解不出退回墙钟。
func republishGapSeconds(last *playingAnchor, ts string, now time.Time) float64 {
	newTS, errNew := time.Parse(time.RFC3339, ts)
	oldTS, errOld := time.Parse(time.RFC3339, last.ts)
	if errNew == nil && errOld == nil {
		return newTS.Sub(oldTS).Seconds()
	}
	return now.Sub(last.at).Seconds()
}

// resolvePlayingAnchorTS 记住"上一个播放锚点",返回这次该用的锚点时间戳:陈旧重发 → 原锚点的
// 时间戳(第二个返回值 true,调用方据此强制自己外推);否则记下这次并原样返回。
func resolvePlayingAnchorTS(track string, elapsed float64, ts string, duration float64, bundleID string, now time.Time) (string, bool) {
	playingAnchorMu.Lock()
	defer playingAnchorMu.Unlock()
	if isStaleAnchorRepublish(lastPlayingAnchor, track, elapsed, ts, duration, bundleID, now) {
		if lastIgnoredRepublishTS != ts {
			lastIgnoredRepublishTS = ts
			log.Printf("stale anchor republish ignored: elapsed=%.3f newTs=%s keepingAnchorTs=%s track=%q", elapsed, ts, lastPlayingAnchor.ts, track)
		}
		return lastPlayingAnchor.ts, true
	}
	at := now
	if t, ok := mediaControlAnchorInstant(ts); ok {
		at = t
	}
	lastPlayingAnchor = &playingAnchor{track: track, elapsed: elapsed, ts: ts, at: at}
	lastIgnoredRepublishTS = ""
	return ts, false
}
