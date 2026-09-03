// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// musixmatchLyric 是歌词第五个候选来源。Musixmatch 是 Spotify 官方合作的歌词供应商，
// 对欧美/日韩等非中文曲库的覆盖明显强于网易云/QQ/酷狗——这几个平台的曲库/搜索索引
// 都是按中文舞台名/中文曲库编的,对纯西文/日韩曲目常常查不到或版本不对。用的是
// apic-desktop.musixmatch.com 这个非官方逆向接口(没有官方文档,但被 syncedlyrics
// 等大量开源项目复用,是"公开的秘密"),固定身份标识 app_id=web-desktop-app-v1.0。
//
// 三段式:①token.get 匿名拿一个临时 usertoken(10 分钟有效,不需要用户任何操作,
// 401 时按官方样例退避 10 秒重试一次);②track.search 按歌手+歌名搜出 track_id(挑
// has_subtitles==1 的结果,没有逐行歌词的候选后面必然 404,不值得白跑一趟);
// ③用 track_id 查 track.subtitle.get(逐行 LRC,当作候选正文)+ track.richsync.get
// (逐字,词级,归一化成 YRCParser 语法,查不到不影响逐行结果)+ 可选的
// crowd.track.translations.get(社区翻译,按 features.LyricsTranslationLanguage
// 指定目标语言——netease/QQ 的译文固定是中文,这是目前唯一能自选语言的译文来源)。
//
// 用 apic-appmobile(mac-ios-v2.0)这组 host+app_id,不是网上大多数参考实现
// (syncedlyrics 等)默认用的 apic-desktop(web-desktop-app-v1.0)——开发时实测
// apic-desktop 在这台机器的网络环境下 token.get 稳定返回 401 hint=captcha(被
// Musixmatch 的反爬风控拦了,不是我方请求有误),换成 apic-appmobile+mac-ios-v2.0
// 立刻能拿到正常 200 的 token,后续 search/subtitle/richsync/translations 四个
// 端点在这组 host+app_id 下逐一实测全部通过。两组 host+app_id 分别对应 Musixmatch
// 桌面网页版/iOS App 客户端,接口形状完全一致,只是反爬策略不同,选哪组纯粹是"哪个
// 实测不被拦"的问题。
//
// ⚠️ 2026-08-15:这个源又哑了一次,但**跟上面那种反爬是两回事**,别按同一个思路去查。
// 这次是系统 DNS 把 apic-*.musixmatch.com 解析到了不属于 Musixmatch 的地址
// (apic-appmobile → 31.13.91.6,Facebook 的段;DoH 查到的真实地址是 44.212.146.46 /
// 52.5.55.223),TLS 握手直接失败("no alternative certificate subject name matches"),
// 一个字节都拿不到。反爬会正经返回 401 + hint=captcha 的 JSON;这次是连接根本建不起来。
// 用 curl --resolve 强连真实 IP 立刻 200 + 拿到 token —— 服务器一直好好的。
// 修法见 doh.go:这个源的 HTTP client 走 DoH 解析,证书仍按域名严格校验。
//
// 顺带一提,当时的表现不只是"少一个源":每首歌它都要把 DNS/TLS 超时白等一遍,
// healthcheck 探两首歌要 29s;修好之后 7s。
const (
	musixmatchAppID   = "mac-ios-v2.0"
	musixmatchBaseURL = "https://apic-appmobile.musixmatch.com/ws/1.1/"
)

type musixmatchResult struct {
	lrc string
	yrc string // 归一化成 YRCParser 语法后的逐字数据,没有则空串
	tr  string // 译文(逐行 LRC),语言取决于调用时传入的 features.LyricsTranslationLanguage,没有则空串
	// title/artist/album/cover 是 Musixmatch 曲库里这首歌实际匹配到的信息——纯粹给
	// "搜索候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自 track.search 响应本身
	// (本来就已经查到,只是原来没往外传)。cover 用 500x500 这档,跟网易云封面挑的
	// 尺寸量级接近,不用最大的 800x800(候选列表里的小图不需要)。
	title, artist, album, cover string
	// durationSecs:musixmatch 自报的曲长(秒),0=没给。透传给
	// lyricCandidate.sourceReportedDurationSecs 参与打分,见 match.go 的
	// sourceDurationMismatchPenalty。
	durationSecs float64
	// plainOnly:lrc 装的是**没有时间戳**的纯文本(2026-09-02 加)。语义与取舍完全等同
	// lrclibResult.plainOnly,见那边的头注——分数钉死 -1、绝不被自动路径选中,只有用户
	// 在「搜索候选歌词」弹窗里明确采纳才生效。
	plainOnly bool
}

var (
	musixmatchMu    sync.Mutex
	musixmatchCache = map[string]musixmatchResult{} // artist|title|trLang -> result

	musixmatchTokenMu     sync.Mutex // 只保护下面两个值本身,不跨 I/O 持有
	musixmatchToken       string
	musixmatchTokenExpiry time.Time

	// musixmatchTokenFetchMu 是单飞锁:同一时刻只允许一个 goroutine 真的去换 token
	// (读磁盘 + 必要时发网络请求),其余排队等它做完再复查缓存。2026-08-24 用户报"批量
	// 解析时 musixmatch 交出候选的比例只有 20% 上下,而单首/大规模扫描能到 65%~90%"——
	// 量出来的根因:相册预取/批量导入触发很多首歌同时解析时,原来每个 goroutine 独立
	// 判定"没有可用 token"就各自发一次 token.get,而 apic 那台机器实测把除第一个之外的
	// 并发请求全按反爬拒掉(401 hint=captcha);被拒的按官方样例退避 10 秒重试一次,但
	// 20 秒的搜索预算根本扛不住 N 个 goroutine 各自跑一遍"发请求→等 10 秒→重试"。持有
	// 这把锁横跨"读磁盘 + 必要时发网络请求"整段,其余 goroutine 直接排队,而不是各自
	// 再抢一次网络——16 个并发请求因此变成至多 1~2 次真实的 token.get。
	musixmatchTokenFetchMu sync.Mutex

	// musixmatchLastFailureMu/musixmatchLastFailureReason:诊断用的只读旁路
	// (2026-08-31,跟 ytmusic.go 的 ytmusicLastFailureReason 同一个思路,同一个理由——
	// 不改 musixmatchLyric 的返回值形状,自动解析路径从来不需要"为什么没查到"这个原因,
	// 只给设置页"测试这个源"功能多开一条只读旁路)。2026-08-31 实测坐实:反爬对连续
	// token.get 请求会限流,第一次成功之后几秒内的请求原样返回 HTTP 200,但 body 是
	// `status_code:401, hint:"captcha"`——上面 musixmatchFetchToken 早就在检测这个信号
	// 并退避重试,只是重试失败之后什么原因都没往外传。
	musixmatchLastFailureMu     sync.Mutex
	musixmatchLastFailureReason string
)

func musixmatchSetLastFailureReason(reason string) {
	musixmatchLastFailureMu.Lock()
	musixmatchLastFailureReason = reason
	musixmatchLastFailureMu.Unlock()
}

// musixmatchLastFailureReasonNow 供 test-lyric-sources 用——本次进程里最近一次识别出的
// 具体失败原因,识别不出就是空串。
func musixmatchLastFailureReasonNow() string {
	musixmatchLastFailureMu.Lock()
	defer musixmatchLastFailureMu.Unlock()
	return musixmatchLastFailureReason
}

// musixmatchDoFetchToken 是"真的去换一个新 token"这一步,musixmatchEnsureToken 在单飞锁
// 里调它。nil(默认)= 用真正的实现 musixmatchFetchToken。声明成变量是给测试留的缝——
// TestMusixmatchEnsureTokenSingleFlight 换成一个不碰网络、只计次的桩,验证单飞锁本身
// 生效(这台机器的网络/反爬状态是不确定的,拿它当测试前提会让用例变得不可复现)。
//
// ⚠️ 不能写成 `var musixmatchDoFetchToken = func(ctx context.Context) string { return musixmatchFetchToken(ctx, 0) }`——
// 那样会形成一条初始化环:该变量的初始化表达式引用 musixmatchFetchToken,
// 它调 musixmatchDo,musixmatchDo 又调 musixmatchEnsureToken,
// 而 musixmatchEnsureToken 引用回这个变量,`go build` 直接报
// "initialization cycle"。留空、调用处判 nil 就没有这个环。
var musixmatchDoFetchToken func(ctx context.Context) string

// musixmatchCachedToken 只读当前内存里的 token,不碰磁盘/网络。命中就直接返回,让绝大多数
// 调用(token 仍在有效期内)完全绕开下面的单飞锁——那把锁只在需要真的刷新时才有意义。
func musixmatchCachedToken() string {
	musixmatchTokenMu.Lock()
	defer musixmatchTokenMu.Unlock()
	if musixmatchToken != "" && time.Now().Before(musixmatchTokenExpiry) {
		return musixmatchToken
	}
	return ""
}

func musixmatchLyric(ctx context.Context, artist, title string, durationSecs float64, trLang string) musixmatchResult {
	if title == "" {
		return musixmatchResult{}
	}
	key := artist + "|" + title + "|" + trLang
	musixmatchMu.Lock()
	if v, ok := musixmatchCache[key]; ok {
		musixmatchMu.Unlock()
		return v
	}
	musixmatchMu.Unlock()

	r := resolveMusixmatchLyric(ctx, artist, title, durationSecs, trLang)
	if r.lrc != "" {
		musixmatchMu.Lock()
		musixmatchCache[key] = r
		musixmatchMu.Unlock()
	}
	return r
}

func resolveMusixmatchLyric(ctx context.Context, artist, title string, durationSecs float64, trLang string) musixmatchResult {
	_ = durationSecs // 时长匹配交给 enrich.go 统一的 scoreLyricCandidate,这里不用
	match, ok := musixmatchSearchTrack(ctx, artist, title)
	if !ok {
		return musixmatchResult{}
	}
	// hasSubtitles==false 时**不发** track.subtitle.get:那一趟按契约必然 404(见
	// pickMusixmatchTrackRow),白等一个网络往返。有 subtitles 却取回空仍照旧往下走纯文本
	// 回退 —— 那是"说有却拿不到"的异常,不是"本来就没有"。
	var lrc string
	if match.hasSubtitles {
		lrc = musixmatchSubtitleLRC(ctx, match.trackID)
	}
	if lrc == "" {
		// ⚠️ **纯文本回退**(2026-09-02,Charlie Musselwhite《Storm Warning》案)。
		//
		// 在此之前这里直接 `return musixmatchResult{}` —— 只要 track.subtitle.get(带时间戳
		// 的字幕)拿不到,整个 Musixmatch 源就当没有。可 Musixmatch 的曲目元数据本来就分
		// **两个独立字段**:has_subtitles(有没有做时间轴)和 has_lyrics(有没有词)。凡是
		// `has_lyrics=1 / has_subtitles=0` 的歌,词就在 track.lyrics.get 里躺着,而我们从来
		// 不问那个接口。
		//
		// 实测坐实的那一首:Charlie Musselwhite《Storm Warning》(专辑 Look Out Highway,
		// 2025-05-16 发行)。track.subtitle.get 回 404,track.lyrics.get 回 200 + 616 字
		// 完整歌词。八个源全查一遍的结果是"都没找到",而其实词一直在。这类"新专辑,平台
		// 收了音频但没人做时间轴"的情况,Musixmatch 往往是唯一有词的那个源 —— 它是西方
		// 曲库覆盖最好的一个,这个洞的影响面不止一首歌。
		//
		// 走的是既有的 plainOnly 通道(lrclib 2026-08-30 起就在喂),不是新造一条路:分数
		// 钉死 -1、绝不被自动解析选中,只在「搜索候选歌词」弹窗里带「无时间戳」标签出现,
		// 由用户决定采不采纳。
		plain := musixmatchPlainLyrics(ctx, match.trackID)
		if plain == "" {
			return musixmatchResult{}
		}
		// 纯文本这条路**不取逐字、不取译文**:richsync 是逐字时间轴(没有字幕就更不会有),
		// 而 musixmatchTranslationLRC 是把译文按行贴回带时间戳的 LRC —— 喂一份没有时间戳
		// 的正文给它只会产出畸形结果。
		//
		// isTimedLRC 这道兜底:track.lyrics.get 按契约给的是无时间戳正文,万一哪天回了带
		// 时间戳的内容,把它标成 plainOnly 等于把一份能自动采纳的歌词降级成"要用户手点",
		// 是净损失 —— 那种情况按正常候选返回。
		if isTimedLRC(plain) {
			return musixmatchResult{lrc: plain, title: match.title, artist: match.artist, album: match.album, cover: match.cover, durationSecs: match.durationSecs}
		}
		return musixmatchResult{lrc: plain, plainOnly: true, title: match.title, artist: match.artist, album: match.album, cover: match.cover, durationSecs: match.durationSecs}
	}
	yrc := musixmatchRichsync(ctx, match.trackID)
	tr := musixmatchTranslationLRC(ctx, match.trackID, lrc, trLang)
	return musixmatchResult{lrc: lrc, yrc: yrc, tr: tr, title: match.title, artist: match.artist, album: match.album, cover: match.cover, durationSecs: match.durationSecs}
}

// musixmatchEnsureToken 返回一个可用的 usertoken——已缓存且未过期直接复用,否则重新
// 获取。10 分钟官方有效期,提前 1 分钟当作过期主动换新,避免临界点上请求刚发出就失效。
func musixmatchEnsureToken(ctx context.Context) string {
	if t := musixmatchCachedToken(); t != "" {
		return t
	}
	// 单飞:见 musixmatchTokenFetchMu 的注释。排队等这把锁的这段时间里,前一个持锁者
	// 可能已经把 token 换好了,所以拿到锁之后**必须**重新查一遍缓存,不能想当然地
	// 认为"轮到我就说明还没人换过"——那样会让排在后面的 goroutine 也各发一次网络请求,
	// 单飞锁就白加了。
	musixmatchTokenFetchMu.Lock()
	defer musixmatchTokenFetchMu.Unlock()
	if t := musixmatchCachedToken(); t != "" {
		return t
	}
	// 内存里没有就先看磁盘 —— 见 musixmatchTokenPath 的注释:一次性的 search-lyrics CLI
	// 每次都是新进程,只靠内存缓存等于每次都要重新 token.get,而那个接口一被拒整个源就哑了。
	if t := musixmatchLoadTokenFile(); t != "" {
		return t
	}
	if musixmatchDoFetchToken != nil {
		return musixmatchDoFetchToken(ctx)
	}
	return musixmatchFetchToken(ctx, 0)
}

// musixmatchTokenPath 是 token 的磁盘缓存位置。
//
// 2026-08-09 实测:250 首抽样里 Musixmatch 只在 5% 出现过,连 Billie Jean、Hello 这种它
// 必然收录的歌都拿不到。原因不在匹配,在鉴权 —— 匿名 usertoken 只缓存在**进程内存**里、
// 官方有效期 10 分钟,而"搜索候选歌词"走的是一次性子进程:每调一次都要重新 token.get,
// 一密集就撞 401(官方样例的做法是退避 10 秒重试一次,再失败就放弃),于是这个源整个失效。
// 常驻的采集器能复用那份内存缓存,一次性 CLI 不能 —— 这正是它在自动解析里勉强能用、在
// 手动搜索里几乎从不出现的原因。
//
// 落盘之后两条路径共用同一个 token,10 分钟内不管起多少个进程都只取一次。
func musixmatchTokenPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", clientName, clientName+"-musixmatch-token.json")
}

type musixmatchTokenFile struct {
	Token  string `json:"token"`
	Expiry int64  `json:"expiry"`
}

func musixmatchLoadTokenFile() string {
	path := musixmatchTokenPath()
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var f musixmatchTokenFile
	if json.Unmarshal(raw, &f) != nil || f.Token == "" {
		return ""
	}
	if time.Now().Unix() >= f.Expiry {
		return ""
	}
	musixmatchTokenMu.Lock()
	musixmatchToken = f.Token
	musixmatchTokenExpiry = time.Unix(f.Expiry, 0)
	musixmatchTokenMu.Unlock()
	return f.Token
}

func musixmatchSaveTokenFile(token string, expiry time.Time) {
	path := musixmatchTokenPath()
	if path == "" {
		return
	}
	raw, err := json.Marshal(musixmatchTokenFile{Token: token, Expiry: expiry.Unix()})
	if err != nil {
		return
	}
	// 先写临时文件再 rename:两个进程同时刷新 token 时不会读到半份内容。临时文件名带
	// 进程号,否则并发的两个写入方会互相覆盖同一个 tmp,rename 出去的可能是半份别人的。
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if os.WriteFile(tmp, raw, 0o600) != nil {
		return
	}
	if os.Rename(tmp, path) != nil {
		os.Remove(tmp)
	}
}

// musixmatchFetchToken 请求一个新 token。401 表示这次匿名请求被限流/拒绝,官方样例
// (syncedlyrics)的做法是退避 10 秒重试一次——这里只重试一次(retry>=1 就放弃),不
// 无限重试卡住调用方。
func musixmatchFetchToken(ctx context.Context, retry int) string {
	if retry > 1 {
		return ""
	}
	body, err := musixmatchDo(ctx, "token.get", neturl.Values{"user_language": {"en"}})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				UserToken string `json:"user_token"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil {
		return ""
	}
	if out.Message.Header.StatusCode == 401 {
		// 2026-08-31 实测坐实的具体原因,见 musixmatchLastFailureReason 声明处注释——
		// 先记下来再退避重试,不管重试成不成功,这一拍"是反爬拒的"这个事实已经发生过。
		// 存的是稳定代码不是文案,见 lyricsourcefailure.go 头注,两侧必须同步维护。
		musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchRateLimited)
		select {
		case <-time.After(10 * time.Second):
		case <-ctx.Done():
			return ""
		}
		return musixmatchFetchToken(ctx, retry+1)
	}
	token := out.Message.Body.UserToken
	if token == "" {
		return ""
	}
	expiry := time.Now().Add(9 * time.Minute)
	musixmatchTokenMu.Lock()
	musixmatchToken = token
	musixmatchTokenExpiry = expiry
	musixmatchTokenMu.Unlock()
	musixmatchSaveTokenFile(token, expiry)
	return token
}

// musixmatchHTTPClient 是这个源专用的 HTTP client —— 走 DoH 解析(见 doh.go)。
//
// 只建一次:http.Transport 自带连接池和 TLS 会话复用,每次请求现造一个等于每次都重新
// 握手,而这个源一首歌要打 search/subtitle/richsync/translations 好几次。
var (
	musixmatchClientOnce sync.Once
	musixmatchClient     *http.Client
)

func musixmatchHTTPClient() *http.Client {
	musixmatchClientOnce.Do(func() {
		// onBlocked:直连被打掉、系统代理也救不回来时,给设置页那颗「测试」按钮留一个
		// 比通用 no_response 准确得多的原因 —— 那两种情况在界面上长得一样("这个源没
		// 反应"),但用户该做的事完全不同(一个是等,一个是去开代理)。
		musixmatchClient = dohHTTPClient(func() {
			musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchDirectBlocked)
		})
	})
	return musixmatchClient
}

// musixmatchDo 发起一次带统一身份参数(app_id/usertoken/t)的请求。action=="token.get"
// 时不附带 usertoken(避免 musixmatchEnsureToken→musixmatchDo→musixmatchEnsureToken
// 递归),其余 action 都需要先有一个可用 token。
func musixmatchDo(ctx context.Context, action string, params neturl.Values) ([]byte, error) {
	if action != "token.get" {
		if token := musixmatchEnsureToken(ctx); token != "" {
			params.Set("usertoken", token)
		}
	}
	params.Set("app_id", musixmatchAppID)
	params.Set("t", strconv.FormatInt(time.Now().UnixMilli(), 10))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, musixmatchBaseURL+action+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	// 走 DoH 解析的 client:这台机器的系统 DNS 把 apic-*.musixmatch.com 解析到了一个
	// 不属于 Musixmatch 的地址,TLS 握手直接失败,整个源静默失效。详见 doh.go。
	// 证书仍按域名严格校验,只是拨号目标换成 DoH 查出来的真实 IP。
	resp, err := doHTTPTracked(musixmatchHTTPClient(), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("musixmatch %s: status %d", action, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// musixmatchTrackMatch 是 musixmatchSearchTrack 选中的候选——title/artist/album/cover
// 是 track.search 响应本身自带的字段(album_name/album_coverart_500x500,实测坐实真的
// 存在,不是猜的),本来就已经查到,只是原来只取了 trackID 就把其余字段丢了。
type musixmatchTrackMatch struct {
	trackID                     int64
	title, artist, album, cover string
	durationSecs                float64 // musixmatch 自报的曲长,0=没给
	// hasSubtitles:这首歌在 Musixmatch 上有没有**做过时间轴**。2026-09-02 加。
	// false 时 track.subtitle.get 必然 404,调用方直接跳过那一趟、去问纯文本接口。
	hasSubtitles bool
}

// musixmatchTrackRow 是 track.search 响应里的一条曲目。抽成命名类型是为了让挑选逻辑
// (pickMusixmatchTrackRow)能脱离网络单测——那道 has_subtitles 闸门 2026-09-02 放宽过
// 一次,而它原来内联在只能联网跑的函数里,改错了没有任何测试会红。
type musixmatchTrackRow struct {
	TrackID              int64  `json:"track_id"`
	TrackName            string `json:"track_name"`
	ArtistName           string `json:"artist_name"`
	AlbumName            string `json:"album_name"`
	AlbumCoverart500x500 string `json:"album_coverart_500x500"`
	HasSubtitles         int    `json:"has_subtitles"`
	// HasLyrics:有没有词(跟 HasSubtitles 是**两个独立字段**)。2026-09-02 才开始读——
	// 在此之前只认 HasSubtitles==1,于是"有词但没做时间轴"的歌在搜索这一步就被跳过,
	// 整个 Musixmatch 源对它们等于不存在。见 pickMusixmatchTrackRow。
	HasLyrics int `json:"has_lyrics"`
	// TrackLength:musixmatch 自报的曲长(秒)。2026-08-22 补上解析。
	// 在此之前五个源里只有它的候选永远没有 sourceReportedDurationSecs,
	// 于是新增的 sourceDurationOff(-400)对它**系统性免罚** —— 而它恰恰
	// 是五源里匹配最松的一个(既不看专辑也不看时长,resolveMusixmatchLyric
	// 第一行还把 durationSecs 直接丢掉)。对抗性复核实测:52 个"musixmatch
	// 有有效候选"的缓存条目里,按 max() 口径偏差 >12% 的有 7 条(13.5%),
	// 其余四源合计 4.3%。字段本来就在响应里 —— 那不是"没有证据",是证据没被读。
	TrackLength int `json:"track_length"`
}

// pickMusixmatchTrackRow 从一批搜索结果里挑出这首歌。纯函数,给单测直接覆盖。
//
// **两趟**,顺序不能反(2026-09-02):
//   - 第一趟只认 has_subtitles==1 —— 跟放宽之前逐字节一致,有时间轴的永远优先;
//   - 第一趟空手时才走第二趟,认 has_lyrics==1 的"只有纯文本"候选。
//
// 为什么要有第二趟:Musixmatch 把"有没有时间轴"和"有没有词"记成两个独立字段。原来这里
// 只认前者(注释写的理由是"没有逐行歌词的候选后面 track.subtitle.get 必然 404,不必跑
// 这一趟"),推理没错但**结论过头**了 —— 那些候选确实拿不到字幕,可它们的词就在
// track.lyrics.get 里。实测 Charlie Musselwhite《Storm Watch…》(Storm Warning,专辑
// Look Out Highway,2025-05-16):has_lyrics=1 / has_subtitles=0,subtitle 回 404、
// lyrics 回 616 字完整歌词,而八源搜索的结果是"都没找到"。
//
// 两趟不能合成一趟按分排序:合起来的话,一条"有词无时间轴"的候选可能因为排在前面就顶掉
// 后面那条有时间轴的,把一份能自动采纳的歌词降级成要用户手点的纯文本,是净损失。
func pickMusixmatchTrackRow(rows []musixmatchTrackRow, artist, localTitle string) (musixmatchTrackMatch, bool) {
	accept := func(r musixmatchTrackRow) bool {
		return lyricTitleAccepted(r.TrackName, localTitle) && lyricSourceArtistMatches(r.ArtistName, artist)
	}
	build := func(r musixmatchTrackRow) musixmatchTrackMatch {
		return musixmatchTrackMatch{
			trackID:      r.TrackID,
			title:        r.TrackName,
			artist:       r.ArtistName,
			album:        r.AlbumName,
			cover:        r.AlbumCoverart500x500,
			durationSecs: float64(r.TrackLength),
			hasSubtitles: r.HasSubtitles == 1,
		}
	}
	for _, r := range rows {
		if r.HasSubtitles == 1 && accept(r) {
			return build(r), true
		}
	}
	for _, r := range rows {
		if r.HasLyrics == 1 && accept(r) {
			return build(r), true
		}
	}
	return musixmatchTrackMatch{}, false
}

// musixmatchSearchTrack 按歌手+歌名分字段搜索(q_artist/q_track,不是拼成一个字符串的
// q——实测同一首歌用分字段搜索时,官方原唱排第一;拼成一个字符串搜索,排在前面的经常是
// 同名翻唱/伴奏/合集这类噪音,即使歌手歌名都对得上字符串也不是真正想要的那个版本)。
// s_track_rating=desc 让热门/权威版本排前面,进一步降低选到冷门错误版本的概率。取第一条
// 歌手/歌名都对上、且 has_subtitles==1(没有逐行歌词的候选后面 track.subtitle.get 必然
// 404,不必跑这一趟)的结果。
// 搜索词按 searchTitleVariants 逐个试,先命中先返回(顺序跟设置走,见那边注释)。
// Musixmatch 在这一点上是五个源里最温和的:带括号仍能回 1~2 条、而且往往就是对的那条,
// 不像 QQ 直接 0 条、酷狗回一堆热门歌。但实测(2026-08-09)差距确实存在——
// "Billie Jean (Single Version)" 带括号回 1 条、去括号回 5 条(page_size 上限),
// 候选池小一截就更容易被 has_subtitles/歌手名这两道门全部筛光。多打的这一次请求只在
// 第一次一无所获时才发生,命中时零额外开销。
func musixmatchSearchTrack(ctx context.Context, artist, title string) (musixmatchTrackMatch, bool) {
	for _, q := range searchTitleVariants(title) {
		// 判定用的始终是本地原样标题 title,q 只是搜索词。
		if m, ok := musixmatchSearchTrackOnce(ctx, artist, q, title); ok {
			return m, true
		}
	}
	return musixmatchTrackMatch{}, false
}

func musixmatchSearchTrackOnce(ctx context.Context, artist, queryTitle, localTitle string) (musixmatchTrackMatch, bool) {
	body, err := musixmatchDo(ctx, "track.search", neturl.Values{
		"q_artist":       {artist},
		"q_track":        {queryTitle},
		"s_track_rating": {"desc"},
		"page_size":      {"5"},
		"page":           {"1"},
	})
	if err != nil {
		return musixmatchTrackMatch{}, false
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				TrackList []struct {
					Track musixmatchTrackRow `json:"track"`
				} `json:"track_list"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return musixmatchTrackMatch{}, false
	}
	rows := make([]musixmatchTrackRow, 0, len(out.Message.Body.TrackList))
	for _, t := range out.Message.Body.TrackList {
		rows = append(rows, t.Track)
	}
	return pickMusixmatchTrackRow(rows, artist, localTitle)
}

// musixmatchSubtitleLRC 取该 track_id 官方的逐行 LRC 歌词,当作候选正文。
// musixmatchPlainLyrics 取**没有时间戳**的纯文本歌词(track.lyrics.get)。
//
// 只在 musixmatchSubtitleLRC 空手而归时才调,理由见 resolveMusixmatchLyric 里那段注释。
// Musixmatch 把"有没有时间轴"和"有没有词"记成两个独立字段(has_subtitles / has_lyrics),
// 这个接口对应后者。
//
// restricted / instrumental 非 0 时返回空:前者是版权受限(正文可能是占位或空串),后者是
// 平台明确说"这是纯音乐"——两种都不该当成歌词端出去。⚠️ instrumental 这里只是**不返回
// 歌词**,不往上报"这是纯音乐"的结论:那个结论有自己的一套跨源优先级(见 enrich.go 的
// instrumentalMarker),不从这里开新口子。
func musixmatchPlainLyrics(ctx context.Context, trackID int64) string {
	body, err := musixmatchDo(ctx, "track.lyrics.get", neturl.Values{
		"track_id": {strconv.FormatInt(trackID, 10)},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Lyrics struct {
					LyricsBody   string `json:"lyrics_body"`
					Restricted   int    `json:"restricted"`
					Instrumental int    `json:"instrumental"`
				} `json:"lyrics"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	l := out.Message.Body.Lyrics
	if l.Restricted != 0 || l.Instrumental != 0 {
		return ""
	}
	return sanitizeMusixmatchPlainLyrics(l.LyricsBody)
}

// sanitizeMusixmatchPlainLyrics 清洗 track.lyrics.get 的正文。纯函数,给单测直接覆盖。
//
// ⚠️ **本项目用的这组身份(apic-appmobile + mac-ios-v2.0)实测不带商用免责水印**
// (2026-09-02 抓 Charlie Musselwhite《Storm Warning》核实:24 行 616 字,末行就是最后
// 一句歌词,没有 `*******` 围栏、没有 `(1409...)` 追踪号)。网上大多数参考实现描述的那个
// 水印是 `web-desktop-app-v1.0` 那组才有的,**不要**照那个说法当成既成事实。
//
// 那为什么还写剥离:代价是几行纯字符串处理,收益是万一 Musixmatch 改了行为、或者某些
// 曲目/地区确实带水印时,不会把免责声明当歌词正文端给用户。剥离规则只认**极其特征化**
// 的两种形态(整行都是星号的围栏、以及 "not for commercial use" 那句),不做模糊猜测,
// 不会误伤正常歌词。
func sanitizeMusixmatchPlainLyrics(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	kept := make([]string, 0, len(lines))
	for _, ln := range lines {
		if musixmatchNoticeLine(ln) {
			break // 水印一旦出现,它和它后面的东西全不是歌词
		}
		kept = append(kept, ln)
	}
	// 尾部单独一行的追踪号 `(1409618012345)`——水印围栏缺失、只剩这一行时的兜底。
	for len(kept) > 0 {
		last := strings.TrimSpace(kept[len(kept)-1])
		if last == "" || musixmatchTrackingNumberLine(last) {
			kept = kept[:len(kept)-1]
			continue
		}
		break
	}
	return strings.TrimSpace(strings.Join(kept, "\n"))
}

// musixmatchNoticeLine:这一行是不是水印区的起点。
func musixmatchNoticeLine(line string) bool {
	t := strings.TrimSpace(line)
	if t == "" {
		return false
	}
	if strings.Count(t, "*") >= 3 && strings.Trim(t, "*") == "" {
		return true // 整行都是星号的围栏
	}
	return strings.Contains(strings.ToLower(t), "not for commercial use")
}

// musixmatchTrackingNumberLine:形如 `(1409618012345)` 的纯数字追踪号行。
//
// ⚠️ 要求整行**只有**括号加数字,不能放宽 —— 歌词里出现 `(2)`、`(x3)` 这类标注是常事,
// 放宽了会把真歌词吃掉。长度下限取 6 位,把 `(2)` 这种彻底排除在外。
func musixmatchTrackingNumberLine(t string) bool {
	if !strings.HasPrefix(t, "(") || !strings.HasSuffix(t, ")") {
		return false
	}
	inner := t[1 : len(t)-1]
	if len(inner) < 6 {
		return false
	}
	for _, r := range inner {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func musixmatchSubtitleLRC(ctx context.Context, trackID int64) string {
	body, err := musixmatchDo(ctx, "track.subtitle.get", neturl.Values{
		"track_id":        {strconv.FormatInt(trackID, 10)},
		"subtitle_format": {"lrc"},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Subtitle struct {
					SubtitleBody string `json:"subtitle_body"`
				} `json:"subtitle"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	lrc := out.Message.Body.Subtitle.SubtitleBody
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}

type musixmatchRichsyncWord struct {
	C string  `json:"c"` // 词文本
	O float64 `json:"o"` // 相对所在行行始的偏移,秒
}

type musixmatchRichsyncLine struct {
	Ts float64                  `json:"ts"` // 行始,绝对秒数(从曲目开头算起)
	Te float64                  `json:"te"` // 行末,绝对秒数——实测该字段总是有值,优先用它
	L  []musixmatchRichsyncWord `json:"l"`
}

// musixmatchRichsync 取该 track_id 的逐字(词级)时间轴,归一化成 YRCParser
// (desktop-lyrics)认识的语法。查不到/该曲目没有逐字数据都返回空串,不影响
// musixmatchSubtitleLRC 已经拿到的逐行结果——跟 kugouLyric 的"逐字是加分项,没有不影响
// 整行可用"策略一致。
func musixmatchRichsync(ctx context.Context, trackID int64) string {
	body, err := musixmatchDo(ctx, "track.richsync.get", neturl.Values{
		"track_id": {strconv.FormatInt(trackID, 10)},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Header struct {
				StatusCode int `json:"status_code"`
			} `json:"header"`
			Body struct {
				Richsync struct {
					RichsyncBody string `json:"richsync_body"`
				} `json:"richsync"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || out.Message.Header.StatusCode != 200 {
		return ""
	}
	raw := out.Message.Body.Richsync.RichsyncBody
	if raw == "" {
		return ""
	}
	var lines []musixmatchRichsyncLine
	if json.Unmarshal([]byte(raw), &lines) != nil || len(lines) == 0 {
		return ""
	}
	return richsyncToYRC(lines)
}

// richsyncToYRC 把 Musixmatch richsync 的行/词绝对时间戳(ts+o,单位秒)转换成
// YRCParser 语法"[行始ms,行长ms](词始ms,词长ms,flag)词"——跟网易云原生 YRC 一样,
// 词始时间戳本来就是绝对值,不需要像酷狗 KRC 那样做相对转绝对的换算(见 krcToYRC
// 注释)。行末优先用 richsync 自带的 te 字段(实测总是有值,行末的绝对秒数);词长
// 则按"到下一个词开始"反推(richsync 不直接给词长)——最后一个词没有下一个词可以
// 反推,退到这一行的行末(te)兜底,只影响 fillFraction 的上限,不影响已经唱到的
// 部分对不对得上。
func richsyncToYRC(lines []musixmatchRichsyncLine) string {
	var b strings.Builder
	for _, ln := range lines {
		lineStartMs := int64(ln.Ts * 1000)
		lineEndMs := int64(ln.Te * 1000)
		if lineEndMs < lineStartMs {
			lineEndMs = lineStartMs
		}
		// 纯空白词条不独立成词(2026-08-19 用户报"有些单词没有读条直接填满"):
		// richsync 把空格作为**独立计时条目**,而空格占走了前一个词的绝大部分演唱时长
		// (实测《Ocho Rios》"In" 23ms + 空格 165ms)——词长按"到下一个条目"反推时,
		// 短词全被空格掏空,悬浮窗 20~50ms 填完一个词,观感就是"瞬间填满"。归并规则:
		// 空白条目的文本并入前一个词尾部,词长反推自然改成"到下一个**非空白**词条";
		// 行首就是空白的(理论情形)给下一个词当前缀。存量缓存的同款清洗见
		// yrcMergeWhitespaceTokens(yrcwhitespace.go)。
		type mergedWord struct {
			startMs int64
			text    string
		}
		words := make([]mergedWord, 0, len(ln.L))
		prefix := ""
		for _, w := range ln.L {
			if strings.TrimSpace(w.C) == "" {
				if n := len(words); n > 0 {
					words[n-1].text += w.C
				} else {
					prefix += w.C
				}
				continue
			}
			words = append(words, mergedWord{lineStartMs + int64(w.O*1000), prefix + w.C})
			prefix = ""
		}
		fmt.Fprintf(&b, "[%d,%d]", lineStartMs, lineEndMs-lineStartMs)
		for j, w := range words {
			var wordEndMs int64
			if j+1 < len(words) {
				wordEndMs = words[j+1].startMs
			} else {
				wordEndMs = lineEndMs
			}
			if wordEndMs < w.startMs {
				wordEndMs = w.startMs
			}
			fmt.Fprintf(&b, "(%d,%d,0)%s", w.startMs, wordEndMs-w.startMs, w.text)
		}
		b.WriteByte('\n')
	}
	return b.String()
}

type musixmatchTranslationItem struct {
	Translation struct {
		SubtitleMatchedLine string `json:"subtitle_matched_line"`
		Description         string `json:"description"`
	} `json:"translation"`
}

var musixmatchLRCLineRe = regexp.MustCompile(`^(\[\d{1,2}:\d{2}[.:]\d{1,3}\])(.*)$`)

// musixmatchTranslationLRC 取该 track_id 的社区翻译(crowd.track.translations.get),
// 目标语言由 lang 指定(ISO 639-1 两位小写代码,如 "en"/"es"/"ja"——见
// FeatureSettingsStore.swift 的 MusixmatchTranslationLanguage)。lang 为空(用户没有
// 启用 Musixmatch 或没配置译文语言)直接跳过,不发这次请求。
func musixmatchTranslationLRC(ctx context.Context, trackID int64, originalLRC, lang string) string {
	if lang == "" {
		return ""
	}
	body, err := musixmatchDo(ctx, "crowd.track.translations.get", neturl.Values{
		"track_id":               {strconv.FormatInt(trackID, 10)},
		"subtitle_format":        {"lrc"},
		"translation_fields_set": {"minimal"},
		"selected_language":      {lang},
	})
	if err != nil {
		return ""
	}
	var out struct {
		Message struct {
			Body struct {
				TranslationsList []musixmatchTranslationItem `json:"translations_list"`
			} `json:"body"`
		} `json:"message"`
	}
	if json.Unmarshal(body, &out) != nil || len(out.Message.Body.TranslationsList) == 0 {
		return ""
	}
	tr := buildTranslatedLRC(originalLRC, out.Message.Body.TranslationsList)
	if !isTimedLRC(tr) {
		return ""
	}
	return tr
}

// buildTranslatedLRC 把 crowd.track.translations.get 返回的"原文行→译文"逐条映射,
// 拼成一份跟原文歌词时间轴对齐的独立 LRC——用原文歌词自己的时间戳(Swift 侧
// LyricsSyncEngine 用 nearestText 按时间戳就近匹配展示译文,不是按行号对应,见
// enrich.go scoredLyricCandidates 里网易云 tr/roma 的同一套用法)。翻译覆盖不全(有些
// 行没有社区翻译)是正常情况,缺的行译文那里就没有对应时间戳,不强行补全。
//
// 外层按原文歌词的时间顺序遍历(不是按 items 本来的顺序)——重复的副歌歌词在原文里
// 会出现好几次,每次出现独立去找一条能对上的翻译,而不是"翻译列表里同一条译文命中了
// 原文第一次出现的位置就不再找第二次"。实测遇到过反过来遍历(items 在外层)会导致
// 多条翻译条目都模糊匹配到原文同一次出现、生成好几行时间戳重复的译文;这样写从根上
// 避免这个问题,顺带让输出天然按时间戳升序(nearestText 的匹配结果不依赖顺序,但升序
// 更符合一份 LRC 文件该有的样子)。
func buildTranslatedLRC(originalLRC string, items []musixmatchTranslationItem) string {
	var parsed []struct{ ts, text string }
	for _, l := range strings.Split(strings.ReplaceAll(originalLRC, "\r\n", "\n"), "\n") {
		m := musixmatchLRCLineRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		parsed = append(parsed, struct{ ts, text string }{ts: m[1], text: strings.TrimSpace(m[2])})
	}
	var b strings.Builder
	for _, p := range parsed {
		if p.text == "" {
			continue
		}
		for _, item := range items {
			matched := strings.TrimSpace(item.Translation.SubtitleMatchedLine)
			tr := strings.TrimSpace(item.Translation.Description)
			if matched == "" || tr == "" {
				continue
			}
			if p.text == matched || strings.Contains(p.text, matched) || strings.Contains(matched, p.text) {
				b.WriteString(p.ts)
				b.WriteString(tr)
				b.WriteByte('\n')
				break
			}
		}
	}
	return b.String()
}
