package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// iTunes Search 的限流退避。靶的是一条性质:被 429/403 打过之后的一段时间里不再发请求,
// 而一次正常响应立刻把窗口清掉。
//
// 这个端点此前完全不受任何退避管辖(lyricSourceForHost 里没有 itunes.apple.com,
// observe 见到空源名直接 return),实测一份日志里 155346 次请求、52.6% 失败,
// 最近那段 429 有 655 次、403 有 546 次。

func resetITunesSearchBackoff(t *testing.T) {
	t.Helper()
	clear := func() {
		itunesSearchMu.Lock()
		itunesSearchCooldownUntil = time.Time{}
		itunesSearchCooldownLogged = false
		itunesSearchMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

func TestITunesSearchBackoff(t *testing.T) {
	base := time.Date(2026, 9, 20, 3, 0, 0, 0, time.UTC)

	t.Run("429 按 Retry-After 退避", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(429, "90", base)
		if !itunesSearchCoolingDown(base.Add(89 * time.Second)) {
			t.Error("Retry-After 给了 90 秒,第 89 秒还该在退避里")
		}
		if itunesSearchCoolingDown(base.Add(91 * time.Second)) {
			t.Error("第 91 秒该出退避了")
		}
	})

	t.Run("429 没给 Retry-After 用默认档", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(429, "", base)
		if !itunesSearchCoolingDown(base.Add(lyricSourceBreakerRetryAfterDefault - time.Second)) {
			t.Error("没给 Retry-After 时该退避默认时长")
		}
	})

	t.Run("离谱的 Retry-After 被封顶", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(429, "86400", base) // 一天
		if itunesSearchCoolingDown(base.Add(lyricSourceBreakerRetryAfterMax + time.Second)) {
			t.Errorf("Retry-After 再大也该封顶在 %s", lyricSourceBreakerRetryAfterMax)
		}
	})

	t.Run("403 用固定档", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(403, "", base)
		if !itunesSearchCoolingDown(base.Add(itunesSearchForbiddenCooldown - time.Second)) {
			t.Error("403 该退避 itunesSearchForbiddenCooldown")
		}
		if itunesSearchCoolingDown(base.Add(itunesSearchForbiddenCooldown + time.Second)) {
			t.Error("403 的固定档过了就该出退避")
		}
	})

	// 实测里 429 之后会紧跟一串 403(同一波限流的两种表现)。403 的固定档比 429 的
	// Retry-After 短,不能让它把更权威的窗口缩回去。
	t.Run("403 不缩短 429 已经定下的更长窗口", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(429, "300", base)
		noteITunesSearchStatus(403, "", base.Add(time.Second))
		if !itunesSearchCoolingDown(base.Add(200 * time.Second)) {
			t.Error("429 定的 300 秒窗口被随后的 403 缩短了")
		}
	})

	t.Run("一次正常响应立刻清掉窗口", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(429, "300", base)
		if !itunesSearchCoolingDown(base.Add(time.Second)) {
			t.Fatal("用例前提不成立:应该先进入退避")
		}
		noteITunesSearchStatus(200, "", base.Add(2*time.Second))
		if itunesSearchCoolingDown(base.Add(3 * time.Second)) {
			t.Error("拿到 200 之后该立刻退出退避 —— 跟 lyricSourceBreaker 的 default 分支同一条规矩")
		}
	})

	// 404/500 这类既不是限流、也不代表限流结束的状态码,走的是同一条 default:
	// 拿到了响应就说明还能通,不该留着退避窗口。
	t.Run("其它状态码同样清窗口", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		noteITunesSearchStatus(429, "300", base)
		noteITunesSearchStatus(404, "", base.Add(time.Second))
		if itunesSearchCoolingDown(base.Add(2 * time.Second)) {
			t.Error("404 也算拿到了响应,该清掉退避")
		}
	})

	t.Run("没被限流过就不退避", func(t *testing.T) {
		resetITunesSearchBackoff(t)
		if itunesSearchCoolingDown(base) {
			t.Error("初始状态不该在退避里")
		}
	})
}

// "itunes.apple.com 不该进歌词源熔断表"这条断言搬去了 sourcecoverage_test.go 的
// TestNonLyricAppleHostsStayUnmapped —— 那边一并覆盖 music.apple.com / mvod / mzstatic,
// 是这里原有那条的超集。
//
// 原来那条还顺手断言了 amp-api.music.apple.com 也不在表里,那是**写错的**:当时它
// 确实不在,但那是个缺口(applemusic 因此成了唯一从未被熔断过的歌词源),不是该锁住的
// 正确状态。现在它已经归进 applemusic,由 TestEveryLyricSourceHasAHostMapping 守着。

// 退避真正要管用的那一步:在冷却窗口里 itunesSearch **一个请求都不发**。
// 上面那些用例只覆盖两个纯函数,漏掉这一步的话整套退避就是摆设 —— 变异测试实测:
// 删掉 itunesSearch 开头那道检查,纯函数用例照样全绿。
func TestITunesSearchSkipsRequestWhileCoolingDown(t *testing.T) {
	resetITunesSearchBackoff(t)

	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[{"trackName":"x","trackViewUrl":"u","artistName":"a"}]}`))
	}))
	t.Cleanup(srv.Close)

	oldURL := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() { itunesSearchBaseURL = oldURL })

	ctx := context.Background()

	// 没退避时该真的发出去,并报告 reached。
	got, reached := itunesSearch(ctx, "q", "cn")
	if len(got) != 1 {
		t.Fatalf("正常情况下该拿到 1 条结果,得到 %d 条", len(got))
	}
	if !reached {
		t.Fatal("拿到 200 该报 reached=true")
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("该发出 1 次请求,实际 %d 次", n)
	}

	// 进入退避后,再调多少次都不该碰网络。
	noteITunesSearchStatus(429, "300", time.Now())
	for i := 0; i < 5; i++ {
		got, reached := itunesSearch(ctx, "q", "cn")
		if got != nil {
			t.Errorf("退避中该返回空,得到 %d 条", len(got))
		}
		// 退避中的空结果**不是**"Apple 没有这首歌" —— reached 必须为 false,
		// 否则 appleMusicMatchCached 会把限流期间的每首歌都错记进负缓存。
		if reached {
			t.Error("退避中该报 reached=false,空结果不代表 Apple 没有")
		}
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("退避中又发了请求:总计 %d 次,应该仍是 1 次", n)
	}

	// 窗口清掉之后恢复。
	noteITunesSearchStatus(200, "", time.Now())
	if got, reached := itunesSearch(ctx, "q", "cn"); len(got) != 1 || !reached {
		t.Errorf("退出退避后该恢复正常请求(得到 %d 条, reached=%v)", len(got), reached)
	}
	if n := atomic.LoadInt32(&hits); n != 2 {
		t.Fatalf("恢复后该再发 1 次(共 2 次),实际 %d 次", n)
	}
}

// 限流的响应必须**当场**报 reached=false。
//
// 这条看着跟上面重复,其实不是:多商店循环里第一个商店 429 之后会开启退避窗口,后续商店
// 因退避返回 false,于是整体 reached 仍是 false —— 变异测试实测,把这里改成谎报 true
// 时那些用例照样全绿(靠退避侥幸兜住了)。只有一个商店、或退避窗口恰好没生效时就会翻车,
// 所以在这一层直接钉死。
func TestITunesSearchReportsUnreachedOnRateLimit(t *testing.T) {
	resetITunesSearchBackoff(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	t.Cleanup(srv.Close)
	old := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() { itunesSearchBaseURL = old })

	got, reached := itunesSearch(context.Background(), "q", "cn")
	if got != nil {
		t.Errorf("限流时该返回空,得到 %d 条", len(got))
	}
	if reached {
		t.Error("429 必须报 reached=false —— 空结果不代表 Apple 没有这首歌")
	}
}
