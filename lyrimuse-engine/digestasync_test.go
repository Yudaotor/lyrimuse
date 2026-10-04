package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// 推送没成功不记「已推送」,下一次检查重推;推成功才记。
func TestCalendarDigestRetriesAfterFailedPush(t *testing.T) {
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC).Unix()
	lbSrv := lbStatsServer(t, &aug)
	var fail atomic.Bool
	fail.Store(true)
	var pushes atomic.Int32
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pushes.Add(1)
		if fail.Load() {
			w.WriteHeader(http.StatusInternalServerError)
		}
	}))
	t.Cleanup(sink.Close)
	p := lbOnlyPoller(lbSrv.URL, sink.URL, t.TempDir()+"/monthly.json")
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, time.Local)

	p.calendarDigest(now, p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, true, digestSourceListenBrainz)
	if pushes.Load() != 1 || p.monthlyRun.state.load() != "" {
		t.Fatalf("推送被拒时不该记已推送: pushes=%d state=%q", pushes.Load(), p.monthlyRun.state.load())
	}
	fail.Store(false)
	p.calendarDigest(now.Add(3*time.Hour), p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, true, digestSourceListenBrainz)
	if pushes.Load() != 2 || p.monthlyRun.state.load() != "2026-08" {
		t.Fatalf("下一次检查该重推并记下: pushes=%d state=%q", pushes.Load(), p.monthlyRun.state.load())
	}
}

// 报告任务在后台跑:主循环调 runDigestsAsync 立即返回;上一轮没跑完时再调不会另起一轮。
func TestRunDigestsAsyncDoesNotBlockAndNeverOverlaps(t *testing.T) {
	saved := features()
	f := saved
	f.MonthlyDigest, f.MonthlyDigestSource = true, digestSourceListenBrainz
	setFeatures(f)
	t.Cleanup(func() { setFeatures(saved) })

	release := make(chan struct{})
	var statsCalls atomic.Int32
	lbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		statsCalls.Add(1)
		<-release
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(lbSrv.Close)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	p := lbOnlyPoller(lbSrv.URL, "http://127.0.0.1:1/push", t.TempDir()+"/monthly.json")
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, time.Local)

	start := time.Now()
	p.runDigestsAsync(now)
	if d := time.Since(start); d > 200*time.Millisecond {
		t.Fatalf("runDigestsAsync 用了 %v,像是在主循环里同步取数", d)
	}
	deadline := time.Now().Add(2 * time.Second)
	for statsCalls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if statsCalls.Load() != 1 {
		t.Fatalf("后台那一轮应已发出取数请求, got %d", statsCalls.Load())
	}
	p.runDigestsAsync(now.Add(3 * time.Hour))
	time.Sleep(50 * time.Millisecond)
	if statsCalls.Load() != 1 {
		t.Fatalf("上一轮还在跑时不该另起一轮, got %d 次取数", statsCalls.Load())
	}
	close(release)
	deadline = time.Now().Add(2 * time.Second)
	for p.digestBusy.Load() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if p.digestBusy.Load() {
		t.Fatal("那一轮结束后应清掉 digestBusy")
	}
}
