package main

import (
	"context"
	"math"
)

// 网易云非会员试听:会员歌只放一段,系统报的是这一段自己的时间轴 —— 时长 30 秒左右、位置从 0 起。网易云不给这一段在
// 整首里的起点,位置换不回原曲口径;这里只把这一拍的时长换回整首(appPlaybackTickFor):缓存条目按整首认、不另开
// 「~durN」,歌词按整首搜,30 秒的试听也够不着「听满一半」。整首时长先查网易云客户端本地曲库(neteaselocal.go 的
// dbTrack),再看歌词缓存里这一首记下的。见 02 章决策 97。
// neteaseTrialMinSecs / neteaseTrialMaxSecs 跟 App 侧 TornTrackHold.neteaseTrialLength 必须一起改。
const (
	neteaseTrialMinSecs = 29.0
	neteaseTrialMaxSecs = 31.0
	// neteaseTrialMinGap:整首至少比报的长这么多才算试听。
	neteaseTrialMinGap = 15.0
)

// neteaseTrialFull 判这一拍是不是网易云试听,是就给出整首时长。full 只在时长落在试听范围里时才调。纯函数。
func neteaseTrialFull(bundle string, duration float64, full func() float64) (float64, bool) {
	if bundle != neteaseMusicBundleID || duration < neteaseTrialMinSecs || duration > neteaseTrialMaxSecs {
		return 0, false
	}
	f := full()
	if f-duration < neteaseTrialMinGap {
		return 0, false
	}
	return f, true
}

// liveNeteaseTrialFull:appPlaybackJudge.neteaseTrial 的实现,入参是 App 报的原始标签。
func liveNeteaseTrialFull(bundle, title, artist, album string, duration float64) (float64, bool) {
	return neteaseTrialFull(bundle, duration, func() float64 {
		if d := neteaseLocalFullDuration(context.Background(), artist, title, album); d > 0 {
			return d
		}
		return cachedFullDuration(artist, title, album)
	})
}

// neteaseLocalFullDuration:网易云本地曲库里这首歌的整首时长(秒),查不到或认不准返回 0。按「歌手 + 歌名」找,
// 署名有几位就逐位试,挑法见 neteaseLocalPickFullDuration。
func neteaseLocalFullDuration(ctx context.Context, artist, title, album string) float64 {
	names := append([]string{artist}, artistCreditParts(artist)...)
	neteaseLocalMu.Lock()
	refreshNeteaseLocalIndexLocked(ctx)
	var ents []neteaseLocalTrack
	for _, a := range names {
		if key := neteaseLocalKey(a, title); key != "" && len(neteaseLocalIndex[key]) > 0 {
			ents = append([]neteaseLocalTrack(nil), neteaseLocalIndex[key]...)
			break
		}
	}
	neteaseLocalMu.Unlock()
	return neteaseLocalPickFullDuration(ents, album)
}

// neteaseLocalPickFullDuration:同名的几条里有专辑对得上的取那一条;没有就要几条的时长都差不多(3% 以内)才取,否则不猜。
func neteaseLocalPickFullDuration(ents []neteaseLocalTrack, album string) float64 {
	if album != "" {
		for _, e := range ents {
			if e.Duration > 0 && e.Album.Name != "" && normLoose(e.Album.Name) == normLoose(album) {
				return e.Duration / 1000
			}
		}
	}
	lo, hi := math.Inf(1), 0.0
	for _, e := range ents {
		if e.Duration > 0 {
			lo, hi = math.Min(lo, e.Duration), math.Max(hi, e.Duration)
		}
	}
	if hi <= 0 || (hi-lo)/hi > 0.03 {
		return 0
	}
	return hi / 1000
}

// cachedFullDuration:歌词缓存里这一首记下的时长,取条目时长与解析时用的时长里大的那个;没有这一首返回 0。
func cachedFullDuration(artist, title, album string) float64 {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	key := enrichKey(artist, title, album)
	e, ok := enrichCache[key]
	if !ok {
		alt, found := canonicalEnrichKey(key)
		if !found {
			return 0
		}
		e = enrichCache[alt]
	}
	return math.Max(e.DurationSecs, e.ResolvedDurationSecs)
}
