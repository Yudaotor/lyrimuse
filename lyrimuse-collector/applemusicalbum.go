package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Apple Music 的同专辑兜底:本地资料库里这张专辑不全(只收了其中几首)或者压根没收(从歌单、电台、
// 推荐里点开的目录内容)时,按目录锚点(applecatalog.go)拿到的专辑 id 去 Apple 目录取整张专辑的曲目表。
//
// 取法是两步,因为中国区的 iTunes lookup 不肯按专辑展开曲目(`lookup?id=<专辑>&entity=song&country=cn`
// 只回专辑本身,实测随手抽的 12 张全是 0 首),而按曲目 id 批量查是好的:
//
//  1. 在别的区(appleAlbumExpandStorefronts)展开这张专辑,只为拿曲目 id —— 目录 id 全球通用;
//  2. 拿这批 id 回中国区批量查,用中国区的歌名 / 歌手 / 时长。那是 Music.app 播到时报给系统的写法
//     (锚点也是在中国区查、再跟本地标签逐字核对过的),写进 enrich key 才对得上。
//
// 中国区下架的曲目第 2 步查不回来,自然就不在表里 —— 本来也播不到。只有这首带着已校验的目录锚点
// (本地导入的文件没有)才走这条;取不到返回 nil,资料库那份照旧能用。

// appleAlbumExpandStorefronts:展开专辑用的几个区,按顺序试到第一个展开得出来的。港台区收录华语
// 最全,美区覆盖欧美,日区补日韩。
var appleAlbumExpandStorefronts = []string{"us", "hk", "tw", "jp"}

// appleAlbumAnchorWait:换曲后等目录锚点就绪的上限。锚点第一次见到这首时要后台查一次目录,
// 下一轮 poll(5 秒)才写进索引,而专辑预取正好在换曲那一刻触发。单测置 0。
var appleAlbumAnchorWait = 12 * time.Second

var (
	appleAlbumMu    sync.Mutex
	appleAlbumCache = map[int64][]albumTrack{} // 目录专辑 id → 中国区曲目表(只存取到了的)
)

// appleMusicAlbumTracks 是 Apple Music 的同专辑曲目表:资料库里有的按资料库的写法,再补上目录里有、
// 资料库里没收的。
func appleMusicAlbumTracks(title, album string) ([]albumTrack, bool) {
	local, ok := albumTracksFromMusicApp(album)
	if !ok {
		local = nil
	}
	catalog := appleCatalogAlbumTracks(title, album)
	merged := mergeAlbumTracks(local, catalog)
	if len(catalog) > 0 && len(merged) > len(local) {
		log.Printf("album prefetch: %q adds %d tracks from the Apple catalog (%d in library)", album, len(merged)-len(local), len(local))
	}
	return merged, ok || len(catalog) > 0
}

// mergeAlbumTracks 以 primary 为准,把 extra 里歌名(宽松比较)还没出现过的追加在后面。
func mergeAlbumTracks(primary, extra []albumTrack) []albumTrack {
	seen := make(map[string]bool, len(primary))
	for _, t := range primary {
		seen[normLoose(t.title)] = true
	}
	out := primary
	for _, t := range extra {
		k := normLoose(t.title)
		if k == "" || seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, t)
	}
	return out
}

// appleCatalogAlbumTracks 等目录锚点给出专辑 id,再取这张专辑的中国区曲目表。取不到返回 nil。
func appleCatalogAlbumTracks(title, album string) []albumTrack {
	albumID, ok := appleCatalogAlbumIDFor(title, album)
	for deadline := time.Now().Add(appleAlbumAnchorWait); !ok && time.Now().Before(deadline); {
		time.Sleep(500 * time.Millisecond)
		albumID, ok = appleCatalogAlbumIDFor(title, album)
	}
	if !ok {
		return nil
	}
	appleAlbumMu.Lock()
	if v, hit := appleAlbumCache[albumID]; hit {
		appleAlbumMu.Unlock()
		return v
	}
	appleAlbumMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var ids []int64
	for _, sf := range appleAlbumExpandStorefronts {
		if ids = appleAlbumTrackIDs(ctx, albumID, sf); len(ids) > 0 {
			break
		}
	}
	if len(ids) == 0 {
		return nil
	}
	tracks := appleCatalogTracksByID(ctx, ids, "cn")
	if len(tracks) == 0 {
		return nil
	}
	appleAlbumMu.Lock()
	appleAlbumCache[albumID] = tracks
	appleAlbumMu.Unlock()
	return tracks
}

// appleITunesLookupItem 是 iTunes lookup 结果里这两步用得到的字段。
type appleITunesLookupItem struct {
	WrapperType     string  `json:"wrapperType"`
	Kind            string  `json:"kind"`
	TrackID         int64   `json:"trackId"`
	TrackName       string  `json:"trackName"`
	ArtistName      string  `json:"artistName"`
	TrackTimeMillis float64 `json:"trackTimeMillis"`
}

func appleITunesLookup(ctx context.Context, u string) []appleITunesLookupItem {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 5 * time.Second}, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []appleITunesLookupItem `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	return out.Results
}

// appleAlbumTrackIDs 在 storefront 区展开一张专辑,按接口给的顺序(碟、音轨号)返回曲目 id。只收歌曲(
// kind=song),把专辑里混的 MV、花絮挡掉,同 albumTracksFromMusicApp 的 `media kind is song`。
func appleAlbumTrackIDs(ctx context.Context, albumID int64, storefront string) []int64 {
	items := appleITunesLookup(ctx, fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&entity=song&limit=200&country=%s", albumID, storefront))
	var ids []int64
	for _, it := range items {
		if it.WrapperType == "track" && it.Kind == "song" && it.TrackID > 0 {
			ids = append(ids, it.TrackID)
		}
	}
	return ids
}

// appleCatalogTracksByID 按曲目 id 批量查 storefront 区的元数据,保持 ids 的顺序。
func appleCatalogTracksByID(ctx context.Context, ids []int64, storefront string) []albumTrack {
	byID := map[int64]appleITunesLookupItem{}
	const batch = 50
	for i := 0; i < len(ids); i += batch {
		end := min(i+batch, len(ids))
		parts := make([]string, 0, end-i)
		for _, id := range ids[i:end] {
			parts = append(parts, fmt.Sprint(id))
		}
		for _, it := range appleITunesLookup(ctx, "https://itunes.apple.com/lookup?country="+storefront+"&id="+strings.Join(parts, ",")) {
			if it.WrapperType == "track" && it.Kind == "song" {
				byID[it.TrackID] = it
			}
		}
	}
	tracks := make([]albumTrack, 0, len(byID))
	for _, id := range ids {
		it, ok := byID[id]
		if !ok || cleanMediaTag(it.TrackName) == "" {
			continue
		}
		tracks = append(tracks, albumTrack{
			title:    cleanMediaTag(it.TrackName),
			artist:   cleanMediaTag(it.ArtistName),
			duration: it.TrackTimeMillis / 1000,
		})
	}
	return tracks
}
