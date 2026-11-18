package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// 中继(state-worker)在 kv.put 抛错时回的 503 响应体,detail 是 KV 自己的原话。
const (
	relayQuotaBody    = `{"ok":false,"error":"kv write failed (quota?)","detail":"Error: KV put() limit exceeded for the day."}`
	relayKVBusyBody   = `{"ok":false,"error":"kv write failed (quota?)","detail":"Error: KV PUT failed: 429 Too Many Requests"}`
	relayPlainBadBody = `error code: 1101`
)

// 额度用完只认「503 + 响应体说 quota 和 limit」;同样是 kv.put 抛错的「写得太快」、别的状态码、没有响应体都不算。
func TestRelayQuotaExhausted(t *testing.T) {
	cases := []struct {
		status int
		body   string
		want   bool
	}{
		{503, relayQuotaBody, true},
		{503, `{"ERROR":"QUOTA","detail":"LIMIT EXCEEDED"}`, true},
		{503, relayKVBusyBody, false},
		{503, relayPlainBadBody, false},
		{503, "", false},
		{500, relayQuotaBody, false},
		{429, relayQuotaBody, false},
	}
	for _, c := range cases {
		if got := relayQuotaExhausted(c.status, []byte(c.body)); got != c.want {
			t.Errorf("%d %s: got %v", c.status, c.body, got)
		}
	}
	if kind, status := relayFailureKind(&relayHTTPError{path: "/push", status: 503, quota: true}); kind != relayFailQuota || status != 503 {
		t.Errorf("额度用完归 quota: %s/%d", kind, status)
	}
	if kind, _ := relayFailureKind(&relayHTTPError{path: "/push", status: 503}); kind != relayFailServer {
		t.Errorf("普通 503 仍归 server: %s", kind)
	}
}

// postRelay 读响应体,额度用完的 503 带上 quota 标记;普通 503 不带。
func TestPostRelayReadsQuotaBody(t *testing.T) {
	body := relayQuotaBody
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	cfg := &config{StateRelayURL: srv.URL}
	if kind, _ := relayFailureKind(postRelay(context.Background(), cfg, "/push", map[string]any{"ok": true})); kind != relayFailQuota {
		t.Fatalf("额度用完的 503: %s", kind)
	}
	body = relayKVBusyBody
	if kind, _ := relayFailureKind(postRelay(context.Background(), cfg, "/push", map[string]any{"ok": true})); kind != relayFailServer {
		t.Fatalf("别的写入失败照普通 503: %s", kind)
	}
}

// 停推到下一个 UTC 0 点;0 点之后一小时以内又报用完(本机时钟快、重置还没生效)只停 relayBackoffMax。
func TestRelayQuotaResumeAt(t *testing.T) {
	cases := []struct{ at, want string }{
		{"2026-11-18T13:00:00Z", "2026-11-19T00:00:00Z"},
		{"2026-11-18T23:59:59Z", "2026-11-19T00:00:00Z"},
		{"2026-11-19T00:10:00Z", "2026-11-19T00:20:00Z"},
		{"2026-11-19T00:59:59Z", "2026-11-19T01:09:59Z"},
		{"2026-11-19T01:00:00Z", "2026-11-20T00:00:00Z"},
		{"2026-11-19T02:00:00+08:00", "2026-11-19T00:00:00Z"},
	}
	for _, c := range cases {
		at, _ := time.Parse(time.RFC3339, c.at)
		want, _ := time.Parse(time.RFC3339, c.want)
		if got := relayQuotaResumeAt(at); !got.Equal(want) {
			t.Errorf("%s: got %s, want %s", c.at, got.UTC().Format(time.RFC3339), c.want)
		}
	}
}

func relayQuotaErr() error { return &relayHTTPError{path: "/push", status: 503, quota: true} }

// 额度用完:停到下一个 UTC 0 点,这期间换歌、暂停都不推、不清退避;状态文件带上截止时刻;封面也不传。到点照常推,推成功撤掉。
func TestRelayQuotaPausesUntilUTCMidnight(t *testing.T) {
	path := useRelayStatusPathForTest(t)
	t.Cleanup(func() { setRelayQuotaPause(time.Time{}) })
	t0, _ := time.Parse(time.RFC3339, "2026-11-18T13:00:00Z")
	midnight, _ := time.Parse(time.RFC3339, "2026-11-19T00:00:00Z")
	p := &poller{relayInflight: true, relayLastState: "mac|A|x|y|c", relayLastAt: t0.Add(-time.Minute),
		relayStateSince: t0.Add(-time.Minute)}
	p.applyRelayResult(relayPushResult{key: "mac|B|x|y|c", at: t0, err: relayQuotaErr()})
	if !p.relayQuotaUntil.Equal(midnight) {
		t.Fatalf("停到下一个 UTC 0 点: %v", p.relayQuotaUntil)
	}
	want := relayStatusFile{Schema: relayStatusSchema, Kind: relayFailQuota, Status: 503, Since: t0.Unix(), Until: midnight.Unix()}
	if f, ok := readRelayStatusForTest(t, path); !ok || f != want {
		t.Fatalf("状态文件带截止时刻: %+v ok=%v", f, ok)
	}
	cover := map[string]any{"artwork": "https://c/1.jpg"}
	for _, tc := range []struct {
		at  time.Duration
		key string
	}{
		{time.Minute, "mac|C|x|y|c"},
		{10 * time.Minute, "macpause|C|x|y|c"},
		{time.Hour, "mac|D|x|y|c"},
		{midnight.Sub(t0) - time.Second, "mac|E|x|y|c"},
	} {
		if _, ok := p.relayShouldPush(t0.Add(tc.at), tc.key, cover, true); ok {
			t.Fatalf("+%v %s:额度用完期间换歌、暂停、重锚都不推", tc.at, tc.key)
		}
	}
	if !relayQuotaPaused(midnight.Add(-time.Second)) || relayQuotaPaused(midnight) {
		t.Fatal("封面托管跟着停到同一时刻")
	}
	reason, ok := p.relayShouldPush(midnight, "mac|E|x|y|c", cover, false)
	if !ok || reason != "change" {
		t.Fatalf("到点照常推: %q %v", reason, ok)
	}
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "mac|E|x|y|c", reason: reason, at: midnight})
	if !p.relayQuotaUntil.IsZero() || relayQuotaPaused(midnight.Add(-time.Second)) {
		t.Fatal("推成功撤掉停推")
	}
	if _, ok := readRelayStatusForTest(t, path); ok {
		t.Fatal("推成功删状态文件")
	}
	// 0 点后一小时内接连报用完、中间没推成过:每次截止时刻都变,状态文件跟着重写。
	early := midnight.Add(10 * time.Minute)
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "mac|E|x|y|c", at: early, err: relayQuotaErr()})
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "mac|E|x|y|c", at: early.Add(relayBackoffMax), err: relayQuotaErr()})
	if f, _ := readRelayStatusForTest(t, path); f.Until != early.Add(2*relayBackoffMax).Unix() {
		t.Fatalf("接连用完,截止时刻跟着更新: %+v", f)
	}
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "mac|E|x|y|c", reason: "change", at: midnight.Add(time.Hour)})
	// 第二天又用完:截止时刻变了,状态文件重写。
	day2 := midnight.Add(20 * time.Hour)
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "mac|F|x|y|c", at: day2, err: relayQuotaErr()})
	if f, _ := readRelayStatusForTest(t, path); f.Until != midnight.Add(24*time.Hour).Unix() {
		t.Fatalf("第二天用完写第二天的截止时刻: %+v", f)
	}
}

// 普通 503 照旧退避:不停推,同一个 key 按退避重试,状态文件不带截止时刻。
func TestRelayPlain503StillBacksOff(t *testing.T) {
	path := useRelayStatusPathForTest(t)
	t0 := time.Now()
	p := &poller{relayInflight: true, relayLastState: "mac|A|x|y|c", relayLastAt: t0.Add(-5 * time.Minute)}
	p.applyRelayResult(relayPushResult{key: "mac|A|x|y|c", at: t0, err: &relayHTTPError{path: "/push", status: 503}})
	if !p.relayQuotaUntil.IsZero() || p.relayBackoff != relayBackoffMin || relayQuotaPaused(t0.Add(time.Second)) {
		t.Fatalf("普通 503 只进退避: until=%v backoff=%v", p.relayQuotaUntil, p.relayBackoff)
	}
	if f, _ := readRelayStatusForTest(t, path); f.Kind != relayFailServer || f.Until != 0 {
		t.Fatalf("普通 503 报 server、不带截止时刻: %+v", f)
	}
	if _, ok := p.relayShouldPush(t0.Add(10*time.Second), "mac|A|x|y|c", nil, false); ok {
		t.Fatal("退避期内同一个 key 不重试")
	}
	if _, ok := p.relayShouldPush(t0.Add(relayBackoffMin), "mac|A|x|y|c", nil, false); !ok {
		t.Fatal("退避到点重试")
	}
}

// 引擎重启:没到期的「额度用完」不删、读回来接着停;到期的和别的失败照旧删。
func TestRelayQuotaPauseSurvivesRestart(t *testing.T) {
	path := useRelayStatusPathForTest(t)
	t.Cleanup(func() { setRelayQuotaPause(time.Time{}) })
	t0, _ := time.Parse(time.RFC3339, "2026-11-18T13:00:00Z")
	midnight, _ := time.Parse(time.RFC3339, "2026-11-19T00:00:00Z")
	first := &poller{relayInflight: true}
	first.applyRelayResult(relayPushResult{key: "mac|A|x|y|c", at: t0, err: relayQuotaErr()})
	setRelayQuotaPause(time.Time{})

	restart := t0.Add(2 * time.Hour)
	setRelayStatusPathAt(path, restart)
	if _, ok := readRelayStatusForTest(t, path); !ok {
		t.Fatal("没到期的额度用完,重启不删")
	}
	second := &poller{relayLastState: "", relayStartupUntil: time.Time{}}
	second.restoreRelayQuotaPause(restart)
	if !second.relayQuotaUntil.Equal(midnight) || !second.relayFailingSince.Equal(t0) || !relayQuotaPaused(restart) {
		t.Fatalf("重启后接着停: until=%v since=%v", second.relayQuotaUntil, second.relayFailingSince)
	}
	if _, ok := second.relayShouldPush(restart, "mac|B|x|y|c", map[string]any{"artwork": "https://c/1.jpg"}, false); ok {
		t.Fatal("重启后停推期间不推")
	}
	second.relayInflight = true
	second.applyRelayResult(relayPushResult{key: "mac|B|x|y|c", at: restart, err: relayQuotaErr()})
	if raw, err := os.Stat(path); err != nil || raw.Size() == 0 {
		t.Fatalf("状态文件还在: %v", err)
	}

	// 到期了再重启:删掉,不停。
	setRelayStatusPathAt(path, midnight)
	if _, ok := readRelayStatusForTest(t, path); ok {
		t.Fatal("到期的额度用完,重启删掉")
	}
	third := &poller{}
	third.restoreRelayQuotaPause(midnight)
	if !third.relayQuotaUntil.IsZero() {
		t.Fatal("到期的不再停")
	}

	// 别的失败照旧在启动时删。
	writeRelayStatus(relayStatusFile{Schema: relayStatusSchema, Kind: relayFailServer, Status: 503, Since: t0.Unix(),
		Until: t0.Add(time.Hour).Unix()})
	setRelayStatusPathAt(path, t0)
	if _, ok := readRelayStatusForTest(t, path); ok {
		t.Fatal("别的失败启动时删")
	}
	// 读不了的文件同样删。
	if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	setRelayStatusPathAt(path, t0)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("坏文件启动时删")
	}
}

// 改了中继地址或令牌:停推撤掉,按新配置推一次。
func TestResetRelayPushClearsQuotaPause(t *testing.T) {
	useRelayStatusPathForTest(t)
	t.Cleanup(func() { setRelayQuotaPause(time.Time{}) })
	now := time.Now()
	p := &poller{relayQuotaUntil: now.Add(time.Hour), relayReanchorPending: true}
	setRelayQuotaPause(p.relayQuotaUntil)
	p.resetRelayPush()
	if !p.relayQuotaUntil.IsZero() || p.relayReanchorPending || relayQuotaPaused(now) {
		t.Fatalf("换了配置撤掉停推: %+v", p)
	}
}

// 只因重锚而推,离上次推送至少隔 relayReanchorMinGap;间隔里的重锚记着,到点补推一次。换歌、暂停、继续不受限。
func TestRelayShouldPushReanchorMinGap(t *testing.T) {
	const key = "mac|Eye Hate U|PRINCE|The Gold Experience|c"
	cover := map[string]any{"artwork": "https://c/1.jpg"}
	t0 := time.Now()
	fresh := func() *poller {
		return &poller{relayLastState: key, relayLastAt: t0, relayStateSince: t0, relayLastDigest: relayContentDigest(cover)}
	}
	p := fresh()
	if _, ok := p.relayShouldPush(t0.Add(5*time.Second), key, cover, true); ok {
		t.Fatal("上次推送 5 秒后的重锚先不推")
	}
	if _, ok := p.relayShouldPush(t0.Add(relayReanchorMinGap-500*time.Millisecond), key, cover, false); ok {
		t.Fatal("间隔差半秒没到,挂着的重锚不推")
	}
	reason, ok := p.relayShouldPush(t0.Add(relayReanchorMinGap), key, cover, false)
	if !ok || reason != "reanchor" {
		t.Fatalf("到点补推挂着的重锚: %q %v", reason, ok)
	}
	p.applyRelayResult(relayPushResult{key: key, reason: reason, at: t0.Add(relayReanchorMinGap), digest: relayContentDigest(cover)})
	if _, ok := p.relayShouldPush(t0.Add(relayReanchorMinGap+time.Minute), key, cover, false); ok {
		t.Fatal("补推之后不再挂着")
	}

	// 换歌、暂停、继续不受限:离上次推送 1 秒也照推。
	if _, ok := fresh().relayShouldPush(t0.Add(time.Second), "mac|Next|PRINCE|The Gold Experience|c", cover, true); !ok {
		t.Error("换歌立刻推")
	}
	if _, ok := fresh().relayShouldPush(t0.Add(time.Second), "macpause|Eye Hate U|PRINCE|The Gold Experience|c", cover, true); !ok {
		t.Error("暂停立刻推")
	}
	resumed := &poller{relayLastState: "macpause|Eye Hate U|PRINCE|The Gold Experience|c", relayLastAt: t0, relayStateSince: t0}
	resumed.relayShouldPush(t0.Add(time.Second), key, cover, true)
	if _, ok := resumed.relayShouldPush(t0.Add(time.Second+relayResumeSettle), key, cover, true); !ok {
		t.Error("继续播放只等 relayResumeSettle,不等重锚间隔")
	}

	// 每 2 秒判一次重锚、连着 25 分钟:每 relayReanchorMinGap 最多写一次。
	q := fresh()
	writes := 0
	for at := 2 * time.Second; at <= 25*time.Minute; at += 2 * time.Second {
		now := t0.Add(at)
		reason, ok := q.relayShouldPush(now, key, cover, true)
		if !ok {
			continue
		}
		q.applyRelayResult(relayPushResult{key: key, reason: reason, at: now, digest: relayContentDigest(cover)})
		writes++
	}
	if limit := int(25*time.Minute/relayReanchorMinGap) + 1; writes > limit || writes < limit-2 {
		t.Fatalf("25 分钟抖动写了 %d 次,要在 %d 次左右且不超过", writes, limit)
	}
}

// 推送失败后换了 key:可以提前再试,但离上次失败至少 relayBackoffMin;退避时长不因换 key 清零,推成功才清。
func TestRelayBackoffSurvivesKeyChange(t *testing.T) {
	t0 := time.Now()
	cover := map[string]any{"artwork": "https://c/1.jpg"}
	p := &poller{relayLastState: "mac|A|x|y|c", relayLastAt: t0.Add(-time.Hour), relayStateSince: t0.Add(-time.Hour)}
	fail := func(key string, at time.Time) {
		p.relayInflight = true
		p.applyRelayResult(relayPushResult{key: key, at: at, err: &relayHTTPError{path: "/push", status: 503}})
	}
	fail("mac|B|x|y|c", t0)
	fail("mac|B|x|y|c", t0.Add(30*time.Second))
	if p.relayBackoff != 2*relayBackoffMin {
		t.Fatalf("同一个 key 两次失败翻倍: %v", p.relayBackoff)
	}
	last := t0.Add(30 * time.Second)
	if _, ok := p.relayShouldPush(last.Add(10*time.Second), "mac|C|x|y|c", cover, false); ok {
		t.Fatal("换了 key 也要离上次失败至少 relayBackoffMin")
	}
	if _, ok := p.relayShouldPush(last.Add(relayBackoffMin), "mac|C|x|y|c", cover, false); !ok {
		t.Fatal("换了 key、离上次失败满 relayBackoffMin 就再试")
	}
	fail("mac|C|x|y|c", last.Add(relayBackoffMin))
	if p.relayBackoff != 4*relayBackoffMin {
		t.Fatalf("换 key 不清退避,接着翻倍: %v", p.relayBackoff)
	}
	if _, ok := p.relayShouldPush(last.Add(relayBackoffMin+time.Minute), "mac|C|x|y|c", cover, false); ok {
		t.Fatal("同一个 key 仍按完整退避等")
	}
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "mac|C|x|y|c", reason: "change", at: last.Add(5 * time.Minute)})
	if p.relayBackoff != 0 || !p.relayFailAt.IsZero() {
		t.Fatalf("推成功清退避: %v", p.relayBackoff)
	}
}

// 中继的 KV 写额度用完、停推期间封面也不传:不起上传、不记冷却;停推撤掉后照常传。见 13 章决策 17。
func TestArtworkUploadWaitsOutRelayQuota(t *testing.T) {
	resetArtworkRelayState(t)
	t.Cleanup(func() { setRelayQuotaPause(time.Time{}) })
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	setStateRelay(srv.URL, "tok")
	path := filepath.Join(t.TempDir(), testSHA+".jpg")
	if err := os.WriteFile(path, []byte("jpeg"), 0o600); err != nil {
		t.Fatal(err)
	}
	setRelayQuotaPause(time.Now().Add(time.Hour))
	scheduleArtworkUpload(testSHA, path)
	waitArtworkIdle(t)
	artworkMu.Lock()
	_, retry := artworkNextRetry[testSHA]
	uploaded := artworkUploaded[testSHA]
	artworkMu.Unlock()
	if hits.Load() != 0 || retry || uploaded {
		t.Fatalf("停推期间不传: hits=%d retry=%v uploaded=%v", hits.Load(), retry, uploaded)
	}
	setRelayQuotaPause(time.Time{})
	scheduleArtworkUpload(testSHA, path)
	waitArtworkIdle(t)
	artworkMu.Lock()
	uploaded = artworkUploaded[testSHA]
	artworkMu.Unlock()
	if hits.Load() == 0 || !uploaded {
		t.Fatalf("停推撤掉后照常传: hits=%d uploaded=%v", hits.Load(), uploaded)
	}
}

// 中继额度用完、停推期间不取 Top10 歌手榜,也不记这次检查;到点后的第一轮就推。
func TestTopArtistsDigestWaitsOutRelayQuota(t *testing.T) {
	t.Cleanup(func() { setRelayQuotaPause(time.Time{}) })
	useTopArtistSeams(t)
	f := useFakeLastfmRead(t, topArtistsRoute(3))
	relay, sink := newRelaySink(t, http.StatusOK)
	p := &poller{topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
	now := time.Now()
	setRelayQuotaPause(now.Add(time.Hour))
	p.topArtistsDigest(now, topArtistsEnv(relay.URL))
	if f.count() != 0 || len(sink.bodies) != 0 || !p.topArtistsLastCheckedAt.IsZero() {
		t.Fatalf("停推期间不取榜、不推、不记检查: fetch=%d push=%d checked=%v", f.count(), len(sink.bodies), p.topArtistsLastCheckedAt)
	}
	setRelayQuotaPause(time.Time{})
	p.topArtistsDigest(now.Add(time.Hour), topArtistsEnv(relay.URL))
	if f.count() != 1 || len(sink.bodies) != 1 {
		t.Fatalf("到点就推: fetch=%d push=%d", f.count(), len(sink.bodies))
	}
}

// /top-artists 收到额度用完:交回主循环停推到 UTC 0 点(状态文件、封面托管同 /push 撞上时),这次检查不算;
// 主循环接手之前和停推期间都不再取榜。普通失败不停推。
func TestTopArtistsQuotaHitPausesRelay(t *testing.T) {
	statusPath := useRelayStatusPathForTest(t)
	t.Cleanup(func() { setRelayQuotaPause(time.Time{}) })
	useTopArtistSeams(t)
	f := useFakeLastfmRead(t, topArtistsRoute(3))
	status, body := http.StatusServiceUnavailable, relayQuotaBody
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	env := topArtistsEnv(srv.URL)
	p := &poller{ctx: context.Background(), cfg: env.cfg, relayDoneCh: make(chan relayPushResult, 4),
		topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
	now := time.Now()
	p.topArtistsDigest(now, env)
	if p.relayQuotaHitPending.Load() == nil || !p.topArtistsLastCheckedAt.IsZero() || p.topArtistsState.load() != 0 {
		t.Fatalf("额度用完交回主循环、这次检查不算: hit=%v checked=%v", p.relayQuotaHitPending.Load(), p.topArtistsLastCheckedAt)
	}
	p.topArtistsDigest(now.Add(time.Minute), env)
	if f.count() != 1 {
		t.Fatalf("主循环接手之前不再取榜: %d", f.count())
	}
	p.pushRelayState(now.Add(time.Minute), false)
	if want := relayQuotaResumeAt(now); !p.relayQuotaUntil.Equal(want) || !relayQuotaPaused(now.Add(time.Minute)) {
		t.Fatalf("主循环按 /push 同一套停推: until=%v want=%v", p.relayQuotaUntil, want)
	}
	if st, ok := readRelayStatusForTest(t, statusPath); !ok || st.Kind != relayFailQuota {
		t.Fatalf("设置页那条状态照写: %+v ok=%v", st, ok)
	}
	if p.relayQuotaHitPending.Load() != nil {
		t.Fatal("接手之后清掉")
	}
	p.topArtistsDigest(now.Add(2*time.Minute), env)
	if f.count() != 1 {
		t.Fatalf("停推期间不取榜: %d", f.count())
	}
	p.noteRelayQuotaHit(relayQuotaErr(), now)
	p.resetRelayPush()
	if p.relayQuotaHitPending.Load() != nil || p.relayQuotaPausedOrHit(now) {
		t.Fatal("改了中继地址或令牌:后台报来的额度用完一并作废")
	}

	q := &poller{cfg: env.cfg, topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
	setRelayQuotaPause(time.Time{})
	body = relayKVBusyBody
	q.topArtistsDigest(now, env)
	if q.relayQuotaHitPending.Load() != nil || q.topArtistsLastCheckedAt.IsZero() {
		t.Fatalf("普通 503 不停推,照旧等下个检查周期: hit=%v checked=%v", q.relayQuotaHitPending.Load(), q.topArtistsLastCheckedAt)
	}
}
