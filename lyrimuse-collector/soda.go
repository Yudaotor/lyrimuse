// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 汽水音乐(Soda Music)歌词源 —— 全部源里第二个能给出**官方逐字**时间轴的(另一个是
// applemusic),也是唯一一个身份不靠搜索的。
//
// # 身份从哪来:本地队列缓存优先,搜索兜底
//
// `seo_track` 只认 track id、不吃歌名,所以这一路要先有 id。两条来源,顺序是固定的:
//
//  1. **汽水客户端自己的播放队列缓存**(sodaLocalTrackID,见 sodalocal.go)。那是客户端
//     为**正在播的这一条**写下的 id,零歧义、零请求,跟 amll 用 Apple/Spotify ID 直取是
//     同一条路子(见 platformtrackid.go 头注里"系统在播放时直接给的"那段)。用汽水听歌
//     时走的就是它,也正是同源加权(+250)成立的场景。
//  2. **搜索**(sodaSearch,见下面那一节)。本地拿不到时才用 —— 搜出来的是"名字对得上的
//     某一条",不保证是同一版录音,所以它是兜底而非等价替代。
//
// # 取词走 SEO 接口,无签名无 Cookie
//
// 歌词不落盘、只随 track_player 播放接口下发(见 sodalocal.go 头注),但 web 端给搜索引擎
// 用的 `seo_track` 端点按 track id 就能取到全文,**不需要签名、不需要 Cookie、不需要登录**。
// 响应里 `lyric.content` 是全文,`seo_track.track` 带曲名/歌手/专辑/时长(毫秒)。
//
// 这是给爬虫用的 SEO 端点,不是稳定契约:同一份客户端的 PC `track_v2` 接口已经下线过
// 一次。域名还带着 `beta-` 前缀。所以全程 fail-soft——取不到就当没有候选,不影响别的源。
//
// # 正文格式跟酷狗 KRC 逐字节同构
//
// `[行始ms,行长ms]<字内偏移ms,字长ms,0>字` —— 跟解密后的酷狗 KRC 正文**完全一样**,所以
// 归一化直接复用 krcToLRC / krcToYRC 两个现成函数(krcWordRegex 连尖括号都对得上),
// 不另写解析器。逐字数据因此天然是 YRCParser 语法,跟 netease/qq/kugou 同一口径。

const (
	// sodaSeoTrackPath 是 web 端的 SEO 曲目端点路径,主机按 sodaSeoHosts 的顺序试(sourcefallback.go)。
	// 见头注:SEO 端点不是稳定契约。
	sodaSeoTrackPath = "/luna/h5/seo_track"
	// sodaSeoTrackHost 单独列出来给熔断的主机映射用(sourcebreaker.go)。
	sodaSeoTrackHost = "beta-luna.douyin.com"
	// sodaImageBase / sodaImageTemplate:接口没带 url_cover.urls / template_prefix 时的兜底值。
	// 图片地址是「前缀 + uri + ~模板-处理参数.格式」,缺了 `~模板-...` 那段图片服务回 400。
	sodaImageBase     = "https://p3-luna.douyinpic.com/img/"
	sodaImageTemplate = "tplv-b829550vbb"
	// sodaCoverTransform:跟网易云 800y800、QQ 800x800 同尺寸。
	sodaCoverTransform = "resize:800:800.jpg"
	// sodaLyricTimeout 跟别的逐字源同量级。这一路只有一次请求、没有搜索轮。
	sodaLyricTimeout = 8 * time.Second
	// sodaUserAgent:SEO 端点按普通网页请求对待,给一个常见桌面 UA 即可,不伪装客户端。
	sodaUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

// sodaResult 跟别的源的同名结构同构。没有 plainOnly:汽水这一路要么给带计时的全文,
// 要么什么都没有 —— 实测未见过"只有纯文本"的形态,真出现时 krcToLRC 会因为没有计时行
// 返回空串,自然落到 empty()。
type sodaResult struct {
	lyrics, yrc, title, artist, album, cover string
	// durationSecs:汽水自报的曲长(秒),透传给打分的 sourceReportedDurationSecs。
	durationSecs float64
	// fromLocalClient:这条曲目的 id 取自汽水客户端的播放队列缓存(sodaLocalTrackID),
	// 不是搜索挑出来的。透传给 lyricCandidate.identityFromLocalClient,是同源加权的准入
	// 条件之一。 **不进 sodaCache** —— 那份缓存按 track id 存,同一个 id 两条路都可能
	// 取到;标记是"这一次怎么拿到的",由 sodaLyric 在缓存之外置位(值拷贝,不污染缓存)。
	fromLocalClient bool
}

func (r sodaResult) empty() bool { return r.lyrics == "" && r.yrc == "" }

// sodaSeoTrackResponse 只摘用得上的字段。 歌词在**顶层** lyric.content;
// seo_track.lyric 实测恒为空,两处都留着是因为 music-lib 那边两处都读(接口两种形态都出现过)。
type sodaSeoTrackResponse struct {
	Lyric struct {
		Content string `json:"content"`
	} `json:"lyric"`
	SeoTrack struct {
		Track struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			Duration int64  `json:"duration"` // 毫秒
			Artists  []struct {
				Name string `json:"name"`
			} `json:"artists"`
			Album struct {
				Name     string `json:"name"`
				URLCover struct {
					URI            string   `json:"uri"`
					URLs           []string `json:"urls"`
					TemplatePrefix string   `json:"template_prefix"`
				} `json:"url_cover"`
			} `json:"album"`
		} `json:"track"`
		Lyric struct {
			Content string `json:"content"`
		} `json:"lyric"`
	} `json:"seo_track"`
}

var (
	sodaMu    sync.Mutex
	sodaCache = map[string]sodaResult{}

	sodaLastFailMu  sync.Mutex
	sodaLastFailure string

	// 搜索结果按"这一首歌的身份"缓存:同一首歌在别名轮/升级重试里会被问到好几次,
	// 没必要每次都重搜。存的是过完身份闸的 id 名次表,可能是空切片(= 搜过、没有匹配的)。
	sodaSearchMu    sync.Mutex
	sodaSearchCache = map[string][]string{}
)

func sodaSetLastFailureReason(reason string) {
	sodaLastFailMu.Lock()
	sodaLastFailure = reason
	sodaLastFailMu.Unlock()
}

// sodaLastFailureReasonNow 供 search-lyrics / test-lyric-sources 用。
//
// 只有一种会往这里记的模式:**响应不再是我们认识的形状**(soda_endpoint_changed)。
// 取词走的是给搜索引擎爬的 SEO 端点、不是稳定契约,同一客户端的 PC track_v2 已经整个
// 下线过一次(实测现在回 200 + 0 字节),所以"哪天它变了"要能被说出来,而不是退化成
// "这首歌没歌词"。反过来,"曲库里有这首歌但没词"和"这首没用汽水放过所以没有 id"都是
// **正常结果**,一个字都不往这里记 —— 报上去会让用户以为源坏了。
func sodaLastFailureReasonNow() string {
	sodaLastFailMu.Lock()
	defer sodaLastFailMu.Unlock()
	return sodaLastFailure
}

// sodaLyric 取汽水歌词。拿不到本地曲目 id 就直接空手返回 —— 没装汽水 / 没用汽水放过
// 这首,本来就不该有它的候选,这时一个请求都不发。
// 第二个返回值是「汽水曲库里有这首歌、但平台没给词」——跟 netease/qq 那两路的同名结论
// 一个语义,由调用方填进 lyricSourceResult.trackFoundNoLyrics。
func sodaLyric(ctx context.Context, artist, title, album string, durationSecs float64) (sodaResult, bool) {
	if title == "" {
		return sodaResult{}, false
	}
	// 本地队列缓存优先:那是汽水客户端为**正在播的这一条**写下的 id,零歧义、零请求。
	// 拿不到才去搜索 —— 搜出来的是"名字对得上的某一条",不一定是同一版录音,所以它
	// 只是兜底,不是等价替代。
	if trackID := sodaLocalTrackID(artist, title, album, durationSecs); trackID != "" {
		r, noLyrics := sodaLyricByID(ctx, trackID, artist, title)
		// 在 sodaCache 之外置位:返回的是值拷贝,标记记的是"这一次的 id 哪来的",
		// 不是那份正文的属性。搜索路径拿到同一个 id 时不会继承它。
		r.fromLocalClient = true
		return r, noLyrics
	}
	return sodaLyricBySearch(ctx, artist, title, album, durationSecs)
}

// sodaLyricBySearch 搜索兜底:身份闸淘汰后按名次依次试,拿到带词的那条就收工。
func sodaLyricBySearch(ctx context.Context, artist, title, album string, durationSecs float64) (sodaResult, bool) {
	key := artist + "|" + title + "|" + album
	sodaSearchMu.Lock()
	ids, ok := sodaSearchCache[key]
	sodaSearchMu.Unlock()
	if !ok {
		items, err := sodaSearch(ctx, artist, title)
		if err != nil {
			log.Printf("soda: search for %q - %q failed: %v", artist, title, err)
			return sodaResult{}, false
		}
		ids = sodaRankCandidates(items, artist, title, album, durationSecs)
		sodaSearchMu.Lock()
		sodaSearchCache[key] = ids
		sodaSearchMu.Unlock()
	}
	// 一条都没通过身份闸 = 汽水没有这首歌(或只有对不上的版本),是正常结果,不报故障。
	var lastNoLyrics bool
	for i, id := range ids {
		if i >= sodaSearchMaxTries {
			break
		}
		r, noLyrics := sodaLyricByID(ctx, id, artist, title)
		if !r.empty() {
			return r, false
		}
		lastNoLyrics = lastNoLyrics || noLyrics
	}
	return sodaResult{}, lastNoLyrics
}

// sodaLyricByID 按曲目 id 取词。两条入口(本地 id / 搜索到的 id)共用。
func sodaLyricByID(ctx context.Context, trackID, artist, title string) (sodaResult, bool) {
	// 缓存键就是 track id:它已经是这条录音的完整身份。
	sodaMu.Lock()
	if v, ok := sodaCache[trackID]; ok {
		sodaMu.Unlock()
		return v, false
	}
	sodaMu.Unlock()

	r, noLyrics, broken, err := sodaFetchSeoTrack(ctx, trackID)
	if err != nil {
		// 传输层的失败(DNS / 连不上 / 5xx)由 sourcebreaker 按主机记,这里不重复登记 ——
		// 它们跟"端点改了形状"是两回事,混在一起会把一次网络抖动报成源失效。
		log.Printf("soda: seo_track for %q - %q (id %s) failed: %v", artist, title, trackID, err)
		return sodaResult{}, false
	}
	if broken {
		sodaSetLastFailureReason(lyricFailureReasonSodaEndpointChanged)
		log.Printf("soda: seo_track for %q - %q (id %s) answered without a track id — the endpoint shape changed", artist, title, trackID)
		return sodaResult{}, false
	}
	// 走到这里说明端点还认得出:把上一次可能记下的失效结论清掉,免得一次旧故障一直挂着。
	sodaSetLastFailureReason("")
	if r.empty() {
		return r, noLyrics
	}
	sodaMu.Lock()
	sodaCache[trackID] = r
	sodaMu.Unlock()
	return r, false
}

// sodaFetchSeoTrack 发一次 seo_track 请求并归一化。分出来是为了让单测能直接喂响应体
// (见 sodaParseSeoTrack)。
func sodaFetchSeoTrack(ctx context.Context, trackID string) (res sodaResult, trackFoundNoLyrics, broken bool, err error) {
	err = tryEach(ctx, sodaSeoHosts, func(host string) error {
		var e error
		res, trackFoundNoLyrics, broken, e = sodaFetchSeoTrackAt(ctx, host, trackID)
		return e
	})
	return res, trackFoundNoLyrics, broken, err
}

// sodaFetchSeoTrackAt 打一个主机上的 seo_track;两个主机同一个路径、同一个响应结构(实测)。
func sodaFetchSeoTrackAt(ctx context.Context, host, trackID string) (res sodaResult, trackFoundNoLyrics, broken bool, err error) {
	params := neturl.Values{}
	params.Set("track_id", trackID)
	params.Set("device_platform", "web")
	u := "https://" + host + sodaSeoTrackPath + "?" + params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return sodaResult{}, false, false, err
	}
	req.Header.Set("User-Agent", sodaUserAgent)
	resp, err := doHTTPTracked(lyricHTTPClient(sodaLyricTimeout), req)
	if err != nil {
		return sodaResult{}, false, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return sodaResult{}, false, false, fmt.Errorf("status %d", resp.StatusCode)
	}
	var body sodaSeoTrackResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return sodaResult{}, false, false, err
	}
	r, noLyrics, broken := sodaParseSeoTrack(body)
	return r, noLyrics, broken, nil
}

// sodaParseSeoTrack 把响应归一化成候选,并分出这一路的**三种结局**。纯函数,单测直接喂结构体。
//
// 正文取**顶层** lyric.content 优先、seo_track.lyric.content 兜底,理由见那个结构体的注释。
//
// 三种结局必须分开,否则端点变化会伪装成"这首歌没歌词"静默退化(这是 SEO 端点最可能的
// 失效形态:改了结构照样回 200,JSON 解得动、字段缺失变零值):
//
//   - broken —— 连 `seo_track.track.id` 都没有。响应不是我们认识的那个形状了,归
//     soda_endpoint_changed,两处诊断面据此报"这个源坏了",不是"这首歌没词"。
//   - trackFoundNoLyrics —— 有 id、没正文(或正文没有一行计时)。曲库里有这首歌、平台
//     没给词,是**正常结果**,跟 netease/qq 那两路的同名结论一个语义,不报故障。
//   - 正常候选。
func sodaParseSeoTrack(body sodaSeoTrackResponse) (res sodaResult, trackFoundNoLyrics, broken bool) {
	if strings.TrimSpace(body.SeoTrack.Track.ID) == "" {
		return sodaResult{}, false, true
	}
	content := body.Lyric.Content
	if strings.TrimSpace(content) == "" {
		content = body.SeoTrack.Lyric.Content
	}
	if strings.TrimSpace(content) == "" {
		return sodaResult{}, true, false
	}
	// 跟酷狗 KRC 正文同构,两个现成函数直接用,见头注。
	lrc := krcToLRC(content)
	if lrc == "" {
		// 没有计时行 = 拿到的是个没法用的壳,口径同 krcToLRC 里那条守卫。曲目本身是在的,
		// 所以归"有这首歌、没有可用歌词",不是端点坏了。
		return sodaResult{}, true, false
	}
	t := body.SeoTrack.Track
	names := make([]string, 0, len(t.Artists))
	for _, a := range t.Artists {
		if n := strings.TrimSpace(a.Name); n != "" {
			names = append(names, n)
		}
	}
	return sodaResult{
		lyrics:       lrc,
		yrc:          krcToYRC(content),
		title:        strings.TrimSpace(t.Name),
		artist:       strings.Join(names, "/"),
		album:        strings.TrimSpace(t.Album.Name),
		cover:        sodaCoverURL(t.Album.URLCover.URI, t.Album.URLCover.URLs, t.Album.URLCover.TemplatePrefix),
		durationSecs: float64(t.Duration) / 1000,
	}, false, false
}

// sodaCoverURL 把 album.url_cover 的 uri / urls / template_prefix 拼成可取的图片地址。
// 空 uri 给空串(调用方的 coverOrFallback 会接手)。
func sodaCoverURL(uri string, bases []string, template string) string {
	uri = strings.TrimSpace(uri)
	if uri == "" {
		return ""
	}
	base := sodaImageBase
	for _, b := range bases {
		if b = strings.TrimSpace(b); strings.HasPrefix(b, "https://") {
			base = b
			break
		}
	}
	if !strings.HasSuffix(base, "/") {
		base += "/"
	}
	if template = strings.TrimSpace(template); template == "" {
		template = sodaImageTemplate
	}
	return base + uri + "~" + template + "-" + sodaCoverTransform
}

// sodaCoverNeedsTransform 认出缺了 `~模板-处理参数` 那段、取不到图的汽水封面地址。
func sodaCoverNeedsTransform(u string) bool {
	return strings.HasPrefix(u, "https://") && strings.Contains(u, "-luna.douyinpic.com/img/") && !strings.Contains(u, "~")
}

// ---- 搜索:本地拿不到曲目 id 时的兜底 ----
//
// 本地队列缓存只有"用汽水放过的歌"(见文件头注),而 `seo_track` 只认 track id、不吃歌名。
// 所以用别的播放器听歌时,这一路要先把歌名搜成 id。
//
// 搜索**不需要伪装成客户端**:实测 `q` / `cursor` / `count` / `aid` 四个参数就够,
// 普通桌面 UA、甚至完全不带 UA 都照样 200。music-lib 那份实现里带着几十个 Android 设备
// 参数(含固定的 device_id / iid / cdid),那是别人某台真机的标识 —— 照抄只会平添被识别
// 的风险,这里一个都不带。
//
// 排序不能直接信:实测搜"方大同 Sorry",第 2 条是 Live 版、第 5 条是 Justin Bieber
// 的同名歌。所以跟酷我那套一样**自己重新打分**,身份闸用跟别的源完全一致的判定函数
// (lyricTitleAccepted / lyricSourceArtistMatches / versionTagsMismatch),不为这一个源
// 另起一套更松的规则。
const (
	sodaSearchBase = "https://api.qishui.com/luna/search/track"
	// sodaSearchHost 给熔断的主机映射用(sourcebreaker.go),跟取词端点不是同一个主机。
	sodaSearchHost = "api.qishui.com"
	// sodaSearchAID:汽水 web 端的固定应用号,跟设备无关。
	sodaSearchAID = "386088"
	// sodaSearchCount:一次要多少条。身份闸会淘汰大半,20 条足够覆盖"原版排在几条之后"。
	sodaSearchCount = 20
	// sodaSearchDurationTolerance:时长偏差超过这个比例直接淘汰,口径同酷我。
	sodaSearchDurationTolerance = 0.25
	// sodaSearchMaxTries:通过身份闸后最多按名次试几条。取词那一步响应不小(实测 ~250KB),
	// 不像酷我那样并发拉 5 条;绝大多数情况第一条就有词,试到第三条还没有就认了。
	sodaSearchMaxTries = 3
)

// sodaSearchItem 只摘身份闸与打分用得上的字段。
type sodaSearchItem struct {
	ID       string
	Name     string
	Artist   string
	Album    string
	Duration float64 // 秒
	// 非会员试听段(毫秒),没有就是 0。见 sodapreview.go。
	PreviewStartMs    int64
	PreviewDurationMs int64
}

// sodaSearchResponse 只摘曲目列表。结构是 result_groups[].data[].entity.track。
type sodaSearchResponse struct {
	ResultGroups []struct {
		ID   string `json:"id"`
		Data []struct {
			Entity struct {
				Track struct {
					ID       string `json:"id"`
					Name     string `json:"name"`
					Duration int64  `json:"duration"` // 毫秒
					Artists  []struct {
						Name string `json:"name"`
					} `json:"artists"`
					Album struct {
						Name string `json:"name"`
					} `json:"album"`
					Preview struct {
						Start    int64 `json:"start"`
						Duration int64 `json:"duration"`
					} `json:"preview"`
				} `json:"track"`
			} `json:"entity"`
		} `json:"data"`
	} `json:"result_groups"`
}

// sodaParseSearch 把响应摊成候选列表。纯函数,单测直接喂结构体。
func sodaParseSearch(body sodaSearchResponse) []sodaSearchItem {
	var out []sodaSearchItem
	for _, g := range body.ResultGroups {
		// 只认曲目那一组:同一个响应里还会回歌手/专辑/歌单等别的组。
		if g.ID != "tracks" {
			continue
		}
		for _, d := range g.Data {
			t := d.Entity.Track
			if strings.TrimSpace(t.ID) == "" {
				continue
			}
			names := make([]string, 0, len(t.Artists))
			for _, a := range t.Artists {
				if n := strings.TrimSpace(a.Name); n != "" {
					names = append(names, n)
				}
			}
			out = append(out, sodaSearchItem{
				ID:       strings.TrimSpace(t.ID),
				Name:     strings.TrimSpace(t.Name),
				Artist:   strings.Join(names, "/"),
				Album:    strings.TrimSpace(t.Album.Name),
				Duration: float64(t.Duration) / 1000,

				PreviewStartMs:    t.Preview.Start,
				PreviewDurationMs: t.Preview.Duration,
			})
		}
	}
	return out
}

// sodaCandidateScore 给一条搜索结果打分:分数越高越像本地这首歌,负数 = 淘汰。
// 判据与取值口径同 kuwoCandidateScore,见那边的注释。纯函数,便于单测。
func sodaCandidateScore(item sodaSearchItem, artist, title, album string, durationSecs float64) int {
	if !lyricTitleAccepted(item.Name, title) {
		return -1
	}
	if !lyricSourceArtistMatches(item.Artist, artist) {
		return -1
	}
	if versionTagsMismatch(title, album, item.Name, item.Album) {
		return -1
	}
	score := 100
	if durationSecs > 0 {
		if item.Duration <= 0 {
			return score // 时长未知,不额外加分也不扣分
		}
		diff := math.Abs(item.Duration-durationSecs) / durationSecs
		if diff > sodaSearchDurationTolerance {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// sodaSearch 发一次搜索请求。
func sodaSearch(ctx context.Context, artist, title string) ([]sodaSearchItem, error) {
	q := strings.TrimSpace(strings.TrimSpace(artist) + " " + strings.TrimSpace(title))
	if q == "" {
		return nil, nil
	}
	params := neturl.Values{}
	params.Set("q", q)
	params.Set("cursor", "0")
	params.Set("count", strconv.Itoa(sodaSearchCount))
	params.Set("aid", sodaSearchAID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sodaSearchBase+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", sodaUserAgent)
	resp, err := doHTTPTracked(lyricHTTPClient(sodaLyricTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var body sodaSearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return sodaParseSearch(body), nil
}

// sodaRankCandidates 过身份闸并按分数排序,返回可以依次尝试的曲目 id。纯函数,便于单测。
func sodaRankCandidates(items []sodaSearchItem, artist, title, album string, durationSecs float64) []string {
	type scored struct {
		id    string
		score int
	}
	var kept []scored
	for _, it := range items {
		if s := sodaCandidateScore(it, artist, title, album, durationSecs); s >= 0 {
			kept = append(kept, scored{it.ID, s})
		}
	}
	// 稳定排序:同分时保留汽水自己的顺序(它的排序实测基本可信,只是不能**只**信它)。
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].score > kept[j].score })
	out := make([]string, 0, len(kept))
	for _, k := range kept {
		out = append(out, k.id)
	}
	return out
}
