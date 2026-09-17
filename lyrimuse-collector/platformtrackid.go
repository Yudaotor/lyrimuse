package main

import (
	"strconv"
	"sync"
)

// 「这次播放的这首歌,在 Apple / Spotify 上的曲目 ID 是多少」——给 amll 按 ID 直取歌词用
// 。
//
// # 为什么要有这份提示
//
// amll-ttml-db 除了 ncm / qq 两份索引,还按 **Apple Music 目录 ID** 和 **Spotify 曲目 ID**
// 各组织了一份(`am-lyrics/` 与 `spotify-lyrics/`;实测 2,641 / 2,477 首)。而
// amll 这个源不做搜索、只按 ID 直取(见 amllttml.go 头注),此前它**唯一**的 ID 来源是网易云
// 和 QQ 两个歌词源搜出来的 songID。两个后果:
//
//  1. **它被另外两个源劫持了**。用户在「歌词来源」里把网易云和 QQ 都关掉时,那两个 channel
//     送来两个空串,amll 一个请求都不发、静默空手而归(enrich.go 那处注释自己写了这件事)。
//     库里明明有这首歌、按 Apple ID 一取就到,却因为「另外两个源没开」而拿不到。
//  2. **证据强度被拉低了**。ncm/qq 的 ID 是**搜出来的**,可能搜到同名的另一版录音(amllttml.go
//     头注记过这个坑:Live 版有自己的 songID);而 Apple / Spotify 的 ID 是**系统在播放时
//     直接给的**,就是用户耳朵里那一条录音本身。
//
// 两个 ID 都是**零请求**的顺带品:Apple 的来自 MediaRemote 的
// `kMRMediaRemoteNowPlayingInfoUniqueIdentifier`,Spotify 的来自换曲那一拍本来就要跑的
// 那次 AppleScript(见 spotifytrack.go)。
//
// ⚠️ **Apple 那个 ID 必须先过校验**。`UniqueIdentifier` 只有在放 Apple Music **目录**曲目时
// 才是目录 ID,本地导入的文件放的是任意 64 位持久 ID(可以是负数)。不校验就拿去查,最好的
// 结果是白发一个 404,最坏是撞上某个真实目录 ID、把**别人的歌词**安到这首歌上。所以写入点
// 只有一处:system.go 里 `appleCatalogAnchor` 判定通过之后(那道守卫要求曲目名逐字同名、
// 专辑名对得上、音轨号不冲突,见 applecatalog.go)。
//
// # 为什么自带一把锁,不复用 enrichMu
//
// 读侧在 `fetchScoredLyricCandidatesStreaming` 的 amll goroutine 里,那条路径不持 enrichMu;
// 写侧一个在 system.go(不持)、一个在 noteSpotifyTrackID 里(持)。自带锁之后锁序只可能是
// enrichMu → 这把,不存在反向,不会成环。
type playbackTrackIDs struct {
	appleCatalogID string
	spotifyTrackID string
}

var (
	playbackTrackIDMu    sync.Mutex
	playbackTrackIDHints = map[string]playbackTrackIDs{}
)

// playbackTrackIDHintCap 防无界增长,理由同 spotifyTrackIDHintCap:提示只在这首歌还在播的
// 那几分钟里有用,超了整个清掉,最坏结果是这一首少一条直取路径,下一首自愈。
const playbackTrackIDHintCap = 512

// notePlayingAppleCatalogID 记下「正在播的这首歌是 Apple 目录里的哪一条」。
//
// ⚠️ 调用方必须**已经过 appleCatalogAnchor 校验**,理由见文件头注。trackID <= 0 一律不记:
// 本地导入文件的持久 ID 可以是负数,那不是目录 ID。
func notePlayingAppleCatalogID(artist, title, album string, trackID int64) {
	if title == "" || trackID <= 0 {
		return
	}
	notePlaybackTrackID(enrichKey(artist, title, album), func(v *playbackTrackIDs) {
		v.appleCatalogID = strconv.FormatInt(trackID, 10)
	})
}

// notePlayingSpotifyTrackID 记下「正在播的这首歌的 Spotify 曲目 ID」。由 noteSpotifyTrackID
// 顺带调用——那边本来就在换曲那一拍拿到了这个 ID,不另外跑脚本。
func notePlayingSpotifyTrackID(artist, title, album, id string) {
	if title == "" || id == "" {
		return
	}
	notePlaybackTrackID(enrichKey(artist, title, album), func(v *playbackTrackIDs) {
		v.spotifyTrackID = id
	})
}

// notePlaybackTrackID 是两个写入口的共同尾巴:同值就不写(这两个写入口都可能在同一首歌上
// 被反复调用——system.go 那条是每次 poll 都走的),真变了才动 map。
func notePlaybackTrackID(key string, set func(*playbackTrackIDs)) {
	playbackTrackIDMu.Lock()
	defer playbackTrackIDMu.Unlock()
	cur := playbackTrackIDHints[key]
	next := cur
	set(&next)
	if next == cur {
		return
	}
	if len(playbackTrackIDHints) >= playbackTrackIDHintCap {
		playbackTrackIDHints = map[string]playbackTrackIDs{}
	}
	playbackTrackIDHints[key] = next
}

// playbackTrackIDsFor 读回这首歌的两个 ID。没记过就给两个空串,调用方据此跳过对应的直取。
//
// ⚠️ 别名轮 / 拆分身份轮拿**改写过的**署名或曲名来调用(见 enrich.go 那几轮),那时这里
// 必然落空、退回只用 ncm/qq 的老行为 —— 这是有意的:提示说的是「系统报的这一条录音」,
// 换了身份之后它就不再对应同一条了,宁可不给也不能给错。
func playbackTrackIDsFor(artist, title, album string) (appleCatalogID, spotifyTrackID string) {
	if title == "" {
		return "", ""
	}
	playbackTrackIDMu.Lock()
	defer playbackTrackIDMu.Unlock()
	v := playbackTrackIDHints[enrichKey(artist, title, album)]
	return v.appleCatalogID, v.spotifyTrackID
}
