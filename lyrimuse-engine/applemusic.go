package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"html"
	"io"
	"log"
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
	"unicode"
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
// **不要试图走官方 MusicKit 框架**。MusicKit 需要
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
	// roma:官方音译(<transliterations>,日文 ja-Latn 等)拼成的逐行 LRC,没有时为空。
	roma string
	// bg:背景人声轨(YRC 语法,形状见 amllResult.bg),没有时为空。
	bg string
	// songwriters:TTML 里的词曲作者名单(amllResult.songwriters),没有时为空。
	songwriters []string
	// cover:artwork.url 是个带 {w}x{h} 占位的模板,取词时替换成原图尺寸,见 applemusicSong.cover。
	cover string
	// durationSecs:Apple 自报的曲长(秒),透传给打分的 sourceReportedDurationSecs。
	durationSecs float64
	// isrc:这条录音的 ISRC(曲库 song attributes),没有时为空。见 isrcretry.go。
	isrc string
	// plainOnly:只拿到没有时间戳的正文 —— 语义同 deezer/lrclib 的同名字段(分数钉死 -1,
	// 只有用户在弹窗里手点才会采用)。
	plainOnly bool
	// fromLocalClient:这份 TTML 读自 Music.app 自己的 fsCachedData(applemusicLocalLyric),
	// 不是拿歌名去 amp-api 搜出来的。透传给 lyricCandidate.identityFromLocalClient,
	// 是同源加权的准入条件之一。
	fromLocalClient bool
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
	// applemusicStorefrontsURL:各区的元数据(默认语言、支持的语言),见 applemusicStorefrontEnglishTag。
	applemusicStorefrontsURL = "https://amp-api.music.apple.com/v1/storefronts/"
	applemusicHTTPTimeout    = 8 * time.Second
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
// 最常见的"失败"其实是**用户压根没连过 Apple Music**(applemusic_not_connected),
// 它跟源坏了不是一回事 —— UI 侧据此提示"去设置里连接",不要报成源故障。
func applemusicLastFailureReasonNow() string {
	applemusicLastFailMu.Lock()
	defer applemusicLastFailMu.Unlock()
	return applemusicLastFailure
}

// ---- 凭据 ----

// applemusicUserTokenPath 是 media-user-token 的落点。写入方是 lyrimuse 设置里的
// "连接 Apple Music"窗口(AppleMusicLoginWindow.swift),引擎只读。
//
// 这是用户 Apple Music 账号的访问凭据,跟 musixmatch token 一样只待在本机配置目录,
// 不进仓库、不上传、不写日志(下面任何一处都不打印它的值,只打印长度)。
func applemusicUserTokenPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-applemusic-token.json")
}

// applemusicUserTokenFile:App 侧 AppleMusicTokenFile(LyrimuseCore)写的那份,这边只读用得到的字段,字段两边同步改。
// 这边对令牌的观察(问到的店面、被拒)不写回这里,记在 applemusicStatusPath 那份。
type applemusicUserTokenFile struct {
	MediaUserToken string `json:"media_user_token"`
	Storefront     string `json:"storefront"`
	SavedAt        int64  `json:"saved_at"`
}

// applemusicStatusPath:这边对用户令牌的观察 —— 问 Apple 补到的店面、带着它被拒(401/403)的时刻。令牌文件只由
// App 写;App 的连接卡片把两份合起来看(AppleMusicTokenFile.parse),字段两边同步改。
func applemusicStatusPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-applemusic-status.json")
}

// applemusicStatus 的每一项只对指纹相同的那份令牌成立:用户重连换了令牌,旧的观察自然作废。
type applemusicStatus struct {
	TokenFP    string `json:"token_fp"`
	Storefront string `json:"storefront,omitempty"`
	RejectedAt int64  `json:"rejected_at,omitempty"`
}

// applemusicTokenFingerprint:令牌 SHA-256 的前 8 字节,16 位小写十六进制。只用来认「是不是同一份令牌」,
// 推不回令牌本身。跟 App 的 AppleMusicTokenFile.fingerprint 逐字一致(两侧单测钉同一个值)。
func applemusicTokenFingerprint(token string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(token)))
	return hex.EncodeToString(sum[:8])
}

// applemusicReadTokenFile 读 App 写的令牌文件;没有令牌返回 false。
func applemusicReadTokenFile() (applemusicUserTokenFile, bool) {
	path := applemusicUserTokenPath()
	if path == "" {
		return applemusicUserTokenFile{}, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return applemusicUserTokenFile{}, false
	}
	var f applemusicUserTokenFile
	if json.Unmarshal(raw, &f) != nil || strings.TrimSpace(f.MediaUserToken) == "" {
		return applemusicUserTokenFile{}, false
	}
	return f, true
}

func applemusicReadStatus() applemusicStatus {
	var st applemusicStatus
	if path := applemusicStatusPath(); path != "" {
		if raw, err := os.ReadFile(path); err == nil {
			_ = json.Unmarshal(raw, &st)
		}
	}
	return st
}

// applemusicLoadUserToken 读用户令牌与 storefront。不发网络请求。
// storefront 读不出来时返回**空串**,调用方必须自己去 applemusicEnsureStorefront 问清楚。
//
// 这里以前会在拿不到时退到 "us",那是个会导致整源静默全灭的设计。
// storefront 不只决定"查哪个区的曲库",它同时决定**取词那一趟的鉴权**:Apple 校验的是
// URL 里的 storefront 段 == 用户订阅的区,跟歌属于哪个区无关。实测同一个 id 同一个令牌,
// cn 路径 200、us/gb/es/jp/de 路径一律 404(对照组用各区都有的大热门,排除了"歌本身没有")。
// 所以对一个 cn 订阅用户退到 "us" 的后果不是"少查到几首区域独占曲目",而是**每一次取词
// 都 404**;更糟的是 applemusicFetchTTML 把 404 当正常结果返回 ("", nil),不报错不记原因,
// 表现出来就是"Apple 也没这首歌的词"。宁可判失败让用户看见,也不要猜一个区。
func applemusicLoadUserToken() (string, string) {
	f, ok := applemusicReadTokenFile()
	if !ok {
		return "", ""
	}
	token := strings.TrimSpace(f.MediaUserToken)
	storefront := strings.ToLower(strings.TrimSpace(f.Storefront))
	if storefront == "" {
		// 登录时没拿到店面的,用这边之前问到的;只认同一份令牌的。
		if st := applemusicReadStatus(); st.TokenFP == applemusicTokenFingerprint(token) {
			storefront = st.Storefront
		}
	}
	return token, storefront
}

// applemusicEnsureStorefront:令牌文件里没记下 storefront 时,问 Apple 要权威答案并记下(applemusicNoteStorefront)。
//
// 为什么需要这条路:登录窗口是从 itua cookie 取 storefront 的,而它跟 media-user-token
// 由 Apple 的登录流程分别写入,未必同时就位;登录侧已经改成等一会儿,但等不到时宁可留空,
// 也不猜。这里用 /v1/me/storefront 收尾 —— 它要 developer token + media-user-token
// 两者(实测:只带 user token 回 401、只带 dev token 回 403),而这两样引擎都有,
// App 侧没有 developer token 的获取机制,所以这一步只能放在这边。
//
// 记下是为了下次不用再问。拿不到就返回空串,由调用方判失败,**绝不退回某个默认区**。
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
		applemusicMarkTokenRejected(userToken)
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
	applemusicNoteStorefront(userToken, sf)
	return sf
}

// applemusicUpdateStatus 改这边的状态文件。只在 userToken 还是令牌文件里那一份时记:用户已经重连、换了新令牌,
// 在飞的旧请求回来的结果不该记到新令牌名下。mutate 拿到令牌文件(看 saved_at 用),返回 false 表示不用写。
func applemusicUpdateStatus(userToken string, mutate func(*applemusicStatus, applemusicUserTokenFile) bool) {
	path := applemusicStatusPath()
	f, ok := applemusicReadTokenFile()
	if path == "" || !ok || strings.TrimSpace(f.MediaUserToken) != strings.TrimSpace(userToken) {
		return
	}
	fp := applemusicTokenFingerprint(userToken)
	st := applemusicReadStatus()
	if st.TokenFP != fp {
		st = applemusicStatus{TokenFP: fp}
	}
	if !mutate(&st, f) {
		return
	}
	out, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return
	}
	_ = writeFileAtomic(path, out)
}

// applemusicNoteStorefront 记下问到的店面。失败不算错 —— 大不了下次再问一次,不该因此让这次取词失败。
func applemusicNoteStorefront(userToken, storefront string) {
	applemusicUpdateStatus(userToken, func(st *applemusicStatus, _ applemusicUserTokenFile) bool {
		if st.Storefront == storefront {
			return false
		}
		st.Storefront = storefront
		return true
	})
}

// applemusicMarkTokenRejected 记下「这份令牌被 Apple 拒了」,App 的连接卡片据此显示「已失效」。这次登录之后
// 已经记过就不重写;同一份令牌重新登录过(saved_at 晚于上次被拒)再被拒,重记。
func applemusicMarkTokenRejected(userToken string) {
	applemusicUpdateStatus(userToken, func(st *applemusicStatus, f applemusicUserTokenFile) bool {
		if st.RejectedAt != 0 && st.RejectedAt >= f.SavedAt {
			return false
		}
		st.RejectedAt = time.Now().Unix()
		return true
	})
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
	// 常驻进程和 search-lyrics 等子命令都会写这份:writeFileAtomic 的临时文件名是随机的。
	_ = writeFileAtomic(path, raw)
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
	applemusicJSAssetRe = regexp.MustCompile(`/assets/[A-Za-z0-9._~-]+\.js`)
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

// applemusicJSAssetMaxTries:一次最多下载几个 bundle 找 token(每个 3MB 量级)。
const applemusicJSAssetMaxTries = 4

// applemusicTokenParserName:parserdrift.go 里这条路径的名字。
const applemusicTokenParserName = "apple-music-web-token"

// applemusicDevTokenFetchCooldown:抓 token 失败之后隔多久再抓。一次要下首页(2MB 量级)加最多
// applemusicJSAssetMaxTries 个 bundle(各 3MB 量级),不冷却的话每解析一首歌都重来一遍。
const applemusicDevTokenFetchCooldown = 30 * time.Minute

// applemusicDevTokenFailedAt:上次抓 token 失败的时刻。受 applemusicDevTokenFetchMu 保护。
var applemusicDevTokenFailedAt time.Time

// applemusicJSAssets 从首页里取出所有 `/assets/*.js`,去重后按「index~ 主包 → 其余 index 开头的
// (index-legacy~ 等) → 其它」排序。token 在主包里,legacy 包里也有一份;只认一种文件名的话 Apple
// 换一次打包命名就续不上 token。纯函数,便于单测。
func applemusicJSAssets(home string) []string {
	rank := func(a string) int {
		name := strings.TrimPrefix(a, "/assets/")
		switch {
		case strings.HasPrefix(name, "index~"):
			return 0
		case strings.HasPrefix(name, "index"):
			return 1
		default:
			return 2
		}
	}
	seen := map[string]bool{}
	var out []string
	for _, a := range applemusicJSAssetRe.FindAllString(home, -1) {
		if seen[a] {
			continue
		}
		seen[a] = true
		out = append(out, a)
	}
	sort.SliceStable(out, func(i, j int) bool { return rank(out[i]) < rank(out[j]) })
	return out
}

// applemusicFetchDeveloperToken 抓一个能用的 developer token:①取 music.apple.com 的
// 首页,列出页面引用的 JS bundle(applemusicJSAssets);②按顺序下载;③抽出所有候选 JWT;
// ④逐个拿一个最轻的 catalog 请求去验,第一个 200 的就是它。一个 bundle 里没有能用的就换下一个。
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
	assets := applemusicJSAssets(home)
	if len(assets) == 0 {
		log.Printf("applemusic: developer token: home page lists no /assets/*.js bundle")
		noteParserUnrecognized(applemusicTokenParserName, "home page lists no /assets/*.js bundle")
		return ""
	}
	tried := map[string]bool{}
	read := 0
	for i, asset := range assets {
		if i >= applemusicJSAssetMaxTries || ctx.Err() != nil {
			break
		}
		js, ok := get(applemusicWebOrigin + asset)
		if !ok {
			continue
		}
		read++
		for _, tok := range applemusicExtractJWTs(js) {
			if tried[tok] {
				continue
			}
			tried[tok] = true
			if applemusicDevTokenWorks(ctx, tok) {
				noteParserRecognized(applemusicTokenParserName)
				return tok
			}
		}
	}
	log.Printf("applemusic: developer token: no working token in %d bundle(s)", min(len(assets), applemusicJSAssetMaxTries))
	// 一个 bundle 都没下成是网络问题,不算认不出。
	if ctx.Err() == nil && read > 0 {
		noteParserUnrecognized(applemusicTokenParserName, fmt.Sprintf("no working JWT in %d bundle(s), %d candidate(s)", min(len(assets), applemusicJSAssetMaxTries), len(tried)))
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
	if !applemusicDevTokenFailedAt.IsZero() && time.Since(applemusicDevTokenFailedAt) < applemusicDevTokenFetchCooldown {
		applemusicSetLastFailureReason(lyricFailureReasonAppleMusicNoDevToken)
		return ""
	}
	tok := applemusicFetchDeveloperToken(ctx)
	if tok == "" {
		if ctx.Err() == nil {
			applemusicDevTokenFailedAt = time.Now()
		}
		applemusicSetLastFailureReason(lyricFailureReasonAppleMusicNoDevToken)
		return ""
	}
	applemusicDevTokenFailedAt = time.Time{}
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
		// Isrc:这条录音的 ISRC。按 ISRC 补取未应答的 deezer / musixmatch 用,见 isrcretry.go。
		Isrc          string `json:"isrc"`
		HasLyrics     bool   `json:"hasLyrics"`
		HasTimeSynced bool   `json:"hasTimeSyncedLyrics"`
		Artwork       struct {
			URL string `json:"url"`
		} `json:"artwork"`
	} `json:"attributes"`
}

// cover 把 artwork.url 的 {w}x{h} 占位替换成 10000x10000:请求比原图大时 Apple 按原图给(实测原图
// 1400 / 3000 的两张都照原图返回),等于拿原图。Apple 给的是模板串,原样用会 404。
func (s applemusicSong) cover() string {
	u := strings.TrimSpace(s.Attributes.Artwork.URL)
	if u == "" {
		return ""
	}
	u = strings.ReplaceAll(u, "{w}", "10000")
	u = strings.ReplaceAll(u, "{h}", "10000")
	u = strings.ReplaceAll(u, "{f}", "jpg")
	// {c} 是裁切/填充代码,Apple 的模板是 `{w}x{h}{c}.{f}` —— 漏掉它,URL 里会留下一个
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
//
// 主机按 applemusicSearchBases(不带 userToken)或 applemusicLyricsBases(带)的顺序试,只在传输失败 / 5xx
// 时换下一个;其余状态码是答了,原样交给调用方。
func applemusicAPIGet(ctx context.Context, path, devToken, userToken string) ([]byte, int, error) {
	bases := applemusicSearchBases
	if userToken != "" {
		bases = applemusicLyricsBases
	}
	var raw []byte
	var status int
	err := tryEach(ctx, bases, func(base string) error {
		var e error
		raw, status, e = applemusicAPIGetAt(ctx, base, path, devToken, userToken)
		if e == nil && status >= 500 {
			return fmt.Errorf("status %d", status)
		}
		return e
	})
	if err != nil && status >= 500 {
		// 主机都回 5xx:状态码照样交出去,调用方按非 200 处理。
		return raw, status, nil
	}
	return raw, status, err
}

func applemusicAPIGetAt(ctx context.Context, base, path, devToken, userToken string) ([]byte, int, error) {
	u := base + path
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

// applemusicSearch 在 storefront 这个区搜候选,lang 非空时按这种语言回名字(l 参数,必须是这个区支持的,
// 不支持的 Apple 静默照默认语言答)。只需要 developer token。
func applemusicSearch(ctx context.Context, storefront, lang, artist, title, devToken string) ([]applemusicSong, error) {
	// 搜索词里歌名带编号时去掉带编号的那几层,见 lyricQueryTitle。
	q := strings.TrimSpace(artist + " " + lyricQueryTitle(title))
	path := neturl.PathEscape(storefront) + "/search?types=songs&limit=10&term=" + neturl.QueryEscape(q)
	if lang != "" {
		path += "&l=" + neturl.QueryEscape(lang)
	}
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

// applemusicSearchVariant:再搜一次用的区和语言。
type applemusicSearchVariant struct{ storefront, lang string }

// applemusicFallbackSearches:用户所在区的搜索一条候选都挑不出时,还值得再搜的几种。取词仍走用户所在区
// (曲目 id 各区通用)。见 09 章决策 142。
//   - 本地歌手名不含中日韩文字:同一个区按这个区支持的英文再搜。cn 这类区把外国歌手名译成本地文字,
//     英文下回原名。
//   - 歌名或歌手带假名 / 谚文:到 jp / kr 区搜。cn 区给不少日韩歌登记的是英文或罗马字名。
func applemusicFallbackSearches(ctx context.Context, storefront, artist, title, devToken string) []applemusicSearchVariant {
	var out []applemusicSearchVariant
	if !containsCJKScript(artist) {
		if tag := applemusicStorefrontEnglishTag(ctx, storefront, devToken); tag != "" {
			out = append(out, applemusicSearchVariant{storefront, tag})
		}
	}
	if storefront != "jp" && containsKana(artist+title) {
		out = append(out, applemusicSearchVariant{"jp", ""})
	}
	if storefront != "kr" && strings.ContainsFunc(artist+title, func(r rune) bool { return unicode.Is(unicode.Hangul, r) }) {
		out = append(out, applemusicSearchVariant{"kr", ""})
	}
	return out
}

var (
	applemusicEnglishTagMu sync.Mutex
	// applemusicEnglishTags:storefront → 这个区支持的英文语言标签,默认语言就是英文或不支持英文时为空串。只存问成了的。
	applemusicEnglishTags = map[string]string{}
)

// applemusicStorefrontEnglishTag:这个区支持的英文语言标签(实测 cn / kr / tw 是 en-GB,jp 是 en-US),
// 默认语言本来就是英文或不支持英文时返回空串。每个区只问一次。
func applemusicStorefrontEnglishTag(ctx context.Context, storefront, devToken string) string {
	applemusicEnglishTagMu.Lock()
	tag, ok := applemusicEnglishTags[storefront]
	applemusicEnglishTagMu.Unlock()
	if ok {
		return tag
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, applemusicStorefrontsURL+neturl.PathEscape(storefront), nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Authorization", "Bearer "+devToken)
	req.Header.Set("Origin", applemusicWebOrigin)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(applemusicHTTPTimeout), req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var out struct {
		Data []struct {
			Attributes struct {
				DefaultLanguageTag    string   `json:"defaultLanguageTag"`
				SupportedLanguageTags []string `json:"supportedLanguageTags"`
			} `json:"attributes"`
		} `json:"data"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out) != nil || len(out.Data) == 0 {
		return ""
	}
	tag = applemusicEnglishTagFrom(out.Data[0].Attributes.DefaultLanguageTag, out.Data[0].Attributes.SupportedLanguageTags)
	applemusicEnglishTagMu.Lock()
	applemusicEnglishTags[storefront] = tag
	applemusicEnglishTagMu.Unlock()
	return tag
}

// applemusicEnglishTagFrom 从一个区的默认语言和支持的语言里挑英文标签。纯函数,便于单测。
func applemusicEnglishTagFrom(defaultTag string, supported []string) string {
	isEnglish := func(t string) bool { return t == "en" || strings.HasPrefix(t, "en-") }
	if isEnglish(defaultTag) {
		return ""
	}
	for _, t := range supported {
		if isEnglish(t) {
			return t
		}
	}
	return ""
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
	// 歌手写法对不上时的第二条依据,口径同汽水。这样收下的分数压在 100 以下,排在歌手对得上的后面。
	byTriangle := false
	if !lyricSourceArtistMatches(a.ArtistName, artist) {
		if !lyricRecordingTriangleMatchesGuarded(a.Name, a.AlbumName, a.ArtistName, float64(a.DurationInMillis)/1000, title, album, artist, durationSecs) {
			return -1
		}
		byTriangle = true
	}
	if versionTagsMismatch(title, album, a.Name, a.AlbumName) {
		return -1
	}
	score := 100
	// 有时间轴的优先 —— 同分时先取它,省得挑到只有纯文本的那条。
	if a.HasTimeSynced {
		score += 200
	}
	if byTriangle {
		score = 0
		if a.HasTimeSynced {
			score = 40
		}
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
			// TTMLLocalizations:带 extend=ttmlLocalizations 时回的是这个字段(同一份文档,多了
			// <translations> / <transliterations>),ttml 那个字段不再出现。
			TTMLLocalizations string `json:"ttmlLocalizations"`
		} `json:"attributes"`
	} `json:"data"`
}

// applemusicLyricsQuery 是取词请求的参数,照 Music.app 自己的写法(它的网络缓存里记着):
// l[lyrics] 决定 <translations type="subtitle"> 的语言;l[script] 里要带一个 `-Latn`,才会回
// <transliterations>(日文 ja-Latn、韩文 ko-Latn、中文 zh-Latn-pinyin);extend=ttmlLocalizations 让
// 这两块进文档。三个都不带时只回正文 —— 官方译文和音译都拿不到。
func applemusicLyricsQuery(target string) string {
	lyrics, script := applemusicLyricsLocale(target)
	v := neturl.Values{}
	v.Set("l[lyrics]", lyrics)
	v.Set("l[script]", script)
	v.Set("extend", "ttmlLocalizations")
	return "?" + v.Encode()
}

// applemusicLyricsLocale:译文语言设置(ISO 639-1,中文可能带 -Hant)换成 Apple 的地区写法和 l[script]。
func applemusicLyricsLocale(target string) (lyrics, script string) {
	t := strings.ToLower(strings.TrimSpace(target))
	switch {
	case t == "zh-hant" || t == "zh-tw" || t == "zh-hk":
		return "zh-Hant-TW", "zh-Hant,zh-Latn"
	case strings.HasPrefix(t, "zh"):
		return "zh-Hans-CN", "zh-Hans,zh-Latn"
	case t == "ja":
		return "ja-JP", "ja-Jpan,ja-Latn"
	case t == "ko":
		return "ko-KR", "ko-Kore,ko-Latn"
	case t == "" || t == "en":
		return "en-US", "en-Latn"
	}
	return t, t + "-Latn"
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
	path := neturl.PathEscape(storefront) + "/songs/" + neturl.PathEscape(songID) + "/" + kind +
		applemusicLyricsQuery(features().LyricsTranslationLanguage)
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
		applemusicMarkTokenRejected(userToken)
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
	if t := out.Data[0].Attributes.TTMLLocalizations; t != "" {
		return t, nil
	}
	return out.Data[0].Attributes.TTML, nil
}

// applemusicParseTTML 把一份 Apple TTML 解析成整行 / 逐字 / 译文 / 罗马音 / 背景人声。直接复用
// amllttml.go 的解析器 —— AMLL 的方言就是照着这份抄的(连 ttm:agent 对唱标注都一样)。
func applemusicParseTTML(ttml string) (amllResult, bool) {
	if strings.TrimSpace(ttml) == "" {
		return amllResult{}, false
	}
	r, ok := parseAMLLTTML(ttml)
	if !ok {
		return amllResult{}, false
	}
	if r.tr == "" {
		// Apple 把译文放在 <iTunesMetadata><translations> 里,parseAMLLTTML 认的是 AMLL 那套
		// ttm:role="x-translation" 形状,看不到它。见 applemusicSubtitleTranslation。
		r.tr = applemusicSubtitleTranslation(ttml)
	}
	if r.roma == "" {
		r.roma = applemusicTransliteration(ttml)
	}
	r.spatialOffsetSecs = applemusicSpatialLyricOffset(ttml)
	return r, true
}

var (
	// <translation type="subtitle" xml:lang="zh-Hans">…</translation>
	amSubtitleBlockRe = regexp.MustCompile(`(?s)<translation\b[^>]*\btype="subtitle"[^>]*>(.*?)</translation>`)
	// <transliteration xml:lang="ja-Latn">…</transliteration>
	amTransliterationBlockRe = regexp.MustCompile(`(?s)<transliteration\b[^>]*>(.*?)</transliteration>`)
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
// **只认 type="subtitle"**。Apple 的 <translations> 里有两种,实测分布是:
//   - type="replacement":全是 `zh-Hant -> zh-Hans`,即**同一语言的字形替换**(繁转简)。
//     那不是译文;而且这个仓库早有 toSimplified 在主链路上处理繁简,再把它当译文塞进来
//     只会让"译文"这一栏名不副实,还会盖掉别处真正的翻译。
//   - type="subtitle":`en -> zh-Hans` 这类**真正的外语翻译**,是官方人工版本,比
//     translate.go 的机器翻译好得多 —— 这条路存在的理由就是它。
//
// 时间轴不从译文自己身上取:译文的 <text for="Lxxx"> 用 key 指回正文的
// <p itunes:key="Lxxx">,所以时间戳一律以正文那边为准,两轨天然对齐。
//
// **key 对不上的行直接丢,不按顺序硬凑**。Apple 自己的数据偶尔就是错位的:实测 6 首
// 带真翻译的歌里 5 首 key 完全对齐(69/69、54/54、102/102、65/65、89/89),剩下一首
// (Michael Jackson《Butterflies》)译文用的是 L83274 起的一套编号、正文是 L1 起,交集为
// 零,而且行数也不等(42 对 38)。那种情况下按顺序对齐必然错位 —— 错位的译文比没有译文糟,
// 所以宁可整首不给。
func applemusicSubtitleTranslation(ttml string) string {
	block := amSubtitleBlockRe.FindStringSubmatch(ttml)
	if block == nil {
		return ""
	}
	return applemusicKeyedLRC(ttml, block[1])
}

// applemusicTransliteration 取 Apple 的官方音译(<transliterations>,日文 ja-Latn、韩文 ko-Latn
// 等),拼成跟正文同轴的罗马音 LRC。对齐规则同 applemusicSubtitleTranslation。多份音译时取第一份。
func applemusicTransliteration(ttml string) string {
	block := amTransliterationBlockRe.FindStringSubmatch(ttml)
	if block == nil {
		return ""
	}
	return applemusicKeyedLRC(ttml, block[1])
}

// applemusicKeyedLRC 把译文 / 音译块里的 <text for="Lxxx"> 按 key 挂回正文 <p itunes:key="Lxxx">
// 的行首时间,拼成 LRC。key 对不上的行直接丢。
func applemusicKeyedLRC(ttml, block string) string {
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
	for _, m := range amTextForRe.FindAllStringSubmatch(block, -1) {
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
// 一个网络请求都不发);②isrc 非空时按 ISRC 直取这条录音的各个上架条目(applemusicSongsByISRC),专辑跟本地对得上的
// 先取词;③按名字搜索、身份闸淘汰、按分数排序(applemusicNameCandidates),按名次逐条取词;④还没有带时间轴的,
// 再取 ISRC 条目里专辑对不上的那些。取词**先逐字后逐行**,逐字那份同时也能产出逐行(parseAMLLTTML 会一并给出 lrc),
// 所以只有逐字不存在时才退到 /lyrics;所有候选都没有带时间轴的,才交出第一份纯文本(按上面的先后)。
//
// 跟 deezer 那条路的一个刻意差别:这里**不并发**取词。Apple 对 amp-api 的限流比
// Deezer 严,而搜索结果第一条几乎总是对的(hasTimeSynced 还额外加了 200 分把有时间轴的
// 顶到前面),顺序取到第一条有词的就停,通常只花一个往返。
//
// isrc:这次播放的这条录音的 ISRC(lyricSourceISRC;只有 Spotify 原生客户端在播时有),没有时为空。
func resolveApplemusicLyric(ctx context.Context, artist, title, album string, durationSecs float64, isrc string) applemusicResult {
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

	tried := map[string]bool{}
	var plain applemusicResult
	// try 给一组候选取词:取到带时间轴的、或者令牌被拒(整路放弃)时 done。纯文本只记第一份。
	try := func(candidates []applemusicSong) (r applemusicResult, done bool) {
		timed, p, fatal := applemusicFetchCandidates(ctx, storefront, candidates, tried, devToken, userToken)
		if fatal {
			return applemusicResult{}, true
		}
		if plain.empty() {
			plain = p
		}
		return timed, !timed.empty()
	}

	// 按 ISRC 直取:拿到的是正在播的这条录音本身,歌名 / 歌手写法跟本地对不上也取得到(Apple 上的名字常多带
	// 「feat.」「(Live)」这类尾巴)。条目的专辑跟本地对不上(这条录音只挂在合辑下)时排到名字检索后面,
	// 名字挑得中时用名字挑的那条。见 09 章决策 146。
	var onAlbum, offAlbum []applemusicSong
	if isrc != "" {
		onAlbum, offAlbum = applemusicISRCCandidates(applemusicSongsByISRC(ctx, storefront, isrc, devToken), album, durationSecs)
		if r, done := try(onAlbum); done {
			return r
		}
	}
	if r, done := try(applemusicNameCandidates(ctx, storefront, artist, title, album, durationSecs, devToken)); done {
		return r
	}
	if r, done := try(offAlbum); done {
		return r
	}
	return plain
}

// applemusicNameCandidates 按名字搜候选:用户所在区搜一次,一条都挑不出时按 applemusicFallbackSearches 再搜。
// 搜索没问成或挑不出返回 nil。
func applemusicNameCandidates(ctx context.Context, storefront, artist, title, album string, durationSecs float64, devToken string) []applemusicSong {
	songs, err := applemusicSearch(ctx, storefront, "", artist, title, devToken)
	if err != nil {
		return nil
	}
	if candidates := applemusicRankCandidates(songs, artist, title, album, durationSecs); len(candidates) > 0 {
		return candidates
	}
	for _, v := range applemusicFallbackSearches(ctx, storefront, artist, title, devToken) {
		if songs, err := applemusicSearch(ctx, v.storefront, v.lang, artist, title, devToken); err == nil {
			if candidates := applemusicRankCandidates(songs, artist, title, album, durationSecs); len(candidates) > 0 {
				return candidates
			}
		}
	}
	return nil
}

// applemusicFetchCandidates 按顺序给候选取词,取到第一份带时间轴的就停(timed)。只有纯文本的候选记下第一份
// (plain,plainOnly,分数恒 -1,只有用户手点才采用),所有候选都没有带时间轴的才有用。tried 记着取过的曲目 id,
// 取过的不再取。fatal:令牌被拒之类,继续试别的候选也是白试。
func applemusicFetchCandidates(ctx context.Context, storefront string, candidates []applemusicSong, tried map[string]bool, devToken, userToken string) (timed, plain applemusicResult, fatal bool) {
	for _, song := range candidates {
		if !plain.empty() && !song.Attributes.HasTimeSynced {
			break // 已经有一份纯文本了,后面标着没有时间轴的不再试(候选按有没有时间轴排过序)
		}
		id := song.ID
		if tried[id] {
			continue
		}
		tried[id] = true
		// 一律先问逐字端点,不看搜索结果的 hasTimeSyncedLyrics:标着 false 的也可能在这里拿到逐行时间轴,
		// 只有纯文本的歌这里回的是同一份不带时间的 TTML(见 09 章决策 142)。这个端点没有时才问 /lyrics。
		ttml, err := applemusicFetchTTML(ctx, storefront, id, "syllable-lyrics", devToken, userToken)
		if err != nil {
			return applemusicResult{}, applemusicResult{}, true
		}
		if ttml == "" {
			if ttml, err = applemusicFetchTTML(ctx, storefront, id, "lyrics", devToken, userToken); err != nil {
				return applemusicResult{}, applemusicResult{}, true
			}
		}
		p, ok := applemusicParseTTML(ttml)
		if ok && isTimedLRC(p.lrc) {
			return applemusicResultFrom(song, p, false), plain, false
		}
		if !plain.empty() {
			continue
		}
		if txt := applemusicPlainLyrics(ttml); txt != "" {
			plain = applemusicResultFrom(song, amllResult{lrc: txt}, true)
		}
	}
	return applemusicResult{}, plain, false
}

// applemusicSongsByISRC 按 ISRC 直取这条录音在 storefront 这个区上架的条目(同一条录音常同时挂在单曲、专辑和
// 各种合辑下)。只需要 developer token。没问成或没有返回 nil。
func applemusicSongsByISRC(ctx context.Context, storefront, isrc, devToken string) []applemusicSong {
	path := neturl.PathEscape(storefront) + "/songs?filter[isrc]=" + neturl.QueryEscape(isrc)
	raw, status, err := applemusicAPIGet(ctx, path, devToken, "")
	if err != nil || status != http.StatusOK {
		return nil
	}
	var out struct {
		Data []applemusicSong `json:"data"`
	}
	if json.Unmarshal(raw, &out) != nil {
		return nil
	}
	return out.Data
}

// applemusicISRCCandidates 从按 ISRC 直取的条目里挑要取词的:不过歌名 / 歌手闸(ISRC 是录音级身份),只过
// hasLyrics 和时长闸(ISRC 也有脏数据,口径同 deezer 的 ISRC 直取)。按专辑分两组:跟本地专辑相同或互相包含
// (albumScore >= 100,本地没有专辑名时全算)的进 onAlbum,其余进 offAlbum(多是合辑:条目的专辑名和封面会交给
// 下游)。组内有时间轴的排前面、同档专辑更像的排前面,每组最多 applemusicMaxCandidatesToFetch 条。纯函数,便于单测。
func applemusicISRCCandidates(songs []applemusicSong, album string, durationSecs float64) (onAlbum, offAlbum []applemusicSong) {
	for _, s := range songs {
		a := s.Attributes
		if strings.TrimSpace(s.ID) == "" || !a.HasLyrics || !sourceDurationFits(durationSecs, float64(a.DurationInMillis)/1000) {
			continue
		}
		if strings.TrimSpace(album) == "" || albumScore(a.AlbumName, album) >= 100 {
			onAlbum = append(onAlbum, s)
		} else {
			offAlbum = append(offAlbum, s)
		}
	}
	rank := func(g []applemusicSong) []applemusicSong {
		sort.SliceStable(g, func(i, j int) bool {
			if ti, tj := g[i].Attributes.HasTimeSynced, g[j].Attributes.HasTimeSynced; ti != tj {
				return ti
			}
			return albumScore(g[i].Attributes.AlbumName, album) > albumScore(g[j].Attributes.AlbumName, album)
		})
		return g[:min(len(g), applemusicMaxCandidatesToFetch)]
	}
	return rank(onAlbum), rank(offAlbum)
}

// applemusicPlainLyrics 把不带时间的 TTML(itunes:timing="None",<p> 没有 begin)按行取出正文,拼成纯文本。
// 带时间的 TTML 也照样只取正文。
func applemusicPlainLyrics(ttml string) string {
	var doc ttmlDoc
	if strings.TrimSpace(ttml) == "" || xml.Unmarshal([]byte(ttml), &doc) != nil {
		return ""
	}
	var lines []string
	for _, div := range doc.Divs {
		for _, ln := range div.Lines {
			if t := strings.TrimSpace(ttmlLiteralText(ln.Kids)); t != "" {
				lines = append(lines, t)
			}
		}
	}
	return strings.Join(lines, "\n")
}

// applemusicRankCandidates 过身份闸、按分数排序,最多留 applemusicMaxCandidatesToFetch 条。纯函数,便于单测。
func applemusicRankCandidates(songs []applemusicSong, artist, title, album string, durationSecs float64) []applemusicSong {
	type scoredSong struct {
		song  applemusicSong
		score int
	}
	var kept []scoredSong
	for _, s := range songs {
		if sc := applemusicCandidateScore(s, artist, title, album, durationSecs); sc >= 0 {
			kept = append(kept, scoredSong{s, sc})
		}
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].score > kept[j].score })
	out := make([]applemusicSong, 0, min(len(kept), applemusicMaxCandidatesToFetch))
	for _, k := range kept {
		if len(out) == applemusicMaxCandidatesToFetch {
			break
		}
		out = append(out, k.song)
	}
	return out
}

// applemusicResultFrom 把一条 song + 解析好的歌词拼成结果。原是 resolveApplemusicLyric
// 里的 build 闭包,提成包级是为了让本地缓存那条路(applemusiclocal.go)复用**同一份**构造 ——
// 两条路进下游的字段形状必须一致(尤其 cover 的 {w}x{h} 替换和 durationSecs 的毫秒换算),
// 否则其中一条会悄悄少给打分层证据。
func applemusicResultFrom(s applemusicSong, p amllResult, plainOnly bool) applemusicResult {
	lyrics, yrc := p.lrc, p.yrc
	if !plainOnly {
		// 空间音频版的偏移跟着正文走,由 App 按实际在放的时长决定用不用(见 applemusicspatial.go)。
		stereoSecs := float64(s.Attributes.DurationInMillis) / 1000
		lyrics = withSpatialAudioTag(lyrics, p.spatialOffsetSecs, stereoSecs)
		yrc = withSpatialAudioTag(yrc, p.spatialOffsetSecs, stereoSecs)
	}
	return applemusicResult{
		lyrics: lyrics, yrc: yrc, tr: p.tr, roma: p.roma, bg: p.bg, songwriters: p.songwriters,
		title: s.Attributes.Name, artist: s.Attributes.ArtistName, album: s.Attributes.AlbumName,
		cover: s.cover(), durationSecs: float64(s.Attributes.DurationInMillis) / 1000,
		isrc: s.Attributes.Isrc, plainOnly: plainOnly,
	}
}

// applemusicLyric 是这一路的入口,带进程内缓存(同 deezer/musixmatch)。
// catalogID:正在播的这首歌在 Apple 目录里的 id(platformtrackid.go 记的,已过
// appleCatalogAnchor 校验)。非空时先问 Music.app 自己的缓存要官方歌词 —— 那份带
// 词级时间轴和官方译文,是搜索那条拿不到的,见 applemusiclocal.go 头注。
// isrc:这次播放的这条录音的 ISRC(lyricSourceISRC),非空时先按它直取,见 resolveApplemusicLyric。
func applemusicLyric(ctx context.Context, artist, title, album string, durationSecs float64, catalogID, isrc string) applemusicResult {
	if title == "" {
		return applemusicResult{}
	}
	// catalogID 进缓存键:首播那一拍 Music.app 可能还没写完缓存(实测延迟 0.5~1 秒),
	// 那次只拿得到搜索的结果;不区分的话这条缓存会把后面每一次都挡住。isrc 同理(Spotify 的 ISRC 索引是后台建的,
	// 首播那一拍常还没有),同 deezer。
	key := artist + "|" + title + "|" + album + "|" + catalogID + "|" + isrc + "|" + features().LyricsTranslationLanguage
	applemusicMu.Lock()
	if v, ok := applemusicCache[key]; ok {
		applemusicMu.Unlock()
		return v
	}
	applemusicMu.Unlock()

	// 本地命中就直接用:那是 Music.app 为**正在播的这一条**取回的官方歌词,比搜索出来的
	// 候选更权威,也不必再花一轮网络。按名字认时用播放器原样标签(lyricIdentityFields):缓存里存的就是它显示的写法。
	idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
	if r, ok := applemusicLocalLyric(catalogID, idArtist, idTitle, idAlbum, durationSecs); ok {
		applemusicMu.Lock()
		applemusicCache[key] = r
		applemusicMu.Unlock()
		return r
	}

	r := resolveApplemusicLyric(ctx, artist, title, album, durationSecs, isrc)
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
