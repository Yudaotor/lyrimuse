package main

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type guardClock struct{ t time.Time }

func (c *guardClock) now() time.Time      { return c.t }
func (c *guardClock) add(d time.Duration) { c.t = c.t.Add(d) }

func newTestGuard(rate hostRate) (*hostGuard, *guardClock) {
	c := &guardClock{t: time.Unix(1_000_000, 0)}
	g := newHostGuard(c.now)
	g.rateFor = func(string) hostRate { return rate }
	return g, c
}

func mustReq(t *testing.T, ctx context.Context, method, raw string) *http.Request {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, method, raw, nil)
	if err != nil {
		t.Fatal(err)
	}
	return req
}

// 攒满的桶先放 burst 个不等,之后按速率排队;排队超过上限或截止时间就不预订。
func TestHostGuardReserveQueuesThenRefuses(t *testing.T) {
	g, c := newTestGuard(hostRate{perSec: 1, burst: 2})
	g.maxWait = 3 * time.Second
	for i := 0; i < 2; i++ {
		if wait, ok := g.reserve("a.example", time.Time{}); !ok || wait != 0 {
			t.Fatalf("第 %d 个该直接放行: wait=%v ok=%v", i+1, wait, ok)
		}
	}
	if wait, ok := g.reserve("a.example", time.Time{}); !ok || wait != time.Second {
		t.Fatalf("桶空了该排 1 秒: wait=%v ok=%v", wait, ok)
	}
	if wait, ok := g.reserve("a.example", time.Time{}); !ok || wait != 2*time.Second {
		t.Fatalf("再来一个该排 2 秒: wait=%v ok=%v", wait, ok)
	}
	if _, ok := g.reserve("a.example", c.t.Add(2500*time.Millisecond)); ok {
		t.Fatal("要等 3 秒、截止时间只剩 2.5 秒,不该预订")
	}
	if _, ok := g.reserve("a.example", time.Time{}); !ok {
		t.Fatal("截止时间那次没预订成,不该占掉位置;按 3 秒上限这一个还排得上")
	}
	if _, ok := g.reserve("a.example", time.Time{}); ok {
		t.Fatal("要等 4 秒,超过 3 秒上限,不该预订")
	}
	// 另一个主机互不影响。
	if wait, ok := g.reserve("b.example", time.Time{}); !ok || wait != 0 {
		t.Fatalf("别的主机该直接放行: wait=%v ok=%v", wait, ok)
	}
	// 时间过去,桶补回来,但不超过 burst。
	c.add(time.Hour)
	for i := 0; i < 2; i++ {
		if wait, ok := g.reserve("a.example", time.Time{}); !ok || wait != 0 {
			t.Fatalf("补满后第 %d 个该直接放行: wait=%v ok=%v", i+1, wait, ok)
		}
	}
	if wait, _ := g.reserve("a.example", time.Time{}); wait == 0 {
		t.Fatal("补回来的不该超过 burst")
	}
}

// 排队期间 ctx 取消:返回 ctx 的错误并退还令牌。
func TestHostGuardAcquireReleasesOnCancel(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 1, burst: 1})
	g.now = time.Now
	if err := g.acquire(context.Background(), "a.example"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := g.acquire(ctx, "a.example"); !errors.Is(err, context.Canceled) {
		t.Fatalf("取消了该返回 Canceled: %v", err)
	}
	g.mu.Lock()
	tokens := g.buckets["a.example"].tokens
	g.mu.Unlock()
	if tokens < -0.01 {
		t.Fatalf("取消的那个令牌该退还,桶里现在 %.2f", tokens)
	}
}

// 429 只封那一个端点,同主机别的端点照发;正常响应当场解除;歌词源主机和上送请求不记。
func TestHostGuardEndpointWindow(t *testing.T) {
	g, c := newTestGuard(hostRate{perSec: 100, burst: 100})
	ctx := context.Background()
	search := mustReq(t, ctx, http.MethodGet, "https://itunes.apple.com/search?term=x")
	lookup := mustReq(t, ctx, http.MethodGet, "https://itunes.apple.com/lookup?id=1")

	g.observe(search, http.StatusTooManyRequests, "30")
	if err := g.admit(search); !errors.Is(err, errHostGuarded) {
		t.Fatalf("429 窗口内该拦下: %v", err)
	}
	if err := g.admit(lookup); err != nil {
		t.Fatalf("同主机别的端点不该被连累: %v", err)
	}
	c.add(31 * time.Second)
	if err := g.admit(search); err != nil {
		t.Fatalf("窗口过了该放行: %v", err)
	}

	g.observe(search, http.StatusTooManyRequests, "")
	g.observe(search, http.StatusOK, "")
	if err := g.admit(search); err != nil {
		t.Fatalf("拿到正常响应该当场解除: %v", err)
	}

	// 没给 Retry-After 用默认 1 分钟,离谱的值封顶 5 分钟。
	g.observe(search, http.StatusTooManyRequests, "")
	c.add(59 * time.Second)
	if err := g.admit(search); !errors.Is(err, errHostGuarded) {
		t.Fatal("默认窗口是 1 分钟")
	}
	c.add(2 * time.Second)
	g.observe(search, http.StatusTooManyRequests, "86400")
	c.add(301 * time.Second)
	if err := g.admit(search); err != nil {
		t.Fatalf("窗口封顶 5 分钟: %v", err)
	}

	// 歌词源主机的 429 归 sourcebreaker 管,这里不记。
	qq := mustReq(t, ctx, http.MethodGet, "https://c.y.qq.com/soso/x")
	g.observe(qq, http.StatusTooManyRequests, "60")
	g.mu.Lock()
	n := len(g.blocked)
	g.mu.Unlock()
	if n != 0 {
		t.Fatalf("歌词源主机不该进端点窗口: %v", g.blocked)
	}

	// 上送类请求不受闸管。
	g.observe(search, http.StatusTooManyRequests, "60")
	post := mustReq(t, ctx, http.MethodPost, "https://itunes.apple.com/search")
	if err := g.admit(post); err != nil {
		t.Fatalf("POST 不该被拦: %v", err)
	}
}

// 响应体里认出的限流(Last.fm 200 + error 29)同样进窗口。
func TestReportEndpointRateLimited(t *testing.T) {
	saved := hostGuardShared
	c := &guardClock{t: time.Unix(1_000_000, 0)}
	hostGuardShared = newHostGuard(c.now)
	t.Cleanup(func() { hostGuardShared = saved })

	u, _ := url.Parse("https://ws.audioscrobbler.com/2.0/?method=track.getInfo")
	reportEndpointRateLimited(u, "")
	req := mustReq(t, context.Background(), http.MethodGet, u.String())
	if err := hostGuardShared.admit(req); !errors.Is(err, errHostGuarded) {
		t.Fatalf("报了限流该拦下: %v", err)
	}
	other := mustReq(t, context.Background(), http.MethodGet, "https://ws.audioscrobbler.com/2.0/?method=user.getRecentTracks")
	if err := hostGuardShared.admit(other); !errors.Is(err, errHostGuarded) {
		t.Fatal("Last.fm 所有读接口是同一个端点,一起停")
	}
	scrobble := mustReq(t, context.Background(), http.MethodPost, "https://ws.audioscrobbler.com/2.0/")
	if err := hostGuardShared.admit(scrobble); err != nil {
		t.Fatalf("scrobble(POST)不受影响: %v", err)
	}
}

// 歌词源冷却:一轮歌词搜索之外拦下;一轮之内交给 planRound,这里不拦。
func TestHostGuardLyricSourceCooling(t *testing.T) {
	savedBreaker := lyricSourceBreakerShared
	c := &guardClock{t: time.Unix(1_000_000, 0)}
	lyricSourceBreakerShared = newLyricSourceBreaker(c.now)
	t.Cleanup(func() { lyricSourceBreakerShared = savedBreaker })
	boom := errors.New("connection refused")
	lyricSourceBreakerShared.observe("c.y.qq.com", boom, 0, "")
	lyricSourceBreakerShared.observe("c.y.qq.com", boom, 0, "")
	if _, cooling := lyricSourceBreakerShared.coolingDown("qq"); !cooling {
		t.Fatal("前提:qq 该在冷却中")
	}

	g, _ := newTestGuard(hostRate{perSec: 100, burst: 100})
	cover := mustReq(t, context.Background(), http.MethodGet, "https://y.qq.com/music/photo_new/x.jpg")
	if err := g.admit(cover); !errors.Is(err, errHostGuarded) {
		t.Fatalf("一轮之外访问冷却中的歌词源主机该拦下: %v", err)
	}
	roundCtx, _ := withLyricSourceRound(context.Background())
	inRound := mustReq(t, roundCtx, http.MethodGet, "https://c.y.qq.com/soso/x")
	if err := g.admit(inRound); err != nil {
		t.Fatalf("一轮之内不越过 planRound: %v", err)
	}
	other := mustReq(t, context.Background(), http.MethodGet, "https://music.163.com/api/x")
	if err := g.admit(other); err != nil {
		t.Fatalf("没在冷却的源照发: %v", err)
	}
}

// 一轮歌词搜索里被限速拦下的源记成跳过,跟熔断跳过同一套后续。
func TestHostGuardMarksLyricSourceSkippedWhenQueueFull(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 0.01, burst: 1})
	g.maxWait = time.Second
	roundCtx, round := withLyricSourceRound(context.Background())
	first := mustReq(t, roundCtx, http.MethodGet, "https://lrclib.net/api/get")
	if err := g.admit(first); err != nil {
		t.Fatal(err)
	}
	second := mustReq(t, roundCtx, http.MethodGet, "https://lrclib.net/api/search")
	if err := g.admit(second); !errors.Is(err, errHostGuarded) {
		t.Fatalf("排不上该拦下: %v", err)
	}
	if got := round.skippedSources(); len(got) != 1 || got[0] != "lrclib" {
		t.Fatalf("该记 lrclib 被跳过: %v", got)
	}
}

// 回环地址不经过闸,单测的 httptest 服务器不受限速影响。
func TestHostGuardSkipsLoopback(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 0.01, burst: 1})
	g.maxWait = 0
	for _, raw := range []string{"http://127.0.0.1:8080/x", "http://localhost/x", "http://[::1]:9/x"} {
		for i := 0; i < 3; i++ {
			if err := g.admit(mustReq(t, context.Background(), http.MethodGet, raw)); err != nil {
				t.Fatalf("%s 第 %d 次不该被拦: %v", raw, i+1, err)
			}
		}
	}
}

// 拦下的请求根本不到传输层,也不计入网络尝试次数(不然会被 roundLooksNetworkDown 读成断网)。
func TestDoHTTPTrackedGuardedRequestNeverSent(t *testing.T) {
	saved := hostGuardShared
	c := &guardClock{t: time.Unix(1_000_000, 0)}
	hostGuardShared = newHostGuard(c.now)
	t.Cleanup(func() { hostGuardShared = saved })

	var sent int32
	cli := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		atomic.AddInt32(&sent, 1)
		return &http.Response{StatusCode: http.StatusTooManyRequests, Header: http.Header{"Retry-After": {"60"}},
			Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}
	req := mustReq(t, context.Background(), http.MethodGet, "https://api.example.org/v1/thing")
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	stat := beginNetworkRound()
	_, err = doHTTPTracked(cli, mustReq(t, context.Background(), http.MethodGet, "https://api.example.org/v1/thing"))
	if !errors.Is(err, errHostGuarded) {
		t.Fatalf("429 窗口内该在本地拦下: %v", err)
	}
	if n := atomic.LoadInt32(&sent); n != 1 {
		t.Fatalf("拦下的请求不该到传输层,实际发了 %d 次", n)
	}
	if attempts, _ := stat(); attempts != 0 {
		t.Fatalf("拦下的请求不该计入网络尝试: %d", attempts)
	}
}

// 限速参数表:iTunes 每分钟 40 次(实测过线后失败率陡升)、Last.fm 每秒 1 次、其余默认。
func TestHostRateFor(t *testing.T) {
	if got := hostRateFor("itunes.apple.com"); got.perSec*60 != 40 {
		t.Errorf("iTunes 该是每分钟 40 次: %+v", got)
	}
	if got := hostRateFor("ws.audioscrobbler.com"); got.perSec != 1 {
		t.Errorf("Last.fm 该是每秒 1 次: %+v", got)
	}
	if got := hostRateFor("c.y.qq.com"); got != hostRateDefault {
		t.Errorf("其余主机用默认档: %+v", got)
	}
}

// 接口熔断:连续 5 次 5xx 跳闸,窗口内一轮歌词搜索之内也拦、但不记跳过;到期后再失败升一档;
// 拿到一次非 5xx 全部清零;同主机别的端点不受影响。
func TestHostGuardEndpointCircuit(t *testing.T) {
	g, c := newTestGuard(hostRate{perSec: 100, burst: 100})
	roundCtx, round := withLyricSourceRound(context.Background())
	dead := mustReq(t, roundCtx, http.MethodGet, "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=x")
	alive := mustReq(t, roundCtx, http.MethodGet, "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=x")

	for i := 0; i < endpointTripAfter-1; i++ {
		g.observe(dead, http.StatusInternalServerError, "")
	}
	if err := g.admit(dead); err != nil {
		t.Fatalf("没到 %d 次不该跳闸: %v", endpointTripAfter, err)
	}
	g.observe(dead, http.StatusInternalServerError, "")
	if err := g.admit(dead); !errors.Is(err, errHostGuarded) {
		t.Fatalf("连续 %d 次 5xx 该跳闸: %v", endpointTripAfter, err)
	}
	if got := round.skippedSources(); len(got) != 0 {
		t.Fatalf("接口熔断不该把整个源记成跳过: %v", got)
	}
	if err := g.admit(alive); err != nil {
		t.Fatalf("同源别的端点不受影响: %v", err)
	}

	c.add(endpointCooldownSchedule[0] + time.Second)
	if err := g.admit(dead); err != nil {
		t.Fatalf("到期该放一个请求试探: %v", err)
	}
	g.observe(dead, http.StatusInternalServerError, "")
	c.add(endpointCooldownSchedule[0] + time.Second)
	if err := g.admit(dead); !errors.Is(err, errHostGuarded) {
		t.Fatal("试探再失败该直接升一档(5 分钟),1 分钟后仍在停用")
	}
	c.add(endpointCooldownSchedule[1])
	g.observe(dead, http.StatusOK, "")
	if err := g.admit(dead); err != nil {
		t.Fatalf("拿到正常响应该清零: %v", err)
	}
	for i := 0; i < endpointTripAfter-1; i++ {
		g.observe(dead, http.StatusInternalServerError, "")
	}
	if err := g.admit(dead); err != nil {
		t.Fatal("清零后要重新攒满次数才跳闸")
	}

	// 中间夹一次成功就不算连续。
	g2, _ := newTestGuard(hostRate{perSec: 100, burst: 100})
	for i := 0; i < 10; i++ {
		status := http.StatusBadGateway
		if i%4 == 3 {
			status = http.StatusOK
		}
		g2.observe(dead, status, "")
	}
	if err := g2.admit(dead); err != nil {
		t.Fatalf("不连续的失败不该跳闸: %v", err)
	}
}

// 停用时长按档升、封顶最后一档。
func TestHostGuardEndpointCircuitSchedule(t *testing.T) {
	g, c := newTestGuard(hostRate{perSec: 100, burst: 100})
	key := "api.example.org/v1/x"
	for i := 0; i < endpointTripAfter; i++ {
		g.noteEndpointFailure(key)
	}
	for trip := 1; trip <= len(endpointCooldownSchedule)+2; trip++ {
		idx := trip - 1
		if idx >= len(endpointCooldownSchedule) {
			idx = len(endpointCooldownSchedule) - 1
		}
		until, open := g.endpointOpenUntil(key)
		if !open || until.Sub(c.t) != endpointCooldownSchedule[idx] {
			t.Fatalf("第 %d 次跳闸该停 %v,实际 open=%v 剩 %v", trip, endpointCooldownSchedule[idx], open, until.Sub(c.t))
		}
		c.add(endpointCooldownSchedule[idx] + time.Second)
		g.noteEndpointFailure(key)
	}
}

// 响应体里认出的拒绝按失败计。
func TestReportEndpointRejectedCounts(t *testing.T) {
	saved := hostGuardShared
	c := &guardClock{t: time.Unix(1_000_000, 0)}
	hostGuardShared = newHostGuard(c.now)
	t.Cleanup(func() { hostGuardShared = saved })
	u, _ := url.Parse("https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do?text=x")
	for i := 0; i < endpointTripAfter; i++ {
		reportEndpointRejected(u)
	}
	if _, open := hostGuardShared.endpointOpenUntil(guardEndpointKey(u)); !open {
		t.Fatal("连续报 5 次拒绝该跳闸")
	}
}

func TestKugouSearchRejected(t *testing.T) {
	one, zero, two := 1, 0, 2
	cases := []struct {
		status, errcode *int
		want            bool
	}{
		{&one, &zero, false},
		{nil, nil, false},
		{&zero, &zero, true},
		{&one, &two, true},
		{nil, &two, true},
	}
	for _, c := range cases {
		if got := kugouSearchRejected(c.status, c.errcode); got != c.want {
			t.Errorf("status=%v errcode=%v: got %v want %v", c.status, c.errcode, got, c.want)
		}
	}
}

// 端到端:QQ 主搜索的首选主机一直回 5xx 时,每次都退到下一个主机拿到结果;首选那个 5 次之后
// 不再打(真实主机名经改写的传输层指到本地,按 Host 头区分)。
func TestQQClientSearchFallsBackAndStopsHittingDeadHost(t *testing.T) {
	savedGuard, savedBreaker, savedTransport := hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport
	hostGuardShared = newHostGuard(time.Now)
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() {
		hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport = savedGuard, savedBreaker, savedTransport
	})
	var deadHits, aliveHits int32
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host == "shc.y.qq.com" {
			atomic.AddInt32(&deadHits, 1)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		atomic.AddInt32(&aliveHits, 1)
		_, _ = io.WriteString(w, `{"code":0,"data":{"song":{"list":[{"mid":"m1","title":"晴天","singer":[{"name":"周杰伦"}]}]}}}`)
	}))
	t.Cleanup(srv.Close)
	target := srv.Listener.Addr().String()
	lyricSourceTransport = &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, target)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	// 在一轮歌词搜索之内跑:源级冷却那道在轮内不管(交给 planRound),只剩接口熔断。
	roundCtx, _ := withLyricSourceRound(context.Background())
	calls := endpointTripAfter + 3
	for i := 0; i < calls; i++ {
		items, err := qqClientSearch(roundCtx, "晴天")
		if err != nil || len(items) != 1 {
			t.Fatalf("第 %d 次该从备用主机拿到结果: items=%v err=%v", i+1, items, err)
		}
	}
	if n := atomic.LoadInt32(&deadHits); n != endpointTripAfter {
		t.Fatalf("挂掉的主机跳闸后不该再打:实际打了 %d 次,应为 %d", n, endpointTripAfter)
	}
	if n := atomic.LoadInt32(&aliveHits); n != int32(calls) {
		t.Fatalf("每次都该落到备用主机:实际 %d 次,应为 %d", n, calls)
	}
}

// 后台请求取完要给前台留 reserve 个;取不到时不预支,前台照样能取,不会排到后台后面。
func TestHostGuardBackgroundLeavesReserveForForeground(t *testing.T) {
	g, c := newTestGuard(hostRate{perSec: 1, burst: 5, reserve: 2})
	for i := 0; i < 3; i++ {
		if _, ok := g.tryTakeBackground("a.example"); !ok {
			t.Fatalf("第 %d 个后台请求桶里够,该取到", i+1)
		}
	}
	wait, ok := g.tryTakeBackground("a.example")
	if ok {
		t.Fatal("桶里只剩 2 个(= reserve),后台不该再取")
	}
	if wait != time.Second {
		t.Fatalf("要等桶涨回 reserve+1,该等 1 秒: %v", wait)
	}
	for i := 0; i < 2; i++ {
		if w, ok := g.reserve("a.example", time.Time{}); !ok || w != 0 {
			t.Fatalf("留给前台的第 %d 个该直接放行: wait=%v ok=%v", i+1, w, ok)
		}
	}
	// 前台透支之后,后台要等桶涨回 reserve+1,前台自己的队列不受后台影响。
	if w, _ := g.reserve("a.example", time.Time{}); w != time.Second {
		t.Fatalf("前台排队只跟前台自己比: %v", w)
	}
	if wait, _ := g.tryTakeBackground("a.example"); wait != 4*time.Second {
		t.Fatalf("桶在 -1,后台要等涨回 3,该等 4 秒: %v", wait)
	}
	c.add(time.Hour)
	if _, ok := g.tryTakeBackground("a.example"); !ok {
		t.Fatal("补满后后台照常取")
	}
}

// 后台排不上(超过等待上限)就不发;标记只由 ctx 带。
func TestHostGuardBackgroundAcquire(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 0.01, burst: 2, reserve: 1})
	g.now = time.Now
	g.backgroundMaxWait = 50 * time.Millisecond
	bg := withBackgroundOutbound(context.Background())
	if !isBackgroundOutbound(bg) || isBackgroundOutbound(context.Background()) {
		t.Fatal("后台标记只该在带了它的 ctx 上")
	}
	if err := g.acquire(bg, "a.example"); err != nil {
		t.Fatalf("桶里 2 个、留 1 个,后台该取到一个: %v", err)
	}
	if err := g.acquire(bg, "a.example"); !errors.Is(err, errHostGuarded) {
		t.Fatalf("只剩 reserve 了,后台排不上该拦下: %v", err)
	}
	if err := g.acquire(context.Background(), "a.example"); err != nil {
		t.Fatalf("前台该拿到留给它的那个: %v", err)
	}
}

// 批量路径必须带后台标记:漏标的话,补空 / 全量扫库 / 预取的请求会跟正在播的那首抢同一个队列。
// 行为上测不到(要跑整轮解析),这里按源码钉住每个批量入口。
func TestBatchPathsMarkBackgroundOutbound(t *testing.T) {
	want := map[string]string{
		"lyricsfillsweep.go": "retryLyricsUpgrade(withBackgroundOutbound(",
		"lyricsfullscan.go":  "rescoreLyrics(withBackgroundOutbound(",
		"albumprefetch.go":   "resolveEnrichAsync(withBackgroundOutbound(",
		"upcoming.go":        "resolveEnrichAsync(withBackgroundOutbound(",
	}
	for file, needle := range want {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("读 %s: %v", file, err)
		}
		if !strings.Contains(string(src), needle) {
			t.Errorf("%s 的批量入口没带后台标记(找不到 %q)", file, needle)
		}
		for _, line := range strings.Split(string(src), "\n") {
			trim := strings.TrimSpace(line)
			if strings.HasPrefix(trim, "//") {
				continue
			}
			for _, fn := range []string{"retryLyricsUpgrade(context.", "rescoreLyrics(context.", "resolveEnrichAsync(context."} {
				if strings.Contains(trim, fn) {
					t.Errorf("%s 里有批量调用没带后台标记: %s", file, trim)
				}
			}
		}
	}
}

// 熔断打开期间陆续回来的失败(跳闸前就发出去的请求)不升档,到期后的试探失败才升一档。
func TestHostGuardEndpointCircuitIgnoresFailuresWhileOpen(t *testing.T) {
	g, c := newTestGuard(hostRate{perSec: 100, burst: 100})
	key := "api.example.org/v1/x"
	for i := 0; i < endpointTripAfter; i++ {
		g.noteEndpointFailure(key)
	}
	for i := 0; i < 3; i++ {
		g.noteEndpointFailure(key)
	}
	until, _ := g.endpointOpenUntil(key)
	if got := until.Sub(c.t); got != endpointCooldownSchedule[0] {
		t.Fatalf("打开期间的失败不该升档: 剩 %v,应为 %v", got, endpointCooldownSchedule[0])
	}
	c.add(endpointCooldownSchedule[0] + time.Second)
	g.noteEndpointFailure(key)
	until, _ = g.endpointOpenUntil(key)
	if got := until.Sub(c.t); got != endpointCooldownSchedule[1] {
		t.Fatalf("试探失败该升到第二档: 剩 %v,应为 %v", got, endpointCooldownSchedule[1])
	}
}

// 端到端:QQ 主搜索回 200 但 code 非 0(服务端拒绝)也按失败计,5 次之后不再发;code 0 的查无不算。
func TestQQClientSearchCodeRejectionTripsEndpoint(t *testing.T) {
	savedGuard, savedBreaker, savedTransport := hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport
	hostGuardShared = newHostGuard(time.Now)
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	t.Cleanup(func() {
		hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport = savedGuard, savedBreaker, savedTransport
	})
	var hits int32
	body := `{"code":0,"data":{"song":{"list":[]}}}`
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 被拒之后还会退到客户端网关搜索(POST musicu.fcg),这里只数网页搜索接口本身。
		if r.URL.Path == "/soso/fcgi-bin/client_search_cp" {
			atomic.AddInt32(&hits, 1)
		}
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	target := srv.Listener.Addr().String()
	lyricSourceTransport = &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, target)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	savedBases := qqClientSearchBases
	qqClientSearchBases = []string{"https://shc.y.qq.com/soso/fcgi-bin/client_search_cp"}
	t.Cleanup(func() { qqClientSearchBases = savedBases })
	roundCtx, _ := withLyricSourceRound(context.Background())
	for i := 0; i < endpointTripAfter+2; i++ {
		if _, err := qqClientSearch(roundCtx, "查无"); err != nil {
			t.Fatalf("code 0 的查无不是失败: %v", err)
		}
	}
	reject := func(n int) {
		body = `{"code":2001,"data":{}}`
		for i := 0; i < n; i++ {
			_, _ = qqClientSearch(roundCtx, "晴天")
		}
	}
	// 拒绝 4 次、正常 1 次、再拒绝 4 次:中间那次正常响应体把计数清零,不该跳闸。
	reject(endpointTripAfter - 1)
	body = `{"code":0,"data":{"song":{"list":[]}}}`
	_, _ = qqClientSearch(roundCtx, "查无")
	reject(endpointTripAfter - 1)
	sent := int32(endpointTripAfter + 2 + 2*(endpointTripAfter-1) + 1)
	if n := atomic.LoadInt32(&hits); n != sent {
		t.Fatalf("不连续的拒绝不该跳闸:实际打了 %d 次,应为 %d", n, sent)
	}
	reject(4)
	if n := atomic.LoadInt32(&hits); n != sent+1 {
		t.Fatalf("第 %d 次连续拒绝跳闸后该停发:实际共打 %d 次,应为 %d", endpointTripAfter, n, sent+1)
	}
}

// 响应体拒绝的计数不被同一响应的 200 清掉,只被调用方确认的正常响应清掉;5xx 计数反过来。
func TestHostGuardRejectsAndFailsCountedSeparately(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 100, burst: 100})
	key := "c.y.qq.com/soso/fcgi-bin/client_search_cp"
	for i := 0; i < endpointTripAfter-1; i++ {
		g.noteEndpointGood(key, false) // 出站闸先看到 200
		g.noteEndpointBad(key, true)   // 调用方随后认出拒绝码
	}
	g.noteEndpointGood(key, true) // 一次正常响应体
	for i := 0; i < endpointTripAfter-1; i++ {
		g.noteEndpointGood(key, false)
		g.noteEndpointBad(key, true)
	}
	if _, open := g.endpointOpenUntil(key); open {
		t.Fatal("中间夹了一次正常响应体,拒绝不算连续")
	}
	g.noteEndpointBad(key, true)
	if _, open := g.endpointOpenUntil(key); !open {
		t.Fatal("200 包着的拒绝码连续 5 次该跳闸")
	}

	g2, _ := newTestGuard(hostRate{perSec: 100, burst: 100})
	for i := 0; i < endpointTripAfter-1; i++ {
		g2.noteEndpointBad(key, false)
		g2.noteEndpointGood(key, true) // 响应体确认不清 5xx 计数
	}
	g2.noteEndpointBad(key, false)
	if _, open := g2.endpointOpenUntil(key); !open {
		t.Fatal("5xx 计数不该被响应体确认清掉")
	}
}

// QQ 客户端网关是用 POST 发的只读查询,也归出站闸管;别的 POST(上送)不管。
func TestHostGuardCoversQQMusicuPost(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 100, burst: 100})
	musicu := mustReq(t, context.Background(), http.MethodPost, "https://u.y.qq.com/cgi-bin/musicu.fcg")
	for i := 0; i < endpointTripAfter; i++ {
		g.observe(musicu, http.StatusBadGateway, "")
	}
	if err := g.admit(musicu); !errors.Is(err, errHostGuarded) {
		t.Fatalf("网关 POST 连续 5xx 该跳闸: %v", err)
	}
	other := mustReq(t, context.Background(), http.MethodPost, "https://u6.y.qq.com/cgi-bin/musicu.fcg")
	if err := g.admit(other); err != nil {
		t.Fatalf("备用网关主机不受影响: %v", err)
	}
	scrobble := mustReq(t, context.Background(), http.MethodPost, "https://ws.audioscrobbler.com/2.0/")
	for i := 0; i < endpointTripAfter; i++ {
		g.observe(scrobble, http.StatusBadGateway, "")
	}
	if err := g.admit(scrobble); err != nil {
		t.Fatalf("上送类 POST 不归出站闸管: %v", err)
	}
}
