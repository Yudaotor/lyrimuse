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
	// appleAlbumHint)。只给**呈现 / 上送**用(见 albumForUpload),**绝不**进 enrich 缓存 key:App 侧
	// EnrichCacheReader 按播放器报的 `artist|title|album` 查歌词,这边 key 若带上它,两边就对不上了。Album 非空时恒为空。
	AlbumHint string
	Bundle    string
	Duration  float64
	// ReportedDuration:系统原样报的时长。电台时 Duration 换成了目录曲长,这里留原值给 radioPerTrackSeed 判单曲量级。
	ReportedDuration float64
	Playing          bool
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
	// 偏置只属于开播锚点,见 updatePosition 里清零那一处。
	AnchorElapsed float64
	// Collector-tracked live position (seconds) at AnchorTS (= submit time). This
	// is what we publish; the web extrapolates Position + (now-AnchorTS)*Rate over
	// a short, always-fresh window rather than from media-control's stale McTS.
	Position float64
	AnchorTS time.Time
	// Radio:这是电台 / 直播流(判据 = media-control 载荷里的 radioStationHash 非空)。
	// 为真时 Duration 已在 extract() 里按"未知"处理、Elapsed/AnchorElapsed/McTS 由 applyRadioClock
	// 换成单曲口径 —— 系统那几个值报的都是整档节目,见 radioclock.go 头注。
	Radio bool
	// NotAudio:这个载荷报的不是"音乐音频"——最常见的是 Apple Music 的 MV(判据见
	// notAudioMedia)。为真时 Duration 已在 extract() 里按"未知"(0)处理:视频时长里
	// 带着歌外内容(前导对白、尾字幕),它不是这首歌的长度。
	NotAudio bool
	// PositionFromPlayerClock:Elapsed 是**播放器自己的钟**(AppleScript `player position`),
	// 不是 MediaRemote 锚点外推出来的,AnchorElapsed 恒 0、没有"锚点重发"可看。
	// Spotify 这个钟每次起播都整首领先真声一截:Elapsed 在 getSpotifyState 里已经扣掉了 App 按起播方式给的
	// 那一段(currentPlayerClockBias),所以 updatePosition 的自然切歌偏置 / repeat-one 回绕重估对它**跳过**
	// (再估一遍就是扣两次,而且交界处声音不连续、连续性本来就估不准)。
	// Apple Music 那份(getAppleMusicState)也置上:poll() 据此直接用这一拍的读数校准位置,不再另问一次。
	// AppleScript 不可达退回 media-control 那份原始快照时为假,按 AnchorElapsed 那条规则走。
	PositionFromPlayerClock bool
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
// (trackEnrichment)、广告判据(isAdBreak 看 Spotify 原生 album 为空)、专辑预取、会话 key 都继续用 Album 本身 ——
// 否则 App 侧按播放器原始标签查歌词会对不上 key,或者一首歌中途回填出专辑就被当成换了歌。
func (s snapshot) albumForUpload() string {
	if s.Album != "" {
		return s.Album
	}
	return s.AlbumHint
}

// mediaTypeMusic 是 MediaRemote 对"音乐音频"的分类。在本机实拉 media-control
// 载荷确认:Apple Music 放普通曲目时 `mediaType` 就是这个值。
const mediaTypeMusic = "MRMediaRemoteMediaTypeMusic"

// notAudioMedia:这个载荷报的不是"音乐音频"。最常见的是 Apple Music 的 MV ——
// 现象:「MV 有额外内容,导致和实际歌词对不上」。
//
// # 为什么要认出它
//
// 视频时长 = 歌 + 前导对白 + 尾字幕,拿它当曲长会同时打坏三处(都在时长这一条证据上):
// match.go 的时长档(吻合加分缩水,差得多时吃 durationMismatchPenalty)、紧跟着的
// "源自报曲长"那一项(源报的是**歌**的长度,于是再叠一次扣分——那处注释说的"相互印证"
// 在这里恰好反了,两次扣分是同一个原因)、以及 enrich.go 的 durationMismatch 12% 闸门
// (MV 和音频版之间每切一次就触发一整轮十源重搜)。实测陶喆《In the Morning》歌曲
// 212.1s,MV 只要多 30s 就跨过 12% 那道线。
//
// 认出来之后 extract() 把 Duration 置 0 = "未知",三处伤害一起消失:打分整段挂在
// `durationSecs > 0` 下,durationMismatch 任一方为 0 也不触发。**一个已知错误的证据
// 比没有证据更糟**,这跟 durationMismatch 自己"任一方为 0 不触发"是同一个立场。
//
// # 判据只看 mediaKind
//
// `mediaKind` 是 Music.app 自己对这条目的分类,由 AppleScript/JXA 那条路读(getStateScript)。
// 走**白名单**,因为取值域是完整的:`sdef /System/Applications/Music.app` 里枚举 `eMdK` =
// song / music video / movie / TV show / unknown。`unknown` 刻意**按音频处理** ——
// 本地导入的文件报什么还没实测,宁可保持现状也不要误伤一整类曲目。
//
// 覆盖面:Apple Music 的两条读取路径最终用的都是这份 JXA state —— auto / 多选走
// refineAppleMusicState(拿 AppleScript 那份整份顶替 raw),只勾 Apple Music 走
// getAppleMusicOnlyState。JXA 读不到时(没有"自动化"权限)退回 raw、这条判据不生效,
// 是降级不是错误:行为跟改动前逐字相同。
//
// # MediaRemote 的 mediaType 认不出 MV,别再试
//
// 实测(用户当场放了陶喆《In the Morning》的 MV):media-control 载荷里
// `mediaType` 仍是 `MRMediaRemoteMediaTypeMusic`,**跟放普通曲目时逐字相同** ——
// MediaRemote 这一层根本不区分 MV。 别拿它做反判("不是 Music 就不信这个时长") ——
// 对这个场景永远不会触发。
//
// 而且反判对**别的播放器**是净风险:Safari 放 YouTube Music 本来就是个视频站,它要是报
// Video,一整个播放器的时长打分会被静默关掉,收益为零。所以这个字段只留观测
// (noteUnfamiliarMediaType),不做判据。
func notAudioMedia(state map[string]any) bool {
	switch mk, _ := state["mediaKind"].(string); mk {
	case "music video", "movie", "TV show":
		return true
	}
	return false
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
	// MV / 视频:时长里带着歌外内容,当"未知"比当曲长诚实。理由与三处受害点见 notAudioMedia。
	// 跟电台那条不同,这里**不**退回 Apple 目录 —— 实测目录根本不给 MV 时长:
	// 按 MV 的 trackId 反查 lookup 返回 kind=music-video、wrapperType=track、trackTimeMillis 缺失。
	// 想改查"歌曲"那一条来拿真实曲长也不保险(entity=song 在有的 storefront 上整个返回空)。
	notAudio := notAudioMedia(state)
	duration := num("duration")
	switch {
	case radio:
		duration = num("catalogDurationSecs")
	case notAudio:
		duration = 0
	}
	return snapshot{
		Title:            str("title"),
		Artist:           str("artist"),
		Album:            str("album"),
		Bundle:           str("bundleIdentifier"),
		Duration:         duration,
		ReportedDuration: num("duration"),
		Playing:          playing,
		Elapsed:          num("elapsedTime"),
		Rate:             num("playbackRate"),
		McTS:             mcTS,
		AnchorElapsed:    num("anchorElapsedTime"),
		Radio:            radio,
		NotAudio:         notAudio,
		PositionFromPlayerClock: func() bool {
			v, _ := state["positionFromPlayerClock"].(bool)
			return v
		}(),
		SodaPreviewPending: func() bool {
			v, _ := state["sodaPreviewPending"].(bool)
			return v
		}(),
	}
}
