// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ytmusicLyric 是歌词第七个候选来源(2026-08-25 加,当天追问后收窄成只认 LyricFind)。
// YouTube Music 的歌词后端同时接了 Musixmatch 和 LyricFind 两家供应商——LyricFind 是
// 独立于现有六源(含 Musixmatch 本身)的另一家歌词版权方,接这一路的价值就在于它,不是
// "YouTube Music"这个平台本身。所以这份代码只在 timedLyricsData 的 sourceMessage 标注
// LyricFind 时才接受候选(见 resolveYTMusicLyric 末尾的 ytmusicIsLyricFindSource 那道闸)、
// 对外注册的**源名是 "lyricfind" 不是 "ytmusic"**(features.go 的 lyricSourceLyricFind)——
// 这份文件之所以还叫 ytmusic.go,是因为它描述的是"怎么从 YouTube Music 拿数据"这个检索
// 机制,跟 amllttml.go(文件按格式 TTML 命名、源叫 "amll")是同一种文件名≠源名的分工。
//
// 为什么要按 sourceMessage 过滤,不是"YouTube Music 查到什么就收什么":实测(见下面覆盖率
// 数据)YTM 命中的候选里 6/9 其实是 Musixmatch 换个管道重发,现有 musixmatch 源已经在直接
// 查它——① 打分层的"跨源正文共识"(contentConsensusPeers)按**来源数**算独立印证,这种
// 情况下两条候选文本高度相似却不是两个独立信源,会把置信度算高、是虚假加分;② 这部分
// 命中在 YouTube Music 这条链路(未公开协议、三跳请求、会过期的硬编码客户端版本号)上
// 纯粹是多担风险、零信息增量。过滤之后这一源名副其实:凡是叫 "lyricfind" 的候选,查到的
// 就真的是 LyricFind 的数据。
//
// 走的是 InnerTube——YouTube 内部用的私有协议,没有公开文档,`search`/`next`/`browse`
// 三个端点(见下面 resolveYTMusicLyric)全部**不需要登录/cookie**。参考实现是
// github.com/sigma67/ytmusicapi(Python,2959★,这个领域事实标准),但没有照抄它的库,
// 是逐字段读它的源码 + 自己发裸 HTTP 请求实测核实过一遍(2026-08-25)才落的这份实现,
// 下面每个端点/字段路径都是核实过的真实结构,不是照抄文档假设。
//
// ⚠️ 跟 amll-ttml-db/musixmatch 同一类风险:未公开协议,随时可能改结构或限流,没有 SLA。
// 这个仓库已经接过两个这一类的源(见 musixmatch.go/amllttml.go 头注),不是新引入一种
// 风险类别,是这类风险的第三个实例。
//
// 实测覆盖率(2026-08-25,用户曲库 9 首中/日/英抽样,过滤生效**之前**测的原始命中):
// 8/9 在 YTM 上有歌词,其中 2/9 是 LyricFind、6/9 是 Musixmatch(过滤生效后这 6/9 会
// 变成"这一源没查到",不再产出候选)。另外拿现有六源全部落空的曲目里最像"真的有歌词
// 只是没搜到"的 3 首去测,YTM 一首都没能补上(1 首 YTM 上确实标注"歌词不可用",2 首
// 因为曲名太泛被搜到完全不相关的曲目、连候选都没拿到)。也就是说这一路的边际价值
// 就是那 2/9 的 LyricFind 命中,不要指望它填补现有六源找不到的空白——那部分命中率是 0。
//
// 格式:只有**逐行**歌词(下面 ytmusicLyricLine 的 startMs/endMs,毫秒精度),没有逐字/
// 逐音节证据(2026-08-25 读 sigma67/ytmusicapi 的 LyricLine 模型 + 实测多首歌词证实,
// 一行就是一个整句字符串)。所以候选构造时不带 wordTimingYRC,跟 lrclib 同一个形状。
type ytmusicResult struct {
	lyrics, title, artist, album, cover string
	// durationSecs:搜索阶段从匹配到的曲目自己解析出的时长(秒),来自 flexColumn 里的
	// "m:ss" 文本(InnerTube 不直接给秒数,只给人类可读时长字符串,见 ytmusicParseDuration)。
	durationSecs float64
}

const (
	ytmusicDomain      = "https://music.youtube.com"
	ytmusicBaseAPI     = ytmusicDomain + "/youtubei/v1/"
	ytmusicHTTPTimeout = 6 * time.Second
	// 每个真实浏览器都会发的 UA——跟 musixmatch.go/amllttml.go 同一个理由:这是未公开的
	// 反爬接口,一个诚实的自定义 UA(比如 lrclib.go 那种"客户端名/版本号")在这类接口上
	// 只会被更容易拦,不是更礼貌。字符串跟 sigma67/ytmusicapi 的默认值一致——那是这个
	// 领域实测多年、被反复验证不会被拦的一个值,没有理由自己另编一个没验证过的。
	ytmusicUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"
	// filter=songs 的 search params——照抄 ytmusicapi get_search_params("songs", nil, false)
	// 的算法手算出这一个常量(filtered_param1"EgWKAQ" + filter_params["songs"]"II" +
	// "AWoMEA4QChADEAQQCRAF")。⚠️ **不能不传这个参数**:2026-08-25 实测坐实,不带过滤器
	// 的默认搜索"Top result"经常命中的是演唱会直拍/翻唱视频而不是录音室曲目(Taylor Swift
	// "Anti-Hero" 命中过一条 Eras Tour 现场版),那条视频往往没有歌词、或者歌词挂在错的
	// 版本上。加上这个过滤器之后同一批查询 20 条结果全部是 MUSIC_VIDEO_TYPE_ATV
	// (InnerTube 对"真·录音室曲目"的标记),没再命中过现场/翻唱。
	ytmusicSongsFilterParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
	// Web 客户端(搜索/取歌词 browseId 都走它)。clientVersion 按 UTC 日期自动生成,
	// 不需要手动跟着 YouTube Music 网页版更新——这是 ytmusicapi 的做法,日期串永远"够新"。
	ytmusicWebClientName = "WEB_REMIX"
	// **带时间戳**的歌词只有切成 Android 客户端身份才拿得到(ytmusicapi 原话"mobile
	// only",2026-08-25 实测坐实:同一个 browseId,WEB_REMIX 身份下 browse 只会返回
	// "Lyrics not available" 那条静态文案,换成 ANDROID_MUSIC 才会带 timedLyricsData)。
	// ⚠️ 已知的过期风险,跟 web 客户端不一样:这个版本号是**硬编码**的,不会随时间自动
	// "看起来永远最新"——真实 Android 客户端版本升级到足够新之后,这个值迟早会被服务端
	// 拒绝。这一路一旦开始整体失效(搜索/next 都正常、browse timed 总是 404 或不再返回
	// timedLyricsData),第一件事就是查 ytmusicapi 最新版这个常量有没有变,跟着更新。
	ytmusicMobileClientName    = "ANDROID_MUSIC"
	ytmusicMobileClientVersion = "7.21.50"
)

var (
	ytmusicMu    sync.Mutex
	ytmusicCache = map[string]ytmusicResult{} // artist|title|album -> result

	// ytmusicVisitorMu 只保护下面这一个值本身,不跨 I/O 持有。
	ytmusicVisitorMu sync.Mutex
	ytmusicVisitorID string

	// ytmusicVisitorFetchMu 是单飞锁:同一时刻只允许一个 goroutine 真的去抓 visitor id
	// (GET 首页 + 正则抠 JS 里的 VISITOR_DATA)。这个值理论上没有过期时间(ytmusicapi
	// 拿到一次就一直复用到进程退出,不会主动刷新),但抓取本身仍然是一次网络请求——批量
	// 解析(相册预取一次触发十几首歌并发)时如果每个 goroutine 各自判定"还没有就自己抓
	// 一次",会同时打十几个请求到 YouTube 首页。这个坑 2026-08-24 刚在 musixmatch 的
	// token 获取上踩过一次(见 musixmatch.go 的 musixmatchTokenFetchMu),这里从一开始
	// 就按同一个模式写,不重蹈一遍。
	ytmusicVisitorFetchMu sync.Mutex

	// ytmusicLastFailureMu/ytmusicLastFailureReason:诊断用的只读旁路
	// (2026-08-31,设置页"测试这个源"功能想知道 lyricfind 到底为什么没查到,不只是
	// "没查到"这个事实),跟 networkobs.go 的 networkLooksDown() 同一个思路——不改
	// ytmusicLyric 的返回值形状(自动解析路径从来不需要"为什么没查到"这个原因),只在
	// 抓 visitor id 这一步识别出具体原因时顺手记一句,给需要更具体诊断信息的调用方
	// (test-lyric-sources)读。识别不出具体原因时留空,调用方退回通用文案,不编一个
	// 没验证过的理由。
	ytmusicLastFailureMu     sync.Mutex
	ytmusicLastFailureReason string
)

func ytmusicSetLastFailureReason(reason string) {
	ytmusicLastFailureMu.Lock()
	ytmusicLastFailureReason = reason
	ytmusicLastFailureMu.Unlock()
}

// ytmusicLastFailureReasonNow 供 test-lyric-sources 用——本次进程里最近一次识别出的
// 具体失败原因,识别不出就是空串。
func ytmusicLastFailureReasonNow() string {
	ytmusicLastFailureMu.Lock()
	defer ytmusicLastFailureMu.Unlock()
	return ytmusicLastFailureReason
}

// ytmusicDoFetchVisitorID 是"真的去抓 visitor id"这一步,ytmusicEnsureVisitorID 在
// 单飞锁里调它。nil(默认)= 用真正的实现 ytmusicFetchVisitorID。声明成变量是给测试
// 留的缝,原因与用法跟 musixmatch.go 的 musixmatchDoFetchToken 一致(那边的头注解释了
// 为什么不能写成 `= func() string { return ytmusicFetchVisitorID() }` 这种直接初始化
// 的形式——会形成初始化环)。
var ytmusicDoFetchVisitorID func(ctx context.Context) string

func ytmusicCachedVisitorID() string {
	ytmusicVisitorMu.Lock()
	defer ytmusicVisitorMu.Unlock()
	return ytmusicVisitorID
}

func ytmusicEnsureVisitorID(ctx context.Context) string {
	if v := ytmusicCachedVisitorID(); v != "" {
		return v
	}
	ytmusicVisitorFetchMu.Lock()
	defer ytmusicVisitorFetchMu.Unlock()
	if v := ytmusicCachedVisitorID(); v != "" {
		return v
	}
	var v string
	if ytmusicDoFetchVisitorID != nil {
		v = ytmusicDoFetchVisitorID(ctx)
	} else {
		v = ytmusicFetchVisitorID(ctx)
	}
	if v != "" {
		ytmusicVisitorMu.Lock()
		ytmusicVisitorID = v
		ytmusicVisitorMu.Unlock()
	}
	return v
}

// ytmusicVisitorDataRe 抠 YouTube Music 首页内联的 `ytcfg.set({...})`,里面的
// VISITOR_DATA 字段就是后续所有请求都要带的 X-Goog-Visitor-Id。跟 ytmusicapi
// get_visitor_id 同一个正则,2026-08-25 实测核实过真的能从首页 HTML 里抠出来。
var ytmusicVisitorDataRe = regexp.MustCompile(`ytcfg\.set\s*\(\s*(\{.+?\})\s*\)\s*;`)

func ytmusicFetchVisitorID(ctx context.Context) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ytmusicDomain+"/", nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", ytmusicUserAgent)
	resp, err := doHTTPTracked(&http.Client{Timeout: 8 * time.Second}, req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return ""
	}
	html := string(body)
	v := ytmusicExtractVisitorID(html)
	if v == "" {
		// 2026-08-31 实测坐实的一种具体失败原因:YouTube Music 按 IP 地理位置限定可用
		// 区域,拿不到 VISITOR_DATA 时,首页返回的不是真正的首页,而是一个几 KB 的
		// 静态提示页("YouTube Music is not available in your area")——跟 youtube.com/
		// google.com 同时能正常访问对照过,不是整体网络问题,是这一个服务本身的地区限制。
		// 只在能确认这个具体原因时才记;识别不出来(比如页面结构改了、regex 该更新了)
		// 就留空,退回调用方的通用文案,不能猜一个没验证过的理由。
		if strings.Contains(strings.ToLower(html), "not available in your area") {
			ytmusicSetLastFailureReason("YouTube Music 在这个网络所在地区不可用（地区限制，非网络故障）")
		}
	}
	return v
}

// ytmusicExtractVisitorID 是纯函数,便于单测——正则匹配 + JSON 解码从首页 HTML 里
// 拿 visitor id,拿不到返回空串(调用方据此判断"这次没抓成,下次再试",不缓存空值)。
func ytmusicExtractVisitorID(html string) string {
	m := ytmusicVisitorDataRe.FindStringSubmatch(html)
	if len(m) < 2 {
		return ""
	}
	var cfg struct {
		VisitorData string `json:"VISITOR_DATA"`
	}
	if json.Unmarshal([]byte(m[1]), &cfg) != nil {
		return ""
	}
	return cfg.VisitorData
}

// ytmusicContext 是三个端点共用的 InnerTube "身份"字段。web 客户端(搜索/next/browse
// 不带时间戳)用日期版本号;取带时间戳的歌词时调用方传 ytmusicMobileClientName/Version
// 换成 Android 身份,见 ytmusicMobileClientVersion 的注释。
func ytmusicContext(clientName, clientVersion string) map[string]any {
	return map[string]any{
		"context": map[string]any{
			"client": map[string]any{"clientName": clientName, "clientVersion": clientVersion},
			"user":   map[string]any{},
		},
	}
}

func ytmusicWebClientVersion() string {
	return "1." + time.Now().UTC().Format("20060102") + ".01.00"
}

// ytmusicPost 是三个端点共用的请求执行。⚠️ 故意不设 Accept-Encoding:Go 的
// http.Transport 只在**自己**加上 `Accept-Encoding: gzip` 时才会透明解压响应体,
// 调用方一旦显式设置这个头就必须自己手动解压——2026-08-25 用真实裸 HTTP 请求测过,
// 不设这个头、让标准库全权处理,响应体拿到的就是解压好的干净 JSON,没有理由为了
// "看起来更像浏览器"去踩这个 Go 特有的坑。
func ytmusicPost(ctx context.Context, endpoint string, body map[string]any, visitorID string) ([]byte, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ytmusicBaseAPI+endpoint+"?alt=json", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", ytmusicUserAgent)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", ytmusicDomain)
	if visitorID != "" {
		req.Header.Set("X-Goog-Visitor-Id", visitorID)
	}
	resp, err := doHTTPTracked(&http.Client{Timeout: ytmusicHTTPTimeout}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil
	}
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}

// ---- ① search:歌名+歌手 → videoId ----

// ytmusicSearchItem 只挑了 search 响应里这一路真正用得上的字段(flexColumns 的两段
// 文字 = 歌名 / "歌手 • 专辑 • 时长"、封面缩略图、以及能确认"这是不是真录音室曲目"的
// musicVideoType + videoId)。2026-08-25 拿真实响应核实过这些字段路径,不是猜的。
type ytmusicSearchItem struct {
	MusicResponsiveListItemRenderer struct {
		FlexColumns []struct {
			MusicResponsiveListItemFlexColumnRenderer struct {
				Text struct {
					Runs []struct {
						Text string `json:"text"`
					} `json:"runs"`
				} `json:"text"`
			} `json:"musicResponsiveListItemFlexColumnRenderer"`
		} `json:"flexColumns"`
		Thumbnail struct {
			MusicThumbnailRenderer struct {
				Thumbnail struct {
					Thumbnails []struct {
						URL   string `json:"url"`
						Width int    `json:"width"`
					} `json:"thumbnails"`
				} `json:"thumbnail"`
			} `json:"musicThumbnailRenderer"`
		} `json:"thumbnail"`
		Overlay struct {
			MusicItemThumbnailOverlayRenderer struct {
				Content struct {
					MusicPlayButtonRenderer struct {
						PlayNavigationEndpoint struct {
							WatchEndpoint struct {
								VideoID                            string `json:"videoId"`
								WatchEndpointMusicSupportedConfigs struct {
									WatchEndpointMusicConfig struct {
										MusicVideoType string `json:"musicVideoType"`
									} `json:"watchEndpointMusicConfig"`
								} `json:"watchEndpointMusicSupportedConfigs"`
							} `json:"watchEndpoint"`
						} `json:"playNavigationEndpoint"`
					} `json:"musicPlayButtonRenderer"`
				} `json:"content"`
			} `json:"musicItemThumbnailOverlayRenderer"`
		} `json:"overlay"`
	} `json:"musicResponsiveListItemRenderer"`
}

// ytmusicParsedSearchItem 是 ytmusicSearchItem 抽完字段之后的干净形状,给挑选逻辑用。
type ytmusicParsedSearchItem struct {
	videoID              string
	title, artist, album string
	durationSecs         float64
	cover                string
	isATV                bool // MUSIC_VIDEO_TYPE_ATV = InnerTube 标记的"真·录音室曲目"
}

// ytmusicParseSearchItem 是纯函数:把一条 search 结果解析成挑选逻辑要用的字段。
// flexColumns 第二段是 "歌手 • 专辑 • 时长" 用 " • "(U+2022)连起来的一行文字
// (2026-08-25 拿中/英/日三种语言的真实查询核实过这个分隔符和顺序一致),最后一段
// 是时长、去掉最后一段之后剩下的整体是专辑名、第一段是歌手 —— 多歌手合作时歌手名
// 本身也不含" • ",这个切法不会误切。
func ytmusicParseSearchItem(item ytmusicSearchItem) (ytmusicParsedSearchItem, bool) {
	r := item.MusicResponsiveListItemRenderer
	flex := r.FlexColumns
	if len(flex) < 2 {
		return ytmusicParsedSearchItem{}, false
	}
	joinRuns := func(i int) string {
		var b strings.Builder
		for _, run := range flex[i].MusicResponsiveListItemFlexColumnRenderer.Text.Runs {
			b.WriteString(run.Text)
		}
		return b.String()
	}
	title := joinRuns(0)
	parts := strings.Split(joinRuns(1), " • ")
	if title == "" || len(parts) < 2 {
		return ytmusicParsedSearchItem{}, false
	}
	artist := parts[0]
	durationText := parts[len(parts)-1]
	album := strings.Join(parts[1:len(parts)-1], " • ")
	watch := r.Overlay.MusicItemThumbnailOverlayRenderer.Content.MusicPlayButtonRenderer.PlayNavigationEndpoint.WatchEndpoint
	videoID := watch.VideoID
	if videoID == "" {
		return ytmusicParsedSearchItem{}, false
	}
	var cover string
	thumbs := r.Thumbnail.MusicThumbnailRenderer.Thumbnail.Thumbnails
	for _, t := range thumbs {
		if cover == "" || t.Width > 0 {
			cover = t.URL
		}
	}
	return ytmusicParsedSearchItem{
		videoID:      videoID,
		title:        title,
		artist:       artist,
		album:        album,
		durationSecs: ytmusicParseDurationText(durationText),
		cover:        cover,
		isATV:        watch.WatchEndpointMusicSupportedConfigs.WatchEndpointMusicConfig.MusicVideoType == "MUSIC_VIDEO_TYPE_ATV",
	}, true
}

// ytmusicParseDurationText 把 "3:21" / "1:02:03" 解析成秒数,解析不动返回 0
// (0 = "该项不参与打分",跟别的源自报时长的约定一致)。
func ytmusicParseDurationText(s string) float64 {
	segs := strings.Split(strings.TrimSpace(s), ":")
	if len(segs) < 2 || len(segs) > 3 {
		return 0
	}
	var total float64
	for _, seg := range segs {
		n, err := strconv.Atoi(seg)
		if err != nil || n < 0 {
			return 0
		}
		total = total*60 + float64(n)
	}
	return total
}

// ytmusicSearchDurationTolerance 跟 lrclibSearchDurationTolerance/scoreLyricCandidate
// 的时长闸门取同一个值——挑一个下游注定会因为时长对不上而丢弃的候选毫无意义。
const ytmusicSearchDurationTolerance = 0.25

// ytmusicPickSearchItem 从解析好的候选里挑一个,挑不出返回 ok=false。纯函数,便于单测。
//
// 三道门,顺序无关但都必须过(跟 pickLRCLIBSearchResult 同一套判定,复用 match.go 的
// 共用函数——版本限定词/歌名/歌手判定不该每个源各写一份):
// ① 曲名要对得上(lyricTitleAccepted);② 歌手要对得上(lyricSourceArtistMatches);
// ③ 版本限定词不能相反(versionTagsMismatch)。
//
// 过门之后优先选 isATV(真录音室曲目,过滤掉现场/翻唱视频误配);再按时长挑最接近的,
// 本地时长未知时退回"第一个过门的"。
func ytmusicPickSearchItem(items []ytmusicParsedSearchItem, artist, title, album string, durationSecs float64) (ytmusicParsedSearchItem, bool) {
	var best ytmusicParsedSearchItem
	found := false
	bestDiff := -1.0
	bestATV := false
	for _, it := range items {
		if !lyricTitleAccepted(it.title, title) || !lyricSourceArtistMatches(it.artist, artist) {
			continue
		}
		if versionTagsMismatch(title, album, it.title, it.album) {
			continue
		}
		if !found {
			best, found, bestATV = it, true, it.isATV
			if durationSecs > 0 && it.durationSecs > 0 {
				bestDiff = mathAbs(it.durationSecs-durationSecs) / durationSecs
			}
			continue
		}
		// 已经选中的是真录音室曲目、这条不是 → 不换(ATV 优先级最高)。
		if bestATV && !it.isATV {
			continue
		}
		promote := it.isATV && !bestATV
		if !promote && durationSecs > 0 && it.durationSecs > 0 {
			diff := mathAbs(it.durationSecs-durationSecs) / durationSecs
			if diff > ytmusicSearchDurationTolerance {
				continue
			}
			if bestDiff < 0 || diff < bestDiff {
				promote, bestDiff = true, diff
			}
		}
		if promote {
			best, bestATV = it, it.isATV
		}
	}
	return best, found
}

// mathAbs 避免只为一个 float64 绝对值就多 import 一次 "math"(match.go 已经 import 了
// math,但这个文件独立成一个源码文件、没有共享 import 别名的必要)。
func mathAbs(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

func ytmusicSearchSong(ctx context.Context, artist, title, album string, durationSecs float64, visitorID string) (ytmusicParsedSearchItem, bool) {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	body["query"] = strings.TrimSpace(artist + " " + title)
	body["params"] = ytmusicSongsFilterParams
	raw, err := ytmusicPost(ctx, "search", body, visitorID)
	if err != nil || len(raw) == 0 {
		return ytmusicParsedSearchItem{}, false
	}
	items := ytmusicExtractSearchItems(raw)
	if len(items) == 0 {
		return ytmusicParsedSearchItem{}, false
	}
	var parsed []ytmusicParsedSearchItem
	for _, it := range items {
		if p, ok := ytmusicParseSearchItem(it); ok {
			parsed = append(parsed, p)
		}
	}
	return ytmusicPickSearchItem(parsed, artist, title, album, durationSecs)
}

// ytmusicExtractSearchItems 从整份 search 响应里摘出 musicResponsiveListItemRenderer
// 数组。用通用递归查找而不是硬编码 tabs[0].tabRenderer.content... 这条深路径——
// InnerTube 是没有文档的私有协议,这条路径 2026-08-25 实测是这个形状,但 amll/musixmatch
// 的头注都记录过同类接口"结构说变就变"的先例(见 amllttml.go/musixmatch.go),按key名
// 找比按精确路径导航更能扛住这类结构调整。
func ytmusicExtractSearchItems(raw []byte) []ytmusicSearchItem {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return nil
	}
	var items []ytmusicSearchItem
	ytmusicWalkJSON(tree, func(node map[string]any) {
		v, ok := node["musicResponsiveListItemRenderer"]
		if !ok {
			return
		}
		b, err := json.Marshal(map[string]any{"musicResponsiveListItemRenderer": v})
		if err != nil {
			return
		}
		var item ytmusicSearchItem
		if json.Unmarshal(b, &item) == nil {
			items = append(items, item)
		}
	})
	return items
}

// ytmusicWalkJSON 是 encoding/json 解到 any 之后的通用递归遍历,对每个 map 节点调
// visit 一次。三个端点(search/next/browse)全部靠这个函数按 key 名字定位数据,
// 不硬编码完整路径——理由见 ytmusicExtractSearchItems 的注释。
func ytmusicWalkJSON(node any, visit func(map[string]any)) {
	switch v := node.(type) {
	case map[string]any:
		visit(v)
		for _, child := range v {
			ytmusicWalkJSON(child, visit)
		}
	case []any:
		for _, child := range v {
			ytmusicWalkJSON(child, visit)
		}
	}
}

// ---- ② next:videoId → 歌词的 browseId ----

// ytmusicLyricsBrowseID 从 "next"(播放这首歌时 YouTube Music 侧边栏那套 tab 列表,
// ytmusicapi 叫 get_watch_playlist)的响应里找 pageType 是
// MUSIC_PAGE_TYPE_TRACK_LYRICS 的那个 tab,取它的 browseId——这首歌没有歌词 tab
// 时(纯音乐/太冷门)返回空串。纯函数,便于单测。
func ytmusicLyricsBrowseID(raw []byte) string {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return ""
	}
	var browseID string
	ytmusicWalkJSON(tree, func(node map[string]any) {
		if browseID != "" {
			return
		}
		be, ok := node["browseEndpoint"].(map[string]any)
		if !ok {
			return
		}
		id, _ := be["browseId"].(string)
		if id == "" {
			return
		}
		cfg, _ := be["browseEndpointContextSupportedConfigs"].(map[string]any)
		musicCfg, _ := cfg["browseEndpointContextMusicConfig"].(map[string]any)
		pageType, _ := musicCfg["pageType"].(string)
		if pageType == "MUSIC_PAGE_TYPE_TRACK_LYRICS" {
			browseID = id
		}
	})
	return browseID
}

func ytmusicFetchLyricsBrowseID(ctx context.Context, videoID, visitorID string) string {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	body["videoId"] = videoID
	body["playlistId"] = "RDAMVM" + videoID
	body["enablePersistentPlaylistPanel"] = true
	body["isAudioOnly"] = true
	body["tunerSettingValue"] = "AUTOMIX_SETTING_NORMAL"
	body["watchEndpointMusicSupportedConfigs"] = map[string]any{
		"watchEndpointMusicConfig": map[string]any{
			"hasPersistentPlaylistPanel": true,
			"musicVideoType":             "MUSIC_VIDEO_TYPE_ATV",
		},
	}
	raw, err := ytmusicPost(ctx, "next", body, visitorID)
	if err != nil || len(raw) == 0 {
		return ""
	}
	return ytmusicLyricsBrowseID(raw)
}

// ---- ③ browse:browseId → 带时间戳的逐行歌词 ----

// ytmusicLyricLine 是一行歌词(毫秒精度),字段来自 timedLyricsData 数组元素的
// lyricLine/cueRange.{start,end}TimeMilliseconds(2026-08-25 拿真实响应核实过,
// 两个时间戳在原始 JSON 里是**字符串**,不是数字)。
type ytmusicLyricLine struct {
	text           string
	startMs, endMs int
}

// ytmusicParseTimedLyrics 从 "browse"(ANDROID_MUSIC 身份)响应里摘出逐行歌词 +
// 来源标注(形如 "Source: LyricFind"/"Source: Musixmatch")。这首歌没有带时间戳的
// 歌词时(WEB_REMIX 身份下这个 tab 存在,但真正查询仍会回"Lyrics not available"—
// 见文件头注)返回空切片。纯函数,便于单测。
func ytmusicParseTimedLyrics(raw []byte) ([]ytmusicLyricLine, string) {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return nil, ""
	}
	var lines []ytmusicLyricLine
	var source string
	ytmusicWalkJSON(tree, func(node map[string]any) {
		if lines != nil {
			return
		}
		raw, ok := node["timedLyricsData"].([]any)
		if !ok || len(raw) == 0 {
			return
		}
		var parsed []ytmusicLyricLine
		for _, entry := range raw {
			e, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			text, _ := e["lyricLine"].(string)
			cue, _ := e["cueRange"].(map[string]any)
			startStr, _ := cue["startTimeMilliseconds"].(string)
			endStr, _ := cue["endTimeMilliseconds"].(string)
			start, errS := strconv.Atoi(startStr)
			end, errE := strconv.Atoi(endStr)
			if errS != nil || errE != nil || end < start {
				continue
			}
			parsed = append(parsed, ytmusicLyricLine{text: text, startMs: start, endMs: end})
		}
		if len(parsed) == 0 {
			return
		}
		lines = parsed
		if s, ok := node["sourceMessage"].(string); ok {
			source = s
		}
	})
	return lines, source
}

// ytmusicBuildLRC 把逐行歌词拼成这个项目通用的逐行 LRC 文本(每行 `[mm:ss.cc]文本`),
// 复用 amllttml.go 已经在用的 formatLRCTime,不重新实现一遍时间戳格式化。
// 空文本行原样保留(YouTube 的开头占位行常是 "♪",如实透传,不替换/不过滤——如实展示
// 是这个仓库对所有源的一贯做法,见 lyricCandidate.title 字段注释那类先例)。
func ytmusicBuildLRC(lines []ytmusicLyricLine) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(formatLRCTime(l.startMs))
		b.WriteString(l.text)
		b.WriteString("\n")
	}
	return b.String()
}

func ytmusicFetchTimedLyrics(ctx context.Context, browseID, visitorID string) (string, string) {
	body := ytmusicContext(ytmusicMobileClientName, ytmusicMobileClientVersion)
	body["browseId"] = browseID
	raw, err := ytmusicPost(ctx, "browse", body, visitorID)
	if err != nil || len(raw) == 0 {
		return "", ""
	}
	lines, source := ytmusicParseTimedLyrics(raw)
	if len(lines) == 0 {
		return "", ""
	}
	return ytmusicBuildLRC(lines), source
}

// ---- 对外入口 ----

func ytmusicLyric(ctx context.Context, artist, title, album string, durationSecs float64) ytmusicResult {
	if title == "" {
		return ytmusicResult{}
	}
	key := artist + "|" + title + "|" + album
	ytmusicMu.Lock()
	if v, ok := ytmusicCache[key]; ok {
		ytmusicMu.Unlock()
		return v
	}
	ytmusicMu.Unlock()

	r := resolveYTMusicLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" {
		ytmusicMu.Lock()
		ytmusicCache[key] = r
		ytmusicMu.Unlock()
	}
	return r
}

// resolveYTMusicLyric 三跳:① search 拿 videoId(带 songs 过滤器,见
// ytmusicSongsFilterParams);② next 拿这首歌"歌词" tab 的 browseId(这首歌没有
// 歌词 tab 就直接放弃,省一次请求);③ browse(切到 Android 客户端身份)拿带时间戳的
// 逐行歌词,并且**只在 sourceMessage 标注 LyricFind 时才接受**(ytmusicIsLyricFindSource,
// 理由见文件头注)——查到的是 Musixmatch 换个管道重发时,当"这一源没查到"处理。
//
// ⚠️ 刻意**不**另外调一次"不带时间戳"的 browse:这个项目的引擎只认真的带时间戳的
// 逐行 LRC(isTimedLRC 要求至少 3 行、过半带 [mm:ss.xx]),纯文本歌词对它毫无用处,
// 调这一路纯属浪费一次网络请求和这首歌 20 秒搜索预算里的时间。
//
// 超时预算:visitor id 首次冷启动 8s(全进程只发生一次,后续调用直接复用缓存值)+
// search/next/browse 各 6s = 最坏 18~26s。跟 lrclib.go 同一个"串行三级、卡进 enrich
// 20s 硬截止"的约束,但**只有第一次冷启动**会摸到上限——多数调用只有后三跳的 18s。
func resolveYTMusicLyric(ctx context.Context, artist, title, album string, durationSecs float64) ytmusicResult {
	visitorID := ytmusicEnsureVisitorID(ctx)
	if visitorID == "" {
		return ytmusicResult{}
	}
	item, ok := ytmusicSearchSong(ctx, artist, title, album, durationSecs, visitorID)
	if !ok {
		return ytmusicResult{}
	}
	browseID := ytmusicFetchLyricsBrowseID(ctx, item.videoID, visitorID)
	if browseID == "" {
		return ytmusicResult{}
	}
	lrc, source := ytmusicFetchTimedLyrics(ctx, browseID, visitorID)
	if !isTimedLRC(lrc) {
		return ytmusicResult{}
	}
	// ⚠️ 2026-08-25 用户追问坐实:只在真是 LyricFind 时才接受这份候选,是 Musixmatch
	// 换个管道重发的一律当"这一源没查到"。理由是两件事的叠加:
	//   ① 打分层的"跨源正文共识"(contentConsensusPeers)按**来源数**算独立印证——
	//      如果这份其实是 Musixmatch 的内容,而现有 musixmatch 源也查到了同一首歌,
	//      两条候选文本大概率高度相似,却不是两个独立信源,是同一份数据走了两条管道。
	//      当成两个源互相印证会把置信度算高,是虚假的加分。
	//   ② 6/9 的实测命中就是这种"重复重发"(见 ytmusicLyric 文档注释里的覆盖率数据),
	//      这部分我们已经有更直接的 musixmatch 源在查,YouTube Music 那条链路(未公开
	//      协议、三跳请求、会过期的硬编码客户端版本号)在这些歌上纯粹是多担风险、
	//      零信息增量——接这个源的理由从一开始就只是"能拿到 Musixmatch 之外的真数据",
	//      过滤掉之后这条理由才真正站得住,也是下面把 source 从 "ytmusic" 改成
	//      "lyricfind" 的前提(过滤前这一路名不副实——不是每次查到的都是 LyricFind)。
	if !ytmusicIsLyricFindSource(source) {
		return ytmusicResult{}
	}
	return ytmusicResult{
		lyrics: lrc, title: item.title, artist: item.artist, album: item.album,
		durationSecs: item.durationSecs, cover: item.cover,
	}
}

// ytmusicIsLyricFindSource 判断 timedLyricsData 的 sourceMessage 是不是标注了
// LyricFind(观察到的真实取值形如 "Source: LyricFind" / "Source: Musixmatch")。
// 纯函数,便于单测;大小写不敏感只是防御性写法,实测两个取值大小写固定,没见过变体。
func ytmusicIsLyricFindSource(source string) bool {
	return strings.Contains(strings.ToLower(source), "lyricfind")
}
