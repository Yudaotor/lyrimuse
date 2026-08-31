// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
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
	// durationSecs:2026-08-30 加,给 searchcli.go 的"本地没有可信时长时,问 Apple 目录
	// 要一个"兜底用——见 runSearchLyricsCLI 里那段调用处的完整说明。
	durationSecs float64
}

// hiResArtwork 把 iTunes Search 默认给的 100x100 封面 URL 换成 1200x1200——mzstatic
// 这个 CDN 支持在 URL 里直接换尺寸段拿高清图,不需要另外调用其它接口,已用真实 URL
// 实测验证换尺寸后能正常访问。查不到"100x100"这个子串(理论上不会发生,防御性
// 处理)就原样返回,好歹还有张小图,不是没有。
//
// 2026-08-28 从 600 提到 1200:悬浮歌词窗口那张满幅封面卡是 820px(@2x,QQ 那次
// 2026-08-24 修复时量出来的),600px 拉到 820px 是 1.37 倍放大,跟 QQ 音乐当初被
// 用户报"很模糊"那次同一个问题——只是没人在 Apple 这条上报过。实测过 mzstatic
// 这个 CDN 对同一张封面 600/1000/1200/2000/3000 全部原样给图(文件大小随分辨率
// 同步涨,不是被裁剪成同一张),天花板至少到 3000,选 1200 是留出黑胶模式/背景
// 模糊这类会把封面放得更大的场景的余量,不是这个 CDN 的实际上限。
func hiResArtwork(url string) string {
	if url == "" {
		return ""
	}
	return strings.Replace(url, "100x100bb", "1200x1200bb", 1)
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

func appleMusicMatchCached(ctx context.Context, artist, title, album string) appleMusicMatch {
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

	m := resolveAppleMusicMatch(ctx, artist, title, album)
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
func resolveAppleMusicMatch(ctx context.Context, artist, title, album string) appleMusicMatch {
	m, albumMatched := searchAppleMusicMatch(ctx, artist, title, album)
	if albumMatched {
		return m
	}
	// 走到这里说明全文搜索要么完全没查到,要么只查到一个**没有专辑证据**的标题匹配
	// (titleFallback)——先按专辑名精确定位试一次,比"没有专辑证据的第一个标题匹配"更
	// 可信:全文搜索排序会把这首歌在别的发行版(合辑/精选)上的版本排到前面,写词标题
	// (如 Prince "Partyup")也会被同名热门曲目挤出排名靠前的结果。
	//
	// 2026-08-28 实测坐实:方大同「Three Tour」全文搜索命中的是完全不相关的另一张合辑
	// 《EMO Market 心碎雜貨店》/《00s & 10s C-Pop》,而按专辑名能精确定位到真正的原专辑
	// 《橙月》——resolveAppleMusicMatchViaAlbum 内部还有一层"专辑对上但曲名对不上就退到
	// 专辑封面"的兜底(那张专辑自己把这首歌收录成繁体曲名「三人遊」,跟本地报的英文
	// 「Three Tour」对不上文字)。
	if viaAlbum := resolveAppleMusicMatchViaAlbum(ctx, artist, title, album); viaAlbum.cover != "" || viaAlbum.url != "" {
		return viaAlbum
	}
	// 按专辑定位也没查到任何东西——titleFallback 好歹是张图,好过没有(哪怕专辑可能不对)。
	return m
}

// searchAppleMusicMatch 在 iTunes 全文搜索里找这首歌。第二个返回值标出这条结果是不是
// **有专辑证据**支撑的(albumScore>0)——调用方(resolveAppleMusicMatch)靠它判断要不要
// 再去按专辑名精确定位试一次:titleFallback 那种"完全没有专辑证据、只是标题对上的第一条"
// 太弱,专辑名一旦跟本地对不上就可能是完全不相关的另一个发行版,不该被当成终局结果。
func searchAppleMusicMatch(ctx context.Context, artist, title, album string) (appleMusicMatch, bool) {
	q := neturl.QueryEscape(artist + " " + title)
	var titleFallback appleMusicMatch
	bestScore := 0
	var best appleMusicMatch
	for _, country := range []string{"CN", "US"} {
		for _, r := range itunesSearch(ctx, q, country) {
			if r.TrackViewURL == "" || !looseContains(r.TrackName, title) {
				continue // skip unrelated results (song may not be in this catalog)
			}
			if titleFallback.url == "" {
				titleFallback = appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000} // CN-first first title match
			}
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, best = sc, appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000} // best album match
			}
		}
	}
	if best.url != "" {
		return best, true
	}
	// titleFallback (空 url 表示压根没查到) 而不是"没查到就报错":better no link
	// than a wrong-song link (iTunes returns fuzzy unrelated hits for missing songs)。
	return titleFallback, false
}

// resolveAppleMusicMatchViaAlbum finds the best-matching album by name via a
// song-entity search on "artist + album" (entity=album has the same relevance
// gap as entity=song and often can't find this album either — verified), pulls
// that album's full tracklist via iTunes lookup, and matches the title locally.
// A lookup by numeric collection ID isn't ranked/filtered, so it can't miss a
// track that genuinely exists in the catalog the way full-text search can.
func resolveAppleMusicMatchViaAlbum(ctx context.Context, artist, title, album string) appleMusicMatch {
	if album == "" {
		return appleMusicMatch{}
	}
	q := neturl.QueryEscape(artist + " " + album)
	for _, country := range []string{"CN", "US"} {
		bestID, bestScore := int64(0), 0
		var bestAlbumCover appleMusicMatch
		for _, r := range itunesSearch(ctx, q, country) {
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestID = sc, r.CollectionID
				bestAlbumCover = appleMusicMatch{cover: hiResArtwork(r.ArtworkURL100), album: r.CollectionName}
			}
		}
		if bestID == 0 {
			continue
		}
		for _, t := range itunesLookupTracks(ctx, bestID, country) {
			if t.TrackViewURL != "" && looseContains(t.TrackName, title) {
				return appleMusicMatch{url: t.TrackViewURL, cover: hiResArtwork(t.ArtworkURL100), title: t.TrackName, album: t.CollectionName, durationSecs: t.TrackTimeMillis / 1000}
			}
		}
		// 专辑名已经精确对上(>=200,同 coverNeedsAlbumCheck 的"确信"门槛),但曲目表里
		// 找不到匹配的曲名——常见于这张专辑自己把这首歌收录成另一种文字的曲名(2026-08-28
		// 实测:方大同《橙月》专辑本身用繁体「三人遊」,本地报的是英文「Three Tour」,
		// 逐字比对天然对不上,而且不值得为了这类跨文字曲名比对引入翻译)。专辑名既然已经
		// 精确对上,这张专辑的封面就是可信的——同一张专辑的所有曲目共用同一张封面,不需要
		// 靠曲名再验一遍,好过因为曲名比不上就整条放弃、任由上面 searchAppleMusicMatch
		// 那个"没有专辑证据的第一个标题匹配"顶替成挂到别的发行版(合辑/精选)上的封面。
		// ⚠️ 只给 cover/album,不给 url:没找到这首歌具体的曲目页,不能假装有一个能跳转
		// 过去的链接。
		if bestScore >= 200 && bestAlbumCover.cover != "" {
			return bestAlbumCover
		}
	}
	return appleMusicMatch{}
}

// itunesLookupTracks returns the full tracklist of an album via the lookup
// endpoint (not full-text search, so no relevance-ranking gap). The album
// itself is also returned as a "collection" entry — filtered out here.
func itunesLookupTracks(ctx context.Context, collectionID int64, country string) []itunesResult {
	cli := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&entity=song&limit=50&country=%s", collectionID, country), nil)
	if err != nil {
		return nil
	}
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Results []struct {
			WrapperType     string  `json:"wrapperType"`
			TrackName       string  `json:"trackName"`
			CollectionName  string  `json:"collectionName"`
			TrackViewURL    string  `json:"trackViewUrl"`
			ArtworkURL100   string  `json:"artworkUrl100"`
			ArtistName      string  `json:"artistName"`
			TrackTimeMillis float64 `json:"trackTimeMillis"`
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
		// 会被当成"专辑不详"、白白错过一次本该顶替的机会。ArtistName/TrackTimeMillis
		// 同理(2026-08-30 补,分别给 appleStorefrontArtistIdentities 和
		// appleMusicMatch.durationSecs 用)。
		tracks = append(tracks, itunesResult{
			TrackName: r.TrackName, CollectionName: r.CollectionName,
			TrackViewURL: r.TrackViewURL, ArtworkURL100: r.ArtworkURL100,
			ArtistName: r.ArtistName, TrackTimeMillis: r.TrackTimeMillis,
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
	// ArtistName:2026-08-30 加,给 appleStorefrontArtistIdentities 用——iTunes Search
	// 一直在回这个字段,这里之前一直没解码。见该函数头注。
	ArtistName string `json:"artistName"`
	// TrackTimeMillis:2026-08-30 加,给 appleMusicMatch.durationSecs 用——同样是
	// iTunes Search 一直在回、之前没解码的字段。
	TrackTimeMillis float64 `json:"trackTimeMillis"`
}

func itunesSearch(ctx context.Context, q, country string) []itunesResult {
	cli := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://itunes.apple.com/search?media=music&entity=song&limit=25&country="+country+"&term="+q, nil)
	if err != nil {
		return nil
	}
	resp, err := doHTTPTracked(cli, req)
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
