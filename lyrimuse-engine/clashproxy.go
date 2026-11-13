package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"sync"
	"time"
)

// ---- Clash 控制口 ----

const clashRequestTimeout = 3 * time.Second

// clashControllerSockets:按顺序试的 Clash 控制口(unix socket)。Clash Verge Rev 默认开这一个、权限对本机所有用户开放,
// 不要密钥。单测换成临时目录里的假控制口。
var clashControllerSockets = []string{"/tmp/verge/verge-mihomo.sock"}

var (
	clashProxyMu     sync.Mutex
	clashProxyValue  *neturl.URL
	clashProxyReadAt time.Time
)

// clashProxyURL:Clash 控制口报的 mixed-port(没有就 port),连得上才算。跟 systemProxyURL 同样缓存 systemProxyCacheTTL,
// 读取时刻只记墙钟(睡眠时单调时钟不走)。
// 「代理」设置自动档在系统代理没开时用它:开着 Clash 却没开系统代理、也没开 TUN 时,请求不经过 Clash。
func clashProxyURL() *neturl.URL {
	clashProxyMu.Lock()
	defer clashProxyMu.Unlock()
	if !clashProxyReadAt.IsZero() && time.Since(clashProxyReadAt) < systemProxyCacheTTL {
		return clashProxyValue
	}
	clashProxyValue, clashProxyReadAt = readClashProxyURL(), time.Now().Round(0)
	return clashProxyValue
}

func readClashProxyURL() *neturl.URL {
	c := clashClient()
	if c == nil {
		return nil
	}
	ctx, cancel := withCancelAfter(context.Background(), clashRequestTimeout)
	defer cancel()
	var cfg struct {
		MixedPort int `json:"mixed-port"`
		Port      int `json:"port"`
	}
	if clashGet(ctx, c, "/configs", &cfg) != nil {
		return nil
	}
	port := cfg.MixedPort
	if port == 0 {
		port = cfg.Port
	}
	if port == 0 {
		return nil
	}
	u := &neturl.URL{Scheme: "http", Host: fmt.Sprintf("127.0.0.1:%d", port)}
	if !proxyReachable(u) {
		return nil
	}
	return u
}

// clashClient:连得上的第一个控制口的 HTTP 客户端;都连不上返回 nil。每次调用都新建,所以不留空闲连接:
// 请求完就断开,不然每个客户端的空闲连接和后台协程都留着、越积越多。
func clashClient() *http.Client {
	for _, sock := range clashControllerSockets {
		if _, err := os.Stat(sock); err != nil {
			continue
		}
		path := sock
		return &http.Client{
			Timeout: clashRequestTimeout,
			Transport: &http.Transport{DisableKeepAlives: true, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", path)
			}},
		}
	}
	return nil
}

func clashGet(ctx context.Context, c *http.Client, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://clash"+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("clash GET %s: status %d", path, resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(out)
}
