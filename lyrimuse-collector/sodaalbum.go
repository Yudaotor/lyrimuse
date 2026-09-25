package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// 汽水的同专辑兜底:取汽水自己的专辑曲目表,歌名、歌手是汽水的写法,跟它真播到时报给系统的一致。
//
// 曲目表来自网页版的专辑分享页 `music.douyin.com/qishui/share/album?album_id=…`:给没登录的人看的
// 页面,服务端渲染时把整页数据以 `_ROUTER_DATA = {…}` 嵌在 HTML 里,loaderData.album_page.trackList
// 就是整张专辑(实测 10~30 首的专辑都完整,跟 albumInfo.count_tracks 一致)。客户端自己调的
// `GetAlbumDetail` 映射到哪个地址编在原生模块里,api.qishui.com 下猜得到的几个路径都是 404。
//
// 专辑 id 按当前这首找:先看 QueueCache 里这首的 album.id,再看音频缓存库里这首的记录(正在播的歌
// 一定会被缓存,见 sodapreload.go)。都找不到、页面取不到或对不上,返回 ok=false,由 albumTracks
// 退回网易云专辑接口。

const sodaAlbumPageBase = "https://music.douyin.com/qishui/share/album"

// sodaAlbumPageMaxBytes:实测一页 90KB 左右,30 首的专辑也在几百 KB 以内。
const sodaAlbumPageMaxBytes = 8 << 20

var (
	sodaAlbumMu    sync.Mutex
	sodaAlbumCache = map[string][]albumTrack{} // 专辑 id → 曲目表(只存取到了的)
)

// sodaAlbumTracks 取当前这首所在专辑的曲目表。
func sodaAlbumTracks(artist, title, album string) ([]albumTrack, bool) {
	albumID := sodaCurrentAlbumID(artist, title, album)
	if albumID == "" {
		return nil, false
	}
	sodaAlbumMu.Lock()
	if v, ok := sodaAlbumCache[albumID]; ok {
		sodaAlbumMu.Unlock()
		return v, true
	}
	sodaAlbumMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	page, err := sodaFetchAlbumPage(ctx, albumID)
	if err != nil {
		log.Printf("album prefetch: soda album %s page failed: %v", albumID, err)
		return nil, false
	}
	tracks := sodaParseAlbumPage(page, albumID)
	if len(tracks) == 0 {
		return nil, false
	}
	sodaAlbumMu.Lock()
	sodaAlbumCache[albumID] = tracks
	sodaAlbumMu.Unlock()
	log.Printf("album prefetch: %q from soda album %s (%d tracks)", album, albumID, len(tracks))
	return tracks, true
}

// sodaCurrentAlbumID 找当前这首的专辑 id,专辑名要对得上本地标签(宽松包含,同 albumTracks 的口径)。
func sodaCurrentAlbumID(artist, title, album string) string {
	if key := sodaLocalKey(artist, title); key != "" {
		sodaLocalMu.Lock()
		refreshSodaLocalIndexLocked()
		ents := append([]sodaLocalTrack(nil), sodaLocalIndex[key]...)
		sodaLocalMu.Unlock()
		if t, ok := pickSodaLocalEntry(ents, album, 0); ok && t.Album.ID != "" && sodaAlbumNameFits(t.Album.Name, album) {
			return t.Album.ID
		}
	}
	path := sodaPreloadPath()
	if path == "" {
		return ""
	}
	if st, err := os.Stat(path); err != nil || st.Size() > sodaPreloadMaxBytes {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	want := loosenEnrichKey(artist + "|" + title)
	for _, t := range parseSodaPreloads(raw) {
		if t.albumID != "" && loosenEnrichKey(t.upcoming.artist+"|"+t.upcoming.title) == want && sodaAlbumNameFits(t.upcoming.album, album) {
			return t.albumID
		}
	}
	return ""
}

func sodaAlbumNameFits(candidate, local string) bool {
	return local == "" || albumScore(candidate, local) >= 100
}

func sodaFetchAlbumPage(ctx context.Context, albumID string) ([]byte, error) {
	u := sodaAlbumPageBase + "?album_id=" + neturl.QueryEscape(albumID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", sodaUserAgent)
	resp, err := doHTTPTracked(&http.Client{Timeout: 10 * time.Second}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, sodaAlbumPageMaxBytes))
}

// sodaParseAlbumPage 从分享页 HTML 里取出曲目表。页面上的专辑 id 必须等于要的那个,否则不认。
func sodaParseAlbumPage(page []byte, albumID string) []albumTrack {
	marker := []byte("_ROUTER_DATA = ")
	i := bytes.Index(page, marker)
	if i < 0 {
		return nil
	}
	var data struct {
		LoaderData struct {
			AlbumPage struct {
				AlbumInfo struct {
					ID string `json:"id"`
				} `json:"albumInfo"`
				TrackList []struct {
					Name     string `json:"name"`
					Duration int64  `json:"duration"` // 毫秒
					Artists  []struct {
						Name string `json:"name"`
					} `json:"artists"`
				} `json:"trackList"`
			} `json:"album_page"`
		} `json:"loaderData"`
	}
	// 只解第一个 JSON 值,后面紧跟着的是页面脚本。
	if err := json.NewDecoder(bytes.NewReader(page[i+len(marker):])).Decode(&data); err != nil {
		return nil
	}
	ap := data.LoaderData.AlbumPage
	if ap.AlbumInfo.ID != albumID {
		return nil
	}
	tracks := make([]albumTrack, 0, len(ap.TrackList))
	for _, t := range ap.TrackList {
		names := make([]string, 0, len(t.Artists))
		for _, a := range t.Artists {
			if n := strings.TrimSpace(a.Name); n != "" {
				names = append(names, n)
			}
		}
		title := strings.TrimSpace(t.Name)
		if title == "" || len(names) == 0 {
			continue
		}
		// 歌手用 "/" 连起来,同 sodaUpcomingArtist。
		tracks = append(tracks, albumTrack{title: title, artist: strings.Join(names, "/"), duration: float64(t.Duration) / 1000})
	}
	return tracks
}
