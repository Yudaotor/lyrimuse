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

// DoH(DNS over HTTPS)解析。歌词源的拨号器(lyricsourcedial.go)在系统 DNS 报错时用它:dohLookup 拿 IP,
// dohDialRaceWith 并发拨号。
const (
	dohTimeout  = 4 * time.Second
	dohCacheTTL = 30 * time.Minute
	// dohNegativeTTL:两个端点都没答上来时,空结果只记这么久。跟系统 DNS 的负缓存
	// (lyricSourceSystemDNSFailTTL)同一个量级:现在八个歌词源都靠这里兜底,合盖唤醒、切网那几秒
	// 恰好查失败的话,记 30 分钟就是网络恢复之后这半小时它们全报「DNS 失败」。
	dohNegativeTTL = 60 * time.Second
	// 单个地址的拨号上限。dohDialRaceWith 并发拨号,这个值不决定"整体等多久"
	// (黑洞地址不会挡住好地址),真正卡总时长的是调用方 ctx 上的 deadline。
	dohDialTimeout = 8 * time.Second
)

// 两个 DoH 端点都用 IP 直连(自己不需要再解析一次 DNS,否则就是鸡生蛋)。
// 按顺序试,先成功先用。
var dohEndpoints = []string{
	"https://1.1.1.1/dns-query",
	"https://8.8.8.8/resolve",
}

type dohEntry struct {
	ips     []string
	expires time.Time
}

var (
	dohMu    sync.Mutex
	dohCache = map[string]dohEntry{}
	// dohInflight:正在查的域名。同一个域名同时只查一次,后来的等它的结果(几个歌词源的请求常常同时
	// 撞上同一台主机的系统 DNS 失败)。受 dohMu 保护。
	dohInflight = map[string]*dohFlight{}
)

type dohFlight struct {
	done chan struct{}
	ips  []string
}

// dohLookup 返回这个域名的 A 记录。查不到/查询失败/调用方的 ctx 先结束了返回 nil,调用方据此退回系统解析。
//
// 查询本身在自己的 goroutine 里跑、不跟任何一个调用方的 ctx 走:结果要缓存下来给别人用,一个调用方被取消
// 不该让等着同一个结果的其他人跟着落空。调用方只是不再等(每个端点 dohTimeout,最多两个)。
func dohLookup(ctx context.Context, host string) []string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))

	dohMu.Lock()
	if e, ok := dohCache[host]; ok && time.Now().Before(e.expires) {
		ips := e.ips
		dohMu.Unlock()
		return ips
	}
	f, running := dohInflight[host]
	if !running {
		f = &dohFlight{done: make(chan struct{})}
		dohInflight[host] = f
		go dohResolve(host, f)
	}
	dohMu.Unlock()

	select {
	case <-f.done:
		return f.ips
	case <-ctx.Done():
		return nil
	}
}

// dohResolve 把 host 按顺序问两个端点,结果写进缓存并交给等着的人。
func dohResolve(host string, f *dohFlight) {
	var ips []string
	for _, endpoint := range dohEndpoints {
		if got := dohQuery(endpoint, host); len(got) > 0 {
			ips = got
			break
		}
	}
	// 失败也缓存(空结果),避免每次请求都为一个解析不出来的域名重试一遍 DoH;只是记得短(dohNegativeTTL)。
	ttl := dohCacheTTL
	if len(ips) == 0 {
		ttl = dohNegativeTTL
	}
	dohMu.Lock()
	dohCache[host] = dohEntry{ips: ips, expires: time.Now().Add(ttl)}
	delete(dohInflight, host)
	f.ips = ips
	dohMu.Unlock()
	close(f.done)
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

func dohDialer() *net.Dialer {
	return &net.Dialer{Timeout: dohDialTimeout, KeepAlive: 30 * time.Second}
}

// dohDialRaceWith 对 DoH 查到的每个地址**同时**发起拨号(dial 是拨号器),第一个连上的胜出,慢一步也连上的
// 当场关掉。ips 为空时返回 (nil, nil),由调用方退回系统解析。
//
// 别改成串行逐个拨:每个 dialer.Timeout = 8s,第一个地址是黑洞(SYN 石沉大海、不是被拒)时预算全耗在它身上,
// 永远轮不到第二个;而 DoH 返回的地址顺序是随机轮转的,dohCache 又一存 30 分钟。并发拨号让"有一个地址能连"
// 直接等价于"连得上",跟顺序无关。标准库的 Happy Eyeballs 只在它自己解析出多个地址时生效,这里走不到。
//
// dial 可注入只为单测:要证明"第一个地址是黑洞时不再挡住第二个",得有一个真的永远不返回的拨号目标。
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
			// 调用方不等了,但还有 remaining 路拨号没回来:恰好在这一刻连上的那条没人关,只能等 GC 收 fd。
			// 跟赢家那一支一样起个收尾 goroutine 排干(ch 的缓冲开满,不会卡住拨号的那几个)。
			go func(n int) {
				for i := 0; i < n; i++ {
					if o := <-ch; o.conn != nil {
						_ = o.conn.Close()
					}
				}
			}(remaining)
			cancel()
			return nil, dialCtx.Err()
		}
	}
	cancel()
	return nil, firstErr
}
