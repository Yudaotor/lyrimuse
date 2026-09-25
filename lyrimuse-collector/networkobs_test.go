// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 回归测试:doHTTPTracked/networkLooksDown 是"联网搜索候选歌词"判断
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

// "所有软件发出的对外请求全部都给我记录下日志",doHTTPTracked
// 从这时起是全局的审计日志出口,不只是网络计数器。这两个测试钉住这一层:①正常/失败
// 两条路径都真的写了一行日志;②日志行**不带 query string**——凭据(比如这里模拟的
// api_key)不应该出现在里面,这是这条功能的核心安全承诺,比单纯"格式对不对"更重要。
// 用 log.SetOutput 换成内存 buffer 是 Go 测试里安全捕获 log 包输出的标准做法——
// installLogSink() 只在真实运行时的 main() 里调用,go test 不会跑到它;此时 slog 的默认
// handler 正是经 log 包写出的,所以 slog.Warn / slog.Debug 也落进这个 buffer。逐次成功行
// 在 Debug(落盘的是按分钟的汇总),测试里把桥接等级放到 Debug 才看得到。
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

// 审计汇总:同一 target 一分钟一行,count / failed / p50 / max 齐全;窗口没满且
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
	recordAPICall("GET example.com/a", 100*time.Millisecond, false, false, t0)
	recordAPICall("GET example.com/a", 300*time.Millisecond, false, false, t0.Add(20*time.Second))
	recordAPICall("GET example.com/a", 900*time.Millisecond, true, false, t0.Add(40*time.Second))
	// b 那一次是 404:它既不进 failed,也要在汇总里单独现一列 notfound。
	recordAPICall("POST example.com/b", 50*time.Millisecond, false, true, t0.Add(10*time.Second))

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
	// 一个 404 都没有的窗口不该挂 notfound= —— 汇总行占日志四成,给每行加一个恒为 0
	// 的字段纯属浪费体积。
	if strings.Contains(out, "notfound") {
		t.Fatalf("窗口里没有 404,汇总行不该出现 notfound=,got: %q", out)
	}
	buf.Reset()
	flushAPICallSummaries(t0.Add(61*time.Second), true)
	if !strings.Contains(buf.String(), `target="POST example.com/b"`) || !strings.Contains(buf.String(), "count=1") {
		t.Fatalf("force flush must summarize the remaining window, got: %q", buf.String())
	}
	// 404 既要单独现列,又不能混进 failed —— 混进去的话 lrclib 那类源的失败率会常年虚高
	// 到 60%+,真故障(503)反而看不出来。
	if !strings.Contains(buf.String(), "notfound=1") {
		t.Fatalf("404 应在汇总里单独记成 notfound=1,got: %q", buf.String())
	}
	if !strings.Contains(buf.String(), "failed=0") {
		t.Fatalf("404 不该计进 failed,got: %q", buf.String())
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

// 传输层失败分类的端到端形状:真 http.Client(带 Client.Timeout)+ 挂住不答的解析器。
// 这正是评审抓到的坑 —— Client.Timeout 会把错误换成 *http.timeoutError(纯字符串),错误链里
// 没有 *net.DNSError;只有 doHTTPTracked 挂的 httptrace 轨迹能证明"死在 DNS 阶段"。
// 用 lyricSourceForHost 认得的主机名(music.163.com),但解析器根本不发包,不碰真实网络。
func TestDoHTTPTracked_HungDNSClassifiedAsDNSFailed(t *testing.T) {
	saved := lyricSourceBreakerShared
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() { lyricSourceBreakerShared = saved })

	hungResolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}
	cli := &http.Client{
		Timeout: 300 * time.Millisecond,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Resolver: hungResolver}).DialContext,
		},
	}
	req, _ := http.NewRequest(http.MethodGet, "http://music.163.com/api/search/get?s=x", nil)
	_, err := doHTTPTracked(cli, req)
	if err == nil {
		t.Fatal("挂住的解析器竟然成功了")
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		t.Logf("注意:这个 Go 版本的错误链里居然还带着 DNSError(%v),轨迹那条判据没被真正考到", err)
	}
	got := lyricSourceBreakerShared.transportFailureCodes()
	if got["netease"] != lyricFailureReasonDNSFailed {
		t.Fatalf("netease 应为 dns_failed,实际 %q(err=%v)", got["netease"], err)
	}
}

// 对照:解析成功、连接被拒 → connect_failed(DNS 轨迹走完且无错,不能误归 dns)。
func TestDoHTTPTracked_RefusedConnectionClassifiedAsConnectFailed(t *testing.T) {
	saved := lyricSourceBreakerShared
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() { lyricSourceBreakerShared = saved })

	// 拿一个刚释放的本地端口,保证 connection refused。
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	localResolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return nil, errors.New("unused") // 下面的 Dialer 直接改写目标地址,不会走到这里
		},
	}
	dialer := &net.Dialer{Resolver: localResolver}
	cli := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				// 把 c.y.qq.com:80 改指到本机已关闭的端口。DNS 阶段在这里被跳过(没有钩子会触发),
				// 分类只能靠错误链 —— connection refused 不含 DNSError → connect_failed。
				return dialer.DialContext(ctx, network, net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
			},
		},
	}
	req, _ := http.NewRequest(http.MethodGet, "http://c.y.qq.com/soso/x", nil)
	if _, err := doHTTPTracked(cli, req); err == nil {
		t.Fatal("连到已关闭端口竟然成功了")
	}
	got := lyricSourceBreakerShared.transportFailureCodes()
	if got["qq"] != lyricFailureReasonConnectFailed {
		t.Fatalf("qq 应为 connect_failed,实际 %q", got["qq"])
	}
}

// 状态码 →(failed, notfound)的映射只存在于 doHTTPTracked 里。上面那条用例是直接调
// recordAPICall 传参的,绕过了这一步 —— 变异测试实测:把 `failed := ... && !notFound`
// 改回 `>= 400`,那条照样全绿。这里走真实 HTTP,把这一步单独钉死。
func TestDoHTTPTracked404IsNotAFailure(t *testing.T) {
	apiCallAgg.mu.Lock()
	apiCallAgg.windows = map[string]*apiCallWindow{}
	apiCallAgg.mu.Unlock()

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/gone" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	for _, path := range []string{"/gone", "/broken"} {
		req, err := http.NewRequest(http.MethodGet, srv.URL+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		resp, err := doHTTPTracked(srv.Client(), req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
	}

	// 逐条行:404 不该有(amll 三天那 18530 行 WARN 就是这么来的),500 仍要有。
	out := buf.String()
	if strings.Contains(out, "/gone") {
		t.Errorf("404 是正常应答,不该逐条记 WARN,got: %q", out)
	}
	if !strings.Contains(out, "/broken") {
		t.Errorf("500 是真故障,仍该逐条记 WARN,got: %q", out)
	}

	buf.Reset()
	flushAPICallSummaries(time.Now(), true)
	var gone, broken string
	for _, line := range strings.Split(buf.String(), "\n") {
		switch {
		case strings.Contains(line, "/gone"):
			gone = line
		case strings.Contains(line, "/broken"):
			broken = line
		}
	}
	if gone == "" || broken == "" {
		t.Fatalf("两个目标都该有汇总行,got: %q", buf.String())
	}
	// 汇总口径:404 进 notfound、不进 failed。混进去的话 lrclib 那类源的失败率会常年
	// 虚高到 60%+,真故障(503)反而挑不出来。
	if !strings.Contains(gone, "failed=0") || !strings.Contains(gone, "notfound=1") {
		t.Errorf("404 该记成 failed=0 notfound=1,got: %q", gone)
	}
	if !strings.Contains(broken, "failed=1") {
		t.Errorf("500 该记成 failed=1,got: %q", broken)
	}
	if strings.Contains(broken, "notfound") {
		t.Errorf("500 不是 404,不该出现 notfound=,got: %q", broken)
	}
}
