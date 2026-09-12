// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/base64"
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

// 两条读取路径,按 features.Players(2026-09-01 起可多选)选择——跟 lyrimuse 侧
// MediaControlClient.swift 是同一套设计,注释详见那边:
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
// player(s) the user selected (features.Players, 2026-09-01 起可多选). It is
// the authoritative fallback: the stream subscription can go silent for
// play/pause/seek notifications (observed on this macOS beta), so the ticker
// re-reads ground truth here to catch state changes the stream missed.
//
// 三条路径,按优先级:
//   - 选了「自动识别」(不管还同时勾了别的具体播放器,auto 是超集,行为跟单选年代的
//     playerAuto 完全一样)→ getAutoDetectedState;
//   - 恰好只选了 Apple Music 一个、没有 auto → getAppleMusicOnlyState:主体仍是
//     getAppleMusicState 的 AppleScript 路径(跟单选年代的 playerAppleMusic 一样),
//     再补两个 MediaRemote 独有的键。⚠️ 2026-09-11 之前这里直接 return
//     getAppleMusicState(ctx)、一次 media-control 都不问,于是电台那一整层在这一种
//     配置下完全不生效 —— 理由见 getAppleMusicOnlyState 头注;
//   - 其它情况(单选或多选了 QQ音乐/网易云/Spotify/酷狗中的若干个,同样没有
//     auto)→ getMultiSelectedState,核对 media-control 报的系统级 Now Playing 焦点
//     是不是落在选中的这个子集里,是的话才认(跟 getAutoDetectedState 同一套"系统只有
//     一个焦点"的道理,只是准入名单从"内置五个+信任列表"收窄成"用户这次选中的这几个")。
func getState(ctx context.Context) (map[string]any, bool) {
	if features.Players[playerAuto] {
		return getAutoDetectedState(ctx)
	}
	if len(features.Players) == 1 && features.Players[playerAppleMusic] {
		return getAppleMusicOnlyState(ctx)
	}
	return getMultiSelectedState(ctx)
}

// getAppleMusicOnlyState 是「只勾了 Apple Music、没勾自动识别」这一种配置的读取路径。
//
// 主体仍是 getAppleMusicState 那份 AppleScript state(位置精度更高,实测
// 289.7659912109375 vs 目录 289.766),只额外把 media-control 那两个 **MediaRemote
// 独有**的键补进来 —— 跟 refineAppleMusicState 补的是同两个键、同一条理由,只是方向
// 相反(那边从 raw 出发合 AppleScript,这边从 AppleScript state 出发合 raw),合并动作
// 共用 mergeRadioKeys 一份实现。
//
// 2026-09-11 加。在这之前这条路直接 `return getAppleMusicState(ctx)`,一次
// media-control 都不问,于是:
//   - `radioStationHash` 拿不到 → 电台判据恒假 → radioclock.go 那套单曲口径、
//     radiostationcard.go 那道"别把台名当一首歌写进歌词缓存"的守卫,全都不生效;
//   - `catalogDurationSecs` 拿不到 → 就算判据补上了,snapshot.extract() 也只能把整档
//     节目那个数(实测 3390.122s)当曲长 → App 的进度条分母、口白判据跟着一起废。
//
// 讽刺的是判据本身一处 bundle id 都不认(谁报 radioStationHash 就算谁),**只勾
// Apple Music 反而是唯一不生效的配置**;默认勾着「自动识别」走 getAutoDetectedState,
// 一直是好的。用户 2026-09-11 问「这个模式是不是仅限于 Apple Music」时查出来的。
//
// # 为什么每拍都问,而 Swift 侧是按曲目探一次
//
// 两边要的东西不一样:App 只要判据本身,而"是不是电台"在同一个曲目 key 内不会翻转,
// 所以那边能按 key 缓存、换歌才多一次 fork(见 MediaControlClient
// .radioAwareAppleMusicSnapshot 头注)。这边还要 `catalogDurationSecs` —— 目录锚点是
// **异步**的,一首歌刚换过来那几拍通常还是 0,几秒后才到位(见 radioduration.go 头注);
// 按曲目缓存会把那个 0 钉死一整首歌,正好废掉这个字段唯一的用处。所以这里跟
// getAutoDetectedState 一样每拍问一次,轮询 5 秒一拍,代价与默认配置持平。
func getAppleMusicOnlyState(ctx context.Context) (map[string]any, bool) {
	state, ok := getAppleMusicState(ctx)
	// 读不到(osascript 跑不起来)或者没有可报告的正在播放 —— 两种都照原样交给调用方,
	// 不为了补两个必然用不上的键再 fork 一次子进程。
	if !ok || len(state) == 0 {
		return state, ok
	}
	raw, bundleID, rawOK := fetchRawMediaControlState(ctx)
	if !rawOK || bundleID != appleMusicBundleID {
		// media-control 不可用,或者系统 Now Playing 焦点根本不是 Apple Music(网页视频
		// 之类占着焦点)—— 后一种情况那份 hash 属于**别人**,不能扣到 Music.app 头上,跟
		// matchMediaControlState 那道核对同一条理由。两种都退回改动前的行为:AppleScript
		// 那份原样报上去,电台这一层这一拍不生效。
		return state, true
	}
	mergeRadioKeys(state, raw)
	return state, true
}

// mergeRadioKeys 把 media-control 那份 raw 里**只有 MediaRemote 才有**的两个键补进
// AppleScript 那份 state。refineAppleMusicState(auto / 多选)与 getAppleMusicOnlyState
// (只勾 Apple Music)共用这一份实现 —— 两条路补的是同两个键,各写一份迟早会漏。
//
// 只在 hash 非空(= 确实是电台)时动 state:非电台时 AppleScript 自己的 duration 精度
// 更高(实测 289.7659912109375 vs 目录 289.766),拿目录值去盖反而是降精度。
func mergeRadioKeys(state, raw map[string]any) {
	hash, _ := raw["radioStationHash"].(string)
	if hash == "" {
		return
	}
	state["radioStationHash"] = hash
	// 目录查到的权威曲长:电台上 AppleScript 给的 duration 同样是整档节目(实测
	// 3390.1220703125),只有目录知道这首歌真实多长。0 = 还没查到 / 自校验没过,不带。
	if d, ok := raw["catalogDurationSecs"].(float64); ok && d > 0 {
		state["catalogDurationSecs"] = d
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
	// ⚠️ 三个标签必须先洗一遍不可见空白(2026-08-31 补)。这里是 **Apple Music 这条路径
	// 唯一的元数据入口** —— media-control 那条早就在 fetchRawMediaControlState 里洗了,
	// 而 Apple Music 走 JXA 直接 unmarshal、绕过那里,于是标签里的 NBSP / 零宽字符会
	// **原样进 Last.fm**,在那边建出一个跟正常写法肉眼完全一样、实际却是另一个实体的
	// 条目;而 enrichKey 那边又洗过,缓存 key 与上送值两边口径不一致。
	//
	// 洗 ≠ 改写:这里只把不可见字符规范化(NBSP/全角空格→普通空格、删零宽、连续空白
	// 折成一个),不替换任何可见内容 —— 跟 lbMeta「原样上送」那条原则不冲突,业界
	// (Web Scrobbler 的 removeZeroWidth/trim 等)也普遍这么做。
	for _, k := range []string{"title", "artist", "album"} {
		if v, ok := state[k].(string); ok {
			state[k] = cleanMediaTag(v)
		}
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

// playerBundleID 把一个具体播放器常量(playerQQMusic 等,不接受 playerAuto——它没有
// 唯一固定的目标,调用方必须先排除这个 case,见 isTracked()/getMultiSelectedState 的
// 注释)映射成它自己会报告的 bundle id。2026-09-01 从单选年代的 expectedPlayerBundleID
// (读包级 features.Player)改成纯函数——多选之后"当前选定播放器"不再是唯一一个值,
// 调用方需要对 features.Players 里的每一个成员分别求 bundle id,不能再读一个包级单值。
func playerBundleID(player string) string {
	switch player {
	case playerQQMusic:
		return qqMusicBundleID
	case playerNetease:
		return neteaseMusicBundleID
	case playerSpotify:
		return spotifyBundleID
	case playerKugou:
		return kugouMusicBundleID
	default:
		return appleMusicBundleID
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
// spotifyCurrentTrackURI 问 Spotify 本尊拿当前曲目的 URI:AppleScript 的 `spotify url` 对广告返回
// "spotify:ad:…"、正常曲目返回 "spotify:track:…"(权威广告判据,见 spotifyURIIsAd;2026-09-09 起同一次脚本的
// 返回值也是真曲目 ID 的唯一来源,见 spotifytrack.go)。只在换曲时被 detectAdAtSessionStart 调一次;
// 超时 / 权限被收回 / Spotify 没在跑都返回 ok=false,调用方退回 isAdBreak 的字段启发式。
// 脚本前垫 running 守卫(02 章决策 9):`tell application "Spotify"` 发任何命令都会把没开的 Spotify 拉起来。
func spotifyCurrentTrackURI(ctx context.Context) (uri string, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e",
		`if application "Spotify" is running then tell application "Spotify" to spotify url of current track`).Output()
	if err != nil {
		return "", false
	}
	uri = strings.TrimSpace(string(out))
	return uri, uri != ""
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
// 判据是 isAdBreak 的**前两条**(`album == "" || artist == ""`),⚠️ **不含**它的第三条
// `title == "—"` —— 原注释写的是"完全一致",不对(2026-08-30 核实)。后果:标题是占位
// 破折号、但歌手/专辑都非空的形态,在信任播放器上没有守卫。
// 区别还在作用域:isAdBreak 只服务 Spotify 广告(第一行就
// `if bundleID != spotifyBundleID { return false }`),这个服务信任列表。信任列表的意义
// 因此从"靠用户选对"变成"选错了也有兜底"。
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
	// isTrustedPlayerBundleID 而不是裸查 features.TrustedPlayers[bundleID]:Safari 的
	// 播放报的是媒体代理进程 com.apple.WebKit.GPU,信任表里存的是宿主 com.apple.Safari,
	// 裸查永远落空 → 这道守卫对 Safari 恒不生效(2026-09-02 修,王力宏《你不知道的事》
	// Safari 网页播放案连带查出来的三处同型裸查之一,见 getAutoDetectedState 那处的注释)。
	if !isTrustedPlayerBundleID(bundleID) {
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
	return isKnownPlayerBundleID(bundleID) || isTrustedPlayerBundleID(bundleID)
}

// isTrustedPlayerBundleID 只回答"信任"这一半(不含五个内置播放器,跟 Swift 侧
// TrustedPlayers.isTrusted 对应——两者都要处理 Safari 的媒体代理进程别名,见
// mediaProxyOwners 的注释),从 isAcceptedPlayerBundleID 里抽出来单独用:2026-09-01
// 播放器多选之后,"具体选中了哪几个播放器"(非 auto)那条路径也要认信任列表——最常见的
// 场景是「网页播放器」卡的"配对浏览器"动作(一步自动信任+配对,见
// SettingsView.trustAndPairBrowser),用户没有理由因为没勾"自动识别"就让这份配对失效,
// 那会让"配对了却读不到播放"的断层从"要不要选一个具体播放器"这条线上重新冒出来。
// 见 getMultiSelectedState/poller.isTracked。
func isTrustedPlayerBundleID(bundleID string) bool {
	if _, trusted := features.TrustedPlayers[bundleID]; trusted {
		return true
	}
	// Safari 的媒体进程按它的宿主算,见 mediaProxyOwners。
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		_, trusted := features.TrustedPlayers[owner]
		return trusted
	}
	return false
}

// mediaProxyOwners 是「媒体进程 bundle id → 真正的宿主 App bundle id」。
//
// Safari 播网页音视频时解码/播放跑在独立的 WebKit GPU 进程里,MediaRemote 报"现在谁在放"
// 报的是那个进程(com.apple.WebKit.GPU)而不是 com.apple.Safari。Chromium 系(Arc/Chrome/
// Edge)报的是浏览器自己的 bundle id,所以只有 Safari 需要这层映射。
//
// ⚠️ 跟 Swift 侧 LyrimuseCore/Local/TrustedPlayers.swift 的 mediaProxyOwners 是**同一张
// 表**,两侧必须同时改 —— 跟 isAcceptedPlayerBundleID / TrustedPlayers.isAccepted 这对
// 本来就得同步的道理一样。完整推导(为什么用别名而不是把代理进程写进信任列表、为什么只
// 登记实测见过的)写在 Swift 那边,不在这里重复一遍。
var mediaProxyOwners = map[string]string{
	"com.apple.WebKit.GPU": "com.apple.Safari",
}

// mediaPlayerLabelIPhone 是 iPhone 桥接路径(poller.go 两处 "source"]="iphone" 附近)
// 提交给 ListenBrainz 的 media_player 值——那条桥接只服务 iPhone 上的 Apple Music
// (经 Last.fm/FastScrobbler 转发,见 bridge 相关注释),跟本地 Mac 选的是哪个播放器
// 无关,固定写死,不需要走 mediaPlayerLabel() 那套判断。
const mediaPlayerLabelIPhone = "Apple Music (iOS)"

// mediaPlayerLabel 是 lbMeta()(Mac 本地这条路径)提交给 ListenBrainz 的 media_player
// 字段——2026-07-24 之前这里不管实际来源一律写死"Apple Music (macOS)",QQ 音乐/网易云
// 音乐接入后如果继续写死会导致 ListenBrainz 上明明是别的播放器放的歌却显示"通过
// Apple Music 播放",按这条具体 listen 真实的 bundleID(调用方直接传 snapshot.Bundle)
// 如实报告。
//
// 2026-09-01 起不再区分"自动识别"和"手动选定"两套分支、也不看 features.Players——
// 单选年代那道 features.Player 分支背后的假设是"手动选定时 bundleID 只可能是选中的那
// 一个",多选之后这个假设不成立(bundleID 可能是选中集合里的任意一个),干脆统一按
// bundleID 直接判断,跟自动识别分支原本的逻辑合并成一份、不再重复——两个分支本来就是
// 同一份映射抄了两遍,不是两种不同的语义。bundleID 的来源是**五个内置播放器之一、或
// 用户显式信任的未知播放器**(不是只有内置那几个,default 分支不是死代码)。
func mediaPlayerLabel(bundleID string) string {
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
		// Safari 的播放报的是媒体代理进程(com.apple.WebKit.GPU),名字要按宿主查,
		// 否则 Safari 播的歌全部落到下面的兜底、被谎报成"Apple Music (macOS)"
		// (2026-09-02 修,同日三处同型裸查之一,见 getAutoDetectedState 那处注释)。
		lookupID := bundleID
		if owner, ok := mediaProxyOwners[bundleID]; ok {
			lookupID = owner
		}
		if name, trusted := features.TrustedPlayers[lookupID]; trusted {
			if name != "" {
				return name + " (macOS)"
			}
			return lookupID + " (macOS)"
		}
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
	// RadioStationHash:电台 / 直播流才有(2026-09-10 实测,值形如 "CgkIBRoFwOSKqxkQBA")。
	// 只当"这是不是电台"的判据用,值本身不看。见 radioclock.go 头注。
	RadioStationHash string `json:"radioStationHash"`
	// ArtworkData/ArtworkMimeType:只有 fetchNowPlayingArtwork 那次不带 --no-artwork
	// 的调用才会非空(见其头注,主 poll 路径的 fetchRawMediaControlState 一直带这个
	// 参数,这两个字段在那条路径上恒为空)。base64 编码的封面原始字节。
	ArtworkData     string `json:"artworkData"`
	ArtworkMimeType string `json:"artworkMimeType"`
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
	if bundleID == appleMusicBundleID {
		return refineAppleMusicState(ctx, raw), true
	}
	switch bundleID {
	case qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID:
		return raw, true
	default:
		// 用户显式信任过的未知播放器跟内置的完全同权(见 features.TrustedPlayers),
		// 但要多过一道"这是不是一首歌"的守卫 —— 见 trustedPlaybackNotASong。
		//
		// ⚠️ 必须走 isTrustedPlayerBundleID,不能裸查 features.TrustedPlayers[bundleID]
		// (2026-09-02 修,王力宏《你不知道的事》Safari 网页播放案):Safari 播网页音频时
		// MediaRemote 报的是媒体代理进程 com.apple.WebKit.GPU,信任表里存的是宿主
		// com.apple.Safari,裸查永远落空 → Safari 的播放在这条 auto 路径被整条当成
		// "不相关 App"丢掉。Swift 侧(MediaControlClient)走 TrustedPlayers.isTrusted
		// 做了代理解析、认了这首歌,于是 App 显示曲目并挂出"搜索歌词中…"占位,而 collector
		// 这边认为什么都没在放、永远不会去解析——占位行就永远停在那。Chrome/Arc 报的是
		// 浏览器自己的 bundle id、直接在表里,所以一直正常;只有 Safari 走代理别名,恰好
		// 只有这条路漏了解析。同型裸查同日一起修的还有 trustedPlaybackNotASong 和
		// mediaPlayerLabel(getMultiSelectedState 从新写就用对了,不在其列)。
		if isTrustedPlayerBundleID(bundleID) {
			artist, _ := raw["artist"].(string)
			album, _ := raw["album"].(string)
			title, _ := raw["title"].(string)
			// trustedPlaybackRejected 而不是裸的 trustedPlaybackNotASong:后者只看字段,
			// 会把 YouTube Music 里"没报专辑名"的那些歌挡在门外(它的 album 常常是空的)。前者在"仅因 album 空
			// 被拒"时去问一次页面本身是广告还是歌,读不到就退回原判据。见 ytmusicad.go 头注。
			rejected, patchAlbum := trustedPlaybackRejected(ctx, bundleID, artist, album, title)
			if rejected {
				return map[string]any{}, true
			}
			// YouTube Music 每条队列的**第一首**在 MediaSession 里没有专辑名(YT Music
			// 自己的疏漏,页面上其实有),复核那一趟顺路读回来了就补上 —— 补的是空缺,
			// 上游报了就一个字不动。见 ytmusicAlbumPatch。
			if patchAlbum != "" {
				raw["album"] = patchAlbum
			}
			return raw, true
		}
		// 空字符串(没有任何 App 在报告 Now Playing)或者别的不相关 App(网页视频/
		// 还没被信任的播放器)——统一按"没有可报告的正在播放"处理。
		return map[string]any{}, true
	}
}

// refineAppleMusicState 是 getAutoDetectedState/getMultiSelectedState 共用的尾段
// (2026-09-01 从 getAutoDetectedState 内联的分支抽出来,给多选新增的
// getMultiSelectedState 复用,不重复这段逻辑):bundleID 已经确认是 Apple Music 时,
// 尝试再走一次 getAppleMusicState 的 AppleScript 路径拿更精确的播放位置——跟手动选
// Apple Music 时同等精度;拿不到(没有"自动化"权限/其它原因)就退回 media-control 本身
// 已经读到的这份基础数据,不整个放弃。
func refineAppleMusicState(ctx context.Context, raw map[string]any) map[string]any {
	if state, ok := getAppleMusicState(ctx); ok && len(state) > 0 {
		// ⚠️ AppleScript 那份 state 是**整份顶替**上来的(位置更精确),但它拿不到
		// `radioStationHash` —— 那是 MediaRemote 独有的字段。不带过去的话,Apple Music 放电台时
		// 判据恒为假,radioclock.go 那套单曲口径在"自动识别 / 多选"这个最常见的配置下完全不生效
		// (2026-09-10 当天就是这么漏的:改完发现缓存里照旧写进整档节目的时长)。
		// 只带这两个键,其余一律以 AppleScript 那份为准。合并动作跟
		// getAppleMusicOnlyState(只勾 Apple Music 那条路)共用 mergeRadioKeys 一份实现。
		mergeRadioKeys(state, raw)
		return state
	}
	return raw
}

// getMultiSelectedState 是"显式多选了若干个具体播放器、没有勾自动识别"的读取路径——
// 跟 getAutoDetectedState 同一套"系统级 Now Playing 只有一个焦点,问 media-control 一次
// 就知道是谁"的机制,区别只在准入名单:这里认的是 features.Players 里用户这次选中的
// 那几个,**加上**信任列表(2026-09-01 补,见 isTrustedPlayerBundleID 的注释——最典型
// 场景是「网页播放器」卡配对的浏览器,那个动作跟"选没选自动识别"是两件独立的事,不该
// 因为没勾自动识别就让配对形同虚设)。单选且未配对任何浏览器时,这条路径跟旧版
// matchMediaControlState(expectedBundleID) 行为等价,QQ音乐/网易云/Spotify/酷狗四个旧
// 函数因此继续保留、单独调用时行为不变(给测试/其它调用点用),getState() 本身不再逐个
// case 派发到它们,改成统一走这里。
func getMultiSelectedState(ctx context.Context) (map[string]any, bool) {
	accepted := map[string]bool{}
	for p := range features.Players {
		accepted[playerBundleID(p)] = true
	}
	raw, bundleID, ok := fetchRawMediaControlState(ctx)
	if !ok {
		return nil, false
	}
	if !accepted[bundleID] {
		if !isTrustedPlayerBundleID(bundleID) {
			// 系统当前的 Now Playing 是别的 App(网页视频/Safari/另一个播放器等),既不在
			// 这次选中的子集里、也没被信任过——不能把它当成"正在播放",按"没有可关心的
			// 正在播放"处理。
			return map[string]any{}, true
		}
		// 走信任列表这条路进来的(不是用户在「播放器」卡里选中的具体播放器)要多过一道
		// "这是不是一首歌"的守卫——跟 getAutoDetectedState 的信任分支同一套语义,理由见
		// trustedPlaybackNotASong 的注释(浏览器视频/播客不能被当成一首歌打卡)。
		artist, _ := raw["artist"].(string)
		album, _ := raw["album"].(string)
		title, _ := raw["title"].(string)
		// 同 getAutoDetectedState 那处:走 trustedPlaybackRejected,好让 YouTube Music 里
		// 没报专辑名的那些歌(album 常常是空的)能靠"页面是不是在放广告"这道复核进来。见 ytmusicad.go 头注。
		rejected, patchAlbum := trustedPlaybackRejected(ctx, bundleID, artist, album, title)
		if rejected {
			return map[string]any{}, true
		}
		// 同 getAutoDetectedState 那处:补上 YouTube Music 队列第一首缺的专辑名。
		if patchAlbum != "" {
			raw["album"] = patchAlbum
		}
	}
	if bundleID == appleMusicBundleID {
		return refineAppleMusicState(ctx, raw), true
	}
	return raw, true
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
		// rate 缺失/为 0 时 elapsedTimeNow 不外推(Spotify 暂停后恢复播放的实测形态),要自己
		// 按锚点时间戳补算 —— 见 playingPositionSecs(与 Swift 侧 livePositionSeconds 的
		// rate 缺失分支同一套规则,采集器没有事件流,只能取整秒中点)。
		// 陈旧锚点重发(见 isStaleAnchorRepublish):命中时沿用原锚点的时间戳,并把 rate 按 0 传,
		// 强制走"自己按锚点时间戳外推"那条路 —— elapsedTimeNow 是按假时间戳外推的,不能信。
		now := time.Now()
		anchorTS, republished := resolvePlayingAnchorTS(trackKey, raw.ElapsedTime, raw.Timestamp, raw.Duration, now)
		rate := raw.PlaybackRate
		if republished {
			rate = 0
		}
		elapsed = playingPositionSecs(raw.ElapsedTime, raw.ElapsedTimeNow, rate, anchorTS, now)
		// App 量出的锚点偏置(见 positionbias.go):Spotify 给歌曲晚打 ~2s 的开播锚点,这里的外推
		// 跟 App 一样恒定落后,由 App 问过 Spotify 自己的钟之后写文件告诉我们扣多少。放在
		// rememberPlayingPosition 之前 —— 暂停规则回退到"最后一次播放位置"时拿到的也是扣过的值。
		// 时间戳用 resolvePlayingAnchorTS 解出来的 anchorTS 而不是 raw.Timestamp:陈旧锚点重发
		// (同一个 elapsed 带着新时间戳,见 isStaleAnchorRepublish)时前者仍是这个锚点**最初**发布的
		// 时刻,偏置判"量在这个锚点之后"要对着它;拿重发的新时间戳比会把一份正确的偏置误判成过期。
		if bias, ok := currentPositionBias(raw.Artist, raw.Title, raw.BundleID, raw.ElapsedTime, anchorTS, now); ok {
			elapsed -= bias
		}
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
	// catalogDuration:只在目录锚点**通过自校验**时才非零 —— 也就是"这个时长是权威的、属于当前这首歌"。
	// 电台要靠它:那条路上快照报的是整档节目时长,而目录知道单曲的真实长度(实测 3390.122 → 226.283)。
	// 单独一个键而不是复用 duration:下面 refineAppleMusicState 整份顶替时,只有"权威"这一层信息值得带过去。
	catalogDuration := 0.0
	if anchor, ok := appleCatalogAnchor(raw.BundleID, raw.UniqueIdentifier, raw.TrackNumber, title, album); ok && anchor.DurationSecs > 0 {
		if math.Abs(anchor.DurationSecs-duration) > appleCatalogDurationLogThreshold {
			log.Printf("apple catalog anchor overrode duration for %q: media-control %.3fs -> catalog %.3fs (track id %d)",
				title, duration, anchor.DurationSecs, raw.UniqueIdentifier)
		}
		duration = anchor.DurationSecs
		catalogDuration = anchor.DurationSecs
	}
	return map[string]any{
		"title": title, "artist": artistTag, "album": album,
		"duration": duration, "elapsedTime": elapsed,
		// 原始锚点 elapsedTime 透传(见 snapshot.AnchorElapsed)。
		"anchorElapsedTime": raw.ElapsedTime,
		"playing":           raw.Playing, "playbackRate": raw.PlaybackRate,
		"isMusicApp": true, "bundleIdentifier": raw.BundleID,
		// 电台判据透传(见 radioclock.go)。⚠️ Apple Music 在 auto / 多选下最终走的是
		// refineAppleMusicState 里那份 **AppleScript** state,它没有这个字段 —— 那边会把这里的值
		// 带过去,否则电台判据在最常见的配置下形同虚设(2026-09-10 当天就是这么漏的)。
		"radioStationHash": raw.RadioStationHash,
		// 目录查到的权威曲长(0 = 没查到 / 自校验没过)。电台的时长以它为准,见 extract()。
		"catalogDurationSecs": catalogDuration,
	}, raw.BundleID, true
}

// fetchNowPlayingArtwork 单独发一次**不带** --no-artwork 的 media-control 调用,只在
// poller.go 的 handle() 确认"新曲目开始播放"那一刻才调——不进每轮轮询(pollInterval=5s)
// 的高频路径,换一次歌才问一次,不会把 --no-artwork 省下来的那份 base64 开销原样加回
// 轮询频率(见 fetchRawMediaControlState 头注)。
//
// expectedBundleID/expectedArtist/expectedTitle 三个校验字段防的是:这次调用和触发它的
// 那次轮询之间(哪怕只隔几百毫秒)曲目已经又换了一次——这时候读到的封面其实属于另一首歌,
// 装作没读到比装错更安全(呼应 deviceartwork.go 头注:这份数据可信的前提正是"身份由
// 读取时刻本身保证",一旦时刻对不上,这个前提就不成立了)。
func fetchNowPlayingArtwork(ctx context.Context, expectedBundleID, expectedArtist, expectedTitle string) (data []byte, mimeType string, ok bool) {
	bin := mediaControlBinaryPath()
	if bin == "" {
		return nil, "", false
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "get", "--now").Output()
	if err != nil {
		return nil, "", false
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" || trimmed == "null" {
		return nil, "", false
	}
	var raw mediaControlRawState
	if err := json.Unmarshal(out, &raw); err != nil || raw.ArtworkData == "" {
		return nil, "", false
	}
	if raw.BundleID != expectedBundleID ||
		cleanMediaTag(raw.Artist) != expectedArtist || cleanMediaTag(raw.Title) != expectedTitle {
		return nil, "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(raw.ArtworkData)
	if err != nil || len(decoded) == 0 {
		return nil, "", false
	}
	return decoded, raw.ArtworkMimeType, true
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
