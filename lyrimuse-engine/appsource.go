package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"math"
	"os"
	"sync"
	"time"
)

// 引擎认「此刻在放什么」只读 App 写的播放状态(契约见 appstate.go),自己不读播放器、不推算位置,
// 也不为此向播放器发 AppleEvent。身份、播放暂停、位置以 App 为准。App 状态不可用(退出中、进程不在、15 秒没写、
// 契约版本不认识)时待机:当读空处理,连着几拍按停播清掉当前曲目(nullStreakMeansStopped),可用了自动接上。
//
// 仍由引擎做的判定照旧跑,输入是状态里的字段(appPlaybackJudge):
//   - 署名纠正:App 报的原始标签照样逐拍喂给 kugouFixedArtist / trustedFixedTrack;引擎发布的纠正比 App
//     套用的新(applied_fix_rev 落后)时,身份用引擎这一拍的结论,其余时候用 App 的。
//   - 汽水试听段:照样查、照样发布;已经查到而 App 报的仍是试听段长度时,本地先换回整首口径。
//   - 网易云试听:时长换回整首;网易云不给试听段的起点,位置照旧(见 neteasetrial.go)。
//   - Apple 目录锚点:按 App 带来的目录曲目 ID 核对并记下目录 ID;电台的曲长只认目录(没有就是 0),
//     其余曲目有权威曲长就覆盖。
//   - 广告:只认 App 的结论(isAdBreak 只看 appReportedAd);Spotify 曲目 ID 用 App 带来的那个。
// 起播与重新对齐看序号,只在同一个 App 进程里比:play_seq 增加且身份不变 = 重新起播(单曲循环);
// anchor_seq 变了、或换了 App 进程 = 位置重新对齐,立即重推网页进度。

// appStateCheckInterval:快速通道的兜底,多久看一次状态文件(一次 stat,变了才读)。平时 App 一写就由目录监听
// 叫醒(dirwatch.go)。
const appStateCheckInterval = time.Second

// appStateMinGap:目录监听叫醒的两轮之间至少隔这么久。连续拖进度时 App 会接连写好几次,中间的变化由每秒那一拍兜住。
const appStateMinGap = 250 * time.Millisecond

// appPlaybackJudge:读 App 状态时仍由引擎做的判定。单测替换。
type appPlaybackJudge struct {
	// fixedTrack:署名纠正,入参是原始标签与时长;ok=false = 不必改。
	fixedTrack func(bundle, title, artist, album string, duration float64) (fixedArtist, fixedTitle string, ok bool)
	// fixRev:引擎最近一次发布的署名纠正版本。
	fixRev func() int64
	// sodaPreview:汽水试听段。known=true 时给出起点与整首时长;pending = 还在后台查。
	sodaPreview func(bundle, title, artist, album string, duration float64) (startSecs, fullSecs float64, known, pending bool)
	// neteaseTrial:网易云试听,是的话给出整首时长(见 neteasetrial.go)。
	neteaseTrial func(bundle, title, artist, album string, duration float64) (fullSecs float64, ok bool)
	// catalog:Apple 目录锚点,核对通过时 ok=true;durationSecs 可能为 0(目录不报时长)。
	catalog func(bundle string, trackID int64, trackNumber int, artist, title, album string) (durationSecs float64, ok bool)
}

var liveAppPlaybackJudge = appPlaybackJudge{
	fixedTrack:   liveAppFixedTrack,
	fixRev:       currentPlayerArtistFixRev,
	sodaPreview:  liveAppSodaPreview,
	neteaseTrial: liveNeteaseTrialFull,
	catalog:      liveAppCatalog,
}

// searchAppPlaybackJudge:search-lyrics 用的判定。同 liveAppPlaybackJudge,只是不查汽水试听段 —— 那一步会联网、
// 还会向 App 发布修正,一次性的搜索进程不该做。
func searchAppPlaybackJudge() appPlaybackJudge {
	j := liveAppPlaybackJudge
	j.sodaPreview = func(string, string, string, string, float64) (float64, float64, bool, bool) {
		return 0, 0, false, false
	}
	return j
}

// notePlaybackIDsFromAppState 读一次 App 写的播放状态,把正在放的那首的 Apple 目录 ID(j.catalog 核对目录锚点时记下)
// 与 Spotify 曲目 ID 记成播放提示(platformtrackid.go)。search-lyrics 是独立进程,常驻进程记下的提示它看不到;
// 搜的正是在放的这首时,按 ID 直取的几条路(amll、Music.app 本地歌词缓存、在播 ISRC)才跟自动解析走得一样。
// 状态不可用(App 没在跑、过期、读不出)或没在放时什么都不记。
func notePlaybackIDsFromAppState(path string, now time.Time, j appPlaybackJudge) {
	rec, avail := newAppStateReader(path).read(now)
	if avail != appStateAvailable {
		return
	}
	tick, _ := appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	notePlayingSpotifyTrackID(tick.snap.Artist, tick.snap.Title, tick.snap.Album, tick.spotifyTrackID)
}

// liveAppFixedTrack:署名纠正,酷狗与信任播放器两套按 bundle 互斥。
func liveAppFixedTrack(bundle, title, artist, album string, duration float64) (string, string, bool) {
	if fixed, ok := kugouFixedArtist(bundle, title, artist, duration); ok {
		return fixed, title, true
	}
	return trustedFixedTrack(bundle, title, artist, album, duration)
}

// liveAppSodaPreview:汽水试听段。查到就记下(会话时长补正要认,见 noteSodaPreviewKnown)并发布给 App
// (publishPlayerPreviewFix,按原始标签);查找按洗过的标签。换算交给调用方。
func liveAppSodaPreview(bundle, rawTitle, rawArtist, rawAlbum string, duration float64) (float64, float64, bool, bool) {
	if bundle != sodaMusicBundleID {
		return 0, 0, false, false
	}
	title, artist := cleanMediaTag(rawTitle), cleanMediaTag(rawArtist)
	p, ok := sodaPreviewFor(artist, title, cleanMediaTag(rawAlbum), duration, func(found sodaPreview) {
		noteSodaPreviewKnown(artist, title, found)
		publishPlayerPreviewFix(bundle, rawTitle, rawArtist, found)
	})
	if !ok {
		return 0, 0, false, sodaPreviewLookupPending(artist, title)
	}
	noteSodaPreviewKnown(artist, title, p)
	publishPlayerPreviewFix(bundle, rawTitle, rawArtist, p)
	return p.StartSecs, p.FullSecs, true, false
}

// liveAppCatalog:Apple 目录锚点,核对通过就记下目录 ID(amll 按它直取歌词)。
func liveAppCatalog(bundle string, trackID int64, trackNumber int, artist, title, album string) (float64, bool) {
	anchor, ok := appleCatalogAnchor(bundle, trackID, trackNumber, title, album)
	if !ok {
		return 0, false
	}
	if anchor.TrackViewURL == "" {
		// 较早落盘的锚点没有 Apple Music 页,补上之后缓存命中那条路(trackEnrichment)才能把链接换成它。
		prefetchAppleCatalogTrackLink(trackID)
	}
	notePlayingAppleCatalogID(artist, title, album, trackID)
	return anchor.DurationSecs, true
}

// appPlaybackMarks:上一份用过的 App 状态里,认起播 / 重新对齐要比的几项。
type appPlaybackMarks struct {
	pid       int
	playSeq   int64
	anchorSeq int64
	key       string
}

// appPlaybackTick:一份可用的 App 状态换成的这一拍。tracked=false = App 此刻没认下歌。holding = App 读不到播放器、
// 按住着上一份(内容是旧的,不计收听时长)。
type appPlaybackTick struct {
	snap           snapshot
	tracked        bool
	holding        bool
	ad             bool
	spotifyTrackID string
	amazonTrackID  string
	// youtubeMusicVideoID:Kaset 那首的 videoId(拼歌曲页用,见 kasetlink.go)。
	youtubeMusicVideoID string
	loopRestart         bool
	reanchor            bool
}

// appPlaybackTickFor 把一份可用的 App 状态换成这一拍的快照与事件,同时给出下一拍要比的 marks。
// 判定经 j 注入,其余是纯函数。没在放时 marks 原样留着:停播后回到同一首、play_seq 没加就不算重新起播。
func appPlaybackTickFor(rec appStateRecord, prev appPlaybackMarks, now time.Time, j appPlaybackJudge) (appPlaybackTick, appPlaybackMarks) {
	marks := prev
	if rec.AppPID != prev.pid {
		marks = appPlaybackMarks{pid: rec.AppPID}
	}
	if !rec.hasTrack() {
		return appPlaybackTick{}, marks
	}
	t := rec.Track
	s := appStateSnapshot(rec, now)
	if fixedArtist, fixedTitle, ok := j.fixedTrack(rec.Player, t.Raw.Title, t.Raw.Artist, t.Raw.Album, s.ReportedDuration); ok &&
		j.fixRev() > t.AppliedFixRev {
		s.Title, s.Artist, s.Album = fixedTitle, fixedArtist, t.Raw.Album
	}
	if start, full, known, pending := j.sodaPreview(rec.Player, t.Raw.Title, t.Raw.Artist, t.Raw.Album, s.Duration); known {
		if math.Abs(s.Duration-full) > sodaPreviewDurationTolerance {
			s.Duration, s.ReportedDuration = full, full
			s.Position += start
		}
	} else {
		s.SodaPreviewPending = pending
	}
	if full, ok := j.neteaseTrial(rec.Player, t.Raw.Title, t.Raw.Artist, t.Raw.Album, s.Duration); ok {
		s.Duration, s.ReportedDuration = full, full
	}
	catalogDuration := 0.0
	if t.CatalogTrackID != nil {
		number := 0
		if t.TrackNumber != nil {
			number = *t.TrackNumber
		}
		if d, ok := j.catalog(rec.Player, *t.CatalogTrackID, number, s.Artist, s.Title, s.Album); ok && d > 0 {
			catalogDuration = d
		}
	}
	if s.Radio || catalogDuration > 0 {
		s.Duration = catalogDuration
	}
	if s.Duration > 0 && s.Position > s.Duration {
		s.Position = s.Duration
	}
	key := s.key()
	anchorSeq := int64(0)
	if rec.Position != nil {
		anchorSeq = rec.Position.AnchorSeq
	}
	samePID := rec.AppPID == prev.pid
	tick := appPlaybackTick{snap: s, tracked: true, holding: rec.Holding, ad: t.Ad, spotifyTrackID: t.SpotifyTrackID,
		amazonTrackID: t.AmazonTrackID, youtubeMusicVideoID: t.YouTubeMusicVideoID}
	tick.loopRestart = samePID && key == prev.key && t.PlaySeq > prev.playSeq
	tick.reanchor = !samePID || tick.loopRestart || anchorSeq != prev.anchorSeq
	marks.playSeq, marks.anchorSeq, marks.key = t.PlaySeq, anchorSeq, key
	return tick, marks
}

var (
	appAdMu sync.Mutex
	// appAdKey:App 此刻判成广告的那一首(bundle + 会话 key);空 = 没有。
	appAdKey string
)

// noteAppReportedAd 记下 App 此刻是不是把这一首判成了广告。App 没认下歌的那几拍传空快照清掉。
func noteAppReportedAd(s snapshot, ad bool) {
	k := ""
	if ad && s.key() != "" {
		k = s.Bundle + "\x00" + s.key()
	}
	appAdMu.Lock()
	appAdKey = k
	appAdMu.Unlock()
}

// appReportedAd:App 把这一首判成了广告(isAdBreak 只认它)。
func appReportedAd(bundleID, artist, title, album string) bool {
	appAdMu.Lock()
	defer appAdMu.Unlock()
	return appAdKey != "" && appAdKey == bundleID+"\x00"+title+"|"+artist+"|"+album
}

// appPlayback:poller 读 App 状态要记的东西。nil = 不读(CLI 子命令、测试)。
type appPlayback struct {
	reader *appStateReader
	judge  appPlaybackJudge
	marks  appPlaybackMarks
	// 上一拍用掉的那份(进程号 + 内容版本)与它的可用性,快速通道据此判有没有新东西。只推进序号的保活重写
	// 不算新东西,由主节拍照常读到。
	usedPID     int
	usedVersion uint64
	usedAvail   appStateAvailability
	// path:上一拍是在用 App 状态还是在待机,变了才记一行日志。
	path string
}

// changed:状态文件自上一拍以来有没有新内容、可用性有没有变。快速通道用;保活重写不算新内容。
func (a *appPlayback) changed(now time.Time) bool {
	if a == nil {
		return false
	}
	rec, avail, version := a.reader.readVersioned(now)
	return rec.AppPID != a.usedPID || version != a.usedVersion || avail != a.usedAvail
}

// notePath 记下这一拍走的哪条路,跟上一拍不同就打一行。
func (a *appPlayback) notePath(path, detail string) {
	if path == a.path {
		return
	}
	a.path = path
	log.Printf("playback source: %s", detail)
}

// appPlaybackArtworkReader:设备封面读 App 写的当前封面文件时用的读取器(run() 登记;nil = 没有封面来源)。
var (
	appPlaybackArtworkMu     sync.Mutex
	appPlaybackArtworkReader *appStateReader
	appPlaybackArtworkPath   string
)

func setAppPlaybackArtworkSource(r *appStateReader, artworkPath string) {
	appPlaybackArtworkMu.Lock()
	defer appPlaybackArtworkMu.Unlock()
	appPlaybackArtworkReader, appPlaybackArtworkPath = r, artworkPath
}

// appPlaybackArtwork:这一首的设备封面,取自 App 写的当前封面文件。ok=false = App 此刻没有这首的封面(换歌那一拍
// 封面常晚到,settleDeviceCover 之后还会再问)。封面要属于这首(play_seq 相同)、文件校验和与状态里记的一致。
func appPlaybackArtwork(bundleID, artist, title string) (data []byte, mimeType string, ok bool) {
	appPlaybackArtworkMu.Lock()
	r, path := appPlaybackArtworkReader, appPlaybackArtworkPath
	appPlaybackArtworkMu.Unlock()
	if r == nil || path == "" {
		return nil, "", false
	}
	rec, avail := r.read(time.Now())
	if avail != appStateAvailable {
		return nil, "", false
	}
	if !rec.hasTrack() || rec.Player != bundleID || rec.Track.Artist != artist || rec.Track.Title != title {
		return nil, "", false
	}
	a := rec.Artwork
	if a == nil || a.PlaySeq != rec.Track.PlaySeq {
		return nil, "", false
	}
	b, err := os.ReadFile(path)
	if err != nil || len(b) != a.Bytes {
		return nil, "", false
	}
	sum := sha256.Sum256(b)
	if hex.EncodeToString(sum[:]) != a.SHA256 {
		return nil, "", false
	}
	return b, a.Mime, true
}
