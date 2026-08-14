// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
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
func qqMusicURL(artist, title, album string) string {
	m := qqMusicMatchCached(artist, title, album)
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
func qqMusicMatchCached(artist, title, album string) qqMusicMatch {
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

	m := resolveQQMusicMatch(artist, title, album)
	if m.url != "" {
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

// qqSmartbox queries QQ Music's suggest endpoint — the one search API that
// still answers unauthenticated (musicu.fcg returns an empty list and
// client_search_cp returns zero bytes under anti-scrape). Returns nil on error.
func qqSmartbox(query string) []qqSmartboxItem {
	u := "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?_=1&cv=4747474&ct=24&format=json&is_xml=0&key=" + neturl.QueryEscape(query)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var out struct {
		Data struct {
			Song struct {
				ItemList []qqSmartboxItem `json:"itemlist"`
			} `json:"song"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil
	}
	return out.Data.Song.ItemList
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

// qqSmartboxFirstNonEmpty 按顺序试查询词,返回第一个非空结果。
func qqSmartboxFirstNonEmpty(queries []string) []qqSmartboxItem {
	for _, q := range queries {
		if items := qqSmartbox(q); len(items) > 0 {
			return items
		}
	}
	return nil
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
func qqSingerAvatar(name string) (string, bool) {
	u := "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?_=1&cv=4747474&ct=24&format=json&is_xml=0&key=" + neturl.QueryEscape(name)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return "", false
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var out struct {
		Data struct {
			Singer struct {
				ItemList []struct {
					Pic string `json:"pic"`
				} `json:"itemlist"`
			} `json:"singer"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", false
	}
	if len(out.Data.Singer.ItemList) == 0 {
		return "", true // 服务端明确说没有这个歌手
	}
	pic := out.Data.Singer.ItemList[0].Pic
	if pic == "" {
		return "", true
	}
	// 接口给的是 150x150 缩略图(跟 qqSongCoverAndSinger 拼专辑封面同一个 CDN 套路),把
	// 分辨率前缀换成 300x300、协议换成 https 同一个 mid 也能取到更清晰的图;页面本身全程
	// https,混合内容图片在部分浏览器/CSP 下有被拦截风险,统一升级更稳妥。
	pic = strings.Replace(pic, "R150x150", "R300x300", 1)
	pic = strings.Replace(pic, "http://", "https://", 1)
	return pic, true
}

// qqSongAlbum returns the album name for a QQ song mid via the single-song
// detail API (album is at data[0].album.name). Empty on any failure — callers
// treat that as "unknown album" and fall back to name-based selection.
func qqSongAlbum(mid string) string {
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequest(http.MethodGet, u, nil)
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

// qqSongCoverAndSinger returns (album cover URL, primary singer name) for a QQ
// song mid via the same single-song detail API qqSongAlbum uses. The singer is
// returned so callers can re-verify identity before trusting the cover (a QQ
// smartbox hit can itself be a fan/cover account; see qqCoverFallback).
func qqSongCoverAndSinger(mid string) (cover, singer string) {
	u := "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequest(http.MethodGet, u, nil)
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
	return "https://y.qq.com/music/photo_new/T002R300x300M000" + d.Album.Mid + ".jpg", singer
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
func qqCoverFallback(artist, title, album string) (cover, canonicalArtist string) {
	if artist == "" || title == "" {
		return "", ""
	}
	// 跟 netease.go 里 chosen 分支同样的道理:本地标签本来就是多人合credit(如"Prince
	// & The Revolution")时,QQ 的 singer 字段可能只单独记了其中一位——不把这个当统一
	// 歌手名用,避免悄悄丢掉本地已经写全的合作者;封面照常正常解析,不受影响。
	singleArtist := len(artistCreditParts(artist)) < 2
	type qqCoverCand struct {
		mid   string
		exact bool // name 与 title loose 相等,跟 resolveQQMusicMatch 的 exact 同一含义
	}
	var cands []qqCoverCand
	for _, it := range qqSmartboxFirstNonEmpty(qqSearchQueries(artist, title)) {
		if it.Mid == "" || !lyricTitleAccepted(it.Name, title) ||
			!artistMatches(it.Singer, artist) {
			continue
		}
		cands = append(cands, qqCoverCand{mid: it.Mid, exact: normLoose(it.Name) == normLoose(title)})
	}
	tryCand := func(c qqCoverCand) (string, string, bool) {
		cover, singer := qqSongCoverAndSinger(c.mid)
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
			sc := albumScore(qqSongAlbum(cands[i].mid), album)
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
		return artistMatches(singer, artist)
	}
	return looseContains(singer, artist)
}

// qqMusicMatch 是 resolveQQMusicURL 选中同一个 mid 时顺带就已经拿到、原来直接丢掉的
// 匹配信息——title/artist 来自 smartbox 搜索结果本身(it.Name/it.Singer),album 来自
// (如果查询带了专辑名)顺带查过的 qqSongAlbum(mid)。给"搜索候选歌词"弹窗展示用,不
// 参与任何匹配/打分逻辑。
type qqMusicMatch struct {
	url, title, artist, album string
}

func resolveQQMusicURL(artist, title, album string) string {
	return resolveQQMusicMatch(artist, title, album).url
}

func resolveQQMusicMatch(artist, title, album string) qqMusicMatch {
	items := qqSmartboxFirstNonEmpty(qqSearchQueries(artist, title))
	if len(items) == 0 {
		// 歌手名跨平台不一致时,退一步只按标题再搜(同样要带上去括号的那一版)
		items = qqSmartboxFirstNonEmpty(searchTitleVariants(title))
	}
	type qqCand struct {
		mid, title, artist string
		exact              bool // name 与 title loose 相等 → 规范版,避开 纯音乐/串烧/live 变体
	}
	// strict 档用 artistMatches(要求逗号/&等分隔的每一段都精确相等);strict 一无所获时
	// 放宽成 looseContains 重试——但绝不完全跳过校验:完全不查歌手会让标题撞上、歌手完全
	// 不相干的翻唱/仿冒账号蒙混过关、链接指向错误的人(同 match.go artistMatches 注释里
	// Jay Chou 那次教训同理;这里此前就是"完全不查")。
	collect := func(strict bool) []qqCand {
		var cs []qqCand
		for _, it := range items {
			if it.Mid == "" || !lyricTitleAccepted(it.Name, title) ||
				!qqArtistOK(strict, it.Singer, artist) {
				continue
			}
			cs = append(cs, qqCand{mid: it.Mid, title: it.Name, artist: it.Singer, exact: normLoose(it.Name) == normLoose(title)})
		}
		return cs
	}
	cands := collect(true)
	if len(cands) == 0 {
		cands = collect(false) // artistMatches 太严格(跨平台歌手名写法不同)时放宽成 looseContains,但仍要求歌手名沾边
	}
	if len(cands) == 0 {
		return qqMusicMatch{} // 无标题匹配 → 上层退搜索链接,绝不给错歌
	}
	// 有专辑名 → 给前几条补专辑、按 albumScore 去重。采集器一首歌只解析一次,
	// 频次低;补专辑失败(反爬/超时)时降级到按名字选,不影响出具体歌链接。
	if album != "" {
		bestMid, bestTitle, bestArtist, bestAlbum, bestScore, bestExact := "", "", "", "", 0, false
		for i, c := range cands {
			if i >= 4 {
				break
			}
			candAlbum := qqSongAlbum(c.mid)
			sc := albumScore(candAlbum, album)
			if sc == 0 && !c.exact {
				continue // 专辑对不上、标题也非精确同名 → 不够格参与本轮选择
			}
			// 标题精确同名优先于专辑分(与 albumScore 的 exact>loose 分层同一原则):避免
			// 同专辑里一首标题超串/子串的非规范版(live/伴奏等)靠专辑分打平甚至反超真正
			// 同名曲目——历史上这类打分边界条件已经在 albumScore 上出过一次真实 bug。
			if bestMid == "" || (c.exact && !bestExact) || (c.exact == bestExact && sc > bestScore) {
				bestMid, bestTitle, bestArtist, bestAlbum, bestScore, bestExact = c.mid, c.title, c.artist, candAlbum, sc, c.exact
			}
		}
		if bestMid != "" {
			return qqMusicMatch{url: qqSongURL(bestMid), title: bestTitle, artist: bestArtist, album: bestAlbum}
		}
	}
	// 无专辑 / 补专辑没命中 → 精确同名优先,否则第一条(smartbox 首条通常是规范版)。
	for _, c := range cands {
		if c.exact {
			return qqMusicMatch{url: qqSongURL(c.mid), title: c.title, artist: c.artist}
		}
	}
	first := cands[0]
	return qqMusicMatch{url: qqSongURL(first.mid), title: first.title, artist: first.artist}
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
	qqLyricCache = map[string]string{}
)

// qqLyric returns QQ Music's time-tagged LRC for a songmid — the fallback lyric
// source when NetEase has none (the two catalogs differ). Cached per mid; only
// successes cached. Empty unless the response has real timestamps.
func qqLyric(mid string) string {
	if mid == "" {
		return ""
	}
	qqLyricMu.Lock()
	if v, ok := qqLyricCache[mid]; ok {
		qqLyricMu.Unlock()
		return v
	}
	qqLyricMu.Unlock()
	l := resolveQQLyric(mid)
	if l != "" {
		qqLyricMu.Lock()
		qqLyricCache[mid] = l
		qqLyricMu.Unlock()
	}
	return l
}

func resolveQQLyric(mid string) string {
	u := "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?format=json&nobase64=1&g_tk=5381&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Referer", "https://y.qq.com/") // 反爬要求带 y.qq.com 来源
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return ""
	}
	// 响应可能被 jsonp 包裹(MusicJsonCallback({...}))：截第一个 { 到最后一个 }。
	s := string(raw)
	i, j := strings.IndexByte(s, '{'), strings.LastIndexByte(s, '}')
	if i < 0 || j <= i {
		return ""
	}
	var out struct {
		Lyric string `json:"lyric"`
	}
	if err := json.Unmarshal([]byte(s[i:j+1]), &out); err != nil {
		return ""
	}
	if l := out.Lyric; isTimedLRC(l) {
		return l
	}
	return ""
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
func qqMusicuPost(method, module string, param any, comm map[string]any) (json.RawMessage, error) {
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
	req, err := http.NewRequest(http.MethodPost, "https://u.y.qq.com/cgi-bin/musicu.fcg", bytes.NewReader(raw))
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
func qqEnsureSession() qqSessionInfo {
	qqSessionMu.Lock()
	defer qqSessionMu.Unlock()
	if qqSessionInit {
		return qqSessionVal
	}
	qqSessionInit = true
	data, err := qqMusicuPost("GetSession", "music.getSession.session", map[string]any{
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

func qqSongMetaByMid(mid string) qqSongMeta {
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
	req, err := http.NewRequest(http.MethodGet, u, nil)
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
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 || out.Data[0].ID == 0 {
		return qqSongMeta{}
	}
	m := qqSongMeta{id: out.Data[0].ID, interval: out.Data[0].Interval}
	qqSongMetaMu.Lock()
	qqSongMetaCache[mid] = m
	qqSongMetaMu.Unlock()
	return m
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
var qrcContentRegex = regexp.MustCompile(`(?s)LyricContent="(.*?)"`)

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

// qqQRCLyric 是 qqLyric 的逐字版本——独立发起、独立判定成败,不影响 qqLyric(mid)
// 现有的整行歌词路径;哪一步失败都直接返回空串,不重试(下次 enrich 短 TTL 到期或
// 进程重启自然再试)。
func qqQRCLyric(mid, artist, title, album string, durationSecs float64) string {
	if mid == "" {
		return ""
	}
	sess := qqEnsureSession()
	if sess.sid == "" {
		return ""
	}
	meta := qqSongMetaByMid(mid)
	if meta.id == 0 {
		return ""
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
	data, err := qqMusicuPost("GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", param, qqComm(sess))
	if err != nil {
		return ""
	}
	var out struct {
		Lyric string      `json:"lyric"`
		QrcT  json.Number `json:"qrc_t"`
		LrcT  json.Number `json:"lrc_t"`
	}
	if err := json.Unmarshal(data, &out); err != nil || out.Lyric == "" {
		return ""
	}
	t := out.QrcT.String()
	if t == "" || t == "0" {
		t = out.LrcT.String()
	}
	if t == "" || t == "0" {
		return ""
	}
	decrypted := decryptQRC(out.Lyric)
	if decrypted == "" {
		return ""
	}
	content := extractQRCLyricContent(decrypted)
	if content == "" {
		return ""
	}
	return qrcToYRC(content)
}
