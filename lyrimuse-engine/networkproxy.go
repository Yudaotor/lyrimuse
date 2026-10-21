package main

import (
	"log"
	"net"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- 「代理」设置:直连失败时经哪个代理重试 ----
//
// 设置 › 通用 › 网络 › 代理(features.json 的 network_proxy / network_proxy_server),三档:
//   - auto(默认):系统代理(systemProxyURL,含环境变量)→ Clash 控制口报的端口(clashProxyURL)→ 本机代理软件
//     监听的端口(localProxyURL:按进程名发现,再试常见默认端口,握手确认是代理才用,localproxydiscover.go)。
//   - manual:只用填的那一个,连不上就当没有。
//   - off:不走代理。
//
// 只管直连失败之后:用它的是 proxyFallbackTransport(海外歌词源、Musixmatch、Telegram、状态中继、ListenBrainz),直连
// 正常时一个包都不经过代理。国内歌词源不在里面(lyricSourceProxyFallbackSources)。见 09 章决策 321。
const (
	networkProxyAuto   = "auto"
	networkProxyManual = "manual"
	networkProxyOff    = "off"
)

func resolveNetworkProxy(v string) string {
	switch v := strings.ToLower(strings.TrimSpace(v)); v {
	case networkProxyManual, networkProxyOff:
		return v
	}
	return networkProxyAuto
}

// fallbackProxyURL:按「代理」设置算出的、现在连得上的代理,nil = 不走代理。单测换掉,免得读到本机真实的代理。
var fallbackProxyURL = resolveFallbackProxyURL

// networkProxyAutoSources:自动档按顺序试的来源。单测换掉。
var networkProxyAutoSources = []func() *neturl.URL{systemProxyURL, clashProxyURL, localProxyURL}

func resolveFallbackProxyURL() *neturl.URL {
	f := features()
	switch resolveNetworkProxy(f.NetworkProxy) {
	case networkProxyOff:
		return nil
	case networkProxyManual:
		return manualProxyURL(f.NetworkProxyServer)
	}
	for _, src := range networkProxyAutoSources {
		if u := src(); u != nil {
			return u
		}
	}
	return nil
}

// fallbackProxyAfterDirectFailure:直连刚失败、fallbackProxyURL 给不出代理时再找一次。只有自动档会变:本机代理软件
// 是后台找的,刚开的或者还没找过的这里当场补上(refreshLocalProxy,守 localProxyRecheckGap)。单测换掉。
var fallbackProxyAfterDirectFailure = fallbackProxyAfterDirectFailureImpl

func fallbackProxyAfterDirectFailureImpl() *neturl.URL {
	if resolveNetworkProxy(features().NetworkProxy) != networkProxyAuto || !refreshLocalProxy(localProxyRecheckGap) {
		return nil
	}
	return fallbackProxyURL()
}

// parseProxyServer:host:port,或带 http:// / https:// / socks5:// / socks5h:// 前缀;不带前缀按 http。写错了返回 nil。
// 用户名密码(user:pass@host:port)原样留着,Go 的 http.Transport 会带上。
func parseProxyServer(s string) *neturl.URL {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	if !strings.Contains(s, "://") {
		s = "http://" + s
	}
	u, err := neturl.Parse(s)
	if err != nil {
		return nil
	}
	switch u.Scheme {
	case "http", "https", "socks5", "socks5h":
	default:
		return nil
	}
	host, port, err := net.SplitHostPort(u.Host)
	if err != nil || host == "" {
		return nil
	}
	if n, err := strconv.Atoi(port); err != nil || n <= 0 || n > 65535 {
		return nil
	}
	return &neturl.URL{Scheme: u.Scheme, Host: u.Host, User: u.User}
}

var (
	manualProxyMu      sync.Mutex
	manualProxyServer  string
	manualProxyValue   *neturl.URL
	manualProxyCheckAt time.Time
)

// manualProxyURL:手动档填的代理,连得上才算。同一个地址的结果缓存 systemProxyCacheTTL,改了地址当场重查。
func manualProxyURL(server string) *neturl.URL {
	manualProxyMu.Lock()
	defer manualProxyMu.Unlock()
	if server == manualProxyServer && !manualProxyCheckAt.IsZero() && time.Since(manualProxyCheckAt) < systemProxyCacheTTL {
		return manualProxyValue
	}
	u := parseProxyServer(server)
	if u == nil && server != "" {
		log.Printf("proxy: proxy server setting is not host:port, treating this round as no proxy")
	}
	if u != nil && !proxyReachable(u) {
		log.Printf("proxy: proxy server %s is unreachable, treating this round as no proxy", u.Host)
		u = nil
	}
	manualProxyServer, manualProxyValue, manualProxyCheckAt = server, u, time.Now()
	return u
}

// newFallbackProxyTransport:proxyFallbackTransport 里走代理那一半。拨的是代理自己的地址,目标域名交给代理去解析。
func newFallbackProxyTransport(tlsHandshake time.Duration) *http.Transport {
	return &http.Transport{
		Proxy:               func(*http.Request) (*neturl.URL, error) { return fallbackProxyURL(), nil },
		TLSHandshakeTimeout: tlsHandshake,
		ForceAttemptHTTP2:   true,
		IdleConnTimeout:     90 * time.Second,
	}
}
