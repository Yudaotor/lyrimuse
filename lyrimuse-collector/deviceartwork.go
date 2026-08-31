// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"image"
	"math"
	"os"
	"path/filepath"
)

// 2026-08-31 加:media-control 能直接给出正在播放这首歌的封面(playing app 自己经
// MediaRemote 上送的,浏览器网页播放器也会给——实测坐实过 Arc 播 Apple Music 网页版时
// media-control 能读到跟这首歌逐字节对应的封面)。这份数据本来就在,只是
// fetchRawMediaControlState 一直传 --no-artwork 把它丢在门外(省几百 KB 的轮询开销)。
//
// 真实bug(Michael Jackson《Workin' Day and Night (Immortal Version)》,专辑《Immortal
// (Deluxe Edition) [Original Motion Picture Soundtrack]》):网易云自己搜到的封面本来是
// 对的(albumScore=100,"Immortal"是本地专辑名的前缀),但这个分数没到 200 那道"精确对版"
// 的门槛,代码因此又去问了一次 QQ 兜底——而 QQ 自己这张专辑的记录本身就挂错了封面(挂成
// 《Michael: Songs From The Motion Picture》那张,25 首曲目全部同一个挂错的封面 URL),
// 代码对 QQ 的答案是无条件采用,于是把本来对的封面换成了错的。这类"专辑名文字对得上、
// 封面图本身对不上"的第三方数据错误,单靠文字匹配分数分不出来(见 enrich.go
// betterEnrichEntry 附近关于 QQ 封面兜底的一系列注释)。
//
// 设备直送的这份不一样:它就是"正在播的这首歌,这一刻,这个 App 自己吐出来的封面",不需要
// 靠任何文字匹配去猜是不是同一张专辑/同一次发行——身份从"什么时候读到的"直接保证,不是
// 靠内容比对出来的。所以按用户要求,只要这份数据本身质量过关,就直接用,不再跟网易云/
// Apple/QQ 三个源的猜测结果比较。

const (
	// deviceArtworkMinEdge:2026-08-31 实测订正过一次——最初拍脑袋定的 200(觉得"真实专辑
	// 封面哪怕最小档位也有几百像素"),结果直接把这个功能真正要修的那个案例挡在外面:
	// Arc/Edge 播 Apple Music 网页版《Immortal》时,MediaSession API 实际上送的封面就是
	// 120x120(Web 端 MediaSession artwork 常见的按需小尺寸档位之一,不是浏览器随便拿了个
	// 图标应付)。收紧到这个地步就是在挡真实数据,不是在挡"通用图标/占位图"那类真正想挡的
	// 东西——那类东西(没有封面时的占位)通常是 1x1 或几像素的透明图,64 这个下限已经能
	// 稳稳把它们挡在外面,同时放行 120x120 这种真实但不大的 Web 封面。
	deviceArtworkMinEdge = 64
	// deviceArtworkMaxAspectSkew:长宽比偏离正方形超过这个比例,就不像是一张封面图。
	// 阈值给得宽松(15%),只挡明显不是封面的情形(截图、长条 banner 之类),不误伤专辑
	// 封面本身就有的小幅不规则(比如带留白边框的图)。
	deviceArtworkMaxAspectSkew = 0.15
)

// deviceArtworkDir 是设备直送封面落盘的目录,main.go 里跟 enrichPath/lyricsDir 同批设置,
// 空串表示这条功能关闭(不落盘就不能生成 file:// URL,退回原有的网易云/Apple/QQ 检索链路)。
var deviceArtworkDir string

// decodeDeviceArtwork 解码 + 核质量,一次做完——deviceArtworkQuality 和取色(color.go 的
// dominantColorFromImage)都要用到解出来的 image.Image,不值得为两处各解一遍。
//
// 质量门槛只核"这看起来像不像一张真的专辑封面"(尺寸/长宽比),核不出"封面内容对不对
// 得上这首歌"——但这份数据是设备自己在播这首歌的当下吐出来的,身份不需要另外验证
// (这正是它比网易云/Apple/QQ 那套要靠文字匹配去猜的机制更可信的地方,见本文件头注)。
func decodeDeviceArtwork(data []byte) (image.Image, bool) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, false
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w < deviceArtworkMinEdge || h < deviceArtworkMinEdge {
		return nil, false
	}
	longer := math.Max(float64(w), float64(h))
	if math.Abs(float64(w-h))/longer > deviceArtworkMaxAspectSkew {
		return nil, false
	}
	return img, true
}

// deviceCoverURLIfFresh 是 resolveEnrichAsync/applyDeviceCoverUpgrade(enrich.go)共用的
// 入口:只在 isNewTrack 时才问 media-control 要封面(理由见 trackEnrichment 参数注释),
// 问到之后依次过质量检查、落盘,任何一步没通过都返回空串——调用方据此照常退回原有的
// 封面检索链路(网易云/Apple/QQ),这不是错误,是"这一刻没能拿到设备封面"的正常结果。
func deviceCoverURLIfFresh(ctx context.Context, isNewTrack bool, bundleID, artist, title string) string {
	if !isNewTrack {
		return ""
	}
	data, mimeType, ok := fetchNowPlayingArtwork(ctx, bundleID, artist, title)
	if !ok {
		return ""
	}
	if _, ok := decodeDeviceArtwork(data); !ok {
		return ""
	}
	url, ok := saveDeviceArtwork(data, mimeType)
	if !ok {
		return ""
	}
	return url
}

// saveDeviceArtwork 把已经过质量检查的封面字节写到本地,返回 Swift 侧能直接加载的
// file:// URL。文件名按内容 sha256 的前 8 字节命名——同一张封面图(哪怕来自不同曲目、
// 不同次播放)只落一份盘,而且天然幂等:同一张图重复保存不会重复写盘(先 Stat 一次)。
func saveDeviceArtwork(data []byte, mimeType string) (string, bool) {
	if deviceArtworkDir == "" {
		return "", false
	}
	ext := ".jpg"
	if mimeType == "image/png" {
		ext = ".png"
	}
	sum := sha256.Sum256(data)
	path := filepath.Join(deviceArtworkDir, hex.EncodeToString(sum[:8])+ext)
	if _, err := os.Stat(path); err == nil {
		return "file://" + path, true
	}
	if err := os.MkdirAll(deviceArtworkDir, 0o755); err != nil {
		return "", false
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", false
	}
	return "file://" + path, true
}
