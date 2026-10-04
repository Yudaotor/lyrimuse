package main

import (
	"math"
	"regexp"
	"strconv"
	"strings"
)

// Apple 的 TTML 时间轴按立体声母带打。同一首歌的空间音频(杜比全景声)混音跟它对不齐时,TTML 头部会带
// `<audio lyricOffset="1.672" role="spatial"/>`:放空间音频版时,歌词整体要晚这么多秒(负数 = 早)。
// 引擎不知道 Music.app 此刻放的是哪一版,所以只把偏移连同立体声版的时长写进正文的标签行
// `[am-spatial:<偏移毫秒>/<立体声时长毫秒>]`,由 App 按实际在放的时长决定用不用
// (LocalPlaybackSource.spatialAudioOffsetMs)。见 09 章决策 149。
//
// 标签写在正文里而不是另开字段:它属于这一份歌词,换歌词时跟着正文一起没了,各条复制正文的路径也不用改。
// 标签行没有时间戳,两侧的 LRC / YRC 解析都把它当元信息跳过。

var (
	amAudioTagRe      = regexp.MustCompile(`<audio\b[^>]*>`)
	amAudioRoleRe     = regexp.MustCompile(`\brole="([^"]*)"`)
	amAudioLyricOffRe = regexp.MustCompile(`\blyricOffset="([^"]*)"`)
	spatialAudioTagRe = regexp.MustCompile(`(?m)^\[am-spatial:[^\]]*\]\s*\n?`)
)

// applemusicSpatialMaxOffsetSecs:超过这个量的偏移不认(读错 / 畸形数据)。口径同 App 侧 LRCParser.maxOffsetMs。
const applemusicSpatialMaxOffsetSecs = 10.0

// applemusicSpatialLyricOffset 取 TTML 里 role="spatial" 那个 <audio> 的 lyricOffset(秒)。没有、解析不出、
// 为 0 或超出 applemusicSpatialMaxOffsetSecs 都返回 0。纯函数。
func applemusicSpatialLyricOffset(ttml string) float64 {
	for _, tag := range amAudioTagRe.FindAllString(ttml, -1) {
		role := amAudioRoleRe.FindStringSubmatch(tag)
		if role == nil || role[1] != "spatial" {
			continue
		}
		off := amAudioLyricOffRe.FindStringSubmatch(tag)
		if off == nil {
			continue
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(off[1]), 64)
		if err != nil || math.IsNaN(v) || math.Abs(v) > applemusicSpatialMaxOffsetSecs {
			continue
		}
		return v
	}
	return 0
}

// withSpatialAudioTag 在正文最前面加一行空间音频标签。正文为空、偏移为 0(四舍五入到毫秒后)、立体声时长
// 未知时原样返回;正文里已经有这行标签时先去掉旧的,不叠两行。纯函数。
func withSpatialAudioTag(body string, offsetSecs, stereoSecs float64) string {
	offMs := int(math.Round(offsetSecs * 1000))
	stereoMs := int(math.Round(stereoSecs * 1000))
	if strings.TrimSpace(body) == "" || offMs == 0 || stereoMs <= 0 {
		return body
	}
	body = strings.TrimLeft(spatialAudioTagRe.ReplaceAllString(body, ""), "\n")
	return formatSpatialAudioTag(offMs, stereoMs) + "\n" + body
}

func formatSpatialAudioTag(offMs, stereoMs int) string {
	return "[am-spatial:" + strconv.Itoa(offMs) + "/" + strconv.Itoa(stereoMs) + "]"
}
