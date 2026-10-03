package main

import (
	"context"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"strings"
)

// 播放器身份(内置的还是信任的、上报时显示成什么名字)、广告判定、标签清洗等工具。
// 「此刻在放什么」由 App 写的播放状态给出(见 appsource.go),collector 不再自己读播放器的实时状态。

// isAdBreak:这一首是不是广告。只认 App 写进播放状态的结论(见 appsource.go 的 noteAppReportedAd):判定归 App,
// Spotify 原生客户端的字段启发式(album 空 / artist 空 / 标题「—」)也在 App 那边(LocalPlaybackSource.adBreakByFields)。
func isAdBreak(bundleID, artist, title, album string) bool {
	return appReportedAd(bundleID, artist, title, album)
}

// isKnownPlayerBundleID:这是不是内置播放器(players.json 里那几家)。信任播放器的署名纠正
// (trustedlyricartist.go)用它把内置的排除掉。
func isKnownPlayerBundleID(bundleID string) bool {
	return builtinPlayerBundleIDs[bundleID]
}

// isTrustedPlayerBundleID 只回答"信任"这一半(不含内置播放器),跟 Swift 侧 TrustedPlayers.isTrusted 同一套判法:
// 先查本体,再按 mediaProxyOwners(生成自 shared/players.json)换成宿主查。信任播放器的署名纠正用它。
// 这一拍算不算数不在这里判:App 只把它认下的播放器写进播放状态(见 poller.isTracked)。
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
		case '\u200b', '\u200c', '\u200d', '\u2060', '\ufeff': // 零宽字符(含字连接符 U+2060),没有宽度,直接删
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
