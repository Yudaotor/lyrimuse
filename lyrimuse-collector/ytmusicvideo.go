package main

import (
	"context"
	"log"
	"regexp"
	"strings"
	"sync"
	"time"
)

// YouTube Music 网页里正在放的是不是 MV —— 是的话打上 stateKeyYTMusicVideo,notAudioMedia 据此认成 MV,
// 这一拍的时长就不交给歌词解析(snapshot.lyricsDurationSecs)。浏览器没有 Music.app 那个 mediaKind,
// 改问页面:`#movie_player.getPlayerResponse().videoDetails.musicVideoType`。
//
// 两条约束:
//   - 别改 snapshot.Duration。它还是打卡门槛、上送时长、专辑回填和网页进度条的分母,置 0 会让
//     listenThreshold 退到 240 秒(3 分半的 MV 永远记不上收听)、专辑回填整条失效。
//   - 别并进 ytmusicAdProbeJS。那段 JS 跟 App 侧是同一份、selftest 逐字比对,而 MV 类型只有 collector 用。
//
// 平台的「歌曲版 ↔ 视频版」配对与分段映射 Web 端不下发,拿不到歌曲版时长,见 02 章决策 33 / 49。

// ytmusicVideoTypeJS 只读当前视频的 musicVideoType。纪律同 ytmusicAdProbeJS:不许双引号、不写反斜杠。
// 读不到播放器或接口返回 NOTFOUND,读到了但没有这个字段返回 NONE。
const ytmusicVideoTypeJS = `(function(){` +
	`var p = document.querySelector('#movie_player');` +
	`if (!p || !p.getPlayerResponse) return 'NOTFOUND';` +
	`var pr = null;` +
	`try { pr = p.getPlayerResponse(); } catch (e) { return 'NOTFOUND'; }` +
	`var vt = pr && pr.videoDetails && pr.videoDetails.musicVideoType;` +
	`return vt ? String(vt) : 'NONE';` +
	`})()`

var ytmusicVideoTypeShape = regexp.MustCompile(`^MUSIC_VIDEO_TYPE_[A-Z_]+$`)

// parseYTMusicVideoType 解 ytmusicVideoTypeJS 的输出。形状不对(NOTFOUND / NONE / 空 / 别的文本)一律空串。
func parseYTMusicVideoType(raw string) string {
	s := unwrapBrowserScriptOutput(raw)
	if !ytmusicVideoTypeShape.MatchString(s) {
		return ""
	}
	return s
}

// ytmusicIsMusicVideoType:这个类型的时长算不算"视频的长度"而不是"歌的长度"。
// 白名单:OMV = 官方 MV,UGC = 用户上传(现场、翻唱、带画面的搬运,时长同样不是录音室版的)。
// ATV(歌曲版)、空串(读不到)和其余类型一律按歌处理 —— 认不准时保持现状,不误伤。
func ytmusicIsMusicVideoType(vt string) bool {
	switch vt {
	case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC":
		return true
	}
	return false
}

// ytmusicVideoTypeScript 真正去浏览器里跑那段 JS。单测换成假的:测试进程绝不能去驱动本机真实的浏览器
// (TestMain 默认就把它换成"读不到")。
var ytmusicVideoTypeScript = func(ctx context.Context, bundleID, family string) (string, bool) {
	return runBrowserTabScript(ctx, bundleID, family, ytmusicHostMarker, ytmusicVideoTypeJS)
}

var (
	ytmusicVideoMu   sync.Mutex
	ytmusicVideoKey  string
	ytmusicVideoType string
	ytmusicVideoAt   time.Time
)

// ytmusicMusicVideo 回答"此刻这个浏览器里的 YouTube Music 放的是不是 MV"。trackKey 同 ytmusicAdProbe。
// 读不到时返回 false(按歌处理,时长照常交给打分,跟没有这条判据时一样),而且不进缓存,下一轮重试。
func ytmusicMusicVideo(ctx context.Context, bundleID, trackKey string) bool {
	target := bundleID
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		target = owner
	}
	family := browserScriptFamily(target)
	if family == "" {
		return false
	}
	cacheKey := target + "\x00" + trackKey
	ytmusicVideoMu.Lock()
	if ytmusicVideoKey == cacheKey && time.Since(ytmusicVideoAt) < ytmusicAdMaxAge {
		vt := ytmusicVideoType
		ytmusicVideoMu.Unlock()
		return ytmusicIsMusicVideoType(vt)
	}
	ytmusicVideoMu.Unlock()

	out, ok := ytmusicVideoTypeScript(ctx, target, family)
	if !ok {
		return false
	}
	vt := parseYTMusicVideoType(out)
	if vt == "" {
		return false
	}
	ytmusicVideoMu.Lock()
	isNewTrack := ytmusicVideoKey != cacheKey
	ytmusicVideoKey, ytmusicVideoType, ytmusicVideoAt = cacheKey, vt, time.Now()
	ytmusicVideoMu.Unlock()
	isMV := ytmusicIsMusicVideoType(vt)
	if isMV && isNewTrack {
		log.Printf("ytmusic: music video (%s), duration not used for lyrics scoring (%s)",
			strings.TrimPrefix(vt, "MUSIC_VIDEO_TYPE_"), strings.ReplaceAll(trackKey, "\x00", " - "))
	}
	return isMV
}
