package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// appleMusicMatchCached 的"查空负缓存"。
//
// 它原来只在查到时写缓存,于是 iTunes 里没有的歌每次调用都完整重跑一轮多商店搜索
// (appleStorefrontsFor 一次 2~4 个商店 + 按专辑名定位那一轮)。实测 42% 的曲目属于这一类,
// 而 enrich 主链路上就有两个调用点、专辑预取一次还要再带 11~30 首。

func resetAppleMatchCaches(t *testing.T) {
	t.Helper()
	clear := func() {
		appleURLMu.Lock()
		appleURLCache = map[string]appleMusicMatch{}
		appleURLMissUntil = map[string]time.Time{}
		appleURLMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

// 用一个假 iTunes 服务端数请求次数。返回值 hits 是累计请求数。
func withFakeITunes(t *testing.T, handler http.HandlerFunc) *int32 {
	t.Helper()
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		handler(w, r)
	}))
	t.Cleanup(srv.Close)
	old := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() { itunesSearchBaseURL = old })
	return &hits
}

// 查空之后,窗口内不再重跑那一轮多商店搜索。
func TestAppleMatchMissCachedAfterRealMiss(t *testing.T) {
	resetAppleMatchCaches(t)
	resetITunesSearchBackoff(t)
	hits := withFakeITunes(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[]}`)) // 真的问到了,Apple 确实没有
	})

	ctx := context.Background()
	appleMusicMatchCached(ctx, "查无此人", "查无此曲", "查无此辑")
	first := atomic.LoadInt32(hits)
	if first == 0 {
		t.Fatal("第一次该真的发请求")
	}
	for i := 0; i < 4; i++ {
		if m := appleMusicMatchCached(ctx, "查无此人", "查无此曲", "查无此辑"); m.url != "" {
			t.Fatal("负缓存窗口内不该凭空给出匹配")
		}
	}
	if n := atomic.LoadInt32(hits); n != first {
		t.Errorf("负缓存没生效:又发了 %d 次请求(总计 %d,应仍为 %d)", n-first, n, first)
	}
}

// ⚠️ 这条是整个改动的要害:被限流时的空结果**不能**被当成"Apple 没有这首歌"。
// iTunes Search 98.4% 的失败是 403/429,不做这道区分的话,一次限流会把那段时间里
// 解析过的每一首歌都错记进负缓存,窗口内连封面和跳转链接一起丢掉。
func TestAppleMatchRateLimitIsNotCachedAsMiss(t *testing.T) {
	resetAppleMatchCaches(t)
	resetITunesSearchBackoff(t)
	withFakeITunes(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests) // 限流,不是"没有这首歌"
	})

	ctx := context.Background()
	appleMusicMatchCached(ctx, "某歌手", "某首歌", "某专辑")

	key := "某歌手|某首歌|某专辑"
	if appleMatchInMissWindow(key, time.Now()) {
		t.Error("被限流不代表 Apple 没有这首歌,不该写进负缓存")
	}
}

// 传输失败(超时/DNS)同理 —— reached 为假就什么都不记。
func TestAppleMatchMissNotRecordedWhenUnreached(t *testing.T) {
	resetAppleMatchCaches(t)
	base := time.Date(2026, 9, 20, 5, 0, 0, 0, time.UTC)
	const key = "a|b|c"

	noteAppleMatchMiss(key, false, base)
	if appleMatchInMissWindow(key, base.Add(time.Second)) {
		t.Error("reached=false 时不该记负缓存")
	}
	noteAppleMatchMiss(key, true, base)
	if !appleMatchInMissWindow(key, base.Add(time.Second)) {
		t.Error("reached=true 的查空该记负缓存")
	}
	if appleMatchInMissWindow(key, base.Add(appleMatchMissTTL+time.Second)) {
		t.Error("TTL 过了就该重新开放查询")
	}
}

// 查到了要清掉这首歌之前的负缓存记录。
func TestAppleMatchHitClearsMiss(t *testing.T) {
	resetAppleMatchCaches(t)
	resetITunesSearchBackoff(t)
	const artist, title, album = "方大同", "三人游", "橙月"
	key := artist + "|" + title + "|" + album

	noteAppleMatchMiss(key, true, time.Now())
	if !appleMatchInMissWindow(key, time.Now()) {
		t.Fatal("用例前提不成立:该先进入负缓存")
	}

	withFakeITunes(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[{"trackName":"三人游","collectionName":"橙月",` +
			`"trackViewUrl":"https://music.apple.com/x","artworkUrl100":"https://i/100x100bb.jpg",` +
			`"artistName":"方大同","trackTimeMillis":200000}]}`))
	})

	// 先把窗口推到过去让这次查询能发出去 —— 但**不能**靠 appleMatchInMissWindow 来验
	// "清掉了没":窗口已经过期,删不删它都返回 false(变异测试实测:"查到后不 delete"
	// 这个变异能存活)。所以直接看 map 里那条记录还在不在。
	appleURLMu.Lock()
	appleURLMissUntil[key] = time.Now().Add(-time.Second)
	appleURLMu.Unlock()

	if m := appleMusicMatchCached(context.Background(), artist, title, album); m.url == "" {
		t.Fatal("该查到匹配")
	}
	appleURLMu.Lock()
	_, stillThere := appleURLMissUntil[key]
	appleURLMu.Unlock()
	if stillThere {
		t.Error("查到之后该把这首歌的负缓存记录删掉,而不是留一条过期的在 map 里")
	}
}

// ② reached 要求**每一个**商店都问成。只要有一个没问成,"Apple 没有这首歌"就不成立 ——
// 那首歌可能恰好只在没问成的那个商店上架。
func TestAppleMatchPartialStorefrontFailureIsNotAMiss(t *testing.T) {
	resetAppleMatchCaches(t)
	resetITunesSearchBackoff(t)

	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 第一个商店正常回空,第二个商店超时/出错 —— 用 500 模拟"没问成"。
		if atomic.AddInt32(&n, 1) == 1 {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"results":[]}`))
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	old := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() { itunesSearchBaseURL = old })

	// ⚠️ album 必须传空:album 非空时还会跑 resolveAppleMusicMatchViaAlbum,那条路径自己
	// 也算一遍 reached,会把 searchAppleMusicMatch 这一层的缺陷盖住 —— 变异测试实测,
	// 带专辑名时"只要一个商店成功就算 reached"这个变异能存活。空 album 让 viaAlbum 直接
	// 早退,这一层的判定才暴露出来。
	appleMusicMatchCached(context.Background(), "某歌手", "某首歌", "")
	if atomic.LoadInt32(&n) < 2 {
		t.Skipf("用例前提不成立:只问了 %d 个商店,拿不到部分失败的形态", n)
	}
	if appleMatchInMissWindow("某歌手|某首歌|", time.Now()) {
		t.Error("有商店没问成时不该判定「Apple 没有这首歌」")
	}
}
