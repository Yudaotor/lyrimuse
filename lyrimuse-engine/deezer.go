package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// deezerLyric 是歌词第十个候选来源(Deezer)。跟 lyricfind(ytmusic.go)
// **数据同源**:Deezer 的歌词由 LyricFind 供词、时间轴由 Deezer 自己做——接这一路的
// 意义有两层:① 给 LyricFind 这家版权方补第二条管道(现在 lyricfind 只有 YouTube Music
// 一条路,YTM 一改版或在某地区不可用,这家的数据就整体拿不到);② Deezer 是法国公司,
// 法语曲库的覆盖比现有九源都好——接入实测见下。
//
// 两段式(逐段实测):
//
//	① 搜索走 **pipe.deezer.com 的 GraphQL `search`**(deezerGraphQLSearch):一次拿 10 条,每条带
//	   hasSynchronizedLyrics,没有同步歌词的不去取词。这个接口按 Accept-Language 把歌名 / 艺人名 / 专辑名
//	   本地化,所以请求头按查询里的文字选(deezerSearchLanguage)。它没问成(网页客户端接口,可能随时变)
//	   才退回**公开** api.deezer.com/search:不需要认证,但不管请求头一律给英文译名(周杰伦《稻香》回
//	   「Rice Field / Jay Chou」),中文 / 日文歌几乎过不了名称闸(09 章决策 136 的实测)。
//	② 取词也走 GraphQL,认证用 auth.deezer.com/login/anonymous 换来的**匿名 JWT**(不需要账号、不需要
//	   ARL、不碰用户登录态)。JWT 自带 exp,实测 iat 到 exp 只有 6 分钟,过期后回 HTTP 200 +
//	   JwtTokenExpiredError(不是 401);进程级缓存 + 单飞锁(同 musixmatch token / ytmusic visitor id)。
//	   响应 data.track.lyrics 里 synchronizedLines[] 是逐行(lrcTimestamp 形如
//	   "[00:01.41]" + line,lineTranslated 是这一行的译文),synchronizedWordByWordLines[]
//	   是逐字({start,end,words:[{start,end,word}]},毫秒),text 是整份纯文本。
//	   译文语言跟请求头 Accept-Language 走(deezerAcceptLanguage)。
//
// **别再走 gw-light.php 的 song.getLyrics —— 那条路已经废了**。它对**任何**歌都回
// `{"DATA_ERROR":"No lyrics id for <id> and country XX"}`,错误文案里的国家极具误导性
// ——第一眼会读成"这个国家没有歌词授权"。对照实验推翻了这个解读:换出口到 US 之后,
// 同一首歌照样回 "No lyrics id ... and country US";直接查 song.getData 更是一目了然:
// **LYRICS_ID 字段对所有歌恒为 0**,连 Adele《Hello》、Stromae《Alors on danse》这种
// 铁定有词的也是 0。也就是说那句话是字面意思——它在旧数据模型里找 lyrics id,而那个
// 字段已经不再被填充,跟国家、跟登录与否都无关。公开实现 syncedlyrics 的 deezer provider
// 至今标着 "Currently broken"、把病因归到 CSRF token,同样是被这条路带偏了。
//
// 实测覆盖(匿名 JWT):Joseph Kamel《Crash》64 行、Zaho de Sagazan
// 《Les dormantes》60 行、Hervé《Si bien du mal》22 行、Stromae《Alors on danse》61 行、
// Aya Nakamura《Djadja》52 行、Adele《Hello》44 行 —— 前三首正是接入前"九源里只有
// lrclib/netease 给得出低分候选"的法语小众歌。周杰伦《稻香》只有 584 字纯文本、没有
// 逐行(走 plainOnly 通道);Jungeli《Juste un peu》、Suzane《SLT》回
// LyricsNotFoundError(真没收录,不是失败)。
//
// **它跟 lyricfind 不是两个独立信源**(正文层面)。两条管道的接口、曲库、匹配、故障面
// 都各走各的,时间轴也不同源(Deezer 的同步是它自己做的,LyricFind 只供词)——但**正文**
// 出自同一家。打分层的"跨源正文共识"按独立信源数给分,所以必须按**供词方**归组而不是按
// 源名:见 match.go 的 lyricSourceConsensusFamily(deezer 与 lyricfind 归同一家)。不归组的
// 后果有两个:两条管道互相印证各拿一份加分、第三方误以为有两家印证拿 +250。这条纪律
// ytmusic.go 顶部早就写下了,接这个源时从另一个方向又踩了一次。
//
// 逐字轨与逐行轨是两份独立的时间轴,逐字轨偶尔整份错位,只在它跟逐行轨对得上时才用
// (deezerWordTrackAgrees)。译文只在文字系统跟目标语言对得上时才用
// (deezerTranslationFitsLanguage):Deezer 没有目标语言的译文时会退回英文。没有罗马音。
// 逐字只覆盖拉丁字母写的歌词,中日韩歌词的逐字轨是空的。搜索排序可信(原版排第一、acoustic 版排第二,实测),
// 所以跟 migu 一样不重排,只套跟别的源完全一致的身份闸;但 Deezer 的搜索结果**自带时长**,
// 比 migu 多一道时长闸和时长加分(口径与 kuwo 一致,容差 0.25)。
//
// 合规提醒:①搜索用的是 Deezer 公开 API;②auth/pipe 两个端点是网页客户端接口、非公开
// 文档,跟 kuwo.go / migu.go / musixmatch.go 同一类风险(可能随时失效或要求验证码),
// 不是新引入一种风险类别。全程匿名,不碰用户账号、不需要登录。
type deezerResult struct {
	lyrics, title, artist, album string
	// yrc:逐字轨转成的 YRC,没有或没过 deezerWordTrackAgrees 时为空。
	yrc string
	// tr:目标语言的逐行译文(LRC,跟 lyrics 同一套时间戳),没有时为空。
	tr string
	// cover:album.cover_xl 换成原图档(见 deezerTrack.cover),搜索结果自带,不用多发请求。拿不到就留空,
	// 交给 enrich.go 的 coverOrFallback 退到 Apple 封面。
	cover string
	// durationSecs:Deezer 自报的曲长(秒),透传给打分的 sourceReportedDurationSecs。
	durationSecs float64
	// plainOnly:只拿到整份纯文本、没有 synchronizedLines —— 语义与取舍完全等同
	// lrclibResult.plainOnly,见那边的头注(分数钉死 -1,只有用户在弹窗里手点才会采用)。
	plainOnly bool
	// songwriters:歌词附带的词曲作者名单(Lyrics.writers,deezerSongwriters 拆开),没有时为空。
	songwriters []string
	// isrc:挑中那条录音的 ISRC(deezerTrack.ISRC),没有时为空。
	isrc string
}

func (r deezerResult) empty() bool { return r.lyrics == "" }

// deezerSongwriters 把 Lyrics.writers(逗号隔开的一串人名)拆成名单,去掉首尾空白、空项与重复。
func deezerSongwriters(writers string) []string {
	return ttmlSongwriters(strings.Split(writers, ","))
}

// deezerAuthAPI:换匿名票的地址。是变量只为单测能指到本地服务器。
var deezerAuthAPI = "https://auth.deezer.com/login/anonymous?jo=p&rto=c&i=c"

const (
	deezerSearchAPI = "https://api.deezer.com/search"
	// deezerTrackAPI:曲目端点。这里只用它的 /isrc:<ISRC> 形式(按录音直取,见 deezerTrackByISRC)。
	deezerTrackAPI = "https://api.deezer.com/track"
	deezerPipeAPI  = "https://pipe.deezer.com/api"
	// deezerScoreDurationTolerance 跟别的源的时长闸门(match.go 的 0.25)取同一个值。
	deezerScoreDurationTolerance = 0.25
	// deezerMaxCandidatesToFetch:通过身份闸后最多拉几条歌词。Deezer 排序可信、原版通常
	// 就是第一条,3 条足够覆盖"第一条恰好没词"的情况——理由同 migu,不必像 kuwo 拉 5 条。
	deezerMaxCandidatesToFetch = 3
	deezerHTTPTimeout          = 6 * time.Second
	// deezerJWTFallbackTTL:JWT 里解不出 exp 时的保守有效期。只在解析失败时兜底,宁可多换几次也不要
	// 拿着过期的票反复被拒。
	deezerJWTFallbackTTL = 5 * time.Minute
	// deezerJWTRenewMargin:提前这么久就当它过期,免得卡在边界上换票。票只有 6 分钟,提前量别写成分钟级 ——
	// 5 分钟的提前量等于每张票只用 1 分钟,几乎每首歌都要多换一次票。
	deezerJWTRenewMargin = 30 * time.Second
)

// deezerLyricsQuery 是取词用的 GraphQL 查询。只要这一路真正用得上的字段:逐行与译文
// (synchronizedLines)、逐字(synchronizedWordByWordLines)、整份纯文本(text)和词曲作者(writers,见 songwritersFromScored)。
// copyright / licence 不取:下游不消费。
const deezerLyricsQuery = `query SynchronizedTrackLyrics($trackId: String!) {
  track(trackId: $trackId) {
    id
    lyrics {
      id
      text
      writers
      synchronizedLines {
        lrcTimestamp
        milliseconds
        line
        lineTranslated
      }
      synchronizedWordByWordLines {
        start
        end
        words {
          start
          end
          word
        }
      }
    }
  }
}`

var (
	deezerMu    sync.Mutex
	deezerCache = map[string]deezerResult{}

	// deezerJWTMu 保护下面两个值本身;deezerJWTFetchMu 是单飞锁,同一时刻只允许一个
	// goroutine 真的去换票。理由跟 musixmatch.go 的 musixmatchTokenFetchMu /
	// ytmusic.go 的 ytmusicVisitorFetchMu 一字不差:相册预取一次能触发十几首歌并发解析,
	// 各自"没有就自己去拿一个"会同时打十几个请求。
	deezerJWTMu       sync.Mutex
	deezerJWT         string
	deezerJWTExpires  time.Time
	deezerJWTFetchMu  sync.Mutex
	deezerLastFailMu  sync.Mutex
	deezerLastFailure string
)

func deezerSetLastFailureReason(reason string) {
	deezerLastFailMu.Lock()
	deezerLastFailure = reason
	deezerLastFailMu.Unlock()
}

// deezerLastFailureReasonNow 供 search-lyrics / test-lyric-sources 用——本次进程里最近
// 一次识别出的具体失败原因,识别不出就是空串。 目前**只有一种**已实测的失败模式:
// 匿名 JWT 换不到(auth 端点不答或改了形状)。"这首歌没有歌词"(LyricsNotFoundError)
// 不算失败,不往这里记 —— 那是正常结果,报上去会让用户以为源坏了。
func deezerLastFailureReasonNow() string {
	deezerLastFailMu.Lock()
	defer deezerLastFailMu.Unlock()
	return deezerLastFailure
}

// isrc:这次播放的这条录音的 ISRC(spotifyisrc.go;只有 Spotify 原生客户端在播、且它的
// 缓存里记了才有)。空串 = 照原样走名称搜索。
func deezerLyric(ctx context.Context, artist, title, album string, durationSecs float64, isrc string) deezerResult {
	if title == "" {
		return deezerResult{}
	}
	// isrc 必须进缓存键。首播那一拍 ISRC 索引往往还没建好(它是后台异步建的),
	// 那次拿到的是"按名字搜"的结果;不区分的话这条缓存会把后面所有次都挡住,
	// ISRC 这条路永远轮不到。
	key := artist + "|" + title + "|" + album + "|" + isrc + "|" + deezerAcceptLanguage()
	deezerMu.Lock()
	if v, ok := deezerCache[key]; ok {
		deezerMu.Unlock()
		return v
	}
	deezerMu.Unlock()

	r := resolveDeezerLyric(ctx, artist, title, album, durationSecs, isrc)
	if !r.empty() {
		deezerMu.Lock()
		deezerCache[key] = r
		deezerMu.Unlock()
	}
	return r
}

// deezerTrack 只挑这一路真正用得上的字段,字段名与实测 dump 的一致。
type deezerTrack struct {
	ID           int64  `json:"id"`
	Title        string `json:"title"`
	TitleVersion string `json:"title_version"` // "(Version acoustique)" 这类版本后缀,已含在 Title 里
	Duration     int    `json:"duration"`      // 秒
	// ISRC:这条录音的 ISRC。GraphQL 搜索与按 ISRC 直取都带,公开搜索不带。
	ISRC   string `json:"isrc"`
	Artist struct {
		Name string `json:"name"`
	} `json:"artist"`
	Album struct {
		Title   string `json:"title"`
		CoverXL string `json:"cover_xl"`
		CoverBg string `json:"cover_big"`
	} `json:"album"`
}

// cover:cover_xl 是 1000x1000,地址里的尺寸段换成 1800x1800 拿原图 —— 请求比原图大时按原图给(实测
// 原图 1200 的两张都返回 1200),2000 起回 403。
func (t deezerTrack) cover() string {
	if u := strings.TrimSpace(t.Album.CoverXL); u != "" {
		if strings.Contains(u, "dzcdn.net/images/cover/") {
			return strings.Replace(u, "/1000x1000-", "/1800x1800-", 1)
		}
		return u
	}
	return strings.TrimSpace(t.Album.CoverBg)
}

// deezerSearch 打公开搜索接口。不需要认证 —— 这是 Deezer 自己文档化的 API。
func deezerSearch(ctx context.Context, artist, title string) ([]deezerTrack, error) {
	q := strings.TrimSpace(artist + " " + title)
	u := deezerSearchAPI + "?limit=10&q=" + neturl.QueryEscape(q)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Data  []deezerTrack   `json:"data"`
		Error json.RawMessage `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&out); err != nil {
		return nil, err
	}
	// 配额/参数错误时 Deezer 回 200 + {"error":{...}},不是 4xx —— 不把它当成"没这首歌"。
	if deezerHasError(out.Error) {
		return nil, fmt.Errorf("api error %s", strings.TrimSpace(string(out.Error)))
	}
	return out.Data, nil
}

// deezerPublicSearchHits:公开搜索的结果包成 deezerSearchHit(不知道有没有同步歌词,noSync 恒 false)。
func deezerPublicSearchHits(ctx context.Context, artist, title string) ([]deezerSearchHit, error) {
	tracks, err := deezerSearch(ctx, artist, title)
	if err != nil {
		return nil, err
	}
	hits := make([]deezerSearchHit, len(tracks))
	for i, t := range tracks {
		hits[i] = deezerSearchHit{track: t}
	}
	return hits, nil
}

// deezerISRCDirectScore:ISRC 直取那条候选的排序分。只有它一条时排序本来就无意义,
// 给个明确的高值只为读代码时一眼看出"这条不是打分打出来的"。
const deezerISRCDirectScore = 1 << 20

// deezerTrackByISRC 按 ISRC 直取一条录音。Deezer 有官方端点 /track/isrc:<ISRC>
// (实测:HKA351401008 → Special Person / Khalil Fong / 259s)。
//
// 查不到时 Deezer 回 200 + {"error":{...}}(不是 4xx),所以跟 deezerSearch 一样要过
// deezerHasError,不能只看状态码。
func deezerTrackByISRC(ctx context.Context, isrc string) (deezerTrack, bool) {
	if isrc == "" {
		return deezerTrack{}, false
	}
	u := deezerTrackAPI + "/isrc:" + neturl.PathEscape(isrc)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return deezerTrack{}, false
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
	if err != nil {
		return deezerTrack{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return deezerTrack{}, false
	}
	var out struct {
		deezerTrack
		Error json.RawMessage `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return deezerTrack{}, false
	}
	if deezerHasError(out.Error) || out.ID == 0 {
		return deezerTrack{}, false
	}
	log.Printf("deezer: isrc %s -> track %d %q", isrc, out.ID, out.Title)
	return out.deezerTrack, true
}

// deezerHasError:gw/公开 API 成功时 error 字段是空数组或空对象,失败时才是内容。
// 纯函数,便于单测。
func deezerHasError(raw json.RawMessage) bool {
	s := strings.TrimSpace(string(raw))
	return s != "" && s != "null" && s != "[]" && s != "{}"
}

// deezerCandidateScore 给一条搜索结果打分:负数 = 淘汰。身份闸用跟别的源完全一致的判定
// 函数(lyricTitleAccepted/lyricSourceArtistMatches/versionTagsMismatch),不为这一个源
// 另起一套更松的规则;时长闸与加分的口径跟 kuwo.go 一致。纯函数,便于单测。
func deezerCandidateScore(t deezerTrack, artist, title, album string, durationSecs float64) int {
	if t.ID <= 0 {
		return -1
	}
	if !lyricTitleAccepted(t.Title, title) {
		return -1
	}
	if !lyricSourceArtistMatches(t.Artist.Name, artist) {
		return -1
	}
	if versionTagsMismatch(title, album, t.Title, t.Album.Title) {
		return -1
	}
	score := 100
	if durationSecs > 0 {
		d := float64(t.Duration)
		if d <= 0 {
			return score // 时长未知,没法比对,不加不扣
		}
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > deezerScoreDurationTolerance {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// deezerJWTExpiry 从 JWT 的 payload 里读 exp。JWT 是 base64url 编码的三段,中间那段是
// claims;解不出来就返回零值,调用方退回保守 TTL。**不校验签名**——我们不是这张票的
// 验证方,只是想知道它什么时候该换,读错了最坏也就是多换一次。纯函数,便于单测。
func deezerJWTExpiry(jwt string) time.Time {
	parts := strings.Split(jwt, ".")
	if len(parts) < 2 {
		return time.Time{}
	}
	payload := parts[1]
	if pad := len(payload) % 4; pad != 0 {
		payload += strings.Repeat("=", 4-pad)
	}
	raw, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return time.Time{}
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(raw, &claims) != nil || claims.Exp <= 0 {
		return time.Time{}
	}
	return time.Unix(claims.Exp, 0)
}

// deezerEnsureJWT 拿(并进程级缓存)匿名 JWT。过期前 deezerJWTRenewMargin 就当它失效。
func deezerEnsureJWT(ctx context.Context) string {
	now := time.Now()
	deezerJWTMu.Lock()
	tok, exp := deezerJWT, deezerJWTExpires
	deezerJWTMu.Unlock()
	if tok != "" && now.Before(exp) {
		return tok
	}
	deezerJWTFetchMu.Lock()
	defer deezerJWTFetchMu.Unlock()
	deezerJWTMu.Lock()
	tok, exp = deezerJWT, deezerJWTExpires
	deezerJWTMu.Unlock()
	if tok != "" && now.Before(exp) {
		return tok
	}
	tok = deezerFetchJWT(ctx)
	if tok == "" {
		return ""
	}
	exp = deezerJWTExpiry(tok)
	if exp.IsZero() {
		exp = time.Now().Add(deezerJWTFallbackTTL)
	} else {
		exp = exp.Add(-deezerJWTRenewMargin)
	}
	deezerJWTMu.Lock()
	deezerJWT, deezerJWTExpires = tok, exp
	deezerJWTMu.Unlock()
	return tok
}

func deezerClearJWT() {
	deezerJWTMu.Lock()
	deezerJWT, deezerJWTExpires = "", time.Time{}
	deezerJWTMu.Unlock()
}

// deezerFetchJWT 真的去换一张匿名票。拿不到时记下具体失败原因 —— 这是这一路目前**唯一**
// 实测见过的失败模式(取词本身失败只会是"这首没有歌词",那不算源不可用)。
func deezerFetchJWT(ctx context.Context) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, deezerAuthAPI, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
	if err != nil {
		// 调用方自己取消 / 到期的不算「换不到票」:这个原因会让别名重查跳过这一路,见 musixmatch.go 同一处。
		if ctx.Err() == nil {
			deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		}
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	var out struct {
		JWT string `json:"jwt"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	if strings.TrimSpace(out.JWT) == "" {
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
		return ""
	}
	// 换到了就撤掉早先的失败原因,理由同 musixmatch.go 那处。
	deezerSetLastFailureReason("")
	return strings.TrimSpace(out.JWT)
}

// deezerJWTRejected:GraphQL 错误是不是在说票不行(过期 / 没带)。这两种都回 HTTP 200,不是 401。纯函数,便于单测。
func deezerJWTRejected(errs string) bool {
	return strings.Contains(errs, "JwtTokenExpiredError") || strings.Contains(errs, "JwtTokenMissingError")
}

// deezerPipeQuery 发一次 GraphQL 请求,返回 data 与 errors 两段原文。lang 非空时作为 Accept-Language。
// 票被拒(HTTP 401,或 deezerJWTRejected 认得的 GraphQL 错误)时清掉重换,只重试一次。
func deezerPipeQuery(ctx context.Context, operation, query string, variables map[string]any, lang string) (data, errs json.RawMessage, err error) {
	body, err := json.Marshal(map[string]any{"operationName": operation, "variables": variables, "query": query})
	if err != nil {
		return nil, nil, err
	}
	for attempt := 0; attempt < 2; attempt++ {
		jwt := deezerEnsureJWT(ctx)
		if jwt == "" {
			return nil, nil, fmt.Errorf("no anonymous jwt")
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, deezerPipeAPI, strings.NewReader(string(body)))
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("User-Agent", "Mozilla/5.0")
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+jwt)
		if lang != "" {
			req.Header.Set("Accept-Language", lang)
		}
		resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
		if err != nil {
			return nil, nil, err
		}
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		status := resp.StatusCode
		resp.Body.Close()
		if status == http.StatusUnauthorized && attempt == 0 {
			deezerClearJWT()
			continue
		}
		if status != http.StatusOK {
			return nil, nil, fmt.Errorf("status %d", status)
		}
		if readErr != nil {
			return nil, nil, readErr
		}
		var out struct {
			Errors json.RawMessage `json:"errors"`
			Data   json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(raw, &out); err != nil {
			return nil, nil, err
		}
		if deezerHasError(out.Errors) && deezerJWTRejected(string(out.Errors)) && attempt == 0 {
			deezerClearJWT()
			continue
		}
		return out.Data, out.Errors, nil
	}
	return nil, nil, fmt.Errorf("jwt refresh exhausted")
}

// deezerSearchQuery:GraphQL 搜索。只要名称闸、时长闸和封面用得上的字段,外加 hasSynchronizedLyrics;
// 歌词本身不在这一步取 —— 取词要带译文的 Accept-Language,而这一步的请求头要留给名称本地化(见
// deezerSearchLanguage)。封面按 1000x1000 要,形状跟公开 API 的 cover_xl 一样,deezerTrack.cover 照常换原图。
const deezerSearchQuery = `query SearchTracks($query: String!, $first: Int!) {
  search(query: $query) {
    results {
      tracks(first: $first) {
        edges {
          node {
            id
            title
            duration
            isrc
            hasSynchronizedLyrics
            contributors(first: 1) { edges { node { ... on Artist { name } } } }
            album { displayTitle cover { urls(pictureRequest: {width: 1000, height: 1000}) } }
          }
        }
      }
    }
  }
}`

// deezerSearchFirst:GraphQL 搜索取几条。20 条起出现部分 "Track media not found" 错误。
const deezerSearchFirst = 10

// deezerSearchHit:一条搜索结果。known = 这条来自 GraphQL 搜索、带了 hasSynchronizedLyrics(公开 API 的不带);
// noSync = 搜索明确说它没有同步歌词。
type deezerSearchHit struct {
	track         deezerTrack
	known, noSync bool
}

// deezerSearchLanguage:GraphQL 搜索的 Accept-Language。这个接口按请求头把歌名、艺人名、专辑名本地化 ——
// 英文请求头下周杰伦《稻香》是「Rice Field / Jay Chou」,中文请求头下 Michael Jackson 是「麥可傑克森」——
// 名称闸要拿原文比,所以按查询里的文字选:有假名用日文、有谚文用韩文、只有汉字用中文,其余用英文。纯函数,便于单测。
func deezerSearchLanguage(s string) string {
	switch {
	case containsKana(s):
		return "ja-JP"
	case strings.ContainsFunc(s, func(r rune) bool { return unicode.Is(unicode.Hangul, r) }):
		return "ko-KR"
	case containsHan(s):
		return "zh-CN"
	}
	return "en-US"
}

// deezerGraphQLSearch 用 GraphQL 搜索。请求没成 / 回了错误(除了部分结果带的零星错误)都返回 err,调用方退回公开搜索。
func deezerGraphQLSearch(ctx context.Context, artist, title string) ([]deezerSearchHit, error) {
	q := strings.TrimSpace(artist + " " + title)
	data, errs, err := deezerPipeQuery(ctx, "SearchTracks", deezerSearchQuery, map[string]any{"query": q, "first": deezerSearchFirst}, deezerSearchLanguage(q))
	if err != nil {
		return nil, err
	}
	var out struct {
		Search struct {
			Results struct {
				Tracks struct {
					Edges []struct {
						Node struct {
							ID                    string `json:"id"`
							Title                 string `json:"title"`
							Duration              int    `json:"duration"`
							ISRC                  string `json:"isrc"`
							HasSynchronizedLyrics bool   `json:"hasSynchronizedLyrics"`
							Contributors          struct {
								Edges []struct {
									Node struct {
										Name string `json:"name"`
									} `json:"node"`
								} `json:"edges"`
							} `json:"contributors"`
							Album struct {
								DisplayTitle string `json:"displayTitle"`
								Cover        struct {
									URLs []string `json:"urls"`
								} `json:"cover"`
							} `json:"album"`
						} `json:"node"`
					} `json:"edges"`
				} `json:"tracks"`
			} `json:"results"`
		} `json:"search"`
	}
	if len(data) == 0 || string(data) == "null" || json.Unmarshal(data, &out) != nil {
		return nil, fmt.Errorf("graphql search: no data %s", strings.TrimSpace(string(errs)))
	}
	edges := out.Search.Results.Tracks.Edges
	if len(edges) == 0 && deezerHasError(errs) {
		return nil, fmt.Errorf("graphql search error %s", strings.TrimSpace(string(errs)))
	}
	hits := make([]deezerSearchHit, 0, len(edges))
	for _, e := range edges {
		n := e.Node
		id, _ := strconv.ParseInt(n.ID, 10, 64)
		var t deezerTrack
		t.ID, t.Title, t.Duration, t.ISRC = id, n.Title, n.Duration, n.ISRC
		if len(n.Contributors.Edges) > 0 {
			t.Artist.Name = n.Contributors.Edges[0].Node.Name
		}
		t.Album.Title = n.Album.DisplayTitle
		if len(n.Album.Cover.URLs) > 0 {
			t.Album.CoverXL = n.Album.Cover.URLs[0]
		}
		hits = append(hits, deezerSearchHit{track: t, known: true, noSync: !n.HasSynchronizedLyrics})
	}
	return hits, nil
}

// deezerSyncLine 是 synchronizedLines 的一个元素(实测形状)。
type deezerSyncLine struct {
	LRCTimestamp   string `json:"lrcTimestamp"` // "[00:01.41]"
	Milliseconds   int    `json:"milliseconds"`
	Line           string `json:"line"`
	LineTranslated string `json:"lineTranslated"`
}

// deezerWordLine 是 synchronizedWordByWordLines 的一个元素,时间都是毫秒、绝对时刻。
type deezerWordLine struct {
	Start int          `json:"start"`
	End   int          `json:"end"`
	Words []deezerWord `json:"words"`
}

type deezerWord struct {
	Start int    `json:"start"`
	End   int    `json:"end"`
	Word  string `json:"word"`
}

// deezerLyricsPayload 是一次取词解析出来的全部内容,各项都可能为空。
type deezerLyricsPayload struct {
	lrc, plain, yrc, tr string
	songwriters         []string
}

const (
	// deezerWordTrackMaxOffsetMs / deezerWordTrackMinAgreement:逐字轨的一行在这么多毫秒内
	// 能找到文字相近的逐行,算它俩对得上;对得上的行要占到这个比例才用逐字轨。
	deezerWordTrackMaxOffsetMs  = 1500
	deezerWordTrackMinAgreement = 0.8
)

// deezerAcceptLanguage 取词请求的 Accept-Language,决定 lineTranslated 用什么语言。
func deezerAcceptLanguage() string {
	return myMemoryLangCode(features().LyricsTranslationLanguage)
}

// deezerBuildYRC 把逐字轨拼成 YRC:`[行始,行长](词始,词长,0)词 …`,词之间的空格挂在前一个词末尾。
// 没有词、时间倒挂的行跳过。纯函数,便于单测。
func deezerBuildYRC(lines []deezerWordLine) string {
	var b strings.Builder
	for _, l := range lines {
		var words []deezerWord
		for _, w := range l.Words {
			if strings.TrimSpace(w.Word) == "" || w.End < w.Start {
				continue
			}
			words = append(words, w)
		}
		if len(words) == 0 || l.End < l.Start {
			continue
		}
		fmt.Fprintf(&b, "[%d,%d]", l.Start, l.End-l.Start)
		for i, w := range words {
			text := strings.TrimSpace(w.Word)
			if i < len(words)-1 {
				text += " "
			}
			fmt.Fprintf(&b, "(%d,%d,0)%s", w.Start, w.End-w.Start, text)
		}
		b.WriteString("\n")
	}
	return strings.TrimSuffix(b.String(), "\n")
}

// deezerTextKey 是逐字行与逐行比对文字用的归一形:只留字母和数字、转小写。
func deezerTextKey(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func (w deezerWordLine) text() string {
	parts := make([]string, 0, len(w.Words))
	for _, x := range w.Words {
		parts = append(parts, x.Word)
	}
	return strings.Join(parts, " ")
}

// deezerMatchSyncLine 给一行逐字找对应的逐行:deezerWordTrackMaxOffsetMs 内、文字归一后互相
// 包含的第一行,skip 为真的行不算。找不到返回 -1。
func deezerMatchSyncLine(w deezerWordLine, lines []deezerSyncLine, skip func(int) bool) int {
	t := deezerTextKey(w.text())
	if t == "" {
		return -1
	}
	for i, l := range lines {
		if skip != nil && skip(i) {
			continue
		}
		r := deezerTextKey(l.Line)
		if r == "" {
			continue
		}
		d := l.Milliseconds - w.Start
		if d < 0 {
			d = -d
		}
		if d <= deezerWordTrackMaxOffsetMs && (strings.Contains(r, t) || strings.Contains(t, r)) {
			return i
		}
	}
	return -1
}

// deezerWordTrackAgrees 判逐字轨能不能用:它跟逐行轨是两份独立的时间轴,多数只差几百毫秒,
// 但偶尔整份错位(行序对、时刻全乱,或中段越走越偏)。逐字轨里能用 deezerMatchSyncLine
// 找到对应逐行的行,要占到 deezerWordTrackMinAgreement 才用。纯函数,便于单测。
func deezerWordTrackAgrees(words []deezerWordLine, lines []deezerSyncLine) bool {
	if len(words) == 0 {
		return false
	}
	agree := 0
	for _, w := range words {
		if deezerMatchSyncLine(w, lines, nil) >= 0 {
			agree++
		}
	}
	return float64(agree) >= float64(len(words))*deezerWordTrackMinAgreement
}

// deezerBuildTranslation 把 lineTranslated 拼成译文 LRC。words 非空(逐字轨已通过
// deezerWordTrackAgrees)时,每句译文挂到对应逐字行的起点、每句只挂一次 —— 界面显示的是
// 逐字轨的行,译文按时间就近配行,挂在逐行轨的时刻上会差出几百毫秒、配不上;words 为空时
// 用逐行轨的时间戳。译文跟原文一样的行(人名、拟声词)不收;整份的主要文字系统跟目标语言
// 对不上时整份不要(deezerTranslationFitsLanguage)。纯函数,便于单测。
func deezerBuildTranslation(lines []deezerSyncLine, words []deezerWordLine, target string) string {
	translated := func(l deezerSyncLine) string {
		text := strings.TrimSpace(l.Line)
		tr := strings.TrimSpace(l.LineTranslated)
		if text == "" || tr == "" || strings.EqualFold(tr, text) {
			return ""
		}
		return tr
	}
	var b, all strings.Builder
	emit := func(ts, tr string) {
		b.WriteString(ts)
		b.WriteString(tr)
		b.WriteString("\n")
		all.WriteString(tr)
		all.WriteString("\n")
	}
	if len(words) > 0 {
		used := make([]bool, len(lines))
		for _, w := range words {
			i := deezerMatchSyncLine(w, lines, func(i int) bool { return used[i] })
			if i < 0 {
				continue
			}
			used[i] = true
			if tr := translated(lines[i]); tr != "" {
				emit(formatLRCTime(w.Start), tr)
			}
		}
	} else {
		for _, l := range lines {
			ts := strings.TrimSpace(l.LRCTimestamp)
			if tr := translated(l); ts != "" && tr != "" {
				emit(ts, tr)
			}
		}
	}
	if b.Len() == 0 || !deezerTranslationFitsLanguage(all.String(), target) {
		return ""
	}
	return b.String()
}

// deezerTranslationFitsLanguage:译文的主要文字系统是不是目标语言会用的那几套
// (targetScripts)。挡的是「目标是中文、Deezer 没有中文就退回英文」这一类;目标本身是
// 拉丁字母语言时,退回的英文分辨不出来。
func deezerTranslationFitsLanguage(tr, target string) bool {
	s := dominantScript(tr)
	for _, t := range targetScripts(target) {
		if s == t {
			return true
		}
	}
	return false
}

// deezerBuildLRC 把 synchronizedLines 拼成逐行 LRC。只认**同时**有时间戳和正文的行:
// Deezer 用空 line 表示间奏,原样拼进去会变成一堆空行,拉低 lines 这一项的打分、还会在
// 歌词面上留白。纯函数,便于单测。
func deezerBuildLRC(lines []deezerSyncLine) string {
	var b strings.Builder
	for _, l := range lines {
		ts := strings.TrimSpace(l.LRCTimestamp)
		text := strings.TrimSpace(l.Line)
		if ts == "" || text == "" {
			continue
		}
		b.WriteString(ts)
		b.WriteString(text)
		b.WriteString("\n")
	}
	return b.String()
}

// deezerIsLyricsNotFound 认 GraphQL 的"这首歌没有歌词"错误。实测原文:
// {"message":"Lyrics does not exists","type":"LyricsNotFoundError",…}。这是**正常结果**
// 不是失败 —— 调用方据此安静返回空,不记失败原因、不惊动熔断。纯函数,便于单测。
func deezerIsLyricsNotFound(errs string) bool {
	return strings.Contains(errs, "LyricsNotFoundError") || strings.Contains(errs, "Lyrics does not exists")
}

// deezerFetchLyrics 取一首歌的歌词,各项都可能为空(见 deezerLyricsPayload)。请求头按译文语言带(deezerAcceptLanguage)。
func deezerFetchLyrics(ctx context.Context, trackID string) (deezerLyricsPayload, error) {
	data, errs, err := deezerPipeQuery(ctx, "SynchronizedTrackLyrics", deezerLyricsQuery, map[string]any{"trackId": trackID}, deezerAcceptLanguage())
	if err != nil {
		return deezerLyricsPayload{}, err
	}
	if deezerHasError(errs) {
		if deezerIsLyricsNotFound(string(errs)) {
			// 正常结果:这首歌 Deezer 没有词。安静返回空。
			return deezerLyricsPayload{}, nil
		}
		return deezerLyricsPayload{}, fmt.Errorf("graphql error %s", strings.TrimSpace(string(errs)))
	}
	var out struct {
		Track struct {
			Lyrics struct {
				Text                        string           `json:"text"`
				Writers                     string           `json:"writers"`
				SynchronizedLines           []deezerSyncLine `json:"synchronizedLines"`
				SynchronizedWordByWordLines []deezerWordLine `json:"synchronizedWordByWordLines"`
			} `json:"lyrics"`
		} `json:"track"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return deezerLyricsPayload{}, err
	}
	ly := out.Track.Lyrics
	var words []deezerWordLine
	if deezerWordTrackAgrees(ly.SynchronizedWordByWordLines, ly.SynchronizedLines) {
		words = ly.SynchronizedWordByWordLines
	}
	return deezerLyricsPayload{
		lrc:   deezerBuildLRC(ly.SynchronizedLines),
		plain: strings.TrimSpace(ly.Text),
		yrc:   deezerBuildYRC(words),
		tr:    deezerBuildTranslation(ly.SynchronizedLines, words, features().LyricsTranslationLanguage),

		songwriters: deezerSongwriters(ly.Writers),
	}, nil
}

// resolveDeezerLyric:①搜索(单次请求,10 条;GraphQL 没问成才退回公开 API);②身份闸 + 时长闸淘汰、
// 按分数稳定排序;③取前几条**并发**取词 —— 搜索明确说没有同步歌词的不在其列;④按名次(不是"谁先拉完")
// 挑第一份真同步的;⑤一份同步的都没有时,退而求其次挑第一份纯文本(plainOnly,分数恒 -1,只有用户手点才会
// 采用)——理由同 lrclib/musixmatch 那两路的纯文本回退:有词可看胜过没有,但绝不让它自动顶掉别的源。
// 候选里全是「没有同步歌词」的,只取分数最高那条、为的是它的纯文本。
func resolveDeezerLyric(ctx context.Context, artist, title, album string, durationSecs float64, isrc string) deezerResult {
	type scoredTrack struct {
		track         deezerTrack
		score         int
		known, noSync bool
	}
	var candidates []scoredTrack

	// ISRC 直取:拿到的是**这条录音本身**,不是搜出来最像的那条。
	//
	// 这条候选**故意不过 deezerCandidateScore**。Deezer 对同一条录音给的常是本地化
	// 标题——实测 USCA20801738(Katy Perry《I Kissed A Girl》原版)回的是日文
	// 「キス・ア・ガール」,拿去过名称闸会被自己淘汰掉。而名称闸要防的事(串到同名的
	// 另一首/另一版录音)在这里根本不成立:ISRC 就是录音级身份。
	//
	// 对照实测:同一首歌按名字搜,第一条是 251 秒的 Live 日文版;按 ISRC 直取是 180 秒的原版。
	//
	// 但**时长闸仍然要过**。ISRC 理论上是录音身份,现实里却存在垃圾值:实测
	// "ZZZZZ9999999"(一眼占位符)在 Deezer 和 Musixmatch 上**都查得到歌**,各自是一首
	// 完全不相干的曲子。名称对不上可能只是本地化写法,时长差一大截就说明拿到的根本不是
	// 这首 —— 这是唯一一道对"ISRC 本身是脏数据"还有效的防线。
	if isrc != "" {
		if t, ok := deezerTrackByISRC(ctx, isrc); ok && sourceDurationFits(durationSecs, float64(t.Duration)) {
			candidates = append(candidates, scoredTrack{track: t, score: deezerISRCDirectScore})
		}
	}

	if len(candidates) == 0 {
		hits, err := deezerGraphQLSearch(ctx, artist, title)
		if err != nil {
			hits, err = deezerPublicSearchHits(ctx, artist, title)
		}
		if err != nil || len(hits) == 0 {
			return deezerResult{}
		}
		for _, h := range hits {
			if s := deezerCandidateScore(h.track, artist, title, album, durationSecs); s >= 0 {
				candidates = append(candidates, scoredTrack{track: h.track, score: s, known: h.known, noSync: h.noSync})
			}
		}
	}
	if len(candidates) == 0 {
		return deezerResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	fetch := make([]scoredTrack, 0, deezerMaxCandidatesToFetch)
	for _, c := range candidates {
		if !c.noSync && len(fetch) < deezerMaxCandidatesToFetch {
			fetch = append(fetch, c)
		}
	}
	if len(fetch) == 0 {
		fetch = candidates[:1]
	}
	candidates = fetch

	got := make([]deezerLyricsPayload, len(candidates))
	fetchAt := func(rank int) {
		p, err := deezerFetchLyrics(ctx, strconv.FormatInt(candidates[rank].track.ID, 10))
		if err != nil {
			return
		}
		if !isTimedLRC(p.lrc) {
			p = deezerLyricsPayload{plain: p.plain, songwriters: p.songwriters}
		}
		got[rank] = p
	}
	if candidates[0].known {
		// 搜索已经说了哪几条有同步歌词:按名次逐条取,取到就停。几条一起取是给「不知道哪条有词」的公开搜索用的,
		// 这里照搬只会多打请求(实测同一批 40 首 71 对 90 个请求,找到的一首不差)。
		for rank := range candidates {
			fetchAt(rank)
			if got[rank].lrc != "" {
				break
			}
		}
	} else {
		var wg sync.WaitGroup
		for i := range candidates {
			wg.Add(1)
			go func(rank int) {
				defer wg.Done()
				fetchAt(rank)
			}(i)
		}
		wg.Wait()
	}

	build := func(rank int, lyrics string, plainOnly bool) deezerResult {
		t := candidates[rank].track
		return deezerResult{
			lyrics: lyrics, title: t.Title, artist: t.Artist.Name, album: t.Album.Title,
			cover: t.cover(), durationSecs: float64(t.Duration), plainOnly: plainOnly, isrc: t.ISRC,
		}
	}
	for rank, f := range got {
		if f.lrc != "" {
			r := build(rank, f.lrc, false)
			r.yrc, r.tr, r.songwriters = f.yrc, f.tr, f.songwriters
			return r
		}
	}
	for rank, f := range got {
		if f.plain != "" {
			r := build(rank, f.plain, true)
			r.songwriters = f.songwriters
			return r
		}
	}
	return deezerResult{}
}
