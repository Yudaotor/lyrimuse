package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httptrace"
	"sync"
	"time"
)

// ---- 歌词源的拨号:系统 DNS 优先,不答 / 查不到才退到 DoH ----
//
// 2026-09-06 加,接着「六个源死在 DNS」那条(sourcebreaker.go 最后一节、docs/09)往下修:
// 用户连着公司 OpenVPN,它下发的 DNS 对 music.163.com / c.y.qq.com / mobilecdn.kugou.com /
// lrclib.net / search.kuwo.cn / pd.musicapp.migu.cn 一律不答,而隧道里**按 IP 直连是通的**
// (`curl --resolve` 实测 200)。所以只要绕开系统 DNS 拿到 IP,歌词就能搜到。
//
// 顺序是用户定的:**先正常走系统 DNS,它失败了才问 DoH**。这跟 musixmatch 那套(doh.go
// dohDialContext:DoH 优先、退回系统解析)正好相反,因为两次的病不同 —— 2026-08-15 那次系统
// DNS 是**答错**(把 musixmatch 解析到 Facebook 的地址段),先问它没有意义;这次是**不答**,
// 系统 DNS 正常时就不该多打一次 1.1.1.1。于是:系统 DNS 正常 → 一个包都不多发、行为跟以前
// 逐位一致;系统 DNS 报错(NXDOMAIN / SERVFAIL / 超时)→ dohLookup 拿 IP → 并发拨号
// (dohDialRace);DoH 也没辄 → 把系统解析那条错误原样交回去,传输层分类照旧认成 dns_failed。
//
// 三个细节:
//   - 系统解析给一个**独立预算**(lyricSourceSystemDNSBudget,2s):DNS 挂住不答时不能让它把
//     整个 http.Client.Timeout(4–8s)吃光,否则 DoH 永远轮不到。秒答的 NXDOMAIN 不受影响。
//   - 系统解析失败后记一个**短期负缓存**(lyricSourceSystemDNSFailTTL,60s):同一首歌一轮里
//     网易云要打 4 个变体、酷狗搜完还要取词,每次都白等 2s 就是十几秒;60 秒内直接走 DoH,
//     期满再试系统 DNS,VPN 一断开就自动回到正常路径。
//   - **DNS 轨迹要自己补**:sourcebreaker.go 的传输层分类靠 httptrace 的 DNSStart / DNSDone 判
//     "是不是死在解析"。系统解析那一步是标准库自己触发钩子的;走到 DoH 之后标准库不知道,
//     这里手动调 trace.DNSDone —— DoH 解析成功就报"成功"(此后连不上算 connect_failed,不是
//     dns_failed,评审提过这条),DoH 也失败就报"失败"。负缓存跳过系统解析时连 DNSStart 也补上。
//
// 只改拨号的目标地址,**不碰 TLS**:crypto/tls 的 ServerName 来自 URL 里的域名,证书照常按域名
// 严格校验(跟 dohDialContext 同一段话)。musixmatch 不走这里 —— 它有自己的 DoH 优先 + 代理兜底
// 那套(dohHTTPClient),两套并存、各管各的病。

const (
	lyricSourceSystemDNSBudget  = 2 * time.Second
	lyricSourceSystemDNSFailTTL = 60 * time.Second
)

// 三个可注入点,只为单测(真实网络里没有可复现的"系统 DNS 不答"):生产路径永远是默认值。
var (
	lyricSourceSystemLookup = func(ctx context.Context, host string) ([]net.IPAddr, error) {
		return net.DefaultResolver.LookupIPAddr(ctx, host)
	}
	lyricSourceDoHLookup = dohLookup
	lyricSourceDial      = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return dohDialer().DialContext(ctx, network, addr)
	}
)

// lyricSourceTransport 是八个歌词源(netease/qq/kugou/lrclib/kuwo/migu/amll/lyricfind)共用的
// Transport:DefaultTransport 的克隆(代理环境变量、连接池、HTTP/2 等一律照旧),只换拨号器。
var lyricSourceTransport = func() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DialContext = lyricSourceDialContext
	return t
}()

// lyricHTTPClient 是歌词源文件里造 client 的唯一入口(lyricsourcedial_test.go 用源码扫描钉着:
// 那八个文件里不许再出现裸的 `&http.Client{`)。Timeout 语义跟原来的 `&http.Client{Timeout: d}`
// 完全一样,只是多了上面那套拨号。
func lyricHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{Timeout: timeout, Transport: lyricSourceTransport}
}

var (
	lyricSourceSystemDNSFailMu    sync.Mutex
	lyricSourceSystemDNSFailUntil = map[string]time.Time{}
	// 上次为这个域名打过"退到 DoH"日志的时间:常驻 collector 在 VPN 下每 60 秒负缓存一过期就会
	// 重新失败一次,九个域名每分钟各一行是噪音,按域名 10 分钟最多记一行。
	lyricSourceSystemDNSLogAt = map[string]time.Time{}
)

const lyricSourceSystemDNSLogEvery = 10 * time.Minute

func lyricSourceSystemDNSRecentlyFailed(host string, now time.Time) bool {
	lyricSourceSystemDNSFailMu.Lock()
	defer lyricSourceSystemDNSFailMu.Unlock()
	return lyricSourceSystemDNSFailUntil[host].After(now)
}

// markLyricSourceSystemDNSFailed 记负缓存,返回这次要不要打日志(限频)。
func markLyricSourceSystemDNSFailed(host string, now time.Time) (shouldLog bool) {
	lyricSourceSystemDNSFailMu.Lock()
	defer lyricSourceSystemDNSFailMu.Unlock()
	lyricSourceSystemDNSFailUntil[host] = now.Add(lyricSourceSystemDNSFailTTL)
	if now.Sub(lyricSourceSystemDNSLogAt[host]) < lyricSourceSystemDNSLogEvery {
		return false
	}
	lyricSourceSystemDNSLogAt[host] = now
	return true
}

func lyricSourceDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || net.ParseIP(host) != nil {
		// 拆不开 / 本来就是 IP:没有解析这一步,原样交给标准拨号器。
		return lyricSourceDial(ctx, network, addr)
	}
	trace := httptrace.ContextClientTrace(ctx)
	now := time.Now()
	var sysErr error
	if !lyricSourceSystemDNSRecentlyFailed(host, now) {
		lookupCtx, cancel := context.WithTimeout(ctx, lyricSourceSystemDNSBudget)
		addrs, lerr := lyricSourceSystemLookup(lookupCtx, host)
		cancel()
		if lerr == nil && len(addrs) > 0 {
			// 系统 DNS 正常:走标准拨号器(它会再解析一次,命中系统缓存,并对多地址做 Happy
			// Eyeballs)—— 这就是改动之前的路径,一个字节都不多。
			return lyricSourceDial(ctx, network, addr)
		}
		if lerr == nil {
			lerr = &net.DNSError{Err: "no addresses", Name: host, IsNotFound: true}
		}
		sysErr = lerr
		if markLyricSourceSystemDNSFailed(host, now) {
			log.Printf("dns: system resolver failed for %s (%v), falling back to DoH for %s", host, lerr, lyricSourceSystemDNSFailTTL)
		}
	} else {
		// 负缓存命中、跳过了系统解析:标准库没机会触发 DNSStart,自己补上,否则传输层分类看不到
		// "这次有解析阶段"。
		sysErr = &net.DNSError{Err: "system resolver failed recently, using DoH", Name: host}
		if trace != nil && trace.DNSStart != nil {
			trace.DNSStart(httptrace.DNSStartInfo{Host: host})
		}
	}

	ips := lyricSourceDoHLookup(host)
	if len(ips) == 0 {
		if trace != nil && trace.DNSDone != nil {
			trace.DNSDone(httptrace.DNSDoneInfo{Err: sysErr})
		}
		return nil, fmt.Errorf("%w (DoH 也没解析出地址)", sysErr)
	}
	if trace != nil && trace.DNSDone != nil {
		addrs := make([]net.IPAddr, 0, len(ips))
		for _, ip := range ips {
			if parsed := net.ParseIP(ip); parsed != nil {
				addrs = append(addrs, net.IPAddr{IP: parsed})
			}
		}
		trace.DNSDone(httptrace.DNSDoneInfo{Addrs: addrs})
	}
	conn, raceErr := dohDialRaceWith(ctx, lyricSourceDial, network, ips, port)
	if conn != nil {
		return conn, nil
	}
	if raceErr == nil {
		raceErr = errors.New("no address dialed")
	}
	// 解析成功(靠 DoH)但地址连不上:这是连接层的失败,不再把系统解析那条错误包进来,
	// 免得传输层分类顺着错误链又认成 dns_failed(评审提过 dohDialContext 那处的同型问题)。
	return nil, fmt.Errorf("dial %s via DoH-resolved %v: %w", host, ips, raceErr)
}
