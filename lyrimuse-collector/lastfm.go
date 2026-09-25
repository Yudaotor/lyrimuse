// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// lastfmScrobbler 把 Mac 播放镜像写入 Last.fm(track.updateNowPlaying /
// track.scrobble)。跟文件里另一处"桥接"逻辑方向相反且互不影响:桥接是读 iPhone
// 已经 scrobble 到 Last.fm 的记录转发进 LB;这里是写 Mac 播放到 Last.fm,补全它作为
// 社交/统计门面时的历史。凭证是经一次性网页授权换取的永久 session key(sk)。
type lastfmScrobbler struct {
	apiKey, secret, sk string
	hc                 *http.Client
	// dead:session key / API key 已被 Last.fm 判死(error 9/10/26 一击、error 4 两击,
	// 见 shouldDisable)。置位后停止一切后续提交 —— 原来这种情况下每首歌照样白打 2 个
	// 注定失败的请求,且除了日志刷屏没有任何机制让用户知道 scrobble 早就全停了
	// 。进程重启(保存配置/重连账号都会 kickstart collector)
	// 自然复位。
	dead atomic.Bool
	// suspect4:第一次撞上 error 4(Authentication Failed)的时刻(UnixNano,0=无嫌疑)。
	// error 4 跟 9/10/26 不同:真撤销授权时它确实会出现,但 Last.fm 服务端不稳时也会
	// **误报**(实测:一上午 500/超时/DNS 失败之后来了一发 error 4,授权
	// 其实完好,进程重启后第一次提交就成功了——不重启的话镜像就永久停在一次误报上)。
	// 所以单发 error 4 只记嫌疑、不熔断;30s~30min 内再次撞上才坐实。真撤销时每次
	// 调用都失败,第二击最多半分钟就到,多打的请求屈指可数;换来的是孤立误报不再
	// 永久杀死镜像。成功一次即洗清嫌疑。
	suspect4 atomic.Int64
	// clearStatus:第一次提交成功时删掉上次运行留下的状态文件(有就删,没有白删一次),
	// sync.Once 保证整个进程生命周期只做一次这个 stat+remove。
	clearStatus sync.Once
	// catalog 是「智能」档的编目匹配器(见 lastfmcatalog.go),只在
	// features().LastfmScrobbleArtistMode == scrobbleArtistSmart 时被 resolveScrobbleTags
	// 调用;nil(没配只读 api_key)时该档整体退化成原样提交。
	catalog *lastfmCatalogMatcher
}

// newLastfmScrobbler 三者任一为空则不启用(返回 nil,调用方需判空跳过)。
func newLastfmScrobbler(apiKey, secret, sk string) *lastfmScrobbler {
	if apiKey == "" || secret == "" || sk == "" {
		return nil
	}
	return &lastfmScrobbler{apiKey: apiKey, secret: secret, sk: sk, hc: &http.Client{Timeout: 8 * time.Second}}
}

// lastfmScrobblerIfEnabled 是 newLastfmScrobbler 的唯一调用点(run() 里)，多包一层
// features().LastfmMirrorScrobble 开关——跟凭据判断是 AND 关系,任一为否都返回 nil。
func lastfmScrobblerIfEnabled(cfg *config) *lastfmScrobbler {
	if !features().LastfmMirrorScrobble {
		return nil
	}
	s := newLastfmScrobbler(cfg.LastfmScrobbleAPIKey, cfg.LastfmScrobbleSecret, cfg.LastfmScrobbleSessionKey)
	if s != nil {
		// 用**只读**的那把 api_key:track.getInfo 不需要签名/session key,判定这一步不碰写凭据。
		// 三档都建(匹配器只是读了一下缓存文件),档位在 resolveScrobbleTags 里判。
		s.catalog = newLastfmCatalogMatcher(cfg.lastfmBridgeAPIKey())
	}
	return s
}

// sign 实现 Last.fm 签名算法:参数(不含 format/callback)按 key 字母序拼接、末尾接
// shared secret,取 MD5 十六进制。
func (s *lastfmScrobbler) sign(params map[string]string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteString(params[k])
	}
	b.WriteString(s.secret)
	sum := md5.Sum([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

func (s *lastfmScrobbler) call(ctx context.Context, method string, params map[string]string) error {
	p := make(map[string]string, len(params)+2)
	for k, v := range params {
		p[k] = v
	}
	p["method"] = method
	p["api_key"] = s.apiKey
	p["sk"] = s.sk
	form := neturl.Values{}
	for k, v := range p {
		form.Set(k, v)
	}
	form.Set("api_sig", s.sign(p))
	form.Set("format", "json")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://ws.audioscrobbler.com/2.0/", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", clientName)
	resp, err := doHTTPTracked(s.hc, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	// Last.fm 的错误经常以 HTTP 200 + {"error":N,"message":...} 返回(读路径
	// LastfmAuthFlow.swift 早有同样的注释,写路径一直没做)——
	// 所以 200 和非 200 的 body 都要解析,先认 error 字段再看状态码。
	var out struct {
		Error     int    `json:"error"`
		Message   string `json:"message"`
		Scrobbles *struct {
			Attr struct {
				Accepted json.Number `json:"accepted"`
				Ignored  json.Number `json:"ignored"`
			} `json:"@attr"`
			// 单条 <scrobble> 里带着 ignoredMessage(code + 人话原因)。回填路径一直在
			// 解析它(backfill.go 的 scrobbleEntry/parseScrobbleEntries),活路径原来
			// 整个丢掉,只报一句笼统的 accepted=0 —— 排查那 5 条真实失败时
			// 只能靠翻日志上下文猜是哪首歌、为什么被拒,故补上,复用同一个解析器。
			Scrobble json.RawMessage `json:"scrobble"`
		} `json:"scrobbles"`
	}
	_ = json.Unmarshal(body, &out) // 解不开就当没有错误体,靠状态码兜底
	if out.Error != 0 {
		return &lastfmAPIError{Code: out.Error, Message: out.Message, Method: method}
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lastfm %s: status %d: %s", method, resp.StatusCode, body)
	}
	// track.scrobble 的"被忽略"也是 200:accepted=0,原来会被当成功。不算致命错误,
	// 但必须如实报出去让日志可见。
	//
	// 带上服务端给的真实原因。原来这句只报 accepted=0,排查时无从判断是
	// 哪一类拒收 —— 实测那 5 条里 3 条是空艺人名(彼时守卫还没加)、2 条是艺人名
	// "群星"(Various Artists,Last.fm 当非艺人拒收),两种成因的处置完全不同,却报同
	// 一句话。旧注释里"时间戳超两周"这条对活路径不成立(当场提交不可能超窗),那是从
	// 回填场景顺手抄来的猜测,一并删掉,不再写没有依据的成因。
	if out.Scrobbles != nil {
		if accepted, _ := out.Scrobbles.Attr.Accepted.Int64(); accepted == 0 {
			return &lastfmIgnoredError{Method: method, Reason: ignoredReason(out.Scrobbles.Scrobble)}
		}
	}
	return nil
}

// lastfmIgnoredError:请求到了服务端、服务端**看过并拒收**(HTTP 200 + accepted=0)。
//
// 单独成一个类型而不是 fmt.Errorf,是因为调用方要据此分流:这一类跟网络失败的处置完全
// 相反 —— 网络失败该留痕待补,被拒收的重发多少次都还是被拒,补提交是白费,只该把真实
// 原因暴露出来让人去改数据。判据见 poller.go 的 recordFailedMirror。
type lastfmIgnoredError struct {
	Method string
	Reason string // 服务端给的 ignoredMessage,可能为空
}

func (e *lastfmIgnoredError) Error() string {
	if e.Reason == "" {
		return fmt.Sprintf("lastfm %s: ignored by server (accepted=0)", e.Method)
	}
	return fmt.Sprintf("lastfm %s: ignored by server (accepted=0): %s", e.Method, e.Reason)
}

// ignoredReason 把回执里 <scrobble> 的 ignoredMessage 拼成一句可读的原因,拿不到就返回
// 空串。复用回填那边的 parseScrobbleEntries —— Last.fm 的 "一条是对象、多条是数组"
// 不一致由它吞掉。
func ignoredReason(raw json.RawMessage) string {
	entries := parseScrobbleEntries(raw)
	reasons := make([]string, 0, len(entries))
	for _, e := range entries {
		code := strings.TrimSpace(e.IgnoredMessage.Code)
		if code == "" || code == "0" {
			continue // 0 = 没被忽略,不该出现在这里,出现了也不当原因报
		}
		if text := strings.TrimSpace(e.IgnoredMessage.Text); text != "" {
			reasons = append(reasons, code+" "+text)
			continue
		}
		reasons = append(reasons, "code "+code)
	}
	return strings.Join(reasons, "; ")
}

// provablyNeverSent 判断这次失败是不是**可以证明请求从没离开本机**。
//
// 只有 DNS 解析失败和 dial 阶段失败算数:这两种情况下 TCP 连接根本没建立起来,服务端
// 不可能看见过这个请求,所以事后补提交绝不会造成重复。其余一律判 false(宁可漏判,
// 不可误判)—— 尤其 `context deadline exceeded`,不管卡在 dial 还是等回执,错误链里都
// **没有** *net.OpError(只有 http 自己的 timeoutError),自然落到 false 这边,正是想要的。
//
// 必须用类型断言,不能用 strings.Contains 匹配错误文案:networkobs.go 会重写
// 出网错误的文案,按字符串判会在它改写之后静默失效。
func provablyNeverSent(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return true
	}
	var opErr *net.OpError
	return errors.As(err, &opErr) && opErr.Op == "dial"
}

// lastfmAPIError 是 Last.fm 应用层错误(区别于网络/HTTP 错误)。
type lastfmAPIError struct {
	Code    int
	Message string
	Method  string
}

func (e *lastfmAPIError) Error() string {
	return fmt.Sprintf("lastfm %s: api error %d: %s", e.Method, e.Code, e.Message)
}

// fatal:这几个错误码属于"凭据级"错误 —— 4=Authentication Failed,9=Invalid session
// key(用户在网站上撤销了授权),10=Invalid API key,26=API key suspended。其余
// (服务暂时不可用/限流等)是暂时性的,永不熔断。注意 fatal 不直接等于熔断:error 4
// 需要复发确认(服务端不稳时会误报),裁决在 shouldDisable。
func (e *lastfmAPIError) fatal() bool {
	switch e.Code {
	case 4, 9, 10, 26:
		return true
	}
	return false
}

// mayHaveStored:这个错误码下,Last.fm **有可能已经落库、只是回执没回来**。
//
// 只有 11(Service Offline)/16(temporarily unavailable) 属于这一档 —— 沿用 runBackfill
// 头注释里已经定过的口径("Last.fm 可能已经落库而回执丢了,重发是最大的自造重复源"),
// 不在这里另立一套。其余的服务端明确表过态、**确定没落库**:凭据类(4/9/10/26)、
// 限流(29)、参数错误等,补提交安全。
//
// 用途见 recordFailedMirror:这一位决定失败的收听是"记下来等回填"还是"记下来但永不
// 自动重试"。判宽了(把确定没落库的当成可能落库)只是漏补一条;判窄了(把可能落库的
// 当成确定没落库)会在用户历史里造出永久删不掉的重复,两边代价不对称,存疑就往
// mayHaveStored=true 靠。
func (e *lastfmAPIError) mayHaveStored() bool {
	switch e.Code {
	case 11, 16:
		return true
	}
	return false
}

// shouldDisable 裁决这次 API 错误要不要熔断镜像:9/10/26 一击致命;4 要两击坐实
// (间隔 ≥confirmGap 才算第二击 —— 换歌那一刻 nowPlaying+scrobble 几乎同时各失败
// 一发,那是同一次故障;超过 suspectWindow 的旧嫌疑作废,隔了半天的两次孤立误报
// 不该累积成死刑)。并发安全:CAS 输了说明别的 goroutine 刚记下同一桩嫌疑,这一发
// 按 burst 处理返回 false 即可。
func (s *lastfmScrobbler) shouldDisable(apiErr *lastfmAPIError, now time.Time) bool {
	if !apiErr.fatal() {
		return false
	}
	if apiErr.Code != 4 {
		return true
	}
	const confirmGap = 30 * time.Second
	const suspectWindow = 30 * time.Minute
	prev := s.suspect4.Load()
	age := time.Duration(now.UnixNano() - prev)
	if prev != 0 && age >= confirmGap && age <= suspectWindow {
		return true
	}
	if prev == 0 || age > suspectWindow {
		s.suspect4.CompareAndSwap(prev, now.UnixNano())
	}
	return false
}

// durationParam 按官方口径把曲长转成 track.scrobble / track.updateNowPlaying 的
// `duration` 参数:**整数秒**,拿不到(<=0)就不发这个键 —— 它是选填的,发一个 0 或负数
// 比不发更糟。跟 backfill.go 那边 `if it.DUR > 0` 的处理逐字一致,两条路径别各写一套。
func durationParam(p map[string]string, key string, durationSecs float64) {
	if durationSecs > 0 {
		p[key] = strconv.FormatInt(int64(durationSecs), 10)
	}
}

// resolveScrobbleTags 决定这条提交实际发哪个歌手名 + 曲名。设置里是三档(账号 → Last.fm →
// 设置 → Scrobble 卡 →「匹配模式」:智能 / 自定义 / 原始),但档位在 features 那边已经
// **摊平成三个布尔**了(resolveLastfmMatch),这里只按布尔办事:
//
//   - LastfmMatchArtist / LastfmMatchTrack:允许把歌手 / 曲名改写成 Last.fm 编目条目的
//     写法(lastfmcatalog.go)。两个都 false 就不打网络。智能档 = 两个都 true。
//   - LastfmMatchFirstArtistOnly:合唱串截成第一位(firstCreditedArtist,纯字符串、不联网)。
//
// ## 截断只在**没匹配到**编目条目时应用
//
// 匹配到的写法已经是 Last.fm 编目认的那一条,再截一刀就把它变成一个不存在的条目 ——
// `Hall & Oates / Maneater`(80 万听众的正规合体条目)会被截成 `Hall`,比不改还糟。
// 所以顺序是:先匹配;匹配上了就用它、不再截断;没匹配上(keep / defer / 查询失败 / 压根
// 没开匹配)才轮到截断。「只开截断、不开匹配」因此跟旧的 `first` 档逐字等价。
//
// ## 为什么默认是「原始」
//
//   - ListenBrainz 文档明写合唱 credit 应当 "include them all";
//   - Navidrome 的同名开关 `Lastfm.ScrobbleFirstArtistOnly` 默认也是 false,其代码注释
//     说明这是给 Last.fm API 缺陷用的 workaround,不是正确性修复;
//   - 无条件截断会丢信息且不可逆(把 "Khalil Fong & Fiona Sit" 发成 "方大同",薛凯琪就没了),
//     而不截断最坏只是 Last.fm 上多一个听众很少的合唱条目 —— 代价不对称。匹配不是
//     无条件截断:它只在编目里真有更多人听的同一首歌时才改写。
//
// now-playing、scrobble、回填三条路径必须调**同一个**函数:否则会出现 "now playing 显示 A、
// 落库却是 A & B" 的自相矛盾状态。匹配下唯一允许的分歧见 lastfmcatalog.go「一致性」一节。
func resolveScrobbleTags(ctx context.Context, c *lastfmCatalogMatcher, artist, track string, durationSecs float64) (string, string) {
	scope := matchScope{artist: features().LastfmMatchArtist, track: features().LastfmMatchTrack}
	matchDuration := durationSecs
	if catalogDurationUnknown(ctx) {
		matchDuration = 0
	}
	artist, track, matched := c.resolve(ctx, artist, track, matchDuration, scope)
	if matched || !features().LastfmMatchFirstArtistOnly {
		return artist, track
	}
	if first := firstCreditedArtist(artist); first != "" {
		return first, track
	}
	return artist, track
}

// lastfmAlbumTag 决定往 Last.fm 发的专辑名。曲名按 Last.fm 编目写法发时(LastfmMatchTrack:
// 智能档恒开、自定义档的「曲名：匹配条目」)同时剥掉 Apple 给单曲 / EP 加的「 - Single」「 - EP」
// 后缀(trimSingleOrEPSuffix):Last.fm 把带后缀和不带后缀的当成两张专辑,专辑榜会被拆成两条。
// 曲名原样发时专辑名也原样。
//
// now-playing、scrobble、回填三条路径必须调这同一个函数(同 resolveScrobbleTags)。只管 Last.fm:
// ListenBrainz 的 release_name 与本地收听日志一律记原样,回填时再经这里改。见 12 章 §4。
func lastfmAlbumTag(album string) string {
	if !features().LastfmMatchTrack {
		return album
	}
	return trimSingleOrEPSuffix(album)
}

// mirrorTimeout 是 mirrorAsync 给一次 Last.fm 写入的总窗口。会联网匹配时多给判定那份
// 预算(lastfmCatalogBudget,含扩展搜索),免得判定把真正的写入挤掉;不匹配就维持 8 秒。
func mirrorTimeout() time.Duration {
	const write = 8 * time.Second
	if features().LastfmMatchArtist || features().LastfmMatchTrack {
		return write + lastfmCatalogBudget
	}
	return write
}

func (s *lastfmScrobbler) updateNowPlaying(ctx context.Context, artist, track, album string, durationSecs float64) error {
	artist, track = resolveScrobbleTags(ctx, s.catalog, artist, track, durationSecs)
	p := map[string]string{"artist": artist, "track": track}
	if album = lastfmAlbumTag(album); album != "" {
		p["album"] = album
	}
	// duration 让 Last.fm 知道这条"正在播放"该挂多久 —— 不给的话它只能自己猜一个默认
	// 时长,长曲子会提前掉、短曲子会挂太久。官方文档列了这个参数、标注选填。
	durationParam(p, "duration", durationSecs)
	return s.call(ctx, "track.updateNowPlaying", p)
}

func (s *lastfmScrobbler) scrobble(ctx context.Context, artist, track, album string, timestamp int64, durationSecs float64) error {
	// 正在播放和完成收听必须走同一次判定,否则 Last.fm 上会出现"now playing 是 A、
	// 落库却是 A & B"这种自相矛盾的状态。
	artist, track = resolveScrobbleTags(ctx, s.catalog, artist, track, durationSecs)
	p := map[string]string{"artist": artist, "track": track, "timestamp": strconv.FormatInt(timestamp, 10)}
	if album = lastfmAlbumTag(album); album != "" {
		p["album"] = album
	}
	// 补:这条**活路径**原来不发 duration,而 backfill.go:200 一直在发 ——
	// 同一首歌当场 scrobble 反而比事后回填少一个字段,编目匹配的输入不如回填全。两条
	// 路径本该给 Last.fm 同样的信息,没有任何理由分叉。
	//
	// 数据现成:调用方 mirrorScrobbleTracked 早就拿着 durationSecs(第 ① 条给失败留痕
	// 加的形参),不用为这个再改一遍调用链。
	durationParam(p, "duration", durationSecs)
	return s.call(ctx, "track.scrobble", p)
}

// mirrorAsync 异步、尽力而为地把一次 Last.fm 写入(track.updateNowPlaying /
// track.scrobble)镜像出去——不阻塞 poll 循环(Last.fm 可能慢/抽风)。goroutine 自带
// 超时上限,不会泄露(同 resolveEnrichAsync 的模式)。s==nil(未配置镜像凭证)时整体
// 跳过,call 不会被执行。
//
// onFail(可为 nil)在每一个失败分支上都被调用(包括入口处已熔断的短路、以及触发熔断的
// 这一次),让调用方决定这一条要不要留痕。
// 加它的理由(实测排查):
//
//	原来失败只打一行日志就完事,注释写的是"下一次 poll/scrobble 自然会覆盖"——那句话
//	对 now-playing 成立(瞬时状态,下一拍就盖掉),对 **scrobble 不成立**:一次收听只提交
//	这一次。而 mirrorScrobbleTracked 在发请求**之前**就把 uts 记进 lfmMirrored 并落盘
//	(防 bridge 抢跑),幂等守卫从此永久挡死这条;p.lfm != nil 时 appendListen 又被跳过。
//	三处同时不兜底 到 一次网络抖动 = 永久少一条 scrobble,且无处可查。用户真实日志里
//	2618 次成功收听对应 13 条这样的真丢失。
//
// onFail 跑在这个 goroutine 里,**只准碰自带锁的 listen log**(appendListen /
// markQuarantined,它们持 listenLogMu)。**绝不能碰 poller 的任何字段** —— 尤其
// p.lfmMirrored 是裸 map,主循环会经 persistedTTLSet.save 整个 range 它,并发写就是
// `fatal error: concurrent map iteration and map write`,recover 都救不回来;
// poller.go 顶部"所有状态变更只发生在 poll 主循环里"那条不变量必须守住。
func mirrorAsync(s *lastfmScrobbler, what string, call func(ctx context.Context) error, onFail func(error)) {
	if s == nil {
		return // 压根没配镜像凭证:这台机器不往 Last.fm 写,谈不上"失败",不留痕
	}
	if s.dead.Load() {
		// 凭据已被判死(见 shouldDisable):不再白打请求,但这一条**确定没写进去**,
		// 该留的痕照留 —— 否则用户重新授权之后,熔断那段时间的收听回填不回来。
		// listenlog.go 的 M 字段注释把这个窗口记成"刻意接受的漏补",现在有
		// recordFailedMirror 就不必再接受了。
		if onFail != nil {
			onFail(&lastfmAPIError{Code: 9, Message: "mirror disabled (credentials judged dead)", Method: what})
		}
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), mirrorTimeout())
		defer cancel()
		err := call(ctx)
		if err == nil {
			// 成功即洗清 error 4 的嫌疑(见 suspect4 注释)——能写进去就说明凭据活着。
			s.suspect4.Store(0)
			// 干净的一次成功:把上次运行可能留下的"授权失效"状态文件清掉(App 的
			// Last.fm 卡靠它显示红标),整个进程只查一次。
			s.clearStatus.Do(func() { os.Remove(lastfmStatusPath) })
			return
		}
		var apiErr *lastfmAPIError
		if errors.As(err, &apiErr) && s.shouldDisable(apiErr, time.Now()) {
			// 只有第一个发现者负责收尾:打一条(且只有一条)显眼日志 + 落状态文件给
			// App 读。之后 mirrorAsync 在入口处直接短路,不再刷屏、不再白打请求。
			if s.dead.CompareAndSwap(false, true) {
				log.Printf("lastfm mirror DISABLED: %v (fatal credential error; reconnect the account in Lyrimuse settings to resume)", apiErr)
				writeLastfmMirrorStatus(apiErr)
			}
			// 凭据判死 = 这一条确定没写进去,跟入口短路那条同样要留痕,重新授权后回填能补回来。
			if onFail != nil {
				onFail(err)
			}
			return
		}
		if apiErr != nil && apiErr.fatal() {
			// 单发 error 4:嫌疑已记下,先不熔断 —— 复发才停(见 shouldDisable)。
			log.Printf("lastfm mirror %s: %v (single error 4 may be transient server flakiness; mirror stays up, disables only on recurrence)", what, apiErr)
			// 仍然交给 onFail:凭据当下没被判死,但这一发确实没写进去,该留痕的照样留。
			if onFail != nil {
				onFail(err)
			}
			return
		}
		log.Printf("lastfm mirror %s failed: %v", what, err)
		if onFail != nil {
			onFail(err)
		}
	}()
}

// writeLastfmMirrorStatus 把致命的 Last.fm 写入错误落盘(lyrimuse-lastfm-status.json),
// App 的账号卡读它来显示"授权已失效"红标 —— 沿用 collector 落盘/Swift 读的既有约定
// (同 lfmMirroredPath 等)。写失败只记日志:状态文件是通知通道,不是正确性依赖。
func writeLastfmMirrorStatus(apiErr *lastfmAPIError) {
	if lastfmStatusPath == "" {
		return
	}
	data, err := json.Marshal(struct {
		Error   int    `json:"error"`
		Message string `json:"message"`
		Method  string `json:"method"`
		At      int64  `json:"at"`
	}{apiErr.Code, apiErr.Message, apiErr.Method, time.Now().Unix()})
	if err != nil {
		return
	}
	if err := os.WriteFile(lastfmStatusPath, data, 0o644); err != nil {
		slog.Error("lastfm mirror: write status file failed", "err", err)
	}
}

// lastfmTrack is a track from Last.fm. UTS is the scrobble time in unix seconds
// (0 for the currently-playing entry, which has no timestamp).
//
// Image是响应里 `image` 数组的 large 档 URL(拿不到退 extralarge、再退
// 最后一档),原样透传、不判占位星——App 侧 `imageURL()` 一直在做那道过滤(按固定 hash 认
// Last.fm 的"万能白星"),两边各判一次没有意义。只给 recent feed 用,桥接/去重逻辑不看它。
type lastfmTrack struct {
	Title, Artist, Album string
	Image                string
	UTS                  int64
}

// lastfmRecentPage 是一次 `user.getrecenttracks limit=50` 的完整解析结果。
//
// 之前 lastfmRecent 只返回 (nowPlaying, done):桥接只关心这两样。现在这次
// 拉取还要落成 App 读的 recent feed(见 lastfmfeed.go),feed 要把 `@attr.total`(账号
// 总 scrobble 数——App 那三个数字里的"总量"原来单独靠一次 page=1 请求的同一个字段)一并
// 带走,所以把响应里用得上的东西收成一个结构体整体返回。
type lastfmRecentPage struct {
	NowPlaying *lastfmTrack
	Done       []lastfmTrack // 已完成的 scrobble,新→旧
	Total      int           // @attr.total,解析不到时为 0
}

// lastfmRecent fetches a user's recent Last.fm tracks: the currently-playing one
// (if any) and completed scrobbles with timestamps (newest first). Bridges iPhone
// playback (FastScrobbler→Last.fm) into ListenBrainz — now-playing mirrors the
// live track, completed scrobbles are forwarded as listens so "last played" and
// history reflect the phone on any device. 同一份响应也落成 App 读的
// recent feed(lastfmfeed.go),所以顺手多解 image / @attr.total。
func lastfmRecent(ctx context.Context, user, apiKey string) (page lastfmRecentPage, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	u := fmt.Sprintf(
		"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=%s&api_key=%s&format=json&limit=50",
		neturl.QueryEscape(user), neturl.QueryEscape(apiKey))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		log.Printf("lastfmRecent: build request: %v", err)
		return lastfmRecentPage{}, false
	}
	resp, err := doHTTPTracked(lastfmReadClient, req)
	if err != nil {
		log.Printf("lastfmRecent: request failed: %v", err)
		return lastfmRecentPage{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("lastfmRecent: status %d", resp.StatusCode)
		return lastfmRecentPage{}, false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		log.Printf("lastfmRecent: read response: %v", err)
		return lastfmRecentPage{}, false
	}
	page, err = parseLastfmRecent(body)
	if err != nil {
		log.Printf("lastfmRecent: decode response: %v", err)
		return lastfmRecentPage{}, false
	}
	return page, true
}

// parseLastfmRecent 把 `user.getrecenttracks` 的响应体解成 lastfmRecentPage。拆出来是为了
// 能用样本 JSON 单测(lastfmfeed_test.go);网络部分在 lastfmRecent。
func parseLastfmRecent(body []byte) (lastfmRecentPage, error) {
	var out struct {
		RecentTracks struct {
			Attr struct {
				Total string `json:"total"`
			} `json:"@attr"`
			Track []struct {
				Name   string `json:"name"`
				Artist struct {
					Text string `json:"#text"`
				} `json:"artist"`
				Album struct {
					Text string `json:"#text"`
				} `json:"album"`
				Image []struct {
					Size string `json:"size"`
					Text string `json:"#text"`
				} `json:"image"`
				Date struct {
					UTS string `json:"uts"`
				} `json:"date"`
				Attr struct {
					NowPlaying string `json:"nowplaying"`
				} `json:"@attr"`
			} `json:"track"`
		} `json:"recenttracks"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return lastfmRecentPage{}, err
	}
	var page lastfmRecentPage
	page.Total, _ = strconv.Atoi(out.RecentTracks.Attr.Total)
	for _, t := range out.RecentTracks.Track {
		if t.Name == "" {
			continue
		}
		tr := lastfmTrack{Title: t.Name, Artist: t.Artist.Text, Album: t.Album.Text}
		// 依次取 large、extralarge、最后一档里第一个非空的,跟 App 侧 LastfmImage.pick 同一条规则,
		// 改一处必须同步改另一处。
		pick := func(size string) string {
			for _, im := range t.Image {
				if im.Size == size {
					return im.Text
				}
			}
			return ""
		}
		tr.Image = pick("large")
		if tr.Image == "" {
			tr.Image = pick("extralarge")
		}
		if tr.Image == "" && len(t.Image) > 0 {
			tr.Image = t.Image[len(t.Image)-1].Text
		}
		if t.Attr.NowPlaying == "true" {
			np := tr
			page.NowPlaying = &np
		} else if t.Date.UTS != "" {
			tr.UTS, _ = strconv.ParseInt(t.Date.UTS, 10, 64)
			page.Done = append(page.Done, tr)
		}
	}
	return page, nil
}
