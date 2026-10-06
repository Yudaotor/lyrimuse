package main

import (
	"context"
	"encoding/json"
	"errors"
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

// 网络基础设施、配置热重读与日志的加固:调用方自己取消不算「直连不通 / 代理坏了」、成功之后撤掉失败原因、
// 源自己的超时共享给等着的人、DoH 的负缓存 / 单飞 / ctx、429 冷却只延不缩、热重读基线取读之前、
// 日志被删后重开、抢到锁之前不轮转、脱敏不误伤普通参数、清单里不认识的源名、系统语言沿用上一次。

// 请求自己的 ctx 已经取消:直连失败不试代理,也不报「直连被打掉」。
func TestProxyFallbackCallerCancelIsNotBlocked(t *testing.T) {
	newFallbackTestEnv(t)
	direct := &stubRoundTripper{err: context.Canceled}
	viaProxy := &stubRoundTripper{body: "ok"}
	blocked := 0
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy, onBlocked: func() { blocked++ }}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := tr.RoundTrip(newTestRequest(t).WithContext(ctx)); err == nil {
		t.Fatal("取消了的请求应当返回错误")
	}
	if blocked != 0 || viaProxy.calls != 0 {
		t.Fatalf("调用方取消不该试代理、不该报 blocked: blocked=%d proxy=%d", blocked, viaProxy.calls)
	}
}

// 已经粘在代理上时调用方取消:不清粘性、不清磁盘提示,也不拿死 ctx 再试直连。
func TestProxyFallbackStickyKeepsStickyOnCallerCancel(t *testing.T) {
	newFallbackTestEnv(t)
	direct := &stubRoundTripper{err: errors.New("i/o timeout")}
	viaProxy := &stubRoundTripper{body: "ok"}
	blocked := 0
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy, onBlocked: func() { blocked++ }}
	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	viaProxy.err = context.Canceled
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := tr.RoundTrip(newTestRequest(t).WithContext(ctx)); err == nil {
		t.Fatal("取消了的请求应当返回错误")
	}
	if direct.calls != 1 || blocked != 0 {
		t.Fatalf("不该拿死 ctx 再试直连 / 报 blocked: direct=%d blocked=%d", direct.calls, blocked)
	}
	if !loadProxyFallbackHint("apic-appmobile.musixmatch.com") {
		t.Fatal("调用方取消不该清掉磁盘提示")
	}
	tr.mu.Lock()
	sticky := time.Now().Before(tr.stickyUntil)
	tr.mu.Unlock()
	if !sticky {
		t.Fatal("调用方取消不该清掉内存里的粘性")
	}
}

// 粘性是上一个进程设的(只在磁盘提示里,已过期):这个进程直连成功时也要把留着的连续失败次数清掉。
func TestProxyFallbackDirectSuccessClearsLeftoverStreak(t *testing.T) {
	newFallbackTestEnv(t)
	host := "apic-appmobile.musixmatch.com"
	saveProxyFallbackHint(host, true)
	saveProxyFallbackHint(host, true)
	f := readProxyFallbackHint()
	f.Until[host] = time.Now().Add(-time.Minute).Unix()
	raw, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(proxyFallbackHintPath(), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	tr := &proxyFallbackTransport{direct: &stubRoundTripper{body: "ok"}, viaProxy: &stubRoundTripper{body: "ok"}}
	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := readProxyFallbackHint().Streak[host]; got != 0 {
		t.Fatalf("直连成功应当清掉上一个进程留下的连续次数,还剩 %d", got)
	}
}

// Musixmatch 答上来了就撤掉早先的失败原因:它在常驻进程里别无清除之处,留着会让别名重查一直跳过这个源。
func TestMusixmatchSuccessClearsFailureReason(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
	musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchDirectBlocked)
	if _, err := musixmatchDo(context.Background(), "track.search", neturl.Values{}); err != nil {
		t.Fatal(err)
	}
	if got := musixmatchLastFailureReasonNow(); got != "" {
		t.Fatalf("答上来之后应当撤掉失败原因,还剩 %q", got)
	}
}

// Deezer:调用方取消的不算「换不到票」;换到了撤掉早先的原因。
func TestDeezerAuthFailureReason(t *testing.T) {
	status := http.StatusInternalServerError
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		w.Write([]byte(`{"jwt":"abc.def"}`))
	}))
	defer srv.Close()
	saved := deezerAuthAPI
	deezerAuthAPI = srv.URL + "/login"
	t.Cleanup(func() { deezerAuthAPI = saved; deezerSetLastFailureReason("") })

	deezerSetLastFailureReason("")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := deezerFetchJWT(ctx); got != "" {
		t.Fatalf("取消了的请求不该拿到票: %q", got)
	}
	if got := deezerLastFailureReasonNow(); got != "" {
		t.Fatalf("调用方取消不该记成换不到票: %q", got)
	}
	if got := deezerFetchJWT(context.Background()); got != "" {
		t.Fatalf("500 不该拿到票: %q", got)
	}
	if got := deezerLastFailureReasonNow(); got != lyricFailureReasonDeezerAuthFailed {
		t.Fatalf("服务端拒了要记原因: %q", got)
	}
	status = http.StatusOK
	if got := deezerFetchJWT(context.Background()); got != "abc.def" {
		t.Fatalf("应当换到票: %q", got)
	}
	if got := deezerLastFailureReasonNow(); got != "" {
		t.Fatalf("换到了应当撤掉原因: %q", got)
	}
}

// YouTube Music:拿到 visitor id 就撤掉早先的地区限制结论。
func TestYTMusicVisitorFromHomeClearsRegionReason(t *testing.T) {
	t.Cleanup(func() { ytmusicSetLastFailureReason("") })
	if got := ytmusicVisitorFromHome("<html>YouTube Music is not available in your area</html>"); got != "" {
		t.Fatalf("地区提示页不该有 visitor id: %q", got)
	}
	if got := ytmusicLastFailureReasonNow(); got != lyricFailureReasonLyricFindRegionRestricted {
		t.Fatalf("应当记下地区限制: %q", got)
	}
	if got := ytmusicVisitorFromHome(`<script>ytcfg.set({"VISITOR_DATA":"abc123=="});</script>`); got != "abc123==" {
		t.Fatalf("应当取到 visitor id: %q", got)
	}
	if got := ytmusicLastFailureReasonNow(); got != "" {
		t.Fatalf("取到之后应当撤掉地区限制: %q", got)
	}
}

// 源自己的超时(http.Client.Timeout,报的也是 DeadlineExceeded)是这个源此刻的真实状态:共享给等着的人,
// 不让他们各自再发一遍、各等一整个超时。
func TestHTTPCoalesceSharesSourceTimeout(t *testing.T) {
	srv, hits := withCoalesceTestServer(t, 2*time.Second)
	cli := &http.Client{Timeout: 400 * time.Millisecond}
	get := func() error {
		req, _ := http.NewRequest(http.MethodGet, srv.URL+"/lyric?id=slow", nil)
		resp, err := doHTTPTracked(cli, req)
		if err == nil {
			resp.Body.Close()
		}
		return err
	}
	leaderErr := make(chan error, 1)
	go func() { leaderErr <- get() }()
	waitCoalesceHits(t, hits, 1)
	var wg sync.WaitGroup
	var followerErrs int32
	start := time.Now()
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if get() != nil {
				atomic.AddInt32(&followerErrs, 1)
			}
		}()
	}
	wg.Wait()
	if err := <-leaderErr; err == nil {
		t.Fatal("发出去的那个应当超时")
	}
	if followerErrs != 3 {
		t.Fatalf("等着的几个应当拿到同一个超时错误,失败了 %d 个", followerErrs)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("源超时不该让等着的人各自重发: 服务端收到 %d 次", n)
	}
	if elapsed := time.Since(start); elapsed > 1500*time.Millisecond {
		t.Fatalf("等着的人不该各自再等一整个超时: %v", elapsed)
	}
}

// 等到共享结果的那个也算这一轮「连上过这个源」。
func TestNoteCoalescedReachedMarksRound(t *testing.T) {
	ctx, round := withLyricSourceRound(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://music.163.com/api/x", nil)
	noteCoalescedReached(req, http.StatusServiceUnavailable)
	if round.reachedAny() {
		t.Fatal("5xx 不算连上")
	}
	noteCoalescedReached(req, http.StatusOK)
	if !round.reachedAny() {
		t.Fatal("共享到 200 应当算连上")
	}
}

// 调用方自己取消的请求不计入网络失败数,不然这一轮偏向误报「网络不通」。
func TestNetworkFailureCountIgnoresCanceled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	done := beginNetworkRound()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL, nil)
	if _, err := doHTTPTrackedOnce(http.DefaultClient, req); err == nil {
		t.Fatal("取消了的请求应当失败")
	}
	if _, failures := done(); failures != 0 {
		t.Fatalf("取消不该计成失败: %d", failures)
	}
}

// withDoHEndpoint 把 DoH 端点换成本地服务器,测试结束还原并清掉这些主机的缓存。
func withDoHEndpoint(t *testing.T, h http.HandlerFunc, hosts ...string) {
	t.Helper()
	srv := httptest.NewServer(h)
	saved := dohEndpoints
	dohEndpoints = []string{srv.URL + "/dns-query"}
	t.Cleanup(func() {
		// 等后台那次查询收尾,免得它在别的测试里写缓存。
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			dohMu.Lock()
			n := len(dohInflight)
			dohMu.Unlock()
			if n == 0 {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		srv.Close()
		dohEndpoints = saved
		dohMu.Lock()
		for _, h := range hosts {
			delete(dohCache, h)
		}
		dohMu.Unlock()
	})
}

// 查失败的空结果只记一会儿:合盖唤醒那几秒恰好失败,不能让接下来半小时都报「DNS 失败」。
func TestDoHNegativeResultCachedBriefly(t *testing.T) {
	withDoHEndpoint(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusInternalServerError) }, "neg.doh.test")
	if ips := dohLookup(context.Background(), "neg.doh.test"); len(ips) != 0 {
		t.Fatalf("端点失败不该有结果: %v", ips)
	}
	dohMu.Lock()
	e := dohCache["neg.doh.test"]
	dohMu.Unlock()
	if left := time.Until(e.expires); left <= 0 || left > 2*dohNegativeTTL {
		t.Fatalf("空结果应当只记 %s 左右,实际还剩 %s", dohNegativeTTL, left)
	}
}

// 同一个域名同时只查一次,后来的等它的结果。
func TestDoHLookupSingleFlight(t *testing.T) {
	var hits int32
	withDoHEndpoint(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		time.Sleep(150 * time.Millisecond)
		w.Write([]byte(`{"Answer":[{"type":1,"data":"1.2.3.4"}]}`))
	}, "one.doh.test")
	var wg sync.WaitGroup
	var bad int32
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ips := dohLookup(context.Background(), "one.doh.test"); len(ips) != 1 || ips[0] != "1.2.3.4" {
				atomic.AddInt32(&bad, 1)
			}
		}()
	}
	wg.Wait()
	if bad != 0 {
		t.Fatalf("%d 个调用方没拿到结果", bad)
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("同一个域名同时只该查一次,查了 %d 次", n)
	}
}

// 调用方的 ctx 先结束了就不再等(查询在后台照常完成、写进缓存)。
func TestDoHLookupHonorsCallerContext(t *testing.T) {
	withDoHEndpoint(t, func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		w.Write([]byte(`{"Answer":[{"type":1,"data":"5.6.7.8"}]}`))
	}, "slow.doh.test")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	if ips := dohLookup(ctx, "slow.doh.test"); ips != nil {
		t.Fatalf("ctx 到期应当返回 nil: %v", ips)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("不该等到查询结束: %v", elapsed)
	}
	if ips := dohLookup(context.Background(), "slow.doh.test"); len(ips) != 1 || ips[0] != "5.6.7.8" {
		t.Fatalf("后来的调用方等到同一次查询的结果: %v", ips)
	}
}

// 调用方不等了、但有一路拨号恰好在那一刻连上:那条连接要被关掉,不能等 GC。
func TestDohDialRaceClosesLateConnAfterCancel(t *testing.T) {
	logRef := &raceDialLog{closed: map[string]bool{}}
	var pipes []net.Conn
	var mu sync.Mutex
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		time.Sleep(80 * time.Millisecond) // 不看 ctx:模拟拨号在取消的同一刻完成
		a, b := net.Pipe()
		mu.Lock()
		pipes = append(pipes, a, b)
		mu.Unlock()
		return &fakeConn{Conn: a, addr: addr, logRef: logRef}, nil
	}
	defer func() {
		mu.Lock()
		for _, p := range pipes {
			_ = p.Close()
		}
		mu.Unlock()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if conn, err := dohDialRaceWith(ctx, dial, "tcp", []string{"10.0.0.9"}, "443"); conn != nil || err == nil {
		t.Fatalf("ctx 到期应当返回错误: conn=%v err=%v", conn, err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		logRef.mu.Lock()
		closed := logRef.closed["10.0.0.9:443"]
		logRef.mu.Unlock()
		if closed {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("取消之后才连上的那条没有被关掉")
}

// 429 的 Retry-After 只往后延:不能把一段更长的冷却缩短;同一轮并发的另一个请求答了 200 也不撤限流窗口。
// 5xx / 断网升上去的冷却照旧一次正常应答就撤。
func TestLyricSourceBreaker429Window(t *testing.T) {
	b, _ := newTestBreaker()
	b.observe("lrclib.net", nil, 429, "300")
	b.observe("lrclib.net", nil, 429, "30")
	if d, cooling := b.coolingDown("lrclib"); !cooling || d != 5*time.Minute {
		t.Fatalf("短的 Retry-After 不该缩短已有的冷却: cooling=%v d=%s", cooling, d)
	}
	b.observe("lrclib.net", nil, 200, "")
	if d, cooling := b.coolingDown("lrclib"); !cooling || d != 5*time.Minute {
		t.Fatalf("一次 200 不该撤掉限流窗口: cooling=%v d=%s", cooling, d)
	}
	b.observe("lrclib.net", nil, 404, "")
	if _, cooling := b.coolingDown("lrclib"); !cooling {
		t.Fatal("404 同样不撤限流窗口")
	}

	b2, _ := newTestBreaker()
	b2.observe("music.163.com", errProbeDial, 0, "")
	b2.observe("music.163.com", errProbeDial, 0, "")
	if _, cooling := b2.coolingDown("netease"); !cooling {
		t.Fatal("两次失败应当冷却")
	}
	b2.observe("music.163.com", nil, 200, "")
	if _, cooling := b2.coolingDown("netease"); cooling {
		t.Fatal("非限流的冷却照旧被一次正常应答撤掉")
	}
}

// 热重读的基线取读文件之前那一刻:读完到登记之间保存的配置(填 token、授权写进 session key)要能热重读进来。
func TestLiveConfigBaselineTakenBeforeRead(t *testing.T) {
	resetLiveConfigForTest(t)
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"listenbrainz_token":"old-token-aaaa"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	baseline, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	// 启动迁移期间 App 保存了新 token。
	writeConfigForTest(t, path, `{"listenbrainz_token":"new-token-bbbbbbbbbb"}`)
	setLiveConfigAt(path, cfg, baseline)
	configCheckedAt.Store(time.Now().Add(-2 * configReloadInterval).UnixNano())
	if got := liveConfig().Token; got != "new-token-bbbbbbbbbb" {
		t.Fatalf("登记之前就保存了的新配置应当热重读进来: %q", got)
	}
}

// 功能开关同理。
func TestFeaturesBaselineTakenBeforeRead(t *testing.T) {
	resetFeaturesForTest(t)
	path := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"smart"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	baseline, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	if err := os.WriteFile(path, []byte(`{"lyrics_source_mode":"priority"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Minute)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	setFeaturesPathAt(path, baseline)
	featuresCheckedAt.Store(time.Now().Add(-2 * featuresReloadInterval).UnixNano())
	if got := features().LyricsSourceMode; got != lyricsModePriority {
		t.Fatalf("登记之前就改了的开关应当热重读进来: %q", got)
	}
}

// 日志文件被外部删掉 / 换掉:在原路径重开接着写,不再写进那个看不见的文件。
func TestRotatingLogFileReopensWhenRemovedOrReplaced(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lyrimuse.log")
	r := openRotatingLogFile(path, 1<<20)
	if r == nil {
		t.Fatal("打不开")
	}
	defer func() { r.f.Close() }()
	if _, err := r.Write([]byte("first\n")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	r.checkedAt = time.Time{}
	if _, err := r.Write([]byte("after delete\n")); err != nil {
		t.Fatal(err)
	}
	cur, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("删掉之后应当在原路径重建: %v", err)
	}
	if !strings.Contains(string(cur), "after delete") || !strings.Contains(string(cur), "reopened") {
		t.Fatalf("重建的文件里应当有重开记录和新写的行: %q", cur)
	}
	// 换成了另一个文件(清理软件挪走再新建):同样跟过去。
	if err := os.Rename(path, path+".moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	r.checkedAt = time.Time{}
	if _, err := r.Write([]byte("after replace\n")); err != nil {
		t.Fatal(err)
	}
	cur, _ = os.ReadFile(path)
	if !strings.Contains(string(cur), "after replace") {
		t.Fatalf("换了文件之后应当写进新的那份: %q", cur)
	}
	// 没变的时候不动。
	r.checkedAt = time.Time{}
	before := r.f
	if _, err := r.Write([]byte("steady\n")); err != nil {
		t.Fatal(err)
	}
	if r.f != before {
		t.Fatal("文件没变时不该重开")
	}
}

// 轮转时路径上已经没有文件:没有可归档的,直接新开一份。
func TestArchiveAndReopenCreatesMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gone.log")
	f, ok := archiveAndReopen(path)
	if !ok || f == nil {
		t.Fatal("路径上没有文件时应当直接新开一份")
	}
	f.Close()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("应当建出来了: %v", err)
	}
}

// 抢到单实例锁之前不轮转:第二个实例不能一打开就把正在用的那份切去 .old。
func TestLogRotationHeldUntilReleased(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lyrimuse.log")
	if err := os.WriteFile(path, []byte(strings.Repeat("x", 100)), 0o644); err != nil {
		t.Fatal(err)
	}
	r := openRotatingLogFileHeld(path, 40, true)
	if r == nil {
		t.Fatal("打不开")
	}
	defer func() { r.f.Close() }()
	if _, err := r.Write([]byte("while held\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".old"); err == nil {
		t.Fatal("拿到锁之前不该轮转")
	}
	saved := logSink.file
	logSink.file = r
	t.Cleanup(func() { logSink.file = saved })
	releaseLogRotation()
	if _, err := os.Stat(path + ".old"); err != nil {
		t.Fatalf("放开之后超过上限应当当场轮转: %v", err)
	}
}

// 按参数名脱敏:词根要落在一段的末尾,keyword / author 不算;值里的反斜杠不吃。
func TestScrubSecretsParamNameBoundaries(t *testing.T) {
	resetSecretsForTest(t)
	in := `GET "https://x.test/s?keyword=晴天&author=someone&api_key=0123456789abcdef&x-api-key=k1k1k1k1&access_token=t0t0t0t0&token_type=bearer&sign=s1s1s1s1"`
	got := scrubSecrets(in)
	for _, keep := range []string{"keyword=晴天", "author=someone"} {
		if !strings.Contains(got, keep) {
			t.Errorf("普通参数不该被打掉,缺 %q: %s", keep, got)
		}
	}
	for _, leak := range []string{"0123456789abcdef", "k1k1k1k1", "t0t0t0t0", "bearer", "s1s1s1s1"} {
		if strings.Contains(got, leak) {
			t.Errorf("凭据类参数仍是明文 %q: %s", leak, got)
		}
	}
	line := `msg="request failed: Get \"https://x.test/?api_key=abc123456\": context canceled"`
	if got := scrubSecrets(line); got != `msg="request failed: Get \"https://x.test/?api_key=***\": context canceled"` {
		t.Fatalf("反斜杠转义要留着,引号结构不能坏: %s", got)
	}
}

// 清单里全是这个版本不认识的源名:跟 App 一样当作全开,不能等于把所有已知源都关了。
func TestResolveLyricsSourcesDropsUnknownNames(t *testing.T) {
	got := resolveLyricsSources([]string{"future-source", "another"})
	if len(got) != len(lyricSourceNames) {
		t.Fatalf("全是不认识的名字应当退成全开: %v", got)
	}
	got = resolveLyricsSources([]string{"netease", "future-source"})
	if len(got) != 1 || !got["netease"] || got["future-source"] {
		t.Fatalf("不认识的名字去掉、认识的照留: %v", got)
	}
}

// 设置里不认识的译文语言当作 auto(跟 App 显示的一致);认识的原样用。
func TestResolveLyricsTranslationLanguageUnknownIsAuto(t *testing.T) {
	saved := querySystemLanguageQuery
	savedLast := systemLanguageLast.Load()
	t.Cleanup(func() {
		querySystemLanguageQuery = saved
		systemLanguageLast.Store(savedLast)
	})
	querySystemLanguageQuery = func(context.Context) ([]byte, error) { return []byte("ja_JP"), nil }
	for in, want := range map[string]string{"fr": "fr", "zh": "zh", "auto": "ja", "": "ja", "xx": "ja", "zh-CN": "ja", "FR": "ja"} {
		if got := resolveLyricsTranslationLanguage(in, ""); got != want {
			t.Errorf("resolveLyricsTranslationLanguage(%q) = %q, want %q", in, got, want)
		}
	}
}

// Go 认的语言清单跟 App 的枚举逐项一致:以后加语言时两边都要改,只改一边这里变红。
func TestLyricsTranslationLanguageCodesMatchSwift(t *testing.T) {
	raw, err := os.ReadFile("../lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift")
	if err != nil {
		t.Fatalf("读不到 App 侧的枚举(路径变了就跟着改,别把这个测试删掉): %v", err)
	}
	src := string(raw)
	start := strings.Index(src, "enum MusixmatchTranslationLanguage")
	if start < 0 {
		t.Fatal("App 侧找不到 MusixmatchTranslationLanguage")
	}
	var swift []string
	for _, line := range strings.Split(src[start:], "\n")[1:] {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		rest, ok := strings.CutPrefix(line, "case ")
		if !ok || strings.ContainsAny(rest, ".:(") {
			break
		}
		for _, c := range strings.Split(rest, ",") {
			if c = strings.TrimSpace(c); c != "auto" {
				swift = append(swift, c)
			}
		}
	}
	if strings.Join(swift, ",") != strings.Join(lyricsTranslationLanguageCodes, ",") {
		t.Fatalf("两边的译文语言清单不一致:\n  App:       %v\n  引擎: %v", swift, lyricsTranslationLanguageCodes)
	}
}

// 系统语言查一次失败时沿用上一次查成功的值,不掉回兜底的 en(那会被当成「译文语言换了」,整库机翻清一遍)。
func TestSystemLanguageCodeKeepsLastGood(t *testing.T) {
	saved := querySystemLanguageQuery
	savedLast := systemLanguageLast.Load()
	t.Cleanup(func() {
		querySystemLanguageQuery = saved
		systemLanguageLast.Store(savedLast)
	})
	systemLanguageLast.Store(nil)
	querySystemLanguageQuery = func(context.Context) ([]byte, error) { return nil, errors.New("boom") }
	if got := systemLanguageCode(); got != "" {
		t.Fatalf("从没查成过时返回空串交给调用方兜底: %q", got)
	}
	querySystemLanguageQuery = func(context.Context) ([]byte, error) { return []byte("zh_Hans_CN\n"), nil }
	if got := systemLanguageCode(); got != "zh" {
		t.Fatalf("got %q", got)
	}
	querySystemLanguageQuery = func(context.Context) ([]byte, error) { return nil, errors.New("boom") }
	if got := systemLanguageCode(); got != "zh" {
		t.Fatalf("查询失败应当沿用上一次的 zh: %q", got)
	}
	if got := resolveLyricsTranslationLanguage("auto", ""); got != "zh" {
		t.Fatalf("auto 应当解析成上一次的系统语言: %q", got)
	}
}

// 译文语言是 auto 时用 App 写进 features.json 的 system_language,不自己查系统偏好;文件里没有这个键才查。
func TestTranslationLanguageFollowsAppSystemLanguage(t *testing.T) {
	saved := querySystemLanguageQuery
	savedLast := systemLanguageLast.Load()
	t.Cleanup(func() {
		querySystemLanguageQuery = saved
		systemLanguageLast.Store(savedLast)
	})
	queries := 0
	querySystemLanguageQuery = func(context.Context) ([]byte, error) { queries++; return []byte("ja_JP"), nil }
	for _, c := range []struct{ lang, sys, want string }{
		{"auto", "de", "de"}, {"", " KO\n", "ko"}, {"xx", "fr", "fr"}, {"es", "de", "es"},
	} {
		if got := resolveLyricsTranslationLanguage(c.lang, c.sys); got != c.want {
			t.Errorf("resolveLyricsTranslationLanguage(%q, %q) = %q, want %q", c.lang, c.sys, got, c.want)
		}
	}
	path := filepath.Join(t.TempDir(), "lyrimuse-features.json")
	if err := os.WriteFile(path, []byte(`{"lyrics_translation_language":"auto","system_language":"de"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := loadFeatureFlags(path).LyricsTranslationLanguage; got != "de" {
		t.Fatalf("features.json 里 App 写的 system_language 没用上: %q", got)
	}
	if queries != 0 {
		t.Fatalf("App 写了 system_language 还自己查了 %d 次系统偏好", queries)
	}
	if got := resolveLyricsTranslationLanguage("auto", ""); got != "ja" || queries != 1 {
		t.Fatalf("文件里没有 system_language 时自己查一次: got %q, 查了 %d 次", got, queries)
	}
}

// AppleLocale 的取法跟 App 的 SystemLanguage.appleLocaleLanguage 跑同一批样例。
func TestAppleLocaleLanguageMatchesApp(t *testing.T) {
	raw, err := os.ReadFile("../shared/testdata/system-language.json")
	if err != nil {
		t.Fatalf("读不到两侧共用的样例: %v", err)
	}
	var cases []struct {
		AppleLocale string `json:"apple_locale"`
		Want        string `json:"want"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil || len(cases) == 0 {
		t.Fatalf("样例解不开: %v", err)
	}
	for _, c := range cases {
		if got := appleLocaleLanguage(c.AppleLocale); got != c.Want {
			t.Errorf("appleLocaleLanguage(%q) = %q, want %q", c.AppleLocale, got, c.Want)
		}
	}
}
