// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"math"
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
	case playerKugou:
		return getKugouMusicState(ctx)
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
	appleMusicBundleID   = "com.apple.Music"
	qqMusicBundleID      = "com.tencent.QQMusicMac"
	neteaseMusicBundleID = "com.netease.163music"
	spotifyBundleID      = "com.spotify.client"
	kugouMusicBundleID   = "com.kugou.mac.Music"
)

// expectedPlayerBundleID 是当前选定播放器(features.Player)自己会报告的 bundle id——
// 供 poller.go 的 isTracked() 兜底判断用,见其注释。playerAuto("自动识别")没有唯一
// 固定的目标,不在这里处理——isTracked() 对 playerAuto 走单独一条分支(核对是不是
// isKnownPlayerBundleID 覆盖的五个已知播放器之一),永远不会调用到这个函数,这里的
// switch 因此不需要、也不应该加 playerAuto 这个 case。
func expectedPlayerBundleID() string {
	switch features.Player {
	case playerQQMusic:
		return qqMusicBundleID
	case playerNetease:
		return neteaseMusicBundleID
	case playerSpotify:
		return spotifyBundleID
	case playerKugou:
		return kugouMusicBundleID
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
//
// 2026-08-19 加宽:实测出现了 album **非空**的广告形态漏网 —— 标题「—」的占位广告
// (collector 日志 `now playing:  - —`)artist 为空、album 非空,熬过了 8 秒 pnPending
// 缓冲仍被 announce 成 Last.fm 的 nowplaying(用户截图,「最近记录」出现"—"正在播放行)。
// 补两条只对 Spotify 生效的信号:artist 为空(真实曲目必有歌手)、标题恰为占位符"—"。
// spotifyCurrentTrackIsAd 问 Spotify 本尊拿权威广告判据:AppleScript 的 `spotify url`
// 对广告返回 "spotify:ad:…"、正常曲目返回 "spotify:track:…"。只在换曲时被
// detectAdAtSessionStart 调一次;超时/权限被收回/Spotify 没在跑都静默返回 false,
// 退回 isAdBreak 的字段启发式。
func spotifyCurrentTrackIsAd(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e",
		`tell application "Spotify" to spotify url of current track`).Output()
	if err != nil {
		return false
	}
	return strings.HasPrefix(strings.TrimSpace(string(out)), "spotify:ad")
}

func isAdBreak(bundleID, artist, title, album string) bool {
	if bundleID != spotifyBundleID {
		return false
	}
	return album == "" || artist == "" || title == "—"
}

// isKnownPlayerBundleID 是"自动识别"模式专用的成员判断——playerAuto 下 isTracked()
// 用它替代 expectedPlayerBundleID() 那种"只认一个固定 bundle id"的判断,因为自动识别
// 模式下 p.cur.Bundle 可能是这五个已知播放器里的任意一个。
func isKnownPlayerBundleID(bundleID string) bool {
	switch bundleID {
	case "com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID:
		return true
	default:
		return false
	}
}

// trustedPlaybackNotASong:一条来自**用户信任的未知播放器**的播放,歌手名或专辑名是空的
// —— 判成"这不是一首歌",整条丢掉(既不解析歌词、也不打卡)。
//
// 判据跟 isAdBreak 完全一致(`album == "" || artist == ""`),区别只在作用域:那个只服务
// Spotify 广告(第一行就 `if bundleID != spotifyBundleID { return false }`),这个服务信任
// 列表。信任列表的意义因此从"靠用户选对"变成"选错了也有兜底"。
//
// 2026-08-21 全靠真实样本定的,四份实测:
//   - 酷狗音乐   artist=周杰伦          album=七里香            → 是歌
//   - Apple Music artist=方大同         album=Soulboy/100种生活 → 是歌
//   - Spotify     artist=方大同         album=Soulboy           → 是歌
//   - Arc 放视频  artist=""/频道名      album=**恒为空**        → 不是歌
//
// **album 是这四份样本里唯一 100% 分对的字段**。artist 单独不够:YouTube 会把**频道名**
// 塞进 artist(实测 `Dream in reality` / `VEILLE + JOUR J de la rentrée 2024`,时长 925 秒
// 的法语 vlog),从数据形状上跟"歌手 - 歌名"无法区分;而它的 album 两次都是空的。
// 代价:电台/单曲场景下真音乐 App 若不报专辑名会被误挡 —— 2026-08-21 用户拍板接受这个
// 取舍(宁可漏认,不要把视频写进永久收听历史)。
//
// mediaType 这条路走不通,顺手记下别再试:酷狗压根不报这个字段,Arc 也不报(不是报 Video,
// 是没有这个键),只有 Apple Music 有。
//
// 内置五个播放器不走这条 —— 它们各有既有守卫(Spotify 广告走 isAdBreak),不在范围内。
func trustedPlaybackNotASong(bundleID, artist, album string) bool {
	if isKnownPlayerBundleID(bundleID) {
		return false
	}
	if _, trusted := features.TrustedPlayers[bundleID]; !trusted {
		return false
	}
	return strings.TrimSpace(artist) == "" || strings.TrimSpace(album) == ""
}

// isAcceptedPlayerBundleID 是"自动识别"下真正的成员判断:五个内置播放器,**加上**用户
// 显式信任的未知播放器(features.TrustedPlayers,见那个字段的注释)。
//
// 内置和信任两者同权 —— 一旦用户点过"加入信任列表",这个 App 的播放就跟 QQ 音乐一样
// 参与显示**和**打卡。两者分开成两个函数而不是塞进一个:isKnownPlayerBundleID 回答的是
// "这是这个项目内置支持的播放器吗"(mediaPlayerLabel 那类固定映射要它),这个回答的是
// "这一条播放该不该被采纳"。
func isAcceptedPlayerBundleID(bundleID string) bool {
	if isKnownPlayerBundleID(bundleID) {
		return true
	}
	_, trusted := features.TrustedPlayers[bundleID]
	return trusted
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
		case kugouMusicBundleID:
			return "KuGou Music (macOS)"
		default:
			// 用户信任的未知播放器:用它自己的 App 名(Swift 侧反查后写进共享文件),
			// 反查不到就退回 bundle id —— 总比谎报"Apple Music"好,那会让
			// ListenBrainz 上的来源统计彻底失真。
			if name, trusted := features.TrustedPlayers[bundleID]; trusted {
				if name != "" {
					return name + " (macOS)"
				}
				return bundleID + " (macOS)"
			}
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
	case playerKugou:
		return "KuGou Music (macOS)"
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
	// 锚点时间戳 —— 算"这份 elapsedTime 有多旧"用,见 mediaControlAnchorAge。
	Timestamp    string  `json:"timestamp"`
	PlaybackRate float64 `json:"playbackRate"`
	// TrackNumber:这首歌在专辑里的序号。只给 Apple 目录锚点做自校验用 —— 同一张专辑上
	// 完全同名的兄弟轨(实测 XSCAPE (Deluxe) 上 #1 和 #17 都叫「Love Never Felt So Good」)
	// 靠曲目名和专辑名分不开,序号能。
	TrackNumber int `json:"trackNumber"`
	// UniqueIdentifier:MediaRemote 的 kMRMediaRemoteNowPlayingInfoUniqueIdentifier。
	// 放 Apple Music **目录**曲目时它就是 Apple 的目录曲目 ID,一次 iTunes lookup 就能
	// 换到权威元数据;本地导入的文件放的是任意 64 位持久 ID(可以是负数)。所有消费方
	// 都必须先过 appleCatalogAnchor 的守卫+自校验,别直接信这个数——见 applecatalog.go。
	UniqueIdentifier int64 `json:"uniqueIdentifier"`
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

func getSpotifyState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, spotifyBundleID)
}

func getKugouMusicState(ctx context.Context) (map[string]any, bool) {
	return matchMediaControlState(ctx, kugouMusicBundleID)
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
	case qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID:
		return raw, true
	default:
		// 用户显式信任过的未知播放器跟内置的完全同权(见 features.TrustedPlayers),
		// 但要多过一道"这是不是一首歌"的守卫 —— 见 trustedPlaybackNotASong。
		if _, trusted := features.TrustedPlayers[bundleID]; trusted {
			artist, _ := raw["artist"].(string)
			album, _ := raw["album"].(string)
			if trustedPlaybackNotASong(bundleID, artist, album) {
				return map[string]any{}, true
			}
			return raw, true
		}
		// 空字符串(没有任何 App 在报告 Now Playing)或者别的不相关 App(网页视频/
		// Safari/另一个还没被信任的播放器)——统一按"没有可报告的正在播放"处理。
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
	// 暂停那一支不再无条件用原始 elapsedTime —— 锚点冻结的源(网页播放器)那个值恒为 0,
	// 直接用会让位置在暂停瞬间归零。见 pausedPositionSecs(与 Swift 侧同一套规则)。
	trackKey := raw.Artist + "|" + raw.Title
	elapsed := raw.ElapsedTime
	if raw.Playing {
		elapsed = raw.ElapsedTimeNow
		rememberPlayingPosition(trackKey, elapsed)
	} else {
		age, hasAge := mediaControlAnchorAge(raw.Timestamp, time.Now())
		last, hasLast := rememberedPlayingPosition(trackKey)
		elapsed = pausedPositionSecs(raw.ElapsedTime, age, hasAge, last, hasLast)
	}
	// ⚠️ 不再对 Spotify 做 JXA 直查覆盖(2026-08-18 与 App 侧同批移除,决策注释见
	// lyrimuse MediaControlClient.fetchRawMediaControlSnapshot):三轮修补仍"经常进度
	// 不准",回归与 QQ 音乐/网易云一致的 media-control 外推。两侧必须同批改——只改
	// 一边就是"采集器和悬浮窗各说各话"的老坑。
	// ⚠️ 三个标签必须先洗一遍不可见空白,见 cleanMediaTag —— 这里是本地这条路径唯一的
	// 元数据入口,洗在这里,下游(缓存 key / 导出文件名 / ListenBrainz / 网页中继)全都干净。
	title, artistTag, album := cleanMediaTag(raw.Title), cleanMediaTag(raw.Artist), cleanMediaTag(raw.Album)
	// Apple 目录锚点:拿得到已校验的锚点时,时长用 Apple 目录的权威值,不用这份快照报的。
	//
	// ⚠️ **适用范围比字面看起来窄**(2026-08-22 对抗性复核订正,原注释夸大了):这个覆盖只
	// 作用在 media-control 这份快照上,而 Apple Music 在 `player=auto` 下走的是
	// getAutoDetectedState —— 它拿到 AppleScript 的 state 就 `return state`,把这里改过的
	// raw 整份丢掉;`player` 手动选成 Apple Music 时更是连 fetchRawMediaControlState 都不调。
	// 所以对 Apple Music 而言,这行覆盖只在**AppleScript 那条路不可用**时才真正生效。
	//
	// 这不是位置放错了:要治的"脏快照"(下一首的时长拼进当前曲目)是 **media-control 专属**
	// 的形态,AppleScript 直接问 Music.app 要 duration of current track 不会串;而且
	// AppleScript 给的精度还更高(实测 289.7659912109375 vs 目录 289.766),拿目录值去盖
	// 反而是降精度。覆盖就该待在产生那个 bug 的那份快照上。
	// 锚点的**另一半**(appleCatalogByTrack 索引 → 歌词检索身份)不受影响:它在这个函数里
	// 就写好了,auto 模式下照常建立。
	// 正常情况两者逐位相等(实测 208.293 对 208.293),只有撞上 media-control 的"脏快照"
	// (换曲预载窗口里把**下一首**的时长拼进当前曲目的快照,见 enrich.go 的
	// observeWrongDuration)才会差开——而那正是这个锚点最值钱的时候:锚点的自校验要求
	// 曲目名对得上,所以它给的一定是**当前这首**的时长。校验不过就原样退回快照值,不会更差。
	// 时长是这里唯一被覆盖的字段:标签本身没有"脏"的已知形态,而且换掉它会牵动缓存 key。
	duration := raw.Duration
	if anchor, ok := appleCatalogAnchor(raw.BundleID, raw.UniqueIdentifier, raw.TrackNumber, title, album); ok && anchor.DurationSecs > 0 {
		if math.Abs(anchor.DurationSecs-duration) > appleCatalogDurationLogThreshold {
			log.Printf("apple catalog anchor overrode duration for %q: media-control %.3fs -> catalog %.3fs (track id %d)",
				title, duration, anchor.DurationSecs, raw.UniqueIdentifier)
		}
		duration = anchor.DurationSecs
	}
	return map[string]any{
		"title": title, "artist": artistTag, "album": album,
		"duration": duration, "elapsedTime": elapsed,
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
