package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	neturl "net/url"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- 「代理」自动档:找本机代理软件监听的端口 ----
//
// 系统代理没开、Clash 控制口也读不到时用(networkproxy.go 的 networkProxyAutoSources 最后一步)。两路候选,按顺序:
//  1. 按进程发现:列出本机监听端口和所属进程,取进程名像代理软件的(localProxyProcessNames)那几个端口。两份来源合并:
//     `lsof` 只看得到本用户的进程;`netstat -anv` 连 root 的也看得到,但从引擎(launchd 拉起、非系统签名)里调时
//     TCP 列表是空的,只在终端里手动跑子命令时有用。root 身份跑的代理内核(Clash Verge Rev 的服务模式)靠
//     clashProxyURL 和下面的默认端口兜。
//  2. 常见客户端的默认端口(networkProxyCommonPorts)。
//
// 候选都要过握手才用(verifyLocalProxy):HTTP CONNECT 到自己开的一个本机端口回 200,或者 SOCKS5 问候回 05 00。
// 只连本机,不往外发任何请求;代理软件的控制接口、本机别的服务都过不了。结果缓存 systemProxyCacheTTL。见 09 章决策 322。

// localProxyProcessNames:进程名(转小写)里含这些词的算代理软件。调试抓包代理(Charles、Proxyman、mitmproxy)刻意不在里面。
var localProxyProcessNames = []string{
	"mihomo", "clash", "sing-box", "xray", "v2ray", "ss-local", "sslocal", "shadowsocks", "privoxy", "trojan",
	"hysteria", "tuic", "naive", "brook", "surge", "stash", "quantumult", "shadowrocket", "nekoray", "nekobox",
	"hiddify", "karing", "qv2ray",
}

// networkProxyCommonPorts:常见客户端的默认端口。Clash 系 7890 / 7891、Clash Verge Rev 7897、Surge 6152 / 6153、
// ShadowsocksX-NG 1086 / 1087、V2rayU 1080、v2rayN 10808 / 10809、NekoRay 2080、v2rayA 20170–20172、privoxy 8118、
// Qv2ray 1089 / 8889。
var networkProxyCommonPorts = []int{
	7890, 7897, 7891, 6152, 6153, 1087, 1086, 1080, 10809, 10808, 2080, 20172, 20171, 20170, 8118, 8889, 1089,
}

const localProxyListTimeout = 2 * time.Second

// localProxyHandshakeTimeout:握手一个端口最多等多久(本机,正常毫秒级)。单测改短。
var localProxyHandshakeTimeout = 800 * time.Millisecond

// localListener:一个本机监听端口。host 是拨号用的地址(127.0.0.1 或 ::1)。
type localListener struct {
	host    string
	port    int
	process string
}

// localProxyListeners:本机的监听端口(lsof 在前)。单测换掉。
var localProxyListeners = func() []localListener {
	var res []localListener
	if out := runListLocal("/usr/sbin/lsof", "-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"); out != "" {
		res = append(res, parseLsofListeners(out)...)
	}
	if out := runListLocal("/usr/sbin/netstat", "-anv", "-p", "tcp"); out != "" {
		res = append(res, parseNetstatListeners(out)...)
	}
	return res
}

func runListLocal(name string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), localProxyListTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// parseLsofListeners 读 `lsof -nP +c 0 -iTCP -sTCP:LISTEN -F pcn`:p 行是 pid,c 行是进程名,n 行是监听地址
// (127.0.0.1:7890、*:7890、[::1]:7890),各行属于它前面最近的 p / c。
func parseLsofListeners(out string) []localListener {
	var res []localListener
	proc := ""
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			proc = ""
		case 'c':
			proc = line[1:]
		case 'n':
			host, portStr, err := net.SplitHostPort(line[1:])
			if err != nil {
				continue
			}
			port, err := strconv.Atoi(portStr)
			if err != nil || port <= 0 || port > 65535 {
				continue
			}
			switch host {
			case "127.0.0.1", "*", "localhost":
				host = "127.0.0.1"
			case "::1":
			default:
				continue
			}
			res = append(res, localListener{host: host, port: port, process: proc})
		}
	}
	return res
}

// parseNetstatListeners 从 `netstat -anv -p tcp` 的输出里挑出本机能连的监听端口(127.0.0.1、::1、*)。
//
// 行的形状(进程名里可能有空格,所以 process:pid 从右边数:它后面固定还有 8 列):
//
//	tcp4  0  0  127.0.0.1.7897  *.*  LISTEN  0  0  131072  131072  verge-mihomo:2469  00180 00000006 ... 1  0  000000
func parseNetstatListeners(out string) []localListener {
	var res []localListener
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 19 || !strings.HasPrefix(f[0], "tcp") || f[5] != "LISTEN" {
			continue
		}
		dot := strings.LastIndex(f[3], ".")
		if dot <= 0 {
			continue
		}
		port, err := strconv.Atoi(f[3][dot+1:])
		if err != nil || port <= 0 || port > 65535 {
			continue
		}
		var host string
		switch f[3][:dot] {
		case "127.0.0.1", "*":
			host = "127.0.0.1"
		case "::1":
			host = "::1"
		default:
			continue
		}
		proc := strings.Join(f[10:len(f)-8], " ")
		if i := strings.LastIndex(proc, ":"); i > 0 {
			proc = proc[:i]
		}
		res = append(res, localListener{host: host, port: port, process: proc})
	}
	return res
}

func isLocalProxyProcess(name string) bool {
	n := strings.ToLower(name)
	for _, w := range localProxyProcessNames {
		if strings.Contains(n, w) {
			return true
		}
	}
	return false
}

var (
	localProxyMu     sync.Mutex
	localProxyValue  *neturl.URL
	localProxyReadAt time.Time
)

// localProxyURL:本机代理软件监听的、握手确认过的第一个端口;没有返回 nil。缓存 systemProxyCacheTTL。
func localProxyURL() *neturl.URL {
	localProxyMu.Lock()
	defer localProxyMu.Unlock()
	if !localProxyReadAt.IsZero() && time.Since(localProxyReadAt) < systemProxyCacheTTL {
		return localProxyValue
	}
	localProxyValue, localProxyReadAt = discoverLocalProxy(), time.Now()
	return localProxyValue
}

func discoverLocalProxy() *neturl.URL {
	seen := map[string]bool{}
	var candidates []string
	add := func(host string, port int) {
		addr := net.JoinHostPort(host, strconv.Itoa(port))
		if !seen[addr] {
			seen[addr] = true
			candidates = append(candidates, addr)
		}
	}
	for _, l := range localProxyListeners() {
		if isLocalProxyProcess(l.process) {
			add(l.host, l.port)
		}
	}
	for _, p := range networkProxyCommonPorts {
		add("127.0.0.1", p)
	}
	for _, addr := range candidates {
		if u := verifyLocalProxy(addr); u != nil {
			return u
		}
	}
	return nil
}

// verifyLocalProxy:addr 上是不是一个能用的代理。先试 HTTP(CONNECT 到自己开的本机端口,回 200),再试 SOCKS5
// (问候回 05 00,不要认证)。都不是返回 nil。
func verifyLocalProxy(addr string) *neturl.URL {
	if httpProxyHandshake(addr) {
		return &neturl.URL{Scheme: "http", Host: addr}
	}
	if socks5ProxyHandshake(addr) {
		return &neturl.URL{Scheme: "socks5", Host: addr}
	}
	return nil
}

func httpProxyHandshake(addr string) bool {
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return false
	}
	defer target.Close()
	go func() {
		for {
			c, err := target.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	conn, err := net.DialTimeout("tcp", addr, localProxyHandshakeTimeout)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(localProxyHandshakeTimeout))
	t := target.Addr().String()
	if _, err := fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", t, t); err != nil {
		return false
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return false
	}
	f := strings.Fields(line)
	return len(f) >= 2 && strings.HasPrefix(f[0], "HTTP/1.") && f[1] == "200"
}

func socks5ProxyHandshake(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, localProxyHandshakeTimeout)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(localProxyHandshakeTimeout))
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return false
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return false
	}
	return bytes.Equal(reply, []byte{0x05, 0x00})
}
