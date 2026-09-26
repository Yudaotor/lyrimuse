package main

import (
	"log"
	"sync"
	"time"
)

// 播放器切歌时先撤掉 Now Playing、隔几秒才发下一首(playerDropsSessionBetweenTracks,实测 KKBOX 多数 4~5 秒,
// 专辑开播后第一次切歌有过 19 秒):这几秒里系统焦点落到别的播放器暂停着的旧会话上,或者谁都没有。照直采纳的话,
// 当前曲目会先换成那个暂停的播放器,网页也跟着推一次「暂停:那首歌」,几秒后再换回来。
//
// 判据:上一份快照(在放或暂停都算:暂停着点开一张新专辑,加载那几秒同样会撤)来自会这样撤会话的播放器;这一拍却是
// 别的播放器没在放、什么都没有,或者同一个播放器报
// 「没在放」却换了一首(撤会话那一瞬读到的撕裂快照:身份还是 KKBOX,曲目已经是 Apple Music 那首)→ 这一拍不算数,
// getState 报读取失败,poller 照旧留着当前曲目、位置接着往前推(不走「连着三拍空就清空」那条路,空档比三拍长)。
// 接手的播放器在放就照常切;同一个播放器报同一首暂停也照常。只对标了 dropsSessionBetweenTracks 的播放器生效(位置
// 链路的判据按播放器收窄,见 02 章决策 41)。Swift 侧 PlayerGapHold 同一套判据。
const (
	// playerGapHoldStartWindow:撤会话那一拍离最后一次看到它不超过这么久,才当是切歌空档。collector 5 秒一拍,
	// 「最后一次看到它」最多落后一拍,不能卡得太紧。
	playerGapHoldStartWindow = 8 * time.Second
	// playerGapHoldWindow:从撤会话那一拍起最多保持多久,再久就当它真的不放了。
	playerGapHoldWindow = 25 * time.Second
)

// gapHoldLast 是上一份被采纳的快照。
type gapHoldLast struct {
	bundle string // "" = 没有
	track  string // 歌手 + 歌名
	seenAt time.Time
}

var (
	gapHoldMu    sync.Mutex
	gapHoldPrev  gapHoldLast
	gapHoldSince time.Time // 这一轮保持从哪一拍开始;零值 = 没在保持
)

// shouldHoldPlayerGap:holdSince 为零值时判「这一拍该不该开始保持」,否则判「还该不该接着保持」。lastRunning 只在
// 别的条件都满足时才问(要 fork 一次 pgrep):那个播放器已经退出了就不等。
func shouldHoldPlayerGap(last gapHoldLast, holdSince time.Time, bundle, track string, playing bool,
	lastRunning func() bool, now time.Time) bool {
	if last.bundle == "" || !playerDropsSessionBetweenTracks[last.bundle] || playing {
		return false
	}
	if bundle == last.bundle && track == last.track {
		return false
	}
	var ok bool
	if holdSince.IsZero() {
		age := now.Sub(last.seenAt)
		ok = age >= 0 && age <= playerGapHoldStartWindow
	} else {
		held := now.Sub(holdSince)
		ok = held >= 0 && held <= playerGapHoldWindow
	}
	return ok && lastRunning()
}

func gapHoldTrack(state map[string]any) string {
	artist, _ := state["artist"].(string)
	title, _ := state["title"].(string)
	return artist + "\x00" + title
}

// gapHoldPlayerRunning:这个播放器的进程还在不在;单测换成固定值。
var gapHoldPlayerRunning = playerRunningForBundle

// playerRunningForBundle:这个播放器的进程还在不在;不知道进程名的当它在。
func playerRunningForBundle(bundle string) bool {
	for id, b := range playerBundleIDs {
		if b == bundle {
			if name := playerProcessNames[id]; name != "" {
				return isProcessRunning(name)
			}
		}
	}
	return true
}

// holdAcrossPlayerGap 在 getState 的出口过一次:要保持就报 ok=false(这一拍不算数),否则原样交回并记下这一拍。
func holdAcrossPlayerGap(state map[string]any, now time.Time) (map[string]any, bool) {
	bundle, _ := state["bundleIdentifier"].(string)
	playing, _ := state["playing"].(bool)
	track := gapHoldTrack(state)
	gapHoldMu.Lock()
	defer gapHoldMu.Unlock()
	last := gapHoldPrev
	if shouldHoldPlayerGap(last, gapHoldSince, bundle, track, playing, func() bool { return gapHoldPlayerRunning(last.bundle) }, now) {
		if gapHoldSince.IsZero() {
			gapHoldSince = now
			log.Printf("now playing: %s dropped out between tracks, holding its last track", last.bundle)
		}
		return nil, false
	}
	if !gapHoldSince.IsZero() {
		log.Printf("now playing: gap hold ended after %s (next: %s playing=%v)", now.Sub(gapHoldSince).Round(time.Second), bundle, playing)
		gapHoldSince = time.Time{}
	}
	if bundle != "" {
		gapHoldPrev = gapHoldLast{bundle: bundle, track: track, seenAt: now}
	} else {
		gapHoldPrev = gapHoldLast{}
	}
	return state, true
}
