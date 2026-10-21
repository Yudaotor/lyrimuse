package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func TestResolveNetworkProxy(t *testing.T) {
	for in, want := range map[string]string{
		"": networkProxyAuto, "auto": networkProxyAuto, " MANUAL ": networkProxyManual, "off": networkProxyOff, "socks": networkProxyAuto,
	} {
		if got := resolveNetworkProxy(in); got != want {
			t.Errorf("resolveNetworkProxy(%q) = %q, 期望 %q", in, got, want)
		}
	}
	if got := buildFeatureFlags(featureFlagsFile{NetworkProxy: " OFF ", NetworkProxyServer: " 127.0.0.1:7890 "}); got.NetworkProxy != networkProxyOff || got.NetworkProxyServer != "127.0.0.1:7890" {
		t.Errorf("buildFeatureFlags 得到 %q %q", got.NetworkProxy, got.NetworkProxyServer)
	}
}

func TestParseProxyServer(t *testing.T) {
	for in, want := range map[string]string{
		"127.0.0.1:7890":            "http://127.0.0.1:7890",
		" 127.0.0.1:7890 ":          "http://127.0.0.1:7890",
		"http://127.0.0.1:7890/":    "http://127.0.0.1:7890",
		"socks5://127.0.0.1:7891":   "socks5://127.0.0.1:7891",
		"socks5h://proxy.lan:1080":  "socks5h://proxy.lan:1080",
		"https://proxy.lan:443":     "https://proxy.lan:443",
		"http://u:p@127.0.0.1:8080": "http://u:p@127.0.0.1:8080",
		"[::1]:7890":                "http://[::1]:7890",
		"":                          "",
		"127.0.0.1":                 "",
		"127.0.0.1:0":               "",
		"127.0.0.1:65536":           "",
		"127.0.0.1:port":            "",
		":7890":                     "",
		"ftp://127.0.0.1:21":        "",
		"http://[::1:7890":          "",
	} {
		got := ""
		if u := parseProxyServer(in); u != nil {
			got = u.String()
		}
		if got != want {
			t.Errorf("parseProxyServer(%q) = %q, 期望 %q", in, got, want)
		}
	}
}

func listenLocal(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

func deadLocalAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

func withFeatures(t *testing.T, f featureFlags) {
	t.Helper()
	saved := features()
	setFeatures(f)
	t.Cleanup(func() { setFeatures(saved) })
}

func resetManualProxyCacheForTest() {
	manualProxyMu.Lock()
	manualProxyServer, manualProxyValue, manualProxyCheckAt = "", nil, time.Time{}
	manualProxyMu.Unlock()
}

func resetLocalPortProxyCacheForTest() {
	localPortProxyMu.Lock()
	localPortProxyValue, localPortProxyReadAt = nil, time.Time{}
	localPortProxyMu.Unlock()
}

func TestResolveFallbackProxyURL(t *testing.T) {
	a := &neturl.URL{Scheme: "http", Host: "127.0.0.1:1"}
	b := &neturl.URL{Scheme: "http", Host: "127.0.0.1:2"}
	saved := networkProxyAutoSources
	t.Cleanup(func() { networkProxyAutoSources = saved })
	none := func() *neturl.URL { return nil }

	networkProxyAutoSources = []func() *neturl.URL{none, func() *neturl.URL { return a }, func() *neturl.URL { return b }}
	withFeatures(t, featureFlags{NetworkProxy: networkProxyAuto})
	if got := resolveFallbackProxyURL(); got != a {
		t.Fatalf("自动档取第一个给得出的来源, 得到 %v", got)
	}
	setFeatures(featureFlags{})
	if got := resolveFallbackProxyURL(); got != a {
		t.Fatalf("没写过设置按自动档, 得到 %v", got)
	}
	networkProxyAutoSources = []func() *neturl.URL{none, none}
	if got := resolveFallbackProxyURL(); got != nil {
		t.Fatalf("自动档都给不出就没有, 得到 %v", got)
	}

	networkProxyAutoSources = []func() *neturl.URL{func() *neturl.URL { return a }}
	setFeatures(featureFlags{NetworkProxy: networkProxyOff, NetworkProxyServer: "127.0.0.1:7890"})
	if got := resolveFallbackProxyURL(); got != nil {
		t.Fatalf("关闭档不走代理, 得到 %v", got)
	}

	ln := listenLocal(t)
	resetManualProxyCacheForTest()
	t.Cleanup(resetManualProxyCacheForTest)
	setFeatures(featureFlags{NetworkProxy: networkProxyManual, NetworkProxyServer: ln.Addr().String()})
	if got := resolveFallbackProxyURL(); got == nil || got.Host != ln.Addr().String() {
		t.Fatalf("手动档用填的那个, 得到 %v", got)
	}
	setFeatures(featureFlags{NetworkProxy: networkProxyManual, NetworkProxyServer: deadLocalAddr(t)})
	if got := resolveFallbackProxyURL(); got != nil {
		t.Fatalf("手动档连不上就没有(不退到自动档), 得到 %v", got)
	}
	setFeatures(featureFlags{NetworkProxy: networkProxyManual, NetworkProxyServer: "not a server"})
	if got := resolveFallbackProxyURL(); got != nil {
		t.Fatalf("手动档写错了就没有, 得到 %v", got)
	}
	setFeatures(featureFlags{NetworkProxy: networkProxyManual})
	if got := resolveFallbackProxyURL(); got != nil {
		t.Fatalf("手动档没填就没有, 得到 %v", got)
	}
}

// 同一个地址的探活结果缓存着;改了地址当场重查。
func TestManualProxyURLCache(t *testing.T) {
	resetManualProxyCacheForTest()
	t.Cleanup(resetManualProxyCacheForTest)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	if manualProxyURL(addr) == nil {
		t.Fatal("连得上的要认")
	}
	ln.Close()
	if manualProxyURL(addr) == nil {
		t.Fatal("同一个地址在缓存期内不重查")
	}
	if manualProxyURL(deadLocalAddr(t)) != nil {
		t.Fatal("换了地址当场重查")
	}
	manualProxyMu.Lock()
	manualProxyServer, manualProxyValue, manualProxyCheckAt = addr, &neturl.URL{Scheme: "http", Host: addr}, time.Now().Add(-2*systemProxyCacheTTL)
	manualProxyMu.Unlock()
	if manualProxyURL(addr) != nil {
		t.Fatal("缓存过期后重查")
	}
}

func TestLocalPortProxyURL(t *testing.T) {
	saved := networkProxyCommonPorts
	t.Cleanup(func() { networkProxyCommonPorts = saved })
	resetLocalPortProxyCacheForTest()
	t.Cleanup(resetLocalPortProxyCacheForTest)
	live := listenLocal(t)
	port := func(addr string) int {
		_, p, _ := net.SplitHostPort(addr)
		n, _ := strconv.Atoi(p)
		return n
	}
	networkProxyCommonPorts = []int{port(deadLocalAddr(t)), port(live.Addr().String())}
	if u := localPortProxyURL(); u == nil || u.Host != live.Addr().String() || u.Scheme != "http" {
		t.Fatalf("取第一个连得上的端口, 得到 %v", u)
	}
	networkProxyCommonPorts = nil
	if u := localPortProxyURL(); u == nil {
		t.Fatal("缓存期内不重探")
	}
	resetLocalPortProxyCacheForTest()
	if u := localPortProxyURL(); u != nil {
		t.Fatalf("没有端口连得上就没有, 得到 %v", u)
	}
}

// 用这一层的客户端都按「代理」设置走代理:判断有没有代理、真正拨过去的是同一个。
func TestFallbackClientsFollowProxySetting(t *testing.T) {
	want := &neturl.URL{Scheme: "http", Host: "127.0.0.1:9"}
	saved := fallbackProxyURL
	fallbackProxyURL = func() *neturl.URL { return want }
	t.Cleanup(func() { fallbackProxyURL = saved })
	req, _ := http.NewRequest(http.MethodGet, "https://example.com/", nil)
	for name, c := range map[string]*http.Client{
		"doh": dohHTTPClient(nil), "telegram": telegramHTTPClient, "relay": relayHTTPClient,
		"relaySeed": relaySeedClient, "lb": lbHTTPClient(),
		"lyricSource": {Transport: lyricSourceFallbackFor("lrclib.net")},
	} {
		tr, ok := c.Transport.(*proxyFallbackTransport)
		if !ok {
			t.Errorf("%s: 不是代理回退那一层", name)
			continue
		}
		if got := tr.proxy(); got != want {
			t.Errorf("%s: 判断有没有代理时没读设置, 得到 %v", name, got)
		}
		via, ok := tr.viaProxy.(*http.Transport)
		if !ok || via.Proxy == nil {
			t.Errorf("%s: 走代理那一半没设 Proxy", name)
			continue
		}
		if got, _ := via.Proxy(req); got != want {
			t.Errorf("%s: 走代理时拨的不是设置里的代理, 得到 %v", name, got)
		}
	}
	if !musixmatchProxyAvailable() {
		t.Error("Musixmatch 被拦时判断有没有代理也读设置")
	}
	fallbackProxyURL = func() *neturl.URL { return nil }
	if musixmatchProxyAvailable() {
		t.Error("设置给不出代理时 Musixmatch 不改走代理")
	}
}

// fakeForwardProxy 是一个只认明文 http 绝对地址的转发代理:记下经它请求的主机,原样回一句话。
func fakeForwardProxy(t *testing.T) (*httptest.Server, *atomic.Int32, *atomic.Value) {
	t.Helper()
	var hits atomic.Int32
	var lastHost atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		lastHost.Store(r.URL.Host)
		_, _ = io.WriteString(w, "via-proxy")
	}))
	t.Cleanup(srv.Close)
	return srv, &hits, &lastHost
}

// 海外歌词源直连不通改走代理,之后这台主机直接走代理;国内源、不认识的主机只直连;设置里关掉就不走代理。
func TestLyricSourceProxyFallback(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	proxySrv, hits, lastHost := fakeForwardProxy(t)
	proxyURL, _ := neturl.Parse(proxySrv.URL)
	savedProxy := fallbackProxyURL
	var proxyOn atomic.Bool
	proxyOn.Store(true)
	fallbackProxyURL = func() *neturl.URL {
		if proxyOn.Load() {
			return proxyURL
		}
		return nil
	}
	savedTransport := sharedLyricSourceTransport()
	var directDials atomic.Int32
	setSharedLyricSourceTransport(&http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		directDials.Add(1)
		return nil, errors.New("connect: connection refused")
	}})
	clearFallbacks := func() {
		lyricSourceFallbacks.Range(func(k, _ any) bool { lyricSourceFallbacks.Delete(k); return true })
	}
	clearFallbacks()
	t.Cleanup(func() {
		fallbackProxyURL = savedProxy
		setSharedLyricSourceTransport(savedTransport)
		clearFallbacks()
	})
	get := func(rawURL string) (string, error) {
		resp, err := lyricHTTPClient(2 * time.Second).Get(rawURL)
		if err != nil {
			return "", err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return string(b), nil
	}

	if body, err := get("http://lrclib.net/api/search?q=x"); err != nil || body != "via-proxy" {
		t.Fatalf("海外源直连不通应改走代理, body=%q err=%v", body, err)
	}
	if hits.Load() != 1 || lastHost.Load() != "lrclib.net" || directDials.Load() == 0 {
		t.Fatalf("代理 %d 次、主机 %v、直连 %d 次", hits.Load(), lastHost.Load(), directDials.Load())
	}
	dialsBefore := directDials.Load()
	if body, err := get("http://lrclib.net/api/get?id=1"); err != nil || body != "via-proxy" {
		t.Fatalf("第二次 body=%q err=%v", body, err)
	}
	if directDials.Load() != dialsBefore {
		t.Fatalf("救回来之后这台主机直接走代理,不再先探直连: 直连 %d → %d", dialsBefore, directDials.Load())
	}

	// 走代理的粘性按主机分开:另一个海外源照常先探直连。
	dialsBefore = directDials.Load()
	if body, err := get("http://api.deezer.com/search?q=x"); err != nil || body != "via-proxy" {
		t.Fatalf("另一个海外源 body=%q err=%v", body, err)
	}
	if directDials.Load() == dialsBefore {
		t.Fatal("一台主机走了代理,别的主机不受牵连")
	}

	for _, u := range []string{"http://music.163.com/api/x", "http://c.y.qq.com/x", "http://example.com/x"} {
		before := hits.Load()
		if _, err := get(u); err == nil {
			t.Fatalf("%s: 直连不通应失败", u)
		}
		if hits.Load() != before {
			t.Fatalf("%s: 国内源和不认识的主机不走代理", u)
		}
	}

	proxyOn.Store(false)
	before := hits.Load()
	if _, err := get("http://apis.naver.com/vibeWeb/x"); err == nil {
		t.Fatal("设置里关掉代理时直连不通就失败")
	}
	if hits.Load() != before {
		t.Fatal("设置里关掉代理时不走代理")
	}
}
