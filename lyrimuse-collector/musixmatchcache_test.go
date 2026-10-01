package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func resetMusixmatchCacheForTest(t *testing.T) {
	t.Helper()
	savedResolve := musixmatchResolve
	musixmatchMu.Lock()
	savedCache := musixmatchCache
	musixmatchCache = map[string]musixmatchResult{}
	musixmatchMu.Unlock()
	t.Cleanup(func() {
		musixmatchResolve = savedResolve
		musixmatchMu.Lock()
		musixmatchCache = savedCache
		musixmatchMu.Unlock()
	})
}

// 子请求没问成(或 ctx 被取消)的结果不进缓存,下一次照样重新解析;完整的结果照旧缓存。
func TestMusixmatchCachesOnlyCompleteResults(t *testing.T) {
	resetMusixmatchCacheForTest(t)
	calls, failSub := 0, true
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		calls++
		if failSub {
			noteLyricSubFetchFailure(ctx)
		}
		return musixmatchResult{lrc: "[00:01.00]a"}
	}
	musixmatchLyric(context.Background(), "A", "T", 200, "", "")
	musixmatchLyric(context.Background(), "A", "T", 200, "", "")
	if calls != 2 {
		t.Fatalf("残缺结果不该进缓存: calls=%d", calls)
	}
	failSub = false
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	musixmatchLyric(ctx, "A", "T", 200, "", "")
	musixmatchLyric(context.Background(), "A", "T", 200, "", "")
	if calls != 4 {
		t.Fatalf("ctx 被取消的那一次也不该进缓存: calls=%d", calls)
	}
	musixmatchLyric(context.Background(), "A", "T", 200, "", "")
	if calls != 4 {
		t.Fatalf("完整的结果应当命中缓存: calls=%d", calls)
	}
}

// 逐字 / 译文子请求:没问成(传输错、限流)记失败;404 是「这首没有」,不记。
func TestMusixmatchSubRequestsReportFailures(t *testing.T) {
	var status map[string]string
	var lastT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		action := strings.TrimPrefix(r.URL.Path, "/")
		lastT = r.URL.Query().Get("t")
		code := status[action]
		if code == "" {
			code = "200"
		}
		w.Write([]byte(`{"message":{"header":{"status_code":` + code + `},"body":{}}}`))
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
	})

	cases := []struct {
		name   string
		status map[string]string
		failed bool
	}{
		{"逐字 401", map[string]string{"track.richsync.get": "401"}, true},
		{"逐字 404", map[string]string{"track.richsync.get": "404"}, false},
		{"译文 401", map[string]string{"crowd.track.translations.get": "401"}, true},
		{"都正常", nil, false},
	}
	for _, c := range cases {
		status = c.status
		ctx, f := withLyricSubFetch(context.Background())
		musixmatchRichsync(ctx, 1)
		musixmatchTranslationLRC(ctx, 1, "[00:01.00]a\n[00:02.00]b\n[00:03.00]c", "zh")
		if got := f.failed.Load(); got != c.failed {
			t.Errorf("%s: failed = %v, want %v", c.name, got, c.failed)
		}
	}
	if len(lastT) > 11 {
		t.Errorf("t 参数应当取到秒: %q", lastT)
	}
	if !musixmatchSawSuccessNow() {
		t.Error("答过 200 之后应当记下成功")
	}
}

// 译文挑选:逐字相等优先,子串匹配要够长。
func TestMusixmatchTranslationPrefersExactLine(t *testing.T) {
	item := func(line, tr string) musixmatchTranslationItem {
		var it musixmatchTranslationItem
		it.Translation.SubtitleMatchedLine, it.Translation.Description = line, tr
		return it
	}
	items := []musixmatchTranslationItem{
		item("I love you", "我爱你"),
		item("I love you baby", "我爱你宝贝"),
		item("Oh my god", "天哪"),
	}
	cases := map[string]string{
		"I love you baby": "我爱你宝贝",
		"I love you":      "我爱你",
		"Oh":              "",    // 太短的子串不算
		"I love you so":   "我爱你", // 10/13 ≥ 0.6
		"Oh my god!":      "天哪",
	}
	for text, want := range cases {
		if got := musixmatchTranslationFor(text, items); got != want {
			t.Errorf("musixmatchTranslationFor(%q) = %q, want %q", text, got, want)
		}
	}
}

// 搜索弹窗:这一轮 musixmatch 答过 200,就不把早先记下的失败原因报出来。
func TestMusixmatchFailureReasonSuppressedAfterSuccess(t *testing.T) {
	savedReason := musixmatchLastFailureReasonNow()
	savedOK := musixmatchAnySuccess.Load()
	t.Cleanup(func() {
		musixmatchSetLastFailureReason(savedReason)
		musixmatchAnySuccess.Store(savedOK)
	})
	musixmatchSetLastFailureReason("musixmatch_rate_limited")
	enabled := func(string) bool { return true }
	musixmatchAnySuccess.Store(false)
	if got := lyricSourceFailureReasonsWith(nil, nil, enabled, false)["musixmatch"]; got != "musixmatch_rate_limited" {
		t.Fatalf("没成功过时应当照报: %q", got)
	}
	musixmatchAnySuccess.Store(true)
	if got := lyricSourceFailureReasonsWith(nil, nil, enabled, false)["musixmatch"]; got == "musixmatch_rate_limited" {
		t.Fatalf("成功过之后不该再报早先的原因: %q", got)
	}
}

// 占位 token 当成没拿到:token.get 答了 200 也不缓存、不写盘;磁盘上存着的占位值也不读回来。
func TestMusixmatchPlaceholderTokenRejected(t *testing.T) {
	for tok, want := range map[string]bool{
		"UpgradeOnlyUpgradeOnlyUpgradeOnlyUpgradeOnly": true,
		"upgradeonly":                      true,
		"0000000000000000000000000000":     true,
		"a":                                true,
		"2203269256ff7abcacc6ca53a4a5d3ac": false,
	} {
		if got := musixmatchPlaceholderToken(tok); got != want {
			t.Errorf("musixmatchPlaceholderToken(%q) = %v, want %v", tok, got, want)
		}
	}
	t.Setenv("HOME", t.TempDir())
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"message":{"header":{"status_code":200},"body":{"user_token":"UpgradeOnlyUpgradeOnlyUpgradeOnlyUpgradeOnly"}}}`))
	}))
	defer srv.Close()
	savedBases := musixmatchBases
	musixmatchBases = []string{srv.URL + "/"}
	t.Cleanup(func() { musixmatchBases = savedBases })
	musixmatchTokenMu.Lock()
	savedTok, savedExp := musixmatchToken, musixmatchTokenExpiry
	musixmatchToken, musixmatchTokenExpiry = "", time.Time{}
	musixmatchTokenMu.Unlock()
	t.Cleanup(func() {
		musixmatchTokenMu.Lock()
		musixmatchToken, musixmatchTokenExpiry = savedTok, savedExp
		musixmatchTokenMu.Unlock()
	})
	if got := musixmatchFetchToken(context.Background(), 0); got != "" {
		t.Fatalf("占位 token 不该当成拿到了: %q", got)
	}
	if musixmatchCachedToken() != "" {
		t.Fatal("占位 token 不该进缓存")
	}
	if p := musixmatchTokenPath(); p != "" {
		os.MkdirAll(filepath.Dir(p), 0o700)
		os.WriteFile(p, []byte(`{"token":"UpgradeOnlyUpgradeOnly","expiry":`+strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)+`}`), 0o600)
		if got := musixmatchLoadTokenFile(); got != "" {
			t.Fatalf("磁盘上的占位 token 不该读回来: %q", got)
		}
	}
}
