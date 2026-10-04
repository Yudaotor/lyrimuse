package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 现象是:批量解析(相册预取一次触发十几首歌同时解析)时 musixmatch 交出
// 候选的比例只有 20% 上下,而单首/大规模扫描能到 65%~90%。量出来的根因:原来
// musixmatchEnsureToken 判定"没有可用 token"之后,并发的每个 goroutine 各自去发一次
// token.get——apic 那台机器实测把除第一个之外的并发请求全按反爬拒掉(401
// hint=captcha),被拒的按官方样例退避 10 秒重试一次,但 20 秒的搜索预算扛不住 N 个
// goroutine 各跑一遍"发请求→等 10 秒→重试"。
//
// 这条测试验证修法本身(单飞锁),不碰网络——用 musixmatchDoFetchToken 这个缝把"真的
// 换 token"换成一个只计次的桩,断言 16 个并发调用只触发 1 次。
func TestMusixmatchEnsureTokenSingleFlight(t *testing.T) {
	// 让 musixmatchLoadTokenFile 读不到东西:musixmatchTokenPath 经 os.UserHomeDir()
	// 落在 $HOME 下,重定向到一个空的临时目录,避免测试跟这台机器真实缓存的 token
	// 文件产生耦合(那份文件是否已过期取决于运行测试的具体时刻,不可控)。
	t.Setenv("HOME", t.TempDir())

	musixmatchTokenMu.Lock()
	musixmatchToken = ""
	musixmatchTokenExpiry = time.Time{}
	musixmatchTokenMu.Unlock()

	orig := musixmatchDoFetchToken
	defer func() { musixmatchDoFetchToken = orig }()

	var calls int32
	musixmatchDoFetchToken = func(ctx context.Context) string {
		atomic.AddInt32(&calls, 1)
		// 拉开一点并发窗口,模拟真实网络请求的耗时——没有这个睡眠,16 个 goroutine
		// 可能因为调度巧合从未真正并发地撞上单飞锁,测试会在锁没生效时也碰巧通过。
		time.Sleep(30 * time.Millisecond)
		musixmatchTokenMu.Lock()
		musixmatchToken = "tok-A"
		musixmatchTokenExpiry = time.Now().Add(9 * time.Minute)
		musixmatchTokenMu.Unlock()
		return "tok-A"
	}

	const n = 16
	var wg sync.WaitGroup
	results := make([]string, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i] = musixmatchEnsureToken(context.Background())
		}(i)
	}
	wg.Wait()

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("单飞失效: %d 个并发调用触发了 %d 次真实换 token(应为 1)", n, got)
	}
	for i, r := range results {
		if r != "tok-A" {
			t.Errorf("goroutine %d 拿到的 token 不对: 实际 %q,期望 %q", i, r, "tok-A")
		}
	}
}

// 已有有效 token 时,并发调用应该完全绕开单飞锁和 musixmatchDoFetchToken——它只在
// 真的需要刷新时才有意义,不该让"读一个还没过期的值"也去排队。
func TestMusixmatchEnsureTokenSkipsFetchWhenCached(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	musixmatchTokenMu.Lock()
	musixmatchToken = "tok-fresh"
	musixmatchTokenExpiry = time.Now().Add(5 * time.Minute)
	musixmatchTokenMu.Unlock()

	orig := musixmatchDoFetchToken
	defer func() { musixmatchDoFetchToken = orig }()
	musixmatchDoFetchToken = func(ctx context.Context) string {
		t.Error("token 仍在有效期内,不该去真的换")
		return "should-not-happen"
	}

	const n = 8
	var wg sync.WaitGroup
	results := make([]string, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i] = musixmatchEnsureToken(context.Background())
		}(i)
	}
	wg.Wait()

	for i, r := range results {
		if r != "tok-fresh" {
			t.Errorf("goroutine %d 拿到的 token 不对: 实际 %q,期望 %q", i, r, "tok-fresh")
		}
	}
}

// 过期后单飞锁必须能再次刷新——不能因为"锁曾经被用过一次"就死锁或者永远返回旧值。
func TestMusixmatchEnsureTokenRefreshesAfterExpiry(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	musixmatchTokenMu.Lock()
	musixmatchToken = "tok-old"
	musixmatchTokenExpiry = time.Now().Add(-time.Second) // 已过期
	musixmatchTokenMu.Unlock()

	orig := musixmatchDoFetchToken
	defer func() { musixmatchDoFetchToken = orig }()
	var calls int32
	musixmatchDoFetchToken = func(ctx context.Context) string {
		atomic.AddInt32(&calls, 1)
		musixmatchTokenMu.Lock()
		musixmatchToken = "tok-new"
		musixmatchTokenExpiry = time.Now().Add(9 * time.Minute)
		musixmatchTokenMu.Unlock()
		return "tok-new"
	}

	if got := musixmatchEnsureToken(context.Background()); got != "tok-new" {
		t.Fatalf("过期后应该换到新 token,实际 %q", got)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("应该真的换了一次,实际触发 %d 次", got)
	}
	// 再调一次:新 token 还在有效期内,不该再触发一次刷新。
	if got := musixmatchEnsureToken(context.Background()); got != "tok-new" {
		t.Fatalf("第二次调用应该复用新 token,实际 %q", got)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("第二次调用不该再触发刷新,累计应仍为 1,实际 %d", got)
	}
}

func resetMusixmatchTokenStateForTest(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	reset := func() {
		musixmatchTokenMu.Lock()
		musixmatchToken, musixmatchTokenExpiry = "", time.Time{}
		musixmatchLastToken, musixmatchLastTokenAt = "", time.Time{}
		musixmatchFetchFailedAt = time.Time{}
		musixmatchTokenMu.Unlock()
	}
	reset()
	orig := musixmatchDoFetchToken
	t.Cleanup(func() {
		musixmatchDoFetchToken = orig
		reset()
	})
}

// token.get 要不到时退回上一个 token,并在冷却期内不再去要。
func TestMusixmatchEnsureTokenFallsBackToPreviousToken(t *testing.T) {
	resetMusixmatchTokenStateForTest(t)
	musixmatchTokenMu.Lock()
	musixmatchToken, musixmatchTokenExpiry = "tok-prev", time.Now().Add(-time.Minute)
	musixmatchLastToken, musixmatchLastTokenAt = "tok-prev", time.Now().Add(-30*time.Minute)
	musixmatchTokenMu.Unlock()
	var calls int32
	musixmatchDoFetchToken = func(context.Context) string { atomic.AddInt32(&calls, 1); return "" }

	if got := musixmatchEnsureToken(context.Background()); got != "tok-prev" {
		t.Fatalf("要不到新 token 应退回上一个,实际 %q", got)
	}
	if got := musixmatchEnsureToken(context.Background()); got != "tok-prev" || atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("冷却期内不该再去要: got=%q calls=%d", got, atomic.LoadInt32(&calls))
	}

	// 已经过了新鲜期的照样退得回去:退路上限必须比新鲜期长。
	musixmatchTokenMu.Lock()
	musixmatchLastTokenAt = time.Now().Add(-musixmatchTokenFreshFor - time.Hour)
	musixmatchTokenMu.Unlock()
	if got := musixmatchEnsureToken(context.Background()); got != "tok-prev" {
		t.Fatalf("过了新鲜期 %s 的上一个 token 也该退得回去,实际 %q", musixmatchTokenFreshFor, got)
	}

	// 太旧的不用。
	musixmatchTokenMu.Lock()
	musixmatchLastTokenAt = time.Now().Add(-musixmatchStaleTokenMaxAge - time.Minute)
	musixmatchTokenMu.Unlock()
	if got := musixmatchEnsureToken(context.Background()); got != "" {
		t.Fatalf("超过 %s 的旧 token 不该再用,实际 %q", musixmatchStaleTokenMaxAge, got)
	}
}

// 过了有效期的磁盘 token 读回来记成「上一个」;数据接口说它失效(非 captcha 的 401)才丢,文件一起删。
func TestMusixmatchExpiredFileTokenIsKeptUntilRejected(t *testing.T) {
	resetMusixmatchTokenStateForTest(t)
	if err := os.MkdirAll(filepath.Dir(musixmatchTokenPath()), 0o755); err != nil {
		t.Fatal(err)
	}
	fetched := time.Now().Add(-musixmatchTokenFreshFor - 10*time.Minute)
	musixmatchSaveTokenFile("tok-file", fetched, fetched.Add(musixmatchTokenFreshFor))
	if got := musixmatchLoadTokenFile(); got != "" {
		t.Fatalf("过了有效期的不该当新鲜的用,实际 %q", got)
	}
	if got := musixmatchStaleToken(); got != "tok-file" {
		t.Fatalf("过了有效期的应记成上一个,实际 %q", got)
	}
	if musixmatchRejectsToken([]byte(`{"message":{"header":{"status_code":401,"hint":"captcha"}}}`)) {
		t.Fatal("captcha 是频率限制,不算 token 失效")
	}
	if !musixmatchRejectsToken([]byte(`{"message":{"header":{"status_code":401,"hint":"renew"}}}`)) {
		t.Fatal("非 captcha 的 401 算 token 失效")
	}
	musixmatchRejectToken("tok-file")
	if got := musixmatchStaleToken(); got != "" {
		t.Fatalf("被拒之后不该再用,实际 %q", got)
	}
	if _, err := os.Stat(musixmatchTokenPath()); !os.IsNotExist(err) {
		t.Fatalf("被拒的 token 文件应删掉: %v", err)
	}
}

// 没有这个字段的旧文件按 Expiry 往前推 9 分钟算拿到的时刻。
func TestMusixmatchTokenFileWithoutFetchedAt(t *testing.T) {
	resetMusixmatchTokenStateForTest(t)
	expiry := time.Now().Add(-time.Hour)
	raw, _ := json.Marshal(map[string]any{"token": "tok-legacy", "expiry": expiry.Unix()})
	if err := os.MkdirAll(filepath.Dir(musixmatchTokenPath()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(musixmatchTokenPath(), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	musixmatchLoadTokenFile()
	musixmatchTokenMu.Lock()
	at := musixmatchLastTokenAt
	musixmatchTokenMu.Unlock()
	if d := expiry.Add(-musixmatchLegacyTokenFreshFor).Sub(at); d > time.Second || d < -time.Second {
		t.Fatalf("拿到时刻 = %s, want %s", at, expiry.Add(-musixmatchLegacyTokenFreshFor))
	}
}
