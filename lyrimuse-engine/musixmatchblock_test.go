package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"sync/atomic"
	"testing"
	"time"
)

// 数据接口回反爬拦截(HTTP 200 + 401 hint=captcha):暂停这个源、记下失败原因;暂停期内一个请求都不发(token.get
// 也不发);到期后的试探答 200 就撤掉暂停、清掉失败原因。见 sourcebreaker.go「反爬拦截」。
func TestMusixmatchCaptchaPausesSource(t *testing.T) {
	var calls atomic.Int32
	var captcha atomic.Bool
	captcha.Store(true)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if captcha.Load() {
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
	b, clk := newTestBreaker()
	setSharedLyricSourceBreaker(b)
	t.Cleanup(func() { setSharedLyricSourceBreaker(prev) })

	ctx := context.Background()
	search := func() ([]byte, error) {
		return musixmatchDo(ctx, "track.search", neturl.Values{"q_track": {"Yesterday"}})
	}
	if body, err := search(); err != nil || !musixmatchBlockedByCaptcha(body) {
		t.Fatalf("第一次应当原样拿到拦截应答: %v %s", err, body)
	}
	if _, blocked := b.blockedFor("musixmatch"); !blocked {
		t.Fatal("被拦之后应当暂停这个源")
	}
	if r := musixmatchLastFailureReasonNow(); r != lyricFailureReasonMusixmatchRateLimited {
		t.Fatalf("失败原因 = %q, want %q", r, lyricFailureReasonMusixmatchRateLimited)
	}

	sent := calls.Load()
	if _, err := search(); !errors.Is(err, errMusixmatchBlocked) {
		t.Fatalf("暂停期内应直接返回 errMusixmatchBlocked,实际 %v", err)
	}
	if _, err := musixmatchDo(ctx, "token.get", neturl.Values{}); !errors.Is(err, errMusixmatchBlocked) {
		t.Fatalf("暂停期内 token.get 也不发,实际 %v", err)
	}
	if got := calls.Load(); got != sent {
		t.Fatalf("暂停期内发出了 %d 个请求", got-sent)
	}

	captcha.Store(false)
	clk.advance(15 * time.Minute)
	if body, err := search(); err != nil || musixmatchHeaderStatus(body) != 200 {
		t.Fatalf("到期后的试探应当发出去: %v %s", err, body)
	}
	if _, blocked := b.blockedFor("musixmatch"); blocked {
		t.Fatal("答了 200 应当撤掉暂停")
	}
	if r := musixmatchLastFailureReasonNow(); r != "" {
		t.Fatalf("答了 200 之后失败原因 = %q, want 空", r)
	}
}

func TestMusixmatchBlockedByCaptcha(t *testing.T) {
	cases := map[string]bool{
		`{"message":{"header":{"status_code":401,"hint":"captcha"}}}`: true,
		`{"message":{"header":{"status_code":401,"hint":"renew"}}}`:   false,
		`{"message":{"header":{"status_code":200}}}`:                  false,
		`not json`: false,
	}
	for body, want := range cases {
		if got := musixmatchBlockedByCaptcha([]byte(body)); got != want {
			t.Errorf("%s = %v, want %v", body, got, want)
		}
	}
}
