package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// DoH(DNS over HTTPS)解析,只给那些**本地 DNS 会把它解析歪**的域名用。
//
// 2026-08-15 实测坐实的问题:这台机器上
//
//	apic-appmobile.musixmatch.com  系统 DNS → 31.13.91.6（Facebook 的地址段）
//	                               DoH 查询 → 44.212.146.46 / 52.5.55.223（AWS）
//	apic-desktop.musixmatch.com    系统 DNS → 98.159.108.57
//	                               DoH 查询 → 18.154.206.x
//
// 连过去的结果是 TLS 握手直接失败(`SSL: no alternative certificate subject name
// matches target host name`)—— 证书当然对不上,那台机器根本不是 Musixmatch。
// 于是 token.get 一个字节都拿不到,整个 Musixmatch 源静默失效:五个源里唯一覆盖
// 欧美/日韩曲库的那个,英文歌就只剩 LRCLIB 一家。
//
// 这**不是**代码问题,也不是 musixmatch.go 注释里记的那种反爬拦截(那种会正经返回
// 401 + hint=captcha 的 JSON)。用 --resolve 强制连真实 IP 立刻拿到 HTTP 200 和
// 有效 token —— 服务器一直是好的,只是我们被送错了地方。
//
// 只对 musixmatch 生效:网易云/QQ/酷狗在这个网络环境下本来就正常,没有理由让它们
// 多绕一层;LRCLIB 也一直通。任何一步失败都静默退回系统 DNS,退化成现在的行为,
// 不会比不加更差。
const (
	dohTimeout  = 4 * time.Second
	dohCacheTTL = 30 * time.Minute
)

// 两个 DoH 端点都用 IP 直连(自己不需要再解析一次 DNS,否则就是鸡生蛋)。
// 按顺序试,先成功先用。
var dohEndpoints = []string{
	"https://1.1.1.1/dns-query",
	"https://8.8.8.8/resolve",
}

// 需要绕过系统 DNS 的域名后缀。故意用一份显式清单而不是"全都走 DoH":
// 把整个进程的解析行为改掉,影响面远超这个 bug 需要修的范围。
var dohHostSuffixes = []string{
	".musixmatch.com",
}

type dohEntry struct {
	ips     []string
	expires time.Time
}

var (
	dohMu    sync.Mutex
	dohCache = map[string]dohEntry{}
)

func dohShouldResolve(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	for _, suffix := range dohHostSuffixes {
		if strings.HasSuffix(h, suffix) {
			return true
		}
	}
	return false
}

// dohLookup 返回这个域名的 A 记录。查不到/查询失败返回 nil,调用方据此退回系统解析。
func dohLookup(host string) []string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))

	dohMu.Lock()
	if e, ok := dohCache[host]; ok && time.Now().Before(e.expires) {
		ips := e.ips
		dohMu.Unlock()
		return ips
	}
	dohMu.Unlock()

	var ips []string
	for _, endpoint := range dohEndpoints {
		if got := dohQuery(endpoint, host); len(got) > 0 {
			ips = got
			break
		}
	}
	// 失败也缓存(空结果),避免每次请求都为一个解析不出来的域名重试一遍 DoH。
	dohMu.Lock()
	dohCache[host] = dohEntry{ips: ips, expires: time.Now().Add(dohCacheTTL)}
	dohMu.Unlock()
	return ips
}

func dohQuery(endpoint, host string) []string {
	url := fmt.Sprintf("%s?name=%s&type=A", endpoint, host)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Accept", "application/dns-json")
	// 这里**不能**用 doHTTPTracked:DoH 查询的成败跟"歌词源可不可达"是两回事,记进
	// networkLooksDown 的统计里会污染那个判断(见 networkobs.go)。
	resp, err := (&http.Client{Timeout: dohTimeout}).Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return nil
	}
	return dohParseAnswer(body)
}

// dohParseAnswer 从 DoH 的 JSON 响应里挑出 A 记录(type==1)的地址。
// 单独拆出来是为了能用固定样本做单测,不需要真的联网。
func dohParseAnswer(body []byte) []string {
	var out struct {
		Answer []struct {
			Type int    `json:"type"`
			Data string `json:"data"`
		} `json:"Answer"`
	}
	if json.Unmarshal(body, &out) != nil {
		return nil
	}
	var ips []string
	for _, a := range out.Answer {
		if a.Type != 1 { // 1 = A 记录；CNAME(5) 之类跳过
			continue
		}
		if ip := net.ParseIP(a.Data); ip != nil && ip.To4() != nil {
			ips = append(ips, a.Data)
		}
	}
	return ips
}

// dohDialContext 是给 http.Transport 用的拨号器:命中清单里的域名就连 DoH 解析出的
// 地址,其余一律走系统解析。
//
// 只改拨号的目标地址,**不碰 TLS** —— crypto/tls 用的 ServerName 来自 URL 里的域名,
// 不是这里的 IP,所以证书照常按域名严格校验(跟 curl --resolve 是同一个机制)。绝不能
// 为了"连得上"去关 InsecureSkipVerify:那才是真的把连接置于风险之中。
func dohDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	host, port, err := net.SplitHostPort(addr)
	if err != nil || !dohShouldResolve(host) {
		return dialer.DialContext(ctx, network, addr)
	}
	ips := dohLookup(host)
	var lastErr error
	for _, ip := range ips {
		conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
		if err == nil {
			return conn, nil
		}
		lastErr = err
	}
	// DoH 没结果、或者拿到的地址都连不上:退回系统解析,行为跟没有这套东西时一致。
	conn, err := dialer.DialContext(ctx, network, addr)
	if err != nil && lastErr != nil {
		return nil, fmt.Errorf("%w (DoH 地址也连不上: %v)", err, lastErr)
	}
	return conn, err
}

// dohHTTPClient 造一个走上面那套拨号逻辑的 client。
func dohHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext:         dohDialContext,
			TLSHandshakeTimeout: 8 * time.Second,
			ForceAttemptHTTP2:   true,
		},
	}
}
