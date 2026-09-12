// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"time"
)

// snapshot is the subset of the media-control state we care about.
type snapshot struct {
	Title  string
	Artist string
	Album  string
	// AlbumHint:播放器**没报**专辑名时,由 Apple 目录按「署名 + 曲名 + 时长」反查出来的专辑名(albumhint.go
	// appleAlbumHint,2026-09-08)。只给**呈现 / 上送**用(见 albumForUpload),**绝不**进 enrich 缓存 key:App 侧
	// EnrichCacheReader 按播放器报的 `artist|title|album` 查歌词,这边 key 若带上它,两边就对不上了。Album 非空时恒为空。
	AlbumHint string
	Bundle    string
	Duration  float64
	Playing   bool
	// media-control's own reading: at McTS the position was Elapsed, advancing at
	// Rate (1 playing, 0 paused). media-control freezes Elapsed/McTS during steady
	// play (only refreshed on events) and McTS drifts stale across sleep/idle, so
	// extrapolating from McTS overcounts non-playback time. We instead track the
	// position ourselves (see updatePosition) and fill Position + AnchorTS below.
	Elapsed float64
	Rate    float64
	McTS    time.Time
	// media-control 原始的锚点 elapsedTime(未经任何派生)。只用来判"这个锚点是不是开播那个"
	// (0 = 开播锚点;>0 = 播放器后来重新发布的锚点:暂停冻结 / 恢复 / 拖动)—— Spotify 自然切歌
	// 偏置只属于开播锚点,见 updatePosition 里清零那一处(2026-09-07)。
	AnchorElapsed float64
	// Collector-tracked live position (seconds) at AnchorTS (= submit time). This
	// is what we publish; the web extrapolates Position + (now-AnchorTS)*Rate over
	// a short, always-fresh window rather than from media-control's stale McTS.
	Position float64
	AnchorTS time.Time
	// Radio:这是电台 / 直播流(判据 = media-control 载荷里的 radioStationHash 非空,2026-09-10)。
	// 为真时 Duration 已在 extract() 里按"未知"处理、Elapsed/AnchorElapsed/McTS 由 applyRadioClock
	// 换成单曲口径 —— 系统那几个值报的都是整档节目,见 radioclock.go 头注。
	Radio bool
}

func (s snapshot) key() string {
	if s.Title == "" && s.Artist == "" {
		return ""
	}
	return s.Title + "|" + s.Artist + "|" + s.Album
}

// albumForUpload:对外呈现 / 上送用的专辑名 —— 播放器报了就用它,没报就用 Apple 目录反查的 AlbumHint。
// ⚠️ 只在「呈现 / 上送」的出口用(relay 网页、Last.fm album、LB release_name、本地收听日志);歌词缓存 key
// (trackEnrichment)、广告判据(isAdBreak 看 Spotify 原生 album 为空)、专辑预取、会话 key 都继续用 Album 本身 ——
// 否则 App 侧按播放器原始标签查歌词会对不上 key,或者一首歌中途回填出专辑就被当成换了歌。
func (s snapshot) albumForUpload() string {
	if s.Album != "" {
		return s.Album
	}
	return s.AlbumHint
}

func extract(state map[string]any) snapshot {
	str := func(k string) string { v, _ := state[k].(string); return v }
	num := func(k string) float64 { v, _ := state[k].(float64); return v }
	playing, _ := state["playing"].(bool)
	mcTS := time.Now()
	if ts := str("timestamp"); ts != "" {
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			mcTS = t
		}
	}
	// 电台:`duration` 报的是**整档节目**(实测 3390.122s = 56 分半),不是当前这首歌。
	// 优先换成 Apple 目录查到的权威曲长(见 system.go 的 catalogDurationSecs,实测把 3390.122 纠成
	// 226.283);目录也不知道就当"未知"(0)。两条路都不能让整档节目那个数留下来:它会被写进歌词缓存的
	// resolved_duration,之后正常播放同一首歌时两者差 94%、超过 durationMismatch 的 12% 阈值,
	// 每次都判成"另一个录音"转去变体键重解析。见 radioclock.go 头注。
	radio := str("radioStationHash") != ""
	duration := num("duration")
	if radio {
		duration = num("catalogDurationSecs")
	}
	return snapshot{
		Title:         str("title"),
		Artist:        str("artist"),
		Album:         str("album"),
		Bundle:        str("bundleIdentifier"),
		Duration:      duration,
		Playing:       playing,
		Elapsed:       num("elapsedTime"),
		Rate:          num("playbackRate"),
		McTS:          mcTS,
		AnchorElapsed: num("anchorElapsedTime"),
		Radio:         radio,
	}
}
