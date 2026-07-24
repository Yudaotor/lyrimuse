// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// 两条完全独立的读取路径,按 features.Player 选择——跟 lyrimuse 侧
// MediaControlClient.swift 是同一套设计,注释详见那边:
//
//   - Apple Music:AppleScript(JXA)直接问 Music.app 本身要"现在在放什么",不依赖外部
//     `media-control`(需要 brew install 的私有 MediaRemote 框架社区逆向实现)——这个
//     项目本来就已经在用同一份"自动化"权限(appleMusicPosition() 就是这么问 Music.app
//     要精确播放位置的)。
//   - QQ 音乐:QQ音乐.app 没有 AppleScript 支持,只能走系统级 MediaRemote(经内置的
//     `media-control` 二进制读,build.sh 从 Homebrew 拷贝进 app bundle,跟 collector
//     自己一起放在 Contents/Resources/ 下,见 mediaControlBinaryPath)。
//
// 返回值特意拼成跟旧版 `media-control get` 完全相同的 JSON 字段
// (title/artist/album/duration/elapsedTime/playing/playbackRate/bundleIdentifier),
// 下面 extract() 不用跟着改。isMusicApp 这里直接硬编码 true——这份 JSON 本来就只会
// 在真的问到当前选定播放器自己的曲目时才产出,不是系统级 Now Playing 焦点判断。
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

// getState reads the current now-playing state once, dispatching to whichever
// player the user selected (features.Player). It is the authoritative
// fallback: the stream subscription can go silent for play/pause/seek
// notifications (observed on this macOS beta), so the ticker re-reads ground
// truth here to catch state changes the stream missed.
func getState(ctx context.Context) (map[string]any, bool) {
	if features.Player == playerQQMusic {
		return getQQMusicState(ctx)
	}
	return getAppleMusicState(ctx)
}

func getAppleMusicState(ctx context.Context) (map[string]any, bool) {
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

// qqMusicBundleID/mediaControlRawState 见 lyrimuse 侧 MediaControlClient.swift 同名
// 常量/结构体的注释——同一套设计,两边分别用 Swift/Go 实现一遍。
const qqMusicBundleID = "com.tencent.QQMusicMac"

// expectedPlayerBundleID 是当前选定播放器(features.Player)自己会报告的 bundle id——
// 供 poller.go 的 isTracked() 兜底判断用,见其注释。
func expectedPlayerBundleID() string {
	if features.Player == playerQQMusic {
		return qqMusicBundleID
	}
	return "com.apple.Music"
}

// mediaPlayerLabelIPhone 是 iPhone 桥接路径(poller.go 两处 "source"]="iphone" 附近)
// 提交给 ListenBrainz 的 media_player 值——那条桥接只服务 iPhone 上的 Apple Music
// (经 Last.fm/FastScrobbler 转发,见 bridge 相关注释),跟本地 Mac 选的是哪个播放器
// 无关,固定写死,不需要走 mediaPlayerLabel() 那套判断。
const mediaPlayerLabelIPhone = "Apple Music (iOS)"

// mediaPlayerLabel 是 lbMeta()(Mac 本地这条路径)提交给 ListenBrainz 的 media_player
// 字段——2026-07-24 之前这里不管实际来源一律写死"Apple Music (macOS)",QQ 音乐接入
// 后如果继续写死会导致 ListenBrainz 上明明是 QQ 音乐放的歌却显示"通过 Apple Music
// 播放",按当前选定的播放器如实报告。
func mediaPlayerLabel() string {
	if features.Player == playerQQMusic {
		return "QQ Music (macOS)"
	}
	return "Apple Music (macOS)"
}

type mediaControlRawState struct {
	Title          string  `json:"title"`
	Artist         string  `json:"artist"`
	Album          string  `json:"album"`
	BundleID       string  `json:"bundleIdentifier"`
	Duration       float64 `json:"duration"`
	ElapsedTime    float64 `json:"elapsedTime"`
	ElapsedTimeNow float64 `json:"elapsedTimeNow"`
	Playing        bool    `json:"playing"`
	PlaybackRate   float64 `json:"playbackRate"`
}

// getQQMusicState 读内置 media-control 二进制(见 mediaControlBinaryPath)。--now 让
// 工具自己按内部时钟外推出一个不会冻结的 elapsedTimeNow——这里把它当成"elapsedTime"
// 字段填回去,让下游 updatePosition()(poller.go)以为自己拿到的是"每一轮都新鲜"的
// 读数,跟 Apple Music 那条 AppleScript 路径的行为假设完全一致(那条注释里写的"Elapsed
// 不再于稳定播放期间冻结、每一轮轮询都读到当下的实时进度"同样适用于这里),不需要改
// updatePosition() 一行代码。--no-artwork 省掉几百 KB 的 base64 封面数据,这里从不使用。
func getQQMusicState(ctx context.Context) (map[string]any, bool) {
	bin := mediaControlBinaryPath()
	if bin == "" {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "get", "--now", "--no-artwork").Output()
	if err != nil {
		return nil, false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "null" {
		// 没有任何 App 在报告 Now Playing——跟 getAppleMusicState 的"null"分支同一种
		// 语义,交给调用方(poller.go 的 poll())走既有的 nullStreak 渐进清空逻辑。
		return map[string]any{}, true
	}
	var raw mediaControlRawState
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, false
	}
	if raw.BundleID != qqMusicBundleID {
		// 系统当前的 Now Playing 是别的 App(网页视频/Safari 等)在报告,不是 QQ 音乐——
		// 不能把它当成 QQ 音乐的"正在播放",按"没有可报告的正在播放"处理。
		return map[string]any{}, true
	}
	// elapsedTimeNow 只在真的在播放时才可信——实测坐实:一首已经暂停的歌,
	// elapsedTimeNow 仍然会按暂停前最后一次记录的 playbackRate 继续按真实时钟外推
	// (拿到过 1381 秒这种远超歌曲时长本身的荒谬值),因为暂停这件事本身并没有让
	// media-control 内部的外推基准归零。暂停时真正正确的位置就是这个原始 elapsedTime
	// (暂停就是"冻结在这一刻",不需要外推),只有 playing=true 时才用 elapsedTimeNow。
	elapsed := raw.ElapsedTime
	if raw.Playing {
		elapsed = raw.ElapsedTimeNow
	}
	return map[string]any{
		"title": raw.Title, "artist": raw.Artist, "album": raw.Album,
		"duration": raw.Duration, "elapsedTime": elapsed,
		"playing": raw.Playing, "playbackRate": raw.PlaybackRate,
		"isMusicApp": true, "bundleIdentifier": raw.BundleID,
	}, true
}

// mediaControlBinaryPath 找同一个 app bundle 里跟 collector 自己放在一起的
// media-control 可执行文件(build.sh 从 Homebrew 把 bin/+lib/+Frameworks/ 整棵相对
// 路径子树拷进 Contents/Resources/media-control/,详见 build.sh 那段注释——这个工具
// 不是单个独立二进制,可执行文件靠相对路径找同一棵树下的 Perl 适配脚本和
// MediaRemoteAdapter.framework,只拷可执行文件本身会在运行时报 "Can't open perl
// script")。collector 常驻进程知道自己的可执行文件路径(os.Executable),按同目录下
// 的固定子路径找,不需要额外配置。找不到/查不到自己路径都返回空字符串,调用方按
// "这条路径不可用"处理,不 panic。
func mediaControlBinaryPath() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	bin := filepath.Join(filepath.Dir(exe), "media-control", "bin", "media-control")
	if _, err := os.Stat(bin); err != nil {
		log.Printf("media-control binary not found at %s: %v", bin, err)
		return ""
	}
	return bin
}
