package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeClash:临时目录里的 unix socket 上起一个假的 Clash 控制口。groups 是组名 → 成员,dead 是 alive=false 的节点。
type fakeClash struct {
	mu      sync.Mutex
	now     map[string]string
	groups  map[string][]string
	types   map[string]string // 组的类型,没写的是 Selector
	dead    map[string]bool
	conns   []string // 连接的 host,id 按下标
	deleted []string
	puts    []string
	// mixedPort:/configs 报的 mixed-port。tun:/configs 报的 tun.enable。
	mixedPort int
	tun       bool
}

func withFakeClash(t *testing.T, fc *fakeClash) {
	t.Helper()
	dir, err := os.MkdirTemp("", "clash")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "c.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &httptest.Server{Listener: ln, Config: &http.Server{Handler: http.HandlerFunc(fc.serve)}}
	srv.Start()
	t.Cleanup(srv.Close)
	saved := clashControllerSockets
	clashControllerSockets = []string{filepath.Join(dir, "missing.sock"), sock}
	t.Cleanup(func() { clashControllerSockets = saved })
	saveClashNodeBlocks(map[string]int64{})
	t.Cleanup(func() { saveClashNodeBlocks(map[string]int64{}) })
}

func (fc *fakeClash) serve(w http.ResponseWriter, r *http.Request) {
	fc.mu.Lock()
	defer fc.mu.Unlock()
	path, _ := neturl.PathUnescape(r.URL.EscapedPath())
	switch {
	case r.Method == http.MethodGet && path == "/configs":
		json.NewEncoder(w).Encode(map[string]any{"mixed-port": fc.mixedPort, "tun": map[string]bool{"enable": fc.tun}})
	case r.Method == http.MethodGet && path == "/connections":
		var out struct {
			Connections []map[string]any `json:"connections"`
		}
		for i, h := range fc.conns {
			out.Connections = append(out.Connections, map[string]any{"id": string(rune('a' + i)), "metadata": map[string]string{"host": h}})
		}
		json.NewEncoder(w).Encode(out)
	case r.Method == http.MethodDelete && strings.HasPrefix(path, "/connections/"):
		fc.deleted = append(fc.deleted, strings.TrimPrefix(path, "/connections/"))
		w.WriteHeader(http.StatusNoContent)
	case strings.HasPrefix(path, "/proxies/"):
		name := strings.TrimPrefix(path, "/proxies/")
		if r.Method == http.MethodPut {
			var body struct{ Name string }
			raw, _ := io.ReadAll(r.Body)
			json.Unmarshal(raw, &body)
			fc.puts = append(fc.puts, body.Name)
			fc.now[name] = body.Name
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if members, ok := fc.groups[name]; ok {
			typ := "Selector"
			if fc.types[name] != "" {
				typ = fc.types[name]
			}
			json.NewEncoder(w).Encode(map[string]any{"type": typ, "now": fc.now[name], "all": members})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"type": "Trojan", "alive": !fc.dead[name]})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// 切到排在当前节点后面、活着、最近没被拦过的第一个;原来那个记成被拦;只断 Musixmatch 的连接。
func TestClashSwitchGroupNode(t *testing.T) {
	fc := &fakeClash{
		now:    map[string]string{clashMusixmatchGroup: "A"},
		groups: map[string][]string{clashMusixmatchGroup: {"DIRECT", "A", "B", "C", "D", "E"}},
		dead:   map[string]bool{"B": true},
		conns:  []string{"apic-appmobile.musixmatch.com", "music.163.com", "apic.musixmatch.com"},
	}
	withFakeClash(t, fc)
	saveClashNodeBlocks(map[string]int64{"C": time.Now().Add(-time.Hour).Unix(), "E": time.Now().Add(-7 * time.Hour).Unix()})

	from, to, ok := clashSwitchGroupNode(context.Background(), clashMusixmatchGroup, "musixmatch")
	if !ok || from != "A" || to != "D" {
		t.Fatalf("应从 A 切到 D(B 不活、C 刚被拦过),得到 %q→%q ok=%v", from, to, ok)
	}
	if strings.Join(fc.deleted, ",") != "a,c" {
		t.Errorf("只断 Musixmatch 的连接,得到 %v", fc.deleted)
	}
	blocks := loadClashNodeBlocks()
	if _, ok := blocks["A"]; !ok {
		t.Error("切走的节点要记成被拦")
	}
	if _, ok := blocks["E"]; ok {
		t.Error("过了 clashNodeBlockTTL 的记录要丢掉")
	}

	// 再被拦:D 记成被拦,E 已经过期可以选。
	if _, to, ok := clashSwitchGroupNode(context.Background(), clashMusixmatchGroup, "musixmatch"); !ok || to != "E" {
		t.Fatalf("第二次应切到 E,得到 %q ok=%v", to, ok)
	}
	// 再被拦:绕回去,A / C / D 都刚被拦过、B 不活,没有可切的。
	if _, _, ok := clashSwitchGroupNode(context.Background(), clashMusixmatchGroup, "musixmatch"); ok {
		t.Fatal("没有可用节点时不切")
	}
}

func TestClashSwitchGroupNodeNeedsSelectorGroup(t *testing.T) {
	fc := &fakeClash{now: map[string]string{}, groups: map[string][]string{"Proxy": {"A", "B"}, "Auto": {"A", "B"}}, types: map[string]string{"Auto": "URLTest"}}
	withFakeClash(t, fc)
	if _, _, ok := clashSwitchGroupNode(context.Background(), clashMusixmatchGroup, "musixmatch"); ok {
		t.Fatal("没有这个组时不切")
	}
	if _, _, ok := clashSwitchGroupNode(context.Background(), "Auto", "musixmatch"); ok || len(fc.puts) != 0 {
		t.Fatal("不是手动选择组时不切")
	}
	saved := clashControllerSockets
	clashControllerSockets = []string{"/nonexistent/clash.sock"}
	t.Cleanup(func() { clashControllerSockets = saved })
	if _, _, ok := clashSwitchGroupNode(context.Background(), "Proxy", "musixmatch"); ok {
		t.Fatal("控制口连不上时不切")
	}
}

func resetMusixmatchRoute(t *testing.T) {
	t.Helper()
	musixmatchRouteMu.Lock()
	musixmatchRouteGen, musixmatchRerouteStreak = 0, 0
	musixmatchRouteMu.Unlock()
	t.Cleanup(func() {
		musixmatchRouteMu.Lock()
		musixmatchRouteGen, musixmatchRerouteStreak = 0, 0
		musixmatchRouteMu.Unlock()
	})
}

// 先改走系统代理;已经走代理了再切 Clash 节点;并发请求同时被拦只换一次;连换次数到顶就不换。
func TestMusixmatchRerouteAround(t *testing.T) {
	resetMusixmatchRoute(t)
	fc := &fakeClash{
		now:    map[string]string{clashMusixmatchGroup: "A"},
		groups: map[string][]string{clashMusixmatchGroup: {"A", "B", "C", "D", "E", "F"}},
	}
	withFakeClash(t, fc)
	var onProxy, proxyUp atomic.Bool
	proxyUp.Store(true)
	savedA, savedO := musixmatchProxyAvailable, musixmatchOnProxy
	musixmatchProxyAvailable = proxyUp.Load
	musixmatchOnProxy = onProxy.Load
	t.Cleanup(func() { musixmatchProxyAvailable, musixmatchOnProxy = savedA, savedO })

	ctx := context.Background()
	if !musixmatchRerouteAround(ctx, 0) || len(fc.puts) != 0 {
		t.Fatal("直连被拦、代理连得上:先改走代理,不切节点")
	}
	if !loadProxyFallbackHint(musixmatchHosts()[0]) {
		t.Error("改走代理要写进磁盘提示,一次性子命令也认")
	}
	if !musixmatchRerouteAround(ctx, 0) || len(fc.puts) != 0 {
		t.Fatal("带着旧代数回来的请求:别人已经换过了,直接重试,不再换")
	}
	onProxy.Store(true)
	if !musixmatchRerouteAround(ctx, musixmatchRouteGeneration()) || strings.Join(fc.puts, ",") != "B" {
		t.Fatalf("已经走代理:切 Clash 节点,得到 %v", fc.puts)
	}
	musixmatchRerouteAround(ctx, musixmatchRouteGeneration())
	musixmatchRerouteAround(ctx, musixmatchRouteGeneration())
	if musixmatchRerouteAround(ctx, musixmatchRouteGeneration()) || strings.Join(fc.puts, ",") != "B,C,D" {
		t.Fatalf("连换 %d 次之后不再换,切过 %v", musixmatchMaxReroutes, fc.puts)
	}
	musixmatchRerouteSucceeded()
	if !musixmatchRerouteAround(ctx, musixmatchRouteGeneration()) || strings.Join(fc.puts, ",") != "B,C,D,E" {
		t.Fatalf("正常答过一次之后连换次数归零,切过 %v", fc.puts)
	}

	// 「代理」设成不使用:没开 TUN 时请求不经过 Clash,不切;开着 TUN 照切。
	resetMusixmatchRoute(t)
	onProxy.Store(false)
	proxyUp.Store(false)
	withFeatures(t, featureFlags{NetworkProxy: networkProxyOff})
	before := len(fc.puts)
	if musixmatchRerouteAround(ctx, musixmatchRouteGeneration()) || len(fc.puts) != before {
		t.Fatalf("不使用代理、没开 TUN:不切节点,切过 %v", fc.puts)
	}
	fc.mu.Lock()
	fc.tun = true
	fc.mu.Unlock()
	if !musixmatchRerouteAround(ctx, musixmatchRouteGeneration()) || len(fc.puts) != before+1 {
		t.Fatalf("不使用代理、开着 TUN:照切,切过 %v", fc.puts)
	}
	setFeatures(featureFlags{})

	resetMusixmatchRoute(t)
	clashControllerSockets = []string{"/nonexistent/clash.sock"}
	if musixmatchRerouteAround(ctx, 0) {
		t.Fatal("没有代理、也没有 Clash 控制口:换不了")
	}
}

// 数据接口被拦后换了出口就当场重试,不暂停;token.get 不走这一步。
func TestMusixmatchDoRetriesAfterReroute(t *testing.T) {
	resetMusixmatchRoute(t)
	var calls atomic.Int32
	var rerouted atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if !rerouted.Load() {
			w.Write([]byte(`{"message":{"header":{"status_code":401,"hint":"captcha"},"body":""}}`))
			return
		}
		w.Write([]byte(`{"message":{"header":{"status_code":200},"body":{}}}`))
	}))
	defer srv.Close()
	savedBases := musixmatchBases
	musixmatchBases = []string{srv.URL + "/"}
	t.Cleanup(func() { musixmatchBases = savedBases })
	musixmatchTokenMu.Lock()
	savedTok, savedExp := musixmatchToken, musixmatchTokenExpiry
	musixmatchToken, musixmatchTokenExpiry = "tok", time.Now().Add(time.Hour)
	musixmatchTokenMu.Unlock()
	t.Cleanup(func() {
		musixmatchTokenMu.Lock()
		musixmatchToken, musixmatchTokenExpiry = savedTok, savedExp
		musixmatchTokenMu.Unlock()
		musixmatchSetLastFailureReason("")
	})
	prev := sharedLyricSourceBreaker()
	b, _ := newTestBreaker()
	setSharedLyricSourceBreaker(b)
	t.Cleanup(func() { setSharedLyricSourceBreaker(prev) })
	var reroutes atomic.Int32
	savedR := musixmatchReroute
	musixmatchReroute = func(context.Context, int) bool {
		reroutes.Add(1)
		rerouted.Store(true)
		return true
	}
	t.Cleanup(func() { musixmatchReroute = savedR })

	musixmatchRouteMu.Lock()
	musixmatchRerouteStreak = 3
	musixmatchRouteMu.Unlock()
	body, err := musixmatchDo(context.Background(), "track.search", neturl.Values{"q_track": {"Yesterday"}})
	if err != nil || musixmatchHeaderStatus(body) != 200 {
		t.Fatalf("换了出口应当场重试拿到正常应答: %v %s", err, body)
	}
	musixmatchRouteMu.Lock()
	streak := musixmatchRerouteStreak
	musixmatchRouteMu.Unlock()
	if streak != 0 {
		t.Fatalf("正常应答之后连换次数归零,得到 %d", streak)
	}
	if calls.Load() != 2 || reroutes.Load() != 1 {
		t.Fatalf("请求 %d 次、换出口 %d 次,想要 2 / 1", calls.Load(), reroutes.Load())
	}
	if _, blocked := b.blockedFor("musixmatch"); blocked {
		t.Fatal("换出口救回来了,不该暂停")
	}

	// 一直被拦:每次请求最多换 musixmatchReroutesPerCall 次,之后照旧暂停。
	rerouted.Store(false)
	musixmatchReroute = func(context.Context, int) bool { reroutes.Add(1); return true }
	calls.Store(0)
	reroutes.Store(0)
	body, _ = musixmatchDo(context.Background(), "track.search", neturl.Values{"q_track": {"Yesterday"}})
	if !musixmatchBlockedByCaptcha(body) || reroutes.Load() != musixmatchReroutesPerCall || calls.Load() != musixmatchReroutesPerCall+1 {
		t.Fatalf("换 %d 次、请求 %d 次", reroutes.Load(), calls.Load())
	}
	if _, blocked := b.blockedFor("musixmatch"); !blocked {
		t.Fatal("换了还被拦就暂停")
	}
}

// forceProxyFor 写进内存粘性和磁盘提示,窗口按给的时长。
func TestForceProxyFor(t *testing.T) {
	tr := &proxyFallbackTransport{}
	c := &http.Client{Transport: tr}
	forceProxyFor(c, "a.example", 3*time.Hour)
	tr.mu.Lock()
	left := time.Until(tr.stickyUntil)
	tr.mu.Unlock()
	if left < 2*time.Hour || left > 3*time.Hour {
		t.Fatalf("内存粘性应约 3 小时,得到 %s", left)
	}
	f := readProxyFallbackHint()
	if u, ok := f.Until["a.example"]; !ok || time.Until(time.Unix(u, 0)) < 2*time.Hour {
		t.Fatalf("磁盘提示应写到约 3 小时后: %v", f.Until)
	}
	forceProxyFor(&http.Client{}, "b.example", time.Hour)
	if _, ok := readProxyFallbackHint().Until["b.example"]; ok {
		t.Fatal("不是代理回退那一层的客户端时什么都不做")
	}
}

// 读 Clash 报的 mixed-port,连得上才用;控制口不在、端口没人听时返回 nil。
func TestReadClashProxyURL(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	fc := &fakeClash{mixedPort: port}
	withFakeClash(t, fc)
	if u := readClashProxyURL(); u == nil || u.Host != ln.Addr().String() {
		t.Fatalf("应读到 %s,得到 %v", ln.Addr(), u)
	}
	ln.Close()
	if u := readClashProxyURL(); u != nil {
		t.Fatalf("端口没人听时不用,得到 %v", u)
	}
	clashControllerSockets = []string{"/nonexistent/clash.sock"}
	if u := readClashProxyURL(); u != nil {
		t.Fatalf("控制口不在时没有,得到 %v", u)
	}
}

// proxy() 用设了的 proxyURL,没设才读「代理」设置(TestFallbackClientsFollowProxySetting)。
func TestProxyFallbackTransportProxyURL(t *testing.T) {
	want := &neturl.URL{Scheme: "http", Host: "127.0.0.1:1"}
	tr := &proxyFallbackTransport{proxyURL: func() *neturl.URL { return want }}
	if got := tr.proxy(); got != want {
		t.Fatalf("设了 proxyURL 就用它,得到 %v", got)
	}
	if got := (&proxyFallbackTransport{proxyURL: func() *neturl.URL { return nil }}).proxy(); got != nil {
		t.Fatalf("proxyURL 说没有就是没有,得到 %v", got)
	}
}
