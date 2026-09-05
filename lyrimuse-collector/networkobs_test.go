// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 2026-08-02 回归测试:doHTTPTracked/networkLooksDown 是"联网搜索候选歌词"判断
// "所有源都没找到"到底是真没有还是网络不通的核心逻辑,读增量(测试前后的差值)而不是
// 绝对值——networkAttemptCount/networkFailureCount 是包级变量,同一个测试二进制里
// 别的测试(或将来新增的测试)也可能调用到 doHTTPTracked,不能假设进测试时一定是
// 零值,只看这个测试自己造成的变化量才是稳的。
func attemptDelta(before int32) int32 { return atomic.LoadInt32(&networkAttemptCount) - before }
func failureDelta(before int32) int32 { return atomic.LoadInt32(&networkFailureCount) - before }

func TestDoHTTPTracked_SuccessfulResponseNotCountedAsFailure(t *testing.T) {
	// 服务器正常响应(即使是非 200 状态码)不算网络层失败——这是区分"网络不通"和
	// "服务器说没有"的关键:后者说明请求确实发出去、收到响应了。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	attemptsBefore := atomic.LoadInt32(&networkAttemptCount)
	failuresBefore := atomic.LoadInt32(&networkFailureCount)

	req, err := http.NewRequest(http.MethodGet, srv.URL, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err != nil {
		t.Fatalf("expected no transport error, got: %v", err)
	}
	resp.Body.Close()

	if got := attemptDelta(attemptsBefore); got != 1 {
		t.Fatalf("expected exactly 1 new attempt recorded, got %d", got)
	}
	if got := failureDelta(failuresBefore); got != 0 {
		t.Fatalf("a successful (even non-200) response must not count as a network failure, got %d new failures", got)
	}
}

func TestDoHTTPTracked_TransportErrorCountsAsFailure(t *testing.T) {
	// 端口 0 上的临时监听器一开就关掉,连接必然被拒绝——这是可靠触发"请求根本没有
	// 发出去/没有收到任何响应"这类真实网络层错误的标准手法,不依赖任何真实外部网络。
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close() // 立刻关闭,这个地址上不再有任何东西监听

	attemptsBefore := atomic.LoadInt32(&networkAttemptCount)
	failuresBefore := atomic.LoadInt32(&networkFailureCount)

	req, err := http.NewRequest(http.MethodGet, "http://"+addr, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	_, err = doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err == nil {
		t.Fatalf("expected a transport-level error connecting to a closed port")
	}

	if got := attemptDelta(attemptsBefore); got != 1 {
		t.Fatalf("expected exactly 1 new attempt recorded, got %d", got)
	}
	if got := failureDelta(failuresBefore); got != 1 {
		t.Fatalf("expected exactly 1 new failure recorded, got %d", got)
	}
}

// 2026-08-26 用户要求"所有软件发出的对外请求全部都给我记录下日志",doHTTPTracked
// 从这时起是全局的审计日志出口,不只是网络计数器。这两个测试钉住这一层:①正常/失败
// 两条路径都真的写了一行日志;②日志行**不带 query string**——凭据(比如这里模拟的
// api_key)不应该出现在里面,这是这条功能的核心安全承诺,比单纯"格式对不对"更重要。
// 用 log.SetOutput 换成内存 buffer 是 Go 测试里安全捕获 log 包输出的标准做法——
// installLogSink() 只在真实运行时的 main() 里调用,go test 不会跑到它;此时 slog 的默认
// handler 正是经 log 包写出的,所以 slog.Warn / slog.Debug 也落进这个 buffer。逐次成功行
// 在 Debug(2026-09-05 起,落盘的是按分钟的汇总),测试里把桥接等级放到 Debug 才看得到。
// defer 全部换回去,不影响其它测试。
func TestDoHTTPTracked_LogsSuccessWithoutQueryString(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)
	defer slog.SetLogLoggerLevel(slog.SetLogLoggerLevel(slog.LevelDebug))

	req, err := http.NewRequest(http.MethodGet, srv.URL+"/2.0/?method=track.getinfo&api_key=SECRET1234567890", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err != nil {
		t.Fatalf("expected no transport error, got: %v", err)
	}
	resp.Body.Close()

	logged := buf.String()
	if !strings.Contains(logged, "200") {
		t.Fatalf("expected the status code to appear in the log line, got: %q", logged)
	}
	if !strings.Contains(logged, "method=track.getinfo") {
		t.Fatalf("expected the safe 'method' query param to be surfaced, got: %q", logged)
	}
	if strings.Contains(logged, "SECRET1234567890") || strings.Contains(logged, "api_key") {
		t.Fatalf("api_key must never appear in the audit log line, got: %q", logged)
	}
}

func TestDoHTTPTracked_LogsFailure(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	req, err := http.NewRequest(http.MethodGet, "http://"+addr+"/submit-listens?token=SECRETTOKEN1234", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	_, err = doHTTPTracked(&http.Client{Timeout: 2 * time.Second}, req)
	if err == nil {
		t.Fatalf("expected a transport-level error connecting to a closed port")
	}

	logged := buf.String()
	if !strings.Contains(logged, "FAILED") {
		t.Fatalf("expected the failure path to be logged as FAILED, got: %q", logged)
	}
	if strings.Contains(logged, "SECRETTOKEN1234") {
		t.Fatalf("token must never appear in the audit log line, got: %q", logged)
	}
}

func TestNetworkLooksDown_RequiresMinimumAttemptsAndAllFailed(t *testing.T) {
	// 直接操纵包级计数器本身来测 networkLooksDown 的判断逻辑,不需要真的再发请求——
	// 上面两个测试已经验证过 doHTTPTracked 记录计数的正确性,这里只测纯粹的判断规则。
	reset := func(attempts, failures int32) {
		atomic.StoreInt32(&networkAttemptCount, attempts)
		atomic.StoreInt32(&networkFailureCount, failures)
	}
	defer reset(atomic.LoadInt32(&networkAttemptCount), atomic.LoadInt32(&networkFailureCount)) // 恢复,不影响其它测试

	reset(0, 0)
	if networkLooksDown() {
		t.Fatalf("zero attempts must never be judged as network-down")
	}

	reset(2, 2)
	if networkLooksDown() {
		t.Fatalf("too few attempts (2) even if all failed must not be judged as network-down — avoids misjudging \"this song has little metadata so few requests were made\" as \"network is down\"")
	}

	reset(5, 3)
	if networkLooksDown() {
		t.Fatalf("some requests succeeded — must not be judged as network-down")
	}

	reset(5, 5)
	if !networkLooksDown() {
		t.Fatalf("enough attempts, all failed — must be judged as network-down")
	}
}

// 审计汇总(2026-09-05):同一 target 一分钟一行,count / failed / p50 / max 齐全;窗口没满且
// 不 force 时什么都不写;结算后窗口清空。
func TestAPICallSummary_AggregatesPerTargetPerMinute(t *testing.T) {
	apiCallAgg.mu.Lock()
	apiCallAgg.windows = map[string]*apiCallWindow{}
	apiCallAgg.mu.Unlock()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	t0 := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	recordAPICall("GET example.com/a", 100*time.Millisecond, false, t0)
	recordAPICall("GET example.com/a", 300*time.Millisecond, false, t0.Add(20*time.Second))
	recordAPICall("GET example.com/a", 900*time.Millisecond, true, t0.Add(40*time.Second))
	recordAPICall("POST example.com/b", 50*time.Millisecond, false, t0.Add(10*time.Second))

	flushAPICallSummaries(t0.Add(30*time.Second), false)
	if buf.Len() != 0 {
		t.Fatalf("window not yet a minute old must not be summarized, got: %q", buf.String())
	}
	flushAPICallSummaries(t0.Add(61*time.Second), false)
	out := buf.String()
	for _, want := range []string{
		`target="GET example.com/a"`, "count=3", "failed=1", "p50_ms=300", "max_ms=900", "span_s=40",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("summary line missing %s, got: %q", want, out)
		}
	}
	if strings.Contains(out, "example.com/b") {
		t.Fatalf("target b opened at +10s must not be summarized at +61s, got: %q", out)
	}
	buf.Reset()
	flushAPICallSummaries(t0.Add(61*time.Second), true)
	if !strings.Contains(buf.String(), `target="POST example.com/b"`) || !strings.Contains(buf.String(), "count=1") {
		t.Fatalf("force flush must summarize the remaining window, got: %q", buf.String())
	}
	buf.Reset()
	flushAPICallSummaries(t0.Add(time.Hour), true)
	if buf.Len() != 0 {
		t.Fatalf("summarized windows must be cleared, got: %q", buf.String())
	}
}

// 汇总分组键的路径归一化:资源 ID 抹成占位,版本段与普通路径不动。
func TestNormalizeAuditPath(t *testing.T) {
	cases := map[string]string{
		"/artwork/f8863d3086cd50bf.jpg":                     "/artwork/<hex>.jpg",
		"/ws/2/artist/4c8ead39-b9df-4c56-a27c-51bc049cfd48": "/ws/2/artist/<uuid>",
		"/2.0/":                                "/2.0/",
		"/v8/fcg-bin/fcg_play_single_song.fcg": "/v8/fcg-bin/fcg_play_single_song.fcg",
		"/1/submit-listens":                    "/1/submit-listens",
		"/api/search/get":                      "/api/search/get",
		"/lyrics/1234567/lrc":                  "/lyrics/<n>/lrc",
		"/dl/ABCDEFGHIJKLMNOPQRSTUVWX0123456789/song.ttml": "/dl/<id>/song.ttml",
		"": "",
	}
	for in, want := range cases {
		if got := normalizeAuditPath(in); got != want {
			t.Fatalf("normalizeAuditPath(%q) = %q, want %q", in, got, want)
		}
	}
}
