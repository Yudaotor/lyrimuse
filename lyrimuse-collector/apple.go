// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

var (
	appleURLMu    sync.Mutex
	appleURLCache = map[string]appleMusicMatch{}
	// appleURLMissUntil:"这首歌 iTunes 确实没有"的负缓存,key 同 appleURLCache,
	// 值是重新开放查询的时刻。跟正缓存共用 appleURLMu。
	appleURLMissUntil = map[string]time.Time{}
)

// appleMatchMissTTL 是查空之后停查多久。
//
// 为什么需要它:appleMusicMatchCached 原来只在**查到**时写缓存,于是 iTunes 里没有的歌
// 每次调用都完整重跑一轮多商店搜索(appleStorefrontsFor 一次 2~4 个商店,加上按专辑名
// 精确定位那一轮)。实测本机 enrich 缓存 6123 条里有 2574 条(42%)没有 apple_music_url,
// 而 enrich 主链路上就有两个调用点、专辑预取一次还要再带 11~30 首 —— iTunes Search 因此
// 成了整个采集器打得最狠的端点(165169 次请求,98.4% 的失败是 403/429 限流)。
//
// 这是所有 Apple 相关路径里唯一一个查空后连内存都不记的:appleStorefrontArtistCache
// 记内存不落盘、appleStorefrontTitleCache 连盘一起记、appleCatalogCache 有自己的缓存。
//
// 取 30 分钟而不是永久:同 mbPrimaryNameCache / appleStorefrontArtistCache 的口径 ——
// 只留在内存、不落盘,重启就重试;窗口内也只是少一张封面和一条跳转链接,不影响歌词。
const appleMatchMissTTL = 30 * time.Minute

// appleMatchInMissWindow 报告这首歌是不是还在"iTunes 确实没有"的窗口里。
func appleMatchInMissWindow(key string, now time.Time) bool {
	appleURLMu.Lock()
	defer appleURLMu.Unlock()
	return now.Before(appleURLMissUntil[key])
}

// noteAppleMatchMiss 记下一次"问成了、但 Apple 确实没有这首歌"。
//
// reached 为假时**什么都不记**:那只是这次没问成(退避中/限流/超时),不是结论。
// iTunes Search 的失败有 98.4% 是限流,不做这道区分的话,一次限流就会把那段时间里
// 解析过的每一首歌都错记成"Apple 没有"。同一道区分见 musicbrainz.go 的 noteMBLookupFailure。
func noteAppleMatchMiss(key string, reached bool, now time.Time) {
	if !reached {
		return
	}
	appleURLMu.Lock()
	appleURLMissUntil[key] = now.Add(appleMatchMissTTL)
	appleURLMu.Unlock()
}

// appleMusicMatch 是这首歌在 iTunes/Apple Music 曲库里匹配到的信息——url 给"App
// 联动跳转链接"用,cover 是 Apple 官方封面,当作"搜索候选歌词"弹窗的通用封面兜底
// (见 enrich.go 的 fetchScoredLyricCandidatesStreaming):QQ/酷狗这两个歌词源的
// 接口本身没有可靠封面,而 iTunes Search 这个接口——不管歌曲原本是哪国语言,曲库
// 覆盖面都很全,实测中文流行曲目也能查到——本来就已经为了"Apple Music 跳转链接"
// 这个功能对几乎每首歌都查一遍,只是原来没把封面字段解析出来,不需要为了拿封面
// 单独多发一轮请求。
type appleMusicMatch struct {
	url, cover string
	// title/album:iTunes 曲库里实际匹配到的歌名/专辑名。透传——它是不与
	// 各歌词源共享曲库和搜歪模式之外的**独立**元数据,给下一轮"独立专辑互证"维度评测
	// 攒数据(search-lyrics CLI 的输出会带上),不参与本文件内的任何挑选逻辑。
	title, album string
	// durationSecs:加,给 searchcli.go 的"本地没有可信时长时,问 Apple 目录
	// 要一个"兜底用——见 runSearchLyricsCLI 里那段调用处的完整说明。
	durationSecs float64
}

// hiResArtwork 把 iTunes Search 默认给的 100x100 封面 URL 换成 1200x1200——mzstatic
// 这个 CDN 支持在 URL 里直接换尺寸段拿高清图,不需要另外调用其它接口,已用真实 URL
// 实测验证换尺寸后能正常访问。查不到"100x100"这个子串(理论上不会发生,防御性
// 处理)就原样返回,好歹还有张小图,不是没有。
//
// 1200:悬浮歌词窗口那张满幅封面卡是 820px(@2x,QQ 那次
// 修复时量出来的),600px 拉到 820px 是 1.37 倍放大,跟 QQ 音乐同样会模糊
// ——只是没人在 Apple 这条上报过。实测过 mzstatic
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
// (url 非空)时写缓存,所以"iTunes 没这首歌"的情形每次调用都会完整重跑一轮多商店搜索;
// 用在"有就带上"的纯透传字段上会把 search-lyrics 的收尾白白挂住几秒(审阅)。
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

	// 刚问过、Apple 确实没有 —— 窗口内不再重跑那一轮多商店搜索(见 appleMatchMissTTL)。
	if appleMatchInMissWindow(key, time.Now()) {
		return appleMusicMatch{}
	}

	m, reached := resolveAppleMusicMatch(ctx, artist, title, album)
	if m.url != "" {
		appleURLMu.Lock()
		appleURLCache[key] = m
		delete(appleURLMissUntil, key) // 查到了就把负缓存清掉
		appleURLMu.Unlock()
		return m
	}
	noteAppleMatchMiss(key, reached, time.Now())
	return m
}

// resolveAppleMusicMatch returns the Apple Music song match, disambiguated by
// album: the same song appears on many albums (originals, compilations, "This
// Is It"), so results[0] often points at the wrong album. Prefer title+album
// match, then title match, then first result. Which storefronts get asked
// comes from appleStorefrontsFor — CN first (user preference), then US, plus
// the script's home store when the tags are not Latin.
// 第二个返回值 reached 汇总两条路径("真的问到了 Apple 吗",见 itunesSearch 头注)。
// 只要有一步没问成就是 false —— appleMusicMatchCached 靠它区分"Apple 确实没有这首歌"
// 和"这次没问成",只有前者才配写进负缓存。
func resolveAppleMusicMatch(ctx context.Context, artist, title, album string) (appleMusicMatch, bool) {
	m, albumMatched, reached := searchAppleMusicMatch(ctx, artist, title, album)
	if albumMatched {
		return m, reached
	}
	// 走到这里说明全文搜索要么完全没查到,要么只查到一个**没有专辑证据**的标题匹配
	// (titleFallback)——先按专辑名精确定位试一次,比"没有专辑证据的第一个标题匹配"更
	// 可信:全文搜索排序会把这首歌在别的发行版(合辑/精选)上的版本排到前面,写词标题
	// (如 Prince "Partyup")也会被同名热门曲目挤出排名靠前的结果。
	//
	// 举例:方大同「Three Tour」全文搜索命中的是完全不相关的另一张合辑
	// 《EMO Market 心碎雜貨店》/《00s & 10s C-Pop》,而按专辑名能精确定位到真正的原专辑
	// 《橙月》——resolveAppleMusicMatchViaAlbum 内部还有一层"专辑对上但曲名对不上就退到
	// 专辑封面"的兜底(那张专辑自己把这首歌收录成繁体曲名「三人遊」,跟本地报的英文
	// 「Three Tour」对不上文字)。
	viaAlbum, viaReached := resolveAppleMusicMatchViaAlbum(ctx, artist, title, album)
	reached = reached && viaReached
	if viaAlbum.cover != "" || viaAlbum.url != "" {
		return viaAlbum, reached
	}
	// 按专辑定位也没查到任何东西——titleFallback 好歹是张图,好过没有(哪怕专辑可能不对)。
	return m, reached
}

// appleResultIdentityOK 判定一条 iTunes 结果能不能被当成**本曲**的匹配。
//
// 为什么必须有这道闸(jolle《danke für nichts》案):iTunes Search 对
// **本商店没有的歌**不会老实回空,而是回一批模糊命中的同名曲目。这首歌只在德区商店
// 上架,基线的 CN/US 两个商店都查不到(德语是拉丁字母,appleStorefrontsFor 那套按文字系统
// 扩展商店的机制对它不触发,所以这道闸才是本案唯一的防线),于是搜索回的是另一个歌手
// (Pie Kei)的同名单曲
// 《Danke für Nichts》;此前这里只校验曲名(looseContains)、歌手一项都不看,那条结果
// 就被整条链路当成了本曲的匹配。后果三层,一层比一层重:
//   - 「搜索候选歌词」弹窗的通用封面和 appleTitle/appleAlbum 显示的是别人的歌;
//   - Apple Music 跳转链接指向别人的歌;
//   - 最重的一条:searchcli.go 在本地没有可信时长时会拿 appleMusicMatch.durationSecs
//     兜底,于是把 Pie Kei 那首的 158.478s 当成本曲时长(真实 137.73s)喂进标题反查轮;
//     反查轮恰恰是靠时长在专辑曲目表里认"哪一首才是我们要的",于是认成同专辑里
//     158.97s 的《fingergun》,最终**把 fingergun 的歌词当成这首歌的候选返回、还给了
//     545 分**。已实测复现——错得理直气壮,比"查不到"糟得多。
//
// 判据不另造一套,直接复用各歌词源共用的那道歌手闸 lyricSourceArtistMatches:它已经
// 吃掉了"换分隔符 / 换合作者语言写法"这类跨平台署名分歧。这里判的是**身份**(封面给谁、
// 链接指向谁、时长信谁),所以只能用这道严格闸,绝不能退到 lyricRecordingTriangleMatches
// 那条放宽档——理由见该函数头注末尾那两条警告。
//
// 歌手对不上时留一条旁路:**专辑名归一后逐字相等**(albumScore>=200)也放行。它兜的是
// iTunes 自己按商店改写署名这个已知现象(同一首歌 CN 商店署"方大同"、US 商店署
// "Khalil Fong",appleStorefrontArtistIdentities 整套机制就是为它而存在)——署名写法可以
// 跨商店变,专辑名逐字相等则足以确认是同一张发行。 只认 200 那一档,**不接受
// albumScore=100 的宽松包含档**:包含档对短通用串几乎免检
// (lyricRecordingTriangleMatches 头注里记过实测——"周杰伦"正好是"周杰伦地表最强世界
// 巡回演唱会live"的子串),放进来等于这道闸白加。本案 Pie Kei 那条的专辑是
// 《Danke für Nichts - Single》、本地是《sunny side up/:down》,albumScore=0,两条都不成立。
//
// **已知边界**(实测清单见 TestAppleResultIdentityOKKnownBoundary):合作署名不用担心
// ——段集交集档只要有一段对上就放行,顺序颠倒 / 少写一位 / 其中一位换语言写法统统能过。
// 过不去的是**单人署名换了写法**:跨语言(宇多田ヒカル / Utada Hikaru)、艺名与本名
// (方大同 / Khalil Fong),以及用 "featuring" 这类 isArtistCreditSep 不认的连接词写的合作
// 署名。这类只能靠上面那条专辑旁路救回来;连专辑名也被商店本地化时就会被拦下,后果是这首歌
// 少一个 Apple 跳转链接 / 封面 / 时长兜底。这是**刻意选的**降级方向,沿用本文件原有的
// "better no link than a wrong-song link":拿到别人的歌会顺着时长兜底一路污染到歌词(上面
// 那个 fingergun 案),少一张封面不会。
//
// 两侧署名任一为空时放行:没有可比的署名就无从判定,拦下来只会把本来查得到的也一起丢掉
// (iTunes 一直在回 artistName,这是防御性分支)。
func appleResultIdentityOK(candidateArtist, candidateAlbum, localArtist, localAlbum string) bool {
	if strings.TrimSpace(localArtist) == "" || strings.TrimSpace(candidateArtist) == "" {
		return true
	}
	if lyricSourceArtistMatches(candidateArtist, localArtist) {
		return true
	}
	return albumScore(candidateAlbum, localAlbum) >= 200
}

// searchAppleMusicMatch 在 iTunes 全文搜索里找这首歌。第二个返回值标出这条结果是不是
// **有专辑证据**支撑的(albumScore>0)——调用方(resolveAppleMusicMatch)靠它判断要不要
// 再去按专辑名精确定位试一次:titleFallback 那种"完全没有专辑证据、只是标题对上的第一条"
// 太弱,专辑名一旦跟本地对不上就可能是完全不相关的另一个发行版,不该被当成终局结果。
//
// 第三个返回值 reached 透传 itunesSearch 那道"真的问到了 Apple 吗"(见它的头注)。
func searchAppleMusicMatch(ctx context.Context, artist, title, album string) (appleMusicMatch, bool, bool) {
	q := neturl.QueryEscape(artist + " " + title)
	var results []itunesResult
	// reached 要求**每一个**商店都问成了。只要有一个没问成,"Apple 没有这首歌"就不成立
	// —— 那首歌可能恰好只在没问成的那个商店上架。宁可多查一次,也不要记错负缓存。
	reached := true
	for _, country := range appleStorefrontsFor(artist, title, album) {
		rs, ok := itunesSearch(ctx, q, country)
		if !ok {
			reached = false
		}
		results = append(results, rs...)
	}
	m, albumMatched := pickAppleMusicMatch(results, artist, title, album)
	return m, albumMatched, reached
}

// pickAppleMusicMatch 是 searchAppleMusicMatch 的挑选逻辑,拆成纯函数好让上面那道身份闸
// 能被回归测试锁住(同 pickAppleTitleSearchIdentities / pickMusixmatchTrackRow 的先例)。
// results 按商店查询顺序拼接,所以"第一条标题匹配"仍然是 CN 优先,跟拆分之前一致。
func pickAppleMusicMatch(results []itunesResult, artist, title, album string) (appleMusicMatch, bool) {
	var titleFallback appleMusicMatch
	bestScore := 0
	var best appleMusicMatch
	for _, r := range results {
		if r.TrackViewURL == "" || !looseContains(r.TrackName, title) {
			continue // skip unrelated results (song may not be in this catalog)
		}
		// 同名不同人的闸:iTunes 对本商店没有的歌会回模糊命中,见 appleResultIdentityOK。
		if !appleResultIdentityOK(r.ArtistName, r.CollectionName, artist, album) {
			continue
		}
		if titleFallback.url == "" {
			titleFallback = appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000} // CN-first first title match
		}
		if sc := albumScore(r.CollectionName, album); sc > bestScore {
			bestScore, best = sc, appleMusicMatch{url: r.TrackViewURL, cover: hiResArtwork(r.ArtworkURL100), title: r.TrackName, album: r.CollectionName, durationSecs: r.TrackTimeMillis / 1000} // best album match
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
// 第二个返回值 reached 同 searchAppleMusicMatch:每个商店都问成了才是 true。
// album 为空时直接返回 true —— 那不是"没问成",是压根没有可问的。
func resolveAppleMusicMatchViaAlbum(ctx context.Context, artist, title, album string) (appleMusicMatch, bool) {
	if album == "" {
		return appleMusicMatch{}, true
	}
	q := neturl.QueryEscape(artist + " " + album)
	reached := true
	for _, country := range appleStorefrontsFor(artist, title, album) {
		bestID, bestScore := int64(0), 0
		var bestAlbumCover appleMusicMatch
		rs, ok := itunesSearch(ctx, q, country)
		if !ok {
			reached = false
		}
		for _, r := range rs {
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestID = sc, r.CollectionID
				bestAlbumCover = appleMusicMatch{cover: hiResArtwork(r.ArtworkURL100), album: r.CollectionName}
			}
		}
		if bestID == 0 {
			continue
		}
		// 同一道身份闸(见 appleResultIdentityOK):这张专辑是靠 albumScore 挑出来的,挑中的
		// 可能是**别人的同名专辑**,曲目表里再逐字对上曲名也还是别人的歌。bestScore>=200
		// (专辑名逐字相等)时闸门里那条专辑旁路天然成立、等于不拦——专辑既已精确定位,
		// 它的曲目表就是权威的,不该被署名写法的跨商店差异挡住。
		for _, t := range itunesLookupTracks(ctx, bestID, country) {
			if t.TrackViewURL != "" && looseContains(t.TrackName, title) && appleResultIdentityOK(t.ArtistName, t.CollectionName, artist, album) {
				return appleMusicMatch{url: t.TrackViewURL, cover: hiResArtwork(t.ArtworkURL100), title: t.TrackName, album: t.CollectionName, durationSecs: t.TrackTimeMillis / 1000}, reached
			}
		}
		// 专辑名已经精确对上(>=200,同 coverNeedsAlbumCheck 的"确信"门槛),但曲目表里
		// 找不到匹配的曲名——常见于这张专辑自己把这首歌收录成另一种文字的曲名(
		// 实测:方大同《橙月》专辑本身用繁体「三人遊」,本地报的是英文「Three Tour」,
		// 逐字比对天然对不上,而且不值得为了这类跨文字曲名比对引入翻译)。专辑名既然已经
		// 精确对上,这张专辑的封面就是可信的——同一张专辑的所有曲目共用同一张封面,不需要
		// 靠曲名再验一遍,好过因为曲名比不上就整条放弃、任由上面 searchAppleMusicMatch
		// 那个"没有专辑证据的第一个标题匹配"顶替成挂到别的发行版(合辑/精选)上的封面。
		// 只给 cover/album,不给 url:没找到这首歌具体的曲目页,不能假装有一个能跳转
		// 过去的链接。
		if bestScore >= 200 && bestAlbumCover.cover != "" {
			return bestAlbumCover, reached
		}
	}
	return appleMusicMatch{}, reached
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
		// CollectionName 补上:少了它,resolveAppleMusicMatchViaAlbum 返回的
		// appleMusicMatch.album 恒为空,而封面选源现在要拿它算 albumScore
		// (见 enrich.go 的 preferAppleCoverOverNetease)—— 空的话这条路径给出的封面
		// 会被当成"专辑不详"、白白错过一次本该顶替的机会。ArtistName/TrackTimeMillis
		// 同理(补,分别给 appleStorefrontArtistIdentities 和
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
	// ArtistName:加,给 appleStorefrontArtistIdentities 用——iTunes Search
	// 一直在回这个字段,这里之前一直没解码。见该函数头注。
	ArtistName string `json:"artistName"`
	// TrackTimeMillis:加,给 appleMusicMatch.durationSecs 用——同样是
	// iTunes Search 一直在回、之前没解码的字段。
	TrackTimeMillis float64 `json:"trackTimeMillis"`
	// ReleaseDate / CollectionArtistName:加,给 pickAppleAlbumHint 用 —— 挑"这首歌出自哪张
	// 专辑"时按发行日期取最早那张、并把群星合辑(collectionArtistName 是 Various Artists 之类、跟曲目
	// 署名不是一个人)排到后面。同样是 iTunes Search 一直在回、之前没解码的字段。
	ReleaseDate          string `json:"releaseDate"`
	CollectionArtistName string `json:"collectionArtistName"`
}

// ---- iTunes Search 的限流退避 ----
//
// 这个端点被打得最狠:实测一份日志里 155346 次请求、52.6% 失败,最近那段里 429 有 655 次、
// 403 有 546 次,远超其它任何源。而它**不受歌词源熔断管辖** —— lyricSourceForHost 的映射表
// 里没有 itunes.apple.com(返回 ""),observe 见到空源名直接 return,于是限流了也不退避,
// 继续猛打、越打越被限。
//
// 为什么不干脆把 itunes.apple.com 加进那张表:表里的 "applemusic" 是
// amp-api.music.apple.com 那条**歌词源**(要 media-user-token)。itunes.apple.com/search
// 是公开的目录检索,给专辑提示 / 封面 / storefront 标题反查 / 目录 id 用,跟歌词正文无关。
// 归到一起的话,目录检索被限流会把真正的 Apple Music 歌词源一起跳过 —— 拿外围补全的故障
// 去停掉一个能出歌词的源,不划算。
//
// 也不能按**主机**退避:同一个 host 上的 /lookup 端点实测 64 次请求 0 失败,健康得很,
// 不该被 /search 的限流连累。所以退避只挂在 /search 这一个端点上。
//
// 403 跟 429 一起算:实测这两个状态码交错出现(429 之后紧跟一串 403,同一波限流的两种表现),
// 不是 sourcebreaker 头注里说的那种"没有凭据的源被反爬 403"。但 403 不带 Retry-After,
// 所以用固定档,比 429 那条保守。
//
// 退避期间直接返回空切片 —— 这正是这个函数既有的失败语义(DNS 失败 / 超时 / ctx 取消统统
// 吞成空切片,见 albumhint.go 里那段注释),调用方本来就按"这次没查到"处理。代价也只落在
// 外围字段上:专辑提示、封面、标题反查,不会让哪首歌因此没有歌词。
var (
	itunesSearchMu             sync.Mutex
	itunesSearchCooldownUntil  time.Time
	itunesSearchCooldownLogged bool
)

// itunesSearchForbiddenCooldown 是 403 用的固定退避。403 不带 Retry-After,而 429 那条
// (parseLyricSourceRetryAfter)没给头时默认 1 分钟、封顶 5 分钟 —— 这里取更短的一档:
// 403 的证据比 429 弱,退避过头会让封面/专辑信息白白缺席。
const itunesSearchForbiddenCooldown = 30 * time.Second

// itunesSearchCoolingDown 报告现在是否还在退避窗口里。
func itunesSearchCoolingDown(now time.Time) bool {
	itunesSearchMu.Lock()
	defer itunesSearchMu.Unlock()
	return now.Before(itunesSearchCooldownUntil)
}

// noteITunesSearchStatus 按一次响应的状态码更新退避窗口。非限流状态码立即清掉窗口 ——
// 跟 lyricSourceBreaker 的 default 分支同一条规矩:拿到一次正常响应就说明限流过去了。
func noteITunesSearchStatus(status int, retryAfter string, now time.Time) {
// status 传 0 表示没拿到响应(超时 / 连不上),按 403 那一档退避:限流时这个端点也会
// 直接拖到超时,跟 403 一样拿不到 Retry-After。
	itunesSearchMu.Lock()
	defer itunesSearchMu.Unlock()
	switch status {
	case http.StatusTooManyRequests:
		itunesSearchCooldownUntil = now.Add(parseLyricSourceRetryAfter(retryAfter))
	case http.StatusForbidden:
		// 已经在更长的窗口里就别缩短它(429 给的 Retry-After 比这条固定档权威)。
		if until := now.Add(itunesSearchForbiddenCooldown); until.After(itunesSearchCooldownUntil) {
			itunesSearchCooldownUntil = until
		}
	default:
		itunesSearchCooldownUntil = time.Time{}
		itunesSearchCooldownLogged = false
		return
	}
	if !itunesSearchCooldownLogged {
		itunesSearchCooldownLogged = true
		log.Printf("apple: iTunes Search rate-limited (status=%d), backing off %s",
			status, time.Until(itunesSearchCooldownUntil).Round(time.Second))
	}
}

// itunesSearchBaseURL 只为单测可改 —— 让退避那条"在冷却窗口里根本不发请求"能被真的数出来
// (纯函数测不到这一步,变异测试实测:去掉 itunesSearch 开头那道检查,只测纯函数的用例照样全绿)。
var itunesSearchBaseURL = "https://itunes.apple.com/search"

// itunesSearch 的第二个返回值 reached 报告**这次真的问到了 Apple**(拿到 2xx 并解出了
// 响应体)。false 表示退避中 / 限流 / 超时 / DNS 失败 —— 此时空结果只说明"没问成",
// 绝不能读成"Apple 没有这首歌"。
//
// 这个区分是 appleMusicMatchCached 那条查空负缓存的前提:iTunes Search 的失败有
// 98.4% 是限流(403+429),不区分的话,一次限流会把那段时间里解析过的每一首歌都错记成
// "Apple 没有",在 TTL 内连封面和跳转链接一起丢掉。同一道区分在 MusicBrainz 那边也有
// (musicbrainz.go:err != nil 与 resolved 为空分开处置)。
//
// 不关心这个信号的调用方照旧忽略第二个返回值 —— 它们本来就按"查不到就算了"处理。
func itunesSearch(ctx context.Context, q, country string) ([]itunesResult, bool) {
	if itunesSearchCoolingDown(time.Now()) {
		return nil, false
	}
	cli := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		itunesSearchBaseURL+"?media=music&entity=song&limit=25&country="+country+"&term="+q, nil)
	if err != nil {
		return nil, false
	}
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	noteITunesSearchStatus(resp.StatusCode, resp.Header.Get("Retry-After"), time.Now())
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	var out struct {
		Results []itunesResult `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, false
	}
	return out.Results, true
}
