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
