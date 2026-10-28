package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 13 章网页中继审计:内容变了补推、等待点到点叫醒、失败时续心跳、上次播放不倒退、运行中补种、封面令牌切换、
// 目录监听退回、Top 歌手的 mbid 与头像、QQ 规范名没问成不缓存。

// 同一个状态里歌词变了:新内容稳定 relayContentSettle 才推一次(原因 content);来回抖的(含退回已推那份)不推;「空」不看内容。
func TestRelayShouldPushContentChange(t *testing.T) {
	const key = "mac|t|a|b|c"
	first := map[string]any{"artwork": "https://x/a.jpg", "lyrics": "[00:01]先上屏"}
	final := map[string]any{"artwork": "https://x/a.jpg", "lyrics": "[00:01]定案", "lyricsTr": "译文"}
	t0 := time.Now()
	p := &poller{relayLastState: key, relayLastAt: t0.Add(-time.Minute), relayStateSince: t0.Add(-time.Minute),
		relayLastDigest: relayContentDigest(first)}
	if _, ok := p.relayShouldPush(t0, key, first, false); ok {
		t.Fatal("内容没变不该推")
	}
	if _, ok := p.relayShouldPush(t0, key, final, false); ok {
		t.Fatal("内容刚变先等它稳定")
	}
	if _, ok := p.relayShouldPush(t0.Add(relayContentSettle-time.Millisecond), key, final, false); ok {
		t.Fatal("没等满不推")
	}
	reason, ok := p.relayShouldPush(t0.Add(relayContentSettle), key, final, false)
	if !ok || reason != "content" {
		t.Fatalf("等满了推,原因 content: %q %v", reason, ok)
	}
	p.applyRelayResult(relayPushResult{key: key, reason: reason, at: t0.Add(relayContentSettle), digest: relayContentDigest(final)})
	if _, ok := p.relayShouldPush(t0.Add(10*time.Second), key, final, false); ok {
		t.Fatal("推过之后同一份内容不再推")
	}

	flap := &poller{relayLastState: key, relayLastAt: t0.Add(-time.Minute), relayStateSince: t0.Add(-time.Minute),
		relayLastDigest: relayContentDigest(first)}
	other := map[string]any{"artwork": "https://x/a.jpg", "lyrics": "[00:01]另一份"}
	for i := range 20 {
		payload := final
		if i%2 == 1 {
			payload = other
		}
		if _, ok := flap.relayShouldPush(t0.Add(time.Duration(i)*time.Second), key, payload, false); ok {
			t.Fatalf("内容每秒来回变,第 %d 拍不该推", i)
		}
	}

	back := &poller{relayLastState: key, relayLastAt: t0.Add(-time.Minute), relayStateSince: t0.Add(-time.Minute),
		relayLastDigest: relayContentDigest(first)}
	for i := range 20 {
		payload := final
		if i%2 == 1 {
			payload = first
		}
		if _, ok := back.relayShouldPush(t0.Add(time.Duration(i)*time.Second), key, payload, false); ok {
			t.Fatalf("内容在已推那份和新的一份之间来回变,第 %d 拍不该推", i)
		}
	}

	empty := &poller{relayLastState: "empty", relayLastAt: t0.Add(-time.Minute), relayStateSince: t0.Add(-time.Minute)}
	if _, ok := empty.relayShouldPush(t0.Add(time.Hour), "empty", map[string]any{"empty": true}, false); ok {
		t.Fatal("「空」不按内容推")
	}
	if relayContentDigest(nil) != 0 {
		t.Fatal("没有负载的摘要是 0")
	}
}

// 等待点到点叫醒主循环;推送回来也叫醒一次,飞着时挡下的变化不等下一个主节拍。
func TestRelayWakesMainLoop(t *testing.T) {
	p := &poller{relayWakeCh: make(chan struct{}, 1)}
	p.applyRelayResult(relayPushResult{key: "mac|t|a|b|c", at: time.Now()})
	select {
	case <-p.relayWakeCh:
	case <-time.After(time.Second):
		t.Fatal("推送成功后该叫醒主循环")
	}
	t0 := time.Now()
	q := &poller{relayWakeCh: make(chan struct{}, 1), relayLastState: "macpause|t|a|b|c", relayLastAt: t0.Add(-time.Minute)}
	if _, ok := q.relayShouldPush(t0, "mac|t|a|b|c", map[string]any{"artwork": "x"}, false); ok {
		t.Fatal("暂停到在放先等一下")
	}
	if q.relayWakeTimer == nil || !q.relayWakeTimer.Stop() {
		t.Fatal("设下等待点时要排一个到点叫醒")
	}
}

// 推送失败还没撤销时,空闲超过 relayIdleHeartbeatFor 也照样续心跳;没失败照旧停。
func TestRelayIdleHeartbeatContinuesWhileFailing(t *testing.T) {
	t0 := time.Now()
	idle := func() *poller {
		return &poller{relayLastState: "macpause|t|a|b", relayLastAt: t0.Add(-5 * time.Minute),
			relayStateSince: t0.Add(-time.Hour)}
	}
	if _, ok := idle().relayShouldPush(t0, "macpause|t|a|b", nil, false); ok {
		t.Fatal("没失败时空闲一小时不续心跳")
	}
	failing := idle()
	failing.relayFailingSince = t0.Add(-20 * time.Minute)
	if reason, ok := failing.relayShouldPush(t0, "macpause|t|a|b", nil, false); !ok || reason != "heartbeat" {
		t.Fatalf("有没撤销的失败时照样续心跳: %q %v", reason, ok)
	}
}

// 「上次播放」不被更早的收听盖掉(iPhone 晚到的离线收听)。
func TestPushScrobbleKeepsNewerLastListen(t *testing.T) {
	p := &poller{}
	p.pushScrobble(snapshot{Title: "新", Artist: "a"}, 2000, "mac")
	p.pushScrobble(snapshot{Title: "旧", Artist: "b"}, 1000, "iphone")
	if p.lastListen.Title != "新" || p.lastListenAt != 2000 || p.lastListenDev != "mac" {
		t.Fatalf("晚到的旧收听不该盖掉: %+v %d %q", p.lastListen, p.lastListenAt, p.lastListenDev)
	}
	p.pushScrobble(snapshot{Title: "更新", Artist: "c"}, 3000, "iphone")
	if p.lastListen.Title != "更新" {
		t.Fatal("更新的照换")
	}
}

// 运行中才配上中继和 ListenBrainz 用户名:补一次「上次播放」;启动时就配好的、手上已有收听的不补。
func TestSyncLiveConfigSeedsLastListenWhenRelayAppears(t *testing.T) {
	resetLiveConfigForTest(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"payload":{"listens":[{"listened_at":1700000000,"track_metadata":{"track_name":"浮夸","artist_name":"陈奕迅"}}]}}`))
	}))
	t.Cleanup(srv.Close)
	mk := func() *poller {
		return &poller{ctx: context.Background(), lb: &lbClient{root: srv.URL}, lastListenSeedCh: make(chan lastListenSeed, 1)}
	}
	ready := &config{StateRelayURL: "https://relay.example", User: "u"}

	p := mk()
	p.maybeSeedLastListen(&config{User: "u"}, ready)
	if !p.lastListenSeeding || p.relayStartupUntil.IsZero() {
		t.Fatal("配上中继后该补种,补种回来之前先不推「空」")
	}
	select {
	case s := <-p.lastListenSeedCh:
		if s.track.Title != "浮夸" {
			t.Fatalf("补种取到的: %+v", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("补种该送回一条")
	}

	already := mk()
	already.maybeSeedLastListen(ready, ready)
	had := mk()
	had.lastListen = snapshot{Title: "真", Artist: "a"}
	had.maybeSeedLastListen(&config{}, ready)
	if already.lastListenSeeding || had.lastListenSeeding {
		t.Fatal("本来就配好的、手上已有收听的不补")
	}
}

// 只换令牌:拿旧令牌失败的冷却作废,代次加一(在飞的旧上传回来不记账),已确认的留着。
func TestSwitchStateRelayTokenOnlyClearsCooldown(t *testing.T) {
	resetArtworkRelayState(t)
	setStateRelay("https://relay-a.example", "bad")
	artworkMu.Lock()
	artworkUploaded["kept"] = true
	artworkNextRetry["cool"] = time.Now().Add(time.Hour)
	artworkMu.Unlock()
	gen := artworkRelayGenNow()

	switchStateRelay("https://relay-a.example", "good")
	artworkMu.Lock()
	_, cooling := artworkNextRetry["cool"]
	kept := artworkUploaded["kept"]
	artworkMu.Unlock()
	if cooling || !kept {
		t.Fatalf("冷却作废、确认留着: cooling=%v kept=%v", cooling, kept)
	}
	if artworkRelayGenNow() == gen {
		t.Fatal("换令牌代次要加一")
	}
	gen = artworkRelayGenNow()
	switchStateRelay("https://relay-a.example", "good")
	if artworkRelayGenNow() != gen {
		t.Fatal("什么都没换代次不动")
	}
}

// 存量补传跳过懒上传正在传的那张。
func TestArtworkSweepSkipsInflight(t *testing.T) {
	src, err := os.ReadFile("artworkrelay.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "skip := artworkUploaded[sha] || artworkInflight[sha]\n if !skip {\n artworkInflight[sha] = true\n }") {
		t.Error("sweepDeviceArtwork 要看并登记 artworkInflight")
	}
}

// 盯着的目录被删掉:监听退出,调用方据此退回定时器。
func TestDirWatchStopsWhenDirRemoved(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "watched")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	stopped, ok := startDirWatch(context.Background(), dir, make(chan struct{}, 1))
	if !ok {
		t.Fatal("该盯得上")
	}
	if err := os.Remove(dir); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("目录删掉后监听该退出")
	}
	src, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "case <-watchStopped:\n // 盯目录中途停了(目录被删、改名,kevent 出错):退回每秒看一次。\n watchStopped = nil\n if ctx.Err() == nil {\n startAppCheck()") {
		t.Error("主循环要在监听退出时退回每秒看一次")
	}
}

// Last.fm 给了 mbid 的单人条目:缓存里那条「认不出身份」(合唱串先按名字查出来的)不挡着它。
func TestArtistIdentityUsesLastfmMbid(t *testing.T) {
	artistIdentityMu.Lock()
	saved := artistIdentityCache
	artistIdentityCache = map[string]mbArtistIdentity{"A": {Checked: true, CheckedAt: time.Now().Unix()}}
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		artistIdentityCache = saved
		artistIdentityMu.Unlock()
	})
	if got := cacheOnlyArtistIdentity("A", "mbid-a").Mbid; got != "mbid-a" {
		t.Errorf("只读缓存那档要用上 Last.fm 的 mbid: %q", got)
	}
	if got := cacheOnlyArtistIdentity("A", "").Mbid; got != "" {
		t.Errorf("没给 mbid 照旧: %q", got)
	}
	if got := budgetedArtistIdentity(0)("A", "mbid-a").Mbid; got != "mbid-a" {
		t.Errorf("预算用完时同只读缓存那档: %q", got)
	}
	// 名字键连不上、只靠 mbid 相同的两条并成一行。
	entries := []lastfmChartEntry{{Name: "A", PlayCount: 5, Mbid: "mbid-a"}, {Name: "Alias", PlayCount: 3, Mbid: "mbid-a"}}
	find, _ := artistMergeGroups(entries, cacheOnlyArtistIdentity, func(s string) string { return s })
	if find(0) != find(1) {
		t.Error("同一个 Last.fm mbid 要并成一行")
	}
}

// QQ 那条腿只拿一半时限:QQ 卡住时 Deezer 还有时间答。
func TestResolveArtistAvatarLeavesTimeForDeezer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	qq := func(ctx context.Context, _ string) (string, bool) {
		<-ctx.Done()
		return "", false
	}
	deezer := func(ctx context.Context, _ string) (string, bool) {
		if ctx.Err() != nil {
			return "", false
		}
		return "dz.jpg", true
	}
	if pic, def := resolveArtistAvatarVia(ctx, "X", qq, deezer); pic != "dz.jpg" || !def {
		t.Fatalf("QQ 卡住时 Deezer 该拿到图: %q %v", pic, def)
	}
}

// 后台 Top 歌手推送走头像磁盘缓存:这次两条腿都暂时故障时用缓存里的旧头像。
func TestCachedArtistAvatarsKeepsOldOnTransientFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "avatars.json")
	ok := func(context.Context, string) (string, bool) { return "https://img/a.jpg", true }
	if got := cachedArtistAvatars(context.Background(), path, []string{"A"}, time.Second, ok)["A"]; got != "https://img/a.jpg" {
		t.Fatalf("第一次取到: %q", got)
	}
	// 缓存过期后再取,这次暂时故障:用旧的。
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	stale := []byte(`{"A":{"url":"https://img/a.jpg","ts":1}}`)
	if len(data) == 0 {
		t.Fatal("该写进缓存")
	}
	if err := os.WriteFile(path, stale, 0o600); err != nil {
		t.Fatal(err)
	}
	down := func(context.Context, string) (string, bool) { return "", false }
	if got := cachedArtistAvatars(context.Background(), path, []string{"A"}, time.Second, down)["A"]; got != "https://img/a.jpg" {
		t.Fatalf("暂时故障时用旧头像: %q", got)
	}
	src, err := os.ReadFile("topartists.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "avatars := cachedArtistAvatars(env.ctx, artistAvatarCachePath(), names, avatarPerNameTimeout, topArtistAvatar)") {
		t.Error("后台推送要走头像缓存")
	}
}

// QQ 规范名没问成:不缓存成「没有」,隔 qqArtistNameRetryAfter 再问。
func TestQQArtistCanonicalNameRetriesAfterFailure(t *testing.T) {
	f := withQQFake(t, func(string) (int, string) { return http.StatusInternalServerError, "" })
	qqArtistNameMu.Lock()
	savedCache, savedRetry := qqArtistNameCache, qqArtistNameRetryAt
	qqArtistNameCache, qqArtistNameRetryAt = map[string]string{}, map[string]time.Time{}
	qqArtistNameMu.Unlock()
	t.Cleanup(func() {
		qqArtistNameMu.Lock()
		qqArtistNameCache, qqArtistNameRetryAt = savedCache, savedRetry
		qqArtistNameMu.Unlock()
	})
	if got := cachedQQArtistCanonicalName("Some Singer"); got != "" {
		t.Fatalf("没问成返回空: %q", got)
	}
	qqArtistNameMu.Lock()
	_, cached := qqArtistNameCache["Some Singer"]
	retryAt := qqArtistNameRetryAt["Some Singer"]
	qqArtistNameMu.Unlock()
	if cached || retryAt.IsZero() {
		t.Fatalf("没问成不缓存、记下重试时刻: cached=%v retryAt=%v", cached, retryAt)
	}
	total := func() int {
		f.mu.Lock()
		defer f.mu.Unlock()
		n := 0
		for _, v := range f.hits {
			n += v
		}
		return n
	}
	// 熔断器、出站闸换成新的:第二次不问只能是因为重试时刻没到
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	before := total()
	cachedQQArtistCanonicalName("Some Singer")
	if total() != before {
		t.Error("重试时刻之前不再问")
	}
}
