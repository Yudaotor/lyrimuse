package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// 正在播放的 App 自己经 MediaRemote 上送这首歌的封面(浏览器网页播放器也会给——例如 Arc 播
// Apple Music 网页版时能读到跟这首歌逐字节对应的封面)。App 换歌时把它写进当前封面文件,
// collector 从那里取(见 appPlaybackArtwork)。
//
// 举例(Michael Jackson《Workin' Day and Night (Immortal Version)》,专辑《Immortal
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
// 靠内容比对出来的。所以拿到就直接用,不再跟网易云/Apple/QQ 三个源的猜测结果比较。
//
// 这张图像不像封面(太小、不是方形、播放器的内置占位图)由 App 判,不像的 App 按没有封面发(LyrimuseCore 的
// CoverArtReplacementGate.isUsableDeviceArtwork、KnownPlaceholderArtwork),这里不再判一遍。

// deviceArtworkDir 是设备直送封面落盘的目录,main.go 里跟 enrichPath/lyricsDir() 同批设置,
// 空串表示这条功能关闭(不落盘就不能生成 file:// URL,退回原有的网易云/Apple/QQ 检索链路)。
var deviceArtworkDir string

// deviceCoverURLIfFresh 是 resolveEnrichAsync/applyDeviceCoverUpgrade(enrich.go)共用的
// 入口:只在 isNewTrack 时才去取封面(读 App 写的当前封面文件,理由见 trackEnrichment 参数注释),
// 取到之后落盘,任何一步没成都返回空串——调用方据此照常退回原有的封面检索链路(网易云/Apple/QQ),
// 这不是错误,是"这一刻没能拿到设备封面"的正常结果。
//
// 这里只核自己解不解得开(格式、像素上限,见 decodeCoverImage):取色和清晰度比较都要解码。
func deviceCoverURLIfFresh(ctx context.Context, isNewTrack bool, bundleID, artist, title string) string {
	if !isNewTrack {
		return ""
	}
	data, mimeType, ok := fetchNowPlayingArtwork(ctx, bundleID, artist, title)
	if !ok {
		return ""
	}
	if _, err := decodeCoverImage(data); err != nil {
		return ""
	}
	url, ok := saveDeviceArtwork(data, mimeType)
	if !ok {
		return ""
	}
	return url
}

// saveDeviceArtwork 把设备封面字节写到本地,返回 Swift 侧能直接加载的
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
	// 原子写:「文件已经在就直接复用」,写到一半被杀(collector 一天重启十几次)留下的半截文件之后会一直被当成
	// 这张图,App 显示残图、中继补传把残图按完整的 sha 传上去。
	if err := writeFileAtomic(path, data); err != nil {
		return "", false
	}
	return "file://" + path, true
}
