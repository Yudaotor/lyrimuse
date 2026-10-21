package main

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
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

// 先按进程名发现,再试常见端口;都要握手过。
func TestLocalProxyURL(t *testing.T) {
	shortHandshake(t)
	savedL, savedP := localProxyListeners, networkProxyCommonPorts
	t.Cleanup(func() { localProxyListeners, networkProxyCommonPorts = savedL, savedP })
	resetLocalProxyCacheForTest()
	t.Cleanup(resetLocalProxyCacheForTest)
	port := func(addr string) int {
		_, p, _ := net.SplitHostPort(addr)
		n, _ := strconv.Atoi(p)
		return n
	}
	httpAddr, socksAddr := fakeHTTPProxy(t), fakeSOCKS5(t)
	apiAddr := silentServer(t)
	var listeners []localListener
	localProxyListeners = func() []localListener { return listeners }

	listeners = []localListener{
		{host: "127.0.0.1", port: port(httpAddr), process: "Code Helper"},
		{host: "127.0.0.1", port: port(apiAddr), process: "verge-mihomo"},
		{host: "127.0.0.1", port: port(socksAddr), process: "sing-box"},
	}
	networkProxyCommonPorts = []int{port(httpAddr)}
	if u := localProxyURL(); u == nil || u.String() != "socks5://"+socksAddr {
		t.Fatalf("先用代理软件进程的、握手过的端口, 得到 %v", u)
	}

	listeners = nil
	if u := localProxyURL(); u == nil || u.String() != "socks5://"+socksAddr {
		t.Fatalf("缓存期内不重找, 得到 %v", u)
	}
	resetLocalProxyCacheForTest()
	if u := localProxyURL(); u == nil || u.String() != "http://"+httpAddr {
		t.Fatalf("进程里找不到就试常见端口, 得到 %v", u)
	}

	resetLocalProxyCacheForTest()
	networkProxyCommonPorts = []int{port(deadLocalAddr(t)), port(apiAddr)}
	if u := localProxyURL(); u != nil {
		t.Fatalf("没有握手过的就没有, 得到 %v", u)
	}
}
