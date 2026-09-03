package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---- dohDialRace:并发拨号 ----

// blackHoleDialer 造一份可控的拨号行为:blackHoles 里的地址永远不返回(直到 ctx 被取消,
// 模拟 SYN 石沉大海),其余地址在 delay 之后返回一条可关闭的假连接。
type raceDialLog struct {
	mu     sync.Mutex
	closed map[string]bool
}

type fakeConn struct {
	net.Conn
	addr   string
	logRef *raceDialLog
}

func (c *fakeConn) Close() error {
	c.logRef.mu.Lock()
	c.logRef.closed[c.addr] = true
	c.logRef.mu.Unlock()
	return c.Conn.Close()
}

func makeRaceDialer(logRef *raceDialLog, blackHoles map[string]bool, delay map[string]time.Duration) (
	func(context.Context, string, string) (net.Conn, error), func()) {
	var pipes []net.Conn
	var mu sync.Mutex
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		if blackHoles[addr] {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		if d := delay[addr]; d > 0 {
			select {
			case <-time.After(d):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		a, b := net.Pipe()
		mu.Lock()
		pipes = append(pipes, a, b)
		mu.Unlock()
		return &fakeConn{Conn: a, addr: addr, logRef: logRef}, nil
	}
	cleanup := func() {
		mu.Lock()
		defer mu.Unlock()
		for _, p := range pipes {
			_ = p.Close()
		}
	}
	return dial, cleanup
}

// 这是 2026-09-03 那个真 bug 的回归测试:**黑洞排在第一个**。
// 串行版本(修复前)会把整个预算耗在第一个地址上,永远轮不到第二个;并发版本必须立刻拿到
// 第二个。断言"很快返回"而不只是"返回了" —— 串行版本最终也会返回,只是要等到超时,那正是
// 用户看到的"这个源整整半小时不可用"。
func TestDohDialRaceBlackHoleFirstDoesNotBlockGoodAddress(t *testing.T) {
	logRef := &raceDialLog{closed: map[string]bool{}}
	dial, cleanup := makeRaceDialer(logRef, map[string]bool{"10.0.0.1:443": true}, nil)
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()
	conn, err := dohDialRaceWith(ctx, dial, "tcp", []string{"10.0.0.1", "10.0.0.2"}, "443")
	elapsed := time.Since(start)

	if err != nil || conn == nil {
		t.Fatalf("应该拿到第二个地址的连接, 得到 conn=%v err=%v", conn, err)
	}
	if got := conn.(*fakeConn).addr; got != "10.0.0.2:443" {
		t.Errorf("赢家 = %s, 期望 10.0.0.2:443", got)
	}
	if elapsed > 500*time.Millisecond {
		t.Errorf("耗时 %v —— 黑洞把好地址挡住了,并发拨号没生效", elapsed)
	}
	conn.Close()
}

// 顺序反过来同样成立(好地址在前),证明上面那条不是碰巧。
func TestDohDialRaceGoodAddressFirst(t *testing.T) {
	logRef := &raceDialLog{closed: map[string]bool{}}
	dial, cleanup := makeRaceDialer(logRef, map[string]bool{"10.0.0.2:443": true}, nil)
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := dohDialRaceWith(ctx, dial, "tcp", []string{"10.0.0.1", "10.0.0.2"}, "443")
	if err != nil || conn == nil {
		t.Fatalf("conn=%v err=%v", conn, err)
	}
	if got := conn.(*fakeConn).addr; got != "10.0.0.1:443" {
		t.Errorf("赢家 = %s, 期望 10.0.0.1:443", got)
	}
	conn.Close()
}

// 慢一步也连上的那条必须被关掉,不能泄漏 fd。
func TestDohDialRaceClosesLoser(t *testing.T) {
	logRef := &raceDialLog{closed: map[string]bool{}}
	dial, cleanup := makeRaceDialer(logRef, nil, map[string]time.Duration{"10.0.0.2:443": 60 * time.Millisecond})
	defer cleanup()

	conn, err := dohDialRaceWith(context.Background(), dial, "tcp", []string{"10.0.0.1", "10.0.0.2"}, "443")
	if err != nil || conn == nil {
		t.Fatalf("conn=%v err=%v", conn, err)
	}
	if got := conn.(*fakeConn).addr; got != "10.0.0.1:443" {
		t.Fatalf("赢家 = %s, 期望快的那个 10.0.0.1:443", got)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		logRef.mu.Lock()
		done := logRef.closed["10.0.0.2:443"]
		logRef.mu.Unlock()
		if done {
			conn.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("输家的连接没有被关掉 —— 收尾 goroutine 漏了,会泄漏 fd")
}

func TestDohDialRaceAllFailAndEmpty(t *testing.T) {
	failing := func(ctx context.Context, network, addr string) (net.Conn, error) {
		return nil, errors.New("boom " + addr)
	}
	if conn, err := dohDialRaceWith(context.Background(), failing, "tcp", []string{"10.0.0.1", "10.0.0.2"}, "443"); conn != nil || err == nil {
		t.Errorf("全失败应返回 (nil, err), 得到 conn=%v err=%v", conn, err)
	}
	// ips 为空 → (nil, nil),由 dohDialContext 退回系统解析。
	if conn, err := dohDialRaceWith(context.Background(), failing, "tcp", nil, "443"); conn != nil || err != nil {
		t.Errorf("空地址表应返回 (nil, nil), 得到 conn=%v err=%v", conn, err)
	}
}

// ---- proxyFallbackTransport ----

type stubRoundTripper struct {
	err   error
	body  string
	calls int32
}

func (s *stubRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	atomic.AddInt32(&s.calls, 1)
	if s.err != nil {
		return nil, s.err
	}
	return &http.Response{
		StatusCode: 200,
		Body:       io.NopCloser(strings.NewReader(s.body)),
		Header:     http.Header{},
		Request:    req,
	}, nil
}

// newFallbackTestEnv 把测试跟真实环境隔开:HOME 换成临时目录(磁盘提示文件不许写进用户
// 真正的 ~/.config/lyrimuse),HTTPS_PROXY 指向一个真的听着的本地端口(让 systemProxyURL
// 的探活能过),系统代理缓存清零。
func newFallbackTestEnv(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	t.Setenv("HTTPS_PROXY", "http://"+ln.Addr().String())
	resetSystemProxyCacheForTest()
	t.Cleanup(resetSystemProxyCacheForTest)
}

func newTestRequest(t *testing.T) *http.Request {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "https://apic-appmobile.musixmatch.com/ws/1.1/token.get", nil)
	if err != nil {
		t.Fatal(err)
	}
	return req
}

func TestProxyFallbackUsesProxyWhenDirectFails(t *testing.T) {
	newFallbackTestEnv(t)
	direct := &stubRoundTripper{err: errors.New("i/o timeout")}
	viaProxy := &stubRoundTripper{body: `{"ok":1}`}
	blocked := 0
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy, onBlocked: func() { blocked++ }}

	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatalf("直连失败时应该被代理救回来, 得到 err=%v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != `{"ok":1}` {
		t.Errorf("body = %q", body)
	}
	if blocked != 0 {
		t.Errorf("代理成功了不该报 blocked, 报了 %d 次", blocked)
	}
	if direct.calls != 1 || viaProxy.calls != 1 {
		t.Errorf("direct=%d viaProxy=%d, 期望各 1 次", direct.calls, viaProxy.calls)
	}

	// 粘性:第二个请求应该**直接**走代理,不再白等一次直连。
	resp2, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatalf("粘性期内应继续走代理, err=%v", err)
	}
	resp2.Body.Close()
	if direct.calls != 1 {
		t.Errorf("粘性没生效:直连又被试了 %d 次(期望仍是 1)", direct.calls)
	}
	if viaProxy.calls != 2 {
		t.Errorf("viaProxy = %d 次, 期望 2", viaProxy.calls)
	}

	// 磁盘提示写下来了 —— 这是给一次性 CLI 子进程用的,它们内存粘性一律归零。
	if !loadProxyFallbackHint("apic-appmobile.musixmatch.com") {
		t.Error("磁盘提示没写下来,新起的 CLI 进程还要再白等一遍直连")
	}
	if _, err := os.Stat(proxyFallbackHintPath()); err != nil {
		t.Errorf("提示文件不存在: %v", err)
	}
}

func TestProxyFallbackDirectSuccessNeverTouchesProxy(t *testing.T) {
	newFallbackTestEnv(t)
	direct := &stubRoundTripper{body: "ok"}
	viaProxy := &stubRoundTripper{body: "should not be used"}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}

	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "ok" {
		t.Errorf("body = %q, 期望走直连", body)
	}
	// 这条是整个改动的核心纪律:代理在这台机器上是更差的通道(见 systemproxy.go 头注的
	// Last.fm 实测),直连正常时一个包都不该经过它。
	if viaProxy.calls != 0 {
		t.Errorf("直连成功却动了代理 %d 次", viaProxy.calls)
	}
	if !loadProxyFallbackHint("apic-appmobile.musixmatch.com") == false {
		t.Error("直连成功不该写代理提示")
	}
}

func TestProxyFallbackReportsBlockedWhenBothFail(t *testing.T) {
	newFallbackTestEnv(t)
	direct := &stubRoundTripper{err: errors.New("i/o timeout")}
	viaProxy := &stubRoundTripper{err: errors.New("proxy refused")}
	blocked := 0
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy, onBlocked: func() { blocked++ }}

	_, err := tr.RoundTrip(newTestRequest(t))
	if err == nil {
		t.Fatal("两条路都失败应该返回错误")
	}
	// 报的是**直连**那次的错:上层真正关心的是我们本来想走的那条路怎么了。
	if !strings.Contains(err.Error(), "i/o timeout") {
		t.Errorf("err = %v, 期望是直连那次的错误", err)
	}
	if blocked != 1 {
		t.Errorf("onBlocked 调了 %d 次, 期望 1", blocked)
	}
}

func TestProxyFallbackReportsBlockedWhenNoProxyConfigured(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// 没有任何代理:环境变量清空,系统设置那边解析不出来也走同一条路。
	for _, k := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"} {
		t.Setenv(k, "")
	}
	resetSystemProxyCacheForTest()
	defer resetSystemProxyCacheForTest()
	// 直接把缓存钉成"没有代理",免得这台机器真实的系统代理状态影响用例的可复现性。
	systemProxyMu.Lock()
	systemProxyValue, systemProxyReadAt = nil, time.Now()
	systemProxyMu.Unlock()

	direct := &stubRoundTripper{err: errors.New("i/o timeout")}
	viaProxy := &stubRoundTripper{body: "unreachable"}
	blocked := 0
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy, onBlocked: func() { blocked++ }}

	if _, err := tr.RoundTrip(newTestRequest(t)); err == nil {
		t.Fatal("没有代理可用时应该如实报直连的错")
	}
	if viaProxy.calls != 0 {
		t.Errorf("没有可用代理却还是走了代理 %d 次", viaProxy.calls)
	}
	if blocked != 1 {
		t.Errorf("onBlocked 调了 %d 次, 期望 1", blocked)
	}
}

// 粘着走代理、代理却坏了(用户关掉了 / 换了端口):必须清掉粘性并当场回直连重试,
// 否则会一直往一个死代理上撞,而直连说不定早就恢复了。
func TestProxyFallbackFallsBackToDirectWhenStickyProxyDies(t *testing.T) {
	newFallbackTestEnv(t)
	host := "apic-appmobile.musixmatch.com"
	saveProxyFallbackHint(host, true)
	if !loadProxyFallbackHint(host) {
		t.Fatal("前置条件没建立:磁盘提示应该存在")
	}

	direct := &stubRoundTripper{body: "direct back online"}
	viaProxy := &stubRoundTripper{err: errors.New("connection refused")}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}

	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatalf("代理死了应该回落直连, err=%v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "direct back online" {
		t.Errorf("body = %q", body)
	}
	if viaProxy.calls != 1 || direct.calls != 1 {
		t.Errorf("viaProxy=%d direct=%d, 期望各 1 次", viaProxy.calls, direct.calls)
	}
	if loadProxyFallbackHint(host) {
		t.Error("代理失败后磁盘提示应该被清掉,否则下一个 CLI 进程还会先撞死代理")
	}
}

// 磁盘提示是给跨进程用的:一个全新的 transport(等价于新起的 CLI 进程)读到提示就该
// 直接走代理,不再白等一次直连探路。
func TestProxyFallbackHintCrossesProcessBoundary(t *testing.T) {
	newFallbackTestEnv(t)
	saveProxyFallbackHint("apic-appmobile.musixmatch.com", true)

	direct := &stubRoundTripper{err: errors.New("should not be tried")}
	viaProxy := &stubRoundTripper{body: "via proxy"}
	fresh := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy} // stickyUntil 是零值

	resp, err := fresh.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if direct.calls != 0 {
		t.Errorf("读到磁盘提示后仍然试了 %d 次直连 —— 跨进程粘性没生效", direct.calls)
	}
}

// 带 body 的请求不做 fallback:req.Clone 不复制 body,重放过去会是个空 body 的请求。
func TestProxyFallbackSkipsRetryForRequestsWithBody(t *testing.T) {
	newFallbackTestEnv(t)
	direct := &stubRoundTripper{err: errors.New("i/o timeout")}
	viaProxy := &stubRoundTripper{body: "should not be used"}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}

	req, err := http.NewRequest(http.MethodPost, "https://apic-appmobile.musixmatch.com/x", strings.NewReader("payload"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tr.RoundTrip(req); err == nil {
		t.Fatal("期望直连的错误原样返回")
	}
	if viaProxy.calls != 0 {
		t.Errorf("带 body 的请求被重放到代理 %d 次", viaProxy.calls)
	}
}

// attempt 把 per-attempt 的 context 挂在 Body 上、等 Close 才释放。如果直接 cancel,
// 调用方读 body 会拿到 "context canceled" —— 看起来像服务器提前关了连接,极难排查。
func TestProxyFallbackBodyReadableAfterRoundTrip(t *testing.T) {
	newFallbackTestEnv(t)
	tr := &proxyFallbackTransport{
		direct:   &stubRoundTripper{body: "0123456789"},
		viaProxy: &stubRoundTripper{err: errors.New("unused")},
	}
	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		t.Fatalf("读 body 失败: %v —— per-attempt ctx 被提前 cancel 了", readErr)
	}
	if string(body) != "0123456789" {
		t.Errorf("body = %q", body)
	}
	if err := resp.Body.Close(); err != nil {
		t.Errorf("Close 报错: %v", err)
	}
	// 重复 Close 不能 panic(sync.Once 保护 cancel)。
	_ = resp.Body.Close()
}
