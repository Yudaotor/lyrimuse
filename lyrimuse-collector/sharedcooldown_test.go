package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func withSharedCooldownFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "lyrimuse-outbound-cooldowns.json")
	setSharedCooldownPath(path)
	t.Cleanup(func() { setSharedCooldownPath("") })
	return path
}

func TestMergeSharedCooldown(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	existing := map[string]float64{"old": 999_000, "keep": 1_000_500, "k": 1_000_300}
	got := mergeSharedCooldown(existing, "k", now.Add(100*time.Second), now)
	if _, ok := got["old"]; ok {
		t.Error("过期的条目该清掉")
	}
	if got["keep"] != 1_000_500 {
		t.Error("没过期的别的条目该留着")
	}
	if got["k"] != 1_000_300 {
		t.Errorf("已有更晚的截止时刻不该被缩短: %v", got["k"])
	}
	got = mergeSharedCooldown(existing, "k", now.Add(900*time.Second), now)
	if got["k"] != 1_000_900 {
		t.Errorf("更晚的截止时刻该覆盖: %v", got["k"])
	}
}

// 写进去的窗口能读回来;不在共享名单里的主机不写;共享没开时什么都不做。
func TestPublishSharedCooldownRoundTrip(t *testing.T) {
	path := withSharedCooldownFile(t)
	until := time.Now().Add(time.Minute)
	publishSharedCooldown("itunes.apple.com", sharedCooldownITunesSearch, until)
	publishSharedCooldown("api.example.org", "api.example.org/x", until)

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f sharedCooldownFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Endpoints) != 1 {
		t.Fatalf("只该写共享名单里的主机: %v", f.Endpoints)
	}
	if got := sharedCooldownUntil(sharedCooldownITunesSearch, time.Now()); got.IsZero() {
		t.Fatal("写进去的窗口该读得回来")
	}
	if got := sharedCooldownUntil(sharedCooldownITunesSearch, until.Add(time.Second)); !got.IsZero() {
		t.Fatal("过期了就不算")
	}

	setSharedCooldownPath("")
	publishSharedCooldown("itunes.apple.com", sharedCooldownITunesSearch, until)
	if got := sharedCooldownUntil(sharedCooldownITunesSearch, time.Now()); !got.IsZero() {
		t.Fatal("共享关着时不该读到东西")
	}
}

// App 那边写进来的窗口,collector 的出站闸要认:iTunes 搜索、Last.fm 读接口都停,别的主机不受影响。
func TestHostGuardHonorsSharedCooldownWrittenByApp(t *testing.T) {
	path := withSharedCooldownFile(t)
	until := float64(time.Now().Add(time.Minute).UnixNano()) / float64(time.Second)
	data, _ := json.Marshal(sharedCooldownFile{Endpoints: map[string]float64{
		sharedCooldownITunesSearch: until,
		sharedCooldownLastfm:       until,
	}})
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	g, _ := newTestGuard(hostRate{perSec: 100, burst: 100})
	for _, raw := range []string{
		"https://itunes.apple.com/search?term=x",
		"https://ws.audioscrobbler.com/2.0/?method=track.getInfo",
	} {
		if err := g.admit(mustReq(t, context.Background(), http.MethodGet, raw)); !errors.Is(err, errHostGuarded) {
			t.Errorf("%s 该被共享窗口拦下: %v", raw, err)
		}
	}
	if err := g.admit(mustReq(t, context.Background(), http.MethodGet, "https://itunes.apple.com/lookup?id=1")); err != nil {
		t.Errorf("同主机别的端点不受影响: %v", err)
	}
}

// collector 这边撞到的限流写进共享文件,App 才看得见。
func TestCollectorPublishesItsRateLimitWindows(t *testing.T) {
	withSharedCooldownFile(t)
	savedGuard := hostGuardShared
	hostGuardShared = newHostGuard(time.Now)
	t.Cleanup(func() { hostGuardShared = savedGuard })
	resetITunesSearchBackoff(t)

	req := mustReq(t, context.Background(), http.MethodGet, "https://ws.audioscrobbler.com/2.0/?method=track.getInfo")
	hostGuardShared.observe(req, http.StatusTooManyRequests, "60")
	if got := sharedCooldownUntil(sharedCooldownLastfm, time.Now()); got.IsZero() {
		t.Error("Last.fm 的 429 窗口该写进共享文件")
	}

	noteITunesSearchStatus(http.StatusForbidden, "", time.Now())
	if got := sharedCooldownUntil(sharedCooldownITunesSearch, time.Now()); got.IsZero() {
		t.Error("iTunes 搜索的退避该写进共享文件")
	}
}
