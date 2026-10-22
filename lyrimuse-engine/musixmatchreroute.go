package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ---- Musixmatch 被反爬拦下时先换出口,换不了才暂停 ----
//
// Musixmatch 的拦截按出口 IP 来:同一时刻家宽直连的数据接口回 401 captcha,经 Clash 节点出去的照常 200。所以
// 数据接口回 captcha 时(musixmatchDo),先按下面两级换一个出口当场重试,两级都换不了才进 sourcebreaker.go 的暂停:
//  1. 现在走的不是代理、而「代理」设置给得出一个连得上的代理(networkproxy.go 的 fallbackProxyURL):这两台主机改走
//     代理 musixmatchViaProxyAfterBlock(proxyfallback.go 的磁盘提示,常驻进程和一次性子命令都认)。
//  2. 已经走代理(或开着 TUN、直连其实也经过 Clash):Clash 控制口(clashControllerSockets)里有 clashMusixmatchGroup
//     这个手动选择组时,把它切到下一个活着、clashNodeBlockTTL 内没被拦过的节点,断开 Musixmatch 的旧连接。组要用户
//     自己在 Clash 里建,并加一条规则把 musixmatch.com 指给它;没有这个组就没有这一级。「代理」设成不使用、Clash 也没开
//     TUN 时请求不经过 Clash,也没有这一级(clashTunEnabled)。
//
// 并发的请求同时被拦时只换一次:每次换出口出口代数 +1,请求带着发出时的代数回来,代数已经变了就直接按新出口重试。
// 一次被拦之后最多连换 musixmatchMaxReroutes 次,数据接口正经答了一次 200 才归零,免得把节点一个个撞过去。
// 见 09 章决策 320。
const (
	// musixmatchViaProxyAfterBlock:直连被拦之后走代理多久。拦截少则几小时,按 proxyfallback 的 10 分钟起翻倍的话,
	// 每次到期都要拿直连去撞一次。
	musixmatchViaProxyAfterBlock = 6 * time.Hour
	// musixmatchMaxReroutes:两次正常应答之间最多换几次出口(走代理一次 + 切节点几次)。
	musixmatchMaxReroutes = 4
	// musixmatchReroutesPerCall:一次请求里最多换几次出口重试。
	musixmatchReroutesPerCall = 2
	// clashMusixmatchGroup:Clash 里给 Musixmatch 用的手动选择组。
	clashMusixmatchGroup = "Lyrimuse-Musixmatch"
	// clashNodeBlockTTL:一个节点被拦之后多久不再选它。
	clashNodeBlockTTL   = 6 * time.Hour
	clashRequestTimeout = 3 * time.Second
)

// clashControllerSockets:按顺序试的 Clash 控制口(unix socket)。Clash Verge Rev 默认开这一个、权限对本机所有用户开放,
// 不要密钥。单测换成临时目录里的假控制口。
var clashControllerSockets = []string{"/tmp/verge/verge-mihomo.sock"}

// musixmatchProxyAvailable:「代理」设置现在给得出一个连得上的代理。musixmatchOnProxy:这两台主机现在已经走代理。单测换掉,
// 免得读到本机真实的代理。
var (
	musixmatchProxyAvailable = func() bool { return fallbackProxyURL() != nil }
	musixmatchOnProxy        = musixmatchViaProxy
)

var (
	musixmatchRouteMu sync.Mutex
	// musixmatchRouteGen:换过几次出口。请求发出时记下,被拦回来时比一比。
	musixmatchRouteGen int
	// musixmatchRerouteStreak:上一次正常应答之后换过几次出口。
	musixmatchRerouteStreak int
)

func musixmatchRouteGeneration() int {
	musixmatchRouteMu.Lock()
	defer musixmatchRouteMu.Unlock()
	return musixmatchRouteGen
}

// musixmatchRerouteSucceeded:数据接口正经答了一次,连换次数归零。
func musixmatchRerouteSucceeded() {
	musixmatchRouteMu.Lock()
	musixmatchRerouteStreak = 0
	musixmatchRouteMu.Unlock()
}

// musixmatchReroute 在数据接口回 captcha 之后调,sentGen 是这次请求发出时的出口代数。返回 true = 换了出口(或者别的请求
// 已经换过),该当场重试;false = 换不了,照旧暂停。测试入口换成什么都不做的版本。
var musixmatchReroute = musixmatchRerouteAround

func musixmatchRerouteAround(ctx context.Context, sentGen int) bool {
	musixmatchRouteMu.Lock()
	defer musixmatchRouteMu.Unlock()
	if musixmatchRouteGen != sentGen {
		return true
	}
	if musixmatchRerouteStreak >= musixmatchMaxReroutes {
		return false
	}
	switch {
	case !musixmatchOnProxy() && musixmatchProxyAvailable():
		for _, h := range musixmatchHosts() {
			forceProxyFor(musixmatchHTTPClient(), h, musixmatchViaProxyAfterBlock)
		}
		via := "the proxy"
		if u := fallbackProxyURL(); u != nil {
			via = "the proxy at " + u.Host
		}
		log.Printf("musixmatch: blocked by its anti-bot check on this connection; sending it through %s for the next %s", via, musixmatchViaProxyAfterBlock)
	default:
		// 切 Clash 节点只在请求真经过 Clash 时有用:不使用代理、或者手动档填的不是 Clash 的端口(又没开 TUN)时,
		// 切了只是白改用户在 Clash 里的选择。
		viaClash := true
		switch resolveNetworkProxy(features().NetworkProxy) {
		case networkProxyOff:
			viaClash = false
		case networkProxyManual:
			m, c := manualProxyURL(features().NetworkProxyServer), clashProxyURL()
			viaClash = m != nil && c != nil && m.Host == c.Host
		}
		if !viaClash && !clashTunEnabled(ctx) {
			return false
		}
		from, to, ok := clashSwitchGroupNode(ctx, clashMusixmatchGroup, "musixmatch")
		if !ok {
			return false
		}
		log.Printf("musixmatch: blocked by its anti-bot check via Clash node %q; switched group %q to %q", from, clashMusixmatchGroup, to)
	}
	musixmatchRouteGen++
	musixmatchRerouteStreak++
	return true
}

// musixmatchHosts:musixmatchBases 里的主机名。
func musixmatchHosts() []string {
	var out []string
	for _, b := range musixmatchBases {
		if u, err := neturl.Parse(b); err == nil && u.Hostname() != "" {
			out = append(out, u.Hostname())
		}
	}
	return out
}

// musixmatchViaProxy:这两台主机现在是不是都走代理。只有一台走代理时算没走:主用主机走直连、备用主机还在代理上的时候,
// 被拦的是直连那台,该先让它也走代理,切 Clash 节点没用。见 09 章决策 328。
func musixmatchViaProxy() bool {
	t, ok := musixmatchHTTPClient().Transport.(*proxyFallbackTransport)
	return ok && t.preferProxyAll(musixmatchHosts())
}

// ---- Clash 控制口 ----

var (
	clashProxyMu     sync.Mutex
	clashProxyValue  *neturl.URL
	clashProxyReadAt time.Time
)

// clashProxyURL:Clash 控制口报的 mixed-port(没有就 port),连得上才算。跟 systemProxyURL 同样缓存 systemProxyCacheTTL。
// 「代理」设置自动档在系统代理没开时用它:开着 Clash 却没开系统代理、也没开 TUN 时,请求不经过 Clash。
func clashProxyURL() *neturl.URL {
	clashProxyMu.Lock()
	defer clashProxyMu.Unlock()
	if !clashProxyReadAt.IsZero() && time.Since(clashProxyReadAt) < systemProxyCacheTTL {
		return clashProxyValue
	}
	clashProxyValue, clashProxyReadAt = readClashProxyURL(), time.Now()
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

// clashTunEnabled:Clash 控制口报的 TUN 开着(本机流量都经过 Clash)。读不到算没开。
func clashTunEnabled(ctx context.Context) bool {
	c := clashClient()
	if c == nil {
		return false
	}
	ctx, cancel := withCancelAfter(ctx, clashRequestTimeout)
	defer cancel()
	var cfg struct {
		Tun struct {
			Enable bool `json:"enable"`
		} `json:"tun"`
	}
	return clashGet(ctx, c, "/configs", &cfg) == nil && cfg.Tun.Enable
}

// clashClient:连得上的第一个控制口的 HTTP 客户端;都连不上返回 nil。
func clashClient() *http.Client {
	for _, sock := range clashControllerSockets {
		if _, err := os.Stat(sock); err != nil {
			continue
		}
		path := sock
		return &http.Client{
			Timeout: clashRequestTimeout,
			Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", path)
			}},
		}
	}
	return nil
}

type clashProxy struct {
	Type  string   `json:"type"`
	Now   string   `json:"now"`
	All   []string `json:"all"`
	Alive *bool    `json:"alive"`
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

func clashSend(ctx context.Context, c *http.Client, method, path string, body any) error {
	var r io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		r = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://clash"+path, r)
	if err != nil {
		return err
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("clash %s %s: status %d", method, path, resp.StatusCode)
	}
	return nil
}

// clashSkipNode:手动选择组里不算出口节点的几项。
func clashSkipNode(name string) bool {
	switch strings.ToUpper(name) {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE":
		return true
	}
	return false
}

// clashSwitchGroupNode 把手动选择组 group 切到下一个可用节点,断开 metadata.host 里带 hostKeyword 的连接。原来那个节点
// 记成被拦(clashNodeBlockTTL 内不再选)。下一个 = 组里排在当前节点后面、活着、最近没被拦过的第一个,绕到头为止。
func clashSwitchGroupNode(ctx context.Context, group, hostKeyword string) (from, to string, ok bool) {
	c := clashClient()
	if c == nil {
		return "", "", false
	}
	ctx, cancel := withCancelAfter(ctx, 2*clashRequestTimeout)
	defer cancel()
	var g clashProxy
	if err := clashGet(ctx, c, "/proxies/"+neturl.PathEscape(group), &g); err != nil || g.Type != "Selector" || len(g.All) == 0 {
		return "", "", false
	}
	blocked := loadClashNodeBlocks()
	now := time.Now()
	if g.Now != "" {
		blocked[g.Now] = now.Unix()
	}
	start := 0
	for i, n := range g.All {
		if n == g.Now {
			start = i + 1
			break
		}
	}
	for k := 0; k < len(g.All); k++ {
		cand := g.All[(start+k)%len(g.All)]
		if cand == g.Now || clashSkipNode(cand) {
			continue
		}
		if at, ok := blocked[cand]; ok && now.Sub(time.Unix(at, 0)) < clashNodeBlockTTL {
			continue
		}
		var p clashProxy
		if err := clashGet(ctx, c, "/proxies/"+neturl.PathEscape(cand), &p); err != nil || (p.Alive != nil && !*p.Alive) {
			continue
		}
		if err := clashSend(ctx, c, http.MethodPut, "/proxies/"+neturl.PathEscape(group), map[string]string{"name": cand}); err != nil {
			return "", "", false
		}
		saveClashNodeBlocks(blocked)
		clashCloseConnections(ctx, c, hostKeyword)
		return g.Now, cand, true
	}
	saveClashNodeBlocks(blocked)
	return "", "", false
}

// clashCloseConnections 断开目标主机带 hostKeyword 的连接:长连接还钉在旧节点上的话,切了组也照样从旧出口出去。
func clashCloseConnections(ctx context.Context, c *http.Client, hostKeyword string) {
	var conns struct {
		Connections []struct {
			ID       string `json:"id"`
			Metadata struct {
				Host string `json:"host"`
			} `json:"metadata"`
		} `json:"connections"`
	}
	if clashGet(ctx, c, "/connections", &conns) != nil {
		return
	}
	for _, cn := range conns.Connections {
		if strings.Contains(cn.Metadata.Host, hostKeyword) {
			_ = clashSend(ctx, c, http.MethodDelete, "/connections/"+neturl.PathEscape(cn.ID), nil)
		}
	}
}

// ---- 被拦过的节点(存盘:引擎常重启,不存的话每次重启都从被拦的那个节点重新撞) ----

func clashNodeBlocksPath() string {
	if cacheDir() == "" {
		return ""
	}
	return cacheFilePath(clientName + "-clash-node-blocks.json")
}

// loadClashNodeBlocks:节点名 → 被拦的 unix 秒。过了 clashNodeBlockTTL 的丢掉。
func loadClashNodeBlocks() map[string]int64 {
	out := map[string]int64{}
	path := clashNodeBlocksPath()
	if path == "" {
		return out
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return out
	}
	var m map[string]int64
	if json.Unmarshal(raw, &m) != nil {
		return out
	}
	for k, v := range m {
		if time.Since(time.Unix(v, 0)) < clashNodeBlockTTL {
			out[k] = v
		}
	}
	return out
}

func saveClashNodeBlocks(m map[string]int64) {
	path := clashNodeBlocksPath()
	if path == "" {
		return
	}
	raw, err := json.Marshal(m)
	if err != nil {
		return
	}
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return
	}
	_ = writeFileAtomic(path, raw)
}
