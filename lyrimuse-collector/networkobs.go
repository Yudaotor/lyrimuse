// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"log/slog"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// networkAttemptCount/networkFailureCount 给"联网搜索候选歌词"(searchcli.go)判断
// "所有源都没找到候选"到底是这首歌真的没有网络歌词,还是网络整体不通导致请求全部
// 发不出去用——2026-08-02 补上(当时还只有五个源,netease/qq/kugou/lrclib/musixmatch,
// amll/ytmusic 后来才接入,一并算进这个统计),之前每个源各自内部把 http 请求失败和
// "服务器正常响应、只是没查到"统统当空结果处理,两种情况在 UI 上完全分不清。
// collector search-lyrics 是一次性子命令(一个独立进程执行一次就退出,不是常驻服务里
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
//     (2026-08-02 起,原来只覆盖七个歌词源)。
//  2. 2026-08-26 新加:**这是整个采集器所有对外请求的统一审计日志出口**——用户
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
func doHTTPTracked(cli *http.Client, req *http.Request) (*http.Response, error) {
	// DNS 阶段轨迹(2026-09-06),只给歌词源的传输层失败分类用(sourcebreaker.go 最后一节的
	// ⚠️ 段说明了为什么不能只看错误链)。钩子在拨号 goroutine 上跑、跟这里不同步,所以用
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
	start := time.Now()
	resp, err := cli.Do(req)
	elapsed := time.Since(start)
	traceMu.Lock()
	tr := trace
	traceMu.Unlock()
	atomic.AddInt32(&networkAttemptCount, 1)
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
		atomic.AddInt32(&networkFailureCount, 1)
		// Go 的 http.Client.Do 失败时返回的是 *url.Error,它的 Error() 会把**完整
		// 请求 URL**(含 query string)拼进错误文案——这正是 LogRedactor.swift 头部
		// 注释记录过的那类泄漏(当时是 App 侧读到 collector 原始日志文件时才发现)。
		// 只取 *url.Error.Err(真正的下层错误,比如 "connection refused"),不调
		// err.Error() 本身,从源头上就不让 URL 进日志,不指望下游脱敏兜底。
		safeErr := any(err)
		if ue, ok := err.(*url.Error); ok {
			safeErr = ue.Err
		}
		// 失败逐条记、Warn 级:这是要看的信号,不进汇总里被平均掉(汇总仍计一次 failed)。
		slog.Warn("api call: "+target+" FAILED", "elapsed_ms", elapsed.Milliseconds(), "err", safeErr)
		recordAPICall(summaryKey, elapsed, true, time.Now())
		// 歌词源级熔断的失败观察(见 sourcebreaker.go):只有歌词源的主机会被记,别的请求
		// 在 lyricSourceForHost 那里直接归零。
		lyricSourceBreakerShared.observeTraced(req.URL.Host, err, 0, "", tr)
		return resp, err
	}
	lyricSourceBreakerShared.observeTraced(req.URL.Host, nil, resp.StatusCode, resp.Header.Get("Retry-After"), tr)
	failed := resp.StatusCode >= 400
	if failed {
		slog.Warn("api call: "+target, "status", resp.StatusCode, "elapsed_ms", elapsed.Milliseconds())
	} else {
		// 成功的逐次记录在 Debug(默认不落盘,log_level=debug 时可见);落盘的是下面按分钟
		// 的汇总 —— 2026-08-26"所有对外请求全部记录"这条要求由汇总里的 count 兑现,不再
		// 一行一次(Last.fm 每 5 秒一次轮询,两天日志里这一项就 4219 行)。
		slog.Debug("api call: "+target, "status", resp.StatusCode, "elapsed_ms", elapsed.Milliseconds())
	}
	recordAPICall(summaryKey, elapsed, failed, time.Now())
	return resp, err
}

// ---- 审计汇总(2026-09-05)----
//
// 同一 target 在一分钟窗口内的调用合成一行 Info:
//
//	api call summary target="GET ws.audioscrobbler.com/2.0/ method=user.getrecenttracks" count=12 failed=0 p50_ms=350 max_ms=800 span_s=55
//
// 窗口从这个 target 第一次被记开始算,满一分钟后由维护循环(logsink.go,每 30 秒)或退出前
// (flushLogSink)结算。failed 同时计传输失败和 HTTP 4xx/5xx —— 这两种在逐条 Warn 里都能
// 看到细节,汇总只回答"这一分钟里失败了几次"。

const apiCallSummaryWindow = time.Minute

// normalizeAuditPath:把路径里像资源标识符的段抹成占位,让汇总按"接口"而不是按"某一个资源"
// 分组。2026-09-05 首次装机实测不抹的话:启动期给几十张封面各发一次 HEAD
// (np.yudaotor.me/artwork/<hash>.jpg)、每个艺人查一次 MusicBrainz(/ws/2/artist/<uuid>),
// 一个资源一行汇总,比逐次记还长。四类占位:<uuid> / <hex>(≥8 位十六进制)/ <n>(≥3 位纯数字)/
// <id>(≥24 字符且含数字的长 token);扩展名保留(能看出是 .jpg 还是 .ttml)。版本段(v8、2.0、1)
// 太短不会被碰。只动汇总的分组键,逐条的 Debug / Warn 行仍写真实路径 —— 排查时要知道是哪一个。
func normalizeAuditPath(p string) string {
	segs := strings.Split(p, "/")
	for i, seg := range segs {
		base, ext := seg, ""
		if dot := strings.LastIndexByte(seg, '.'); dot > 0 && len(seg)-dot <= 5 {
			base, ext = seg[:dot], seg[dot:]
		}
		switch {
		case base == "":
		case isUUIDToken(base):
			segs[i] = "<uuid>" + ext
		case len(base) >= 8 && allInSet(base, "0123456789abcdefABCDEF"):
			segs[i] = "<hex>" + ext
		case len(base) >= 3 && allInSet(base, "0123456789"):
			segs[i] = "<n>" + ext
		case len(base) >= 24 && strings.ContainsAny(base, "0123456789"):
			segs[i] = "<id>" + ext
		}
	}
	return strings.Join(segs, "/")
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
	durations   []time.Duration
}

var apiCallAgg = struct {
	mu      sync.Mutex
	windows map[string]*apiCallWindow
}{windows: map[string]*apiCallWindow{}}

func recordAPICall(target string, elapsed time.Duration, failed bool, now time.Time) {
	apiCallAgg.mu.Lock()
	defer apiCallAgg.mu.Unlock()
	w := apiCallAgg.windows[target]
	if w == nil {
		w = &apiCallWindow{first: now}
		apiCallAgg.windows[target] = w
	}
	w.last = now
	w.count++
	if failed {
		w.failed++
	}
	w.durations = append(w.durations, elapsed)
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
	sort.Slice(ready, func(i, j int) bool { return ready[i].target < ready[j].target })
	for _, d := range ready {
		sort.Slice(d.w.durations, func(i, j int) bool { return d.w.durations[i] < d.w.durations[j] })
		p50 := d.w.durations[len(d.w.durations)/2]
		max := d.w.durations[len(d.w.durations)-1]
		slog.Info("api call summary",
			"target", d.target,
			"count", d.w.count,
			"failed", d.w.failed,
			"p50_ms", p50.Milliseconds(),
			"max_ms", max.Milliseconds(),
			"span_s", int(d.w.last.Sub(d.w.first).Round(time.Second).Seconds()))
	}
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

// beginNetworkRound 开始一轮观察,返回的函数给出"从这一刻到调用它为止"的网络成败。
//
// ⚠️ 上面那个 networkLooksDown() **不能**用在常驻采集器里,只对一次性子命令成立:
// 它读的是进程启动以来的累计值,而 `failures == attempts` 这个条件只要进程早期有过
// 任何一次成功就永远不再成立 —— 开机时有网、后来断网,它一路报"网络正常"。
// 一次性 CLI 跑完就退出,累计值天然等于"这一次的",所以那边没问题。
//
// 并发说明:专辑预取会同时解析多首歌,别人的成功会混进这个差值里。方向是安全的 ——
// 混入成功只会让 failures < attempts,导致**漏报**(该说没网时没说),不会误报
// (把有网说成没网)。对一个界面提示来说,宁可漏报。
func beginNetworkRound() func() (attempts, failures int32) {
	a0 := atomic.LoadInt32(&networkAttemptCount)
	f0 := atomic.LoadInt32(&networkFailureCount)
	return func() (int32, int32) {
		return atomic.LoadInt32(&networkAttemptCount) - a0,
			atomic.LoadInt32(&networkFailureCount) - f0
	}
}

// roundLooksNetworkDown 判断某一轮观察的结果是不是"网络整体不通"。
// 判据跟 networkLooksDown 一致:至少试过 3 次、且全部失败。
func roundLooksNetworkDown(attempts, failures int32) bool {
	return attempts >= 3 && failures == attempts
}

// lyricsRoundConfirmsNoResult 判断这一轮"什么都没查到"是不是一个**可以下结论**的结果
// (2026-09-09,给 resolveEnrichAsync 那道全空守卫用,理由见那边的长注释)。
//
// 判据是"至少有一个请求真的成功了" —— 网络通、源确实回了话、就是没有这首歌。
//
// ⚠️ 刻意不写成 `!roundLooksNetworkDown(...)`:那个要 attempts>=3 **且**全挂才算不通,
// 于是"这一轮只发出去 1~2 个请求、而且全挂"(大部分源被熔断跳过时就是这个形状,见
// sourcebreaker.go)会从它的网眼里漏过去、被当成确证查无 —— 那明明更像没查成。
// 这里宁可严一点:漏判的代价只是这一轮继续显示"搜索歌词中…",下一轮自愈会再来;
// 误判的代价是把"没查成"写成"这首歌没有歌词"。
//
// attempts==0(整轮全命中缓存、一个请求都没发)同样不算数:它不构成任何证据。
func lyricsRoundConfirmsNoResult(attempts, failures int32) bool {
	return attempts > 0 && failures < attempts
}
