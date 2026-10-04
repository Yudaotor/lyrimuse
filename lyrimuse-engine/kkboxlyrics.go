package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"
)

// KKBOX 本地歌词:用 KKBOX 放歌时,读 KKBOX 客户端自己缓存里的那份歌词(缓存格式与路径见 kkboxqueue.go)。
//
// 它**不是歌词源**:不能按歌名去搜,只有用 KKBOX 放过的歌才有,所以不进源清单、设置里没有开关、不算进「几个歌词源」。
// KKBOX 的在线接口要登录凭据,不接(见 09 章决策 103)。候选的来源名是 kkboxLocalLyricsSource,只在正在用 KKBOX 放歌时读
// (kkboxLocalLyricsFor),players.json 里 KKBOX 的 nativeLyricSource 也填它,于是照样享受同源加权。
//
// KKBOX 开播一首歌时拉三样东西:`/v2/tracks/<id>`(单曲详情)、`/v2/lyrics/<id>`(歌词)、`/v2/related-tracks/<id>`。
// 歌词接口的正文是 `data.info.lyrics`,逐行 `{start, end, type, text}`(毫秒),没有逐字、没有译文;`type` 是合唱
// 分段(男 / 女 / 合),这里不用。开头那几行署名(作词 / 编曲 / Written By)start 与 end 都是 0,去掉;歌词本身从第一句
// 起都有时间。
//
// 只有 KKBOX 放过的歌才有,所以不搜索、不发请求:按缓存里有歌词的那些曲目 id,解开它们的单曲详情比歌名 + 歌手
// (或时长)。歌词是用户上传后审核的(`uploaded_by`),有一部分只精确到整秒 —— 这类标成 coarse,不享受同源加权
// (见 lyricCandidate.identityFromLocalClient),交给打分跟各歌词源公平比。
//
// 只读,读不动当没有;播放器没装、没用 KKBOX 放过这首,都是安静地空手而归。

// kkboxLocalLyricsSource:KKBOX 本地歌词那份候选的来源名(歌词缓存的 lyrics_source、决策记录、界面上的来源都用它)。
const kkboxLocalLyricsSource = "kkbox"

// kkboxLyricsMinLines:少于这么多句带时间的不算有歌词(只剩署名、或只上传了一两句)。
const kkboxLyricsMinLines = 3

// kkboxLyricsDurationTolerance:按时长认同一首时允许差多少秒(歌手名写法对不上时用,见 kkboxLyricMatch)。
const kkboxLyricsDurationTolerance = 2.0

type kkboxLyricResult struct {
	lyrics, title, artist, album string
	cover                        string // 单曲详情里的专辑封面,候选列表显示用
	durationSecs                 float64
	// coarse:每一句的时间都是整秒。
	coarse bool
	// weakIdentity:歌手不是逐字对上的,是靠「去掉括号别名后沾边 + 时长对得上」认的(见 kkboxLyricMatchLevel)。
	// 这种不当成播放器本地给的身份,不吃同源加权。
	weakIdentity bool
}

type kkboxLyricsBody struct {
	Data struct {
		Info *struct {
			Lyrics []struct {
				Start int64  `json:"start"`
				End   int64  `json:"end"`
				Text  string `json:"text"`
			} `json:"lyrics"`
		} `json:"info"`
	} `json:"data"`
}

// kkboxLyricsLRC 把歌词接口的正文换成 LRC;带时间的句子不够 kkboxLyricsMinLines 返回 ok=false。
func kkboxLyricsLRC(body []byte) (lrc string, coarse, ok bool) {
	var r kkboxLyricsBody
	if json.Unmarshal(body, &r) != nil || r.Data.Info == nil {
		return "", false, false
	}
	var b strings.Builder
	timed := 0
	coarse = true
	for _, l := range r.Data.Info.Lyrics {
		if l.Start == 0 && l.End == 0 {
			continue
		}
		if l.Start < 0 {
			continue
		}
		timed++
		if l.Start%1000 != 0 {
			coarse = false
		}
		cs := l.Start / 10
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", cs/6000, cs/100%60, cs%100, strings.TrimSpace(l.Text))
	}
	if timed < kkboxLyricsMinLines {
		return "", false, false
	}
	return b.String(), coarse, true
}

// kkboxLyricMatch:缓存里的这首是不是播放器报的这首,见 kkboxLyricMatchLevel。
func kkboxLyricMatch(t kkboxTrack, artist, title string, durationSecs float64) bool {
	return kkboxLyricMatchLevel(t, artist, title, durationSecs) > kkboxMatchNone
}

const (
	kkboxMatchNone = iota
	// kkboxMatchByAlias:歌手写法不同(别的播放器报「五月天」、KKBOX 是「五月天 (Mayday)」),去掉括号别名后
	// 互相沾边,而且时长对得上。
	kkboxMatchByAlias
	// kkboxMatchExact:歌名、歌手都对上。
	kkboxMatchExact
)

// kkboxLyricMatchLevel:歌名要对上;歌手逐字对上是 exact。对不上时只认去掉括号别名后互相包含、且时长差在
// kkboxLyricsDurationTolerance 以内的 —— 原来只看时长,换一首时长差不到两秒的翻唱,原唱那份词就被当成这首的。
func kkboxLyricMatchLevel(t kkboxTrack, artist, title string, durationSecs float64) int {
	if loosenEnrichKey(t.Name) != loosenEnrichKey(title) {
		return kkboxMatchNone
	}
	name := kkboxArtistName(t, "")
	if loosenEnrichKey(name) == loosenEnrichKey(artist) {
		return kkboxMatchExact
	}
	if !kkboxArtistAliasCompatible(name, artist) {
		return kkboxMatchNone
	}
	if durationSecs > 0 && t.DurationMs > 0 && math.Abs(t.DurationMs/1000-durationSecs) <= kkboxLyricsDurationTolerance {
		return kkboxMatchByAlias
	}
	return kkboxMatchNone
}

// kkboxArtistAliasCompatible:两个歌手名去掉括号别名(半角、全角都算)之后,一个包含另一个。
func kkboxArtistAliasCompatible(a, b string) bool {
	na, nb := loosenEnrichKey(stripParens(a)), loosenEnrichKey(stripParens(b))
	if na == "" || nb == "" {
		return false
	}
	return strings.Contains(na, nb) || strings.Contains(nb, na)
}

// lyricsByTrack:缓存里有歌词的曲目 id → 最新那份歌词。
func (c kkboxCache) lyricsByTrack() map[string]kkboxCacheEntry {
	out := map[string]kkboxCacheEntry{}
	for _, e := range c {
		id, ok := strings.CutPrefix(e.url.Path, "/v2/lyrics/")
		if !ok || id == "" || strings.Contains(id, "/") {
			continue
		}
		if _, seen := out[id]; !seen {
			out[id] = e
		}
	}
	return out
}

// lyricFor 找这首的歌词:只解开有歌词的那些曲目的单曲详情。
func (c kkboxCache) lyricFor(artist, title string, durationSecs float64) (kkboxLyricResult, bool) {
	lyrics := c.lyricsByTrack()
	if len(lyrics) == 0 {
		return kkboxLyricResult{}, false
	}
	// 先找歌手逐字对上的那条;只有别名 + 时长认出来的,等整份扫完都没有逐字对上的才用(缓存按新到旧排,
	// 原来第一个命中就返回,不会优先选歌手对上的那条)。
	tried := map[string]bool{}
	var weak *kkboxLyricResult
	for _, e := range c {
		id, ok := strings.CutPrefix(e.url.Path, "/v2/tracks/")
		if !ok || id == "" || tried[id] {
			continue
		}
		lyr, has := lyrics[id]
		if !has {
			continue
		}
		tried[id] = true
		body, ok := e.body()
		if !ok {
			continue
		}
		var d struct {
			Data kkboxTrack `json:"data"`
		}
		if json.Unmarshal(body, &d) != nil {
			continue
		}
		level := kkboxLyricMatchLevel(d.Data, artist, title, durationSecs)
		if level == kkboxMatchNone || (level == kkboxMatchByAlias && weak != nil) {
			continue
		}
		r, ok := kkboxLyricResultFrom(d.Data, lyr)
		if !ok {
			continue
		}
		if level == kkboxMatchExact {
			return r, true
		}
		r.weakIdentity = true
		weak = &r
	}
	if weak != nil {
		return *weak, true
	}
	return kkboxLyricResult{}, false
}

// kkboxLyricResultFrom 把一条单曲详情 + 它的歌词条目装成结果;歌词条目读不出、不是能用的歌词时 ok=false。
func kkboxLyricResultFrom(t kkboxTrack, lyr kkboxCacheEntry) (kkboxLyricResult, bool) {
	lbody, ok := lyr.body()
	if !ok {
		return kkboxLyricResult{}, false
	}
	lrc, coarse, ok := kkboxLyricsLRC(lbody)
	if !ok {
		return kkboxLyricResult{}, false
	}
	album := ""
	if t.Album != nil {
		album = t.Album.Name
	}
	return kkboxLyricResult{
		lyrics: lrc, title: t.Name, artist: kkboxArtistName(t, ""), album: album, cover: t.albumCover(),
		durationSecs: t.DurationMs / 1000, coarse: coarse,
	}, true
}

// kkboxLyric 在 KKBOX 的缓存里找这首的歌词。
func kkboxLyric(artist, title string, durationSecs float64) (kkboxLyricResult, bool) {
	return scanKKBOXCache(kkboxCacheDir()).lyricFor(artist, title, durationSecs)
}

// kkboxLocalLyricsFor 给歌词检索用:正在用 KKBOX 放歌(它是当前播放器的同源,见 setNativeLyricSourcesForPlayer)时才读,
// 换成一份跟各歌词源同形的原始应答。
func kkboxLocalLyricsFor(artist, title string, durationSecs float64) (lyricSourceResult, bool) {
	if !isNativeLyricSource(kkboxLocalLyricsSource) {
		return lyricSourceResult{}, false
	}
	r, ok := kkboxLyric(artist, title, durationSecs)
	if !ok {
		return lyricSourceResult{}, false
	}
	return lyricSourceResult{
		source: kkboxLocalLyricsSource, lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album,
		matchCover: r.cover, srcDur: r.durationSecs, identityFromLocalClient: !r.coarse && !r.weakIdentity,
	}, true
}

// kkboxPlayingInfo:用 KKBOX 放的这首,它缓存里现在有的两样东西 —— 单曲详情给的歌曲页,和有没有它的歌词。
type kkboxPlayingInfo struct {
	url    string
	lyrics bool
}

// kkboxPlayingInfoTTL:同一首记多久。trackEnrichment 在同一首歌的播放期间会被反复调用,每次都扫一遍缓存目录不值当;
// KKBOX 开播后一两秒就把详情和歌词写进缓存,30 秒内问到的都是同一个答案。
const kkboxPlayingInfoTTL = 30 * time.Second

var (
	kkboxPlayingInfoMu   sync.Mutex
	kkboxPlayingInfoMemo = map[string]kkboxPlayingInfoAt{}
)

type kkboxPlayingInfoAt struct {
	at   time.Time
	info kkboxPlayingInfo
}

// kkboxPlayingInfoFor 取这首的歌曲页和歌词有无(见 kkboxLyricsWorthRecheck、enrichEntry.KKBOXURL)。
func kkboxPlayingInfoFor(artist, title string, durationSecs float64) kkboxPlayingInfo {
	key := loosenEnrichKey(artist) + "\x00" + loosenEnrichKey(title)
	now := time.Now()
	kkboxPlayingInfoMu.Lock()
	if m, ok := kkboxPlayingInfoMemo[key]; ok && now.Sub(m.at) < kkboxPlayingInfoTTL {
		kkboxPlayingInfoMu.Unlock()
		return m.info
	}
	kkboxPlayingInfoMu.Unlock()
	c := scanKKBOXCache(kkboxCacheDir())
	_, lyrics := c.lyricFor(artist, title, durationSecs)
	info := kkboxPlayingInfo{url: c.songURLFor(artist, title, durationSecs), lyrics: lyrics}
	kkboxPlayingInfoMu.Lock()
	for k, m := range kkboxPlayingInfoMemo {
		if now.Sub(m.at) >= kkboxPlayingInfoTTL {
			delete(kkboxPlayingInfoMemo, k)
		}
	}
	kkboxPlayingInfoMemo[key] = kkboxPlayingInfoAt{at: now, info: info}
	kkboxPlayingInfoMu.Unlock()
	return info
}

// songURLFor:缓存里这首的单曲详情给的歌曲页;只认 KKBOX 自己网站上的 song 页。
func (c kkboxCache) songURLFor(artist, title string, durationSecs float64) string {
	for _, e := range c {
		id, ok := strings.CutPrefix(e.url.Path, "/v2/tracks/")
		if !ok || id == "" {
			continue
		}
		body, ok := e.body()
		if !ok {
			continue
		}
		var d struct {
			Data kkboxTrack `json:"data"`
		}
		var u struct {
			Data struct {
				URL string `json:"url"`
			} `json:"data"`
		}
		if json.Unmarshal(body, &d) != nil || json.Unmarshal(body, &u) != nil || !kkboxLyricMatch(d.Data, artist, title, durationSecs) {
			continue
		}
		if kkboxSongPageURL(u.Data.URL) {
			return u.Data.URL
		}
	}
	return ""
}

// kkboxSongPageURL:`https://www.kkbox.com/<地区>/<语言>/song/<id>` 这种形状才认(缓存条目是别的 App 写的,不照单全收)。
func kkboxSongPageURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "www.kkbox.com" {
		return false
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	return len(parts) == 4 && parts[2] == "song" && parts[3] != ""
}

// kkboxLyricsRechecked:这次进程里已经为 kkbox 重来过的条目。kkbox 那份被判废分时不会记进 LyricsSourcesSeen,
// 光靠 kkboxLyricsWorthRecheck 会每次调用都再来一遍(重试次数上限兜得住,但那是三次全源重搜)。只在 enrichMu 里读写。
var kkboxLyricsRechecked = map[string]bool{}

// kkboxLyricsRecheckOnce:这个条目这次进程里还没为 kkbox 重来过就记下、返回 true。调用方持有 enrichMu。
func kkboxLyricsRecheckOnce(key string) bool {
	if kkboxLyricsRechecked[key] {
		return false
	}
	kkboxLyricsRechecked[key] = true
	return true
}

// kkboxLyricsWorthRecheck:正在用 KKBOX 放的这首,缓存里的歌词当初没见过 KKBOX 本地歌词那份候选,而 KKBOX 现在有它的词 →
// 值得重来一次(retryLyricsUpgrade,分数严格更高才替换)。KKBOX 只在开播时才拉当前这首的词,预解析过的条目播到时已经在了,
// 不补这一次它自己的词就进不了打分(见 09 章决策 103)。
//
// 只看 kkbox 一家(同源加权的立论只对 KKBOX 成立,见 02 章决策 41),available 由调用方在锁外算好传进来。
// kkbox 已经在 LyricsSourcesSeen 里,或者最近一轮决策里它应答过(别的路径刚把歌词重搜过一遍,比如补外围字段那条,
// 它不写 LyricsSourcesSeen),就不再来;kkbox 只有真拿到词才算应答,所以应答过 = 已经打过分。手改过、校准过、
// 关了自动升级的都不动。
func kkboxLyricsWorthRecheck(e enrichEntry, bundleID string, pinned, autoUpgrade, available bool) bool {
	if bundleID != kkboxBundleID || !autoUpgrade || pinned || e.ManualLyrics || !available {
		return false
	}
	if slices.Contains(e.LyricsSourcesSeen, kkboxLocalLyricsSource) || slices.Contains(e.LyricsSourcesResponded, kkboxLocalLyricsSource) {
		return false
	}
	if e.LyricsDecision != nil && slices.Contains(e.LyricsDecision.SourcesResponded, kkboxLocalLyricsSource) {
		return false
	}
	return e.LyricsRetryCount < lyricsRetryMaxAttempts
}
