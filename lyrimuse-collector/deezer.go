// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// deezerLyric 是歌词第十个候选来源(Deezer,2026-09-13 加)。跟 lyricfind(ytmusic.go)
// **数据同源**:Deezer 的歌词由 LyricFind 供词、时间轴由 Deezer 自己做——接这一路的
// 意义有两层:① 给 LyricFind 这家版权方补第二条管道(现在 lyricfind 只有 YouTube Music
// 一条路,YTM 一改版或在某地区不可用,这家的数据就整体拿不到);② Deezer 是法国公司,
// 法语曲库的覆盖比现有九源都好——接入实测见下。
//
// 两段式(2026-09-13 逐段实测):
//
//	① 搜索走**公开** api.deezer.com/search —— 不需要认证,返回的 track 对象自带
//	   id / title / title_version / duration / isrc / artist.name / album.title /
//	   album.cover_xl(1000x1000)。字段是实测 dump 出来的,不是照文档猜的。
//	② 取词走 **pipe.deezer.com 的 GraphQL**,认证用 auth.deezer.com/login/anonymous
//	   换来的**匿名 JWT**(不需要账号、不需要 ARL、不碰用户登录态)。JWT 自带 exp,
//	   实测有效期约 8 小时,进程级缓存 + 单飞锁(同 musixmatch token / ytmusic visitor id)。
//	   响应 data.track.lyrics 里 synchronizedLines[] 是逐行(lrcTimestamp 形如
//	   "[00:01.41]" + line),text 是整份纯文本。
//
// ⚠️ **别再走 gw-light.php 的 song.getLyrics —— 那条路已经废了**(2026-09-13 实测坐实,
// 这个源最初就是按它写的,错了一版)。它对**任何**歌都回
// `{"DATA_ERROR":"No lyrics id for <id> and country XX"}`,错误文案里的国家极具误导性
// ——第一眼会读成"这个国家没有歌词授权"。对照实验推翻了这个解读:换出口到 US 之后,
// 同一首歌照样回 "No lyrics id ... and country US";直接查 song.getData 更是一目了然:
// **LYRICS_ID 字段对所有歌恒为 0**,连 Adele《Hello》、Stromae《Alors on danse》这种
// 铁定有词的也是 0。也就是说那句话是字面意思——它在旧数据模型里找 lyrics id,而那个
// 字段已经不再被填充,跟国家、跟登录与否都无关。公开实现 syncedlyrics 的 deezer provider
// 至今标着 "Currently broken"、把病因归到 CSRF token,同样是被这条路带偏了。
//
// 实测覆盖(2026-09-13,匿名 JWT):Joseph Kamel《Crash》64 行、Zaho de Sagazan
// 《Les dormantes》60 行、Hervé《Si bien du mal》22 行、Stromae《Alors on danse》61 行、
// Aya Nakamura《Djadja》52 行、Adele《Hello》44 行 —— 前三首正是接入前"九源里只有
// lrclib/netease 给得出低分候选"的法语小众歌。周杰伦《稻香》只有 584 字纯文本、没有
// 逐行(走 plainOnly 通道);Jungeli《Juste un peu》、Suzane《SLT》回
// LyricsNotFoundError(真没收录,不是失败)。
//
// ⚠️ **它跟 lyricfind 不是两个独立信源**(正文层面)。两条管道的接口、曲库、匹配、故障面
// 都各走各的,时间轴也不同源(Deezer 的同步是它自己做的,LyricFind 只供词)——但**正文**
// 出自同一家。打分层的"跨源正文共识"按独立信源数给分,所以必须按**供词方**归组而不是按
// 源名:见 match.go 的 lyricSourceConsensusFamily(deezer 与 lyricfind 归同一家)。不归组的
// 后果有两个:两条管道互相印证各拿一份加分、第三方误以为有两家印证拿 +250。这条纪律
// ytmusic.go 顶部早就写下了,2026-09-13 接这个源时从另一个方向又踩了一次。
//
// 只有逐行,没有逐字/译文/罗马音。搜索排序可信(原版排第一、acoustic 版排第二,实测),
// 所以跟 migu 一样不重排,只套跟别的源完全一致的身份闸;但 Deezer 的搜索结果**自带时长**,
// 比 migu 多一道时长闸和时长加分(口径与 kuwo 一致,容差 0.25)。
//
// 合规提醒:①搜索用的是 Deezer 公开 API;②auth/pipe 两个端点是网页客户端接口、非公开
// 文档,跟 kuwo.go / migu.go / musixmatch.go 同一类风险(可能随时失效或要求验证码),
// 不是新引入一种风险类别。全程匿名,不碰用户账号、不需要登录。
type deezerResult struct {
	lyrics, title, artist, album string
	// cover:album.cover_xl(1000x1000),搜索结果自带,不用多发请求。拿不到就留空,
	// 交给 enrich.go 的 coverOrFallback 退到 Apple 封面。
	cover string
	// durationSecs:Deezer 自报的曲长(秒),透传给打分的 sourceReportedDurationSecs。
	durationSecs float64
	// plainOnly:只拿到整份纯文本、没有 synchronizedLines —— 语义与取舍完全等同
	// lrclibResult.plainOnly,见那边的头注(分数钉死 -1,只有用户在弹窗里手点才会采用)。
	plainOnly bool
}

func (r deezerResult) empty() bool { return r.lyrics == "" }

const (
	deezerSearchAPI = "https://api.deezer.com/search"
	deezerAuthAPI   = "https://auth.deezer.com/login/anonymous?jo=p&rto=c&i=c"
	deezerPipeAPI   = "https://pipe.deezer.com/api"
	// deezerScoreDurationTolerance 跟别的源的时长闸门(match.go 的 0.25)取同一个值。
	deezerScoreDurationTolerance = 0.25
	// deezerMaxCandidatesToFetch:通过身份闸后最多拉几条歌词。Deezer 排序可信、原版通常
	// 就是第一条,3 条足够覆盖"第一条恰好没词"的情况——理由同 migu,不必像 kuwo 拉 5 条。
	deezerMaxCandidatesToFetch = 3
	deezerHTTPTimeout          = 6 * time.Second
	// deezerJWTFallbackTTL:JWT 里解不出 exp 时的保守有效期。实测 exp 给的是 ~8 小时,
	// 这里只在解析失败时兜底,宁可多换几次也不要拿着过期的票反复被拒。
	deezerJWTFallbackTTL = time.Hour
	// deezerJWTRenewMargin:提前这么久就当它过期,免得卡在边界上换票。
	deezerJWTRenewMargin = 5 * time.Minute
)

// deezerLyricsQuery 是取词用的 GraphQL 查询。只要这一路真正用得上的字段:逐行
// (synchronizedLines)和整份纯文本(text)。不取 writers/copyright —— 那是署名信息,
// 这个项目的下游不消费,多取一份只是白传。
const deezerLyricsQuery = `query SynchronizedTrackLyrics($trackId: String!) {
  track(trackId: $trackId) {
    id
    lyrics {
      id
      text
      synchronizedLines {
        lrcTimestamp
        line
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
// 一次识别出的具体失败原因,识别不出就是空串。⚠️ 目前**只有一种**已实测的失败模式:
// 匿名 JWT 换不到(auth 端点不答或改了形状)。"这首歌没有歌词"(LyricsNotFoundError)
// 不算失败,不往这里记 —— 那是正常结果,报上去会让用户以为源坏了。
func deezerLastFailureReasonNow() string {
	deezerLastFailMu.Lock()
	defer deezerLastFailMu.Unlock()
	return deezerLastFailure
}

func deezerLyric(ctx context.Context, artist, title, album string, durationSecs float64) deezerResult {
	if title == "" {
		return deezerResult{}
	}
	key := artist + "|" + title + "|" + album
	deezerMu.Lock()
	if v, ok := deezerCache[key]; ok {
		deezerMu.Unlock()
		return v
	}
	deezerMu.Unlock()

	r := resolveDeezerLyric(ctx, artist, title, album, durationSecs)
	if !r.empty() {
		deezerMu.Lock()
		deezerCache[key] = r
		deezerMu.Unlock()
	}
	return r
}

// deezerTrack 只挑这一路真正用得上的字段,字段名与 2026-09-13 实测 dump 的一致。
type deezerTrack struct {
	ID           int64  `json:"id"`
	Title        string `json:"title"`
	TitleVersion string `json:"title_version"` // "(Version acoustique)" 这类版本后缀,已含在 Title 里
	Duration     int    `json:"duration"`      // 秒
	Artist       struct {
		Name string `json:"name"`
	} `json:"artist"`
	Album struct {
		Title   string `json:"title"`
		CoverXL string `json:"cover_xl"`
		CoverBg string `json:"cover_big"`
	} `json:"album"`
}

func (t deezerTrack) cover() string {
	if u := strings.TrimSpace(t.Album.CoverXL); u != "" {
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
		deezerSetLastFailureReason(lyricFailureReasonDeezerAuthFailed)
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
	return strings.TrimSpace(out.JWT)
}

// deezerSyncLine 是 synchronizedLines 的一个元素(2026-09-13 实测形状)。
type deezerSyncLine struct {
	LRCTimestamp string `json:"lrcTimestamp"` // "[00:01.41]"
	Line         string `json:"line"`
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

// deezerIsLyricsNotFound 认 GraphQL 的"这首歌没有歌词"错误。2026-09-13 实测原文:
// {"message":"Lyrics does not exists","type":"LyricsNotFoundError",…}。这是**正常结果**
// 不是失败 —— 调用方据此安静返回空,不记失败原因、不惊动熔断。纯函数,便于单测。
func deezerIsLyricsNotFound(errs string) bool {
	return strings.Contains(errs, "LyricsNotFoundError") || strings.Contains(errs, "Lyrics does not exists")
}

// deezerFetchLyrics 取一首歌的歌词。返回(逐行 LRC, 纯文本, error)——两者都可能为空。
// JWT 被拒(401)时清掉重换一次,只重试一次。
func deezerFetchLyrics(ctx context.Context, trackID string) (string, string, error) {
	for attempt := 0; attempt < 2; attempt++ {
		jwt := deezerEnsureJWT(ctx)
		if jwt == "" {
			return "", "", fmt.Errorf("no anonymous jwt")
		}
		body, err := json.Marshal(map[string]any{
			"operationName": "SynchronizedTrackLyrics",
			"variables":     map[string]any{"trackId": trackID},
			"query":         deezerLyricsQuery,
		})
		if err != nil {
			return "", "", err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, deezerPipeAPI, strings.NewReader(string(body)))
		if err != nil {
			return "", "", err
		}
		req.Header.Set("User-Agent", "Mozilla/5.0")
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+jwt)
		resp, err := doHTTPTracked(lyricHTTPClient(deezerHTTPTimeout), req)
		if err != nil {
			return "", "", err
		}
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		status := resp.StatusCode
		resp.Body.Close()
		if status == http.StatusUnauthorized && attempt == 0 {
			deezerClearJWT()
			continue
		}
		if status != http.StatusOK {
			return "", "", fmt.Errorf("status %d", status)
		}
		if readErr != nil {
			return "", "", readErr
		}
		var out struct {
			Errors json.RawMessage `json:"errors"`
			Data   struct {
				Track struct {
					Lyrics struct {
						Text              string           `json:"text"`
						SynchronizedLines []deezerSyncLine `json:"synchronizedLines"`
					} `json:"lyrics"`
				} `json:"track"`
			} `json:"data"`
		}
		if err := json.Unmarshal(raw, &out); err != nil {
			return "", "", err
		}
		if deezerHasError(out.Errors) {
			errs := string(out.Errors)
			if deezerIsLyricsNotFound(errs) {
				// 正常结果:这首歌 Deezer 没有词。安静返回空。
				return "", "", nil
			}
			return "", "", fmt.Errorf("graphql error %s", strings.TrimSpace(errs))
		}
		ly := out.Data.Track.Lyrics
		return deezerBuildLRC(ly.SynchronizedLines), strings.TrimSpace(ly.Text), nil
	}
	return "", "", fmt.Errorf("jwt refresh exhausted")
}

// resolveDeezerLyric:①搜索(单次请求,10 条);②身份闸 + 时长闸淘汰、按分数稳定排序;
// ③取前几条**并发**取词;④按名次(不是"谁先拉完")挑第一份真同步的;⑤一份同步的都没有
// 时,退而求其次挑第一份纯文本(plainOnly,分数恒 -1,只有用户手点才会采用)——理由同
// lrclib/musixmatch 那两路的纯文本回退:有词可看胜过没有,但绝不让它自动顶掉别的源。
func resolveDeezerLyric(ctx context.Context, artist, title, album string, durationSecs float64) deezerResult {
	tracks, err := deezerSearch(ctx, artist, title)
	if err != nil || len(tracks) == 0 {
		return deezerResult{}
	}

	type scoredTrack struct {
		track deezerTrack
		score int
	}
	var candidates []scoredTrack
	for _, t := range tracks {
		if s := deezerCandidateScore(t, artist, title, album, durationSecs); s >= 0 {
			candidates = append(candidates, scoredTrack{t, s})
		}
	}
	if len(candidates) == 0 {
		return deezerResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > deezerMaxCandidatesToFetch {
		candidates = candidates[:deezerMaxCandidatesToFetch]
	}

	type fetched struct{ synced, plain string }
	got := make([]fetched, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, t deezerTrack) {
			defer wg.Done()
			synced, plain, err := deezerFetchLyrics(ctx, strconv.FormatInt(t.ID, 10))
			if err != nil {
				return
			}
			if isTimedLRC(synced) {
				got[rank] = fetched{synced: synced}
				return
			}
			got[rank] = fetched{plain: plain}
		}(i, c.track)
	}
	wg.Wait()

	build := func(rank int, lyrics string, plainOnly bool) deezerResult {
		t := candidates[rank].track
		return deezerResult{
			lyrics: lyrics, title: t.Title, artist: t.Artist.Name, album: t.Album.Title,
			cover: t.cover(), durationSecs: float64(t.Duration), plainOnly: plainOnly,
		}
	}
	for rank, f := range got {
		if f.synced != "" {
			return build(rank, f.synced, false)
		}
	}
	for rank, f := range got {
		if f.plain != "" {
			return build(rank, f.plain, true)
		}
	}
	return deezerResult{}
}
