package main

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseNetstatListeners(t *testing.T) {
	out := strings.Join([]string{
		"Active Internet connections (including servers)",
		"Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs",
		"tcp4       0      0  127.0.0.1.7897         *.*                    LISTEN                 0            0  131072  131072     verge-mihomo:2469   00180 00000006 0000000000003fb6 00000000 00000800      1      0 000000",
		"tcp46      0      0  *.3940                 *.*                    LISTEN                 0            0  131072  131072         lyrimuse:11335  00100 00000006 000000000066cb6c 00000000 00080800      1      0 000000",
		"tcp4       0      0  127.0.0.1.49833        *.*                    LISTEN                 0            0  131072  131072      Code Helper:3105   00100 00000106 0000000000004e02 00000001 00000800      1      0 000000",
		"tcp6       0      0  ::1.6379               *.*                    LISTEN                 0            0  131072  131072     redis-server:99   00100 00000006 0000000000004e03 00000001 00000800      1      0 000000",
		"tcp4       0      0  10.0.0.5.8080          *.*                    LISTEN                 0            0  131072  131072            nginx:77   00100 00000006 0000000000004e04 00000001 00000800      1      0 000000",
		"tcp4       0      0  10.255.0.247.55585     58.221.74.2.443        ESTABLISHED         9876         1551  262144  131072         DingTalk:1658   00102 00020000 0000000000686963 00180001 04082900      2      0 000000",
		"tcp4       0      0  127.0.0.1.50000        127.0.0.1.7897         ESTABLISHED         9876         1551  262144  131072           clash:1659   00102 00020000 0000000000686963 00180001 04082900      2      0 000000",
		"tcp4       0      0  127.0.0.1.7890         *.*                    LISTEN",
	}, "\n")
	want := []localListener{
		{host: "127.0.0.1", port: 7897, process: "verge-mihomo"},
		{host: "127.0.0.1", port: 3940, process: "lyrimuse"},
		{host: "127.0.0.1", port: 49833, process: "Code Helper"},
		{host: "::1", port: 6379, process: "redis-server"},
	}
	if got := parseNetstatListeners(out); !reflect.DeepEqual(got, want) {
		t.Fatalf("得到 %+v\n期望 %+v", got, want)
	}
}

func TestParseLsofListeners(t *testing.T) {
	out := "p1540\ncrapportd\nf10\nn*:54960\np2001\ncShadowsocksX-NG\nf5\nn127.0.0.1:1086\nf6\nn[::1]:1087\nf7\nn10.0.0.5:8080\n" +
		"p2002\ncCode Helper\nf9\nnlocalhost:49833\nf10\nn127.0.0.1:0\nf11\nnbad\np2003\nf1\nn127.0.0.1:5555\n"
	want := []localListener{
		{host: "127.0.0.1", port: 54960, process: "rapportd"},
		{host: "127.0.0.1", port: 1086, process: "ShadowsocksX-NG"},
		{host: "::1", port: 1087, process: "ShadowsocksX-NG"},
		{host: "127.0.0.1", port: 49833, process: "Code Helper"},
		{host: "127.0.0.1", port: 5555, process: ""},
	}
	if got := parseLsofListeners(out); !reflect.DeepEqual(got, want) {
		t.Fatalf("得到 %+v\n期望 %+v", got, want)
	}
}

func TestIsLocalProxyProcess(t *testing.T) {
	for name, want := range map[string]bool{
		"verge-mihomo": true, "ShadowsocksX-NG": true, "Surge": true, "sing-box": true, "privoxy": true, "ClashX Meta": true,
		"Code Helper": false, "lyrimuse": false, "Proxyman": false, "Charles": false, "redis-server": false,
	} {
		if got := isLocalProxyProcess(name); got != want {
			t.Errorf("isLocalProxyProcess(%q) = %v", name, got)
		}
	}
}

// serveLocal 起一个本机监听端口,每个连接交给 handle。
func serveLocal(t *testing.T, handle func(net.Conn)) string {
	t.Helper()
	ln := listenLocal(t)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); handle(c) }()
		}
	}()
	return ln.Addr().String()
}

// fakeHTTPProxy:真去连 CONNECT 的目标,连上回 200。
func fakeHTTPProxy(t *testing.T) string {
	return serveLocal(t, func(c net.Conn) {
		line, err := bufio.NewReader(c).ReadString('\n')
		f := strings.Fields(line)
		if err != nil || len(f) < 2 || f[0] != "CONNECT" {
			return
		}
		up, err := net.Dial("tcp", f[1])
		if err != nil {
			_, _ = io.WriteString(c, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
			return
		}
		up.Close()
		_, _ = io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n")
	})
}

func fakeSOCKS5(t *testing.T) string {
	return serveLocal(t, func(c net.Conn) {
		buf := make([]byte, 3)
		if _, err := io.ReadFull(c, buf); err == nil && buf[0] == 0x05 {
			_, _ = c.Write([]byte{0x05, 0x00})
		}
	})
}

func silentServer(t *testing.T) string {
	return serveLocal(t, func(c net.Conn) { time.Sleep(time.Second) })
}

func shortHandshake(t *testing.T) {
	saved := localProxyHandshakeTimeout
	localProxyHandshakeTimeout = 100 * time.Millisecond
	t.Cleanup(func() { localProxyHandshakeTimeout = saved })
}

func TestVerifyLocalProxy(t *testing.T) {
	shortHandshake(t)
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	t.Cleanup(api.Close)
	httpAddr, socksAddr := fakeHTTPProxy(t), fakeSOCKS5(t)
	cases := []struct{ name, addr, want string }{
		{"HTTP 代理", httpAddr, "http://" + httpAddr},
		{"SOCKS5 代理", socksAddr, "socks5://" + socksAddr},
		{"控制接口这类 HTTP 服务", strings.TrimPrefix(api.URL, "http://"), ""},
		{"不说话的服务", silentServer(t), ""},
		{"要认证的 SOCKS5", serveLocal(t, func(c net.Conn) {
			buf := make([]byte, 3)
			if _, err := io.ReadFull(c, buf); err == nil {
				_, _ = c.Write([]byte{0x05, 0xFF})
			}
		}), ""},
		{"没人听", deadLocalAddr(t), ""},
	}
	for _, c := range cases {
		got := ""
		if u := verifyLocalProxy(c.addr); u != nil {
			got = u.String()
		}
		if got != c.want {
			t.Errorf("%s: 得到 %q, 期望 %q", c.name, got, c.want)
		}
	}
}

func resetLocalProxyCacheForTest() {
	localProxyMu.Lock()
	localProxyValue, localProxyReadAt = nil, time.Time{}
	localProxyMu.Unlock()
}

// waitLocalProxyIdle 等后台那次重找跑完,免得它在别的用例里改缓存。
func waitLocalProxyIdle(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		localProxyMu.Lock()
		busy := localProxyRefreshing
		localProxyMu.Unlock()
		if !busy {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("后台重找一直没跑完")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func localPort(addr string) int {
	_, p, _ := net.SplitHostPort(addr)
	n, _ := strconv.Atoi(p)
	return n
}

// withLocalProxyEnv 换掉监听列表和默认端口,清缓存;用完等后台跑完再还原。
func withLocalProxyEnv(t *testing.T, listeners *[]localListener, ports []int) {
	t.Helper()
	shortHandshake(t)
	savedL, savedP := localProxyListeners, networkProxyCommonPorts
	localProxyListeners = func() []localListener { return *listeners }
	networkProxyCommonPorts = ports
	resetLocalProxyCacheForTest()
	t.Cleanup(func() {
		waitLocalProxyIdle(t)
		localProxyListeners, networkProxyCommonPorts = savedL, savedP
		resetLocalProxyCacheForTest()
	})
}

// 先按进程名发现,再试常见端口;都要握手过。
func TestDiscoverLocalProxy(t *testing.T) {
	httpAddr, socksAddr, apiAddr := fakeHTTPProxy(t), fakeSOCKS5(t), silentServer(t)
	listeners := []localListener{
		{host: "127.0.0.1", port: localPort(httpAddr), process: "Code Helper"},
		{host: "127.0.0.1", port: localPort(apiAddr), process: "verge-mihomo"},
		{host: "127.0.0.1", port: localPort(socksAddr), process: "sing-box"},
	}
	withLocalProxyEnv(t, &listeners, []int{localPort(httpAddr)})
	if u := discoverLocalProxy(); u == nil || u.String() != "socks5://"+socksAddr {
		t.Fatalf("先用代理软件进程的、握手过的端口, 得到 %v", u)
	}
	listeners = nil
	if u := discoverLocalProxy(); u == nil || u.String() != "http://"+httpAddr {
		t.Fatalf("进程里找不到就试常见端口, 得到 %v", u)
	}
	networkProxyCommonPorts = []int{localPort(deadLocalAddr(t)), localPort(apiAddr)}
	if u := discoverLocalProxy(); u != nil {
		t.Fatalf("没有握手过的就没有, 得到 %v", u)
	}
}

// localProxyURL 只读缓存:第一次和过期后先返回手上的值,在后台重找;找到的和没找到的缓存时长不同。
func TestLocalProxyURLCache(t *testing.T) {
	httpAddr := fakeHTTPProxy(t)
	var listeners []localListener
	withLocalProxyEnv(t, &listeners, []int{localPort(httpAddr)})
	want := "http://" + httpAddr

	if u := localProxyURL(); u != nil {
		t.Fatalf("还没找过时不等,先返回 nil, 得到 %v", u)
	}
	waitLocalProxyIdle(t)
	if u := localProxyURL(); u == nil || u.String() != want {
		t.Fatalf("后台找完之后读得到, 得到 %v", u)
	}

	networkProxyCommonPorts = nil
	localProxyMu.Lock()
	localProxyReadAt = time.Now().Add(-localProxyFoundTTL + time.Second)
	localProxyMu.Unlock()
	if u := localProxyURL(); u == nil || u.String() != want {
		t.Fatalf("找到的在 localProxyFoundTTL 内不重找, 得到 %v", u)
	}
	localProxyMu.Lock()
	localProxyReadAt = time.Now().Add(-localProxyFoundTTL - time.Second)
	localProxyMu.Unlock()
	if u := localProxyURL(); u == nil || u.String() != want {
		t.Fatalf("过期了先返回旧值, 得到 %v", u)
	}
	waitLocalProxyIdle(t)
	if u := localProxyURL(); u != nil {
		t.Fatalf("后台重找之后换成新结果, 得到 %v", u)
	}

	networkProxyCommonPorts = []int{localPort(httpAddr)}
	localProxyMu.Lock()
	localProxyReadAt = time.Now().Add(-localProxyFoundTTL - time.Second)
	localProxyMu.Unlock()
	localProxyURL()
	waitLocalProxyIdle(t)
	if u := localProxyURL(); u != nil {
		t.Fatalf("没找到的缓存 localProxyMissTTL,比找到的长, 得到 %v", u)
	}
}

// 两次找之间至少隔 minAge;同一时刻只找一次。
func TestRefreshLocalProxyGap(t *testing.T) {
	var calls atomic.Int32
	var listeners []localListener
	withLocalProxyEnv(t, &listeners, nil)
	localProxyListeners = func() []localListener { calls.Add(1); return nil }
	if !refreshLocalProxy(time.Minute) || calls.Load() != 1 {
		t.Fatalf("没找过就找, 找了 %d 次", calls.Load())
	}
	if refreshLocalProxy(time.Minute) || calls.Load() != 1 {
		t.Fatalf("间隔内不再找, 找了 %d 次", calls.Load())
	}
	if !refreshLocalProxy(0) || calls.Load() != 2 {
		t.Fatalf("间隔为 0 时当场找, 找了 %d 次", calls.Load())
	}
}

// 直连刚失败时当场补找:只有自动档,守间隔。
func TestFallbackProxyAfterDirectFailure(t *testing.T) {
	httpAddr := fakeHTTPProxy(t)
	var listeners []localListener
	withLocalProxyEnv(t, &listeners, []int{localPort(httpAddr)})
	savedF, savedS := fallbackProxyURL, networkProxyAutoSources
	fallbackProxyURL = resolveFallbackProxyURL
	networkProxyAutoSources = []func() *neturl.URL{localProxyURL}
	t.Cleanup(func() { fallbackProxyURL, networkProxyAutoSources = savedF, savedS })
	impl := fallbackProxyAfterDirectFailureImpl

	withFeatures(t, featureFlags{NetworkProxy: networkProxyOff})
	if u := impl(); u != nil {
		t.Fatalf("不使用代理时不找, 得到 %v", u)
	}
	setFeatures(featureFlags{NetworkProxy: networkProxyAuto})
	if u := impl(); u == nil || u.String() != "http://"+httpAddr {
		t.Fatalf("自动档当场补找, 得到 %v", u)
	}
	// 间隔内不再找,但刚找到的那个照样给:一批请求同时直连失败时,后到的几个等的就是它。
	if u := impl(); u == nil || u.String() != "http://"+httpAddr {
		t.Fatalf("间隔内不再找、照样拿到刚找到的代理, 得到 %v", u)
	}
}
