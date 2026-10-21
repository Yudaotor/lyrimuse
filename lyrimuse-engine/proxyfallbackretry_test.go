package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	neturl "net/url"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 直连失败、手上没有代理:当场补找一次(本机代理软件是后台找的),找到就经它重试。
func TestProxyFallbackLooksAgainAfterDirectFailure(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	want := &neturl.URL{Scheme: "http", Host: "127.0.0.1:9"}
	var found atomic.Bool
	var looked atomic.Int32
	savedF, savedA := fallbackProxyURL, fallbackProxyAfterDirectFailure
	fallbackProxyURL = func() *neturl.URL {
		if found.Load() {
			return want
		}
		return nil
	}
	fallbackProxyAfterDirectFailure = func() *neturl.URL {
		looked.Add(1)
		found.Store(true)
		return want
	}
	t.Cleanup(func() { fallbackProxyURL, fallbackProxyAfterDirectFailure = savedF, savedA })

	direct := &stubRoundTripper{err: errors.New("connect: connection refused")}
	viaProxy := &stubRoundTripper{body: "ok"}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}
	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatalf("补找到代理就经它重试, err=%v", err)
	}
	resp.Body.Close()
	if looked.Load() != 1 || viaProxy.calls != 1 {
		t.Fatalf("补找 %d 次、代理 %d 次", looked.Load(), viaProxy.calls)
	}

	// 单测注入了 proxyURL 的不补找。
	looked.Store(0)
	tr2 := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy, proxyURL: func() *neturl.URL { return nil }}
	if _, err := tr2.RoundTrip(newTestRequest(t)); err == nil || looked.Load() != 0 {
		t.Fatalf("注入了 proxyURL 不补找, err=%v 补找 %d 次", err, looked.Load())
	}
}

// 后面有代理可退时,直连没在预算内拿到连接,错误认得出是「没连上」。
func TestAttemptDirectNoConnectionError(t *testing.T) {
	srv := delayedServer(t, 0, "ok")
	slowDial := &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		var d net.Dialer
		return d.DialContext(ctx, network, addr)
	}}
	tr := &proxyFallbackTransport{direct: slowDial, directBudget: 30 * time.Millisecond}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/x", nil)
	_, err := tr.attemptDirect(req, true)
	if !errors.Is(err, errDirectNoConnection) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("得到 %v", err)
	}
}

// 只是没在预算内连上:第一次只走代理 proxyFallbackStickySlowFirst;再来一次照常翻倍。明确不通的照旧 10 分钟起。
func TestMarkStickySlowConnectFirstWindow(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	tr := &proxyFallbackTransport{}
	if w := tr.markSticky("slow.example", true); w != proxyFallbackStickySlowFirst {
		t.Fatalf("第一次慢: %s", w)
	}
	if !loadProxyFallbackHint("slow.example") {
		t.Fatal("磁盘提示也记下")
	}
	if w := tr.markSticky("slow.example", true); w != proxyStickyWindow(2) {
		t.Fatalf("第二次慢: %s, 期望 %s", w, proxyStickyWindow(2))
	}
	if w := tr.markSticky("dead.example", false); w != proxyFallbackSticky {
		t.Fatalf("明确不通: %s", w)
	}
}

// 同一个进程里多台主机同时写提示文件,一条都不丢。
func TestProxyFallbackHintConcurrentWrites(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	const n = 40
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			saveProxyFallbackHint(fmt.Sprintf("h%d.example", i), true)
		}(i)
	}
	wg.Wait()
	if got := len(readProxyFallbackHint().Until); got != n {
		t.Fatalf("记下 %d 台,期望 %d", got, n)
	}
}

// 整条走一遍:直连没在预算内连上、经代理救回来,这台主机只钉 proxyFallbackStickySlowFirst。
func TestProxyFallbackSlowConnectStickyWindow(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	srv := delayedServer(t, 0, "ok")
	slowDial := &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		var d net.Dialer
		return d.DialContext(ctx, network, addr)
	}}
	viaProxy := &stubRoundTripper{body: "proxy"}
	tr := &proxyFallbackTransport{direct: slowDial, viaProxy: viaProxy, directBudget: 30 * time.Millisecond,
		proxyURL: func() *neturl.URL { return &neturl.URL{Scheme: "http", Host: "127.0.0.1:9"} }}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/x", nil)
	resp, err := tr.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	until, ok := readProxyFallbackHint().Until[req.URL.Hostname()]
	if !ok {
		t.Fatal("没记下走代理")
	}
	if left := time.Until(time.Unix(until, 0)); left > proxyFallbackStickySlowFirst+time.Second || left < proxyFallbackStickySlowFirst-10*time.Second {
		t.Fatalf("窗口剩 %s, 期望约 %s", left, proxyFallbackStickySlowFirst)
	}
}
