package main

import (
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"time"
)

// snapshot:这一拍认下的「此刻在放什么」。本机播放取自 App 写的播放状态(appStateSnapshot / appPlaybackTickFor),
// iPhone 那一路取自 Last.fm 桥接。
type snapshot struct {
	Title  string
	Artist string
	Album  string
	// AlbumHint:播放器**没报**专辑名时,由 Apple 目录按「署名 + 曲名 + 时长」反查出来的专辑名(albumhint.go
	// appleAlbumHint)。只给**呈现 / 上送**用(见 albumForUpload),**绝不**进 enrich 缓存 key:App 侧
	// EnrichCacheReader 按播放器报的 `artist|title|album` 查歌词,这边 key 若带上它,两边就对不上了。Album 非空时恒为空。
	AlbumHint string
	Bundle    string
	// Duration:曲长。电台换成目录曲长(没有就是 0)、汽水试听段换成整首,见 appPlaybackTickFor。
	Duration float64
	// ReportedDuration:App 报的曲长(汽水试听段已换成整首),目录锚点覆盖之前的那个。署名纠正按它判。
	ReportedDuration float64
	Playing          bool
	Rate             float64
	// Position:AnchorTS 那一刻的播放位置(秒),对外发布的就是它;网页按 Position + (now-AnchorTS)*Rate
	// 只外推到下一次刷新。
	Position float64
	AnchorTS time.Time
	// Radio:电台 / 直播流。Duration 与位置都已是单曲口径。
	Radio bool
	// NotAudio:这一首报的不是"音乐音频"(Apple Music 的 MV、YouTube Music 网页里的 MV,App 报 music_video)。
	// **Duration 不动**:它还是打卡门槛、上送时长、专辑回填和网页进度条的分母;只有交给歌词解析时按"未知"处理,
	// 见 lyricsDurationSecs。
	NotAudio bool
	// SodaPreviewPending:汽水非会员试听、试听段还在后台搜 —— 这一拍的 Duration 还是试听段长度,
	// 拿它解析歌词会另开一个时长变体。poller 在它为真时先不解析(见 sodapreview.go)。
	SodaPreviewPending bool
	// Remote:iPhone 经 Last.fm 桥接来的这一条(转发的完成收听、同步的正在播放)。上送时只查歌词缓存、
	// 不新建条目,见 bridgeenrich.go。
	Remote bool
}

func (s snapshot) key() string {
	if s.Title == "" && s.Artist == "" {
		return ""
	}
	return s.Title + "|" + s.Artist + "|" + s.Album
}

// albumForUpload:对外呈现 / 上送用的专辑名 —— 播放器报了就用它,没报就用 Apple 目录反查的 AlbumHint。
// 只在「呈现 / 上送」的出口用(relay 网页、Last.fm album、LB release_name、本地收听日志);歌词缓存 key
// (trackEnrichment)、广告判定(isAdBreak 按原始标签对 App 的结论)、专辑预取、会话 key 都继续用 Album 本身 ——
// 否则 App 侧按播放器原始标签查歌词会对不上 key,或者一首歌中途回填出专辑就被当成换了歌。
func (s snapshot) albumForUpload() string {
	if s.Album != "" {
		return s.Album
	}
	return s.AlbumHint
}

// lyricsDurationSecs:交给歌词解析(trackEnrichment)的时长。MV 返回 0 = "未知":视频时长含前导与片尾,拿它打分会
// 压低对的歌词、偏向更长的版本(02 章决策 33、49)。其余照报。凡是拿快照去解析歌词的地方都要走它,不要直接传 Duration。
func (s snapshot) lyricsDurationSecs() float64 {
	if s.NotAudio {
		return 0
	}
	return s.Duration
}
