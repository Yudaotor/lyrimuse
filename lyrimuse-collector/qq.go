// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	qqURLMu    sync.Mutex
	qqURLCache = map[string]qqMusicMatch{}
)

// qqMusicURL returns the QQ Music song-detail URL for a track, resolved via
// smartbox + single-song album enrichment (see resolveQQMusicURL). Cached per
// artist|title|album; only real song URLs are cached — the search-link fallback
// is not, so a later poll retries exact resolution.
func qqMusicURL(ctx context.Context, artist, title, album string) string {
	m := qqMusicMatchCached(ctx, artist, title, album)
	if m.url != "" {
		return m.url
	}
	if title == "" {
		return ""
	}
	// smartbox 无结果/无标题匹配时，退回 QQ 搜索链接：桌面能打开搜索页、绝不串到错歌
	// (用户自己选)。不缓存，下次提交再试精确解析。
	return qqSearchFallbackPrefix + "w=" + neturl.QueryEscape(artist+" "+title)
}

// qqSearchFallbackPrefix 是上面那个兜底搜索链接的前缀。单独拎出来是因为调用方需要能
// **认出**这一档:它是纯本地拼接的,不需要任何网络请求就能得到,所以不能被当作"这首歌
// 解析成功了"的证据(见 enrich.go 里 resolveEnrichAsync 的全空守卫)。
const qqSearchFallbackPrefix = "https://y.qq.com/n/ryqq/search?"

// isQQSearchFallbackURL 判断一个 QQ 音乐链接是不是"没查到,给个搜索页"的兜底值。
func isQQSearchFallbackURL(u string) bool {
	return strings.HasPrefix(u, qqSearchFallbackPrefix)
}

// qqMusicMatchCached 是 qqMusicURL 的富信息版本——"搜索候选歌词"弹窗展示每条候选
// 实际匹配到的歌名/歌手/专辑时(见 enrich.go 的 fetchScoredLyricCandidatesStreaming)
// 需要这些字段,不能只要一个 URL 字符串。跟 qqMusicURL 共用同一份缓存(按
// artist|title|album 存完整 qqMusicMatch,而不是只存 url 字符串)——不管从哪个入口
// 先查到,另一个入口都能直接命中缓存,不会重复发两遍 smartbox/专辑请求。
func qqMusicMatchCached(ctx context.Context, artist, title, album string) qqMusicMatch {
	if title == "" {
		return qqMusicMatch{}
	}
	key := artist + "|" + title + "|" + album
	qqURLMu.Lock()
	if v, ok := qqURLCache[key]; ok {
		qqURLMu.Unlock()
		return v
	}
	qqURLMu.Unlock()

	m := resolveQQMusicMatch(ctx, artist, title, album)
	// unreliable(专辑路线网络失败、这是回落结果)不进缓存:见 qqMusicMatch.unreliable 注释。
	if m.url != "" && !m.unreliable {
		qqURLMu.Lock()
		qqURLCache[key] = m
		qqURLMu.Unlock()
	}
	return m
}

// qqSmartboxItem is one suggestion from smartbox_new.fcg (mid + song name +
// singer; no album — enriched separately via qqSongAlbum when disambiguating).
type qqSmartboxItem struct {
	Mid    string `json:"mid"`
	Name   string `json:"name"`
	Singer string `json:"singer"`
}

const qqUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

// qqSearchItem 是"歌名维度找候选"这一步的统一条目形态——两条搜索路线
// (client_search_cp 与 smartbox)的结果都归一成它,下游(resolveQQMusicMatch /
// qqCoverFallback)只认这一种。
//
// Album/Interval 只有 client_search_cp 路线填得上(smartbox 的响应里根本没有这两个
// 字段),空/0 表示"这条路线没给",调用方照旧回落到 qqSongAlbum(mid) 单独查一次。
type qqSearchItem struct {
	Mid      string
	Name     string
	Singer   string
	Album    string
	Interval float64 // 官方时长(秒),0=没给
}

// qqClientSearchResp 是 client_search_cp 在 new_json=1 下的响应形状(只声明本文件
// 用得上的字段)。
type qqClientSearchResp struct {
	Code int `json:"code"`
	Data struct {
		Song struct {
			List []struct {
				Mid      string  `json:"mid"`
				Title    string  `json:"title"`
				Interval float64 `json:"interval"`
				Singer   []struct {
					Name string `json:"name"`
				} `json:"singer"`
				Album struct {
					Name string `json:"name"`
				} `json:"album"`
			} `json:"list"`
		} `json:"song"`
	} `json:"data"`
}

// qqClientSearchItems 把 client_search_cp 的响应归一成 qqSearchItem。从发请求那步
// 单独拆出来的纯函数,好让单测拿真实响应直接验(合唱署名怎么拼、字段缺了怎么办),
// 不用起网络。
//
// 合唱署名用 "/" 拼:smartbox 对合唱本来就返回 "UMI/V" 这种形态(见 qqArtistOK 注释),
// 而 "/" 是 isArtistCreditSep 认识的分隔符——两条路线拼法一致,下游那几道身份闸
// (artistMatches / lyricSourceArtistMatches / looseContains)才不会因为换了搜索接口
// 就换一套行为。
func qqClientSearchItems(resp qqClientSearchResp) []qqSearchItem {
	var out []qqSearchItem
	for _, s := range resp.Data.Song.List {
		if s.Mid == "" {
			continue
		}
		var names []string
		for _, sg := range s.Singer {
			if n := strings.TrimSpace(sg.Name); n != "" {
				names = append(names, n)
			}
		}
		out = append(out, qqSearchItem{
			Mid:      s.Mid,
			Name:     s.Title,
			Singer:   strings.Join(names, "/"),
			Album:    s.Album.Name,
			Interval: s.Interval,
		})
	}
	return out
}

// qqSearchLimit 是 client_search_cp 一次取几条。10 条跟改造前 smartbox 的量级一致;
// 实测再往上加(20/30)对本仓踩到的几个 case 都没有新增召回(见 qqSearchSongs ②),
// 只是白解码。
const qqSearchLimit = 10

// qqAlbumLookupBudget 是"为了给候选补专辑名,最多额外打几次详情接口"。只有搜索结果
// 没自带专辑名的候选(smartbox 路线)才消耗它,见 resolveQQMusicMatch 里的用法。
const qqAlbumLookupBudget = 4

// qqClientSearch 打 QQ 音乐的**正式搜索接口** client_search_cp。
//
// ⚠️ 这里的历史结论翻过案,别照着旧注释理解。2026-09-02 之前本文件断言
// "client_search_cp returns zero bytes under anti-scrape",于是歌名维度整条链路只走
// smartbox_new.fcg。但 smartbox 是**搜索框自动补全**、不是搜索:它有很高的热度门槛,
// 冷门曲目一条都不回,而"回 0 条"跟"QQ 根本没收录这首歌"长得一模一样,从外面完全
// 看不出来——表现就是欧美独立/长尾曲目上 QQ 这一源常年静默失效。
//
// 2026-09-02 逐条实测(起因是 Have Gun, Will Travel《Gravity Blues》八个源 0 候选
// 那次排查):
//
//	查询词                                smartbox   client_search_cp
//	周杰伦 稻香                            4 条       6 条
//	Taylor Swift Lover                    2 条       6 条
//	Geese Gravity Blues                   0 条       6 条(第 1 条即目标)
//	Charlie Musselwhite Storm Warning     0 条       6 条(第 1 条即目标)
//	裘德 寻找一片青草地                     0 条       6 条(第 1 条即目标)
//	Have Gun, Will Travel Gravity Blues   0 条       6 条(第 1 条即目标)
//
// 而 client_search_cp 当下**裸请求就能用**:不带 UA、不带 Referer 同样 200,连打 6 次
// 响应字节数完全一致,Go 的 http.Client 与 curl 结果相同。UA/Referer 仍照发(跟本文件
// 其它 QQ 接口一致,反爬策略随时可能收紧,带上没坏处)。
//
// new_json=1 不能省:不带它响应里没有 mid / 曲名 / 专辑名(实测只剩歌手名和时长),
// 下游身份闸会全部失效。
//
// error 非 nil = 网络层失败(超时/非 200/解码失败),跟"接口正常应答但 0 条"是两回事
// ——qqSearchSongs 靠这个区分"要不要退到 smartbox"。
func qqClientSearch(ctx context.Context, query string) ([]qqSearchItem, error) {
	u := "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&new_json=1&t=0&aggr=1&cr=1&p=1&n=" +
		strconv.Itoa(qqSearchLimit) + "&w=" + neturl.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("client_search_cp status %d", resp.StatusCode)
	}
	var out qqClientSearchResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return qqClientSearchItems(out), nil
}

// qqSmartbox queries QQ Music's suggest endpoint. 2026-09-02 起它不再是歌名维度的
// 主路线,而是 qqClientSearch 的兜底——理由和实测对比见 qqClientSearch 的头注。
// Returns nil on error.
func qqSmartbox(ctx context.Context, query string) []qqSmartboxItem {
	d, _ := qqSmartboxRaw(ctx, query)
	return d.Song.ItemList
}

// qqSmartboxAlbums 是同一个 suggest 接口的 **album 分类**——专辑维度检索路线
// (resolveQQMatchViaAlbum)用它找专辑 mid。跟 song 分类同一次请求形态,条目字段也同形
// (mid/name/singer)。error 非 nil 表示**网络层失败**(超时/非 200/解码失败),跟"接口
// 正常应答但 0 条"是两回事——专辑路线要靠这个区分"确定没有"和"这次没查成"。
func qqSmartboxAlbums(ctx context.Context, query string) ([]qqSmartboxItem, error) {
	d, err := qqSmartboxRaw(ctx, query)
	return d.Album.ItemList, err
}

// qqSmartboxCategoryList 是 smartbox 响应里一个分类的条目列表。
type qqSmartboxCategoryList struct {
	ItemList []qqSmartboxItem `json:"itemlist"`
}

type qqSmartboxData struct {
	Song  qqSmartboxCategoryList `json:"song"`
	Album qqSmartboxCategoryList `json:"album"`
}

func qqSmartboxRaw(ctx context.Context, query string) (qqSmartboxData, error) {
	u := "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?_=1&cv=4747474&ct=24&format=json&is_xml=0&key=" + neturl.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqSmartboxData{}, err
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return qqSmartboxData{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqSmartboxData{}, fmt.Errorf("smartbox status %d", resp.StatusCode)
	}
	var out struct {
		Data qqSmartboxData `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return qqSmartboxData{}, err
	}
	return out.Data, nil
}

// qqSearchQueries 是 smartbox 的"歌手+歌名"查询尝试序列。QQ 这一源对括号**格外**敏感:
// 2026-08-09 逐源实测,smartbox 的 key 里只要出现括号就返回 0 条(不是少几条,是一条不
// 回),而去掉括号立刻有结果——也就是说改之前,凡是本地标题带 "(Remastered 2014)"/
// "(Single Version)"/"(Taylor's Version)" 这类后缀的歌,QQ 音乐整个源都是废的,而且因为
// 返回空跟"QQ 没收录这首歌"长得一模一样,从外面完全看不出来。
func qqSearchQueries(artist, title string) []string {
	var out []string
	for _, t := range searchTitleVariants(title) {
		out = append(out, strings.TrimSpace(artist+" "+t))
	}
	return out
}

// qqSearchSongs 是歌名维度找候选的唯一入口:把正式搜索接口(qqClientSearch)对**每个**
// 标题变体的结果按 mid 去重合并,必要时再补一次 smartbox。
//
// ⚠️ 两处都不是随手定的,各自对应一个 2026-09-02 回放里实测到的坑:
//
// ① **跨变体合并,不是"第一个非空就返回"。** 改造前那个"first non-empty"策略,暗中
// 依赖的是"smartbox 对带括号的查询词恒返回 0 条"——所以带括号那版必然落空、必然轮到
// 去括号那版。换成真正的搜索接口之后带括号也有结果了,去括号那版就再也没机会被查,
// 而正确答案偏偏只在后者里:周杰伦《七里香 (Live)》,查 "周杰伦 七里香 (Live)" 只回
// 无与伦比演唱会那版,查 "周杰伦 七里香" 才有本地专辑对应的地表最强那版(两版都叫
// "七里香 (Live)",靠专辑名才分得开)。合并之后由下游 albumScore 分胜负,不再由
// "哪个查询词先返回非空"决定。
//
// ② **smartbox 是补充,不是兜底。** 两个索引互补,不是替代关系:client_search_cp 召回
// 广,但排序里可能把最规范的原版整个漏掉——PRINCE《Little Red Corvette》实测 n 开到 30,
// 回来的只有 The Hits 精选版 / Single Version / 2019 重制版 / Live 广播版四个,原版专辑
// 《1999》那条一次都没出现,而 smartbox 恰恰只回那一条。反过来 smartbox 对冷门曲目
// 整片交白卷(见 qqClientSearch 头注的实测表)。
//
// 补 smartbox 的条件收在"正式搜索没给出任何标题精确同名的候选"上:smartbox 的价值就是
// 补那条最规范的版本,正式搜索已经有精确同名候选时它给不出新信息,这一次请求可以省掉。
// 这也顺带保住了原来的降级路径——正式接口哪天再被反爬打死(旧注释就是上一次留下的),
// 结果为空 → 一定不含精确同名 → 必然补 smartbox,行为退回 2026-09-02 之前的样子。
func qqSearchSongs(ctx context.Context, queries []string, title string) []qqSearchItem {
	var out []qqSearchItem
	seen := map[string]bool{}
	appendNew := func(items []qqSearchItem) {
		for _, it := range items {
			if it.Mid == "" || seen[it.Mid] {
				continue
			}
			seen[it.Mid] = true
			out = append(out, it)
		}
	}
	for _, q := range queries {
		if items, err := qqClientSearch(ctx, q); err == nil {
			appendNew(items)
		}
	}
	if qqSearchNeedsSmartboxSupplement(out, title) {
		for _, q := range queries {
			if items := qqSmartbox(ctx, q); len(items) > 0 {
				appendNew(qqSearchItemsFromSmartbox(items))
				break
			}
		}
	}
	return out
}

// qqSearchNeedsSmartboxSupplement 判断要不要再补一次 smartbox:正式搜索的结果里已经
// 有**标题与本地曲名精确同名**的候选时就不补(理由见 qqSearchSongs 的 ② 段)。
// 一条都没搜到、或者本地曲名为空(无从判断)时一律补,这也是正式接口再次被反爬打死时
// 的降级路径。
func qqSearchNeedsSmartboxSupplement(items []qqSearchItem, title string) bool {
	if len(items) == 0 {
		return true
	}
	want := normLoose(title)
	if want == "" {
		return true
	}
	for _, it := range items {
		if normLoose(it.Name) == want {
			return false
		}
	}
	return true
}

// qqSearchItemsFromSmartbox 把 smartbox 兜底路线的结果归一成 qqSearchItem。
// Album/Interval 一律留零值——smartbox 的响应里压根没有这两个字段,留零就是在告诉
// 下游"这条路线没给,该查还得自己查",不能拿别处的值糊上去。
func qqSearchItemsFromSmartbox(items []qqSmartboxItem) []qqSearchItem {
	out := make([]qqSearchItem, 0, len(items))
	for _, it := range items {
		out = append(out, qqSearchItem{Mid: it.Mid, Name: it.Name, Singer: it.Singer})
	}
	return out
}

// qqSingerAvatar 给"历史播放 Top10 歌手"(见 topartists.go)查一张歌手头像,复用
// smartbox_new.fcg 这同一个免认证接口,但读的是响应里的"singer"分类(qqSmartbox 只读
// "song"分类,两者是同一份 JSON 里并列的不同板块,需各自独立请求、不能共用同一个
// http.Response)。只取第一个结果,不做 artistMatches 那类严格核验——这里只是找一张
// 装饰用的头像,不是核实版权归属,找错了最多是头像不准,不像歌词/封面匹配错那样是
// 功能性 bug。查不到/网络失败返回空,调用方(topartists.go 的 resolveArtistAvatar)
// 会转去 Deezer 兜底。
// 返回 (头像 URL, definitive)。definitive 区分两种"没有":true = 服务端正常应答且
// 确定查无此人(可以放心负缓存);false = 网络/非 200/解码失败这类**暂时故障**,不能
// 当"查无"记下来 —— avatarcli 曾把两者都缓存 14 天,离线打开一次页面就让一批歌手
// 14 天只显示首字母(2026-08-11 审阅确认)。
// qqSingerSuggestion 是 smartbox_new.fcg "singer" 分类返回的一条建议——qqSingerAvatar
// (取头像)和 qqArtistCanonicalName(取歌手名换算,见其头注)共用同一次网络请求/同一份
// 解码,避免两个调用点各自发一遍请求。
type qqSingerSuggestion struct {
	Name string
	Pic  string
}

// qqSingerSuggestions 查 QQ 音乐的歌手搜索建议——用 qqSmartbox 同一个免认证接口,读的是
// "singer"分类(qqSmartbox 只读"song"分类,是同一份 JSON 里并列的不同板块)。
//
// 返回值第二项区分"服务端正常应答"(true,itemlist 可能是空——服务端明确说没有这个歌手)
// 和"网络/状态码/解码失败"(false,这次没查到任何结论,不代表"确认没有")——调用方各自
// 需要不同的处理:qqSingerAvatar 只在 ok=false 时报"暂时故障"，qqArtistCanonicalName
// 的缓存包装同理只在 ok=false 时不落盘负缓存。
func qqSingerSuggestions(name string) ([]qqSingerSuggestion, bool) {
	u := "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?_=1&cv=4747474&ct=24&format=json&is_xml=0&key=" + neturl.QueryEscape(name)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, false
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	var out struct {
		Data struct {
			Singer struct {
				ItemList []struct {
					Name string `json:"name"`
					Pic  string `json:"pic"`
				} `json:"itemlist"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, false
	}
	items := make([]qqSingerSuggestion, 0, len(out.Data.Singer.ItemList))
	for _, it := range out.Data.Singer.ItemList {
		items = append(items, qqSingerSuggestion{Name: it.Name, Pic: it.Pic})
	}
	return items, true
}

func qqSingerAvatar(name string) (string, bool) {
	items, ok := qqSingerSuggestions(name)
	if !ok {
		return "", false
	}
	if len(items) == 0 {
		return "", true // 服务端明确说没有这个歌手
	}
	pic := items[0].Pic
	if pic == "" {
		return "", true
	}
	// 接口给的是 150x150 缩略图(跟 qqSongCoverAndSinger 拼专辑封面同一个 CDN 套路),把
	// 分辨率前缀换成 300x300、协议换成 https 同一个 mid 也能取到更清晰的图;页面本身全程
	// https,混合内容图片在部分浏览器/CSP 下有被拦截风险,统一升级更稳妥。
	//
	// 走 qqCoverAtEdge 而不是原来那句写死的 `Replace("R150x150","R300x300")`:接口哪天
	// 换成别的档(200/240…)那句就静默不生效、留着一张小图。这里仍然只提到 300 —— 这个
	// URL 的消费方是网页「历史播放 Top10 歌手」那排小头像,不是歌词窗口那张大卡,
	// 提到 800 只是白烧流量。
	pic = qqCoverAtEdge(pic, "300")
	pic = strings.Replace(pic, "http://", "https://", 1)
	return pic, true
}

// qqArtistCanonicalName 用 QQ 音乐自己的歌手搜索建议,把一个罗马化/英文歌手名换成 QQ
// 曲库认得的写法(通常是中文名)。
//
// 2026-08-31 加,起因是通用链路 canonicalArtistViaMusicBrainz/musicBrainzArtistAliases
// 在"罗马化姓名 → 中文艺人"这个场景上有两类实测坐实的真实缺口:
//  1. 查不到——李荣浩/窦靖童/陈柏宇/曲婉婷等十余位,MusicBrainz 索引或别名登记不覆盖。
//  2. 查错人——同名撞车:MusicBrainz 对 "David Tao" 排第一的是一位无关的德国音乐人
//     (陶喆本人反而没有查到中文别名);对 "Lexie Liu" 给出的是"刘昱妤",跟刘柏辛完全
//     是两个人。
//
// QQ 音乐作为中文平台,它自己的搜索建议本来就是为"用户拿英文/罗马化名字搜华语歌手"这个
// 场景服务的,实测同一批人绝大多数都能直接查对,包括两个 MusicBrainz 查错人的案例。
//
// ⚠️ 只看**第一条**建议,不扫描整份列表——2026-08-31 实测坐实两个反例,分别对应"扫描
// 整份列表"和"只看第一条"这两种做法各自的坑,必须两条都躲开:
//   - "Prince":第一条建议就是"Prince"自己(没有汉字,他本来就不需要中文名),但第二条
//     建议是"戴爱玲"——一个毫不相关的歌手。早期实现"扫描全部建议取第一个含汉字的"会把
//     这条噪声当成解析结果,而 Prince 这个真实案例混进 Top 歌手榜合并逻辑会把 Prince
//     的播放量错记到戴爱玲名下。QQ 的自动补全本来就不是身份核验,列表越往后越不相关。
//   - "Wanting":第一条建议是"婉婷"——含汉字、但查证下来是**另一个人**(QQ 上一位无关
//     歌手,跟"婉婷/杨炆"合唱,跟真正的曲婉婷毫无关系),真正对应曲婉婷的"曲婉婷"反而是
//     第二条。这条反过来证明"只信第一条"也不是万能的——第一条同样可能是同名撞车。
//
// 两个反例合起来说明:这份接口终究是个模糊补全,不是身份核验,没有一种"扫描位置"的
// 策略能同时躲开两类坑。选择只信第一条,是因为它已经覆盖了绝大多数真实案例、且"查不到"
// 比"扫描更靠后的位置、查到错误答案"更安全——查不到会诚实地退回调用方的下一级信号
// (resolveGenericArtistCanonicalName 里的手工表兜底),查错答案却会被当成确定结果直接
// 写进展示字段。"wanting"/"hikaru utada"(第一条建议是"Utada"、没有汉字)这两个已知
// 撞不上的案例保留在 artistAliasTable 里当真实残留,不强求这里的启发式覆盖到 100%。
func qqArtistCanonicalName(rawArtist string) string {
	items, ok := qqSingerSuggestions(rawArtist)
	if !ok || len(items) == 0 {
		return ""
	}
	return pickQQArtistCanonicalName(items[0].Name, rawArtist)
}

// pickQQArtistCanonicalName 是上面查询的判据部分,拆出来纯函数好测:命中的建议必须
// 含汉字(否则跟原始罗马化写法没有信息增量),且不能(忽略大小写/空格后)原样等于
// 输入本身——避免把查询词自己当成"解析结果"回传。
//
// ⚠️ 这里没有 artistMatches 那类严格核验(这里没有具体曲目可比对),置信度来自 QQ 自己
// 的搜索排序;调用方如果需要更高置信度(比如直接展示成正式署名),应该结合别的信号
// 交叉验证,不要单独当作绝对真相。
func pickQQArtistCanonicalName(suggestion, rawArtist string) string {
	suggestion = strings.TrimSpace(suggestion)
	if suggestion == "" || !containsHan(suggestion) {
		return ""
	}
	if normLoose(suggestion) == normLoose(rawArtist) {
		return ""
	}
	return suggestion
}

// qqArtistNameCache 是 qqArtistCanonicalName 的持久化缓存,跟 artistAliasCache/
// mbPrimaryNameCache 同一套"查一次永久生效,但只有查到非空结果才落盘"的规则(理由见
// musicbrainz.go 里 saveArtistAliasCache 前的注释——一次偶发的网络/接口故障不该把
// 一位歌手永久钉死在"没有中文名"上)。
var (
	qqArtistNameMu    sync.Mutex
	qqArtistNameCache = map[string]string{}
	qqArtistNamePath  string
	qqArtistNameDirty bool
)

func loadQQArtistNameCache(path string) {
	qqArtistNamePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		qqArtistNameMu.Lock()
		qqArtistNameCache = m
		qqArtistNameMu.Unlock()
		log.Printf("loaded %d cached QQ artist names from %s", len(m), path)
	}
}

func saveQQArtistNameCache() {
	qqArtistNameMu.Lock()
	if !qqArtistNameDirty || qqArtistNamePath == "" {
		qqArtistNameMu.Unlock()
		return
	}
	keep := make(map[string]string, len(qqArtistNameCache))
	for k, v := range qqArtistNameCache {
		if v != "" {
			keep[k] = v
		}
	}
	data, err := json.Marshal(keep)
	qqArtistNameDirty = false
	qqArtistNameMu.Unlock()
	if err != nil {
		return
	}
	tmp := qqArtistNamePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, qqArtistNamePath); err != nil {
		log.Printf("save QQ artist name cache: %v", err)
	}
}

// cachedQQArtistCanonicalName 是 qqArtistCanonicalName 的缓存包装,跟
// canonicalArtistViaMusicBrainz 同一个模式:containsHan 守卫(已经是中文标签的不必
// 查)、查一次缓存住。
func cachedQQArtistCanonicalName(rawArtist string) string {
	rawArtist = strings.TrimSpace(rawArtist)
	if rawArtist == "" || containsHan(rawArtist) {
		return ""
	}

	qqArtistNameMu.Lock()
	if v, ok := qqArtistNameCache[rawArtist]; ok {
		qqArtistNameMu.Unlock()
		return v
	}
	qqArtistNameMu.Unlock()
	if artistCanonicalCacheOnly {
		return "" // 见 musicbrainz.go artistCanonicalCacheOnly
	}

	resolved := qqArtistCanonicalName(rawArtist)

	qqArtistNameMu.Lock()
	qqArtistNameCache[rawArtist] = resolved
	if resolved != "" {
		qqArtistNameDirty = true
	}
	qqArtistNameMu.Unlock()
	saveQQArtistNameCache()
	return resolved
}

// qqSongAlbum returns the album name for a QQ song mid via the single-song
// detail API (album is at data[0].album.name). Empty on any failure — callers
// treat that as "unknown album" and fall back to name-based selection.
func qqSongAlbum(ctx context.Context, mid string) string {
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var out struct {
		Data []struct {
			Album struct {
				Name string `json:"name"`
			} `json:"album"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return ""
	}
	if len(out.Data) == 0 {
		return ""
	}
	return out.Data[0].Album.Name
}

// QQ 音乐图床的尺寸档写在**路径**里(`T002R300x300M000<mid>.jpg`),换个数字就换一档。
// 800 是天花板:2026-08-24 对两个不同的 album mid 各测一轮,300/500/800 都 200,
// 1000 与 2000 都 404。不带 Referer 也照给(实测 200)。
//
// 原来这里写死 300x300,而歌词窗口那张封面卡满幅是 820px(0.279×1470pt 窗宽 ×2),
// 300px 顶上去是 2.73 倍放大 —— 用户报的"QQ 音乐这个封面很模糊"。
const qqCoverMaxEdge = "800"

// qqCoverSizeRe 匹配 QQ 图床路径里的那一段尺寸档。T001 是歌手头像、T002 是专辑封面,
// 两种前缀同一套规则(都实测过 800 给图),所以只认 `T<数字>R` 这个形状、不写死前缀。
var qqCoverSizeRe = regexp.MustCompile(`(T[0-9]+R)[0-9]+x[0-9]+(M)`)

// qqCoverAtEdge 把一条 QQ 图床 URL 的尺寸档换成 edge。不是 QQ 图床、或路径里没有那一段
// 时原样返回 —— 判 host 而不是光看形状:别的图源万一路径里也有类似片段,改了就是 404。
func qqCoverAtEdge(raw, edge string) string {
	if raw == "" || edge == "" {
		return raw
	}
	if !strings.Contains(raw, "y.qq.com/music/photo_new/") &&
		!strings.Contains(raw, "y.gtimg.cn/music/photo_new/") {
		return raw
	}
	if !qqCoverSizeRe.MatchString(raw) {
		return raw
	}
	return qqCoverSizeRe.ReplaceAllString(raw, "${1}"+edge+"x"+edge+"${2}")
}

// qqAlbumCoverURL 按专辑 mid 拼封面 URL,取图床能给的最大一档(见 qqCoverMaxEdge)。
func qqAlbumCoverURL(albumMid string) string {
	if albumMid == "" {
		return ""
	}
	return "https://y.qq.com/music/photo_new/T002R" + qqCoverMaxEdge + "x" + qqCoverMaxEdge +
		"M000" + albumMid + ".jpg"
}

// qqSongCoverAndSinger returns (album cover URL, primary singer name) for a QQ
// song mid via the same single-song detail API qqSongAlbum uses. The singer is
// returned so callers can re-verify identity before trusting the cover (a QQ
// smartbox hit can itself be a fan/cover account; see qqCoverFallback).
func qqSongCoverAndSinger(ctx context.Context, mid string) (cover, singer string) {
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", ""
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return "", ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", ""
	}
	var out struct {
		Data []struct {
			Album struct {
				Mid string `json:"mid"`
			} `json:"album"`
			Singer []struct {
				Name string `json:"name"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 {
		return "", ""
	}
	d := out.Data[0]
	if d.Album.Mid == "" {
		return "", ""
	}
	if len(d.Singer) > 0 {
		singer = d.Singer[0].Name
	}
	return qqAlbumCoverURL(d.Album.Mid), singer
}

// qqSongCatalogMids 取一首歌的 专辑 mid 与 首位歌手 mid —— 歌词窗口「前往专辑/前往艺人」
// 在播放器是 QQ 音乐时要的就是这两个,页面路由分别是 y.qq.com/n/ryqq/albumDetail/<mid>
// 与 /n/ryqq/singer/<mid>(实测都 302 到 /n/ryqq_v2/…,与代码在用的 songDetail 同族)。
//
// 打的是跟 qqSongCoverAndSinger 同一个 single-song 详情接口 —— 那边只拿 album.mid 拼了
// 封面 URL、把 singer 的 mid 丢掉了,所以这里单独要一次,不复用它的返回值。
//
// 多歌手只取第一位:QQ 的歌手页是一人一页,合唱曲目没有"这首歌的歌手页"这种东西,
// 取主歌手是唯一说得通的选择(与 CanonicalArtist 只在单一歌手时才给值同一个取向)。
func qqSongCatalogMids(ctx context.Context, mid string) (albumMid, singerMid string) {
	if mid == "" {
		return "", ""
	}
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", ""
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return "", ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", ""
	}
	var out struct {
		Data []struct {
			Album struct {
				Mid string `json:"mid"`
			} `json:"album"`
			Singer []struct {
				Mid string `json:"mid"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 {
		return "", ""
	}
	d := out.Data[0]
	if len(d.Singer) > 0 {
		singerMid = d.Singer[0].Mid
	}
	return d.Album.Mid, singerMid
}

// qqCoverFallback finds an official-artist cover via QQ Music for when
// NetEase's own catalog has no genuine match for this artist — rights-
// withdrawn artists (Jay Chou is the case that surfaced this; see the
// artistMatches comment) are absent from NetEase entirely, so searching there
// only turns up impersonator accounts. Requires a strict (non-loose) artist
// match on BOTH the smartbox search hit and the detail-lookup singer field,
// so a QQ-side impersonator/cover account can't slip through either step.
// 第二个返回值是 QQ 音乐核实过的官方歌手名(见下方 artistMatches 校验)，用于统一同一
// 歌手在历史记录里时而中文时而英文、时而全大写的写法(如 PRINCE/Prince)。
//
// 2026-08-03 实测排查坐实(Michael Jackson《Morphine》——本地专辑标签是
// "BLOOD ON THE DANCE FLOOR/ HIStory In The Mix",网页黑胶封面却显示成完全不相关的
// 精选集《The Indispensable Collection》):这里原来"smartbox 结果里第一条双重校验
// 通过的就是最终结果",跟同一文件里 resolveQQMusicMatch(给"QQ音乐链接"用)不是同一套
// 选择逻辑——那边有 album 参数时会给前几条候选补专辑名、按 albumScore 选出最贴合本地
// 专辑的那条,避免"同一首歌被合辑/精选集顶替"(albumScore 函数注释原文就点名了
// "The Indispensable Collection" 这个例子)；这边完全没有这层专辑感知,只要 smartbox
// 搜索结果第一条身份对得上就直接采用它的封面,哪个专辑版本排在前面全凭 QQ 搜索接口
// 自己的排序,拿到精选集封面纯属运气不好。现在补上跟 resolveQQMusicMatch 同一套
// album 打分:调用方传了专辑名时,先在前几条候选(封顶 4 条,理由/上限跟
// resolveQQMusicMatch 一致——降低多打详情接口的次数)里按 albumScore 挑出最贴合的
// 一条,单独过一遍下面这层身份校验;通不过(或本来就没传专辑名)时,原样退回到"逐条
// 按 smartbox 原始顺序试、第一条双重校验通过就用"这条既有兜底路径,不会比改之前更
// 容易返回空。
func qqCoverFallback(ctx context.Context, artist, title, album string) (cover, canonicalArtist string) {
	if artist == "" || title == "" {
		return "", ""
	}
	// 跟 netease.go 里 chosen 分支同样的道理:本地标签本来就是多人合credit(如"Prince
	// & The Revolution")时,QQ 的 singer 字段可能只单独记了其中一位——不把这个当统一
	// 歌手名用,避免悄悄丢掉本地已经写全的合作者;封面照常正常解析,不受影响。
	singleArtist := len(artistCreditParts(artist)) < 2
	type qqCoverCand struct {
		mid   string
		album string // 搜索结果自带的专辑名(client_search_cp 路线才有),空=要另外查
		exact bool   // name 与 title loose 相等,跟 resolveQQMusicMatch 的 exact 同一含义
	}
	var cands []qqCoverCand
	for _, it := range qqSearchSongs(ctx, qqSearchQueries(artist, title), title) {
		if it.Mid == "" || !lyricTitleAccepted(it.Name, title) ||
			!artistMatches(it.Singer, artist) {
			continue
		}
		cands = append(cands, qqCoverCand{mid: it.Mid, album: it.Album, exact: normLoose(it.Name) == normLoose(title)})
	}
	tryCand := func(c qqCoverCand) (string, string, bool) {
		cover, singer := qqSongCoverAndSinger(ctx, c.mid)
		if cover == "" || !artistMatches(singer, artist) {
			return "", "", false
		}
		if !singleArtist {
			return cover, "", true
		}
		return cover, singer, true
	}
	if album != "" {
		limit := len(cands)
		if limit > 4 {
			limit = 4
		}
		bestIdx, bestScore, bestExact := -1, 0, false
		for i := 0; i < limit; i++ {
			mid := cands[i].mid
			sc := albumScore(qqCandAlbumName(cands[i].album, func() string { return qqSongAlbum(ctx, mid) }), album)
			if sc == 0 && !cands[i].exact {
				continue
			}
			if bestIdx == -1 || (cands[i].exact && !bestExact) || (cands[i].exact == bestExact && sc > bestScore) {
				bestIdx, bestScore, bestExact = i, sc, cands[i].exact
			}
		}
		if bestIdx != -1 {
			if cover, singer, ok := tryCand(cands[bestIdx]); ok {
				return cover, singer
			}
		}
	}
	for _, c := range cands {
		if cover, singer, ok := tryCand(c); ok {
			return cover, singer
		}
	}
	return "", ""
}

// resolveQQMusicURL finds the QQ Music song-detail URL for a track. smartbox
// yields a real songmid, so the link opens the actual song on both desktop
// (y.qq.com/n/ryqq/songDetail) and the i.y.qq.com mobile player — a search
// link, by contrast, redirects mobile users to a useless QQ landing page.
// When the album is known, the top few candidates are enriched with their
// album name and the best albumScore wins, avoiding same-song-wrong-album
// compilations. Returns "" (→ caller uses a search link) only when nothing
// plausibly matches; never a confidently-wrong song.
// qqArtistOK reports whether singer counts as an identity match for artist under
// the given strictness. artist=="" 表示调用方本来就没有可比对的歌手名，视为通过
// (标题匹配已经把关)。strict 用 artistMatches(逐段精确相等)；否则退化到 looseContains
// (规整后互相包含)——比 artistMatches 宽松，但仍要求歌手名字面上沾得上边，不是零校验。
func qqArtistOK(strict bool, singer, artist string) bool {
	if artist == "" {
		return true
	}
	if strict {
		// strict 档从 artistMatches 换成 lyricSourceArtistMatches(2026-08-20):QQ 的
		// 合唱署名用斜杠("UMI/V"),本地标签 "UMI & 金泰亨" 在原闸下两档全拒——loose 的
		// looseContains("umiv","umi金泰亨") 同样不含。段集交集档正好补这个洞,防仿冒
		// 守卫见 lyricSourceArtistMatches 注释。
		return lyricSourceArtistMatches(singer, artist)
	}
	return looseContains(singer, artist)
}

// qqMusicMatch 是 resolveQQMusicURL 选中同一个 mid 时顺带就已经拿到、原来直接丢掉的
// 匹配信息——title/artist 来自 smartbox 搜索结果本身(it.Name/it.Singer),album 来自
// (如果查询带了专辑名)顺带查过的 qqSongAlbum(mid)。给"搜索候选歌词"弹窗展示用,不
// 参与任何匹配/打分逻辑。
//
// interval 只有专辑维度路线(resolveQQMatchViaAlbum)会填:GetAlbumSongList 顺带给了
// 每首的官方时长(秒),enrich.go 把它当 srcDur 透传给打分;smartbox 路线拿不到时长,留 0
// (那边照旧走 qqSongMetaCachedOnly 的"QRC 路径查过详情就有"的只读缓存)。
//
// unreliable:专辑维度路线因网络层失败没能给出结论、这个 match 是回落的歌名维度结果时
// 置位——qqMusicMatchCached 见它就不写缓存,下一轮重搜有机会翻案(不置位的话,一次
// smartbox 超时就把录音室版按 artist|title|album 永久钉进本进程的 qqURLCache)。
type qqMusicMatch struct {
	url, title, artist, album string
	interval                  float64
	unreliable                bool
}

func resolveQQMusicURL(ctx context.Context, artist, title, album string) string {
	return resolveQQMusicMatch(ctx, artist, title, album).url
}

// qqCand 是歌名维度的一条候选。提到包级(原来是 resolveQQMusicMatch 里的局部类型)只为
// 一件事:让 qqCollectCandidates 能被单测直接调。身份闸怎么放行、以及"搜索结果自带的
// 专辑名/时长有没有一路透传到候选上",以前都内联在一个必须联网的函数里,单测根本够不到
// ——2026-09-02 变异测试在 pickQQAlbumTrack 上暴露过同型盲区(改了调用点单测全绿),
// 这里照同样的处置先拆出来再测。
type qqCand struct {
	mid, title, artist string
	album              string  // 搜索结果自带的专辑名(client_search_cp 路线才有),空=要另外查
	interval           float64 // 搜索结果自带的官方时长(秒),0=没给
	exact              bool    // name 与 title loose 相等 → 规范版,避开 纯音乐/串烧/live 变体
}

// qqCollectCandidates 按标题闸 + 身份闸把搜索结果筛成候选,并把搜索结果自带的
// 专辑名/时长原样带上。strict 的两档含义见 qqArtistOK。
func qqCollectCandidates(items []qqSearchItem, artist, title string, strict bool) []qqCand {
	var cs []qqCand
	for _, it := range items {
		if it.Mid == "" || !lyricTitleAccepted(it.Name, title) ||
			!qqArtistOK(strict, it.Singer, artist) {
			continue
		}
		cs = append(cs, qqCand{
			mid: it.Mid, title: it.Name, artist: it.Singer,
			album: it.Album, interval: it.Interval,
			exact: normLoose(it.Name) == normLoose(title),
		})
	}
	return cs
}

// qqCandAlbumName 决定拿哪个专辑名去 albumScore:搜索结果自带就用自带的
// (client_search_cp 路线本来就返回专辑名),没有才回落到单曲详情多打一次请求。
//
// 单独拆成一个函数不是洁癖:2026-09-02 变异测试确认,这段逻辑内联在
// resolveQQMusicMatch/qqCoverFallback 这两个**必须联网**的函数里时,把它整段改回
// "永远重新查",单测全绿——也就是"自带专辑名到底有没有被用上"根本没人守。
func qqCandAlbumName(inline string, fetch func() string) string {
	if inline != "" {
		return inline
	}
	return fetch()
}

// qqCreditSetEqual 判断候选的署名与本地署名是**同一组人**(规整后逐段相等,不计顺序)。
// 跟 lyricSourceArtistMatches 那种"有交集就算数"的身份闸不是一回事:那是**准入**闸,
// 宽一点才不会把跨平台写法差异挡在门外;这个只用作**最后一档 tiebreak**,专门区分
// "同名同专辑、但一条是独唱一条是合唱"。
//
// 2026-09-02 回放实测的那一条:陶喆《逗阵兄弟 (独唱版)》,QQ 上独唱(陶喆,335s)与合唱
// (陶喆/卢广仲,306s)同名同专辑《再见你好吗》,albumScore 都是 200、都不是标题精确同名
// ——改造前靠 smartbox 只回独唱那条侥幸选对,合并召回之后两条同时在池子里,胜负就只由
// 谁排在前面决定了。而排序恰恰是 searchTitleVariants 的既有约定(标题里的装饰不在已知
// 版本限定词表内时,去括号那版排在前面)顺带决定的,不是一个可靠信号。所以这里补一个
// **显式**判据,不去动那个排序约定。
func qqCreditSetEqual(singer, artist string) bool {
	if singer == "" || artist == "" {
		return false
	}
	a, b := artistCreditParts(singer), artistCreditParts(artist)
	if len(a) == 0 || len(a) != len(b) {
		return false
	}
	left := map[string]int{}
	for _, p := range a {
		left[p]++
	}
	for _, p := range b {
		if left[p] == 0 {
			return false
		}
		left[p]--
	}
	return true
}

// qqMatchFromCand 把一条候选装成 qqMusicMatch。三个出口原来各写一份 struct literal,
// 漏掉 album/interval 里的任何一个都不会报错,只会静默少一个打分信号(专辑名喂
// versionTagsMismatch,时长喂 sourceDurationMismatchPenalty)——收敛成一处,单测守一处。
func qqMatchFromCand(c qqCand, unreliable bool) qqMusicMatch {
	return qqMusicMatch{
		url: qqSongURL(c.mid), title: c.title, artist: c.artist,
		album: c.album, interval: c.interval, unreliable: unreliable,
	}
}

// qqPickCandidate 在候选里挑冠军。两档优先级,同档取先出现的那条(搜索接口按相关度
// 排序,首条通常是规范版):
//
//	① 标题精确同名 —— 避开 纯音乐/串烧/live 这类变体,权重最高;
//	② 署名恰好是同一组人 —— 只作同档内的 tiebreak,区分独唱/合唱,见 qqCreditSetEqual。
func qqPickCandidate(cands []qqCand, artist string) (qqCand, bool) {
	var best qqCand
	haveBest, bestRank := false, -1
	for _, c := range cands {
		rank := 0
		if qqCreditSetEqual(c.artist, artist) {
			rank++
		}
		if c.exact {
			rank += 2
		}
		if !haveBest || rank > bestRank {
			best, haveBest, bestRank = c, true, rank
		}
	}
	return best, haveBest
}

func resolveQQMusicMatch(ctx context.Context, artist, title, album string) qqMusicMatch {
	items := qqSearchSongs(ctx, qqSearchQueries(artist, title), title)
	if len(items) == 0 {
		// 歌手名跨平台不一致时,退一步只按标题再搜(同样要带上去括号的那一版)
		items = qqSearchSongs(ctx, searchTitleVariants(title), title)
	}
	// strict 档用 artistMatches(要求逗号/&等分隔的每一段都精确相等);strict 一无所获时
	// 放宽成 looseContains 重试——但绝不完全跳过校验:完全不查歌手会让标题撞上、歌手完全
	// 不相干的翻唱/仿冒账号蒙混过关、链接指向错误的人(同 match.go artistMatches 注释里
	// Jay Chou 那次教训同理;这里此前就是"完全不查")。
	cands := qqCollectCandidates(items, artist, title, true)
	if len(cands) == 0 {
		cands = qqCollectCandidates(items, artist, title, false) // artistMatches 太严格(跨平台歌手名写法不同)时放宽成 looseContains,但仍要求歌手名沾边
	}
	if len(cands) == 0 {
		// 歌名维度一无所获 → 专辑维度还有机会(标题带括号时 smartbox 恒 0 条;命中不了
		// 就照旧返回零值,上层退搜索链接,绝不给错歌)。零值本来就不进缓存,degraded
		// 信号在这条路径上不用管。
		m, _ := resolveQQMatchViaAlbum(ctx, artist, title, album)
		return m
	}
	// 有专辑名 → 给前几条补专辑、按 albumScore 去重。采集器一首歌只解析一次,
	// 频次低;补专辑失败(反爬/超时)时降级到按名字选,不影响出具体歌链接。
	viaAlbumDegraded := false // 专辑路线曾网络失败 → 本函数所有回落出口都要打 unreliable
	if album != "" {
		var best qqCand
		haveBest, bestScore, bestExact, bestCreditEq := false, 0, false, false
		// 条数上限只约束**需要额外发一次详情请求**的候选(上限的初衷就是别为一首歌
		// 反复打详情接口)。client_search_cp 路线的专辑名是搜索结果自带的、不花请求,
		// 全部参与比较——这个上限当年是照着 smartbox"短而紧"的候选表定的,套在一次回
		// 十条的正式搜索结果上会把正确的那条挡在门外。
		fetched := 0
		for _, c := range cands {
			if c.album == "" && fetched >= qqAlbumLookupBudget {
				continue
			}
			if c.album == "" {
				fetched++
			}
			candAlbum := qqCandAlbumName(c.album, func() string { return qqSongAlbum(ctx, c.mid) })
			sc := albumScore(candAlbum, album)
			if sc == 0 && !c.exact {
				continue // 专辑对不上、标题也非精确同名 → 不够格参与本轮选择
			}
			// 标题精确同名优先于专辑分(与 albumScore 的 exact>loose 分层同一原则):避免
			// 同专辑里一首标题超串/子串的非规范版(live/伴奏等)靠专辑分打平甚至反超真正
			// 同名曲目——历史上这类打分边界条件已经在 albumScore 上出过一次真实 bug。
			// 优先级:标题精确同名 > 专辑分 > 署名恰好同一组人。最后一档只在前两项都打平时
			// 起作用,专门区分同名同专辑的独唱/合唱两条,见 qqCreditSetEqual。
			creditEq := qqCreditSetEqual(c.artist, artist)
			better := !haveBest ||
				(c.exact && !bestExact) ||
				(c.exact == bestExact && sc > bestScore) ||
				(c.exact == bestExact && sc == bestScore && creditEq && !bestCreditEq)
			if better {
				best = c
				best.album = candAlbum // 自带为空时这里装的是刚查到的那个,别丢回去
				haveBest, bestScore, bestExact, bestCreditEq = true, sc, c.exact, creditEq
			}
		}
		if haveBest && bestScore > 0 {
			return qqMatchFromCand(best, false)
		}
		// 歌名维度找到了条目但**专辑证据为零**(smartbox 只回热门录音室版是常态——2026-09-01
		// 周杰伦《龙拳 (Live)》案:它对 "周杰伦 龙拳" 恒只回八度空间那一条,The One 演唱会的
		// Live 版根本不在联想结果里)→ 先试专辑维度,能以专辑为锚找到对版就用它。
		var viaAlbum qqMusicMatch
		viaAlbum, viaAlbumDegraded = resolveQQMatchViaAlbum(ctx, artist, title, album)
		if viaAlbum.url != "" {
			return viaAlbum
		}
		// 专辑维度也没有 → 回落到原有行为(标题精确同名但专辑对不上的那条)。专辑路线是
		// 因网络失败(而非"确定没有")空手而回时,给回落结果打 unreliable,不让它进缓存。
		if haveBest {
			return qqMatchFromCand(best, viaAlbumDegraded)
		}
	}
	// 无专辑 / 补专辑没命中 → 精确同名优先,否则第一条(smartbox 首条通常是规范版)。
	// 这两个出口同样可能是专辑路线网络失败后的回落(龙拳案的录音室候选 exact=false、
	// 专辑分 0,bestMid 一直是空,实际就落在 cands[0] 这里),unreliable 一并带上。
	// album/interval:client_search_cp 路线在搜索结果里就带着,由 qqMatchFromCand 原样
	// 透传——专辑名喂给打分的 versionTagsMismatch / 候选弹窗展示,时长喂给
	// sourceDurationMismatchPenalty,跟专辑维度路线(resolveQQMatchViaAlbum)填 interval
	// 是同一个字段、同一套语义。smartbox 兜底路线两者都是零值,行为与改造前一致。
	c, ok := qqPickCandidate(cands, artist)
	if !ok {
		return qqMusicMatch{}
	}
	return qqMatchFromCand(c, viaAlbumDegraded)
}

// ---- 专辑维度检索路线(2026-09-01) ----
//
// 起因(用户报"QQ 搜出来的是录音室版"):smartbox 是**前缀联想**不是搜索——对
// "周杰伦 龙拳" 恒只回八度空间录音室版那一条,加词("周杰伦 龙拳 Live")、带括号都直接
// 0 条;而 QQ 给现场专辑曲目起名**不带 (Live)**(The One 演唱会里就叫"龙拳"),live 身份
// 只在专辑名上。也就是说歌名维度**永远**够不到现场专辑曲目,必须以专辑为锚:
// smartbox 的 album 分类(实测 "周杰伦 The One" 能命中专辑,而带上"周杰伦演唱会"后缀
// 就 0 条——所以查询词要先剥歌手名和现场类通用词)→ GetAlbumSongList 拉曲目单
// (musicu.fcg 未登录可用,实测)→ 按标题闸挑曲目。
//
// 这条路线只在歌名维度**拿不出专辑证据**时启用(见 resolveQQMusicMatch 里的调用点),
// 三道身份闸:专辑歌手 looseContains、albumScore≥1、曲目 lyricTitleAccepted 且最优
// 档位内唯一——宁可空手而归回落旧行为,不给错歌。

var (
	qqAlbumSongsMu    sync.Mutex
	qqAlbumSongsCache = map[string][]qqAlbumSong{}
)

type qqAlbumSong struct {
	mid, name, singer string
	interval          float64 // 官方时长,秒
}

// qqAlbumSongs 拉一张专辑的曲目单(mid/曲名/歌手/时长),按 albumMid 缓存。
// num=100:够覆盖演唱会专辑的常见规模(The One 20 首、地表最强 30+),真超过也只是
// 尾部曲目挑不到,不会挑错。error 非 nil = 网络层失败(区分"确定没有",同 qqSmartboxAlbums)。
func qqAlbumSongs(ctx context.Context, albumMid string) ([]qqAlbumSong, error) {
	if albumMid == "" {
		return nil, nil
	}
	qqAlbumSongsMu.Lock()
	if v, ok := qqAlbumSongsCache[albumMid]; ok {
		qqAlbumSongsMu.Unlock()
		return v, nil
	}
	qqAlbumSongsMu.Unlock()
	data, err := qqMusicuPost(ctx, "GetAlbumSongList", "music.musichallAlbum.AlbumSongList", map[string]any{
		"albumMid": albumMid, "begin": 0, "num": 100, "order": 2,
	}, qqCommBase)
	if err != nil {
		return nil, err
	}
	var out struct {
		SongList []struct {
			SongInfo struct {
				Mid      string  `json:"mid"`
				Name     string  `json:"name"`
				Interval float64 `json:"interval"`
				Singer   []struct {
					Name string `json:"name"`
				} `json:"singer"`
			} `json:"songInfo"`
		} `json:"songList"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	songs := make([]qqAlbumSong, 0, len(out.SongList))
	for _, s := range out.SongList {
		si := s.SongInfo
		if si.Mid == "" || si.Name == "" {
			continue
		}
		singer := ""
		if len(si.Singer) > 0 {
			singer = si.Singer[0].Name
		}
		songs = append(songs, qqAlbumSong{mid: si.Mid, name: si.Name, singer: singer, interval: si.Interval})
	}
	if len(songs) > 0 {
		qqAlbumSongsMu.Lock()
		qqAlbumSongsCache[albumMid] = songs
		qqAlbumSongsMu.Unlock()
	}
	return songs, nil
}

// qqAlbumIdentityQuery:本地专辑名剥掉括号段、歌手名和 live 类通用词之后的"身份串",
// 给 smartbox 的 album 分类当查询词。实测(2026-09-01):本地标签"The One 周杰伦演唱会",
// 查 "周杰伦 The One 周杰伦演唱会"/"The One 演唱会" 都是 0 条,查 "周杰伦 The One" 命中
// ——smartbox 对多余的词零容忍,必须把非身份成分全剥掉。统一转小写+简体:查询对大小写
// 不敏感,而 ToLower 后再做子串定位不会有字节错位。
func qqAlbumIdentityQuery(artist, album string) string {
	s := strings.ToLower(toSimplified(stripParens(album)))
	if a := strings.ToLower(strings.TrimSpace(toSimplified(artist))); a != "" {
		s = strings.ReplaceAll(s, a, " ")
	}
	for _, m := range cjkLiveAlbumMarkers {
		s = strings.ReplaceAll(s, m, " ")
	}
	var out []string
	for _, f := range strings.Fields(s) {
		if liveAlbumMarkerTokens[f] {
			continue
		}
		out = append(out, f)
	}
	return strings.Join(out, " ")
}

// pickQQAlbumTrack 从一张专辑的曲目单里挑出"就是本地这首歌"的那一条。抽成纯函数是为了
// 让单测能直接拿真实专辑数据钉住整段判定 —— 这段逻辑此前只在 resolveQQMatchViaAlbum
// 内联,而它需要联网,于是"并列一律放弃"那条规则改回去也没有任何测试会红(2026-09-02
// 变异测试当场抓出这个盲点)。
//
// 第二个返回值 false = 没挑出来,调用方照旧放弃整条专辑路线。
func pickQQAlbumTrack(songs []qqAlbumSong, artist, title string) (qqAlbumSong, bool) {
	const (
		tierExact = iota
		tierStripped
		tierAccepted
	)
	type qqTieredAlbumSong struct {
		song qqAlbumSong
		tier int
	}
	var matched []qqTieredAlbumSong
	nt := normLoose(title)
	st := normLoose(stripParens(title))
	for _, s := range songs {
		if !lyricTitleAccepted(s.name, title) {
			continue
		}
		if s.singer != "" && !qqArtistOK(false, s.singer, artist) {
			continue
		}
		tier := tierAccepted
		switch {
		case normLoose(s.name) == nt:
			tier = tierExact
		case normLoose(stripParens(s.name)) == st:
			tier = tierStripped
		}
		matched = append(matched, qqTieredAlbumSong{song: s, tier: tier})
	}
	best := -1
	for _, m := range matched {
		if best == -1 || m.tier < best {
			best = m.tier
		}
	}
	if best == -1 {
		return qqAlbumSong{}, false
	}
	var tied []qqAlbumSong
	for _, m := range matched {
		if m.tier == best {
			tied = append(tied, m.song)
		}
	}
	if len(tied) > 1 && !qqAlbumTiedSongsAreSameTrack(tied) {
		return qqAlbumSong{}, false
	}
	return tied[0], true
}

// qqSameTrackDurationSpreadSecs 是"并列的这几条算不算同一首歌"的时长容差。
//
// 10 秒的来路:裘德《离开银色荒原》在 QQ 上整张上架了两遍,同一首歌的两条时长实测差
// 0~7 秒(不同母带的首尾静音长度不同)。取 10 秒既盖得住这类重复上架,又拦得住"两场
// 不同的现场演出恰好同名"——那种差距通常在几十秒以上。
const qqSameTrackDurationSpreadSecs = 10

// qqAlbumTiedSongsAreSameTrack 判断"最优档位里并列的这几条,是不是同一首歌被列了多遍"。
//
// 判据三条全要满足:归一化同名、归一化同歌手、时长跨度不超过 qqSameTrackDurationSpreadSecs。
// 任一条不满足就返回 false,调用方照旧放弃整条专辑路线(宁可空手而归,不给错歌)。
//
// ⚠️ 时长缺失(interval<=0)一律返回 false —— 核不了就不能认。这不是"缺失当通过"的地方:
// 这个函数的全部价值就在于用时长把"重复上架"和"真·不同版本"分开,没有时长等于没有判据。
//
// 残留风险写明白:同一张专辑里两条同名、同歌手、时长只差几秒、却**真的是不同录音**的
// 曲目,会被判成同一首并取第一条。对歌词而言这没有代价(同一首歌的词一样);对"QQ音乐
// 链接"而言是可能指到另一个版本,量级可控,换来的是整张重复上架专辑的歌词不再全军覆没。
func qqAlbumTiedSongsAreSameTrack(tied []qqAlbumSong) bool {
	if len(tied) == 0 {
		return false
	}
	first := tied[0]
	if first.interval <= 0 {
		return false
	}
	minD, maxD := first.interval, first.interval
	for _, s := range tied[1:] {
		if normLoose(s.name) != normLoose(first.name) {
			return false
		}
		if normLoose(s.singer) != normLoose(first.singer) {
			return false
		}
		if s.interval <= 0 {
			return false
		}
		if s.interval < minD {
			minD = s.interval
		}
		if s.interval > maxD {
			maxD = s.interval
		}
	}
	return maxD-minD <= qqSameTrackDurationSpreadSecs
}

// resolveQQMatchViaAlbum 是专辑维度的兜底解析,启用条件与身份闸见上面的路线注释。
//
// 第二个返回值 degraded:路上发生过**网络层失败**(超时/限流/解码失败),"没找到"这个
// 结论不可信——调用方拿它决定回落结果要不要进 qqURLCache(对抗性复核抓出的真实毒化
// 时序:一次 6s 超时 → 零值 → 回落录音室版被按 artist|title|album 永久正缓存,本进程
// 后续所有重搜/自愈全部命中毒化条目,恰好把这条路线要修的 bug 原样钉回去)。
func resolveQQMatchViaAlbum(ctx context.Context, artist, title, album string) (m qqMusicMatch, degraded bool) {
	if album == "" || title == "" {
		return qqMusicMatch{}, false
	}
	// 本地专辑剥掉歌手名和 live 类通用词后**必须还有身份词**,否则整条路线放弃:
	// "陈奕迅演唱会"这类粗糙标签剥完是空串,查询词会退化成裸歌手名、闸门也无从核验身份
	// ——与 liveAlbumIdentityConflict 第③门"全是通用词的一边等于没有做身份声明"同理。
	localIdentity := albumIdentityTokens(artist, album)
	if len(localIdentity) == 0 {
		return qqMusicMatch{}, false
	}
	// 整条路线一个总预算:最坏形态(每个查询变体都撞 6s 超时 + musicu 8s)会把 qq
	// goroutine 拖到 ~26s,连锁让 amll 源(阻塞等 qqID)一起缺席 20s 截止。正常网络下
	// 每次请求几十 ms,10s 预算只裁撑满超时的病态路径,不裁正常路径。
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	// 查询变体从"信息最全"到"最剥"排——跟 searchTitleVariants 同一哲学:先带原样(剥括号),
	// 不行再剥身份外的词。每个变体一次请求,第一个产出**过闸专辑**的变体胜出。
	var queries []string
	seen := map[string]bool{}
	addQ := func(q string) {
		q = strings.TrimSpace(q)
		if q == "" || seen[q] {
			return
		}
		seen[q] = true
		queries = append(queries, q)
	}
	identity := qqAlbumIdentityQuery(artist, album)
	addQ(artist + " " + stripParens(album))
	if identity != "" {
		addQ(artist + " " + identity)
		addQ(identity)
	}
	var bestAlbum qqSmartboxItem
	bestScore := 0
	for _, q := range queries {
		items, err := qqSmartboxAlbums(ctx, q)
		if err != nil {
			degraded = true
		}
		for _, it := range items {
			if it.Mid == "" || !qqArtistOK(false, it.Singer, artist) {
				continue
			}
			// 两道专辑闸都要过:albumScore≥1(词元亲和)+ **身份词**有交集。albumScore
			// 的词元集不剥歌手名和 live/tour/演唱会类通用词,单靠它,"Jay Chou The One
			// Concert"和"Jay Chou The Invincible Concert"共享 {jay,chou,concert} 也能
			// 过闸——身份词交集(剥完通用词后)把这类"同歌手另一场演出"拦在检索层,
			// 跟打分层 liveAlbumIdentityConflict 的判据同源。
			sc := albumScore(it.Name, album)
			if sc == 0 {
				continue
			}
			candIdentity := albumIdentityTokens(artist, it.Name)
			shared := false
			for t := range candIdentity {
				if localIdentity[t] {
					shared = true
					break
				}
			}
			if !shared {
				continue
			}
			if sc > bestScore {
				bestAlbum, bestScore = it, sc
			}
		}
		if bestScore > 0 {
			break
		}
	}
	if bestScore == 0 {
		return qqMusicMatch{}, degraded
	}
	songs, err := qqAlbumSongs(ctx, bestAlbum.Mid)
	if err != nil {
		degraded = true
	}
	// 曲目挑选:lyricTitleAccepted 是门,门内分两档——归一化精确同名 > 剥括号后相等(QQ 的
	// 现场专辑曲目不带"(Live)",本地标题剥掉括号才对得上)。
	// 曲目自带 singer 时再核一遍歌手(合辑/拼盘专辑里同名曲可能是别人唱的);为空不拦
	// (元数据缺失不是反面证据)。
	//
	// 最优档位里并列多条时**不再一律放弃**(2026-09-02 放宽,裘德《寻找一片青草地》案)。
	// 原规则是"出现两条同档就交回旧行为",防的是"同名不同版本挑错版"。但实测撞到一种它
	// 判错性质的形态:**同一张专辑在 QQ 上被整个上架了两遍**——裘德《离开银色荒原》的
	// GetAlbumSongList 回 20 条 = 同样 10 首各一条(两个母带,部分曲目时长差 1~7 秒),
	// 于是这张专辑的**每一首**都并列两条、整张专辑的词全被这道闸挡在外面。而那两条并不是
	// "两个不同的东西分不清",是同一首歌的两个版本,拿哪条的词都对(实测《火山灰》《变色龙》
	// 两条 mid 取回的歌词逐字节相同)。
	//
	// 放宽的边界见 qqAlbumTiedSongsAreSameTrack:只有并列各条"同名 + 同歌手 + 时长几乎
	// 相同"才认定是同一首歌被列了多遍、取第一条;时长差得多(真·不同版本,比如两场
	// 不同的现场)照旧放弃。
	picked, ok := pickQQAlbumTrack(songs, artist, title)
	if !ok {
		return qqMusicMatch{}, degraded
	}
	return qqMusicMatch{
		url: qqSongURL(picked.mid), title: picked.name, artist: picked.singer,
		album: bestAlbum.Name, interval: picked.interval,
	}, degraded
}

func qqSongURL(mid string) string {
	if mid == "" {
		return ""
	}
	return "https://y.qq.com/n/ryqq/songDetail/" + mid
}

// qqMidFromURL pulls the songmid out of a QQ song-detail URL
// (y.qq.com/n/ryqq/songDetail/<mid>); "" for the search-link fallback.
func qqMidFromURL(u string) string {
	const marker = "/songDetail/"
	i := strings.Index(u, marker)
	if i < 0 {
		return ""
	}
	mid := u[i+len(marker):]
	if j := strings.IndexAny(mid, "/?#"); j >= 0 {
		mid = mid[:j]
	}
	return mid
}

var (
	qqLyricMu    sync.Mutex
	qqLyricCache = map[string]qqLyricResult{}
)

// qqLyric returns QQ Music's time-tagged LRC for a songmid — the fallback lyric
// source when NetEase has none (the two catalogs differ). Cached per mid; only
// successes cached. Empty unless the response has real timestamps.
// qqLyricResult 把"整行歌词"和"这首歌是纯音乐"分开带出来。
//
// 为什么要多这个 bool(2026-08-22,用户报「蛋堡《收敛水》的「关键字: Intro」搜出来没歌词」):
// QQ 对纯音乐曲目回的是单行占位 `[00:00:00]此歌曲为没有填词的纯音乐,请您欣赏`,而
// resolveQQLyric 末尾那道 isTimedLRC(要求 ≥3 行带戳)会把它判成"不是歌词"直接返回空串 ——
// **信号在那一步就被扔了**,后面谁都读不到。于是这类曲目落在「无歌词」而不是「纯音乐」,
// 界面上看起来像失败,还要被 needsLyricsFirstFill 每 24 小时(退避后翻倍)白搜一轮。
// 实测该曲五源口径一致:网易云只有一行署名(没有 pureMusic 字段)、酷狗 KRC 候选 0 条、
// LRCLIB 404、**只有 QQ 明确说了这句话**。文档第 09 章原来写「纯音乐标记的两个来源」,
// 这是第三个。
type qqLyricResult struct {
	lrc          string
	instrumental bool
}

func qqLyric(ctx context.Context, mid string) qqLyricResult {
	if mid == "" {
		return qqLyricResult{}
	}
	qqLyricMu.Lock()
	if v, ok := qqLyricCache[mid]; ok {
		qqLyricMu.Unlock()
		return v
	}
	qqLyricMu.Unlock()
	l := resolveQQLyric(ctx, mid)
	if l.lrc != "" || l.instrumental {
		qqLyricMu.Lock()
		qqLyricCache[mid] = l
		qqLyricMu.Unlock()
	}
	return l
}

func resolveQQLyric(ctx context.Context, mid string) qqLyricResult {
	u := "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?format=json&nobase64=1&g_tk=5381&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqLyricResult{}
	}
	req.Header.Set("Referer", "https://y.qq.com/") // 反爬要求带 y.qq.com 来源
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return qqLyricResult{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqLyricResult{}
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return qqLyricResult{}
	}
	// 响应可能被 jsonp 包裹(MusicJsonCallback({...}))：截第一个 { 到最后一个 }。
	s := string(raw)
	i, j := strings.IndexByte(s, '{'), strings.LastIndexByte(s, '}')
	if i < 0 || j <= i {
		return qqLyricResult{}
	}
	var out struct {
		Lyric string `json:"lyric"`
	}
	if err := json.Unmarshal([]byte(s[i:j+1]), &out); err != nil {
		return qqLyricResult{}
	}
	// ⚠️ 顺序要紧:占位判定必须在 isTimedLRC **之前**。QQ 的纯音乐占位只有一行带戳,
	// 过不了"≥3 行且过半"那道门槛,先过 isTimedLRC 的话这个明确结论就被当成"没歌词"扔掉了。
	if isInstrumentalPlaceholderLyric(out.Lyric) {
		return qqLyricResult{instrumental: true}
	}
	if l := out.Lyric; isTimedLRC(l) {
		return qqLyricResult{lrc: l}
	}
	return qqLyricResult{}
}

// ---- QQ音乐逐字(QRC)歌词 ----
//
// resolveQQLyric 用的旧接口(fcg_query_lyric_new.fcg)只有整行歌词。QQ 音乐真正的逐字
// 接口是 musicu.fcg 的 GetPlayLyricInfo,跟上面这套 c.y.qq.com REST 接口是完全不同的
// 一套 API 家族(JSON-RPC 风格,comm+request 外壳),需要:①先建一个匿名 session(不需要
// 登录);②数字型 songID(不是到处传的 mid 字符串,复用 fcg_play_single_song.fcg 这个
// 已经在用的单曲详情接口额外取一下);③响应内容是 3DES 加密+zlib压缩的 XML,解出来的
// LyricContent 属性里才是真正的逐字歌词正文。密钥/算法已用真实歌曲验证解密成功。

type qqSessionInfo struct {
	uid    string
	sid    string
	userip string
}

var (
	qqSessionMu   sync.Mutex
	qqSessionInit bool
	qqSessionVal  qqSessionInfo
)

var qqCommBase = map[string]any{
	"ct": 11, "cv": "1003006", "v": "1003006",
	"os_ver":    "15",
	"phonetype": "24122RKC7C",
	"rom":       "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
	"tmeAppID":  "qqmusiclight",
	"nettype":   "NETWORK_WIFI",
	"udid":      "0",
}

func qqComm(sess qqSessionInfo) map[string]any {
	comm := make(map[string]any, len(qqCommBase)+3)
	for k, v := range qqCommBase {
		comm[k] = v
	}
	comm["uid"], comm["sid"], comm["userip"] = sess.uid, sess.sid, sess.userip
	return comm
}

// qqMusicuPost POSTs a JSON-RPC-style request to musicu.fcg (QQ 音乐 App 内部接口,
// 跟 c.y.qq.com 那套完全独立)。返回 request.data 的原始 JSON,调用方各自解码成自己
// 关心的形状,不用一个万能 map 应付所有响应。
func qqMusicuPost(ctx context.Context, method, module string, param any, comm map[string]any) (json.RawMessage, error) {
	reqBody := struct {
		Comm    map[string]any `json:"comm"`
		Request struct {
			Method string `json:"method"`
			Module string `json:"module"`
			Param  any    `json:"param"`
		} `json:"request"`
	}{Comm: comm}
	reqBody.Request.Method = method
	reqBody.Request.Module = module
	reqBody.Request.Param = param
	raw, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://u.y.qq.com/cgi-bin/musicu.fcg", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Cookie", "tmeLoginType=-1;")
	req.Header.Set("User-Agent", "okhttp/3.14.9")
	resp, err := doHTTPTracked(&http.Client{Timeout: 8 * time.Second}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Code    int `json:"code"`
		Request struct {
			Code int             `json:"code"`
			Data json.RawMessage `json:"data"`
		} `json:"request"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if out.Code != 0 || out.Request.Code != 0 {
		return nil, fmt.Errorf("qq musicu api error: code=%d request.code=%d", out.Code, out.Request.Code)
	}
	return out.Request.Data, nil
}

// qqEnsureSession 懒加载一个匿名 session,失败就返回零值(调用方据此放弃这次 QRC
// 尝试)。只真正尝试一次(用 qqSessionInit 卡住,不管成不成功),不做主动刷新/重试——
// 跟 lrclib/kugou 现有代码同等的"失败就放弃、下次进程重启再试"哲学一致。
func qqEnsureSession(ctx context.Context) qqSessionInfo {
	qqSessionMu.Lock()
	defer qqSessionMu.Unlock()
	if qqSessionInit {
		return qqSessionVal
	}
	qqSessionInit = true
	data, err := qqMusicuPost(ctx, "GetSession", "music.getSession.session", map[string]any{
		"caller": 0, "uid": "0", "vkey": 0,
	}, qqCommBase)
	if err != nil {
		return qqSessionInfo{}
	}
	var out struct {
		Session struct {
			UID    json.Number `json:"uid"`
			SID    string      `json:"sid"`
			UserIP string      `json:"userip"`
		} `json:"session"`
	}
	if err := json.Unmarshal(data, &out); err != nil || out.Session.SID == "" {
		return qqSessionInfo{}
	}
	qqSessionVal = qqSessionInfo{uid: out.Session.UID.String(), sid: out.Session.SID, userip: out.Session.UserIP}
	return qqSessionVal
}

type qqSongMeta struct {
	id       int64
	interval float64 // 秒,QQ 音乐官方时长
	// language 是 fcg_play_single_song.fcg 的 language 字段,实测坐实 0=国语/1=粤语
	// (交叉验证过陈奕迅《浮夸》=1/《好久不见》=0、Beyond《海阔天空》=1、周杰伦《稻香》=0、
	// Taylor Swift《Love Story》=5=英语)。其余取值未穷举,qqCanonicalLanguage 一律折算成空,
	// 不外推。
	language int
}

var (
	qqSongMetaMu    sync.Mutex
	qqSongMetaCache = map[string]qqSongMeta{}
)

// qqSongMetaByMid 取 GetPlayLyricInfo 要用的数字型 songID + 官方时长,复用
// qqSongAlbum/qqSongCoverAndSinger 已经在用的同一个单曲详情接口
// (fcg_play_single_song.fcg),按 mid 单独缓存(这两个现有函数各自只取自己关心的
// 字段,没有把 id 传出来)。
// qqSongMetaCachedOnly 只读缓存、绝不发请求:给"有就带上、没有就算了"的纯透传字段用,
// 不能让它把歌词主路径拖慢(见 enrich.go 里 qqDur 的调用点)。
func qqSongMetaCachedOnly(mid string) qqSongMeta {
	if mid == "" {
		return qqSongMeta{}
	}
	qqSongMetaMu.Lock()
	defer qqSongMetaMu.Unlock()
	return qqSongMetaCache[mid]
}

func qqSongMetaByMid(ctx context.Context, mid string) qqSongMeta {
	if mid == "" {
		return qqSongMeta{}
	}
	qqSongMetaMu.Lock()
	if v, ok := qqSongMetaCache[mid]; ok {
		qqSongMetaMu.Unlock()
		return v
	}
	qqSongMetaMu.Unlock()

	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqSongMeta{}
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return qqSongMeta{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqSongMeta{}
	}
	var out struct {
		Data []struct {
			ID       int64   `json:"id"`
			Interval float64 `json:"interval"`
			Language int     `json:"language"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 || out.Data[0].ID == 0 {
		return qqSongMeta{}
	}
	m := qqSongMeta{id: out.Data[0].ID, interval: out.Data[0].Interval, language: out.Data[0].Language}
	qqSongMetaMu.Lock()
	qqSongMetaCache[mid] = m
	qqSongMetaMu.Unlock()
	return m
}

// qqCanonicalLanguage 把 fcg_play_single_song.fcg 的 language 数字字段折算成
// lyricCandidate.language 的取值(songLanguageMandarin/songLanguageCantonese),
// 未识别的取值(含未实测过的枚举值)一律返回空串,不外推。
func qqCanonicalLanguage(n int) string {
	switch n {
	case 0:
		return songLanguageMandarin
	case 1:
		return songLanguageCantonese
	default:
		return ""
	}
}

// qrcDESKey 是 QQ 音乐 GetPlayLyricInfo 响应里 lyric 字段(逐字内容)加密用的固定 24
// 字节 3DES 密钥——公开算法(社区已逆向),已用真实歌曲验证解密成功。标准 3DES-EDE3-ECB,
// Go 标准库 crypto/des 直接支持,不用手写 DES。
var qrcDESKey = []byte("!@#)(*$%123ZXC!@!@#)(NHL")

// decryptQRC 对 GetPlayLyricInfo 返回的 hex 编码密文做 3DES-ECB 解密(8 字节一块、块间
// 互不链接) + zlib 解压,得到内层 XML
// (<QrcInfos>...<Lyric_N LyricType="..." LyricContent="...">...)。不能用 Go 标准库
// crypto/des——标准 FIPS-46 DES 解不出合法 zlib 流(先报 zlib: invalid header),QQ 音乐
// 这份密文匹配的是社区逆向出的特定位运算实现(见 des3_qmusic.go 顶部注释),必须用
// qm3DESDecrypt。
func decryptQRC(hexStr string) string {
	raw, err := hex.DecodeString(hexStr)
	if err != nil || len(raw) == 0 || len(raw)%8 != 0 {
		return ""
	}
	dec := qm3DESDecrypt(qrcDESKey, raw)
	if dec == nil {
		return ""
	}
	zr, err := zlib.NewReader(bytes.NewReader(dec))
	if err != nil {
		return ""
	}
	defer zr.Close()
	out, err := io.ReadAll(zr)
	if err != nil {
		return ""
	}
	return string(out)
}

// (?s) 让 . 匹配换行——LyricContent 属性值本身是多行文本(内嵌真实的 \n),Go 的 RE2
// 默认 . 不跨行,不加这个前缀只会匹配到第一行就提前收尾,后面整段内容会被截断丢失。
//
// ⚠️ `(.*)` 必须是**贪婪**的,并且以 `"/>` 收尾,不能像 2026-08-16 之前那样写成
// 非贪婪的 `(.*?)"`。原来那版的依据是"XML 属性值里的字面 \" 按规范必须转义成 &quot;,
// 所以匹配到下一个引号是安全的"—— 这个假设对 QQ 的真实返回**不成立**:实测
// PRINCE - Little Red Corvette 的正文里有 5 个**字面**双引号、0 个 &quot;
// (歌词本身就带引号:`And you say "What have I got to lose"`),于是非贪婪匹配在第一个
// 引号处就收尾,8508 字节的正文只截出 1604 字节 —— 丢掉 81%。
//
// 表现是"这首歌明明标着有逐字,前半段有效果、后面就没了":被截断的那份 YRC 仍然非空,
// 所以 hasWordTiming 判定为真、打分还照拿逐字的加权,只是内容缺了一大半。英文歌里
// 带引号的对白很常见,所以这不是个别曲目的问题。
//
// 贪婪匹配到最后一个 `"/>` 是安全的:实测解密后的 XML 结构是
// `...<Lyric_1 LyricType="1" LyricContent="…正文…"/>\n</LyricInfo>\n</QrcInfos>`,
// LyricContent 是最后一个属性、后面紧跟自闭合,而正文里出现字面 `"/>` 三字符序列
// 需要引号紧挨着 `/>`,歌词里不会有。
var qrcContentRegex = regexp.MustCompile(`(?s)LyricContent="(.*)"\s*/>`)

// extractQRCLyricContent 从解密后的 XML 里取出 LyricContent 属性值——用正则而非完整
// XML 解析,因为外层 Lyric_N 标签名是动态的(N=LyricCount,实测目前只见过 1,但不想依赖
// 这个假设),只关心这一个属性。XML 属性值里的字面 " 按规范必须转义成 &quot;,所以
// (.*?) 非贪婪匹配到下一个 " 是安全的;再用 html.UnescapeString 反转义 &lt;/&gt;/
// &amp; 等 XML 预定义实体,还原成真正的歌词正文。
func extractQRCLyricContent(xmlText string) string {
	m := qrcContentRegex.FindStringSubmatch(xmlText)
	if m == nil {
		return ""
	}
	return html.UnescapeString(m[1])
}

var qqWordRegex = regexp.MustCompile(`([^\[\]()\n]+)\((\d+),(\d+)\)`)

// qrcToYRC 把 QQ QRC 正文转换成 YRCParser(desktop-lyrics)认识的语法。QQ 原生写法是
// "词(词始ms,词长ms)"——词在括号前、只有两个数字;YRC 是"(词始ms,词长ms,flag)词"——
// 标记在前、词紧跟其后、3个数字。这里做的是重排+补一个恒为 0 的 flag,行头
// [行始,行长] 本身两边格式一致不用动。
func qrcToYRC(qrc string) string {
	if qrc == "" {
		return ""
	}
	return qqWordRegex.ReplaceAllString(qrc, "($2,$3,0)$1")
}

// qqQRCResult 是 GetPlayLyricInfo 一次请求带回的三条轨道,都已归一化成 App 侧认识的
// 语法:yrc 是逐字(YRCParser 语法),tr/roma 是逐行 LRC。任何一条拿不到就留空串,三条
// 互不牵连——译文解不出不影响逐字,反之亦然。
//
// kana 是 QRC 正文里那一行 `[kana:…]` 假名标注(原样,含方括号),没有就空串。它跟酷狗
// LRC 里的 `[kana:]` 标签同一个格式(`<单个数字><读音假名>` 序列,读音里夹 `(起始,时长)`),
// App 侧 KanaAnnotation 只从**整行歌词**(lyrics 字段)里找这一行,所以 enrich.go 把它拼到
// QQ 候选的整行歌词开头,而不是留在逐字数据里(留在 YRC 里 App 读不到,还会被 qrcToYRC
// 的词级重排搅乱)。实测(2026-09-02,直连接口 8 首):日文歌 6/6 带这一行,且条目覆盖数与
// 旧接口整行歌词里的汉字数(含 々)逐首相等——正好是 KanaAnnotation 的对齐前提;中文歌
// (晴天)与韩文歌(Ditto)没有这一行,不会误标。
type qqQRCResult struct {
	yrc, tr, roma string
	kana          string
}

// qqQRCLyric 是 qqLyric 的逐字版本——独立发起、独立判定成败,不影响 qqLyric(mid)
// 现有的整行歌词路径;哪一步失败都直接返回零值,不重试(下次 enrich 短 TTL 到期或
// 进程重启自然再试)。
//
// 2026-09-02 起把同一份响应里的 trans(中文译文)/roma(罗马音)两轨也接了回来:请求体
// 从一开始就带着 roma=1/trans=1,响应却一直只解 lyric——那是接 QRC 那次刻意搁置的项
// (见 enrich.go 候选装配处的注释)。实测四首(米津玄師 Lemon / NewJeans Ditto /
// Taylor Swift Cruel Summer / 周杰伦 晴天):日/韩/英三首都带译文,日/韩带罗马音,中文歌
// 两者皆空;旧接口 fcg_query_lyric_new 的 trans 字段对这四首全空,所以译文只能从这里拿。
// 两轨的格式与清洗规则见下面 qqAuxiliaryLRC 的注释。
func qqQRCLyric(ctx context.Context, mid, artist, title, album string, durationSecs float64) qqQRCResult {
	if mid == "" {
		return qqQRCResult{}
	}
	sess := qqEnsureSession(ctx)
	if sess.sid == "" {
		return qqQRCResult{}
	}
	meta := qqSongMetaByMid(ctx, mid)
	if meta.id == 0 {
		return qqQRCResult{}
	}
	interval := meta.interval
	if interval <= 0 {
		interval = durationSecs
	}
	param := map[string]any{
		"albumName":  base64.StdEncoding.EncodeToString([]byte(album)),
		"crypt":      1,
		"ct":         19,
		"cv":         2111,
		"interval":   int(interval),
		"lrc_t":      0,
		"qrc":        1,
		"qrc_t":      0,
		"roma":       1,
		"roma_t":     0,
		"singerName": base64.StdEncoding.EncodeToString([]byte(artist)),
		"songID":     meta.id,
		"songName":   base64.StdEncoding.EncodeToString([]byte(title)),
		"trans":      1,
		"trans_t":    0,
		"type":       0,
	}
	data, err := qqMusicuPost(ctx, "GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", param, qqComm(sess))
	if err != nil {
		return qqQRCResult{}
	}
	var out struct {
		Lyric string      `json:"lyric"`
		Trans string      `json:"trans"`
		Roma  string      `json:"roma"`
		QrcT  json.Number `json:"qrc_t"`
		LrcT  json.Number `json:"lrc_t"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return qqQRCResult{}
	}
	// 译文/罗马音跟逐字互不牵连:逐字这条没过下面 qrc_t/lrc_t 那道闸,两条辅助轨照样接
	// (它们各有自己的 trans_t/roma_t,这里不看——内容解不出自然是空串)。
	res := qqQRCResult{tr: qqAuxiliaryLRC(out.Trans), roma: qqAuxiliaryLRC(out.Roma)}
	if out.Lyric == "" {
		return res
	}
	t := out.QrcT.String()
	if t == "" || t == "0" {
		t = out.LrcT.String()
	}
	if t == "" || t == "0" {
		return res
	}
	decrypted := decryptQRC(out.Lyric)
	if decrypted == "" {
		return res
	}
	content := extractQRCLyricContent(decrypted)
	if content == "" {
		return res
	}
	// 假名标注行单独摘出来给整行歌词用(见 qqQRCResult.kana);剩下的才进逐字转换。
	res.kana, content = splitQRCKanaLine(content)
	res.yrc = qrcToYRC(content)
	return res
}

// splitQRCKanaLine 把 QRC 正文里的 `[kana:…]` 行(实测在正文第一行,这里不依赖位置)摘出来:
// 返回该行原样(去首尾空白)与去掉该行之后的正文。没有就返回 ("", 原文)。
func splitQRCKanaLine(content string) (kana, rest string) {
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[kana:") && strings.HasSuffix(trimmed, "]") {
			return trimmed, strings.Join(append(lines[:i:i], lines[i+1:]...), "\n")
		}
	}
	return "", content
}

// attachKanaLine 把 QQ 的 `[kana:…]` 行拼到整行歌词最前面,给 App 侧 KanaAnnotation 读
// (它在整份 LRC 里找第一行 `[kana:` 开头、`]` 收尾的行,位置不限)。整行歌词本身已经带有
// 这一行(酷狗那种源自带的形态)就不重复拼;任一侧为空原样返回。
func attachKanaLine(lrc, kana string) string {
	if lrc == "" || kana == "" || strings.Contains(lrc, "[kana:") {
		return lrc
	}
	return kana + "\n" + lrc
}

// ---- QQ音乐译文 / 罗马音(GetPlayLyricInfo 的 trans / roma 轨) ----
//
// 两轨跟 lyric 一样是 3DES+zlib 的 hex 密文(同一把 qrcDESKey),解出来的形态实测有两种
// (2026-09-02,四首歌直连接口看的):
//   - trans:解出来直接是普通逐行 LRC(**不带** QrcInfos XML 包装),时间戳与旧接口
//     fcg_query_lyric_new 的整行歌词逐行一致([00:01.54]夢ならば ↔ [00:01.54]如果只是一场梦),
//     所以能靶到候选的 lyrics 上(App 侧 LyricsSyncEngine 按 700ms 最近邻贴行)。里面夹着
//     三类不是译文的行,必须剔掉:① `//` 占位行(对应标题/词曲署名行,Lemon 3 行、
//     Cruel Summer 8 行)——不剔的话 App 会把「//」当译文贴到那几行上;② 版权声明行
//     `[00:00.00]QQ音乐享有本翻译作品的著作权`(只剔 // 不够——不剔这个的话,这句
//     会被当成标题行的译文显示出来);③ 无时间戳的 `[kana:…]` 假名注音元数据行(跟 [ti:]/[ar:]
//     一起被「只留带时间戳的行」这条规则带走)。
//   - roma:沿用 QRC 的 XML 包装 + 逐字计时(`[1547,1151]yu (1547,223)me (1771,152)…`),
//     而 LyricsRoma 要的是逐行 LRC,所以抠出 LyricContent 后按行把 `[行始,行长]` 换成
//     `[mm:ss.SSS]`、去掉每个词后面的 `(词始,词长)`;有的行只剩计时没有文字
//     (`[0,529](496,33)`,对应署名行)要丢。App 侧 LRCParser 与 match.go 的 lrcTimestampRe
//     都认 1~3 位毫秒,不用改解析器。
// 哪种形态用 hasQRCLineTiming 判:有一行以 `[数字,数字]` 开头就按 QRC 处理(两轨可能是纯
// LRC,也可能沿用 QRC 包装,实测两种形态都见过)。两种都过 isTimedLRC 收口(≥3 行带戳、
// 过半带戳),不够就当没有——跟别的源的译文口径一致。

var (
	qrcLineHeadRegex   = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
	qrcWordTimingRegex = regexp.MustCompile(`\(\d+,\d+\)`)
)

// qqAuxiliaryLRC 把 GetPlayLyricInfo 的 trans/roma 字段(hex 密文)变成可直接进
// LyricsTr/LyricsRoma 的逐行 LRC;拿不到、解不出、清洗完不够 3 行都返回空串。
func qqAuxiliaryLRC(cipherHex string) string {
	if strings.TrimSpace(cipherHex) == "" {
		return ""
	}
	decrypted := decryptQRC(cipherHex)
	if decrypted == "" {
		return ""
	}
	return qqAuxiliaryPlainToLRC(decrypted)
}

// qqAuxiliaryPlainToLRC 是 qqAuxiliaryLRC 解密之后的那一半,单独拆出来是为了让单测能直接
// 喂明文(密文没有现成的加密器可以造)。
func qqAuxiliaryPlainToLRC(plain string) string {
	if c := extractQRCLyricContent(plain); c != "" {
		plain = c
	}
	var lrc string
	if hasQRCLineTiming(plain) {
		lrc = qrcToLineLRC(plain)
	} else {
		lrc = cleanQQAuxiliaryLRC(plain)
	}
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

func hasQRCLineTiming(s string) bool {
	for _, line := range strings.Split(s, "\n") {
		if qrcLineHeadRegex.MatchString(strings.TrimSpace(line)) {
			return true
		}
	}
	return false
}

// qrcToLineLRC 把 QRC 逐字正文压成逐行 LRC:行头 [行始ms,行长ms] → [mm:ss.SSS],正文去掉
// 每个词后面的 (词始,词长),多余空白折成单个空格(罗马音是 `yu (1547,223)me (1771,152)`
// 这种词后带空格的写法,去掉计时后正好留下音节间的空格)。只剩计时没有文字的行、`//`
// 占位行、版权声明行丢掉;[offset:] 标签原样保留(App 侧 LRCParser 会应用它);其它元数据
// 行([ti:]/[ar:]/[kana:]…)丢掉。
func qrcToLineLRC(qrc string) string {
	var out []string
	for _, line := range strings.Split(qrc, "\n") {
		line = strings.TrimSpace(line)
		if isLRCOffsetTag(line) {
			out = append(out, line)
			continue
		}
		m := qrcLineHeadRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		startMs, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		text := qrcWordTimingRegex.ReplaceAllString(line[len(m[0]):], "")
		text = strings.Join(strings.Fields(text), " ")
		if text == "" || text == "//" || isQQTranslationNotice(text) {
			continue
		}
		out = append(out, fmt.Sprintf("[%02d:%02d.%03d]%s", startMs/60000, (startMs/1000)%60, startMs%1000, text))
	}
	return strings.Join(out, "\n")
}

// cleanQQAuxiliaryLRC 处理已经是逐行 LRC 形态的辅助轨:只保留带时间戳、正文非空、不是 `//`
// 占位、不是版权声明的行;[offset:] 标签保留;行本身(含可能的多个时间戳)原样输出。
func cleanQQAuxiliaryLRC(lrc string) string {
	var out []string
	for _, line := range strings.Split(lrc, "\n") {
		trimmed := strings.TrimSpace(line)
		if isLRCOffsetTag(trimmed) {
			out = append(out, trimmed)
			continue
		}
		if !strings.HasPrefix(trimmed, "[") || !lrcTimestampRe.MatchString(trimmed) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(trimmed, ""))
		if text == "" || text == "//" || isQQTranslationNotice(text) {
			continue
		}
		out = append(out, trimmed)
	}
	return strings.Join(out, "\n")
}

func isLRCOffsetTag(line string) bool {
	return strings.HasPrefix(strings.ToLower(line), "[offset:")
}

// isQQTranslationNotice 认 QQ 音乐塞在译文轨第一行的版权声明(实测原话
// 「QQ音乐享有本翻译作品的著作权」,挂在 [00:00.00] 上,会跟标题行对齐)。两种写法都认,
// 但要求「著作权」一定在——别把歌词里恰好出现「QQ音乐」的句子误杀。
func isQQTranslationNotice(text string) bool {
	return strings.Contains(text, "翻译作品的著作权") ||
		(strings.Contains(text, "QQ音乐") && strings.Contains(text, "著作权"))
}
