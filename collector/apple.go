// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"net/http"
	neturl "net/url"
	"sync"
	"time"
)

var (
	appleURLMu    sync.Mutex
	appleURLCache = map[string]string{}
)

// appleMusicURL returns the Apple Music page URL for a track via the public
// iTunes Search API (results[0].trackViewUrl points at the exact song). Cached
// per track; only successes are cached so a transient failure retries.
func appleMusicURL(artist, title, album string) string {
	if title == "" {
		return ""
	}
	key := artist + "|" + title + "|" + album
	appleURLMu.Lock()
	if v, ok := appleURLCache[key]; ok {
		appleURLMu.Unlock()
		return v
	}
	appleURLMu.Unlock()

	url := resolveAppleMusicURL(artist, title, album)
	if url != "" {
		appleURLMu.Lock()
		appleURLCache[key] = url
		appleURLMu.Unlock()
	}
	return url
}

// resolveAppleMusicURL returns the Apple Music song URL, disambiguated by album:
// the same song appears on many albums (originals, compilations, "This Is It"),
// so results[0] often points at the wrong album. Prefer title+album match, then
// title match, then first result. China store first (user preference), US fallback.
func resolveAppleMusicURL(artist, title, album string) string {
	if url := searchAppleMusicURL(artist, title, album); url != "" {
		return url
	}
	// 全文搜索有时找不到确实存在于目录里的曲目——连写词标题(如 Prince "Partyup")
	// 会被同名的其他热门曲目挤出排名靠前的结果,不管查询词怎么改写都搜不到。退而
	// 求其次:按专辑名找到专辑,拉专辑完整曲目表本地按标题匹配,绕开全文搜索排序。
	return resolveAppleMusicURLViaAlbum(artist, title, album)
}

func searchAppleMusicURL(artist, title, album string) string {
	q := neturl.QueryEscape(artist + " " + title)
	var titleFallback, bestURL string
	bestScore := 0
	for _, country := range []string{"CN", "US"} {
		for _, r := range itunesSearch(q, country) {
			if r.TrackViewURL == "" || !looseContains(r.TrackName, title) {
				continue // skip unrelated results (song may not be in this catalog)
			}
			if titleFallback == "" {
				titleFallback = r.TrackViewURL // CN-first first title match
			}
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestURL = sc, r.TrackViewURL // best album match
			}
		}
	}
	if bestURL != "" {
		return bestURL
	}
	// titleFallback ("" if the song isn't in the catalog): better no link than a
	// wrong-song link (iTunes returns fuzzy unrelated hits for missing songs).
	return titleFallback
}

// resolveAppleMusicURLViaAlbum finds the best-matching album by name via a
// song-entity search on "artist + album" (entity=album has the same relevance
// gap as entity=song and often can't find this album either — verified), pulls
// that album's full tracklist via iTunes lookup, and matches the title locally.
// A lookup by numeric collection ID isn't ranked/filtered, so it can't miss a
// track that genuinely exists in the catalog the way full-text search can.
func resolveAppleMusicURLViaAlbum(artist, title, album string) string {
	if album == "" {
		return ""
	}
	q := neturl.QueryEscape(artist + " " + album)
	for _, country := range []string{"CN", "US"} {
		bestID, bestScore := int64(0), 0
		for _, r := range itunesSearch(q, country) {
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestID = sc, r.CollectionID
			}
		}
		if bestID == 0 {
			continue
		}
		for _, t := range itunesLookupTracks(bestID, country) {
			if t.TrackViewURL != "" && looseContains(t.TrackName, title) {
				return t.TrackViewURL
			}
		}
	}
	return ""
}

// itunesLookupTracks returns the full tracklist of an album via the lookup
// endpoint (not full-text search, so no relevance-ranking gap). The album
// itself is also returned as a "collection" entry — filtered out here.
func itunesLookupTracks(collectionID int64, country string) []itunesResult {
	cli := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest(http.MethodGet,
		fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&entity=song&limit=50&country=%s", collectionID, country), nil)
	if err != nil {
		return nil
	}
	resp, err := cli.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []struct {
			WrapperType  string `json:"wrapperType"`
			TrackName    string `json:"trackName"`
			TrackViewURL string `json:"trackViewUrl"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	tracks := make([]itunesResult, 0, len(out.Results))
	for _, r := range out.Results {
		if r.WrapperType != "track" {
			continue
		}
		tracks = append(tracks, itunesResult{TrackName: r.TrackName, TrackViewURL: r.TrackViewURL})
	}
	return tracks
}

type itunesResult struct {
	TrackName      string `json:"trackName"`
	CollectionName string `json:"collectionName"`
	CollectionID   int64  `json:"collectionId"`
	TrackViewURL   string `json:"trackViewUrl"`
}

func itunesSearch(q, country string) []itunesResult {
	cli := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest(http.MethodGet,
		"https://itunes.apple.com/search?media=music&entity=song&limit=25&country="+country+"&term="+q, nil)
	if err != nil {
		return nil
	}
	resp, err := cli.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []itunesResult `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	return out.Results
}
