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

// 两条读取路径,按 features.Player 选择——跟 lyrimuse 侧 MediaControlClient.swift
// 是同一套设计,注释详见那边:
//
//   - Apple Music:AppleScript(JXA)直接问 Music.app 本身要"现在在放什么",不依赖外部
//     `media-control`(需要 brew install 的私有 MediaRemote 框架社区逆向实现)——这个
//     项目本来就已经在用同一份"自动化"权限(appleMusicPosition() 就是这么问 Music.app
//     要精确播放位置的)。
//   - QQ 音乐/网易云音乐:两者的 .app 都没有 AppleScript 支持(用 sdef/PlistBuddy 核实
//     过,都没有 .sdef、也没开 NSAppleScriptEnabled),共用同一条系统级 MediaRemote
//     路径(经内置的 `media-control` 二进制读,build.sh 从 Homebrew 拷贝进 app bundle,
//     跟 collector 自己一起放在 Contents/Resources/ 下,见 mediaControlBinaryPath),
//     只是各自要核对的 bundle id 不同(getMediaControlState 的 expectedBundleID 参数)。
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
	switch features.Player {
	case playerQQMusic:
		return getQQMusicState(ctx)
	case playerNetease:
		return getNeteaseMusicState(ctx)
	case playerSpotify:
		return getSpotifyState(ctx)
	case playerAuto:
		return getAutoDetectedState(ctx)
	default:
		return getAppleMusicState(ctx)
	}
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

// qqMusicBundleID/neteaseMusicBundleID/spotifyBundleID/mediaControlRawState 见
// lyrimuse 侧 MediaControlClient.swift 同名常量/结构体的注释——同一套设计,两边
// 分别用 Swift/Go 实现一遍。
const (
	qqMusicBundleID      = "com.tencent.QQMusicMac"
	neteaseMusicBundleID = "com.netease.163music"
	spotifyBundleID      = "com.spotify.client"
)

// expectedPlayerBundleID 是当前选定播放器(features.Player)自己会报告的 bundle id——
// 供 poller.go 的 isTracked() 兜底判断用,见其注释。playerAuto("自动识别")没有唯一
// 固定的目标,不在这里处理——isTracked() 对 playerAuto 走单独一条分支(核对是不是
// isKnownPlayerBundleID 覆盖的四个已知播放器之一),永远不会调用到这个函数,这里的
// switch 因此不需要、也不应该加 playerAuto 这个 case。
func expectedPlayerBundleID() string {
	switch features.Player {
	case playerQQMusic:
		return qqMusicBundleID
	case playerNetease:
		return neteaseMusicBundleID
	case playerSpotify:
		return spotifyBundleID
	default:
		return "com.apple.Music"
	}
}

// isAdBreak 判断这条播放是不是 Spotify 的插播广告。
//
// 判据是"Spotify + 专辑名为空":media-control 自己的文档确认广告播放时 album 恒为空
// 字符串(系统级 MediaRemote 就是这么报告的,不是我们没读到),见它 README 的
// "Skip Spotify ads" 一节。这个信号原来只用在 enrich.go 里挡住"别拿广告标题去搜歌词",
// 2026-08-14 抽出来复用 —— 用户在网页「最近播放」和 App「最近记录」里看到了
// "Now Streaming on Hulu." / "BLIZZARD® Double Flip Deal BOGO for 99¢" 这种条目:
// 广告没被搜歌词,但**照样当成一次收听上送**给了 ListenBrainz / Last.fm,还写进了本地
// 收听日志,污染听歌历史和统计。
//
// ⚠️ 已知的误伤面:Spotify 上**确实没有专辑名**的内容(播客单集、上传的本地文件)会一并
// 被判成广告、不再上送。取舍是明确的:少记一条播客,好过让广告混进听歌历史 —— 后者是
// scrobble,落进 Last.fm 之后基本删不掉(只能上网页一条条手删)。这个判据不影响
// Apple Music / QQ 音乐 / 网易云:那三家的正常曲目本来就带专辑名。
func isAdBreak(bundleID, album string) bool {
	return bundleID == spotifyBundleID && album == ""
}

// isKnownPlayerBundleID 是"自动识别"模式专用的成员判断——playerAuto 下 isTracked()
// 用它替代 expectedPlayerBundleID() 那种"只认一个固定 bundle id"的判断,因为自动识别
// 模式下 p.cur.Bundle 可能是这四个已知播放器里的任意一个。
func isKnownPlayerBundleID(bundleID string) bool {
	switch bundleID {
	case "com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID:
		return true
	default:
		return false
	}
}

// mediaPlayerLabelIPhone 是 iPhone 桥接路径(poller.go 两处 "source"]="iphone" 附近)
// 提交给 ListenBrainz 的 media_player 值——那条桥接只服务 iPhone 上的 Apple Music
// (经 Last.fm/FastScrobbler 转发,见 bridge 相关注释),跟本地 Mac 选的是哪个播放器
// 无关,固定写死,不需要走 mediaPlayerLabel() 那套判断。
const mediaPlayerLabelIPhone = "Apple Music (iOS)"

// mediaPlayerLabel 是 lbMeta()(Mac 本地这条路径)提交给 ListenBrainz 的 media_player
// 字段——2026-07-24 之前这里不管实际来源一律写死"Apple Music (macOS)",QQ 音乐/网易云
// 音乐接入后如果继续写死会导致 ListenBrainz 上明明是别的播放器放的歌却显示"通过
// Apple Music 播放",按当前选定的播放器如实报告。playerAuto("自动识别")下"当前选定的
// 播放器"这个概念本身没有固定答案,改成按这条具体 listen 的 bundleID(调用方直接传
// snapshot.Bundle,由 getAutoDetectedState 写入,已经是四个已知播放器之一)如实判断,
// 不看 features.Player。
func mediaPlayerLabel(bundleID string) string {
	if features.Player == playerAuto {
		switch bundleID {
		case qqMusicBundleID:
			return "QQ Music (macOS)"
		case neteaseMusicBundleID:
			return "NetEase Cloud Music (macOS)"
		case spotifyBundleID:
			return "Spotify (macOS)"
		default:
			return "Apple Music (macOS)"
		}
	}
	switch features.Player {
	case playerQQMusic:
		return "QQ Music (macOS)"
	case playerNetease:
		return "NetEase Cloud Music (macOS)"
	case playerSpotify:
		return "Spotify (macOS)"
	default:
		return "Apple Music (macOS)"
	}
}

// cleanMediaTag 洗掉播放器报上来的标签里的不可见空白。
//
// 2026-08-14 实测抓到的真实故障:「歌词管理」里出现成对的重复歌,肉眼完全看不出差别 ——
// 因为差的是一个 U+00A0(不换行空格)。媒体标签里带 NBSP 并不罕见(有些发行版的官方元数据
// 就是这么打的),而这个字符会一路原样传下去:
//
//	缓存 key    "方大同|偷笑|爱爱爱"  vs  "方大同|偷笑\u00a0|爱爱爱"   → 两条独立条目
//	导出文件名  "方大同 - 偷笑 - 爱爱爱.lrc"  vs  "方大同 - 偷笑\u00a0 - 爱爱爱.lrc"
//
// 两边各自解析歌词、各自打分、各自导出文件,谁也不知道对方存在。用户看到的就是"同一首歌
// 出现两次"。
//
// ⚠️ 别指望 strings.TrimSpace 兜住:Go 的 unicode.IsSpace 确实认 U+00A0,但 TrimSpace 只
// 削首尾 —— 而 NBSP 一旦落在拼好的文件名中段("… - 偷笑\u00a0 - …"),就削不掉了。必须在
// 拼接**之前**逐个字段洗。
//
// 处理方式:各种不换行/全角空格统一成普通空格,零宽字符直接删,再把连续空白折成一个、
// 去掉首尾。不做大小写折叠 —— 那是 canonicalEnrichKey 的职责,而且标签本身的大小写要
// 原样保留给界面显示。
func cleanMediaTag(s string) string {
	if s == "" {
		return ""
	}
	s = strings.Map(func(r rune) rune {
		switch r {
		case '\u00a0', '\u2007', '\u202f', '\u3000': // 各种不换行空格 / 全角空格
			return ' '
		case '\u200b', '\u200c', '\u200d', '\ufeff': // 零宽字符,没有宽度,直接删
			return -1
		}
		return r
	}, s)
	// Fields 按空白切分并丢掉空片段,Join 回去等于"连续空白折成一个 + 去掉首尾"。
	return strings.Join(strings.Fields(s), " ")
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

// getQQMusicState/getNeteaseMusicState/getSpotifyState 都是 getMediaControlState 的
// 薄封装——QQ 音乐/网易云音乐都没有 AppleScript 支持,Spotify 虽然有但 2026-07-29 实测
// 坐实它同样把播放状态发布进系统级 MediaRemote,三者读取路径完全一样,只是各自要核对
// 的 bundle id 不同,不需要把整个函数体抄三遍。
func getQQMusicState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, qqMusicBundleID)
}

func getNeteaseMusicState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, neteaseMusicBundleID)
}

// spotifyPositionScript 只问 Spotify 一件事:当前播放位置。
//
// 为什么需要它:Spotify 的播放状态是经系统级 MediaRemote 读到的,而 MediaRemote 拿到的
// Spotify 锚点**本身就滞后**。2026-08-14 实测(同一首歌同时在 Apple Music 和 Spotify 放,
// 对着同一份歌词比):media-control 的 elapsedTimeNow 恒定落后 Spotify 自己报的
// player position **1.64 秒**,波动只有 ±0.02 —— 是固定偏移,不是抖动也不是漂移,所以
// 单纯提高轮询频率没有任何用。Apple Music 之所以准,正是因为它走的是 AppleScript 直接
// 问 Music.app 要 playerPosition,没有中间那层锚点。
//
// 只覆盖"位置"这一个字段,曲目identity/播放状态仍旧以 MediaRemote 为准 —— 那一层要负责
// 判断"系统当前的 Now Playing 到底是不是 Spotify",换成 AppleScript 反而做不到。
//
// ⚠️ 必须先 .running() 再碰任何属性:JXA 里 Application('Spotify') 本身不会拉起 App,
// 但只要访问它的属性就会 —— 一个没开 Spotify 的用户会被这段脚本莫名其妙启动一个播放器。
// 写法照抄 getStateScript 里 Music.running() 那道守卫。
const spotifyPositionScript = `(() => {
    const Spotify = Application('Spotify');
    try {
        if (!Spotify.running()) return JSON.stringify(null);
    } catch (e) {
        return JSON.stringify(null);
    }
    try {
        const state = Spotify.playerState();
        if (state !== 'playing' && state !== 'paused') return JSON.stringify(null);
        return JSON.stringify({ position: Spotify.playerPosition() });
    } catch (e) {
        return JSON.stringify(null);
    }
})()`

// spotifyPlayerPosition 读 Spotify 自己报的播放位置(秒)。读不到就返回 false,调用方
// 退回 media-control 的读数 —— 那个虽然慢 1.6 秒,但总比没有强。
func spotifyPlayerPosition(ctx context.Context) (float64, bool) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", spotifyPositionScript).Output()
	if err != nil {
		return 0, false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" || trimmed == "null" {
		return 0, false
	}
	var r struct {
		Position float64 `json:"position"`
	}
	if err := json.Unmarshal([]byte(trimmed), &r); err != nil || r.Position < 0 {
		return 0, false
	}
	return r.Position, true
}

func getSpotifyState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, spotifyBundleID)
}

// matchMediaControlState 核对 media-control 报的 bundle id 是不是 expectedBundleID——
// QQ 音乐/网易云音乐/Spotify 共用这同一份实现,真正调用子进程/解析原始输出的逻辑收在
// fetchRawMediaControlState 里。
func matchMediaControlState(ctx context.Context, expectedBundleID string) (map[string]any, bool) {
	raw, bundleID, ok := fetchRawMediaControlState(ctx)
	if !ok {
		return nil, false
	}
	if bundleID != expectedBundleID {
		// 系统当前的 Now Playing 是别的 App(网页视频/Safari/另一个播放器等)在报告,
		// 不是当前选定的这个——不能把它当成这个播放器的"正在播放",按"没有可报告的
		// 正在播放"处理。
		return map[string]any{}, true
	}
	return raw, true
}

// getAutoDetectedState 是 playerAuto("自动识别")的读取路径——不预先假定是哪个
// 播放器,直接问 media-control 当前系统级 Now Playing 焦点是谁,再核对是不是这四个
// 已知播放器之一(macOS 的 MediaRemote/Control Center 本来就只有一个"当前正在播放"
// 焦点,不需要这里自己猜)。检测到的恰好是 Apple Music 时,额外走一次
// getAppleMusicState 的 AppleScript 路径拿更精确的播放位置——跟手动选 Apple Music
// 时同等精度;拿不到(没有"自动化"权限/其它原因)就退回 media-control 本身已经读到的
// 这份基础数据,不整个放弃,让没单独开自动化权限的用户在自动识别模式下依然至少能看到
// Apple Music 的歌词,只是播放位置精度稍低一点。
func getAutoDetectedState(ctx context.Context) (map[string]any, bool) {
	raw, bundleID, ok := fetchRawMediaControlState(ctx)
	if !ok {
		return nil, false
	}
	if bundleID == "com.apple.Music" {
		if state, ok := getAppleMusicState(ctx); ok && len(state) > 0 {
			return state, true
		}
		return raw, true
	}
	switch bundleID {
	case qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID:
		return raw, true
	default:
		// 空字符串(没有任何 App 在报告 Now Playing)或者别的不相关 App(网页视频/
		// Safari/另一个不受支持的播放器)——统一按"没有可报告的正在播放"处理。
		return map[string]any{}, true
	}
}

// fetchRawMediaControlState 读内置 media-control 二进制(见 mediaControlBinaryPath)。
// --now 让工具自己按内部时钟外推出一个不会冻结的 elapsedTimeNow——这里把它当成
// "elapsedTime"字段填回去,让下游 updatePosition()(poller.go)以为自己拿到的是
// "每一轮都新鲜"的读数,跟 Apple Music 那条 AppleScript 路径的行为假设完全一致(那条
// 注释里写的"Elapsed 不再于稳定播放期间冻结、每一轮轮询都读到当下的实时进度"同样适用
// 于这里),不需要改 updatePosition() 一行代码。--no-artwork 省掉几百 KB 的 base64
// 封面数据,这里从不使用。matchMediaControlState(核对单一 expectedBundleID)和
// getAutoDetectedState(核对"是不是这几个已知播放器之一")共用这份子进程调用逻辑,
// 只是各自拿到 bundleID 之后核对的规则不同。
func fetchRawMediaControlState(ctx context.Context) (map[string]any, string, bool) {
	bin := mediaControlBinaryPath()
	if bin == "" {
		return nil, "", false
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "get", "--now", "--no-artwork").Output()
	if err != nil {
		return nil, "", false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "null" {
		// 没有任何 App 在报告 Now Playing——跟 getAppleMusicState 的"null"分支同一种
		// 语义,交给调用方(poller.go 的 poll())走既有的 nullStreak 渐进清空逻辑。
		return map[string]any{}, "", true
	}
	var raw mediaControlRawState
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, "", false
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
	// Spotify 的位置改问它自己 —— MediaRemote 那份恒定慢 1.64 秒,见 spotifyPositionScript
	// 上的实测记录。读不到就沿用上面算好的 elapsed,不比现状差。
	//
	// 只在 bundle 确实是 Spotify 时才多跑这一次 osascript:别的播放器不该为此付代价,
	// 而 Apple Music 本来就走 AppleScript,压根不经过这个函数。
	if raw.BundleID == spotifyBundleID {
		if pos, ok := spotifyPlayerPosition(ctx); ok {
			elapsed = pos
		}
	}
	return map[string]any{
		// ⚠️ 三个标签必须先洗一遍不可见空白,见 cleanMediaTag —— 这里是本地这条路径唯一的
		// 元数据入口,洗在这里,下游(缓存 key / 导出文件名 / ListenBrainz / 网页中继)全都干净。
		"title": cleanMediaTag(raw.Title), "artist": cleanMediaTag(raw.Artist), "album": cleanMediaTag(raw.Album),
		"duration": raw.Duration, "elapsedTime": elapsed,
		"playing": raw.Playing, "playbackRate": raw.PlaybackRate,
		"isMusicApp": true, "bundleIdentifier": raw.BundleID,
	}, raw.BundleID, true
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
