package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// iPhone 完成收听转发到 LB 在后台跑:LB 再慢,applyBridgeResult 也立刻返回;在飞期间不另起一轮;
// 结果回来才记进 forwarded。
func TestBridgeForwardDoesNotBlockMainLoop(t *testing.T) {
	withEnrichCache(t, nil)
	release := make(chan struct{})
	var hits atomic.Int32
	lbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		<-release
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(lbSrv.Close)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	dir := t.TempDir()
	now := time.Now()
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
	uts := now.Unix() - 60
	page := lastfmRecentPage{Done: []lastfmTrack{{Artist: "Crowd Lu", Title: "Boring", UTS: uts}}}

	start := time.Now()
	p.applyBridgeResult(bridgeFetchResult{now: now, ok: true, page: page})
	if d := time.Since(start); d > 300*time.Millisecond {
		t.Fatalf("applyBridgeResult 用了 %v,像是在主循环里同步提交", d)
	}
	if !p.bridgeForwarding || p.forwarded[uts] {
		t.Fatalf("应在后台转发中、还没记进 forwarded: forwarding=%v forwarded=%v", p.bridgeForwarding, p.forwarded[uts])
	}
	deadline := time.Now().Add(2 * time.Second)
	for hits.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	p.applyBridgeResult(bridgeFetchResult{now: now.Add(15 * time.Second), ok: true, page: page})
	time.Sleep(100 * time.Millisecond)
	if hits.Load() != 1 {
		t.Fatalf("在飞期间不该另起一轮, LB 收到 %d 次", hits.Load())
	}
	close(release)
	select {
	case r := <-p.bridgeForwardDoneCh:
		p.applyBridgeForwardResults(r)
	case <-time.After(3 * time.Second):
		t.Fatal("没收到后台结果")
	}
	if p.bridgeForwarding || !p.forwarded[uts] || p.lastListen.Title != "Boring" {
		t.Fatalf("结果回来后该记账: forwarding=%v forwarded=%v last=%q", p.bridgeForwarding, p.forwarded[uts], p.lastListen.Title)
	}
}

// 后台转发按顺序、瞬时失败就停;明确拒收的记进结果(之后不再试)。
func TestForwardBridgeListensStopsOnTransientFailure(t *testing.T) {
	var n atomic.Int32
	lbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 第 3 条两次尝试都 502(瞬时失败),之后的请求一律 200:没停下的话第 4 条会被送达。
		switch k := n.Add(1); {
		case k == 1:
			w.WriteHeader(http.StatusOK)
		case k == 2:
			w.WriteHeader(http.StatusBadRequest)
		case k <= 4:
			w.WriteHeader(http.StatusBadGateway)
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	t.Cleanup(lbSrv.Close)
	p := &poller{ctx: context.Background(), lb: &lbClient{root: lbSrv.URL, token: "t", hc: &http.Client{}},
		bridgeForwardDoneCh: make(chan []bridgeForwardResult, 1)}
	items := []bridgeForwardItem{
		{uts: 1, meta: lbTrackMeta{ArtistName: "a", TrackName: "1"}},
		{uts: 2, meta: lbTrackMeta{ArtistName: "a", TrackName: "2"}},
		{uts: 3, meta: lbTrackMeta{ArtistName: "a", TrackName: "3"}},
		{uts: 4, meta: lbTrackMeta{ArtistName: "a", TrackName: "4"}},
	}
	p.forwardBridgeListens(items)
	got := <-p.bridgeForwardDoneCh
	if len(got) != 2 || got[0].item.uts != 1 || got[0].rejected || got[1].item.uts != 2 || !got[1].rejected {
		t.Fatalf("第 1 条送达、第 2 条拒收、第 3 条瞬时失败就停: %+v", got)
	}
}

func withLBRetryFile(t *testing.T) {
	t.Helper()
	saved := lbRetryPath
	lbRetryPath = filepath.Join(t.TempDir(), "lb-retry.json")
	t.Cleanup(func() { lbRetryPath = saved })
}

// 待重发队列:同一条不重复入队;成功和明确拒收的移出,瞬时失败停下留到下一轮。
func TestLBRetryQueue(t *testing.T) {
	withLBRetryFile(t)
	enqueueLBRetry(100, lbTrackMeta{ArtistName: "Ariana Grande", TrackName: "west side"})
	enqueueLBRetry(100, lbTrackMeta{ArtistName: "Ariana Grande", TrackName: "west side"})
	enqueueLBRetry(200, lbTrackMeta{ArtistName: "方大同", TrackName: "夠不夠"})
	enqueueLBRetry(300, lbTrackMeta{ArtistName: "x", TrackName: "later"})
	enqueueLBRetry(400, lbTrackMeta{ArtistName: "y", TrackName: "after"})
	lbRetryMu.Lock()
	if n := len(loadLBRetryLocked()); n != 4 {
		lbRetryMu.Unlock()
		t.Fatalf("同一条不该重复入队, got %d", n)
	}
	lbRetryMu.Unlock()

	var seen []int64
	sent := processLBRetry(context.Background(), func(ctx context.Context, at int64, meta lbTrackMeta) error {
		seen = append(seen, at)
		switch at {
		case 100:
			return nil
		case 200:
			return fmt.Errorf("post single: 400: %w", errListenRejected)
		case 300:
			return errors.New("timeout")
		default:
			return nil // 瞬时失败之后就该停下,轮不到这条
		}
	})
	if sent != 1 || fmt.Sprint(seen) != "[100 200 300]" {
		t.Fatalf("按入队顺序各试一次: sent=%d seen=%v", sent, seen)
	}
	lbRetryMu.Lock()
	left := loadLBRetryLocked()
	lbRetryMu.Unlock()
	if len(left) != 2 || left[0].ListenedAt != 300 || left[1].ListenedAt != 400 {
		t.Fatalf("留下瞬时失败的那条和它后面没轮到的: %+v", left)
	}

	// 下一轮成功就清空,文件一并删掉。
	processLBRetry(context.Background(), func(ctx context.Context, at int64, meta lbTrackMeta) error { return nil })
	lbRetryMu.Lock()
	if n := len(loadLBRetryLocked()); n != 0 {
		lbRetryMu.Unlock()
		t.Fatalf("该清空, got %d", n)
	}
	lbRetryMu.Unlock()
}

// 会话已经结束时提交失败才入队;还在放的(会每拍重试)不入队;LB 明确拒收的不入队。
func TestApplySubmitOutcomeQueuesOnlyEndedSessions(t *testing.T) {
	withLBRetryFile(t)
	p := &poller{ctx: context.Background(), cfg: &config{}}
	meta := snapshot{Title: "west side", Artist: "Ariana Grande", Duration: 200}
	count := func() int {
		lbRetryMu.Lock()
		defer lbRetryMu.Unlock()
		return len(loadLBRetryLocked())
	}

	live := &playSession{meta: meta, lastfmSettled: true}
	p.applySubmitOutcome(submitOutcome{sess: live, meta: meta, startedAt: 1000, err: errors.New("timeout")})
	if count() != 0 {
		t.Fatal("还在放的会话失败不入队(播放中每拍会重试)")
	}
	ended := &playSession{meta: meta, lastfmSettled: true, ended: true}
	p.applySubmitOutcome(submitOutcome{sess: ended, meta: meta, startedAt: 1000, err: fmt.Errorf("post single: 400: %w", errListenRejected)})
	if count() != 0 {
		t.Fatal("LB 明确拒收的不入队")
	}
	p.applySubmitOutcome(submitOutcome{sess: ended, meta: meta, startedAt: 1000, err: errors.New("timeout")})
	if count() != 1 {
		t.Fatal("会话已结束时的瞬时失败要入队")
	}
}
