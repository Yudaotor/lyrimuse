// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

var (
	appleURLMu    sync.Mutex
	appleURLCache = map[string]appleMusicMatch{}
)

// appleMusicMatch 是这首歌在 iTunes/Apple Music 曲库里匹配到的信息——url 给"App
// 联动跳转链接"用,cover 是 Apple 官方封面,当作"搜索候选歌词"弹窗的通用封面兜底
// (见 enrich.go 的 fetchScoredLyricCandidatesStreaming):QQ/酷狗这两个歌词源的
// 接口本身没有可靠封面,而 iTunes Search 这个接口——不管歌曲原本是哪国语言,曲库
// 覆盖面都很全,实测中文流行曲目也能查到——本来就已经为了"Apple Music 跳转链接"
// 这个功能对几乎每首歌都查一遍,只是原来没把封面字段解析出来,不需要为了拿封面
// 单独多发一轮请求。
type appleMusicMatch struct {
	url, cover string
	// title/album:iTunes 曲库里实际匹配到的歌名/专辑名。2026-08-12 起透传——它是不与
	// 五个歌词源共享曲库和搜歪模式的**第六方**元数据,给下一轮"独立专辑互证"维度评测
	// 攒数据(search-lyrics CLI 的输出会带上),不参与本文件内的任何挑选逻辑。
	title, album string
}

// hiResArtwork 把 iTunes Search 默认给的 100x100 封面 URL 换成 600x600——mzstatic
// 这个 CDN 支持在 URL 里直接换尺寸段拿高清图,不需要另外调用其它接口,已用真实 URL
// 实测验证换尺寸后能正常访问。查不到"100x100"这个子串(理论上不会发生,防御性
// 处理)就原样返回,好歹还有张小图,不是没有。
func hiResArtwork(url string) string {
	if url == "" {
		return ""
	}
	return strings.Replace(url, "100x100bb", "600x600bb", 1)
}

// appleMusicMatchCached 按 artist|title|album 缓存 Apple Music/iTunes Search 的匹配
// 结果——url 给"App 跳转链接"用,cover 给封面(主封面兜底 + 搜索候选歌词的通用封面
// 兜底)用,不管哪个调用方先查到,其它调用方都直接命中缓存,不会重复发两遍 iTunes 请求。
// appleMusicMatchCachedOnly 只读缓存、绝不发请求。appleMusicMatchCached 只在查到
// (url 非空)时写缓存,所以"iTunes 没这首歌"的情形每次调用都会完整重跑一轮 CN+US 搜索;
// 用在"有就带上"的纯透传字段上会把 search-lyrics 的收尾白白挂住几秒(2026-08-12 审阅)。
func appleMusicMatchCachedOnly(artist, title, album string) appleMusicMatch {
	if title == "" {
		return appleMusicMatch{}
	}
	appleURLMu.Lock()
	defer appleURLMu.Unlock()
	return appleURLCache[artist+"|"+title+"|"+album]
}

func appleMusicMatchCached(artist, title, album string) appleMusicMatch {
	if title == "" {
		return appleMusicMatch{}
	}
	key := artist + "|" + title + "|" + album
	appleURLMu.Lock()
	if v, ok := appleURLCache[key]; ok {
		appleURLMu.Unlock()
		return v
	}
	appleURLMu.Unlock()

	m := resolveAppleMusicMatch(artist, title, album)
	if m.url != "" {
		appleURLMu.Lock()
		appleURLCache[key] = m
		appleURLMu.Unlock()
	}
	return m
}

// resolveAppleMusicMatch returns the Apple Music song match, disambiguated by
// album: the same song appears on many albums (originals, compilations, "This
// Is It"), so results[0] often points at the wrong album. Prefer title+album
// match, then title match, then first result. China store first (user
// preference), US fallback.
func resolveAppleMusicMatch(artist, title, album string) appleMusicMatch {
	if m := searchAppleMusicMatch(artist, title, album); m.url != "" {
		return m
	}
	// 全文搜索有时找不到确实存在于目录里的曲目——连写词标题(如 Prince "Partyup")
	// 会被同名的其他热门曲目挤出排名靠前的结果,不管查询词怎么改写都搜不到。退而
	// 求其次:按专辑名找到专辑,拉专辑完整曲目表本地按标题匹配,绕开全文搜索排序。
	return resolveAppleMusicMatchViaAlbum(artist, title, album)
}

func searchAppleMusicMatch(artist, title, album string) appleMusicMatch {
	q := neturl.QueryEscape(artist + " " + title)
	var titleFallback appleMusicMatch
	bestScore := 0
	var best appleMusicMatch
	for _, country := range []string{"CN", "US"} {
		for _, r := range itunesSearch(q, country) {
			if r.TrackViewURL == "" || !looseContains(r.TrackName, title) {
				continue // skip unrelated results (song may not be in this catalog)
			}
			if titleFallback.url == "" {
				titleFallback = appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName} // CN-first first title match
			}
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, best = sc, appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName} // best album match
			}
		}
	}
	if best.url != "" {
		return best
	}
	// titleFallback (空 url 表示压根没查到) 而不是"没查到就报错":better no link
	// than a wrong-song link (iTunes returns fuzzy unrelated hits for missing songs)。
	return titleFallback
}

// resolveAppleMusicMatchViaAlbum finds the best-matching album by name via a
// song-entity search on "artist + album" (entity=album has the same relevance
// gap as entity=song and often can't find this album either — verified), pulls
// that album's full tracklist via iTunes lookup, and matches the title locally.
// A lookup by numeric collection ID isn't ranked/filtered, so it can't miss a
// track that genuinely exists in the catalog the way full-text search can.
func resolveAppleMusicMatchViaAlbum(artist, title, album string) appleMusicMatch {
	if album == "" {
		return appleMusicMatch{}
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
				return appleMusicMatch{url: t.TrackViewURL, cover: hiResArtwork(t.ArtworkURL100), title: t.TrackName, album: t.CollectionName}
			}
		}
	}
	return appleMusicMatch{}
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
			WrapperType    string `json:"wrapperType"`
			TrackName      string `json:"trackName"`
			CollectionName string `json:"collectionName"`
			TrackViewURL   string `json:"trackViewUrl"`
			ArtworkURL100  string `json:"artworkUrl100"`
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
		// CollectionName 2026-08-20 补上:少了它,resolveAppleMusicMatchViaAlbum 返回的
		// appleMusicMatch.album 恒为空,而封面选源现在要拿它算 albumScore
		// (见 enrich.go 的 preferAppleCoverOverNetease)—— 空的话这条路径给出的封面
		// 会被当成"专辑不详"、白白错过一次本该顶替的机会。
		tracks = append(tracks, itunesResult{
			TrackName: r.TrackName, CollectionName: r.CollectionName,
			TrackViewURL: r.TrackViewURL, ArtworkURL100: r.ArtworkURL100,
		})
	}
	return tracks
}

type itunesResult struct {
	TrackName      string `json:"trackName"`
	CollectionName string `json:"collectionName"`
	CollectionID   int64  `json:"collectionId"`
	TrackViewURL   string `json:"trackViewUrl"`
	ArtworkURL100  string `json:"artworkUrl100"`
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
