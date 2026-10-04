package main

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func withLfmRetryFile(t *testing.T) {
	t.Helper()
	saved := lfmRetryPath
	lfmRetryPath = filepath.Join(t.TempDir(), "lastfm-retry.json")
	t.Cleanup(func() { lfmRetryPath = saved })
}

var errDNS = &net.DNSError{Err: "no such host", Name: "ws.audioscrobbler.com"}

func TestLastfmResendSafe(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"DNS 失败:请求没离开本机", errDNS, true},
		{"限流 29:服务端明确没收", &lastfmAPIError{Code: 29}, true},
		{"凭据失效 9:服务端明确没收", &lastfmAPIError{Code: 9}, true},
		{"11 服务不可用:可能已落库", &lastfmAPIError{Code: 11}, false},
		{"16 暂时不可用:可能已落库", &lastfmAPIError{Code: 16}, false},
		{"accepted=0:看过内容并拒收", &lastfmIgnoredError{Method: "track.scrobble"}, false},
		{"超时:不知道收没收到", context.DeadlineExceeded, false},
	}
	for _, c := range cases {
		if got := lastfmResendSafe(c.err); got != c.want {
			t.Errorf("%s: lastfmResendSafe = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestEnqueueLastfmRetryOnlySafeAndOnce(t *testing.T) {
	withLfmRetryFile(t)
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{Timestamp: 100, Artist: "Prince", Title: "Controversy"})
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{Timestamp: 100, Artist: "Prince", Title: "Controversy"})
	enqueueLastfmRetryIfSafe(context.DeadlineExceeded, lfmRetryItem{Timestamp: 200, Artist: "x", Title: "timeout"})
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{Timestamp: 0, Artist: "x", Title: "no timestamp"})
	items := loadLfmRetryLocked()
	if len(items) != 1 || items[0].Title != "Controversy" || items[0].QueuedAt == 0 {
		t.Fatalf("queue = %+v, want only the one safe item, once", items)
	}
}

func TestProcessLfmRetry(t *testing.T) {
	withLfmRetryFile(t)
	now := time.Unix(1_800_000_000, 0)
	ts := now.Add(-time.Hour).Unix()
	old := now.Add(-backfillMaxAge - time.Hour).Unix()
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "u", Timestamp: old, Artist: "a", Title: "too-old"})
	for i, title := range []string{"ok", "ignored", "maybe-stored", "bad-params", "no-reply", "already-backfilled", "rate-limited", "after"} {
		enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "u", Timestamp: ts + int64(i), Artist: "a", Title: title})
	}

	var submitted, quarantined, asked []int64
	hooks := lfmRetryHooks{
		handled:    func() map[int64]bool { return map[int64]bool{ts + 5: true} },
		submitted:  func(t int64) error { submitted = append(submitted, t); return nil },
		quarantine: func(t int64) { quarantined = append(quarantined, t) },
	}
	results := map[string]error{
		"ok":           nil,
		"ignored":      &lastfmIgnoredError{Method: "track.scrobble"},
		"maybe-stored": &lastfmAPIError{Code: 16},
		"bad-params":   &lastfmAPIError{Code: 6},
		"no-reply":     context.DeadlineExceeded,
		"rate-limited": &lastfmAPIError{Code: 29},
		"after":        nil,
	}
	submit := func(ctx context.Context, it lfmRetryItem) error {
		asked = append(asked, it.Timestamp)
		return results[it.Title]
	}
	if got := processLfmRetry(context.Background(), now, "u", submit, hooks); got != 1 {
		t.Fatalf("sent = %d, want 1", got)
	}
	if !reflect.DeepEqual(submitted, []int64{ts}) {
		t.Fatalf("submitted = %v: only the success writes a receipt", submitted)
	}
	if !reflect.DeepEqual(quarantined, []int64{ts + 2, ts + 4}) {
		t.Fatalf("quarantined = %v: 16 and a timeout may have been stored", quarantined)
	}
	if !reflect.DeepEqual(asked, []int64{ts, ts + 1, ts + 2, ts + 3, ts + 4, ts + 6}) {
		t.Fatalf("asked = %v: already backfilled and too old are never sent, rate limit stops the round", asked)
	}
	var left []string
	for _, it := range loadLfmRetryLocked() {
		left = append(left, it.Title)
	}
	if !reflect.DeepEqual(left, []string{"rate-limited", "after"}) {
		t.Fatalf("left = %v, want the rate-limited one and everything after it", left)
	}

	results["rate-limited"] = nil
	asked = nil
	if got := processLfmRetry(context.Background(), now.Add(lfmRetryInterval), "u", submit, hooks); got != 2 {
		t.Fatalf("second round sent = %d, want 2", got)
	}
	if len(loadLfmRetryLocked()) != 0 {
		t.Fatal("queue should be empty after everything went through")
	}
}

func TestProcessLfmRetryKeepsQueueWhileOffline(t *testing.T) {
	withLfmRetryFile(t)
	now := time.Unix(1_800_000_000, 0)
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "u", Timestamp: now.Add(-time.Minute).Unix(), Artist: "a", Title: "t1"})
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "u", Timestamp: now.Unix(), Artist: "a", Title: "t2"})
	calls := 0
	hooks := lfmRetryHooks{handled: func() map[int64]bool { return nil }, submitted: func(int64) error { return nil }, quarantine: func(int64) { t.Fatal("offline must not quarantine") }}
	processLfmRetry(context.Background(), now, "u", func(context.Context, lfmRetryItem) error {
		calls++
		return errors.Join(errDNS)
	}, hooks)
	if calls != 1 || len(loadLfmRetryLocked()) != 2 {
		t.Fatalf("calls = %d, left = %d: still offline → stop after the first, keep both", calls, len(loadLfmRetryLocked()))
	}
}

func TestProcessLfmRetryDropsAnotherAccountsListens(t *testing.T) {
	withLfmRetryFile(t)
	now := time.Unix(1_800_000_000, 0)
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "old", Timestamp: now.Unix(), Artist: "a", Title: "old account"})
	enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "new", Timestamp: now.Unix() + 1, Artist: "a", Title: "new account"})
	var asked []string
	hooks := lfmRetryHooks{handled: func() map[int64]bool { return nil }, submitted: func(int64) error { return nil }, quarantine: func(int64) {}}
	processLfmRetry(context.Background(), now, "new", func(_ context.Context, it lfmRetryItem) error {
		asked = append(asked, it.Title)
		return nil
	}, hooks)
	if !reflect.DeepEqual(asked, []string{"new account"}) || len(loadLfmRetryLocked()) != 0 {
		t.Fatalf("asked = %v: a listen queued under another account must be dropped, not scrobbled to this one", asked)
	}
}

func TestDisableLastfmOnFatal(t *testing.T) {
	saved := lastfmStatusPath
	lastfmStatusPath = filepath.Join(t.TempDir(), "lastfm-status.json")
	t.Cleanup(func() { lastfmStatusPath = saved })
	s := &lastfmScrobbler{}
	disableLastfmOnFatal(s, errDNS, time.Now())
	disableLastfmOnFatal(s, &lastfmAPIError{Code: 29}, time.Now())
	if s.dead.Load() {
		t.Fatal("network errors and rate limits must not disable the writer")
	}
	disableLastfmOnFatal(s, &lastfmAPIError{Code: 9, Message: "Invalid session key", Method: "track.scrobble"}, time.Now())
	if !s.dead.Load() {
		t.Fatal("error 9 during a retry should disable the writer like the live path does")
	}
	if _, err := os.Stat(lastfmStatusPath); err != nil {
		t.Fatalf("status file not written (App shows the red mark and the notification from it): %v", err)
	}
}
