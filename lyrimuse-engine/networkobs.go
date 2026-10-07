package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// networkAttemptCount/networkFailureCount 给"联网搜索候选歌词"(searchcli.go)判断
// "所有源都没找到候选"到底是这首歌真的没有网络歌词,还是网络整体不通导致请求全部
// 发不出去用——补上(当时还只有五个源,netease/qq/kugou/lrclib/musixmatch,
// amll/ytmusic 后来才接入,一并算进这个统计),之前每个源各自内部把 http 请求失败和
// "服务器正常响应、只是没查到"统统当空结果处理,两种情况在 UI 上完全分不清。
// lyrimuse-engine search-lyrics 是一次性子命令(一个独立进程执行一次就退出,不是常驻服务里
// 反复调用的路径),这里用包级变量累计"这次进程调用期间"的请求总数/失败数,不需要在
// 两次搜索之间显式清零。
//
// 只有 http.Client.Do 本身返回 error(DNS 解析失败、连接被拒、超时——请求根本没有
// 发出去或者没有收到任何响应)才算一次网络层失败;请求确实发出去、拿到了响应(哪怕
// 状态码不是 200,或者响应内容解析出来是空)算一次成功的网络尝试,不计入失败——那
// 说明网络本身没问题,只是这次查询没有命中。
var (
	networkAttemptCount int32
	networkFailureCount int32
)

// doHTTPTracked 是 http.Client.Do 的一层透明包装——完全不改变调用方原有的返回值/
// 错误处理逻辑,调用方该怎么处理 resp/err 还怎么处理,行为不变。现在承担两件事:
//
//  1. 原有的:给 networkLooksDown() 那套"网络是不是整体不通"的判断累计原子计数器
//     (原来只覆盖七个歌词源)。
//  2. 新加:**这是整个采集器所有对外请求的统一审计日志出口**——用户
//     明确要求"所有软件发出的对外请求全部都给我记录下日志"。采集器里几乎所有发
//     真实网络请求的地方(Last.fm/ListenBrainz/歌词各源/推送/状态中继/翻译/取色/
//     MusicBrainz/iTunes)都已经改成调这个函数,不再各自直接 cli.Do(req)。
//
// 日志行故意**不带 query string**——Last.fm/ListenBrainz 这类接口的凭据就是拼在
// query string 或 path 里的,不记录这部分,比"记了再指望脱敏兜底"更彻底(见
// logscrub.go 的注释:那道全局脱敏是防御性的第二层,不是这条新日志唯一的安全保障)。
// 唯一放行的例外是 Last.fm 的 `method` 参数(比如 track.getinfo)——它标识调用的是
// 哪个 API 方法,不是凭据,不在任何一份敏感参数名单里,带上它才能看出"打的是哪个接口"。
//
// 刻意排除在外、不经过这里的两类:DNS-over-HTTPS 查询(doh.go,那是给别的请求解析
// 域名用的基础设施调用,不是"联系了哪个外部服务");App 自动更新检查(Sparkle 框架,
// 是 Swift 侧的事,而且请求整个发生在框架内部,拿不到这个函数需要的 method/URL/状态
// 码/耗时)。
// doHTTPTrackedOnce 是真正发一次请求的那部分;对外入口 doHTTPTracked 在它外面包了一层同 URL 合并(httpcoalesce.go)。
func doHTTPTrackedOnce(cli *http.Client, req *http.Request) (*http.Response, error) {
	// 本地出站闸(hostguard.go):限速排队、429 窗口、歌词源冷却。拦下的请求没发出去,
	// 不计数、不喂熔断、不进审计汇总。
	if err := sharedHostGuard().admit(req); err != nil {
		return nil, err
	}
	// DNS 阶段轨迹,只给歌词源的传输层失败分类用(sourcebreaker.go 最后一节的
	// 段说明了为什么不能只看错误链)。钩子在拨号 goroutine 上跑、跟这里不同步,所以用
	// 锁读写;请求结束后再读一次快照交给 observeTraced。非歌词源主机也会挂,开销是一个
	// 闭包结构体加一次 WithContext 的浅拷贝,可忽略。
	var (
		traceMu sync.Mutex
		trace   transportTrace
	)
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
		DNSStart: func(httptrace.DNSStartInfo) {
			traceMu.Lock()
			trace.dnsStarted = true
			traceMu.Unlock()
		},
		DNSDone: func(info httptrace.DNSDoneInfo) {
			traceMu.Lock()
			trace.dnsDone = true
			trace.dnsErr = info.Err
			traceMu.Unlock()
		},
	}))
	// 歌词源的在途上限(lyricsourceinflight.go):排不上就等,拿到响应就还。
	releaseSlot, slotErr := acquireLyricSourceSlot(req.Context(), guardHost(req.URL))
	if slotErr != nil {
		return nil, slotErr
	}
	start := time.Now()
	resp, err := cli.Do(req)
	releaseSlot()
	elapsed := time.Since(start)
	traceMu.Lock()
	tr := trace
	traceMu.Unlock()
	atomic.AddInt32(&networkAttemptCount, 1)
	noteNetworkRoundOutcome(req.Context(), err)
	// 审计里标识"打的是哪个接口":HTTP 方法 + host + path(+ Last.fm 的 method 参数)。
	// 同时是汇总的分组键。
	target := req.Method + " " + req.URL.Host + req.URL.Path
	// 汇总的分组键把路径里的资源 ID 抹掉(见 normalizeAuditPath),逐条行仍写真实路径。
	summaryKey := req.Method + " " + req.URL.Host + normalizeAuditPath(req.URL.Path)
	if m := req.URL.Query().Get("method"); m != "" {
		target += " method=" + m
		summaryKey += " method=" + m
	}
	if err != nil {
		// 调用方自己取消的(救急支线被叫停、切歌)不算网络失败:算进去会让这一轮的失败数虚高,
		// 偏向误报「网络不通」。熔断那边同样把它滤掉了(sourcebreaker.go)。
		if !errors.Is(err, context.Canceled) {
			atomic.AddInt32(&networkFailureCount, 1)
		}
		// Go 的 http.Client.Do 失败时返回的是 *url.Error,它的 Error() 会把**完整
		// 请求 URL**(含 query string)拼进错误文案——这正是 LogRedactor.swift 头部
		// 注释记录过的那类泄漏(当时是 App 侧读到引擎原始日志文件时才发现)。
		// 只取 *url.Error.Err(真正的下层错误,比如 "connection refused"),不调
		// err.Error() 本身,从源头上就不让 URL 进日志,不指望下游脱敏兜底。
		safeErr := any(err)
		if ue, ok := err.(*url.Error); ok {
			safeErr = ue.Err
		}
		if errors.Is(err, context.Canceled) {
			// 调用方主动取消(这一轮已经选出结果、切歌、扫描被叫停)是正常收尾,不是失败:逐条只到
			// Debug,汇总里单独计 canceled,不进 failed。
			slog.Debug("api call: "+target+" canceled", "elapsed_ms", elapsed.Milliseconds())
			recordCanceledAPICall(summaryKey, elapsed, time.Now())
		} else {
			// 失败逐条记、Warn 级:这是要看的信号,不进汇总里被平均掉(汇总仍计一次 failed)。
			slog.Warn("api call: "+target+" FAILED", "elapsed_ms", elapsed.Milliseconds(), "err", safeErr)
			recordAPICall(summaryKey, elapsed, true, false, time.Now())
		}
		// 歌词源级熔断的失败观察(见 sourcebreaker.go):只有歌词源的主机会被记,别的请求
		// 在 lyricSourceForHost 那里直接归零。
		sharedLyricSourceBreaker().observeTraced(req.URL.Host, guardEndpointKey(req.URL), err, 0, "", tr)
		return resp, err
	}
	sharedLyricSourceBreaker().observeTraced(req.URL.Host, guardEndpointKey(req.URL), nil, resp.StatusCode, resp.Header.Get("Retry-After"), tr)
	sharedHostGuard().observe(req, resp.StatusCode, resp.Header.Get("Retry-After"))
	if resp.StatusCode < 500 && resp.StatusCode != http.StatusTooManyRequests {
		if src := lyricSourceForHost(req.URL.Host); src != "" {
			lyricSourceRoundFrom(req.Context()).markReached(src)
		}
	}
	// 404 跟别的 4xx/5xx 分开(修)。对歌词源来说 404 是**正常应答**——"这个库里没有这首歌",
	// 跟"这个源坏了"是两回事,原来 `>= 400` 一刀切同时污染了两头:
	//   - WARN 被淹:amll 走 GitHub 裸文件,查不到就是 404,三天 18530 行 WARN、占日志体积
	//     15.6%,而它实际只贡献 34/6283 条歌词;自家 np.yudaotor.me 的封面 HEAD 探测同理,
	//     "还没上传"也被记成 WARN。真正的故障淹在里面挑不出来。
	//   - 汇总失真:lrclib 的 failed 率显示 62.5%,其中 1068 次是 404,真故障只有 503 那 399 次。
	// 现在 notfound 单独一列、逐次记录降到 Debug,failed 只留真故障。
	//
	// 只影响日志与汇总口径:熔断器那边 404 走哪条分支由它自己判(上面 observeTraced 已经
	// 把原始状态码给它了),不受这里影响。
	notFound := resp.StatusCode == http.StatusNotFound
	failed := resp.StatusCode >= 400 && !notFound
	if failed {
		slog.Warn("api call: "+target, "status", resp.StatusCode, "elapsed_ms", elapsed.Milliseconds())
	} else {
		// 成功(以及 404)的逐次记录在 Debug(默认不落盘,log_level=debug 时可见);落盘的是
		// 下面按分钟的汇总 —— "所有对外请求全部记录"这条要求由汇总里的 count 兑现,不再
		// 一行一次(Last.fm 每 5 秒一次轮询,两天日志里这一项就 4219 行)。
		slog.Debug("api call: "+target, "status", resp.StatusCode, "elapsed_ms", elapsed.Milliseconds())
	}
	recordAPICall(summaryKey, elapsed, failed, notFound, time.Now())
	return resp, err
}

// ---- 审计汇总----
//
// 同一 target 在一分钟窗口内的调用合成一行:
//
//	api call summary target="GET ws.audioscrobbler.com/2.0/ method=user.getrecenttracks" count=12 failed=0 p50_ms=350 max_ms=800 span_s=55
//
// 窗口从这个 target 第一次被记开始算,满一分钟后由维护循环(logsink.go,每 30 秒)或退出前
// (flushLogSink)结算。failed 同时计传输失败和 HTTP 4xx/5xx —— 这两种在逐条 Warn 里都能
// 看到细节,汇总只回答"这一分钟里失败了几次"。
//
// 逐 target 那一行只在窗口里有失败、或最慢一次不短于 apiCallSlowMax 时落 Info,其余落 Debug
// (log_level=debug 时可见,按接口量速率用这一档)。每次结算另写一行 Info 总计(api call rollup),
// 按歌词源(lyricSourceForHost)或主机给出调用次数:搜一首歌要打二三十个接口,逐接口各一行
// 的话这一类会占掉日志的一半以上。

const apiCallSummaryWindow = time.Minute

// apiCallSlowMax:窗口里最慢一次不短于它,这个 target 的汇总行就落 Info。
const apiCallSlowMax = 5 * time.Second

// normalizeAuditPath:把路径里像资源标识符的段抹成占位,让汇总按"接口"而不是按"某一个资源"
// 分组。不抹的话一个资源一行汇总,比逐次记还长(启动期几十张封面的 HEAD、每个艺人一次
// MusicBrainz、咪咕每首歌的歌词文件、amll 每首歌一个 ttml)。占位:
//   - <uuid>;<hex>(≥8 位十六进制);<n>(≥3 位纯数字);
//   - <id>:≥24 字符且含数字的长 token,或 ≥10 位、字母数字混排的 token(QQ 的 songmid 如
//     001WYlp031x9Gz、Spotify 的 22 位 id);
//   - <path>:连续三段以上、每段一两个字母数字的分桶目录(咪咕 /data/oss/resource/00/2c/n2/lf、
//     mzstatic 的 /v4/30/0c/5a)整段并成一个。
//
// 扩展名保留(能看出是 .jpg 还是 .ttml)。版本段(v8、2.0、1)、接口名(client_search_cp、
// fcg_query_lyric_new.fcg)不会被碰。只动汇总的分组键,逐条的 Debug / Warn 行仍写真实路径 ——
// 排查时要知道是哪一个。
func normalizeAuditPath(p string) string {
	segs := strings.Split(p, "/")
	out := make([]string, 0, len(segs))
	for i := 0; i < len(segs); {
		j := i
		for j < len(segs) && len(segs[j]) >= 1 && len(segs[j]) <= 2 && isAlnumToken(segs[j]) {
			j++
		}
		if j-i >= 3 {
			out = append(out, "<path>")
			i = j
			continue
		}
		seg := segs[i]
		i++
		base, ext := seg, ""
		if dot := strings.LastIndexByte(seg, '.'); dot > 0 && len(seg)-dot <= 5 {
			base, ext = seg[:dot], seg[dot:]
		}
		switch {
		case base == "":
		case isUUIDToken(base):
			seg = "<uuid>" + ext
		case len(base) >= 8 && allInSet(base, "0123456789abcdefABCDEF"):
			seg = "<hex>" + ext
		case len(base) >= 3 && allInSet(base, "0123456789"):
			seg = "<n>" + ext
		case len(base) >= 24 && strings.ContainsAny(base, "0123456789"):
			seg = "<id>" + ext
		case len(base) >= 10 && isAlnumToken(base) && strings.ContainsAny(base, "0123456789") &&
			strings.IndexFunc(base, func(r rune) bool { return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' }) >= 0:
			seg = "<id>" + ext
		}
		out = append(out, seg)
	}
	return strings.Join(out, "/")
}

func isAlnumToken(s string) bool {
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z') {
			return false
		}
	}
	return s != ""
}

func allInSet(s, set string) bool {
	for _, r := range s {
		if !strings.ContainsRune(set, r) {
			return false
		}
	}
	return true
}

func isUUIDToken(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
				return false
			}
		}
	}
	return true
}

type apiCallWindow struct {
	first, last time.Time
	count       int
	failed      int
	// notfound:窗口里应答 404 的次数。跟 failed 分开记,理由见 doHTTPTracked 里那段 提醒。
	notfound int
	// canceled:调用方主动取消的次数,不进 failed、不进耗时分位(没等到应答)。
	canceled  int
	durations []time.Duration
}

var apiCallAgg = struct {
	mu      sync.Mutex
	windows map[string]*apiCallWindow
}{windows: map[string]*apiCallWindow{}}

func recordAPICall(target string, elapsed time.Duration, failed, notFound bool, now time.Time) {
	apiCallAgg.mu.Lock()
	defer apiCallAgg.mu.Unlock()
	w := apiCallWindowLocked(target, now)
	w.count++
	if failed {
		w.failed++
	}
	if notFound {
		w.notfound++
	}
	w.durations = append(w.durations, elapsed)
}

// recordCanceledAPICall:调用方主动取消的一次,只计 canceled。
func recordCanceledAPICall(target string, elapsed time.Duration, now time.Time) {
	apiCallAgg.mu.Lock()
	defer apiCallAgg.mu.Unlock()
	w := apiCallWindowLocked(target, now)
	w.count++
	w.canceled++
}

func apiCallWindowLocked(target string, now time.Time) *apiCallWindow {
	w := apiCallAgg.windows[target]
	if w == nil {
		w = &apiCallWindow{first: now}
		apiCallAgg.windows[target] = w
	}
	w.last = now
	return w
}

// flushAPICallSummaries:把开窗满一分钟的 target 各写一行汇总;force = 不管满没满全部结算
// (退出前)。输出按 target 排序,同一秒结算的几行顺序稳定,便于对照。
func flushAPICallSummaries(now time.Time, force bool) {
	apiCallAgg.mu.Lock()
	type done struct {
		target string
		w      *apiCallWindow
	}
	var ready []done
	for target, w := range apiCallAgg.windows {
		if !force && now.Sub(w.first) < apiCallSummaryWindow {
			continue
		}
		ready = append(ready, done{target, w})
		delete(apiCallAgg.windows, target)
	}
	apiCallAgg.mu.Unlock()
	if len(ready) == 0 {
		return
	}
	sort.Slice(ready, func(i, j int) bool { return ready[i].target < ready[j].target })
	var calls, failed, notfound, canceled int
	bySource := map[string]int{}
	for _, d := range ready {
		calls += d.w.count
		failed += d.w.failed
		notfound += d.w.notfound
		canceled += d.w.canceled
		bySource[apiCallRollupGroup(d.target)] += d.w.count
		// notfound / canceled 只在非零时出现 —— 绝大多数目标一个都没有,给每行都挂一个恒为 0 的字段
		// 是纯粹的体积浪费。
		attrs := []any{"target", d.target, "count", d.w.count, "failed", d.w.failed}
		if d.w.notfound > 0 {
			attrs = append(attrs, "notfound", d.w.notfound)
		}
		if d.w.canceled > 0 {
			attrs = append(attrs, "canceled", d.w.canceled)
		}
		var max time.Duration
		if n := len(d.w.durations); n > 0 {
			sort.Slice(d.w.durations, func(i, j int) bool { return d.w.durations[i] < d.w.durations[j] })
			max = d.w.durations[n-1]
			attrs = append(attrs, "p50_ms", d.w.durations[n/2].Milliseconds(), "max_ms", max.Milliseconds())
		}
		attrs = append(attrs, "span_s", int(d.w.last.Sub(d.w.first).Round(time.Second).Seconds()))
		if d.w.failed > 0 || max >= apiCallSlowMax {
			slog.Info("api call summary", attrs...)
		} else {
			slog.Debug("api call summary", attrs...)
		}
	}
	groups := make([]string, 0, len(bySource))
	for g := range bySource {
		groups = append(groups, g)
	}
	sort.Slice(groups, func(i, j int) bool {
		if bySource[groups[i]] != bySource[groups[j]] {
			return bySource[groups[i]] > bySource[groups[j]]
		}
		return groups[i] < groups[j]
	})
	parts := make([]string, len(groups))
	for i, g := range groups {
		parts[i] = g + "=" + strconv.Itoa(bySource[g])
	}
	attrs := []any{"targets", len(ready), "calls", calls, "failed", failed}
	if notfound > 0 {
		attrs = append(attrs, "notfound", notfound)
	}
	if canceled > 0 {
		attrs = append(attrs, "canceled", canceled)
	}
	slog.Info("api call rollup", append(attrs, "by_source", strings.Join(parts, " "))...)
}

// apiCallRollupGroup:汇总总计里的分组名。歌词源按源名合并(QQ 的五六个主机算一个 qq),
// 其余按主机。target 形如 "GET host/path"。
func apiCallRollupGroup(target string) string {
	host := target
	if sp := strings.IndexByte(host, ' '); sp >= 0 {
		host = host[sp+1:]
	}
	if sl := strings.IndexByte(host, '/'); sl >= 0 {
		host = host[:sl]
	}
	if sp := strings.IndexByte(host, ' '); sp >= 0 {
		host = host[:sp]
	}
	if src := lyricSourceForHost(host); src != "" {
		return src
	}
	return host
}

// networkLooksDown 判断"这一轮联网搜索期间,是不是网络本身就不通"。至少尝试过 3 次
// 请求、且全部失败,才判定为网络不通——尝试次数太少(比如某个源提前因为本地校验/
// 缓存命中直接跳过,根本没发出真正的网络请求)时不下这个结论,避免把"这首歌信息不全
// 所以没发几个请求"误判成"网络挂了"。
func networkLooksDown() bool {
	attempts := atomic.LoadInt32(&networkAttemptCount)
	failures := atomic.LoadInt32(&networkFailureCount)
	return attempts >= 3 && failures == attempts
}

// withNetworkRound 开始一轮只数自己请求的观察:经返回的 ctx 发出去的请求(doHTTPTracked,等到别人那次合并结果的也算)
// 才计入,返回的函数给出到调用它为止的成败。
//
// 上面那个 networkLooksDown() **不能**用在常驻采集器里,只对一次性子命令成立:
// 它读的是进程启动以来的累计值,而 `failures == attempts` 这个条件只要进程早期有过
// 任何一次成功就永远不再成立 —— 开机时有网、后来断网,它一路报"网络正常"。
// 一次性 CLI 跑完就退出,累计值天然等于"这一次的",所以那边没问题。
//
// 也不能拿全进程计数的差值代替:别的 goroutine 的请求(中继推送、收听上送、专辑预取并发解析的别的歌)一直在成功,
// 混进来以后一个请求都没问成的这一轮也会被当成「查过了」—— 首次解析把它落成「暂无歌词」(24 小时后才再试)、
// 后台补封面把它记成补过。
// 可以嵌套,里层的请求外层同样计入。
func withNetworkRound(ctx context.Context) (context.Context, func() (attempts, failures int32)) {
	r := &networkRound{parent: networkRoundFrom(ctx)}
	return context.WithValue(ctx, networkRoundKey{}, r), func() (int32, int32) {
		return r.attempts.Load(), r.failures.Load()
	}
}

type networkRoundKey struct{}

// networkRound:withNetworkRound 开的一轮。parent 是外面那一层,计数一路往上记。
type networkRound struct {
	parent             *networkRound
	attempts, failures atomic.Int32
}

func networkRoundFrom(ctx context.Context) *networkRound {
	r, _ := ctx.Value(networkRoundKey{}).(*networkRound)
	return r
}

// noteNetworkRoundOutcome 把一个请求记进 ctx 上的每一层观察(err 非空算失败)。调用方自己取消的不记:它没成也没败,
// 记成成功会把一个请求都没问成的一轮当成问过。
func noteNetworkRoundOutcome(ctx context.Context, err error) {
	if errors.Is(err, context.Canceled) {
		return
	}
	for r := networkRoundFrom(ctx); r != nil; r = r.parent {
		r.attempts.Add(1)
		if err != nil {
			r.failures.Add(1)
		}
	}
}

// roundLooksNetworkDown 判断某一轮观察的结果是不是"网络整体不通"。
// 判据跟 networkLooksDown 一致:至少试过 3 次、且全部失败。
func roundLooksNetworkDown(attempts, failures int32) bool {
	return attempts >= 3 && failures == attempts
}

// lyricsRoundConfirmsNoResult 判断这一轮"什么都没查到"是不是一个**可以下结论**的结果
// (给 resolveEnrichAsync 那道全空守卫用,理由见那边的长注释)。
//
// 判据是"至少有一个请求真的成功了" —— 网络通、源确实回了话、就是没有这首歌。
//
// 刻意不写成 `!roundLooksNetworkDown(...)`:那个要 attempts>=3 **且**全挂才算不通,
// 于是"这一轮只发出去 1~2 个请求、而且全挂"(大部分源被熔断跳过时就是这个形状,见
// sourcebreaker.go)会从它的网眼里漏过去、被当成确证查无 —— 那明明更像没查成。
// 这里宁可严一点:漏判的代价只是这一轮继续显示"搜索歌词中…",下一轮自愈会再来;
// 误判的代价是把"没查成"写成"这首歌没有歌词"。
//
// attempts==0(整轮全命中缓存、一个请求都没发)同样不算数:它不构成任何证据。
func lyricsRoundConfirmsNoResult(attempts, failures int32) bool {
	return attempts > 0 && failures < attempts
}
