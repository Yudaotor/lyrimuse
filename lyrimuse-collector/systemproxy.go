package main

import (
	"context"
	"log"
	"net"
	neturl "net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- 读 macOS 系统代理设置 ----
//
// 2026-09-03 加。起因:用户在设置页点 Musixmatch 那颗「测试」,报「两首探测曲都没有响应,
// 这个源目前可能不可用」。逐层量下来根因既不在代码,也不在 Musixmatch:
//
//	ping 52.22.193.26 / 54.144.176.235(apic-appmobile 的两个 A 记录)  100% 丢包
//	ping 18.154.206.74(apic-desktop)/ 1.1.1.1  对照组                 0% 丢包,~160ms
//	TCP connect 16 次                                                 只成功 3 次(且都要等 SYN 重传)
//	TLS 握手 16 次                                                     0 次成功
//	经本机 Clash(127.0.0.1:7897)                                      HTTP 200,拿到真 token
//
// 也就是说这台机器**直连** Musixmatch 那两个 AWS us-east-1 地址是不通的,而用户开着代理、
// macOS 系统代理开关也是开的(scutil --proxy 里 HTTPSEnable=1 HTTPSProxy=127.0.0.1:7897),
// collector 却全程直连。
//
// 为什么会这样:**Go 标准库不读 macOS 系统代理**。http.ProxyFromEnvironment 只认
// HTTP(S)_PROXY / ALL_PROXY 环境变量,而 collector 是被 Lyrimuse.app(GUI)拉起来的,
// GUI 进程不继承 shell 环境 —— 实测运行中的 collector 进程环境里一个 proxy 变量都没有。
// 三个形状完全一样、只差 Proxy 字段的 http.Client 打同一个 URL 的对照:
//
//	A 现状(Transport 没有 Proxy 字段)     FAILED after 8.001s: context deadline exceeded
//	B 只加 Proxy 显式指向 Clash           HTTP 200 in 6.5s
//	C Proxy: http.ProxyFromEnvironment    FAILED: dial tcp 54.144.176.235:443: i/o timeout
//
// C 就是"指望标准库自己读系统代理"这条路走不通的直接证据。
//
// ⚠️ **这不是"让 collector 全局走系统代理"的理由,恰恰相反。** docs/features/12 章记着一组
// 反向实测:App 进程(URLSession,默认就走系统代理)打 Last.fm 是 p50 1.2s / p90 6s / 16%
// 超时,同一时段 collector 的 Go 直连是 p50 0.4s / ~1% 失败;curl 对照直连 0.6~1.0s 全成功、
// 经代理 1.7~2.5s 且 2/6 握手失败。**在这台机器上代理是更差的通道。** 所以这里读出来的代理
// 只作为"直连失败后的兜底"(proxyfallback.go),而且只对 doh.go 那份域名清单(当前只有
// .musixmatch.com)生效 —— 跟 doh.go 自己"只给解析歪的那个域名开小灶"是同一条纪律,不给
// 本来就通的源多绕一层。全仓其余 26 处 http.Client 一律不动。
const (
	// 系统代理设置读一次缓存多久。开关代理是低频操作,60 秒足够跟手,又不会让每个请求
	// 都 fork 一次 scutil。
	systemProxyCacheTTL = 60 * time.Second
	// scutil 子进程超时。它读的是本机 SystemConfiguration,正常毫秒级。
	systemProxyReadTimeout = 2 * time.Second
	// 代理探活超时。只是本地 TCP 连一下,400ms 很宽裕。
	systemProxyProbeTimeout = 400 * time.Millisecond
)

var (
	systemProxyMu     sync.Mutex
	systemProxyValue  *neturl.URL
	systemProxyReadAt time.Time
)

// systemProxyURL 返回当前**可用**的系统代理。没有配置、或者配置着但连不上,都返回 nil。
//
// ⚠️ 探活(proxyReachable)不能省。代理软件崩溃/被强杀时,macOS 那份系统代理开关会**留在
// 开着的状态**;此时若照单全收,本来只是"某个源直连不通"就会升级成"兜底通道也是死的、还要
// 白等一次超时"。探一下本地 TCP 是几毫秒的事,换的是"配置残留时行为退回直连,不比不加更差"
// —— 跟 doh.go 头注最后一句是同一条纪律。
func systemProxyURL() *neturl.URL {
	systemProxyMu.Lock()
	defer systemProxyMu.Unlock()
	if !systemProxyReadAt.IsZero() && time.Since(systemProxyReadAt) < systemProxyCacheTTL {
		return systemProxyValue
	}
	u := readSystemProxyURL()
	if u != nil && !proxyReachable(u) {
		log.Printf("proxy: 系统代理 %s 配置着但连不上,这一轮当作没有代理", u.Host)
		u = nil
	}
	systemProxyValue, systemProxyReadAt = u, time.Now()
	return u
}

// readSystemProxyURL:环境变量优先,没有再问 scutil。
//
// 环境变量排在前面是因为它更"显式":从终端手动跑 collector 子命令、或者哪天在 launchd
// plist 里配了 EnvironmentVariables,那都是明确指定过的意图,不该被系统设置盖掉。
func readSystemProxyURL() *neturl.URL {
	if u := envProxyURL(); u != nil {
		return u
	}
	ctx, cancel := context.WithTimeout(context.Background(), systemProxyReadTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/scutil", "--proxy").Output()
	if err != nil {
		return nil
	}
	return parseSCUtilProxy(string(out))
}

func envProxyURL() *neturl.URL {
	// 顺序跟 Go 标准库 httpproxy.FromEnvironment 一致:我们发的全是 https,HTTPS_PROXY
	// 最贴切;ALL_PROXY 是 curl/Clash 生态的通用写法,也认。
	for _, key := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"} {
		v := strings.TrimSpace(os.Getenv(key))
		if v == "" {
			continue
		}
		if !strings.Contains(v, "://") {
			v = "http://" + v
		}
		if u, err := neturl.Parse(v); err == nil && u.Host != "" {
			return u
		}
	}
	return nil
}

// parseSCUtilProxy 从 `scutil --proxy` 的输出里挑出代理地址。单独拆成纯函数是为了能用固定
// 样本做单测 —— 这台机器的代理开关状态随时会变,拿它当测试前提用例就不可复现了。
//
// 输出形状(2026-09-03 实测样本,ExceptionsList 已裁剪):
//
//	<dictionary> {
//	  ExceptionsList : <array> {
//	    0 : 127.0.0.1
//	    1 : *.local
//	  }
//	  FTPPassive : 1
//	  HTTPEnable : 1
//	  HTTPPort : 7897
//	  HTTPProxy : 127.0.0.1
//	  HTTPSEnable : 1
//	  HTTPSPort : 7897
//	  HTTPSProxy : 127.0.0.1
//	  ProxyAutoConfigEnable : 0
//	  SOCKSEnable : 1
//	  SOCKSPort : 7897
//	  SOCKSProxy : 127.0.0.1
//	}
//
// 优先级 HTTPS > HTTP > SOCKS:我们发的全是 https 请求,HTTPSProxy 就是系统给这类流量指定
// 的那一个。
//
// ⚠️ 返回的 scheme 是 **http** 而不是 https。那两个字段名说的是"给哪种流量用",不是"用什么
// 协议连代理本身";HTTP(S) 代理靠明文 CONNECT 建隧道,写成 https:// 会让 Go 先去跟代理做一次
// TLS,而本机 Clash 那个端口不说 TLS,整条路直接握手失败。
//
// PAC(ProxyAutoConfigEnable=1)刻意不支持:要跑一段 JS 才能算出该用哪个代理,Go 标准库同样
// 不支持。命中时返回 nil、退回直连,行为跟没有这套东西时一致。
//
// ExceptionsList 也刻意不解析:这条兜底通路只在"直连已经失败"之后才启用,且只对 doh.go 那份
// 域名清单生效(当前只有 .musixmatch.com,不可能出现在内网例外表里)。把 `*.local` / `<local>` /
// `10.0.0.0/8` 这套通配 + CIDR 语义完整实现一遍是一大坨代码,而它能改变的行为只有"某个已经
// 连不上的域名要不要试一下代理"。
func parseSCUtilProxy(out string) *neturl.URL {
	kv := map[string]string{}
	// ExceptionsList 那个嵌套 <array> 里的行形如 `0 : 127.0.0.1`,键是纯数字,跟下面认的
	// 键都不重名,所以不需要为它做括号配对。
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(line, " : ")
		if !ok {
			continue
		}
		kv[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	for _, c := range []struct{ enable, host, port, scheme string }{
		{"HTTPSEnable", "HTTPSProxy", "HTTPSPort", "http"},
		{"HTTPEnable", "HTTPProxy", "HTTPPort", "http"},
		{"SOCKSEnable", "SOCKSProxy", "SOCKSPort", "socks5"},
	} {
		if kv[c.enable] != "1" {
			continue
		}
		host, port := kv[c.host], kv[c.port]
		if host == "" || port == "" {
			continue
		}
		if n, err := strconv.Atoi(port); err != nil || n <= 0 || n > 65535 {
			continue
		}
		return &neturl.URL{Scheme: c.scheme, Host: net.JoinHostPort(host, port)}
	}
	return nil
}

func proxyReachable(u *neturl.URL) bool {
	conn, err := net.DialTimeout("tcp", u.Host, systemProxyProbeTimeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
