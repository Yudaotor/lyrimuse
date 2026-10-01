// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"strings"
)

// 播放器身份(哪些 bundle id 算我们认的播放器、显示成什么名字)、广告字段判据、标签清洗等工具。
// 「此刻在放什么」由 App 写的播放状态给出(见 appsource.go),collector 不再自己读播放器的实时状态。

// playerBundleID 把一个具体播放器常量(playerQQMusic 等)映射成它自己会报告的 bundle id。不接受 playerAuto:
// 它没有唯一固定的目标,调用方先排除(见 poller.isTracked)。多选时对 features().Players 的每个成员分别求。
func playerBundleID(player string) string {
	// 表在 players_generated.go(生成自 shared/players.json)。查不到一律退回 Apple Music:
	// 调用方在"选了 auto / 认不出来"时要的就是这个既有兜底,不是空字符串。
	if id, ok := playerBundleIDs[player]; ok {
		return id
	}
	return appleMusicBundleID
}

func isAdBreak(bundleID, artist, title, album string) bool {
	// App 的广告结论与下面的字段判据取或(见 appsource.go)。
	if appReportedAd(bundleID, artist, title, album) {
		return true
	}
	if bundleID != spotifyBundleID {
		return false
	}
	return album == "" || artist == "" || title == "—"
}

// isKnownPlayerBundleID:这是不是内置播放器(players.json 里那几家)。自动识别下 poller.isTracked 经
// isAcceptedPlayerBundleID 用它。
func isKnownPlayerBundleID(bundleID string) bool {
	return builtinPlayerBundleIDs[bundleID]
}

// isAcceptedPlayerBundleID 是"自动识别"下真正的成员判断:内置播放器,**加上**用户显式信任的未知播放器
// (features().TrustedPlayers,见那个字段的注释)。
//
// 内置和信任两者同权 —— 一旦用户点过"加入信任列表",这个 App 的播放就跟 QQ 音乐一样
// 参与显示**和**打卡。两者分开成两个函数而不是塞进一个:isKnownPlayerBundleID 回答的是
// "这是这个项目内置支持的播放器吗"(mediaPlayerLabel 那类固定映射要它),这个回答的是
// "这一条播放该不该被采纳"。
func isAcceptedPlayerBundleID(bundleID string) bool {
	return isKnownPlayerBundleID(bundleID) || isTrustedPlayerBundleID(bundleID)
}

// isTrustedPlayerBundleID 只回答"信任"这一半(不含内置播放器,跟 Swift 侧 TrustedPlayers.isTrusted 对应——
// 两者都要处理 Safari 的媒体代理进程别名,见 mediaProxyOwners 的注释)。具体选中了哪几个播放器(非 auto)
// 时也要认信任列表:「网页播放器」卡的"配对浏览器"一步自动信任 + 配对(SettingsView.trustAndPairBrowser),
// 没勾"自动识别"也不能让这份配对失效。见 poller.isTracked。
func isTrustedPlayerBundleID(bundleID string) bool {
	if _, trusted := features().TrustedPlayers[bundleID]; trusted {
		return true
	}
	// Safari 的媒体进程按它的宿主算,见 mediaProxyOwners。
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		_, trusted := features().TrustedPlayers[owner]
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
// 跟 Swift 侧 LyrimuseCore/Local/TrustedPlayers.swift 的 mediaProxyOwners 是**同一张
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

// mediaPlayerLabel 是 lbMeta()(Mac 本地这条路径)提交给 ListenBrainz 的 media_player 字段:按这条 listen
// 真实的 bundleID(调用方直接传 snapshot.Bundle)如实报告,不看 features().Players。bundleID 的来源是
// **内置播放器之一、或用户显式信任的未知播放器**,default 分支不是死代码。
func mediaPlayerLabel(bundleID string) string {
	// 内置播放器的标签表在 players_generated.go(生成自 shared/players.json)。
	if label, ok := playerScrobbleLabels[bundleID]; ok {
		return label
	}
	// 用户信任的未知播放器:用它自己的 App 名(Swift 侧反查后写进共享文件),
	// 反查不到就退回 bundle id —— 总比谎报"Apple Music"好,那会让
	// ListenBrainz 上的来源统计彻底失真。
	// Safari 的播放报的是媒体代理进程(com.apple.WebKit.GPU),名字要按宿主查,
	// 否则 Safari 播的歌全部落到下面的兜底、被谎报成"Apple Music (macOS)"。
	lookupID := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		lookupID = owner
	}
	if name, trusted := features().TrustedPlayers[lookupID]; trusted {
		if name != "" {
			return name + " (macOS)"
		}
		return lookupID + " (macOS)"
	}
	return defaultScrobbleLabel
}

// cleanMediaTag 洗掉播放器报上来的标签里的不可见空白。
//
// 「歌词管理」里可能出现成对的重复歌,肉眼完全看不出差别 ——
// 因为差的是一个 U+00A0(不换行空格)。媒体标签里带 NBSP 并不罕见(有些发行版的官方元数据
// 就是这么打的),而这个字符会一路原样传下去:
//
//	缓存 key    "方大同|偷笑|爱爱爱"  vs  "方大同|偷笑\u00a0|爱爱爱"   → 两条独立条目
//	导出文件名  "方大同 - 偷笑 - 爱爱爱.lrc"  vs  "方大同 - 偷笑\u00a0 - 爱爱爱.lrc"
//
// 两边各自解析歌词、各自打分、各自导出文件,谁也不知道对方存在。用户看到的就是"同一首歌
// 出现两次"。
//
// 别指望 strings.TrimSpace 兜住:Go 的 unicode.IsSpace 确实认 U+00A0,但 TrimSpace 只
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
	// Fields 按空白切分并丢掉空片段,Join 回去等于"连续空白折成一个 + 去掉首尾"。最后转 NFC:
	// 播放器偶尔报分解形式(见 nfc.go),不转的话同一首歌会算出两个 key。Swift 侧 cleanTag 同一顺序。
	return composeNFC(strings.Join(strings.Fields(s), " "))
}

// fetchNowPlayingArtwork:设备直送封面,取自 App 写的当前封面文件(见 appPlaybackArtwork)。只在换歌后要封面那一刻调
// (deviceCoverURLIfFresh);播放器 / 歌手 / 歌名对不上这首就当没拿到。
func fetchNowPlayingArtwork(ctx context.Context, expectedBundleID, expectedArtist, expectedTitle string) (data []byte, mimeType string, ok bool) {
	return appPlaybackArtwork(expectedBundleID, expectedArtist, expectedTitle)
}
