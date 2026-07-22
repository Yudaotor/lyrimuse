// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// 直接用 AppleScript(JXA)问 Music.app 本身要"现在在放什么",不依赖外部
// `media-control`(需要 brew install 的私有 MediaRemote 框架社区逆向实现)——这个
// 项目本来就已经在用同一份"自动化"权限(appleMusicPosition() 就是这么问 Music.app
// 要精确播放位置的)。返回值特意拼成跟旧版 `media-control get` 完全相同的 JSON 字段
// (title/artist/album/duration/elapsedTime/playing/playbackRate/bundleIdentifier),
// 下面 extract() 不用跟着改。isMusicApp 这里直接硬编码 true——这份 JSON 本来就只会
// 在真的问到 Music.app 自己的当前曲目时才产出,不是系统级 Now Playing 焦点判断。
const getStateScript = `(() => {
    const Music = Application("Music");
    try {
        if (!Music.running()) return JSON.stringify(null);
    } catch (e) {
        return JSON.stringify(null);
    }
    let state;
    try {
        state = Music.playerState();
    } catch (e) {
        return JSON.stringify(null);
    }
    if (state === "stopped") return JSON.stringify(null);
    let track;
    try {
        track = Music.currentTrack;
        if (!track.exists()) return JSON.stringify(null);
    } catch (e) {
        return JSON.stringify(null);
    }
    try {
        return JSON.stringify({
            title: track.name(),
            artist: track.artist(),
            album: track.album(),
            duration: track.duration(),
            elapsedTime: Music.playerPosition(),
            playing: state === "playing",
            playbackRate: state === "playing" ? 1 : 0,
            isMusicApp: true,
            bundleIdentifier: "com.apple.Music"
        });
    } catch (e) {
        return JSON.stringify(null);
    }
})()`

// getState reads the current now-playing state once via AppleScript. It is
// the authoritative fallback: the stream subscription can go silent for
// play/pause/seek notifications (observed on this macOS beta), so the ticker
// re-reads ground truth here to catch state changes the stream missed.
func getState(ctx context.Context) (map[string]any, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", getStateScript).Output()
	if err != nil {
		// osascript 本身跑不起来(极端情况,比如系统损坏/沙盒限制)——真正的硬失败,
		// 调用方按"这次没读到"跳过整个 if 块处理,不碰 nullStreak。
		return nil, false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "null" {
		// 脚本自己捕获掉了每一种"没有可报告的正在播放"情况(Music.app 没在运行/
		// 已停止/没有曲目在加载),也包括"自动化"权限被拒绝时访问 Music.app 属性抛出的
		// 异常——这几种情况从这层往上完全无法区分,跟旧版 media-control 遇到同类情况
		// 时的行为一致(它也没法区分"真的没在播"和"读取失败")。返回空 map+true,让
		// 调用方(poller.go 的 poll())走既有的 nullStreak 渐进清空逻辑,不要一律当成
		// "这次调用失败,什么都不做"——否则播放停止后 p.cur 会永远卡在最后一次成功
		// 状态,不会被清空。
		return map[string]any{}, true
	}
	var state map[string]any
	if err := json.Unmarshal(out, &state); err != nil {
		return nil, false
	}
	return state, true
}

// appleMusicPosition returns Apple Music.app's authoritative player position
// (seconds) via AppleScript — exact to ~0.1s, vs media-control's elapsed+timestamp
// which drifts ~1-2s. Only valid when Music.app itself is playing (so it's empty
// for other players / the iPhone bridge). Short timeout; ok=false on any failure
// so the caller falls back to media-control tracking.
func appleMusicPosition(ctx context.Context) (float64, bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	const script = `tell application "Music"
	if player state is playing then return (player position as text)
	return "x"
end tell`
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).Output()
	if err != nil {
		return 0, false
	}
	p, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil || p < 0 {
		return 0, false
	}
	return p, true
}
