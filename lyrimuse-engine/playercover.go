package main

import (
	"context"
	"encoding/json"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

// 播放器自己给这首记下的封面地址:哪个播放器在放,就从它本机的数据里取它给这首记下的那张专辑图,不联网。
// 按播放器记进缓存条目的 PlayerCovers,App 给 Discord 这类 App 外面的地方挑封面时先用当前播放器的那张
// (CoverURL 常是设备直送、存在本机的文件,离开这台机器打不开)。
//
// 各家来源,都是引擎本来就在读的本机数据:
//   - 网易云:客户端曲库 dbTrack 里这首的 album.picUrl(neteaselocal.go 的索引),图床给的 http 换成 https;
//   - QQ 音乐:播放列表归档里当前这首的 albumInfo.albumMid,按 qqAlbumCoverURL 拼;
//   - KKBOX:客户端缓存的单曲详情里的专辑图 600 档(kkboxPlayingInfo.cover);
//   - Amazon Music:目录缓存里这首(按 ASIN)的 album.image,换成同尺寸的 JPEG。
// Spotify、Kaset、YouTube Music 网页版的封面地址 App 自己读得到,不经这里。

// 同一首多久再读一次:trackEnrichment 在同一首歌的播放期间每几秒进来一次,本机数据(sqlite、plist、LevelDB)
// 不必每次都读;客户端开播后才把这首写进去,没读到的隔一会儿再试。
const (
	playerCoverHitTTL  = 10 * time.Minute
	playerCoverMissTTL = 20 * time.Second
)

var (
	playerCoverMu   sync.Mutex
	playerCoverMemo = map[string]playerCoverAt{}
)

type playerCoverAt struct {
	at    time.Time
	cover string
}

func playerCoverTTL(cover string) time.Duration {
	if cover == "" {
		return playerCoverMissTTL
	}
	return playerCoverHitTTL
}

// playerCoverURLFor:当前播放器给这首记下的封面地址;不是上面四家、本机数据里没有都返回 ""。要读别的 App 的
// 本机文件,调用方不能持着 enrichMu(Amazon 那条经 amazonASINFor 会取它)。kkbox 是同一拍已经取好的那份
// (kkboxPlayingInfoFor 自己记 30 秒)。
func playerCoverURLFor(bundleID, artist, title, album string, durationSecs float64, kkbox kkboxPlayingInfo) string {
	switch bundleID {
	case kkboxBundleID:
		return kkbox.cover
	case neteaseMusicBundleID, qqMusicBundleID, amazonMusicBundleID:
	default:
		return ""
	}
	key := bundleID + "\x00" + loosenEnrichKey(artist) + "\x00" + loosenEnrichKey(title) + "\x00" + loosenEnrichKey(album)
	now := time.Now()
	playerCoverMu.Lock()
	if m, ok := playerCoverMemo[key]; ok && now.Sub(m.at) < playerCoverTTL(m.cover) {
		playerCoverMu.Unlock()
		return m.cover
	}
	playerCoverMu.Unlock()
	var cover string
	switch bundleID {
	case neteaseMusicBundleID:
		cover = neteaseLocalCoverURL(artist, title, album, durationSecs)
	case qqMusicBundleID:
		cover = qqPlayingCoverURL(artist, title)
	case amazonMusicBundleID:
		cover = amazonPlayingCoverURL(artist, title)
	}
	playerCoverMu.Lock()
	for k, m := range playerCoverMemo {
		if now.Sub(m.at) >= playerCoverTTL(m.cover) {
			delete(playerCoverMemo, k)
		}
	}
	playerCoverMemo[key] = playerCoverAt{at: now, cover: cover}
	playerCoverMu.Unlock()
	return cover
}

// applyPlayerCoverLocked 把这一拍读到的地址记进条目,变了返回 true(调用方据此落盘)。读不到时不删已记下的:客户端会
// 自己清理本机数据,记下过的那张仍然是它给这首的封面。换掉整张表而不是原地改:条目是值拷贝,表跟落盘那份快照共用。
// 调用方持有 enrichMu。
func applyPlayerCoverLocked(e *enrichEntry, bundleID, cover string) bool {
	if bundleID == "" || cover == "" || e.PlayerCovers[bundleID] == cover {
		return false
	}
	covers := make(map[string]string, len(e.PlayerCovers)+1)
	for k, v := range e.PlayerCovers {
		covers[k] = v
	}
	covers[bundleID] = cover
	e.PlayerCovers = covers
	return true
}

// neteaseLocalCoverURL:网易云客户端曲库里这首的专辑图,挑条目的判据同 neteaseLocalSong。
func neteaseLocalCoverURL(artist, title, album string, durationSecs float64) string {
	key := neteaseLocalKey(artist, title)
	if key == "" {
		return ""
	}
	neteaseLocalMu.Lock()
	refreshNeteaseLocalIndexLocked(context.Background())
	ents := append([]neteaseLocalTrack(nil), neteaseLocalIndex[key]...)
	neteaseLocalMu.Unlock()
	t, ok := pickNeteaseLocalEntry(ents, album, durationSecs)
	if !ok {
		return ""
	}
	return neteaseHTTPSImage(t.Album.PicURL)
}

// neteaseHTTPSImage:网易云图床(*.music.126.net)的地址换成 https,同一路径照给(实测);别的主机不认。
func neteaseHTTPSImage(raw string) string {
	u, err := neturl.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	if host != "music.126.net" && !strings.HasSuffix(host, ".music.126.net") {
		return ""
	}
	u.Scheme = "https"
	return u.String()
}

// qqPlayingCoverURL:QQ 音乐播放列表归档里当前这首的专辑图。归档里没有这首、没有 albumMid 返回 ""。
func qqPlayingCoverURL(artist, title string) string {
	pl, ok := qqLoadPlayingList(artist, title)
	if !ok {
		return ""
	}
	mid, _ := qqPlistField(pl.objs, qqPlistField(pl.objs, qqDeref(pl.objs, pl.items[pl.pos]), "albumInfo"), "albumMid").(string)
	if !qqMidShape(mid) {
		return ""
	}
	return qqAlbumCoverURL(mid)
}

// qqMidShape:albumMid 是一串字母数字(实测 14 位);空的、带别的字符的不拼进地址。
func qqMidShape(mid string) bool {
	if mid == "" || len(mid) > 32 {
		return false
	}
	for _, c := range mid {
		if (c < '0' || c > '9') && (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') {
			return false
		}
	}
	return true
}

// amazonPlayingCoverURL:Amazon Music 目录缓存里这首(App 报的 ASIN)的专辑图。
func amazonPlayingCoverURL(artist, title string) string {
	asin := amazonASINFor(artist, title)
	if asin == "" {
		return ""
	}
	t, ok := amazonCatalog([]string{asin})[asin]
	if !ok {
		return ""
	}
	return amazonJPEGImage(t.Album.Image)
}

// amazonJPEGImage:目录缓存给的是 webp 档(`…/images/I/<id>._FMwebp_SX500_.jpg`),去掉 `FMwebp_` 那一段就是同尺寸的
// JPEG(实测)。只认 Amazon 图床(*.media-amazon.com)的 https 地址。
func amazonJPEGImage(raw string) string {
	u, err := neturl.Parse(raw)
	if err != nil || u.Scheme != "https" {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	if host != "media-amazon.com" && !strings.HasSuffix(host, ".media-amazon.com") {
		return ""
	}
	u.Path = strings.Replace(u.Path, "._FMwebp_", "._", 1)
	u.RawPath = ""
	return u.String()
}

// coverFor:KKBOX 缓存里这首的单曲详情给的专辑图 600 档;没有就空串。挑条目同 songURLFor。
func (c kkboxCache) coverFor(artist, title string, durationSecs float64) string {
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
		if json.Unmarshal(body, &d) != nil || !kkboxLyricMatch(d.Data, artist, title, durationSecs) {
			continue
		}
		if cover := d.Data.albumImage600(); cover != "" {
			return cover
		}
	}
	return ""
}

// albumImage600:单曲详情里的专辑图 600 档(给 App 外面用,不要原图;要原图走 albumCover)。
func (t kkboxTrack) albumImage600() string {
	if t.Album == nil || t.Album.Images == nil {
		return ""
	}
	for _, img := range []*kkboxImage{t.Album.Images.Large, t.Album.Images.Medium} {
		if img != nil && strings.HasPrefix(img.URL, "https://") {
			return img.URL
		}
	}
	return ""
}
