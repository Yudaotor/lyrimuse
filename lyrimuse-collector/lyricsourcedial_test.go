package main

import (
	"context"
	"errors"
	"net"
	"net/http/httptrace"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// 2026-09-06 歌词源拨号:系统 DNS 优先、不答才退 DoH(lyricsourcedial.go)。真实网络里没有
// 可复现的"系统 DNS 不答",三个注入点全换成假的,连接用 net.Pipe 造。

type dialProbe struct {
	sysCalls, dohCalls, dialCalls int
	dialedAddrs                   []string
	sysErr                        error
	sysAddrs                      []net.IPAddr
	dohIPs                        []string
	dialErr                       error
}

func installDialProbe(t *testing.T, p *dialProbe) {
	t.Helper()
	savedSys, savedDoH, savedDial := lyricSourceSystemLookup, lyricSourceDoHLookup, lyricSourceDial
	lyricSourceSystemDNSFailMu.Lock()
	savedFail := lyricSourceSystemDNSFailUntil
	lyricSourceSystemDNSFailUntil = map[string]time.Time{}
	lyricSourceSystemDNSFailMu.Unlock()
	t.Cleanup(func() {
		lyricSourceSystemLookup, lyricSourceDoHLookup, lyricSourceDial = savedSys, savedDoH, savedDial
		lyricSourceSystemDNSFailMu.Lock()
		lyricSourceSystemDNSFailUntil = savedFail
		lyricSourceSystemDNSFailMu.Unlock()
	})
	lyricSourceSystemLookup = func(context.Context, string) ([]net.IPAddr, error) {
		p.sysCalls++
		return p.sysAddrs, p.sysErr
	}
	lyricSourceDoHLookup = func(string) []string {
		p.dohCalls++
		return p.dohIPs
	}
	lyricSourceDial = func(_ context.Context, _, addr string) (net.Conn, error) {
		p.dialCalls++
		p.dialedAddrs = append(p.dialedAddrs, addr)
		if p.dialErr != nil {
			return nil, p.dialErr
		}
		c1, c2 := net.Pipe()
		go c2.Close()
		return c1, nil
	}
}

type traceProbe struct {
	starts, dones int
	lastDoneErr   error
	lastAddrs     int
}

func (tp *traceProbe) ctx() context.Context {
	return httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{
		DNSStart: func(httptrace.DNSStartInfo) { tp.starts++ },
		DNSDone: func(i httptrace.DNSDoneInfo) {
			tp.dones++
			tp.lastDoneErr = i.Err
			tp.lastAddrs = len(i.Addrs)
		},
	})
}

// 系统 DNS 正常:走标准拨号(带域名),DoH 一次都不问 —— 改动前的路径逐位不变。
func TestLyricSourceDial_SystemDNSHealthyNeverTouchesDoH(t *testing.T) {
	p := &dialProbe{sysAddrs: []net.IPAddr{{IP: net.ParseIP("1.2.3.4")}}}
	installDialProbe(t, p)
	conn, err := lyricSourceDialContext(context.Background(), "tcp", "music.163.com:443")
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if p.sysCalls != 1 || p.dohCalls != 0 {
		t.Fatalf("sys=%d doh=%d,系统 DNS 正常时不该问 DoH", p.sysCalls, p.dohCalls)
	}
	if len(p.dialedAddrs) != 1 || p.dialedAddrs[0] != "music.163.com:443" {
		t.Fatalf("应按域名交给标准拨号器,实际 %v", p.dialedAddrs)
	}
}

// 系统 DNS NXDOMAIN → 问 DoH → 并发拨 DoH 给的地址;轨迹上 DNSDone 报成功(此后连不上是 connect 不是 dns)。
func TestLyricSourceDial_FallsBackToDoHWhenSystemDNSFails(t *testing.T) {
	p := &dialProbe{
		sysErr: &net.DNSError{Err: "no such host", Name: "c.y.qq.com", IsNotFound: true},
		dohIPs: []string{"129.226.103.212", "129.226.103.11"},
	}
	installDialProbe(t, p)
	tp := &traceProbe{}
	conn, err := lyricSourceDialContext(tp.ctx(), "tcp", "c.y.qq.com:443")
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if p.dohCalls != 1 {
		t.Fatalf("应问一次 DoH,实际 %d", p.dohCalls)
	}
	for _, a := range p.dialedAddrs {
		if !strings.HasSuffix(a, ":443") || strings.Contains(a, "c.y.qq.com") {
			t.Fatalf("应拨 DoH 解析出的 IP:443,实际 %v", p.dialedAddrs)
		}
	}
	if tp.dones == 0 || tp.lastDoneErr != nil || tp.lastAddrs != 2 {
		t.Fatalf("DoH 解析成功应在轨迹上报 DNSDone(无错、2 个地址),实际 dones=%d err=%v addrs=%d", tp.dones, tp.lastDoneErr, tp.lastAddrs)
	}
	// 负缓存:60 秒内第二次不再问系统 DNS,但要补 DNSStart。
	tp2 := &traceProbe{}
	conn, err = lyricSourceDialContext(tp2.ctx(), "tcp", "c.y.qq.com:443")
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if p.sysCalls != 1 {
		t.Fatalf("负缓存期内不该再问系统 DNS,实际 sys=%d", p.sysCalls)
	}
	if tp2.starts != 1 || tp2.dones != 1 {
		t.Fatalf("跳过系统解析时要自己补 DNSStart/DNSDone,实际 starts=%d dones=%d", tp2.starts, tp2.dones)
	}
}

// 系统 DNS 失败、DoH 也空:返回的错误链里保留 *net.DNSError,轨迹 DNSDone 带错 → 传输层分类认成 dns_failed。
func TestLyricSourceDial_BothFailKeepsDNSError(t *testing.T) {
	sysErr := &net.DNSError{Err: "i/o timeout", Name: "lrclib.net", IsTimeout: true}
	p := &dialProbe{sysErr: sysErr}
	installDialProbe(t, p)
	tp := &traceProbe{}
	_, err := lyricSourceDialContext(tp.ctx(), "tcp", "lrclib.net:443")
	if err == nil {
		t.Fatal("两边都失败竟然成功")
	}
	var dnsErr *net.DNSError
	if !errors.As(err, &dnsErr) {
		t.Fatalf("错误链应保留 DNSError,实际 %v", err)
	}
	if tp.lastDoneErr == nil {
		t.Fatal("DoH 也失败时轨迹 DNSDone 应带错")
	}
	if p.dialCalls != 0 {
		t.Fatal("没有地址不该拨号")
	}
	if got := classifyLyricSourceTransportFailure(err, 0, transportTrace{dnsStarted: true, dnsDone: true, dnsErr: tp.lastDoneErr}); got != lyricFailureReasonDNSFailed {
		t.Fatalf("分类应为 dns_failed,实际 %q", got)
	}
}

// DoH 解析成功但地址拨不通:错误链**不**带 DNSError,轨迹 DNSDone 无错 → connect_failed,不是 dns_failed。
func TestLyricSourceDial_DoHResolvedButUnreachableIsConnectFailure(t *testing.T) {
	p := &dialProbe{
		sysErr:  &net.DNSError{Err: "no such host", Name: "mobilecdn.kugou.com", IsNotFound: true},
		dohIPs:  []string{"43.174.172.213"},
		dialErr: errors.New("connect: connection refused"),
	}
	installDialProbe(t, p)
	tp := &traceProbe{}
	_, err := lyricSourceDialContext(tp.ctx(), "tcp", "mobilecdn.kugou.com:80")
	if err == nil {
		t.Fatal("拨不通竟然成功")
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		t.Fatalf("DoH 已解析成功,错误链不该再带 DNSError:%v", err)
	}
	if got := classifyLyricSourceTransportFailure(err, 0, transportTrace{dnsStarted: true, dnsDone: true, dnsErr: tp.lastDoneErr}); got != lyricFailureReasonConnectFailed {
		t.Fatalf("分类应为 connect_failed,实际 %q", got)
	}
}

// 目标本来就是 IP:不解析、不问 DoH,直接拨。
func TestLyricSourceDial_IPLiteralBypassesResolution(t *testing.T) {
	p := &dialProbe{}
	installDialProbe(t, p)
	conn, err := lyricSourceDialContext(context.Background(), "tcp", "127.0.0.1:9")
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if p.sysCalls != 0 || p.dohCalls != 0 || p.dialCalls != 1 {
		t.Fatalf("sys=%d doh=%d dial=%d", p.sysCalls, p.dohCalls, p.dialCalls)
	}
}

// 源码级守卫:八个歌词源文件里不许再出现裸的 `&http.Client{` —— 那样造出来的 client 走
// DefaultTransport,没有 DoH 兜底,VPN 那种 DNS 不答的场景下这个源就又"静默消失"了。
// musixmatch 刻意不在名单里(它走 dohHTTPClient 那套)。
func TestLyricSourceFilesUseLyricHTTPClient(t *testing.T) {
	files := []string{"netease.go", "qq.go", "kugou.go", "lrclib.go", "kuwo.go", "migu.go", "amllttml.go", "ytmusic.go"}
	raw := regexp.MustCompile(`&http\.Client\{`)
	seen := 0
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if raw.Match(src) {
			t.Errorf("%s 里有裸的 &http.Client{ —— 改用 lyricHTTPClient(timeout)", f)
		}
		seen += strings.Count(string(src), "lyricHTTPClient(")
	}
	if seen == 0 {
		t.Fatal("一个 lyricHTTPClient( 都没扫到 —— 守卫失效")
	}
	// lyricHTTPClient 必须真的挂了自定义拨号器,否则等于没改。
	if lyricSourceTransport.DialContext == nil {
		t.Fatal("lyricSourceTransport 没有自定义 DialContext")
	}
}
