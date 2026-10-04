package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ListenBrainz / Last.fm 账号同步这一侧的加固:令牌被拒、待重发队列、Last.fm 错误分档、编目匹配、
// iPhone 桥接、退出兜底、收听日志整份重写、周期状态落盘。

// ---- ListenBrainz ----

// 401 / 403 是「这把令牌现在不能用」,不是「这条内容不收」:报 errListenAuth(不带 errListenRejected),
// 同一把令牌冷却期间不再发请求,换了令牌立刻恢复。
func TestLBSubmitAuthRejectedHoldsUntilTokenChanges(t *testing.T) {
	resetLiveConfigForTest(t)
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Header.Get("Authorization") == "Token good" {
			w.Write([]byte(`{"status":"ok"}`))
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	c := &lbClient{root: srv.URL, token: "bad", hc: srv.Client()}
	meta := lbTrackMeta{ArtistName: "A", TrackName: "T", AdditionalInfo: map[string]any{}}

	err := c.submit(context.Background(), "single", 1790000000, meta)
	if !errors.Is(err, errListenAuth) || errors.Is(err, errListenRejected) {
		t.Fatalf("401 应报 errListenAuth、不算拒收,got %v", err)
	}
	if n := hits.Load(); n != 1 {
		t.Fatalf("401 不该重试,打了 %d 次", n)
	}
	err = c.submit(context.Background(), "single", 1790000001, meta)
	if !errors.Is(err, errListenAuth) || hits.Load() != 1 {
		t.Fatalf("同一把令牌冷却中不该再发请求:err=%v hits=%d", err, hits.Load())
	}
	c.mu.Lock()
	c.token = "good"
	c.mu.Unlock()
	if err := c.submit(context.Background(), "single", 1790000002, meta); err != nil || hits.Load() != 2 {
		t.Fatalf("换了令牌应立刻恢复:err=%v hits=%d", err, hits.Load())
	}
}

// 会话已结束的那条:令牌被拒进待重发队列(换好令牌还能补);内容被拒标成已处理、不进队列。
func TestApplySubmitOutcomeAuthVsRejected(t *testing.T) {
	withLBRetryFile(t)
	p := &poller{ctx: context.Background(), cfg: &config{}}
	mk := func(title string) (*playSession, snapshot) {
		meta := snapshot{Artist: "歌手", Title: title}
		return &playSession{key: title, meta: meta, submitting: true, ended: true, lastfmExcluded: true}, meta
	}
	auth, authMeta := mk("令牌被拒")
	rej, rejMeta := mk("内容被拒")
	p.applySubmitOutcome(submitOutcome{sess: auth, meta: authMeta, artistName: "歌手", startedAt: 100,
		lm: lbTrackMeta{ArtistName: "歌手", TrackName: "令牌被拒"}, err: fmt.Errorf("post single: %w", errListenAuth)})
	p.applySubmitOutcome(submitOutcome{sess: rej, meta: rejMeta, artistName: "歌手", startedAt: 200,
		lm: lbTrackMeta{ArtistName: "歌手", TrackName: "内容被拒"}, err: fmt.Errorf("post single: %w", errListenRejected)})

	if auth.listenSent {
		t.Error("令牌被拒不算发出去了")
	}
	if !rej.listenSent {
		t.Error("内容被拒应标成已处理,免得每拍重发")
	}
	lbRetryMu.Lock()
	items := loadLBRetryLocked()
	lbRetryMu.Unlock()
	if len(items) != 1 || items[0].ListenedAt != 100 || items[0].Meta.TrackName != "令牌被拒" {
		t.Fatalf("只有令牌被拒那条进队列: %+v", items)
	}
}

// 待重发队列里令牌被拒:停在这一条、整队留到下一轮,不当拒收丢掉。
func TestProcessLBRetryKeepsItemsOnAuthError(t *testing.T) {
	withLBRetryFile(t)
	enqueueLBRetry(100, lbTrackMeta{ArtistName: "A", TrackName: "一"})
	enqueueLBRetry(200, lbTrackMeta{ArtistName: "A", TrackName: "二"})
	calls := 0
	sent := processLBRetry(context.Background(), func(context.Context, int64, lbTrackMeta) error {
		calls++
		return fmt.Errorf("post single: %w", errListenAuth)
	})
	if sent != 0 || calls != 1 {
		t.Fatalf("撞上令牌被拒应当停手:sent=%d calls=%d", sent, calls)
	}
	lbRetryMu.Lock()
	n := len(loadLBRetryLocked())
	lbRetryMu.Unlock()
	if n != 2 {
		t.Fatalf("两条都应留在队列里,剩 %d 条", n)
	}
}

// 进队列的载荷不带歌词(完成收听本来就不发),而且不改调用方那份 map。
func TestLBRetryMetaStripsLyricsWithoutMutating(t *testing.T) {
	in := lbTrackMeta{ArtistName: "A", TrackName: "T", AdditionalInfo: map[string]any{
		"lyrics": "x", "lyrics_tr": "y", "lyrics_roma": "z", "lyrics_yrc": "w", "media_player": "Music",
	}}
	out := lbRetryMeta(in)
	if len(out.AdditionalInfo) != 1 || out.AdditionalInfo["media_player"] != "Music" {
		t.Errorf("应只剩非歌词字段: %+v", out.AdditionalInfo)
	}
	if len(in.AdditionalInfo) != 5 {
		t.Errorf("不该改调用方的 map: %+v", in.AdditionalInfo)
	}
}

// 队列文件解不开:挪到旁边再当空,不在原地被下一次入队整份覆盖。
func TestLBRetryCorruptQueueMovedAside(t *testing.T) {
	withLBRetryFile(t)
	if err := os.WriteFile(lbRetryPath, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	lbRetryMu.Lock()
	items := loadLBRetryLocked()
	lbRetryMu.Unlock()
	if items != nil {
		t.Fatalf("解不开应当当空: %+v", items)
	}
	if _, err := os.Stat(lbRetryPath); !os.IsNotExist(err) {
		t.Error("原文件应当被挪走")
	}
	entries, _ := os.ReadDir(filepath.Dir(lbRetryPath))
	found := false
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), filepath.Base(lbRetryPath)+".corrupt-") {
			data, _ := os.ReadFile(filepath.Join(filepath.Dir(lbRetryPath), e.Name()))
			found = string(data) == "{not json"
		}
	}
	if !found {
		t.Error("挪开的那份应当原样保留")
	}
}

// ---- Last.fm 错误分档 ----

func TestLastfmMayHaveStoredIncludesOperationFailed(t *testing.T) {
	if !(&lastfmAPIError{Code: 8}).mayHaveStored() {
		t.Error("error 8(后端出错)可能已落库,不能当确定没收")
	}
	if lastfmResendSafe(&lastfmAPIError{Code: 8}) {
		t.Error("error 8 不该自动重发")
	}
}

// track.scrobble 的 200 没带回执:结果不明,不能当成功;updateNowPlaying 没有回执这一说,照旧算成功。
func TestLastfmScrobbleWithoutReceiptIsUnconfirmed(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return `{}`, nil })
	err := env.p.lfm.scrobble(context.Background(), "A", "S", "", 1790000000, 200)
	var unconfirmed *lastfmUnconfirmedError
	if !errors.As(err, &unconfirmed) {
		t.Fatalf("没回执应报结果不明,got %v", err)
	}
	if lastfmResendSafe(err) || provablyNeverSent(err) {
		t.Error("结果不明:不能自动重发,也不能当没发出去")
	}
	if err := env.p.lfm.updateNowPlaying(context.Background(), "A", "S", "", 200); err != nil {
		t.Errorf("正在播放没有回执一说,got %v", err)
	}
}

// ctx 在发之前就结束了:请求没离开本机,报「确定没发」,不被当成不确定隔离掉。
func TestLastfmCallWithEndedContextIsNotSent(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := env.p.lfm.scrobble(ctx, "A", "S", "", 1790000000, 200)
	if !errors.Is(err, errLastfmNotSent) || !provablyNeverSent(err) || !lastfmResendSafe(err) {
		t.Fatalf("发之前 ctx 已结束应算确定没发,got %v", err)
	}
	if env.requests.Load() != 0 {
		t.Error("不该发出请求")
	}
}

// ---- 编目匹配 ----

// 判成 keep(原样就是编目里那条)时不截合唱串:`Hall & Oates` 截成 `Hall` 就错了。
func TestResolveScrobbleTagsKeepIsNotTruncated(t *testing.T) {
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey("Hall & Oates", "Maneater"): {body: trackJSON("mbid-hall-oates", 800000, 273000)},
	})
	setMatch(t, lastfmMatchCustom, true, true, true)
	if a, tr := resolveScrobbleTags(context.Background(), col, "Hall & Oates", "Maneater", 273); a != "Hall & Oates" || tr != "Maneater" {
		t.Errorf("keep 不该截断,got %q / %q", a, tr)
	}
	// 第二次走缓存,同样不截。
	if a, _ := resolveScrobbleTags(context.Background(), col, "Hall & Oates", "Maneater", 273); a != "Hall & Oates" {
		t.Errorf("缓存命中的 keep 也不该截断,got %q", a)
	}
}

// 没时长时判出的 defer 挡不住之后带时长的同一首;带时长判出的 defer 照常缓存。
func TestCatalogNoDurationDeferIsRecheckedWithDuration(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("A", "歌"): {body: shadowJSON},
	})
	calls := func() int {
		cs.mu.Lock()
		defer cs.mu.Unlock()
		return cs.calls[infoKey("A", "歌")]
	}
	col.resolve(context.Background(), "A", "歌", 0, scopeAll)
	if d := col.cache["A\n歌"]; d.Verdict != verdictDefer || !d.NoDuration {
		t.Fatalf("没时长判出的 defer 应带 NoDuration: %+v", d)
	}
	col.resolve(context.Background(), "A", "歌", 0, scopeAll)
	if n := calls(); n != 1 {
		t.Fatalf("同样没时长时照常用缓存,查了 %d 次", n)
	}
	col.resolve(context.Background(), "A", "歌", 200, scopeAll)
	if n := calls(); n != 2 {
		t.Fatalf("带时长来的应当重判,查了 %d 次", n)
	}
	if d := col.cache["A\n歌"]; d.NoDuration {
		t.Fatal("带时长判出的 defer 不该再带 NoDuration")
	}
	col.resolve(context.Background(), "A", "歌", 200, scopeAll)
	if n := calls(); n != 2 {
		t.Fatalf("带时长判出的 defer 照常缓存,查了 %d 次", n)
	}
}

// 扩展搜索:同时在飞的请求不超过上限;本地出站闸排不上队只算这一路缺了(partial),不让整个判定作废。
func TestExtCandidatesBoundedConcurrencyAndLocalGuardIsPartial(t *testing.T) {
	var inflight, peak atomic.Int32
	col := &lastfmCatalogMatcher{apiKey: "k", baseURL: "http://catalog.test/2.0/",
		cache: map[string]lastfmCatalogDecision{}, tops: map[string][]lastfmTopTrack{}}
	col.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		if lastfmEndpointDecode(q.Get("artist")) == "Busy" {
			return nil, errHostRateLimited
		}
		n := inflight.Add(1)
		defer inflight.Add(-1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		body := shadowJSON
		switch q.Get("method") {
		case "artist.getTopTracks":
			body = emptyTopTracksJSON
		case "track.search":
			body = emptySearchJSON
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})}
	names := []extName{{"N1", identityStrong}, {"N2", identityStrong}, {"N3", identityStrong}, {"N4", identityWeak}, {"Busy", identityStrong}}
	_, partial, err := col.extCandidates(context.Background(), "N1 & N2", "歌", names, nil, scopeAll)
	if err != nil {
		t.Fatalf("本地闸拒绝不该让整个判定失败: %v", err)
	}
	if !partial {
		t.Error("有一路被本地闸拒绝,应报 partial")
	}
	if p := peak.Load(); p > lastfmCatalogExtConcurrency || p < 1 {
		t.Errorf("同时在飞的请求峰值 %d,上限 %d", p, lastfmCatalogExtConcurrency)
	}
}

// ---- iPhone 桥接 ----

// 本机经回填 / 重发补进 Last.fm 的收听(收听日志里有 "s" 回执、lfmMirrored 里没有)不当 iPhone 收听转发。
func TestBridgeSkipsListensWithLocalReceipt(t *testing.T) {
	withEnrichCache(t, nil)
	useMirrorFiles(t)
	var hits atomic.Int32
	lbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(lbSrv.Close)
	dir := t.TempDir()
	now := time.Now()
	uts := now.Unix() - 120
	markBackfilled(uts)
	p := &poller{
		ctx:                 context.Background(),
		cfg:                 &config{LastfmUser: "someone", LastfmAPIKey: "key", User: "lb-user", Token: "lb-token"},
		lb:                  &lbClient{root: lbSrv.URL, token: "lb-token", hc: &http.Client{}},
		fwdSeeded:           true,
		forwarded:           map[int64]bool{},
		lfmMirrored:         map[int64]bool{},
		forwardedSet:        persistedTTLSet{path: dir + "/forwarded.json", ttl: forwardedTTL},
		lfmMirroredSet:      persistedTTLSet{path: dir + "/mirrored.json", ttl: lfmMirroredTTL},
		bridgeForwardDoneCh: make(chan []bridgeForwardResult, 1),
	}
	page := lastfmRecentPage{Done: []lastfmTrack{{Artist: "A", Title: "回填过的", UTS: uts}}}
	p.applyBridgeResult(bridgeFetchResult{now: now, ok: true, page: page})
	if p.bridgeForwarding {
		t.Fatal("有本机回执的那条不该起转发")
	}
	if !p.forwarded[uts] {
		t.Error("应记进 forwarded,下次不再判")
	}
	time.Sleep(50 * time.Millisecond)
	if hits.Load() != 0 {
		t.Errorf("不该转发给 LB,打了 %d 次", hits.Load())
	}
}

// Last.fm 上的正在播放:跟最近一次实际发出去的写法(编目改写过的)对得上也算我们自己的回声,过了窗口不算。
func TestLfmNowPlayingEchoUsesSentTags(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return `{"nowplaying":{}}`, nil })
	p := env.p
	p.cur = snapshot{Artist: "鶴", Title: "歌"}
	now := time.Now()
	if p.lfmNowPlayingEcho("The Crane", "歌", now) {
		t.Fatal("还没发过正在播放,改写后的写法不该算回声")
	}
	if err := p.lfm.updateNowPlaying(context.Background(), "The Crane", "歌", "", 200); err != nil {
		t.Fatal(err)
	}
	if !p.lfmNowPlayingEcho("The Crane", "歌", time.Now()) {
		t.Error("跟发出去的写法对得上应算回声")
	}
	if p.lfmNowPlayingEcho("The Crane", "歌", time.Now().Add(lastfmSentNPEchoWindow+time.Minute)) {
		t.Error("过了回声窗口不该再挡")
	}
	if !p.lfmNowPlayingEcho("鶴", "歌", now) {
		t.Error("跟本地当前曲目对得上照旧算回声")
	}
	p.lfm = nil
	if p.lfmNowPlayingEcho("鶴", "歌", now) {
		t.Error("没连 Last.fm 写入就不存在回声")
	}
}

// user.getrecenttracks 回 200 + {"error":N}:报错,不解成一页空结果;29 让 bridge 停手一段时间。
func TestLastfmRecentErrorBodyAndRateLimitGate(t *testing.T) {
	_, err := parseLastfmRecent([]byte(`{"error":29,"message":"Rate Limit Exceeded"}`))
	var apiErr *lastfmAPIError
	if !errors.As(err, &apiErr) || apiErr.Code != 29 {
		t.Fatalf("错误体应报 lastfmAPIError 29,got %v", err)
	}
	if _, err := parseLastfmRecent([]byte(`{"recenttracks":{"@attr":{"total":"0"},"track":[]}}`)); err != nil {
		t.Fatalf("正常的空页不是错误: %v", err)
	}

	saved := lastfmRecentRateLimitedUntil.Load()
	t.Cleanup(func() { lastfmRecentRateLimitedUntil.Store(saved) })
	now := time.Now()
	lastfmRecentRateLimitedUntil.Store(now.Add(time.Minute).UnixNano())
	p := &poller{cfg: &config{LastfmUser: "someone", LastfmAPIKey: "key"}}
	p.bridge(now)
	if p.bridgeFetching || !p.lastfmCheckedAt.IsZero() {
		t.Error("限流退避期间 bridge 不该起拉取")
	}
	if !lastfmRecentRateLimited(now) || lastfmRecentRateLimited(now.Add(2*time.Minute)) {
		t.Error("退避窗口判定不对")
	}
}

// 已熔断的写入器:config.json 换了新快照就重建一次(热重读之后保存配置不再重启进程)。
func TestSyncLiveConfigRebuildsDeadLastfmWriter(t *testing.T) {
	resetFeaturesForTest(t)
	setFeatures(featureFlags{LastfmMirrorScrobble: true})
	creds := `"lastfm_scrobble_api_key":"k","lastfm_scrobble_secret":"s","lastfm_scrobble_session_key":"sk"`
	path := startLiveConfigForTest(t, `{`+creds+`}`)
	start := liveConfig()
	p := &poller{cfg: start, lb: &lbClient{}, lfm: lastfmScrobblerIfEnabled(start), lfmKey: lastfmScrobblerKeyOf(start)}
	first := p.lfm
	if first == nil {
		t.Fatal("应当有 writer")
	}
	p.syncLiveConfig()
	if p.lfm != first {
		t.Fatal("配置没变不该重建")
	}
	first.dead.Store(true)
	p.syncLiveConfig()
	if p.lfm != first {
		t.Fatal("配置没变时熔断状态保持")
	}
	writeConfigForTest(t, path, `{`+creds+`,"listenbrainz_user":"u"}`)
	p.syncLiveConfig()
	if p.lfm == first || p.lfm == nil || p.lfm.dead.Load() {
		t.Fatal("熔断的 writer 在配置换了新快照后应重建")
	}
}

// ---- 退出兜底 ----

// 退出兜底期间结算的会话走同步变体:返回时请求已经发完,不留一个活不过进程退出的 goroutine。
func TestSettleLastfmPendingSyncDuringExit(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
	p := env.p
	p.exitFlushCtx = context.Background()
	s := &playSession{meta: snapshot{Artist: "A", Title: "S", Duration: 200}, playedSecs: 200,
		lastfmPending: &pendingLastfmListen{artistName: "A", meta: snapshot{Artist: "A", Title: "S", Duration: 200}, startedAt: time.Now().Add(-5 * time.Minute).Unix()}}
	if !p.settleLastfmPending(s) {
		t.Fatal("到点了应当结算")
	}
	if env.requests.Load() != 1 || mirrorsInflight.Load() != 0 {
		t.Fatalf("应当同步发完:requests=%d inflight=%d", env.requests.Load(), mirrorsInflight.Load())
	}
	if !s.lastfmSettled || s.lastfmPending != nil {
		t.Error("结算后状态应当落定")
	}
}

// 退出兜底的时限在轮到这一条之前就用完:只写 "l"(确定没发)、进重发队列,不隔离。
func TestMirrorScrobbleSyncWithExhaustedContext(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
	withLfmRetryFile(t)
	env.p.lfm.user = "me"
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	uts := time.Now().Add(-3 * time.Minute).Unix()
	env.p.mirrorScrobbleSync(ctx, "A", "S", "", uts, "Raw", 200, true)
	if env.requests.Load() != 0 || !env.p.lfmMirrored[uts] {
		t.Fatalf("不该发请求、要标记:requests=%d", env.requests.Load())
	}
	if k := logKinds(uts); k != "l" {
		t.Errorf("确定没发应只写 l,got %q", k)
	}
	lfmRetryMu.Lock()
	items := loadLfmRetryLocked()
	lfmRetryMu.Unlock()
	if len(items) != 1 || items[0].Timestamp != uts || !items[0].NotAudio {
		t.Fatalf("应进重发队列且带上 NotAudio: %+v", items)
	}
}

// 已熔断 + 活路径已处理过这一条:退出这一拍不再留一次痕。
func TestMirrorScrobbleSyncDeadButAlreadyMirrored(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
	uts := time.Now().Add(-3 * time.Minute).Unix()
	env.p.lfm.dead.Store(true)
	env.p.lfmMirrored[uts] = true
	env.p.mirrorScrobbleSync(context.Background(), "A", "S", "", uts, "Raw", 200, false)
	if k := logKinds(uts); k != "" {
		t.Errorf("已处理过的不该再留痕,got %q", k)
	}
}

// ---- Last.fm 待重发队列 ----

// 重发送达、回执却写不进收听日志:移出队列、补隔离标记、这一轮停手。
func TestProcessLfmRetryReceiptWriteFailureStops(t *testing.T) {
	withLfmRetryFile(t)
	now := time.Now()
	lfmRetryMu.Lock()
	saveLfmRetryLocked([]lfmRetryItem{
		{User: "me", Timestamp: now.Add(-time.Hour).Unix(), Artist: "A", Title: "一"},
		{User: "me", Timestamp: now.Add(-30 * time.Minute).Unix(), Artist: "A", Title: "二"},
	})
	lfmRetryMu.Unlock()
	var submitted int
	var quarantined []int64
	hooks := lfmRetryHooks{
		handled:    func() map[int64]bool { return nil },
		submitted:  func(int64) error { return errors.New("disk full") },
		quarantine: func(ts int64) { quarantined = append(quarantined, ts) },
	}
	sent := processLfmRetry(context.Background(), now, "me", func(context.Context, lfmRetryItem) error {
		submitted++
		return nil
	}, hooks)
	if sent != 1 || submitted != 1 {
		t.Fatalf("第一条送达后应停手:sent=%d submitted=%d", sent, submitted)
	}
	if len(quarantined) != 1 || quarantined[0] != now.Add(-time.Hour).Unix() {
		t.Errorf("送达那条应补隔离标记: %v", quarantined)
	}
	lfmRetryMu.Lock()
	left := loadLfmRetryLocked()
	lfmRetryMu.Unlock()
	if len(left) != 1 || left[0].Title != "二" {
		t.Fatalf("送达那条移出、第二条留着: %+v", left)
	}
}

// 用户在待补清单里删掉的收听:队列里那条也一起删;收听行没了的条目不再交。
func TestLfmRetryHonoursDeletedListens(t *testing.T) {
	withLfmRetryFile(t)
	now := time.Now()
	a, b := now.Add(-time.Hour).Unix(), now.Add(-30*time.Minute).Unix()
	lfmRetryMu.Lock()
	saveLfmRetryLocked([]lfmRetryItem{{User: "me", Timestamp: a, Title: "一"}, {User: "me", Timestamp: b, Title: "二"}})
	lfmRetryMu.Unlock()
	if n := dropLfmRetryTimestamps(map[int64]bool{a: true}); n != 1 {
		t.Fatalf("应删掉 1 条,删了 %d", n)
	}
	lfmRetryMu.Lock()
	left := loadLfmRetryLocked()
	lfmRetryMu.Unlock()
	if len(left) != 1 || left[0].Timestamp != b {
		t.Fatalf("剩下的不对: %+v", left)
	}

	var sent []int64
	hooks := lfmRetryHooks{
		handled:    func() map[int64]bool { return nil },
		submitted:  func(int64) error { return nil },
		quarantine: func(int64) {},
		logged:     func() (map[int64]bool, bool) { return map[int64]bool{}, true },
	}
	processLfmRetry(context.Background(), now, "me", func(_ context.Context, it lfmRetryItem) error {
		sent = append(sent, it.Timestamp)
		return nil
	}, hooks)
	if len(sent) != 0 {
		t.Fatalf("收听行已经不在的不该再交: %v", sent)
	}
	lfmRetryMu.Lock()
	n := len(loadLfmRetryLocked())
	lfmRetryMu.Unlock()
	if n != 0 {
		t.Errorf("应当移出队列,剩 %d 条", n)
	}
}

// ---- 收听日志 ----

// 整份重写(delete-listen、压缩)只挑行不改行:解不开的行、新版本多出来的字段原样留下。
func TestListenLogRewritePreservesRawLines(t *testing.T) {
	useMirrorFiles(t)
	lines := []string{
		`{"t":"l","v":1,"uts":100,"ar":"A","ti":"留着","zz":"未来字段"}`,
		`{"t":"l","v":1,"uts":200,"ar":"A","ti":"删掉"`,
		`{"t":"l","v":1,"uts":200,"ar":"A","ti":"删掉"}`,
		`{"t":"s","v":1,"uts":200}`,
		`{"t":"l","v":1,"uts":300,"ar":"A","ti":"也留着"}`,
	}
	if err := os.WriteFile(listenLogPath, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	deleted, remaining, err := deleteListensByUTS([]int64{200})
	if err != nil || deleted != 2 || remaining != 3 {
		t.Fatalf("deleted=%d remaining=%d err=%v", deleted, remaining, err)
	}
	data, _ := os.ReadFile(listenLogPath)
	want := strings.Join([]string{lines[0], lines[1], lines[4]}, "\n") + "\n"
	if string(data) != want {
		t.Fatalf("重写后内容不对:\n%s\nwant:\n%s", data, want)
	}
}

// 隔离标记写不进去要能被调用方看到(补提交据此停手)。
func TestMarkQuarantinedCheckedReportsWriteFailure(t *testing.T) {
	useMirrorFiles(t)
	setListenLogPath(t.TempDir()) // 路径是个目录:追加必然失败
	if err := markQuarantinedChecked(1790000000); err == nil {
		t.Fatal("写不进去应当报错")
	}
	if err := markBackfilledChecked(1790000000); err == nil {
		t.Fatal("回执写不进去应当报错")
	}
}

// ---- 听歌报告 ----

// LB 用户名进路径段要转义。
func TestLBListensBeforeEscapesUser(t *testing.T) {
	var mu sync.Mutex
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gotPath = r.URL.EscapedPath()
		mu.Unlock()
		w.Write([]byte(`{"payload":{"listens":[]}}`))
	}))
	t.Cleanup(srv.Close)
	if _, _, err := lbListensBefore(context.Background(), srv.URL, "a b#c?d", 0, 100); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if gotPath != "/1/user/a%20b%23c%3Fd/listens" {
		t.Errorf("路径 = %q", gotPath)
	}
}

// 周期状态原子写:写完读得回来,不留临时文件。
func TestDigestStateSaveIsAtomic(t *testing.T) {
	dir := t.TempDir()
	d := dailyDigestState{path: filepath.Join(dir, "daily.json")}
	d.save("2026-09-28")
	if got := d.load(); got != "2026-09-28" {
		t.Fatalf("daily 读回 %q", got)
	}
	w := weeklyDigestState{path: filepath.Join(dir, "weekly.json")}
	w.save(1790000000)
	c := calendarDigestState{path: filepath.Join(dir, "calendar.json")}
	c.save("2026-09")
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp") {
			t.Errorf("不该留下临时文件 %s", e.Name())
		}
	}
	if len(entries) != 3 {
		t.Errorf("应当正好三份状态文件,有 %d 份", len(entries))
	}
}
