package main

import (
	"context"
	"encoding/json"
	"log"
	"os/exec"
	"sync"
	"time"
)

// 系统级「正在播放」被别的 App 占走时,直接问上一份被接受的那个播放器自己。
//
// MediaRemote 的「正在播放」是单焦点,浏览器里一个 video 元素就能占走;占走之后 media-control
// 报的是占用者,读取路径按"没有可关心的正在播放"处理,3 拍之后清空当前曲目、结束会话 —— 而目标
// 播放器多半还在放,期间播完的歌一首都记不上。App 侧同一件事在 MediaControlClient.snapshotAfterFocusLost,
// 两侧口径一致:
//   - 开关是"上一份被接受的快照来自哪个内置播放器";拿到别的播放器 / 信任的浏览器的快照当场关掉;
//   - 回退问到了就保持(焦点被占多久都兜得住),问不到就关掉,此后不再为它起子进程;
//   - Apple Music / Spotify 先问它自己的 AppleScript,问不到再按 bundle id 直查系统(nowplaying-clients),
//     其余内置播放器只有后一条。
// 回退期间电台判据拿不到(radioStationHash 是 MediaRemote 当选那一份独有的),按普通曲目处理。见 02 章决策 52。

var (
	focusFallbackMu     sync.Mutex
	focusFallbackBundle string // 上一份被接受的快照来自哪个内置播放器;"" = 没有
	focusFallbackActive bool
)

// focusFallbackAppleScript 问 Apple Music / Spotify 自己;别的播放器返回 nil。单测替换它。
var focusFallbackAppleScript = func(ctx context.Context, bundleID string) map[string]any {
	var state map[string]any
	var ok bool
	switch bundleID {
	case appleMusicBundleID:
		state, ok = getAppleMusicState(ctx)
	case spotifyBundleID:
		state, ok = getSpotifyState(ctx)
	}
	if !ok || len(state) == 0 {
		return nil
	}
	return state
}

// focusFallbackProbe 按 bundle id 直查系统;拿不到返回 nil。单测替换它。
var focusFallbackProbe = func(ctx context.Context, bundleID string) map[string]any {
	script, lib := nowPlayingClientsPaths()
	if script == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/perl", script, lib, bundleID).Output()
	if err != nil {
		return nil
	}
	return parseNowPlayingClientState(out, bundleID)
}

// parseNowPlayingClientState 把 nowplaying-clients 那一行 JSON 换成跟 fetchRawMediaControlState 同形的 state。
// 那个 App 没在报时输出 null;标题为空也不算。elapsedTime 已经在加载器里外推到此刻。
func parseNowPlayingClientState(out []byte, bundleID string) map[string]any {
	var p struct {
		Title             string   `json:"title"`
		Artist            string   `json:"artist"`
		Album             string   `json:"album"`
		Duration          float64  `json:"duration"`
		ElapsedTime       *float64 `json:"elapsedTime"`
		AnchorElapsedTime float64  `json:"anchorElapsedTime"`
		Playing           bool     `json:"playing"`
		PlaybackRate      float64  `json:"playbackRate"`
	}
	if err := json.Unmarshal(out, &p); err != nil {
		return nil
	}
	title, artist, album := cleanMediaTag(p.Title), cleanMediaTag(p.Artist), cleanMediaTag(p.Album)
	if title == "" {
		return nil
	}
	// 与 fetchRawMediaControlState 同一道:酷狗 3.3.2 把当前这句歌词发布成 artist。
	if fixed, ok := kugouFixedArtist(bundleID, title, artist, p.Duration); ok {
		artist = fixed
	}
	elapsed := p.AnchorElapsedTime
	if p.ElapsedTime != nil {
		elapsed = *p.ElapsedTime
	}
	return map[string]any{
		"title": title, "artist": artist, "album": album,
		"duration": p.Duration, "elapsedTime": elapsed,
		"anchorElapsedTime": p.AnchorElapsedTime,
		"playing":           p.Playing, "playbackRate": p.PlaybackRate,
		"isMusicApp": true, "bundleIdentifier": bundleID,
	}
}

// noteFocusAccepted:正常路径拿到了被接受的快照,记下它是谁报的(不是内置播放器就关掉开关)。
func noteFocusAccepted(bundleID string) {
	focusFallbackMu.Lock()
	wasActive := focusFallbackActive
	focusFallbackBundle = ""
	if isKnownPlayerBundleID(bundleID) {
		focusFallbackBundle = bundleID
	}
	focusFallbackActive = false
	focusFallbackMu.Unlock()
	if wasActive {
		log.Printf("now playing focus regained; back on media-control")
	}
}

// stateAfterFocusLost:这一拍 media-control 没给出可接受的快照时,问上一份被接受的那个播放器自己。
// selected 非 nil 时还要核一次"用户这次确实勾了它"(多选路径)。ok=false = 没有可回退的 / 回退也问不到。
func stateAfterFocusLost(ctx context.Context, selected map[string]bool) (map[string]any, bool) {
	focusFallbackMu.Lock()
	bundle := focusFallbackBundle
	focusFallbackMu.Unlock()
	if bundle == "" || (selected != nil && !selected[bundle]) {
		return nil, false
	}
	via := "AppleScript"
	state := focusFallbackAppleScript(ctx, bundle)
	if state == nil {
		via = "per-client MediaRemote probe"
		state = focusFallbackProbe(ctx, bundle)
	}
	focusFallbackMu.Lock()
	firstTick := !focusFallbackActive
	if state == nil {
		focusFallbackBundle, focusFallbackActive = "", false
	} else {
		focusFallbackActive = true
	}
	focusFallbackMu.Unlock()
	if state == nil {
		return nil, false
	}
	if firstTick {
		log.Printf("now playing focus lost to another app; falling back to %s for %s", via, bundle)
	}
	return state, true
}
