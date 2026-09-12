package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- 歌词源级熔断 / 退避 ----
//
// 2026-09-02 加。全部歌词源并发、20 秒总截止(lyricSearchDeadline),
// 某个源整个哑掉(DNS 污染、TLS 挂死、5xx)时,之前每首歌都要把它等到自己的超时——AGENTS.md
// 里 2026-08-15 Musixmatch DNS 事故的原话就是「每首歌都要把 DNS/TLS 超时白等一遍」。已有的
// 退避都是点状的(网易云端点桶 30s 拒绝冷却、lb.go 的 429 阶梯、Musixmatch 自己换 token),
// 没有「某个源连续失败就在接下来一段时间跳过它」的通用层。
//
// 挂在哪:各源函数把所有错误都吞成空结果、不区分"没查到"和"没查成",唯一集中的地方是
// doHTTPTracked(整个采集器所有对外请求的统一出口),能拿到网络层错误与状态码——所以失败
// 观察挂在那里,按请求主机归到源(lyricSourceForHost);跳过决策挂在
// fetchScoredLyricCandidatesStreaming 每个源 goroutine 的开头(planRound)。
//
// 只统计两类失败:http.Client.Do 本身返回错误(DNS/连接/TLS/超时——请求根本没发出去或
// 没拿到响应)和 5xx;429 单独按 Retry-After 处理。任何拿到响应且状态码 < 500 的请求都算
// 一次成功、立即清零——4xx 一律不算:那是各源自己的业务判定(网易云 body 里的 405、
// Musixmatch 的 401 hint=captcha 都已各自处理),也刻意**不**把
// 401/402/403 当成长期粘性冷却的理由——对没有凭据的源来说,反爬 403 那样处理会让该源永久缺席、界面还不提示。
//
// 三条护栏(理由见 09 章第 41 条):
//   - 连续 2 次失败才开(lyricSourceBreakerTripAfter),不是 1 次:一次网络抖动不该让下一首歌
//     少一个源。网易云一轮最多发 4 个变体,一首歌就够触发;lrclib 单请求要两首歌。
//   - 启用的源**全部**在冷却中时谁也不跳过,照常跑一轮——让 roundLooksNetworkDown 那套
//     "至少 3 次请求全失败 = 断网"的判定接手,别让熔断把断网状态伪装成"这首歌没歌词"。
//   - 被跳过的源记进 lyricSourceRound(经 ctx 传给 enrich.go),落到 lyrics_sources_skipped /
//     决策留痕的 sources_skipped;歌词为空且这一轮有源被跳过时,needsLyricsFirstFill 的补空
//     间隔从 24 小时改成 10 分钟(只对第一次生效)。
//
// 被跳过的源在"哪些源应答了"的口径里就是没应答——这正好接上既有的两条机制:
// needsLyricsRetry 会在 6 小时后重搜(最多 3 次),rescoreDecidable 拒绝在当前源缺席时降级。
// 全部状态在进程内存里,collector 重启归零;search-lyrics 这类一次性 CLI 进程永远不会有
// 冷却态,冷却本身不需要给 Swift 侧加失败原因代码 —— 但同一个 observe 入口顺手记下的
// **传输层失败分类**(本文件最后一节)会以 dns_failed / connect_failed / server_error 三个
// 代码报给弹窗,那三个是 2026-09-06 加的,见 lyricsourcefailure.go。

// lyricSourceBreakerSchedule:第 N 次达到触发阈值之后的冷却时长(N 从 0 起),超出表长封顶
// 在最后一档——上限 5 分钟,成功即清,误熔断的代价有界。
var lyricSourceBreakerSchedule = []time.Duration{
	15 * time.Second, 30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute,
}

const (
	// lyricSourceBreakerTripAfter:连续多少次失败才进入冷却。
	lyricSourceBreakerTripAfter = 2
	// 429 的 Retry-After:没给或解析不出用默认值,给了也封顶,别被一个离谱的头把源关掉一天。
	lyricSourceBreakerRetryAfterDefault = time.Minute
	lyricSourceBreakerRetryAfterMax     = 5 * time.Minute
)

const (
	lyricSourceCooldownReasonNetwork     = "network"
	lyricSourceCooldownReasonServerError = "http_5xx"
	lyricSourceCooldownReasonRateLimited = "http_429"
)

type lyricSourceBreakerState struct {
	until       time.Time
	consecutive int
	// trips:这个源**熔断过几轮**(不是失败过几个请求)。冷却档位按它取,见 observeWith
	// 里那段 ⚠️。成功一次整条 state 被删掉,它跟着归零。
	trips  int
	reason string
}

type lyricSourceBreaker struct {
	mu    sync.Mutex
	now   func() time.Time
	state map[string]*lyricSourceBreakerState
	// transport:按源累计的传输层结局(本文件最后一节「传输层失败分类」)。跟 state 分开放:
	// state 在成功时会被整个删掉,而"这个源拿到过响应"这个事实恰恰要在成功之后留下来。
	transport map[string]*lyricSourceTransportState
}

func newLyricSourceBreaker(now func() time.Time) *lyricSourceBreaker {
	return &lyricSourceBreaker{
		now:       now,
		state:     map[string]*lyricSourceBreakerState{},
		transport: map[string]*lyricSourceTransportState{},
	}
}

// lyricSourceBreakerShared 是常驻采集器用的那一份(进程级)。
var lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)

// lyricSourceForHost 把请求主机归到歌词源名(lyricSourceNames 里的写法);不是歌词源的主机
// (Last.fm / ListenBrainz / MusicBrainz / iTunes / DoH …)返回空串。主机名单来自各源文件里
// 实际请求的域名(2026-09-02 grep 核对);raw.githubusercontent.com 全仓只有 amll 在用。
func lyricSourceForHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.Contains(h, ":") {
		if hostOnly, _, err := net.SplitHostPort(h); err == nil {
			h = hostOnly
		}
	}
	switch {
	case h == "music.163.com" || strings.HasSuffix(h, ".163.com"):
		return "netease"
	case h == "qq.com" || strings.HasSuffix(h, ".qq.com"):
		return "qq"
	case h == "kugou.com" || strings.HasSuffix(h, ".kugou.com"):
		return "kugou"
	case h == "lrclib.net" || strings.HasSuffix(h, ".lrclib.net"):
		return "lrclib"
	case h == "musixmatch.com" || strings.HasSuffix(h, ".musixmatch.com"):
		return "musixmatch"
	case h == "raw.githubusercontent.com":
		return "amll"
	case h == "music.youtube.com":
		return "lyricfind"
	case h == "kuwo.cn" || strings.HasSuffix(h, ".kuwo.cn"):
		return "kuwo"
	case h == "migu.cn" || strings.HasSuffix(h, ".migu.cn"):
		return "migu" // 搜索 pd.musicapp.migu.cn、歌词文件 d.musicapp.migu.cn 都归这一源
	}
	return ""
}

// observe 记录一次对外请求的结果。err 是 http.Client.Do 的返回错误(nil = 拿到了响应),
// status 是响应状态码(err != nil 时忽略),retryAfter 是响应的 Retry-After 头原文(可空)。
// 没有 DNS 轨迹的调用方(测试、以及日后别的入口)用这个;doHTTPTracked 走 observeTraced。
func (b *lyricSourceBreaker) observe(host string, err error, status int, retryAfter string) {
	b.observeWith(host, err, status, retryAfter, transportTrace{})
}

func (b *lyricSourceBreaker) observeWith(host string, err error, status int, retryAfter string, tr transportTrace) {
	source := lyricSourceForHost(host)
	if source == "" {
		return
	}
	// 用户主动取消(enrichcancel.go)会让全部在飞的请求同时以 context.Canceled 失败——
	// 那是用户的动作,不是源的毛病,一次都不算。
	if err != nil && errors.Is(err, context.Canceled) {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.noteTransport(source, err, status, tr)
	now := b.now()
	st := b.state[source]
	switch {
	case err != nil || status >= 500:
		reason := lyricSourceCooldownReasonNetwork
		if err == nil {
			reason = lyricSourceCooldownReasonServerError
		}
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		st.consecutive++
		if st.consecutive < lyricSourceBreakerTripAfter {
			return
		}
		// ⚠️ 已经在冷却里就到此为止:不升档、也不续期(2026-09-09 修)。
		//
		// 原来这里是 `idx := st.consecutive - lyricSourceBreakerTripAfter` —— 拿**失败请求
		// 数**当档位。可 consecutive 是按请求数涨的,而一轮搜索里同一个源要发好几个请求
		// (网易云 4 个歌手别名变体、QQ 的 smartbox + client_search 加起来更多),源整个挂掉
		// 时它们在同一瞬间一起失败,于是一次抖动就能把阶梯从头走到尾。2026-09-09 实测日志:
		// QQ 在 14:38:19.804 这**同一毫秒**里连跳 15s→30s→1m→2m→5m 五档,网易云 0.8 秒内到顶
		// 并一路涨到 consecutive=22;整份日志里冷却到顶 5 分钟发生过 331 次,可配对的 35 例
		// 里有 14 例是"第一档 15 秒都还没过完就到顶"。用户看得见的后果:一次 2 秒的 DNS 抖动
		// 换来 7 个源停摆 5 分钟,期间播到的歌被判"暂无歌词"(《One Last Kiss》那一例)。
		//
		// 阶梯本来的语义(见文件头「第 N 次达到触发阈值之后的冷却时长」)是**每熔断一轮升
		// 一档** —— 冷却到期、放它再试一次、又挂了,才说明问题更严重。所以档位改用 trips,
		// 并且冷却窗口内的余震一律直接返回:窗口内那些失败既不是新证据,也不该把冷却续期
		// (续期会让"上限 5 分钟"变成"只要还在失败就永远冷却",跟文件头「误熔断的代价有界」
		// 相悖)。consecutive 保留原样,它只管"连续两次才开"那道门槛。
		if st.until.After(now) {
			return
		}
		idx := st.trips
		if idx >= len(lyricSourceBreakerSchedule) {
			idx = len(lyricSourceBreakerSchedule) - 1
		}
		st.trips++
		st.until = now.Add(lyricSourceBreakerSchedule[idx])
		st.reason = reason
		log.Printf("lyrics: source %s cooling down %s (reason=%s trip=%d consecutive=%d host=%s)",
			source, lyricSourceBreakerSchedule[idx], reason, st.trips, st.consecutive, host)
	case status == http.StatusTooManyRequests:
		if st == nil {
			st = &lyricSourceBreakerState{}
			b.state[source] = st
		}
		d := parseLyricSourceRetryAfter(retryAfter)
		st.until = now.Add(d)
		st.reason = lyricSourceCooldownReasonRateLimited
		log.Printf("lyrics: source %s cooling down %s (reason=%s host=%s)", source, d, st.reason, host)
	default:
		if st == nil {
			return
		}
		if st.until.After(now) {
			log.Printf("lyrics: source %s recovered, cooldown cleared (reason=%s)", source, st.reason)
		}
		delete(b.state, source)
	}
}

// parseLyricSourceRetryAfter 只认「秒数」写法;HTTP-date 写法(RFC 7231 允许)用默认值——
// 各源里没见过谁发日期形态的 Retry-After,不值得为它引入日期解析。
func parseLyricSourceRetryAfter(v string) time.Duration {
	secs, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || secs <= 0 {
		return lyricSourceBreakerRetryAfterDefault
	}
	d := time.Duration(secs) * time.Second
	if d > lyricSourceBreakerRetryAfterMax {
		d = lyricSourceBreakerRetryAfterMax
	}
	return d
}

// lyricSourceRoundPlan:这一轮该跳过的源 → 剩余冷却时长。
type lyricSourceRoundPlan map[string]time.Duration

// planRound 在一轮全源搜索起跑前算一次"谁在冷却中"。启用的源全部都在冷却时返回 nil
// (谁也不跳过,见文件头第二条护栏);未启用的源在不在名单里无所谓——2026-09-06 起
// fetchScoredLyricCandidatesStreaming 对关掉的源直接跳过、根本不起请求(enrich.go
// lyricSourceSkipFor),这里只管冷却。
func (b *lyricSourceBreaker) planRound(sources []string, enabled func(string) bool) lyricSourceRoundPlan {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	plan := lyricSourceRoundPlan{}
	enabledTotal, enabledCooling := 0, 0
	for _, s := range sources {
		isEnabled := enabled(s)
		if isEnabled {
			enabledTotal++
		}
		if st := b.state[s]; st != nil && st.until.After(now) {
			plan[s] = st.until.Sub(now)
			if isEnabled {
				enabledCooling++
			}
		}
	}
	if len(plan) == 0 {
		return nil
	}
	if enabledTotal > 0 && enabledCooling == enabledTotal {
		log.Printf("lyrics: all %d enabled sources are cooling down, running the round anyway", enabledTotal)
		return nil
	}
	return plan
}

// anyLyricSourceCooling 回答"这些源里还有没有在冷却中的"。
//
// 给 needsLyricsFirstFill 用:上一轮因熔断被跳过的那些源要是都不冷却了,那条"补空歌词"
// 就不必再干等满 10 分钟(见那边的注释)。写成包级变量而不是直接调
// lyricSourceBreakerShared,是为了让 enrich 侧的单测能把它换掉——熔断状态在进程内存里,
// 测试不该为了跑一条节流判定去伪造一个全局熔断器。
var anyLyricSourceCooling = func(sources []string) bool {
	for _, s := range sources {
		if _, cooling := lyricSourceBreakerShared.coolingDown(s); cooling {
			return true
		}
	}
	return false
}

// coolingDown 只读地回答某个源现在是不是在冷却中(给诊断/测试用)。
func (b *lyricSourceBreaker) coolingDown(source string) (time.Duration, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	st := b.state[source]
	if st == nil || !st.until.After(b.now()) {
		return 0, false
	}
	return st.until.Sub(b.now()), true
}

// ---- 把"这一轮跳过了谁"从 fetchScoredLyricCandidatesStreaming 传回给写缓存的那几层 ----
//
// 用 context 值而不是改返回值:fetchScoredLyricCandidatesStreaming 在 scoredLyricCandidatesStreaming
// 里为歌手别名 / 标题反查会被调最多 4 次,再往上还有三层调用链(retryLyricsUpgrade /
// rescoreLyrics / resolveTrackEnrichment),逐层加返回值要改六处签名却只为传一份名单;
// 挂在 ctx 上,只有真关心的三个写缓存点各拿一次。没挂(search-lyrics CLI)就什么都不记。

type lyricSourceRound struct {
	mu      sync.Mutex
	skipped map[string]bool
}

type lyricSourceRoundKey struct{}

func withLyricSourceRound(ctx context.Context) (context.Context, *lyricSourceRound) {
	r := &lyricSourceRound{skipped: map[string]bool{}}
	return context.WithValue(ctx, lyricSourceRoundKey{}, r), r
}

func lyricSourceRoundFrom(ctx context.Context) *lyricSourceRound {
	if ctx == nil {
		return nil
	}
	r, _ := ctx.Value(lyricSourceRoundKey{}).(*lyricSourceRound)
	return r
}

// ---- 「这一轮只查这些源」(2026-09-06,给别名轮用) ----
//
// 跟上面 lyricSourceRound 同一个理由走 ctx:fetchScoredLyricCandidatesStreaming 的签名不动。
// nil 名单 = 不限制(所有调用方的默认);非 nil 时名单外的源在 skipSource 里静默跳过。

type lyricSourceOnlyKey struct{}

// withLyricSourceOnly:sources 为空切片 / nil 时返回原 ctx(不限制)。
func withLyricSourceOnly(ctx context.Context, sources []string) context.Context {
	if len(sources) == 0 {
		return ctx
	}
	set := make(map[string]bool, len(sources))
	for _, s := range sources {
		set[s] = true
	}
	return context.WithValue(ctx, lyricSourceOnlyKey{}, set)
}

// lyricSourceOnlyFrom:没挂 / ctx 为 nil 时返回 nil(不限制)。
func lyricSourceOnlyFrom(ctx context.Context) map[string]bool {
	if ctx == nil {
		return nil
	}
	set, _ := ctx.Value(lyricSourceOnlyKey{}).(map[string]bool)
	return set
}

// markSkipped / skippedSources 对 nil 接收者都是安全的空操作(CLI 路径没有 round)。
func (r *lyricSourceRound) markSkipped(source string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.skipped[source] = true
	r.mu.Unlock()
}

func (r *lyricSourceRound) skippedSources() []string {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.skipped) == 0 {
		return nil
	}
	out := make([]string, 0, len(r.skipped))
	for s := range r.skipped {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// ---- 传输层失败分类:给「歌词源可用情况」按源报"为什么连不上" ----
//
// 2026-09-06 加,用户报「派对后派对(黄妍)搜不到」。真相:这台机器连着公司 OpenVPN,它下发的
// DNS(10.255.0.1)对 music.163.com / c.y.qq.com / mobilecdn.kugou.com / lrclib.net / search.kuwo.cn /
// pd.musicapp.migu.cn 一律不答(dig 实测:多数超时、偶尔空答),六个源的请求 2ms 内就以
// `lookup xxx: no such host` 死在解析这一步、一个字节都没发出去;而 itunes.apple.com /
// music.youtube.com / www.google.com 这几个域名同一台 DNS 能答。于是 networkLooksDown()(要求
// 进程内**所有**请求全失败)是 false、sourceFailureReasonCodes 只有 lyricfind 那条不相干的地区
// 限制 —— 弹窗照实显示「九个源都没找到可用的候选」,把"连不上"报成了"没收录"。用 8.8.8.8 解析出
// IP 直连立刻 200,网易云 / QQ 的第一条结果就是这首(标题 / 专辑 / 歌手三项精确命中)。
//
// 判据是**这个源在本进程里有没有拿到过任何一个 HTTP 响应**(状态码 < 500 即算 —— 4xx 也是
// 服务器在说话,404 = 没这首、403 = 反爬,跟上面熔断的口径一致):一次都没有、且失败过 → 报
// 最多见的那一类失败(dns_failed / connect_failed / server_error,见 lyricsourcefailure.go)。
// 拿到过响应的源**不报** —— "响应了但没这首歌"跟"连不上"必须分开,这正是这次要修的混淆。
//
// ⚠️ DNS 失败怎么认(评审时抓到的坑):不能只靠 errors.As(err, *net.DNSError)。各源的 client 都
// 设了 http.Client.Timeout(4–8 秒),DNS **挂住不答**(而不是秒答 NXDOMAIN)时是这个 Timeout 先
// 到:Transport.getConn 直接返回 ctx.Err()、丢掉拨号 goroutine 里那条带 DNSError 的错误,
// Client.do 再把它整体换成 *http.timeoutError(纯字符串,没有 Unwrap)—— 类型链彻底没了,
// 只看错误链会把"DNS 不答"归成 connect_failed,界面再说一句"域名能解析",正好说反。所以
// doHTTPTracked 给每个请求挂 httptrace.ClientTrace 记 DNSStart / DNSDone(net 包在系统解析器
// 与纯 Go 解析器两条路上都会调这两个钩子,ctx 被取消时 DNSDone 也会带 err 调一次),
// 分类时**先看轨迹**:DNS 阶段开始了却没结束、或结束时带错 → dns_failed;错误链里有 DNSError
// → dns_failed;其余才是 connect_failed。复用连接(没有 DNS 阶段)与 DoH 自定义拨号(musixmatch,
// 没有 net 包的 DNS 钩子)拿不到轨迹,退回错误链判定 —— 后者今天被 musixmatch_direct_blocked
// 这个具体代码盖住,看不出差别;若日后把 DoH 扩到别的源,dohDialContext 用 %w 包住的系统解析
// NXDOMAIN 会让"DoH 解析成功但拨不通"被归成 dns_failed,到那时要一并改。
//
// 只有一次性 CLI(searchcli.go 的 lyricSourceFailureReasons)消费。常驻 collector 里这份是进程
// 生命周期累计的、不按轮清零,跟 xxxLastFailureReasonNow 同一条注意事项;search-lyrics 每次
// 都是全新进程,读到的就是这一次搜索本身的结局。

type lyricSourceTransportState struct {
	responded bool           // 拿到过 < 500 的响应
	failures  map[string]int // 失败代码 → 次数
}

// transportTrace 是 doHTTPTracked 从 httptrace 钩子里收来的 DNS 阶段轨迹。零值 = 没有观察到
// DNS 阶段(复用连接 / 自定义拨号 / 没挂钩子),分类退回只看错误链。
type transportTrace struct {
	dnsStarted bool
	dnsDone    bool
	dnsErr     error
}

// classifyLyricSourceTransportFailure 把一次请求的结局归到三个通用代码之一;拿到 < 500 的响应
// 返回空串。err 是 http.Client.Do 的返回值,status 只在 err == nil 时有意义,tr 见 transportTrace。
func classifyLyricSourceTransportFailure(err error, status int, tr transportTrace) string {
	if err == nil {
		if status >= 500 {
			return lyricFailureReasonServerError
		}
		return ""
	}
	// 先看轨迹:DNS 阶段没走完 / 走完了但带错,不管错误链被 http.Client 换成了什么。
	if tr.dnsStarted && (!tr.dnsDone || tr.dnsErr != nil) {
		return lyricFailureReasonDNSFailed
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return lyricFailureReasonDNSFailed
	}
	return lyricFailureReasonConnectFailed
}

// observeTraced 是 observe 的带轨迹版本,doHTTPTracked 用它;observe 本身等价于零轨迹。
func (b *lyricSourceBreaker) observeTraced(host string, err error, status int, retryAfter string, tr transportTrace) {
	b.observeWith(host, err, status, retryAfter, tr)
}

// noteTransport 在 observeWith 里(已持锁)记一笔。context.Canceled 已在那边开头被过滤。
func (b *lyricSourceBreaker) noteTransport(source string, err error, status int, tr transportTrace) {
	ts := b.transport[source]
	if ts == nil {
		ts = &lyricSourceTransportState{failures: map[string]int{}}
		b.transport[source] = ts
	}
	code := classifyLyricSourceTransportFailure(err, status, tr)
	if code == "" {
		ts.responded = true
		return
	}
	ts.failures[code]++
}

// lyricSourceTransportFailureOrder:并列时的取舍顺序。DNS 失败是最靠前、最能解释其它现象的那
// 一层(解析都不通,别的更谈不上),其次是连不上,最后才是"连上了但服务器报错"。
// ⚠️ 这份顺序也是 Swift 侧空状态分组的顺序(LyricsSearchSheet.transportFailureCodes,那边多一个
// 只由 searchcli 派生、不经这里的 upstream_unreachable),lyricsourcefailure_test.go 钉着两边一致。
var lyricSourceTransportFailureOrder = []string{
	lyricFailureReasonDNSFailed, lyricFailureReasonConnectFailed, lyricFailureReasonServerError,
}

func dominantLyricSourceTransportFailure(failures map[string]int) string {
	best, bestN := "", 0
	for _, code := range lyricSourceTransportFailureOrder {
		if n := failures[code]; n > bestN {
			best, bestN = code, n
		}
	}
	return best
}

// transportFailureCodes:本进程里一个响应都没拿到过、又确实失败过的源 → 最多见的那类失败代码。
// 没有这样的源返回 nil。
func (b *lyricSourceBreaker) transportFailureCodes() map[string]string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]string{}
	for source, ts := range b.transport {
		if ts.responded || len(ts.failures) == 0 {
			continue
		}
		if code := dominantLyricSourceTransportFailure(ts.failures); code != "" {
			out[source] = code
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
