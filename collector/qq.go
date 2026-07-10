// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

var (
	qqURLMu    sync.Mutex
	qqURLCache = map[string]string{}
)

// qqMusicURL returns the QQ Music song-detail URL for a track, resolved via
// smartbox + single-song album enrichment (see resolveQQMusicURL). Cached per
// artist|title|album; only real song URLs are cached — the search-link fallback
// is not, so a later poll retries exact resolution.
func qqMusicURL(artist, title, album string) string {
	if title == "" {
		return ""
	}
	key := artist + "|" + title + "|" + album
	qqURLMu.Lock()
	if v, ok := qqURLCache[key]; ok {
		qqURLMu.Unlock()
		return v
	}
	qqURLMu.Unlock()

	if url := resolveQQMusicURL(artist, title, album); url != "" {
		qqURLMu.Lock()
		qqURLCache[key] = url
		qqURLMu.Unlock()
		return url
	}
	// smartbox 无结果/无标题匹配时，退回 QQ 搜索链接：桌面能打开搜索页、绝不串到错歌
	// (用户自己选)。不缓存，下次提交再试精确解析。
	return "https://y.qq.com/n/ryqq/search?w=" + neturl.QueryEscape(artist+" "+title)
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
	resp, err := (&http.Client{Timeout: 6 * time.Second}).Do(req)
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
	resp, err := (&http.Client{Timeout: 6 * time.Second}).Do(req)
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
	resp, err := (&http.Client{Timeout: 6 * time.Second}).Do(req)
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
// withdrawn artists (Jay Chou is the case that surfaced this; 实测坐实见
// artistMatches 注释) are absent from NetEase entirely, so searching there
// only turns up impersonator accounts. Requires a strict (non-loose) artist
// match on BOTH the smartbox search hit and the detail-lookup singer field,
// so a QQ-side impersonator/cover account can't slip through either step.
// 第二个返回值是 QQ 音乐核实过的官方歌手名(见下方 artistMatches 校验)，用于统一同一
// 歌手在历史记录里时而中文时而英文、时而全大写的写法(如 PRINCE/Prince)。
func qqCoverFallback(artist, title string) (cover, canonicalArtist string) {
	if artist == "" || title == "" {
		return "", ""
	}
	// 跟 netease.go 里 chosen 分支同样的道理:本地标签本来就是多人合credit(如"Prince
	// & The Revolution")时,QQ 的 singer 字段可能只单独记了其中一位——不把这个当统一
	// 歌手名用,避免悄悄丢掉本地已经写全的合作者;封面照常正常解析,不受影响。
	singleArtist := len(artistCreditParts(artist)) < 2
	for _, it := range qqSmartbox(artist + " " + title) {
		if it.Mid == "" || !looseContains(it.Name, title) || !artistMatches(it.Singer, artist) {
			continue
		}
		if c, singer := qqSongCoverAndSinger(it.Mid); c != "" && artistMatches(singer, artist) {
			if !singleArtist {
				return c, ""
			}
			return c, singer
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

func resolveQQMusicURL(artist, title, album string) string {
	items := qqSmartbox(artist + " " + title)
	if len(items) == 0 {
		items = qqSmartbox(title) // 歌手名跨平台不一致时,退一步只按标题再搜
	}
	type qqCand struct {
		mid   string
		exact bool // name 与 title loose 相等 → 规范版,避开 纯音乐/串烧/live 变体
	}
	// strict 档用 artistMatches(要求逗号/&等分隔的每一段都精确相等);strict 一无所获时
	// 放宽成 looseContains 重试——但绝不完全跳过校验:完全不查歌手会让标题撞上、歌手完全
	// 不相干的翻唱/仿冒账号蒙混过关、链接指向错误的人(同 match.go artistMatches 注释里
	// Jay Chou 那次教训同理;这里此前就是"完全不查")。
	collect := func(strict bool) []qqCand {
		var cs []qqCand
		for _, it := range items {
			if it.Mid == "" || !looseContains(it.Name, title) || !qqArtistOK(strict, it.Singer, artist) {
				continue
			}
			cs = append(cs, qqCand{mid: it.Mid, exact: normLoose(it.Name) == normLoose(title)})
		}
		return cs
	}
	cands := collect(true)
	if len(cands) == 0 {
		cands = collect(false) // artistMatches 太严格(跨平台歌手名写法不同)时放宽成 looseContains,但仍要求歌手名沾边
	}
	if len(cands) == 0 {
		return "" // 无标题匹配 → 上层退搜索链接,绝不给错歌
	}
	// 有专辑名 → 给前几条补专辑、按 albumScore 去重。采集器一首歌只解析一次,
	// 频次低;补专辑失败(反爬/超时)时降级到按名字选,不影响出具体歌链接。
	if album != "" {
		bestMid, bestScore, bestExact := "", 0, false
		for i, c := range cands {
			if i >= 4 {
				break
			}
			sc := albumScore(qqSongAlbum(c.mid), album)
			if sc == 0 && !c.exact {
				continue // 专辑对不上、标题也非精确同名 → 不够格参与本轮选择
			}
			// 标题精确同名优先于专辑分(与 albumScore 的 exact>loose 分层同一原则):避免
			// 同专辑里一首标题超串/子串的非规范版(live/伴奏等)靠专辑分打平甚至反超真正
			// 同名曲目——历史上这类打分边界条件已经在 albumScore 上出过一次真实 bug。
			if bestMid == "" || (c.exact && !bestExact) || (c.exact == bestExact && sc > bestScore) {
				bestMid, bestScore, bestExact = c.mid, sc, c.exact
			}
		}
		if bestMid != "" {
			return qqSongURL(bestMid)
		}
	}
	// 无专辑 / 补专辑没命中 → 精确同名优先,否则第一条(smartbox 首条通常是规范版)。
	for _, c := range cands {
		if c.exact {
			return qqSongURL(c.mid)
		}
	}
	return qqSongURL(cands[0].mid)
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
	resp, err := (&http.Client{Timeout: 6 * time.Second}).Do(req)
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
	if l := out.Lyric; strings.Contains(l, "[") && len(l) < 20000 {
		return l
	}
	return ""
}
