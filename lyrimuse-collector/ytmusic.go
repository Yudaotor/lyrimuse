package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ytmusicLyric 是歌词第七个候选来源(加,当天追问后收窄成只认 LyricFind)。
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
// github.com/sigma67/ytmusicapi(Python,2959 星,这个领域事实标准),但没有照抄它的库,
// 是逐字段读它的源码 + 自己发裸 HTTP 请求实测核实过一遍才落的这份实现,
// 下面每个端点/字段路径都是核实过的真实结构,不是照抄文档假设。
//
// 跟 amll-ttml-db/musixmatch 同一类风险:未公开协议,随时可能改结构或限流,没有 SLA。
// 这个仓库已经接过两个这一类的源(见 musixmatch.go/amllttml.go 头注),不是新引入一种
// 风险类别,是这类风险的第三个实例。
//
// 实测覆盖率(用户曲库 9 首中/日/英抽样,过滤生效**之前**测的原始命中):
// 8/9 在 YTM 上有歌词,其中 2/9 是 LyricFind、6/9 是 Musixmatch(过滤生效后这 6/9 会
// 变成"这一源没查到",不再产出候选)。另外拿现有六源全部落空的曲目里最像"真的有歌词
// 只是没搜到"的 3 首去测,YTM 一首都没能补上(1 首 YTM 上确实标注"歌词不可用",2 首
// 因为曲名太泛被搜到完全不相关的曲目、连候选都没拿到)。也就是说这一路的边际价值
// 就是那 2/9 的 LyricFind 命中,不要指望它填补现有六源找不到的空白——那部分命中率是 0。
//
// 格式:只有**逐行**歌词(下面 ytmusicLyricLine 的 startMs/endMs,毫秒精度),没有逐字/
// 逐音节证据(读 sigma67/ytmusicapi 的 LyricLine 模型 + 实测多首歌词证实,
// 一行就是一个整句字符串)。所以候选构造时不带 wordTimingYRC,跟 lrclib 同一个形状。
// 没有带时间戳的、只有纯文本时交成 plainOnly(见 resolveYTMusicLyric)。
type ytmusicResult struct {
	lyrics, title, artist, album, cover string
	// durationSecs:搜索阶段从匹配到的曲目自己解析出的时长(秒),来自 flexColumn 里的
	// "m:ss" 文本(InnerTube 不直接给秒数,只给人类可读时长字符串,见 ytmusicParseDuration)。
	durationSecs float64
	// plainOnly:lyrics 是不带时间戳的纯文本(Android 身份拿不到带时间戳的、Web 身份那份有),语义同 lrclibResult.plainOnly。
	plainOnly bool
}

const (
	ytmusicDomain      = "https://music.youtube.com"
	ytmusicHTTPTimeout = 6 * time.Second
	// 每个真实浏览器都会发的 UA——跟 musixmatch.go/amllttml.go 同一个理由:这是未公开的
	// 反爬接口,一个诚实的自定义 UA(比如 lrclib.go 那种"客户端名/版本号")在这类接口上
	// 只会被更容易拦,不是更礼貌。字符串跟 sigma67/ytmusicapi 的默认值一致——那是这个
	// 领域实测多年、被反复验证不会被拦的一个值,没有理由自己另编一个没验证过的。
	ytmusicUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"
	// filter=songs 的 search params——照抄 ytmusicapi get_search_params("songs", nil, false)
	// 的算法手算出这一个常量(filtered_param1"EgWKAQ" + filter_params["songs"]"II" +
	// "AWoMEA4QChADEAQQCRAF")。 **不能不传这个参数**:不带过滤器
	// 的默认搜索"Top result"经常命中的是演唱会直拍/翻唱视频而不是录音室曲目(如 Taylor Swift
	// "Anti-Hero" 命中过一条 Eras Tour 现场版),那条视频往往没有歌词、或者歌词挂在错的
	// 版本上。加上这个过滤器之后同一批查询 20 条结果全部是 MUSIC_VIDEO_TYPE_ATV
	// (InnerTube 对"真·录音室曲目"的标记),没再命中过现场/翻唱。
	ytmusicSongsFilterParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
	// Web 客户端(搜索/取歌词 browseId 都走它)。clientVersion 按 UTC 日期自动生成,
	// 不需要手动跟着 YouTube Music 网页版更新——这是 ytmusicapi 的做法,日期串永远"够新"。
	ytmusicWebClientName = "WEB_REMIX"
	// **带时间戳**的歌词只有切成 Android 客户端身份才拿得到(ytmusicapi 原话"mobile
	// only":同一个 browseId,WEB_REMIX 身份下 browse 只给同一份歌词的纯文本,
	// 换成 ANDROID_MUSIC 才会带 timedLyricsData)。7.0 以下的版本号拿不到 timedLyricsData。
	// 已知的过期风险,跟 web 客户端不一样:这个版本号是**硬编码**的,不会随时间自动
	// "看起来永远最新"——真实 Android 客户端版本升级到足够新之后,这个值迟早会被服务端
	// 拒绝。这一路一旦开始整体失效(搜索/next 都正常、browse timed 总是 404 或不再返回
	// timedLyricsData),第一件事就是查 ytmusicapi 最新版这个常量有没有变,跟着更新。
	ytmusicMobileClientName    = "ANDROID_MUSIC"
	ytmusicMobileClientVersion = "7.21.50"
)

var (
	ytmusicMu    sync.Mutex
	ytmusicCache = map[string]ytmusicResult{} // artist|title|album -> result

	// ytmusicVisitorMu 保护下面三个值,不跨 I/O 持有。
	ytmusicVisitorMu sync.Mutex
	// ytmusicVisitorID:请求里带的 X-Goog-Visitor-Id。三个端点不带它也照常应答,应答的 responseContext.visitorData
	// 会发一个,拿到之后后面的请求都带上(ytmusicNoteVisitorData);查首页时顺带拿到的也存在这里。
	ytmusicVisitorID string
	// ytmusicRegionCheckedAt / ytmusicRegionBlocked:上次查首页(ytmusicCheckRegion)的时间和结论 —— 首页是不是
	// 「YouTube Music 在这个地区不可用」的提示页。没问成、调用方自己取消的不算查过。
	ytmusicRegionCheckedAt time.Time
	ytmusicRegionBlocked   bool

	// ytmusicRegionFetchMu 是查首页的单飞锁:批量解析(相册预取一次触发十几首歌并发)时同时搜不到的那几首只查一次,
	// 跟 musixmatch.go 的 musixmatchTokenFetchMu 同一个模式。
	ytmusicRegionFetchMu sync.Mutex

	// ytmusicLastFailureMu/ytmusicLastFailureReason:诊断用的只读旁路
	// (设置页"测试这个源"功能想知道 lyricfind 到底为什么没查到,不只是
	// "没查到"这个事实),跟 networkobs.go 的 networkLooksDown() 同一个思路——不改
	// ytmusicLyric 的返回值形状(自动解析路径从来不需要"为什么没查到"这个原因),只在
	// 查首页这一步识别出具体原因时顺手记一句,给需要更具体诊断信息的调用方
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

// ytmusicDoFetchVisitorID 是"真的去查首页"这一步(返回首页里的 visitor id,顺带记下 / 撤掉地区限制这个失败原因),
// ytmusicCheckRegion 在单飞锁里调它。nil(默认)= 用真正的实现 ytmusicFetchVisitorID。声明成变量是给测试
// 留的缝,原因与用法跟 musixmatch.go 的 musixmatchDoFetchToken 一致(那边的头注解释了
// 为什么不能写成 `= func() string { return ytmusicFetchVisitorID() }` 这种直接初始化
// 的形式——会形成初始化环)。
var ytmusicDoFetchVisitorID func(ctx context.Context) string

// ytmusicRegionRecheck:查过首页之后多久内不再查。首页慢(0.8～8 秒)、常超时,查一次的结论
// 管这么久:是地区限制提示页时这么久里这一源一个请求都不发,不是时这么久里搜不到也不再查。
const ytmusicRegionRecheck = 30 * time.Minute

func ytmusicCachedVisitorID() string {
	ytmusicVisitorMu.Lock()
	defer ytmusicVisitorMu.Unlock()
	return ytmusicVisitorID
}

// ytmusicVisitorDataFieldRe:应答里的 `"visitorData": "…"`(冒号两边可能有空白)。
var ytmusicVisitorDataFieldRe = regexp.MustCompile(`"visitorData"\s*:\s*"([^"]{1,512})"`)

// ytmusicNoteVisitorData:还没有 visitor id 时,从这份应答的 responseContext.visitorData 里取一个存下。只找第一处,
// 不整份解析(应答在 responseContext 开头就带着它)。
func ytmusicNoteVisitorData(raw []byte) {
	if ytmusicCachedVisitorID() != "" {
		return
	}
	m := ytmusicVisitorDataFieldRe.FindSubmatch(raw)
	if m == nil {
		return
	}
	ytmusicVisitorMu.Lock()
	if ytmusicVisitorID == "" {
		ytmusicVisitorID = string(m[1])
	}
	ytmusicVisitorMu.Unlock()
}

// ytmusicRegionBlockedNow:上次查首页看到的是地区限制提示页,而且还在 ytmusicRegionRecheck 之内。
func ytmusicRegionBlockedNow(now time.Time) bool {
	ytmusicVisitorMu.Lock()
	defer ytmusicVisitorMu.Unlock()
	return ytmusicRegionBlocked && now.Sub(ytmusicRegionCheckedAt) < ytmusicRegionRecheck
}

// ytmusicCheckRegion 查一次首页,看 YouTube Music 在这个网络所在的地区能不能用 —— 只在搜歌一条结果都没有时调
// (地区受限时搜什么都是空的)。ytmusicRegionRecheck 之内查过就不再查,同一时刻只查一次。首页是提示页时记下地区
// 限制(失败原因由 ytmusicVisitorFromHome 记),拿得到 visitor id 时撤掉;没问成的保留上一次的结论。
func ytmusicCheckRegion(ctx context.Context) {
	ytmusicRegionFetchMu.Lock()
	defer ytmusicRegionFetchMu.Unlock()
	ytmusicVisitorMu.Lock()
	recent := !ytmusicRegionCheckedAt.IsZero() && time.Since(ytmusicRegionCheckedAt) < ytmusicRegionRecheck
	ytmusicVisitorMu.Unlock()
	if recent {
		return
	}
	var v string
	if ytmusicDoFetchVisitorID != nil {
		v = ytmusicDoFetchVisitorID(ctx)
	} else {
		v = ytmusicFetchVisitorID(ctx)
	}
	if ctx.Err() != nil {
		// 调用方自己取消 / 超时不算查过:那是这一轮不要了,下一首照常查。
		return
	}
	ytmusicVisitorMu.Lock()
	defer ytmusicVisitorMu.Unlock()
	ytmusicRegionCheckedAt = time.Now()
	if v != "" {
		ytmusicRegionBlocked = false
		if ytmusicVisitorID == "" {
			ytmusicVisitorID = v
		}
		return
	}
	ytmusicRegionBlocked = ytmusicLastFailureReasonNow() == lyricFailureReasonLyricFindRegionRestricted
}

// ytmusicVisitorDataRe 抠 YouTube Music 首页内联的 `ytcfg.set({...})`,里面的
// VISITOR_DATA 字段就是后续所有请求都要带的 X-Goog-Visitor-Id。跟 ytmusicapi
// get_visitor_id 同一个正则,实测核实过真的能从首页 HTML 里抠出来。
var ytmusicVisitorDataRe = regexp.MustCompile(`ytcfg\.set\s*\(\s*(\{.+?\})\s*\)\s*;`)

func ytmusicFetchVisitorID(ctx context.Context) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ytmusicDomain+"/", nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", ytmusicUserAgent)
	resp, err := doHTTPTracked(lyricHTTPClient(8*time.Second), req)
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
	return ytmusicVisitorFromHome(string(body))
}

// ytmusicVisitorFromHome 从首页 HTML 取 visitor id,顺带记下 / 撤掉「地区限制」这个失败原因。纯文本进出,可单测。
func ytmusicVisitorFromHome(html string) string {
	v := ytmusicExtractVisitorID(html)
	if v == "" {
		// 一种具体失败原因:YouTube Music 按 IP 地理位置限定可用
		// 区域,拿不到 VISITOR_DATA 时,首页返回的不是真正的首页,而是一个几 KB 的
		// 静态提示页("YouTube Music is not available in your area")——跟 youtube.com/
		// google.com 同时能正常访问对照过,不是整体网络问题,是这一个服务本身的地区限制。
		// 只在能确认这个具体原因时才记;识别不出来(比如页面结构改了、regex 该更新了)
		// 就留空,退回调用方的通用文案,不能猜一个没验证过的理由。
		if strings.Contains(strings.ToLower(html), "not available in your area") {
			// 这里存的是稳定代码,不是文案——人话由 Swift 侧按 App 界面语言翻译,见
			// lyricsourcefailure.go 头注,两侧必须同步维护。
			ytmusicSetLastFailureReason(lyricFailureReasonLyricFindRegionRestricted)
		}
	} else {
		// 拿到了就撤掉早先的地区限制结论(换了网络 / 节点),理由同 musixmatch.go 那处。
		ytmusicSetLastFailureReason("")
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

// ytmusicPost 是三个端点共用的请求执行。 故意不设 Accept-Encoding:Go 的
// http.Transport 只在**自己**加上 `Accept-Encoding: gzip` 时才会透明解压响应体,
// 调用方一旦显式设置这个头就必须自己手动解压——用真实裸 HTTP 请求测过,
// 不设这个头、让标准库全权处理,响应体拿到的就是解压好的干净 JSON,没有理由为了
// "看起来更像浏览器"去踩这个 Go 特有的坑。
func ytmusicPost(ctx context.Context, endpoint string, body map[string]any, visitorID string) ([]byte, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	var out []byte
	err = tryEach(ctx, ytmusicAPIBases, func(base string) error {
		b, err := ytmusicPostAt(ctx, base, endpoint, raw, visitorID)
		if err == nil {
			out = b
		}
		return err
	})
	if err != nil {
		// 几个主机都没问成:跟原来一样按「没拿到」返回(nil, nil),调用方各自当空结果处理。
		return nil, nil
	}
	return out, nil
}

// ytmusicPostAt 发到一个 InnerTube 主机。Origin 始终是 music.youtube.com:三个主机同一套接口,
// 按 Origin 认这是 YouTube Music 的请求。err 非 nil 是没问成(含非 200)。prettyPrint=false 要带:不带时应答是缩进
// 排版的 JSON,搜索那一次传输 41KB、解压后 682KB,带了是 13KB / 195KB。
func ytmusicPostAt(ctx context.Context, base, endpoint string, raw []byte, visitorID string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/youtubei/v1/"+endpoint+"?prettyPrint=false&alt=json", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", ytmusicUserAgent)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", ytmusicDomain)
	if visitorID != "" {
		req.Header.Set("X-Goog-Visitor-Id", visitorID)
	}
	resp, err := doHTTPTracked(lyricHTTPClient(ytmusicHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err == nil {
		ytmusicNoteVisitorData(body)
	}
	return body, err
}

// ---- ① search:歌名+歌手 → videoId ----

// ytmusicSearchItem 只挑了 search 响应里这一路真正用得上的字段(flexColumns 的两段
// 文字 = 歌名 / "歌手 • 专辑 • 时长"、封面缩略图、以及能确认"这是不是真录音室曲目"的
// musicVideoType + videoId)。拿真实响应核实过这些字段路径,不是猜的。
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
// (拿中/英/日三种语言的真实查询核实过这个分隔符和顺序一致),最后一段
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
	cover = ytmusicOriginalThumbnail(cover)
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

// ytmusicSearchHL:搜歌词时带的界面语言。YouTube Music 按它给歌名和歌手名换写法:不带时中日韩歌手多半回英文名,
// 歌手闸就对不上。按歌手名的文字取(ytmusicLocalHL);歌手只有汉字、歌名或专辑带假名时是日文歌,用 ja。歌手名是
// 拉丁字母时不带 —— 带了反而会把它换成中文写法。
func ytmusicSearchHL(artist, title, album string) string {
	hl := ytmusicLocalHL(artist)
	if (hl == "zh-CN" || hl == "zh-TW") && (containsKana(title) || containsKana(album)) {
		return "ja"
	}
	return hl
}

// ytmusicSearchSong 搜「歌手 歌名」(只看歌曲,界面语言见 ytmusicSearchHL),挑一条(ytmusicPickSearchItem)。
// noItems:问成了、但一条结果都没有(地区受限时搜什么都是这样,见 ytmusicCheckRegion);没问成时为 false。
func ytmusicSearchSong(ctx context.Context, artist, title, album string, durationSecs float64) (item ytmusicParsedSearchItem, ok, noItems bool) {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	if hl := ytmusicSearchHL(artist, title, album); hl != "" {
		if c, ok := body["context"].(map[string]any)["client"].(map[string]any); ok {
			c["hl"] = hl
		}
	}
	body["query"] = strings.TrimSpace(artist + " " + title)
	body["params"] = ytmusicSongsFilterParams
	raw, err := ytmusicPost(ctx, "search", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return ytmusicParsedSearchItem{}, false, false
	}
	var parsed []ytmusicParsedSearchItem
	for _, it := range ytmusicExtractSearchItems(raw) {
		if p, ok := ytmusicParseSearchItem(it); ok {
			parsed = append(parsed, p)
		}
	}
	if len(parsed) == 0 {
		return ytmusicParsedSearchItem{}, false, true
	}
	item, ok = ytmusicPickSearchItem(parsed, artist, title, album, durationSecs)
	return item, ok, false
}

// ytmusicExtractSearchItems 从整份 search 响应里摘出 musicResponsiveListItemRenderer
// 数组。用通用递归查找而不是硬编码 tabs[0].tabRenderer.content... 这条深路径——
// InnerTube 是没有文档的私有协议,这条路径实测是这个形状,但 amll/musixmatch
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

// ytmusicFetchLyricsBrowseID 只带 videoId 问 next。别带 playlistId(`RDAMVM`+videoId 的自动电台)那一套:应答会
// 多出整张电台列表,解压后 2MB、传输 117KB,只带 videoId 是 61KB / 6KB,歌词 tab 的 browseId 一样。
func ytmusicFetchLyricsBrowseID(ctx context.Context, videoID string) string {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	body["videoId"] = videoID
	body["isAudioOnly"] = true
	raw, err := ytmusicPost(ctx, "next", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return ""
	}
	return ytmusicLyricsBrowseID(raw)
}

// ---- ③ browse:browseId → 带时间戳的逐行歌词 ----

// ytmusicLyricLine 是一行歌词(毫秒精度),字段来自 timedLyricsData 数组元素的
// lyricLine/cueRange.{start,end}TimeMilliseconds(拿真实响应核实过,
// 两个时间戳在原始 JSON 里是**字符串**,不是数字)。
type ytmusicLyricLine struct {
	text           string
	startMs, endMs int
}

// ytmusicParseTimedLyrics 从 "browse"(ANDROID_MUSIC 身份)响应里摘出逐行歌词 +
// 来源标注(形如 "Source: LyricFind"/"Source: Musixmatch")。这首歌没有带时间戳的
// 歌词时返回空切片(纯文本那份见 ytmusicParsePlainLyrics)。纯函数,便于单测。
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

func ytmusicFetchTimedLyrics(ctx context.Context, browseID string) (string, string) {
	body := ytmusicContext(ytmusicMobileClientName, ytmusicMobileClientVersion)
	body["browseId"] = browseID
	raw, err := ytmusicPost(ctx, "browse", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return "", ""
	}
	lines, source := ytmusicParseTimedLyrics(raw)
	if len(lines) == 0 {
		return "", ""
	}
	return ytmusicBuildLRC(lines), source
}

// ytmusicParsePlainLyrics 从 Web 身份的 browse 应答里取不带时间戳的歌词:musicDescriptionShelfRenderer 的
// description 是正文、footer 是来源标注(形如 "Source: LyricFind")。没有歌词时那一页是一条「Lyrics not available」
// 提示(messageRenderer),这里取不到东西,返回空。纯函数,便于单测。
func ytmusicParsePlainLyrics(raw []byte) (string, string) {
	var tree any
	if json.Unmarshal(raw, &tree) != nil {
		return "", ""
	}
	var text, source string
	ytmusicWalkJSON(tree, func(node map[string]any) {
		if text != "" {
			return
		}
		shelf, ok := node["musicDescriptionShelfRenderer"].(map[string]any)
		if !ok {
			return
		}
		runs := func(key string) string {
			obj, _ := shelf[key].(map[string]any)
			list, _ := obj["runs"].([]any)
			var b strings.Builder
			for _, r := range list {
				m, _ := r.(map[string]any)
				s, _ := m["text"].(string)
				b.WriteString(s)
			}
			return strings.TrimSpace(b.String())
		}
		text, source = runs("description"), runs("footer")
	})
	return text, source
}

// ytmusicFetchPlainLyrics:Android 身份拿不到带时间戳的歌词时,纯文本只在 Web 身份的应答里有(Android 那份里没有)。
func ytmusicFetchPlainLyrics(ctx context.Context, browseID string) (string, string) {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	body["browseId"] = browseID
	raw, err := ytmusicPost(ctx, "browse", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return "", ""
	}
	return ytmusicParsePlainLyrics(raw)
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

// resolveYTMusicLyric 三跳:① search 拿 videoId(带 songs 过滤器,见 ytmusicSongsFilterParams),一条结果都没有时查一次
// 地区限制(ytmusicCheckRegion),查出受限的那段时间里整源不发请求;② next 拿这首歌"歌词" tab 的 browseId(没有歌词
// tab 就放弃);③ browse(切到 Android 客户端身份)拿带时间戳的逐行歌词,没有时用 Web 身份再 browse 一次取纯文本,
// 交成 plainOnly。两种都**只在来源标注 LyricFind 时才接受**(ytmusicIsLyricFindSource,理由见文件头注):是 Musixmatch
// 换个管道重发的,跟 musixmatch 源查到的是同一份数据,当成两个源会让跨源正文共识(contentConsensusPeers)虚高,当
// "这一源没查到"。
//
// 超时预算:search / next / browse 各 6s,没有带时间戳的歌词时多一次 browse;查地区限制那一次首页 8s,只在搜不到时、
// ytmusicRegionRecheck 一次。
func resolveYTMusicLyric(ctx context.Context, artist, title, album string, durationSecs float64) ytmusicResult {
	if ytmusicRegionBlockedNow(time.Now()) {
		return ytmusicResult{}
	}
	item, ok, noItems := ytmusicSearchSong(ctx, artist, title, album, durationSecs)
	if noItems {
		ytmusicCheckRegion(ctx)
	}
	if !ok {
		return ytmusicResult{}
	}
	browseID := ytmusicFetchLyricsBrowseID(ctx, item.videoID)
	if browseID == "" {
		return ytmusicResult{}
	}
	out := ytmusicResult{title: item.title, artist: item.artist, album: item.album, durationSecs: item.durationSecs, cover: item.cover}
	lrc, source := ytmusicFetchTimedLyrics(ctx, browseID)
	if isTimedLRC(lrc) {
		if !ytmusicIsLyricFindSource(source) {
			return ytmusicResult{}
		}
		out.lyrics = lrc
		return out
	}
	if source != "" && !ytmusicIsLyricFindSource(source) {
		return ytmusicResult{}
	}
	plain, plainSource := ytmusicFetchPlainLyrics(ctx, browseID)
	if plain == "" || !ytmusicIsLyricFindSource(plainSource) {
		return ytmusicResult{}
	}
	out.lyrics, out.plainOnly = plain, true
	return out
}

// ytmusicIsLyricFindSource 判断 timedLyricsData 的 sourceMessage 是不是标注了
// LyricFind(观察到的真实取值形如 "Source: LyricFind" / "Source: Musixmatch")。
// 纯函数,便于单测;大小写不敏感只是防御性写法,实测两个取值大小写固定,没见过变体。
func ytmusicIsLyricFindSource(source string) bool {
	return strings.Contains(strings.ToLower(source), "lyricfind")
}

// ytmusicOriginalThumbnail:搜索结果的缩略图是 googleusercontent 地址,末尾 `=w120-h120-l90-rj` 这段是
// 缩放参数,换成 `=s0` 拿原图(实测 2400;更大的请求也封顶在原图)。不是这个图床的地址原样返回。
func ytmusicOriginalThumbnail(u string) string {
	if !strings.Contains(u, ".googleusercontent.com/") {
		return u
	}
	if i := strings.LastIndex(u, "="); i > strings.LastIndex(u, "/") {
		return u[:i] + "=s0"
	}
	return u
}
