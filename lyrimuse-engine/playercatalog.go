package main

import (
	"encoding/json"
	"math"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 播放器自己给这首记下的专辑 id、第一位歌手的 id(汽水还有曲目 id):哪个播放器在放,就从它本机的数据里取,不联网。
// 记进缓存条目,App 拼成那家的专辑页、歌手页放进歌词窗口「⋯」菜单;汽水的曲目 id 拼成歌曲页 soda_url,跟别家的歌曲页
// 一样进 fields()、ListenBrainz 和中继。
//
// 各家来源,都是引擎本来就在读的本机数据:
//   - 汽水音乐:播放队列缓存(sodalocal.go)里这首的 id / album.id / 第一位歌手的 id;从歌单、专辑点播的不在队列缓存里,
//     看音频缓存库(sodapreload.go),正在播的这首一定在里面;
//   - KKBOX:客户端缓存的单曲详情里的 album.id / artist.id(artist_roles 里的歌手没有 id);
//   - Amazon Music:目录缓存里这首(App 报的 ASIN)的 album.asin / artist.asin;
//   - Spotify:客户端元数据缓存(primary.ldb)里这首(换曲那一拍记下的曲目 id)的所属专辑与第一位歌手。
// YouTube Music(Kaset)的专辑页、歌手页 id 跟专辑判定一起记(kasetalbum.go)。
//
// 专辑、歌手只存 id,不存拼好的地址:带 _url 的字段都按歌曲页对待,要进 fields()、ListenBrainz 白名单和中继 links;
// 专辑页、歌手页只有 App 用,跟 QQAlbumMid 一样不进 fields()。

// 同一首多久再读一次:trackEnrichment 在同一首歌的播放期间每几秒进来一次,本机数据不必每次都读;客户端开播后才把
// 这首写进去(Spotify 的曲目 id 也是换曲那一拍才记下),没读到的隔一会儿再试。
const (
	playerCatalogHitTTL  = 10 * time.Minute
	playerCatalogMissTTL = 20 * time.Second
)

// playerCatalogIDs:song 是歌曲页(只有汽水走这里),album / artist 是那家自己的 id。
type playerCatalogIDs struct {
	song, album, artist string
}

var (
	playerCatalogMu   sync.Mutex
	playerCatalogMemo = map[string]playerCatalogAt{}
)

type playerCatalogAt struct {
	at  time.Time
	ids playerCatalogIDs
}

func (m playerCatalogAt) ttl() time.Duration {
	if m.ids == (playerCatalogIDs{}) {
		return playerCatalogMissTTL
	}
	return playerCatalogHitTTL
}

// playerCatalogIDsFor:当前播放器给这首记下的 id;不是上面四家、本机数据里没有都返回空。要读别的 App 的本机文件,
// 调用方不能持着 enrichMu(Amazon 那条经 amazonASINFor 会取它的锁)。
func playerCatalogIDsFor(bundleID, artist, title, album string, durationSecs float64) playerCatalogIDs {
	switch bundleID {
	case sodaMusicBundleID, kkboxBundleID, amazonMusicBundleID, spotifyBundleID:
	default:
		return playerCatalogIDs{}
	}
	key := strings.Join([]string{bundleID, loosenEnrichKey(artist), loosenEnrichKey(title), loosenEnrichKey(album),
		strconv.Itoa(int(math.Round(durationSecs)))}, "\x00")
	now := time.Now()
	playerCatalogMu.Lock()
	if m, ok := playerCatalogMemo[key]; ok && now.Sub(m.at) < m.ttl() {
		playerCatalogMu.Unlock()
		return m.ids
	}
	playerCatalogMu.Unlock()
	var ids playerCatalogIDs
	switch bundleID {
	case sodaMusicBundleID:
		ids = sodaPlayingCatalogIDs(artist, title, album, durationSecs)
	case kkboxBundleID:
		ids = scanKKBOXCache(kkboxCacheDir()).catalogIDsFor(artist, title, durationSecs)
	case amazonMusicBundleID:
		ids = amazonPlayingCatalogIDs(artist, title, album)
	case spotifyBundleID:
		ids = spotifyPlayingCatalogIDs(artist, title)
	}
	if !playerCatalogIDOK(bundleID, ids.album) {
		ids.album = ""
	}
	if !playerCatalogIDOK(bundleID, ids.artist) {
		ids.artist = ""
	}
	playerCatalogMu.Lock()
	for k, m := range playerCatalogMemo {
		if now.Sub(m.at) >= m.ttl() {
			delete(playerCatalogMemo, k)
		}
	}
	playerCatalogMemo[key] = playerCatalogAt{at: now, ids: ids}
	playerCatalogMu.Unlock()
	return ids
}

// applyPlayerCatalogIDsLocked 把这一拍读到的 id 记进条目,变了返回 true(调用方据此落盘)。读不到的不删已记下的:
// 客户端会自己清理本机数据,记下过的仍然是它给这首的。调用方持有 enrichMu。
func applyPlayerCatalogIDsLocked(e *enrichEntry, bundleID string, ids playerCatalogIDs) bool {
	var fields []*string
	var values []string
	switch bundleID {
	case sodaMusicBundleID:
		fields, values = []*string{&e.SodaURL, &e.SodaAlbumID, &e.SodaArtistID}, []string{ids.song, ids.album, ids.artist}
	case kkboxBundleID:
		fields, values = []*string{&e.KKBOXAlbumID, &e.KKBOXArtistID}, []string{ids.album, ids.artist}
	case amazonMusicBundleID:
		fields, values = []*string{&e.AmazonAlbumASIN, &e.AmazonArtistASIN}, []string{ids.album, ids.artist}
	case spotifyBundleID:
		fields, values = []*string{&e.SpotifyAlbumID, &e.SpotifyArtistID}, []string{ids.album, ids.artist}
	}
	changed := false
	for i, f := range fields {
		if values[i] != "" && *f != values[i] {
			*f, changed = values[i], true
		}
	}
	return changed
}

// playerCatalogIDOK:各家 id 的形状(实测):汽水是一串数字,KKBOX 是字母数字加 - _,Amazon 的 ASIN 是 10 位大写字母
// 数字,Spotify 是 22 位 base62。别的 App 本机数据里的东西拼进地址之前先过这一道,形状不对的不记。App 侧
// PlatformLinks 的形状闸与这里同源。
func playerCatalogIDOK(bundleID, id string) bool {
	switch bundleID {
	case sodaMusicBundleID:
		return catalogIDChars(id, 1, 32, isASCIIDigitRune)
	case kkboxBundleID:
		return catalogIDChars(id, 1, 32, func(r rune) bool { return isASCIIAlnumRune(r) || r == '-' || r == '_' })
	case amazonMusicBundleID:
		return catalogIDChars(id, 10, 10, func(r rune) bool { return r >= 'A' && r <= 'Z' || isASCIIDigitRune(r) })
	case spotifyBundleID:
		return catalogIDChars(id, 22, 22, isASCIIAlnumRune)
	}
	return false
}

// catalogIDChars:长度在 [minLen, maxLen] 内、每个字符都过 ok。
func catalogIDChars(id string, minLen, maxLen int, ok func(rune) bool) bool {
	if len(id) < minLen || len(id) > maxLen {
		return false
	}
	for _, r := range id {
		if !ok(r) {
			return false
		}
	}
	return true
}

func isASCIIDigitRune(r rune) bool { return r >= '0' && r <= '9' }

func isASCIIAlnumRune(r rune) bool {
	return isASCIIDigitRune(r) || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z'
}

// sodaTrackPageURL:汽水的曲目 id 拼成网页分享页(跟取词最后一级备用的是同一个页面,见 sodaSharePageURL)。形状不对返回 ""。
func sodaTrackPageURL(id string) string {
	if !playerCatalogIDOK(sodaMusicBundleID, id) {
		return ""
	}
	return sodaSharePageURL + "?track_id=" + id
}

// sodaPlayingCatalogIDs:汽水队列缓存里正在播的这首;不在里面就看音频缓存库。
func sodaPlayingCatalogIDs(artist, title, album string, durationSecs float64) playerCatalogIDs {
	if t, ok := sodaLocalCatalogTrack(artist, title, album, durationSecs); ok {
		ids := playerCatalogIDs{song: sodaTrackPageURL(strings.TrimSpace(t.ID)), album: t.Album.ID}
		for _, a := range t.Artists {
			if a.Name != "" {
				ids.artist = a.ID
				break
			}
		}
		return ids
	}
	if t, ok := sodaPreloadCatalogTrack(artist, title, album, durationSecs); ok {
		return playerCatalogIDs{song: sodaTrackPageURL(t.id), album: t.albumID, artist: t.artistID}
	}
	return playerCatalogIDs{}
}

// sodaLocalCatalogTrack:队列缓存里的这首。多人署名按 sodaArtistCandidates 拆开逐个查(索引按单个歌手建),挑法同
// pickSodaLocalEntry。
func sodaLocalCatalogTrack(artist, title, album string, durationSecs float64) (sodaLocalTrack, bool) {
	sodaLocalMu.Lock()
	refreshSodaLocalIndexLocked()
	var ents []sodaLocalTrack
	for _, a := range sodaArtistCandidates(artist) {
		if key := sodaLocalKey(a, title); key != "" {
			ents = append(ents, sodaLocalIndex[key]...)
		}
	}
	sodaLocalMu.Unlock()
	return pickSodaLocalEntry(ents, album, durationSecs)
}

// sodaPreloadCatalogTrack:音频缓存库里的这首。歌手连同歌名按 loosenEnrichKey 比(缓存里的多人署名用 "/" 连着,
// 播放器报的是「HUSH, 孙盛希」,分隔符那一层折平了);时长要对得上整首,或者放的是试听段、跟它的试听段对得上
// (sodaPreviewMatches)。专辑对得上的优先,再挑时长差最小的。
func sodaPreloadCatalogTrack(artist, title, album string, durationSecs float64) (sodaPreloadedTrack, bool) {
	want := loosenEnrichKey(artist + "|" + title)
	if want == "|" {
		return sodaPreloadedTrack{}, false
	}
	var best sodaPreloadedTrack
	var bestScore float64
	found := false
	for _, t := range sodaPreloadIndex() {
		if loosenEnrichKey(t.upcoming.artist+"|"+t.upcoming.title) != want {
			continue
		}
		full := sourceDurationFits(durationSecs, t.upcoming.duration)
		if !full {
			p, ok := sodaPreviewFromMillis(t.previewStartMs, t.previewDurMs, t.fullMs)
			if !ok || !sodaPreviewMatches(durationSecs, p) {
				continue
			}
		}
		score := 0.0
		if album != "" && t.upcoming.album != "" && normLoose(t.upcoming.album) == normLoose(album) {
			score += 1000
		}
		if full && durationSecs > 0 && t.upcoming.duration > 0 {
			score -= math.Abs(t.upcoming.duration - durationSecs)
		}
		if !found || score > bestScore {
			best, bestScore, found = t, score, true
		}
	}
	return best, found
}

// catalogIDsFor:缓存里这首的单曲详情给的专辑 id 与歌手 id;挑条目同 songURLFor。
func (c kkboxCache) catalogIDsFor(artist, title string, durationSecs float64) playerCatalogIDs {
	for _, e := range c {
		if id, ok := strings.CutPrefix(e.url.Path, "/v2/tracks/"); !ok || id == "" {
			continue
		}
		body, ok := e.body()
		if !ok {
			continue
		}
		var d struct {
			Data kkboxTrack `json:"data"`
		}
		var ids struct {
			Data struct {
				Album *struct {
					ID string `json:"id"`
				} `json:"album"`
				Artist *struct {
					ID string `json:"id"`
				} `json:"artist"`
			} `json:"data"`
		}
		if json.Unmarshal(body, &d) != nil || json.Unmarshal(body, &ids) != nil || !kkboxLyricMatch(d.Data, artist, title, durationSecs) {
			continue
		}
		var out playerCatalogIDs
		if ids.Data.Album != nil {
			out.album = ids.Data.Album.ID
		}
		if ids.Data.Artist != nil {
			out.artist = ids.Data.Artist.ID
		}
		if out != (playerCatalogIDs{}) {
			return out
		}
	}
	return playerCatalogIDs{}
}

// amazonPlayingCatalogIDs:目录缓存里这首(App 报的当前曲目的 ASIN)的 album.asin / artist.asin。只认 App 报的当前曲目,
// 别换成 amazonASINFor:它的队列与缓存索引两条退路按歌手 + 歌名认曲目,同名的单曲与专辑版会认到另一条上,把另一张专辑
// 记到这一条。当前曲目同样只比歌手歌名,所以目录里这一轨的专辑名跟这一条的专辑对不上时也不认(见 07 章决策 143)。
func amazonPlayingCatalogIDs(artist, title, album string) playerCatalogIDs {
	asin := amazonCurrentASIN(artist, title)
	if asin == "" {
		return playerCatalogIDs{}
	}
	t, ok := amazonCatalog([]string{asin})[asin]
	if !ok {
		return playerCatalogIDs{}
	}
	if name := t.albumName(); album != "" && name != "" && loosenEnrichKey(cleanMediaTag(name)) != loosenEnrichKey(cleanMediaTag(album)) {
		return playerCatalogIDs{}
	}
	return playerCatalogIDs{album: t.Album.ASIN, artist: t.Artist.ASIN}
}

// spotifyPlayingCatalogIDs:客户端元数据缓存里这首的所属专辑与第一位歌手。
func spotifyPlayingCatalogIDs(artist, title string) playerCatalogIDs {
	userDir := spotifyActiveUserDir()
	trackID := spotifyTrackIDHintFor(artist, title)
	if userDir == "" || trackID == "" {
		return playerCatalogIDs{}
	}
	key := spotifyXmetaKey(spotifyTrackKind, trackID)
	v := ldbGet(filepath.Join(userDir, "primary.ldb"), [][]byte{key})[string(key)]
	return playerCatalogIDs{album: spotifyParseTrackAlbumID(v), artist: spotifyParseTrackArtistID(v)}
}
