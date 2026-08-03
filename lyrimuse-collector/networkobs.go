// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"net/http"
	"sync/atomic"
)

// networkAttemptCount/networkFailureCount 给"联网搜索候选歌词"(searchcli.go)判断
// "五个源都没找到候选"到底是这首歌真的没有网络歌词,还是网络整体不通导致请求全部
// 发不出去用——2026-08-02 补上,之前 netease/qq/kugou/lrclib/musixmatch 五个源各自
// 内部把 http 请求失败和"服务器正常响应、只是没查到"统统当空结果处理,两种情况在
// UI 上完全分不清。collector search-lyrics 是一次性子命令(一个独立进程执行一次
// 就退出,不是常驻服务里反复调用的路径),这里用包级变量累计"这次进程调用期间"的
// 请求总数/失败数,不需要在两次搜索之间显式清零。
//
// 只有 http.Client.Do 本身返回 error(DNS 解析失败、连接被拒、超时——请求根本没有
// 发出去或者没有收到任何响应)才算一次网络层失败;请求确实发出去、拿到了响应(哪怕
// 状态码不是 200,或者响应内容解析出来是空)算一次成功的网络尝试,不计入失败——那
// 说明网络本身没问题,只是这次查询没有命中。
var (
	networkAttemptCount int32
	networkFailureCount int32
)

// doHTTPTracked 是 http.Client.Do 的一层透明包装——只把"请求本身有没有发出去、
// 收到响应"这个信号记一笔,完全不改变调用方原有的返回值/错误处理逻辑,调用方该怎么
// 处理 resp/err 还怎么处理,行为不变。五个歌词源(netease/qq/kugou/lrclib/
// musixmatch)所有真正发起网络请求的地方都改用这个包装,替换原来直接调
// (&http.Client{...}).Do(req) 的写法。
func doHTTPTracked(cli *http.Client, req *http.Request) (*http.Response, error) {
	resp, err := cli.Do(req)
	atomic.AddInt32(&networkAttemptCount, 1)
	if err != nil {
		atomic.AddInt32(&networkFailureCount, 1)
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
