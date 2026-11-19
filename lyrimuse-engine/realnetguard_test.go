package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 单测不连真实网络的守卫,TestMain 里装(见 15 章决策 125)。共享歌词源传输层的系统 DNS / DoH / 拨号三个注入点,
// 以及 http.DefaultTransport 的拨号器(DefaultClient 和没设 Transport 的 client 都走它):目标不是回环地址就不发,
// 当场返回 errRealNetworkInTest。用例结束后还在跑的后台协程同样拦,它就拿不到真实响应、也没法经同 URL 合并
// (httpcoalesce.go)交给后面的用例。
//
// 拦下的错误同时是 context.Canceled:熔断、出站统计、网络轮次都不把取消记成失败,漏网的请求不会让后面的用例
// 看到某个源被熔断。系统 DNS 那一步答一个不可路由的地址(192.0.2.1)、不报错,免得给这台主机记上 DNS 负缓存。
//
// 按设计打真实网络的用例在 skipLiveInShort 之后放行(allowRealNetwork)。管不到的:各文件自己 new 的 Transport
// (推送、中转、代理探测、lxmusic 本机接口)。整套跑完打一行拦了几次;LYRIMUSE_NET_AUDIT=1 时每拦一次当场打出
// 主机,配合 -v 看是哪个用例前后发的。
var errRealNetworkInTest = errors.New("单测不许连真实网络")

var (
	realNetworkAllowed atomic.Int32
	realNetworkMu      sync.Mutex
	realNetworkHits    = map[string]int{}
)

func isLoopbackHost(host string) bool {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func realNetworkOK(host string) bool {
	return isLoopbackHost(host) || realNetworkAllowed.Load() > 0
}

// blockRealDial:addr 是 host:port。放行返回 nil。
func blockRealDial(addr string) error {
	host := addr
	if h, _, err := net.SplitHostPort(addr); err == nil {
		host = h
	}
	if realNetworkOK(host) {
		return nil
	}
	realNetworkMu.Lock()
	realNetworkHits[host]++
	realNetworkMu.Unlock()
	if os.Getenv("LYRIMUSE_NET_AUDIT") != "" {
		fmt.Fprintf(os.Stderr, "REALNET-BLOCKED %s\n", addr)
	}
	return fmt.Errorf("%w: %s: %w", errRealNetworkInTest, addr, context.Canceled)
}

func installRealNetworkGuard() {
	sysLookup, doh, dial := lyricSourceSystemLookup, lyricSourceDoHLookup, lyricSourceDial
	lyricSourceSystemLookup = func(ctx context.Context, host string) ([]net.IPAddr, error) {
		if !realNetworkOK(host) {
			return []net.IPAddr{{IP: net.IPv4(192, 0, 2, 1)}}, nil
		}
		return sysLookup(ctx, host)
	}
	lyricSourceDoHLookup = func(ctx context.Context, host string) []string {
		if !realNetworkOK(host) {
			return nil
		}
		return doh(ctx, host)
	}
	lyricSourceDial = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if err := blockRealDial(addr); err != nil {
			return nil, err
		}
		return dial(ctx, network, addr)
	}
	dt := http.DefaultTransport.(*http.Transport)
	base := dt.DialContext
	dt.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if err := blockRealDial(addr); err != nil {
			return nil, err
		}
		return base(ctx, network, addr)
	}
}

// allowRealNetwork:按设计打真实网络的用例在它结束前放行。
func allowRealNetwork(t *testing.T) {
	t.Helper()
	realNetworkAllowed.Add(1)
	t.Cleanup(func() { realNetworkAllowed.Add(-1) })
}

// reportRealNetworkHits:整套跑完调一次。LYRIMUSE_NET_AUDIT=1 时先等 2 秒,让最后几个用例留下的后台协程把请求发完再数。
func reportRealNetworkHits() {
	if os.Getenv("LYRIMUSE_NET_AUDIT") != "" {
		time.Sleep(2 * time.Second)
	}
	realNetworkMu.Lock()
	defer realNetworkMu.Unlock()
	if len(realNetworkHits) == 0 {
		return
	}
	total := 0
	hosts := make([]string, 0, len(realNetworkHits))
	for h, n := range realNetworkHits {
		total += n
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	fmt.Fprintf(os.Stderr, "单测里有 %d 次真实出站被拦下(没发出去),%d 台主机;LYRIMUSE_NET_AUDIT=1 加 -v 看是哪个用例前后发的\n",
		total, len(hosts))
	if os.Getenv("LYRIMUSE_NET_AUDIT") != "" {
		for _, h := range hosts {
			fmt.Fprintf(os.Stderr, "  %4d 次  %s\n", realNetworkHits[h], h)
		}
	}
}

// 守卫本身:DefaultClient 与歌词源共享传输层发往外网的请求当场失败、错误可按「取消」认,回环地址照常通。
func TestRealNetworkGuardBlocksOutbound(t *testing.T) {
	t.Cleanup(func() {
		realNetworkMu.Lock()
		delete(realNetworkHits, "guard-probe.invalid")
		delete(realNetworkHits, "search.kuwo.cn")
		realNetworkMu.Unlock()
	})
	for name, cli := range map[string]*http.Client{"DefaultClient": http.DefaultClient, "歌词源": lyricHTTPClient(time.Second)} {
		host := "guard-probe.invalid"
		if name == "歌词源" {
			host = "search.kuwo.cn"
		}
		start := time.Now()
		resp, err := cli.Get("https://" + host + "/r.s")
		if resp != nil {
			resp.Body.Close()
		}
		if !errors.Is(err, errRealNetworkInTest) || !errors.Is(err, context.Canceled) {
			t.Fatalf("%s: 外网请求该被拦下且按取消认: %v", name, err)
		}
		if d := time.Since(start); d > 500*time.Millisecond {
			t.Errorf("%s: 拦下该是当场的,用了 %v", name, d)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok") }))
	defer srv.Close()
	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatalf("回环地址该照常通: %v", err)
	}
	resp.Body.Close()
}
