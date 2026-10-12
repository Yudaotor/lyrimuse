package main

import (
	"math"
	"time"
)

// 另开「~durN」条目(resolveEnrichKeyForDuration)之前的去抖:这一拍的时长跟命中的条目差太多、要另开的那一位还空着时,
// 同一个时长(±1 秒)要连续观察满 durationVariantConfirm 才建。快速切歌时系统快照里的时长会停在上一首(歌名已经换了),
// 一闪而过;没满之前 trackEnrichment 这一拍返回空,轮询把这首挂起、下一拍再问(poller.go 的 pnPending)。时长跟命中的
// 条目对上就清掉记录。只在 enrichMu 临界区内读写。见 09 章决策 192。
const (
	durationVariantConfirm = 4 * time.Second
	// durationVariantMaxGap:两次观察隔得比这久就重新计时。挂起期间轮询一拍一问,远小于它。
	durationVariantMaxGap = 15 * time.Second
	// durationVariantSeenCap:记录条数上限,满了整个清掉。
	durationVariantSeenCap = 256
)

type durationVariantObs struct {
	durationSecs        float64
	firstSeen, lastSeen time.Time
}

var durationVariantSeen = map[string]durationVariantObs{}

// durationVariantSteadyLocked:key 是命中的那一条(还没换成变体)。满了返回 true 并清掉记录。
func durationVariantSteadyLocked(key string, durationSecs float64, now time.Time) bool {
	obs, ok := durationVariantSeen[key]
	if !ok || math.Abs(obs.durationSecs-durationSecs) > 1 || now.Sub(obs.lastSeen) > durationVariantMaxGap {
		if len(durationVariantSeen) >= durationVariantSeenCap {
			durationVariantSeen = map[string]durationVariantObs{}
		}
		durationVariantSeen[key] = durationVariantObs{durationSecs: durationSecs, firstSeen: now, lastSeen: now}
		return false
	}
	obs.lastSeen = now
	durationVariantSeen[key] = obs
	if now.Sub(obs.firstSeen) < durationVariantConfirm {
		return false
	}
	delete(durationVariantSeen, key)
	return true
}

// enrichCreatedThisPlay:正在播的那首首次解析时新建的条目,连同是哪一次播放(换歌那一拍 noteEnrichPlayingKey 存的指针,
// 每换一首一份新的)。开播头一两拍报的时长可能不对(汽水试听换回整首之前),主条目按它建了;同一次播放里时长稳定成另一个值,
// 是这条记录的时长记错了、不是另一段录音:原地改时长,不另开「~durN」(trackEnrichment 时长那段)。只在 enrichMu 临界区内读写。
// 见 09 章决策 234。
var enrichCreatedThisPlay struct {
	key  string
	play *string
}

// noteEnrichCreatedLocked:首次解析开跑时记一笔,只记正在播的那首。别再按 isNewTrack 挑:汽水试听段要先搜,
// 正在播的这首常常是挂起之后那一拍(isNewTrack=false)才起解析。
func noteEnrichCreatedLocked(key string) {
	if !isEnrichPlayingKey(key) {
		return
	}
	enrichCreatedThisPlay.key, enrichCreatedThisPlay.play = key, enrichPlayingKey.Load()
}

// enrichCreatedThisPlayLocked:key 是这一次播放里刚建的(播放还没换过歌)。
func enrichCreatedThisPlayLocked(key string) bool {
	return enrichCreatedThisPlay.key == key && enrichCreatedThisPlay.play != nil &&
		enrichPlayingKey.Load() == enrichCreatedThisPlay.play
}
