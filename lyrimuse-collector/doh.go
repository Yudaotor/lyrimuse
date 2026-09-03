package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	neturl "net/url"
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
	// 单个地址的拨号上限。有了 dohDialRace 的并发拨号之后,这个值不再决定"整体等多久"
	// (黑洞地址不会再挡住好地址),真正卡总时长的是调用方 ctx 上的 deadline
	// —— dohHTTPClient 那条路上是 proxyFallbackTransport 的 3s 直连预算。
	dohDialTimeout         = 8 * time.Second
	dohTLSHandshakeTimeout = 8 * time.Second
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
	host, port, err := net.SplitHostPort(addr)
	if err != nil || !dohShouldResolve(host) {
		return dohDialer().DialContext(ctx, network, addr)
	}
	conn, raceErr := dohDialRace(ctx, network, dohLookup(host), port)
	if conn != nil {
		return conn, nil
	}
	// DoH 没结果、或者拿到的地址都连不上:退回系统解析,行为跟没有这套东西时一致。
	conn, err = dohDialer().DialContext(ctx, network, addr)
	if err != nil && raceErr != nil {
		return nil, fmt.Errorf("%w (DoH 地址也连不上: %v)", err, raceErr)
	}
	return conn, err
}

func dohDialer() *net.Dialer {
	return &net.Dialer{Timeout: dohDialTimeout, KeepAlive: 30 * time.Second}
}

// dohDialRace 对 DoH 查到的每个地址**同时**发起拨号,第一个连上的胜出,慢一步也连上的
// 当场关掉。ips 为空时返回 (nil, nil),由调用方退回系统解析。
//
// ⚠️ 2026-09-03 修的真 bug。原来这里是串行的:
//
//	for _, ip := range ips { conn, err := dialer.DialContext(ctx, ...); if err == nil { return } }
//
// 每个 dialer.Timeout = 8s,而外面 http.Client.Timeout 也是 8s —— 第一个地址是黑洞
// (SYN 石沉大海、不是被拒)时,8 秒预算全耗在它身上,**永远轮不到第二个**。而 DoH 返回的
// 地址顺序是随机轮转的(2026-09-03 实测:1.1.1.1 对同一个域名连查三次给了两种顺序),
// dohCache 又一存 30 分钟 —— 一次坏运气就是接下来半小时这个源全废,而另一个地址明明是
// 好的。并发拨号让"有一个地址能连"直接等价于"连得上",跟顺序无关。
//
// 这跟 net.Dialer 自己对多地址做的 Happy Eyeballs 是同一个思路,但标准库那套只在**它自己**
// 解析出多个地址时生效;我们是拿 DoH 的结果逐个拨,走不到那条路径。
func dohDialRace(ctx context.Context, network string, ips []string, port string) (net.Conn, error) {
	return dohDialRaceWith(ctx, dohDialer().DialContext, network, ips, port)
}

// dohDialRaceWith 是 dohDialRace 的可注入版本。拆出来只为单测:要证明"第一个地址是黑洞
// 时不再挡住第二个",就得有一个**真的永远不返回**的拨号目标,而真实网络里没有可移植、
// 可复现的黑洞地址(RFC 5737 那几段在不同网络下有时秒回 EHOSTUNREACH、有时超时)。
// 生产路径只有 dohDialRace 一个调用方,传的永远是真拨号器。
func dohDialRaceWith(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error),
	network string, ips []string, port string) (net.Conn, error) {
	if len(ips) == 0 {
		return nil, nil
	}
	dialCtx, cancel := context.WithCancel(ctx)
	type dialOutcome struct {
		conn net.Conn
		err  error
	}
	// 缓冲开满:输家写进来永远不会阻塞,即使赢家已经把结果交出去、没人再读。
	ch := make(chan dialOutcome, len(ips))
	for _, ip := range ips {
		go func(ip string) {
			conn, err := dial(dialCtx, network, net.JoinHostPort(ip, port))
			ch <- dialOutcome{conn, err}
		}(ip)
	}
	var firstErr error
	for remaining := len(ips); remaining > 0; remaining-- {
		select {
		case out := <-ch:
			if out.err != nil {
				if firstErr == nil {
					firstErr = out.err
				}
				continue
			}
			// 有人连上了:立刻交出去,**不等**剩下那几个 —— 等它们就等于没有并发,黑洞
			// 那条要到 dialer.Timeout 才返回。cancel 让它们尽快收工,收尾 goroutine 把
			// 万一也连上的连接关掉,不泄漏 fd。
			//
			// cancel 不会影响已经交出去的这条:net.Dialer 的 ctx 只管拨号过程,连接建成
			// 之后 ctx 过期/取消对它没有作用(标准库文档明写)。
			go func(n int) {
				defer cancel()
				for i := 0; i < n; i++ {
					if o := <-ch; o.conn != nil {
						_ = o.conn.Close()
					}
				}
			}(remaining - 1)
			return out.conn, nil
		case <-dialCtx.Done():
			cancel()
			return nil, dialCtx.Err()
		}
	}
	cancel()
	return nil, firstErr
}

// dohHTTPClient 造一个走上面那套拨号逻辑的 client:直连优先(DoH 解析 + 并发拨号),直连
// 被打掉时自动改走系统代理(proxyfallback.go / systemproxy.go —— 完整的实测依据和"为什么
// 不全局走代理"记在 systemproxy.go 头注)。
//
// onBlocked 透传给 proxyFallbackTransport:直连不通、代理也救不回来时回调一次,让调用方
// 记一个具体的失败原因。可以为 nil。
//
// ⚠️ **刻意不设 http.Client.Timeout。** 那是把直连和代理两次尝试算进同一个预算里,直连一
// 超时就没钱给代理重试了,fallback 等于没加。预算落在 proxyFallbackTransport.attempt 的
// 每次尝试上(3s 直连 / 10s 代理),调用方自己 ctx 上的 deadline 照常生效。
func dohHTTPClient(onBlocked func()) *http.Client {
	return &http.Client{
		Transport: &proxyFallbackTransport{
			direct: &http.Transport{
				DialContext:         dohDialContext,
				TLSHandshakeTimeout: dohTLSHandshakeTimeout,
				ForceAttemptHTTP2:   true,
			},
			// 走代理时拨的是代理自己的地址(通常是 127.0.0.1),DoH 对它没有意义,用默认
			// 拨号器即可;目标域名交给代理去解析。
			viaProxy: &http.Transport{
				Proxy:               func(*http.Request) (*neturl.URL, error) { return systemProxyURL(), nil },
				TLSHandshakeTimeout: dohTLSHandshakeTimeout,
				ForceAttemptHTTP2:   true,
			},
			onBlocked: onBlocked,
		},
	}
}
