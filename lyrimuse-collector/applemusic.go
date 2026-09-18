// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"math"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// applemusicLyric 是歌词第十一个候选来源(Apple Music 官方)。
//
// 接它的理由跟前十个源都不一样:它不是"再补一家覆盖率"，而是**唯一一家给得出时间轴、
// 却在现有十源之外**的信源。拿用户本机 enrich 缓存做过全量核对:5634 首里
// 158 首十源一个字都取不回来,其中 92 首能对上 Apple catalog id、查到 88 首,
// **18 首 Apple 侧 hasTimeSyncedLyrics=true**(另 15 首只有纯文本、55 首 Apple 也没有,
// 后者多是器乐/现场,本来就不该有词)。也就是说这一路能补上当前缺口的两成(按带时间轴
// 口径)到三成七(含纯文本)。触发这次接入的 ALOISIO《BESO DE ESOS》就在这 18 首里。
//
// 为什么其余候选源一个都没接:逐个实测过。Musixmatch 对这类歌
// has_subtitles=0(有词无时间轴),而 Spotify / Tidal / Amazon 的歌词后端都是 Musixmatch,
// 一并出局;Yandex 在本地网络回 451(区域封锁);韩国 Bugs 零命中;人工 LRC 站
// (Megalobiz / Lyricsify)对一个月内的小众新歌没有收录;Genius 只有纯文本,而纯文本
// Musixmatch 已经给了,增量为零。
//
// 两段式:
//
//	① 搜索走 amp-api 的 catalog search,**只需要 developer token**(见
//	   applemusicEnsureDeveloperToken:从 music.apple.com 的 JS bundle 里抓,不要钱、
//	   不要账号)。返回的 song attributes 自带 hasLyrics / hasTimeSyncedLyrics /
//	   durationInMillis / artwork —— 其中那两个布尔是**这一路独有的便宜信号**:没有
//	   时间轴的歌可以在取词之前就判掉,不白跑一个往返(同 musixmatch.go 那道
//	   has_subtitles 闸)。
//	② 取词走 /songs/{id}/syllable-lyrics(逐字)与 /songs/{id}/lyrics(逐行),**必须**
//	   带 media-user-token —— 这是订阅用户的登录令牌,由 lyrimuse 设置里的"连接
//	   Apple Music"窗口登录一次拿到(见 applemusicUserTokenPath)。没有它这两个端点
//	   返回 404 "No related resources"(不是 401,别被这个状态码带偏:实测,
//	   同一个 id 不带 user token 回 404、带上就有数据)。
//
// ⚠️ **不要试图走官方 MusicKit 框架**。MusicKit 需要
// com.apple.developer.musickit entitlement,而它只发给 Apple Developer Program 成员的
// 正式证书;lyrimuse 是自签名(build.sh 的 "Lyrimuse Dev Signing"),强行把这条
// entitlement 签进去的结果是**进程被 amfid 直接 SIGKILL**(退出码 137),连跑都跑不起来。
// 不带 entitlement 时 MusicAuthorization.currentStatus 虽然是 .authorized,但任何
// MusicDataRequest / MusicCatalogResourceRequest 一律 .permissionDenied —— 连最普通的
// catalog 查询都拒,不是歌词端点特殊。同理,Music.app 本机也提取不到任何东西:歌词不落盘
// (MusicCatalogData.db 的 catalog_song 表 0 行、fsCachedData 里没有 TTML)、AppleScript
// 的 `lyrics` 属性对流媒体曲目(class=URL track)恒为空串、凭据由 itunescloudd 在内存里
// 管(钥匙串里 music/itunes 相关条目零条)。开源社区(librelyrics-applemusic / Manzana /
// Music Assistant)清一色走 cookie 取 media-user-token,没有第二条路。
//
// 令牌的寿命是这一路唯一需要用户操心的事:media-user-token **固定 6 个月、不可续期**
// (Apple 不发 refresh token,到期只能重登一次)。过期表现为取词端点回 401/403,
// 这时把失败原因记成 applemusicTokenRejected,让 UI 能提示"重新连接"。
//
// 解析直接复用 amllttml.go 的 parseAMLLTTML —— AMLL 的 TTML 方言本来就是照着 Apple 这份
// 抄的,连 ttm:agent 对唱标注都一样,没必要写第二个解析器。逐字(syllable)与逐行(lyrics)
// 是两个端点、同一种文档结构,差别只在 <span> 有没有再分词。
type applemusicResult struct {
	lyrics, yrc, tr, title, artist, album string
	// cover:artwork.url 是个带 {w}x{h} 占位的模板,取词时替换成 1000x1000。
	cover string
	// durationSecs:Apple 自报的曲长(秒),透传给打分的 sourceReportedDurationSecs。
	durationSecs float64
	// plainOnly:只拿到没有时间戳的正文 —— 语义同 deezer/lrclib 的同名字段(分数钉死 -1,
	// 只有用户在弹窗里手点才会采用)。
	plainOnly bool
}

func (r applemusicResult) empty() bool { return r.lyrics == "" && r.yrc == "" }

const (
	applemusicAMPBase = "https://amp-api.music.apple.com/v1/catalog/"
	// applemusicWebOrigin:amp-api 校验 Origin,不带就 403。值必须是 Apple 自己的站点。
	applemusicWebOrigin = "https://music.apple.com"
	applemusicBrowseURL = "https://music.apple.com/us/browse"
	// applemusicMeStorefrontURL:账号所在区的权威来源。注意它不在 /v1/catalog/ 下,
	// 所以不能走 applemusicAPIGet。
	applemusicMeStorefrontURL = "https://amp-api.music.apple.com/v1/me/storefront"
	applemusicHTTPTimeout     = 8 * time.Second
	// applemusicScoreDurationTolerance 跟别的源的时长闸门(match.go 的 0.25)取同一个值。
	applemusicScoreDurationTolerance = 0.25
	// applemusicMaxCandidatesToFetch:通过身份闸后最多拉几条。Apple 的 catalog search
	// 排序非常可信(原版几乎总是第一条,实测),3 条足够覆盖"第一条恰好没词"——理由同 deezer。
	applemusicMaxCandidatesToFetch = 3
	// applemusicDevTokenRenewMargin:提前这么久就当 developer token 过期。实测它的有效期
	// 是 70 天量级,留一天余量绰绰有余。
	applemusicDevTokenRenewMargin = 24 * time.Hour
)

var (
	applemusicMu    sync.Mutex
	applemusicCache = map[string]applemusicResult{}

	// 单飞锁,理由同 musixmatch/deezer:相册预取一次能触发十几首歌并发解析,各自去抓一次
	// JS bundle(3MB)是纯浪费。
	applemusicDevTokenMu      sync.Mutex
	applemusicDevToken        string
	applemusicDevTokenExpires time.Time
	applemusicDevTokenFetchMu sync.Mutex

	applemusicLastFailMu  sync.Mutex
	applemusicLastFailure string
)

func applemusicSetLastFailureReason(reason string) {
	applemusicLastFailMu.Lock()
	applemusicLastFailure = reason
	applemusicLastFailMu.Unlock()
}

// applemusicLastFailureReasonNow 供 search-lyrics / test-lyric-sources 用。
// ⚠️ 最常见的"失败"其实是**用户压根没连过 Apple Music**(applemusic_not_connected),
// 它跟源坏了不是一回事 —— UI 侧据此提示"去设置里连接",不要报成源故障。
func applemusicLastFailureReasonNow() string {
	applemusicLastFailMu.Lock()
	defer applemusicLastFailMu.Unlock()
	return applemusicLastFailure
}

// ---- 凭据 ----

// applemusicUserTokenPath 是 media-user-token 的落点。写入方是 lyrimuse 设置里的
// "连接 Apple Music"窗口(AppleMusicLoginWindow.swift),collector 只读。
//
// ⚠️ 这是用户 Apple Music 账号的访问凭据,跟 musixmatch token 一样只待在本机配置目录,
// 不进仓库、不上传、不写日志(下面任何一处都不打印它的值,只打印长度)。
func applemusicUserTokenPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-applemusic-token.json")
}

type applemusicUserTokenFile struct {
	MediaUserToken string `json:"media_user_token"`
	Storefront     string `json:"storefront"`
	SavedAt        int64  `json:"saved_at"`
}

// applemusicLoadUserToken 读用户令牌与 storefront。不发网络请求。
// storefront 读不出来时返回**空串**,调用方必须自己去 applemusicEnsureStorefront 问清楚。
//
// ⚠️ 这里以前会在拿不到时退到 "us",那是个会导致整源静默全灭的设计。
// storefront 不只决定"查哪个区的曲库",它同时决定**取词那一趟的鉴权**:Apple 校验的是
// URL 里的 storefront 段 == 用户订阅的区,跟歌属于哪个区无关。实测同一个 id 同一个令牌,
// cn 路径 200、us/gb/es/jp/de 路径一律 404(对照组用各区都有的大热门,排除了"歌本身没有")。
// 所以对一个 cn 订阅用户退到 "us" 的后果不是"少查到几首区域独占曲目",而是**每一次取词
// 都 404**;更糟的是 applemusicFetchTTML 把 404 当正常结果返回 ("", nil),不报错不记原因,
// 表现出来就是"Apple 也没这首歌的词"。宁可判失败让用户看见,也不要猜一个区。
func applemusicLoadUserToken() (string, string) {
	path := applemusicUserTokenPath()
	if path == "" {
		return "", ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	var f applemusicUserTokenFile
	if json.Unmarshal(raw, &f) != nil || strings.TrimSpace(f.MediaUserToken) == "" {
		return "", ""
	}
	return strings.TrimSpace(f.MediaUserToken), strings.ToLower(strings.TrimSpace(f.Storefront))
}

// applemusicEnsureStorefront:令牌文件里没记下 storefront 时,问 Apple 要权威答案并写回。
//
// 为什么需要这条路:登录窗口是从 itua cookie 取 storefront 的,而它跟 media-user-token
// 由 Apple 的登录流程分别写入,未必同时就位;登录侧已经改成等一会儿,但等不到时宁可留空,
// 也不猜。这里用 /v1/me/storefront 收尾 —— 它要 developer token + media-user-token
// 两者(实测:只带 user token 回 401、只带 dev token 回 403),而这两样 collector 都有,
// App 侧没有 developer token 的获取机制,所以这一步只能放在这边。
//
// 写回是为了下次不用再问。拿不到就返回空串,由调用方判失败,**绝不退回某个默认区**。
func applemusicEnsureStorefront(ctx context.Context, userToken, devToken string) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, applemusicMeStorefrontURL, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Authorization", "Bearer "+devToken)
	req.Header.Set("Media-User-Token", userToken)
	req.Header.Set("Origin", applemusicWebOrigin)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(applemusicHTTPTimeout), req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return ""
	}
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusUnauthorized, http.StatusForbidden:
		// 带着 user token 还被拒 = 令牌过期或被吊销,跟取词端点同一个判定。
		applemusicSetLastFailureReason(lyricFailureReasonAppleMusicTokenRejected)
		return ""
	default:
		return ""
	}
	var out struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.Unmarshal(raw, &out) != nil || len(out.Data) == 0 {
		return ""
	}
	sf := strings.ToLower(strings.TrimSpace(out.Data[0].ID))
	if sf == "" {
		return ""
	}
	applemusicSaveStorefront(sf)
	return sf
}

// applemusicSaveStorefront 把问到的 storefront 补写回令牌文件,保留其余字段。
// 失败不算错 —— 大不了下次再问一次,不该因此让这次取词失败。
func applemusicSaveStorefront(storefront string) {
	path := applemusicUserTokenPath()
	if path == "" {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f applemusicUserTokenFile
	if json.Unmarshal(raw, &f) != nil || strings.TrimSpace(f.MediaUserToken) == "" {
		return
	}
	f.Storefront = storefront
	out, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return
	}
	// 0o600:文件里是用户的 Apple Music 访问凭据,权限跟 App 侧写它时保持一致。
	_ = os.WriteFile(path, out, 0o600)
}

// applemusicDevTokenPath:developer token 的磁盘缓存。它是**公开**的(从 Apple 自己的
// 网页 JS 里抓的,每个访问 music.apple.com 的浏览器都拿得到),不是用户凭据,
// 但仍然落盘缓存 —— 理由跟 musixmatchTokenPath 一模一样:一次性的 search-lyrics CLI
// 每次都是新进程,只靠内存缓存等于每次都要下一个 3MB 的 JS bundle。
func applemusicDevTokenPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-applemusic-devtoken.json")
}

type applemusicDevTokenFile struct {
	Token  string `json:"token"`
	Expiry int64  `json:"expiry"`
}

func applemusicLoadDevTokenFile() string {
	path := applemusicDevTokenPath()
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var f applemusicDevTokenFile
	if json.Unmarshal(raw, &f) != nil || f.Token == "" {
		return ""
	}
	if time.Now().Add(applemusicDevTokenRenewMargin).Unix() >= f.Expiry {
		return ""
	}
	applemusicDevTokenMu.Lock()
	applemusicDevToken = f.Token
	applemusicDevTokenExpires = time.Unix(f.Expiry, 0)
	applemusicDevTokenMu.Unlock()
	return f.Token
}

func applemusicSaveDevTokenFile(token string, expiry time.Time) {
	path := applemusicDevTokenPath()
	if path == "" {
		return
	}
	raw, err := json.Marshal(applemusicDevTokenFile{Token: token, Expiry: expiry.Unix()})
	if err != nil {
		return
	}
	// 先写临时文件再 rename,理由同 musixmatchSaveTokenFile。
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if os.WriteFile(tmp, raw, 0o600) != nil {
		return
	}
	if os.Rename(tmp, path) != nil {
		os.Remove(tmp)
	}
}

// applemusicJWTExpiry 从 JWT payload 里读 exp。**不校验签名** —— 我们不是这张票的验证方,
// 只想知道它什么时候该换。纯函数,便于单测。
func applemusicJWTExpiry(jwt string) time.Time {
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

var (
	applemusicJSAssetRe = regexp.MustCompile(`/assets/index~[A-Za-z0-9]+\.js`)
	applemusicJWTRe     = regexp.MustCompile(`eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{50,}\.[A-Za-z0-9_-]{20,}`)
)

// applemusicExtractJWTs 从一段 JS 里挑出所有候选 JWT,按 exp 从晚到早排序、去重、
// 丢掉已过期的。纯函数,便于单测。
//
// 为什么要"所有候选"而不是第一个:实测 music.apple.com 的 bundle 里同时躺着
// 3 个 JWT(kid 各不相同),第一个拿去打 amp-api 回 **401**,第二个才 200 —— 它们是给不同
// 端点/产品线用的,光看形状分不出来,只能挨个试(见 applemusicFetchDeveloperToken)。
func applemusicExtractJWTs(js string) []string {
	seen := map[string]bool{}
	type cand struct {
		tok string
		exp time.Time
	}
	var cands []cand
	now := time.Now()
	for _, m := range applemusicJWTRe.FindAllString(js, -1) {
		if seen[m] {
			continue
		}
		seen[m] = true
		exp := applemusicJWTExpiry(m)
		if exp.IsZero() || exp.Before(now) {
			continue
		}
		cands = append(cands, cand{m, exp})
	}
	sort.SliceStable(cands, func(i, j int) bool { return cands[i].exp.After(cands[j].exp) })
	out := make([]string, 0, len(cands))
	for _, c := range cands {
		out = append(out, c.tok)
	}
	return out
}

// applemusicFetchDeveloperToken 抓一个能用的 developer token:①取 music.apple.com 的
// 首页,找到 index~*.js 的路径;②下载那个 bundle;③抽出所有候选 JWT;④逐个拿一个最轻的
// catalog 请求去验,第一个 200 的就是它。
//
// ④ 这一步不能省:光看 JWT 形状分不出哪个是给 amp-api 用的(见 applemusicExtractJWTs)。
// 验证成本是一次很小的 search 请求,而验过之后这个 token 能用 70 天量级,摊下来可以忽略。
func applemusicFetchDeveloperToken(ctx context.Context) string {
	client := lyricHTTPClient(applemusicHTTPTimeout)

	get := func(u string) (string, bool) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return "", false
		}
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(client, req)
		if err != nil {
			return "", false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", false
		}
		// bundle 有 3MB 量级,给够上限;首页只有几百 KB。
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 12<<20))
		if err != nil {
			return "", false
		}
		return string(raw), true
	}

	home, ok := get(applemusicBrowseURL)
	if !ok {
		return ""
	}
	asset := applemusicJSAssetRe.FindString(home)
	if asset == "" {
		return ""
	}
	js, ok := get(applemusicWebOrigin + asset)
	if !ok {
		return ""
	}
	for _, tok := range applemusicExtractJWTs(js) {
		if applemusicDevTokenWorks(ctx, tok) {
			return tok
		}
	}
	return ""
}

// applemusicDevTokenWorks 用一个最小的 catalog 请求验证 token 能不能打 amp-api。
func applemusicDevTokenWorks(ctx context.Context, devToken string) bool {
	u := applemusicAMPBase + "us/search?types=songs&limit=1&term=a"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return false
	}
	req.Header.Set("Authorization", "Bearer "+devToken)
	req.Header.Set("Origin", applemusicWebOrigin)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(applemusicHTTPTimeout), req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode == http.StatusOK
}

// applemusicEnsureDeveloperToken 拿(并缓存)developer token。内存 → 磁盘 → 网络,
// 单飞锁保证同一时刻只有一个 goroutine 真的去抓 bundle。
func applemusicEnsureDeveloperToken(ctx context.Context) string {
	if tok := applemusicCachedDevToken(); tok != "" {
		return tok
	}
	applemusicDevTokenFetchMu.Lock()
	defer applemusicDevTokenFetchMu.Unlock()
	// 拿到锁之后必须重查一遍:等锁的这段时间里别人可能已经抓好了。
	if tok := applemusicCachedDevToken(); tok != "" {
		return tok
	}
	if tok := applemusicLoadDevTokenFile(); tok != "" {
		return tok
	}
	tok := applemusicFetchDeveloperToken(ctx)
	if tok == "" {
		applemusicSetLastFailureReason(lyricFailureReasonAppleMusicNoDevToken)
		return ""
	}
	exp := applemusicJWTExpiry(tok)
	if exp.IsZero() {
		exp = time.Now().Add(24 * time.Hour)
	}
	applemusicDevTokenMu.Lock()
	applemusicDevToken = tok
	applemusicDevTokenExpires = exp
	applemusicDevTokenMu.Unlock()
	applemusicSaveDevTokenFile(tok, exp)
	return tok
}

func applemusicCachedDevToken() string {
	applemusicDevTokenMu.Lock()
	defer applemusicDevTokenMu.Unlock()
	if applemusicDevToken == "" {
		return ""
	}
	if time.Now().Add(applemusicDevTokenRenewMargin).After(applemusicDevTokenExpires) {
		return ""
	}
	return applemusicDevToken
}

// applemusicClearDevToken 在 401 时把当前 token 作废,下一次 ensure 会重新抓。
func applemusicClearDevToken() {
	applemusicDevTokenMu.Lock()
	applemusicDevToken = ""
	applemusicDevTokenExpires = time.Time{}
	applemusicDevTokenMu.Unlock()
	if p := applemusicDevTokenPath(); p != "" {
		os.Remove(p)
	}
}

// ---- 搜索 ----

// applemusicSong 只挑这一路用得上的字段。
type applemusicSong struct {
	ID         string `json:"id"`
	Attributes struct {
		Name             string `json:"name"`
		ArtistName       string `json:"artistName"`
		AlbumName        string `json:"albumName"`
		DurationInMillis int    `json:"durationInMillis"`
		HasLyrics        bool   `json:"hasLyrics"`
		HasTimeSynced    bool   `json:"hasTimeSyncedLyrics"`
		Artwork          struct {
			URL string `json:"url"`
		} `json:"artwork"`
	} `json:"attributes"`
}

// cover 把 artwork.url 的 {w}x{h} 占位替换成 1000x1000。Apple 给的是模板串,
// 原样用会 404。
func (s applemusicSong) cover() string {
	u := strings.TrimSpace(s.Attributes.Artwork.URL)
	if u == "" {
		return ""
	}
	u = strings.ReplaceAll(u, "{w}", "1000")
	u = strings.ReplaceAll(u, "{h}", "1000")
	u = strings.ReplaceAll(u, "{f}", "jpg")
	// ⚠️ {c} 是裁切/填充代码,Apple 的模板是 `{w}x{h}{c}.{f}` —— 漏掉它,URL 里会留下一个
	// 花括号占位符,整条链接直接 400(实测:同一张图 .../1000x1000{c}.jpg 回 400、
	// .../1000x1000bb.jpg 回 200)。这一路的封面因此从来没成功加载过一次
	// (本机 enrich 缓存里 mzstatic 封面 0 条)。bb = black background padding,
	// 就是 Apple 自家网页在用的那个值。
	u = strings.ReplaceAll(u, "{c}", "bb")
	return u
}

// applemusicAPIGet 发一次 amp-api 请求。devToken 必带;userToken 只在取词时需要
// (搜索不带也能过)。401/403 时把 developer token 作废并重试一次 —— 但**只在没带
// userToken 时**这么判:带了 userToken 的 401/403 更可能是用户令牌过期,重抓 developer
// token 没有意义,直接把原因记成 applemusicTokenRejected 让 UI 去提示重连。
func applemusicAPIGet(ctx context.Context, path, devToken, userToken string) ([]byte, int, error) {
	u := applemusicAMPBase + path
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+devToken)
	req.Header.Set("Origin", applemusicWebOrigin)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	if userToken != "" {
		req.Header.Set("Media-User-Token", userToken)
	}
	resp, err := doHTTPTracked(lyricHTTPClient(applemusicHTTPTimeout), req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return raw, resp.StatusCode, nil
}

// applemusicSearch 搜候选。只需要 developer token。
func applemusicSearch(ctx context.Context, storefront, artist, title, devToken string) ([]applemusicSong, error) {
	q := strings.TrimSpace(artist + " " + title)
	path := neturl.PathEscape(storefront) + "/search?types=songs&limit=10&term=" + neturl.QueryEscape(q)
	raw, status, err := applemusicAPIGet(ctx, path, devToken, "")
	if err != nil {
		return nil, err
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		// developer token 失效(Apple 轮换了 bundle 里的那张票),作废重来一次。
		applemusicClearDevToken()
		newTok := applemusicEnsureDeveloperToken(ctx)
		if newTok == "" || newTok == devToken {
			return nil, fmt.Errorf("developer token rejected (status %d)", status)
		}
		raw, status, err = applemusicAPIGet(ctx, path, newTok, "")
		if err != nil {
			return nil, err
		}
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("status %d", status)
	}
	var out struct {
		Results struct {
			Songs struct {
				Data []applemusicSong `json:"data"`
			} `json:"songs"`
		} `json:"results"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out.Results.Songs.Data, nil
}

// applemusicCandidateScore 给一条搜索结果打分:负数 = 淘汰。身份闸用跟别的源完全一致的
// 判定函数,不为这一个源另起一套更松的规则;时长闸与加分的口径跟 deezer/kuwo 一致。
//
// 比别的源多一道**便宜闸**:hasLyrics=false 的直接淘汰 —— Apple 在搜索结果里就告诉了
// 我们有没有词,不必等到取词那一趟才发现是空的。注意**不**在这里要求 hasTimeSynced:
// 只有纯文本的歌仍然值得取回来走 plainOnly 通道(跟 musixmatch 那道 has_subtitles 闸的
// 取舍一致 —— 那边 2026 年就踩过"因为没时间轴就整首丢掉"的坑)。纯函数,便于单测。
func applemusicCandidateScore(s applemusicSong, artist, title, album string, durationSecs float64) int {
	if strings.TrimSpace(s.ID) == "" {
		return -1
	}
	a := s.Attributes
	if !a.HasLyrics {
		return -1
	}
	if !lyricTitleAccepted(a.Name, title) {
		return -1
	}
	if !lyricSourceArtistMatches(a.ArtistName, artist) {
		return -1
	}
	if versionTagsMismatch(title, album, a.Name, a.AlbumName) {
		return -1
	}
	score := 100
	// 有时间轴的优先 —— 同分时先取它,省得挑到只有纯文本的那条。
	if a.HasTimeSynced {
		score += 200
	}
	if durationSecs > 0 {
		d := float64(a.DurationInMillis) / 1000
		if d <= 0 {
			return score // 时长未知,没法比对,不加不扣
		}
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > applemusicScoreDurationTolerance {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// ---- 取词 ----

// applemusicLyricsPayload 是 /lyrics 与 /syllable-lyrics 的共同响应形状:
// data[0].attributes.ttml 是一整份 TTML 文档。
type applemusicLyricsPayload struct {
	Data []struct {
		Attributes struct {
			TTML string `json:"ttml"`
		} `json:"attributes"`
	} `json:"data"`
}

// applemusicFetchTTML 取一首歌的一种歌词。kind 是 "syllable-lyrics"(逐字)或
// "lyrics"(逐行)。
//
// 三种返回:
//   - (ttml, nil)           拿到了
//   - ("", nil)             这首歌没有这一种歌词 —— **正常结果**,不记失败原因。
//     Apple 对此回 404 + code 40403 "No related resources",而不是 401;
//     没带 user token 时也是同一个 404,所以调用方必须先自己确认 token 在手,
//     不能靠状态码区分这两件事。
//   - ("", err)             真失败(网络/令牌被拒)
func applemusicFetchTTML(ctx context.Context, storefront, songID, kind, devToken, userToken string) (string, error) {
	path := neturl.PathEscape(storefront) + "/songs/" + neturl.PathEscape(songID) + "/" + kind
	raw, status, err := applemusicAPIGet(ctx, path, devToken, userToken)
	if err != nil {
		return "", err
	}
	switch status {
	case http.StatusOK:
	case http.StatusNotFound:
		// 这首歌没有这一种歌词。正常结果。
		return "", nil
	case http.StatusUnauthorized, http.StatusForbidden:
		// 带着 user token 还被拒 —— 令牌过期(6 个月硬上限)或被吊销,要用户重连。
		applemusicSetLastFailureReason(lyricFailureReasonAppleMusicTokenRejected)
		return "", fmt.Errorf("media-user-token rejected (status %d)", status)
	default:
		return "", fmt.Errorf("status %d", status)
	}
	var out applemusicLyricsPayload
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	if len(out.Data) == 0 {
		return "", nil
	}
	return out.Data[0].Attributes.TTML, nil
}

// applemusicParseTTML 把一份 Apple TTML 解析成我们的三件套。直接复用 amllttml.go 的
// 解析器 —— AMLL 的方言就是照着这份抄的(连 ttm:agent 对唱标注都一样)。
func applemusicParseTTML(ttml string) (lrc, yrc, tr string, ok bool) {
	if strings.TrimSpace(ttml) == "" {
		return "", "", "", false
	}
	r, ok := parseAMLLTTML(ttml)
	if !ok {
		return "", "", "", false
	}
	tr = r.tr
	if tr == "" {
		// Apple 把译文放在 <iTunesMetadata><translations> 里,parseAMLLTTML 认的是 AMLL 那套
		// ttm:role="x-translation" 形状,看不到它。见 applemusicSubtitleTranslation。
		tr = applemusicSubtitleTranslation(ttml)
	}
	return r.lrc, r.yrc, tr, true
}

var (
	// <translation type="subtitle" xml:lang="zh-Hans">…</translation>
	amSubtitleBlockRe = regexp.MustCompile(`(?s)<translation\b[^>]*\btype="subtitle"[^>]*>(.*?)</translation>`)
	// <text for="L12">…</text>
	amTextForRe = regexp.MustCompile(`(?s)<text\b[^>]*\bfor="([^"]+)"[^>]*>(.*?)</text>`)
	// 主体的 <p begin="13.429" … itunes:key="L1" …>
	amPTagRe      = regexp.MustCompile(`<p\b([^>]*)>`)
	amAttrBeginRe = regexp.MustCompile(`\bbegin="([^"]+)"`)
	amAttrKeyRe   = regexp.MustCompile(`\bitunes:key="([^"]+)"`)
	amAnyTagRe    = regexp.MustCompile(`<[^>]*>`)
)

// applemusicSubtitleTranslation 从 Apple 的 TTML 里取译文,拼成一份跟正文同轴的 LRC。
//
// ⚠️ **只认 type="subtitle"**。Apple 的 <translations> 里有两种,实测分布是:
//   - type="replacement":全是 `zh-Hant -> zh-Hans`,即**同一语言的字形替换**(繁转简)。
//     那不是译文;而且这个仓库早有 toSimplified 在主链路上处理繁简,再把它当译文塞进来
//     只会让"译文"这一栏名不副实,还会盖掉别处真正的翻译。
//   - type="subtitle":`en -> zh-Hans` 这类**真正的外语翻译**,是官方人工版本,比
//     translate.go 的机器翻译好得多 —— 这条路存在的理由就是它。
//
// 时间轴不从译文自己身上取:译文的 <text for="Lxxx"> 用 key 指回正文的
// <p itunes:key="Lxxx">,所以时间戳一律以正文那边为准,两轨天然对齐。
//
// ⚠️ **key 对不上的行直接丢,不按顺序硬凑**。Apple 自己的数据偶尔就是错位的:实测 6 首
// 带真翻译的歌里 5 首 key 完全对齐(69/69、54/54、102/102、65/65、89/89),剩下一首
// (Michael Jackson《Butterflies》)译文用的是 L83274 起的一套编号、正文是 L1 起,交集为
// 零,而且行数也不等(42 对 38)。那种情况下按顺序对齐必然错位 —— 错位的译文比没有译文糟,
// 所以宁可整首不给。
func applemusicSubtitleTranslation(ttml string) string {
	block := amSubtitleBlockRe.FindStringSubmatch(ttml)
	if block == nil {
		return ""
	}
	// key -> 行首毫秒
	at := map[string]int{}
	for _, m := range amPTagRe.FindAllStringSubmatch(ttml, -1) {
		attrs := m[1]
		k := amAttrKeyRe.FindStringSubmatch(attrs)
		b := amAttrBeginRe.FindStringSubmatch(attrs)
		if k == nil || b == nil {
			continue
		}
		at[k[1]] = parseTTMLTime(b[1])
	}
	type line struct {
		ms   int
		text string
	}
	var lines []line
	for _, m := range amTextForRe.FindAllStringSubmatch(block[1], -1) {
		ms, ok := at[m[1]]
		if !ok {
			continue // 对不上正文的行直接丢,不猜时间
		}
		// 译文本身也可能是逐字的(一串 <span>),去掉标签取纯文本。
		txt := strings.TrimSpace(html.UnescapeString(amAnyTagRe.ReplaceAllString(m[2], "")))
		if txt == "" {
			continue
		}
		lines = append(lines, line{ms, txt})
	}
	if len(lines) == 0 {
		return ""
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].ms < lines[j].ms })
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(formatLRCTime(l.ms))
		b.WriteString(l.text)
		b.WriteByte('\n')
	}
	return b.String()
}

// resolveApplemusicLyric:①确认用户令牌在手(没有就直接判 applemusic_not_connected,
// 一个网络请求都不发);②搜索;③身份闸淘汰、按分数排序;④按名次逐条取词 ——
// **先逐字后逐行**,逐字那份同时也能产出逐行(parseAMLLTTML 会一并给出 lrc),
// 所以只有逐字不存在时才退到 /lyrics。
//
// 跟 deezer 那条路的一个刻意差别:这里**不并发**取词。Apple 对 amp-api 的限流比
// Deezer 严,而搜索结果第一条几乎总是对的(hasTimeSynced 还额外加了 200 分把有时间轴的
// 顶到前面),顺序取到第一条有词的就停,通常只花一个往返。
func resolveApplemusicLyric(ctx context.Context, artist, title, album string, durationSecs float64) applemusicResult {
	userToken, storefront := applemusicLoadUserToken()
	if userToken == "" {
		applemusicSetLastFailureReason(lyricFailureReasonAppleMusicNotConnected)
		return applemusicResult{}
	}
	devToken := applemusicEnsureDeveloperToken(ctx)
	if devToken == "" {
		return applemusicResult{} // 原因已由 ensure 记下
	}
	if storefront == "" {
		// 登录时没拿到账号所在区,问 Apple 并写回。问不到就判失败 —— 见
		// applemusicLoadUserToken 的注释:猜一个区会让这一源静默全灭。
		if storefront = applemusicEnsureStorefront(ctx, userToken, devToken); storefront == "" {
			return applemusicResult{}
		}
	}

	songs, err := applemusicSearch(ctx, storefront, artist, title, devToken)
	if err != nil || len(songs) == 0 {
		return applemusicResult{}
	}

	type scoredSong struct {
		song  applemusicSong
		score int
	}
	var candidates []scoredSong
	for _, s := range songs {
		if sc := applemusicCandidateScore(s, artist, title, album, durationSecs); sc >= 0 {
			candidates = append(candidates, scoredSong{s, sc})
		}
	}
	if len(candidates) == 0 {
		return applemusicResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > applemusicMaxCandidatesToFetch {
		candidates = candidates[:applemusicMaxCandidatesToFetch]
	}

	for _, c := range candidates {
		id := c.song.ID
		// 逐字优先:它同时给得出逐行,拿到就不用再打 /lyrics。
		if c.song.Attributes.HasTimeSynced {
			if ttml, err := applemusicFetchTTML(ctx, storefront, id, "syllable-lyrics", devToken, userToken); err != nil {
				return applemusicResult{} // 令牌被拒之类,继续试别的候选也是白试
			} else if lrc, yrc, tr, ok := applemusicParseTTML(ttml); ok && lrc != "" {
				return applemusicResultFrom(c.song, lrc, yrc, tr, false)
			}
			if ttml, err := applemusicFetchTTML(ctx, storefront, id, "lyrics", devToken, userToken); err != nil {
				return applemusicResult{}
			} else if lrc, yrc, tr, ok := applemusicParseTTML(ttml); ok && lrc != "" {
				return applemusicResultFrom(c.song, lrc, yrc, tr, !isTimedLRC(lrc))
			}
			continue
		}
		// 只有纯文本的歌:仍然取回来走 plainOnly 通道(分数恒 -1,只有用户手点才采用)。
		ttml, err := applemusicFetchTTML(ctx, storefront, id, "lyrics", devToken, userToken)
		if err != nil {
			return applemusicResult{}
		}
		if lrc, yrc, tr, ok := applemusicParseTTML(ttml); ok && lrc != "" {
			return applemusicResultFrom(c.song, lrc, yrc, tr, !isTimedLRC(lrc))
		}
	}
	return applemusicResult{}
}

// applemusicResultFrom 把一条 song + 解析好的歌词拼成结果。原是 resolveApplemusicLyric
// 里的 build 闭包,提成包级是为了让本地缓存那条路(applemusiclocal.go)复用**同一份**构造 ——
// 两条路进下游的字段形状必须一致(尤其 cover 的 {w}x{h} 替换和 durationSecs 的毫秒换算),
// 否则其中一条会悄悄少给打分层证据。
func applemusicResultFrom(s applemusicSong, lrc, yrc, tr string, plainOnly bool) applemusicResult {
	return applemusicResult{
		lyrics: lrc, yrc: yrc, tr: tr,
		title: s.Attributes.Name, artist: s.Attributes.ArtistName, album: s.Attributes.AlbumName,
		cover: s.cover(), durationSecs: float64(s.Attributes.DurationInMillis) / 1000,
		plainOnly: plainOnly,
	}
}

// applemusicLyric 是这一路的入口,带进程内缓存(同 deezer/musixmatch)。
// catalogID:正在播的这首歌在 Apple 目录里的 id(platformtrackid.go 记的,已过
// appleCatalogAnchor 校验)。非空时先问 Music.app 自己的缓存要官方歌词 —— 那份带
// 词级时间轴和官方译文,是搜索那条拿不到的,见 applemusiclocal.go 头注。
func applemusicLyric(ctx context.Context, artist, title, album string, durationSecs float64, catalogID string) applemusicResult {
	if title == "" {
		return applemusicResult{}
	}
	// catalogID 进缓存键:首播那一拍 Music.app 可能还没写完缓存(实测延迟 0.5~1 秒),
	// 那次只拿得到搜索的结果;不区分的话这条缓存会把后面每一次都挡住。
	key := artist + "|" + title + "|" + album + "|" + catalogID
	applemusicMu.Lock()
	if v, ok := applemusicCache[key]; ok {
		applemusicMu.Unlock()
		return v
	}
	applemusicMu.Unlock()

	// 本地命中就直接用:那是 Music.app 为**正在播的这一条**取回的官方歌词,比搜索出来的
	// 候选更权威,也不必再花一轮网络。
	if r, ok := applemusicLocalLyric(catalogID, artist, title, album, durationSecs); ok {
		applemusicMu.Lock()
		applemusicCache[key] = r
		applemusicMu.Unlock()
		return r
	}

	r := resolveApplemusicLyric(ctx, artist, title, album, durationSecs)
	if !r.empty() {
		applemusicMu.Lock()
		applemusicCache[key] = r
		applemusicMu.Unlock()
	}
	return r
}

// applemusicConnected 供 UI / CLI 判断"用户连过没有"——不发任何网络请求。
func applemusicConnected() bool {
	tok, _ := applemusicLoadUserToken()
	return tok != ""
}
