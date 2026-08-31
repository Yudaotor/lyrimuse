package main

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 2026-08-24 用户报:批量解析(相册预取一次触发十几首歌同时解析)时 musixmatch 交出
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
