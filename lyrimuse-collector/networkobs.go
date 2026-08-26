// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"log"
	"net/http"
	"net/url"
	"sync/atomic"
	"time"
)

// networkAttemptCount/networkFailureCount 给"联网搜索候选歌词"(searchcli.go)判断
// "七个源都没找到候选"到底是这首歌真的没有网络歌词,还是网络整体不通导致请求全部
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
//     真实网络请求的地方(Last.fm/ListenBrainz/歌词七源/推送/状态中继/翻译/取色/
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
	start := time.Now()
	resp, err := cli.Do(req)
	elapsed := time.Since(start)
	atomic.AddInt32(&networkAttemptCount, 1)
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
		log.Printf("api call: %s %s%s FAILED after %dms: %v",
			req.Method, req.URL.Host, req.URL.Path, elapsed.Milliseconds(), safeErr)
		return resp, err
	}
	if m := req.URL.Query().Get("method"); m != "" {
		log.Printf("api call: %s %s%s method=%s -> %d (%dms)",
			req.Method, req.URL.Host, req.URL.Path, m, resp.StatusCode, elapsed.Milliseconds())
	} else {
		log.Printf("api call: %s %s%s -> %d (%dms)",
			req.Method, req.URL.Host, req.URL.Path, resp.StatusCode, elapsed.Milliseconds())
	}
	return resp, err
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
