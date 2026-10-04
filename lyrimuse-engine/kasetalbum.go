package main

import (
	"context"
	"log"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Kaset 放的这一版该显示什么专辑。Kaset 的队列那一格常是 MV / 视频版本(专辑只登记在音轨版本上),放歌单时还可能根本
// 没配音轨版本;它自己报的专辑那一栏从歌单页开播时是歌单名。所以按 YouTube Music 的登记判(界面语言见
// ytmusicDisplayLanguage):
//  1. 放的这一版自己登记了专辑(音轨版本):就是它。
//  2. 队列里配了音轨版本:两版一样长(差不超过 kasetSameLengthTolerance 秒)是同一段录音,用音轨版本的专辑;不一样长,
//     放的又是官方 MV(MUSIC_VIDEO_TYPE_OMV),放的就是 MV 版本(界面写「MV」),别的视频没有专辑。
//  3. 没配音轨版本:按歌手 + 歌名 + 这一版的时长去曲库里找一样长的音轨版本,找到用它的专辑;找不到,放的是官方 MV 就是
//     MV 版本,不是就没有专辑。
//
// 结论写进条目(youtube_music_album / youtube_music_mv,连同判的时候用的界面语言 youtube_music_album_lang),给界面、
// 上送,以及播放器没报专辑时搜歌词用(见 kasetlyricsalbum.go),不进缓存 key。

// kasetSameLengthTolerance:两版时长差不超过这么多秒算同一段录音(元数据是整数秒)。
const kasetSameLengthTolerance = 3

const ytmusicVideoTypeOMV = "MUSIC_VIDEO_TYPE_OMV"

// kasetAlbumVerdictRev:判法的版本,跟结论一起记进条目(youtube_music_album_rev)。改了判法就加一,补判扫描把旧版判的重判一次。
const kasetAlbumVerdictRev = 1

// kasetAlbumVerdict:album 非空 = 这首的专辑;mv = 放的是 MV 版本;两样都没有 = 这一版没有专辑。
type kasetAlbumVerdict struct {
	album string
	mv    bool
	// albumBrowseID:那张专辑的专辑页 id(同专辑预取用,kasetalbumprefetch.go)。
	albumBrowseID string
}

// kasetAlbumLookups:判专辑要问的三样。listed / catalog 的 ok=false 是还没问到,这一回不下结论。
type kasetAlbumLookups struct {
	listed  func(videoID string) (ytmusicCredit, bool)
	catalog func(artist, title string, lengthSecs float64) (string, bool)
	audioOf func(videoID string) string
}

// kasetSameLength:两个时长都知道、而且差不超过 kasetSameLengthTolerance。
func kasetSameLength(a, b float64) bool {
	return a > 0 && b > 0 && math.Abs(a-b) <= kasetSameLengthTolerance
}

// kasetAlbumVerdictWith 按头注那三条判。这一版的时长取 YouTube Music 登记的,没有才用 playedSecs。纯函数(问法从 l
// 传进来),单测覆盖。
func kasetAlbumVerdictWith(l kasetAlbumLookups, videoID string, playedSecs float64, artist, title string) (kasetAlbumVerdict, bool) {
	if videoID == "" {
		return kasetAlbumVerdict{}, false
	}
	played, ok := l.listed(videoID)
	if !ok {
		return kasetAlbumVerdict{}, false
	}
	if played.album != "" {
		return kasetAlbumVerdict{album: played.album, albumBrowseID: played.albumBrowseID}, true
	}
	length := played.durationSecs
	if length <= 0 {
		length = playedSecs
	}
	isMV := played.videoType == ytmusicVideoTypeOMV
	if audio := l.audioOf(videoID); audio != "" && audio != videoID {
		a, ok := l.listed(audio)
		if !ok {
			return kasetAlbumVerdict{}, false
		}
		if a.album != "" {
			if length > 0 && a.durationSecs > 0 && !kasetSameLength(length, a.durationSecs) {
				return kasetAlbumVerdict{mv: isMV}, true
			}
			return kasetAlbumVerdict{album: a.album, albumBrowseID: a.albumBrowseID}, true
		}
	}
	found, ok := l.catalog(artist, kasetCatalogTitle(artist, title), length)
	if !ok {
		return kasetAlbumVerdict{}, false
	}
	if found != "" {
		a, ok := l.listed(found)
		if !ok {
			return kasetAlbumVerdict{}, false
		}
		if a.album != "" {
			return kasetAlbumVerdict{album: a.album, albumBrowseID: a.albumBrowseID}, true
		}
	}
	return kasetAlbumVerdict{mv: isMV}, true
}

// kasetCatalogTitle:曲库搜索用的歌名。归一化之后去掉开头的「这首的歌手 - 」(Kaset 把歌名换成视频标题时带着)。
func kasetCatalogTitle(artist, title string) string {
	t := normEnrichTitle(title)
	for _, sep := range []string{" - ", " – ", " — "} {
		if i := strings.Index(t, sep); i > 0 && normLoose(t[:i]) == normLoose(artist) {
			return strings.TrimSpace(t[i+len(sep):])
		}
	}
	return t
}

// kasetAlbumVerdictFor:轮询每拍、预解析时用 —— 问过的有就给,没有就后台去问(这一拍先不下结论)。
func kasetAlbumVerdictFor(videoID string, playedSecs float64, artist, title string) (kasetAlbumVerdict, bool) {
	hl := ytmusicDisplayLanguage()
	return kasetAlbumVerdictWith(kasetAlbumLookups{
		listed:  func(id string) (ytmusicCredit, bool) { return ytmusicListedCachedOrFetch(id, hl) },
		catalog: kasetCatalogAudioVersionCachedOrFetch,
		audioOf: kasetAudioVideoIDFor,
	}, videoID, playedSecs, artist, title)
}

// applyKasetAlbumVerdict:判出来的结论写进条目,连同判的时候用的界面语言和判法版本;都没变返回 false。调用方持有 enrichMu。
func applyKasetAlbumVerdict(e *enrichEntry, v kasetAlbumVerdict, hl string) bool {
	if e.YouTubeMusicAlbum == v.album && e.YouTubeMusicMV == v.mv && e.YouTubeMusicAlbumLang == hl &&
		e.YouTubeMusicAlbumRev == kasetAlbumVerdictRev {
		return false
	}
	e.YouTubeMusicAlbum, e.YouTubeMusicMV, e.YouTubeMusicAlbumLang = v.album, v.mv, hl
	e.YouTubeMusicAlbumRev = kasetAlbumVerdictRev
	return true
}

var (
	kasetCatalogMu sync.Mutex
	// kasetCatalogCache:kasetCatalogKey → 曲库里找到的音轨版本 videoId,空串 = 找过、没有。
	kasetCatalogCache = map[string]string{}
	// kasetCatalogPending:正在后台找的;kasetCatalogFailedAt:没问成的时刻。都在 kasetCatalogMu 里读写。
	kasetCatalogPending  = map[string]bool{}
	kasetCatalogFailedAt = map[string]time.Time{}
)

func kasetCatalogKey(artist, title string, lengthSecs float64) string {
	return artist + "|" + title + "|" + strconv.Itoa(int(math.Round(lengthSecs)))
}

// kasetCatalogAudioVersionCachedOrFetch:找过的有就给(ok=true);没有就后台去曲库找一次(同一首同时只找一次,没问成隔
// ytmusicCreditRetryAfter 再找),这一回 ok=false。
func kasetCatalogAudioVersionCachedOrFetch(artist, title string, lengthSecs float64) (string, bool) {
	key := kasetCatalogKey(artist, title, lengthSecs)
	kasetCatalogMu.Lock()
	defer kasetCatalogMu.Unlock()
	if id, ok := kasetCatalogCache[key]; ok {
		return id, true
	}
	if kasetCatalogPending[key] || time.Since(kasetCatalogFailedAt[key]) < ytmusicCreditRetryAfter {
		return "", false
	}
	kasetCatalogPending[key] = true
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), ytmusicCreditFetchTimeout)
		defer cancel()
		id, err := kasetSearchAudioVersion(ctx, artist, title, lengthSecs)
		kasetCatalogMu.Lock()
		defer kasetCatalogMu.Unlock()
		delete(kasetCatalogPending, key)
		if err != nil {
			kasetCatalogFailedAt[key] = time.Now()
			return
		}
		kasetCatalogCache[key] = id
	}()
	return "", false
}

// kasetSearchAudioVersion:按歌手 + 歌名在 YouTube Music 曲库里找这首的音轨版本(ATV),时长要跟 lengthSecs 一样长
// (kasetSameLength)。找不到返回空串;没问成返回 err。
func kasetSearchAudioVersion(ctx context.Context, artist, title string, lengthSecs float64) (string, error) {
	if lengthSecs <= 0 || artist == "" || title == "" {
		return "", nil
	}
	items, err := ytmusicSearchSongItems(ctx, artist, title, "")
	if err != nil {
		return "", err
	}
	item, ok := ytmusicPickSearchItem(items, artist, title, "", lengthSecs)
	if !ok || !item.isATV || !kasetSameLength(lengthSecs, item.durationSecs) {
		return "", nil
	}
	return item.videoID, nil
}

// kasetAlbumSweepDelay:引擎起来后多久补判;kasetAlbumSweepPace:两条之间隔多久(不抢正在放的那首的网络)。
const (
	kasetAlbumSweepDelay = 2 * time.Minute
	kasetAlbumSweepPace  = time.Second
)

// startKasetAlbumSweep:引擎起来后补判一次用 Kaset 放过、还没按当前界面语言和当前判法判过专辑的条目 —— 放的时候还没有
// 这一步的、按别的界面语言或旧判法判过的(界面语言换了,下次起来再补)。不在播放现场,队列里配的音轨版本多半拿不到,按头注第 3 条判。
func startKasetAlbumSweep(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(kasetAlbumSweepDelay):
	}
	hl := ytmusicDisplayLanguage()
	enrichMu.Lock()
	keys := kasetAlbumSweepCandidatesLocked(hl)
	enrichMu.Unlock()
	if len(keys) == 0 {
		return
	}
	lookups := kasetAlbumLookups{
		listed: func(id string) (ytmusicCredit, bool) { return ytmusicListedTrackSettled(ctx, id, hl) },
		catalog: func(artist, title string, lengthSecs float64) (string, bool) {
			id, err := kasetSearchAudioVersion(ctx, artist, title, lengthSecs)
			return id, err == nil
		},
		audioOf: kasetAudioVideoIDFor,
	}
	updated := 0
	for _, key := range keys {
		if ctx.Err() != nil {
			break
		}
		enrichMu.Lock()
		e, ok := enrichCache[key]
		enrichMu.Unlock()
		parts := strings.SplitN(key, "|", 3)
		if ok && len(parts) == 3 {
			title, _, _ := strings.Cut(parts[1], "~dur")
			v, settled := kasetAlbumVerdictWith(lookups, youtubeMusicVideoIDOfURL(e.YouTubeMusicURL), e.DurationSecs, parts[0], title)
			if settled {
				enrichMu.Lock()
				if cur, ok := enrichCache[key]; ok && applyKasetAlbumVerdict(&cur, v, hl) {
					enrichCache[key] = cur
					enrichDirty = true
					updated++
				}
				enrichMu.Unlock()
			}
		}
		select {
		case <-ctx.Done():
		case <-time.After(kasetAlbumSweepPace):
		}
	}
	if updated > 0 {
		requestEnrichSave()
	}
	log.Printf("kaset album sweep: %d of %d entries updated (hl=%s)", updated, len(keys), hl)
}

// kasetAlbumSweepCandidatesLocked:存过 YouTube Music 歌曲页(用 Kaset 放过)、键里没有专辑、还没按 hl 和当前判法判过的
// 条目,按 key 排序。调用方持有 enrichMu。
func kasetAlbumSweepCandidatesLocked(hl string) []string {
	var keys []string
	for k, e := range enrichCache {
		if e.YouTubeMusicURL == "" || (e.YouTubeMusicAlbumLang == hl && e.YouTubeMusicAlbumRev >= kasetAlbumVerdictRev) {
			continue
		}
		if parts := strings.SplitN(k, "|", 3); len(parts) != 3 || parts[2] != "" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
