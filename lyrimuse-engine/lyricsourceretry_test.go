package main

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// 一次过载应答加它的重试只算熔断的一次失败:第一个请求(两次都 503)之后不冷却,第二个请求再失败才冷却。
func TestLRCLIBOverloadRetryCountsOnceInBreaker(t *testing.T) {
	withLRCLIBInstantPause(t)
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		return http.StatusServiceUnavailable, lrclibOverloaded, `{"statusCode":503,"name":"ServerOverloaded"}`
	})
	var out lrclibSearchItem
	lrclibRequest(qqRoundCtx(), "https://lrclib.net/api/get?artist_name=a&track_name=b", time.Second, &out)
	if _, cooling := sharedLyricSourceBreaker().coolingDown("lrclib"); cooling {
		t.Fatal("一个请求的 503 和它的重试只算一次失败,不该凑够跳闸")
	}
	lrclibRequest(qqRoundCtx(), "https://lrclib.net/api/search?q=b", time.Second, &out)
	if _, cooling := sharedLyricSourceBreaker().coolingDown("lrclib"); !cooling {
		t.Fatal("两个请求都过载应当冷却")
	}
}

func TestLyricSourceRetryForgiven(t *testing.T) {
	pending := withLyricSourceRetryPending(context.Background())
	for _, c := range []struct {
		ctx    context.Context
		status int
		ra     string
		want   bool
	}{
		{pending, 503, "1", true}, {pending, 429, "2", true}, {pending, 503, "3", false}, {pending, 503, "", false},
		{pending, 500, "1", false}, {pending, 200, "", false}, {context.Background(), 503, "1", false},
	} {
		if got := lyricSourceRetryForgiven(c.ctx, c.status, c.ra); got != c.want {
			t.Errorf("lyricSourceRetryForgiven(%d, %q) = %v, want %v", c.status, c.ra, got, c.want)
		}
	}
}

// 429 + Retry-After: 1 跟 503 一样等一下重发一次。
func TestLRCLIBRetriesShortRateLimit(t *testing.T) {
	waits := withLRCLIBInstantPause(t)
	calls := 0
	f := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		calls++
		if calls == 1 {
			return http.StatusTooManyRequests, lrclibOverloaded, `{}`
		}
		return http.StatusOK, nil, `{"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"` + lrclibSyncedFixture + `"}`
	})
	if r := resolveLRCLIBLyric(qqRoundCtx(), "Artist", "Song", "", 200); r.lyrics == "" {
		t.Fatalf("重发那次拿到了,应当用上: %+v", r)
	}
	if n := len(f.requests()); n != 2 || len(*waits) != 1 {
		t.Fatalf("应发两次、等一次: requests=%d waits=%v", n, *waits)
	}
}

// 后台请求重发前要等本地的后台暂停结束;暂停还要超过 lyricSourceShortRetryMax 时不重发。前台请求不受后台暂停影响。
func TestLRCLIBRetryWaitRespectsBackgroundPause(t *testing.T) {
	now := time.Date(2026, 10, 18, 3, 0, 0, 0, time.UTC)
	saved := sharedHostGuard()
	g := newHostGuard(func() time.Time { return now })
	setSharedHostGuard(g)
	t.Cleanup(func() { setSharedHostGuard(saved) })
	bg := withBackgroundOutbound(context.Background())

	if d, ok := lrclibRetryWait(bg, "lrclib.net", time.Second); !ok || d != time.Second {
		t.Fatalf("没在暂停:按 Retry-After 等,got %v %v", d, ok)
	}
	g.bgPause["lrclib.net"] = &lyricSourceBackgroundPause{until: now.Add(1500 * time.Millisecond)}
	if d, ok := lrclibRetryWait(bg, "lrclib.net", time.Second); !ok || d != 1510*time.Millisecond {
		t.Fatalf("暂停 1.5 秒:应等到暂停结束,got %v %v", d, ok)
	}
	if d, ok := lrclibRetryWait(context.Background(), "lrclib.net", time.Second); !ok || d != time.Second {
		t.Fatalf("前台请求不看后台暂停,got %v %v", d, ok)
	}
	g.bgPause["lrclib.net"] = &lyricSourceBackgroundPause{until: now.Add(4 * time.Second)}
	if _, ok := lrclibRetryWait(bg, "lrclib.net", time.Second); ok {
		t.Fatal("暂停还要 4 秒:不该重发")
	}
}

// 兜底的纯文本是在 search 被 503 打掉时退下来的:不缓存。请求都问成了(search 正常答空)时照常缓存。
func TestLRCLIBFallbackCachedOnlyWhenComplete(t *testing.T) {
	withLRCLIBInstantPause(t)
	for _, c := range []struct {
		name       string
		search     func() (int, http.Header, string)
		wantCached bool
	}{
		{"search 过载", func() (int, http.Header, string) { return http.StatusServiceUnavailable, lrclibOverloaded, `{}` }, false},
		{"search 答空", func() (int, http.Header, string) { return http.StatusOK, nil, `[]` }, true},
	} {
		withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
			if r.URL.Path == "/api/search" {
				return c.search()
			}
			return http.StatusOK, nil, `{"trackName":"Song","artistName":"Artist","duration":200,"plainLyrics":"a\nb"}`
		})
		r := lrclibLyric(qqRoundCtx(), "Artist", "Song", "Album", 200)
		if r.lyrics == "" || !r.plainOnly {
			t.Fatalf("%s: 应退回纯文本: %+v", c.name, r)
		}
		lrclibMu.Lock()
		_, cached := lrclibCache["Artist|Song|Album"]
		lrclibMu.Unlock()
		if cached != c.wantCached {
			t.Errorf("%s: 缓存了 = %v,期望 %v", c.name, cached, c.wantCached)
		}
	}
}

// 只剩 lyricSourceShortRetryMax 以内的限流窗口不整轮跳过;更长的照跳。
func TestPlanRoundKeepsShortRateLimit(t *testing.T) {
	now := time.Date(2026, 10, 18, 3, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		ra       string
		wantSkip bool
	}{
		{"1", false}, {"2", false}, {"30", true},
	} {
		b := newLyricSourceBreaker(func() time.Time { return now })
		b.observe("lrclib.net", nil, http.StatusTooManyRequests, c.ra)
		plan := b.planRound([]string{"lrclib", "qq"})
		if _, skip := plan["lrclib"]; skip != c.wantSkip {
			t.Errorf("Retry-After %s: 跳过 = %v,期望 %v", c.ra, skip, c.wantSkip)
		}
	}
}

// 本轮跳过名单:跳过的那一刻记下原因,先记的不被空原因盖掉;这一轮拿到过正常应答的不算没问到。
func TestLyricSourceRoundStatsSkips(t *testing.T) {
	_, r := withLyricSourceRound(context.Background())
	r.markSkippedBecause("lrclib", lyricSourceSkipReasonPaused)
	r.markSkipped("lrclib")
	r.markSkippedBecause("kuwo", lyricSourceSkipReasonQueued)
	r.markSkippedBecause("qq", lyricSourceCooldownReasonServerError)
	r.markReached("qq")
	got := r.statsSkips()
	if len(got) != 2 || got["lrclib"] != lyricSourceSkipReasonPaused || got["kuwo"] != lyricSourceSkipReasonQueued {
		t.Fatalf("statsSkips = %v", got)
	}
	if skipped := r.skippedSources(); len(skipped) != 3 {
		t.Fatalf("重试用的跳过名单不受影响,应仍是 3 个: %v", skipped)
	}
}

// 统计按本轮名单算:原因用记下的,本地排队那个源这一轮不算;没有本轮名单时退回按 SourcesSkipped、问熔断器。
func TestLyricSourceOutcomeUsesRoundSkips(t *testing.T) {
	all := func(string) bool { return true }
	breakerReason := func(string) string { return lyricSourceCooldownReasonServerError }
	d := &lyricsDecision{SourcesSkipped: []string{"lrclib", "kuwo", "qq"},
		statsSkips: map[string]string{"lrclib": lyricSourceSkipReasonPaused, "kuwo": lyricSourceSkipReasonQueued}}
	o := lyricSourceOutcomeFromDecision(d, all, all, breakerReason)
	if !o.skipped["lrclib"] || o.skipReason["lrclib"] != lyricSourceSkipReasonPaused {
		t.Errorf("lrclib 应按记下的原因算跳过: %v %v", o.skipped, o.skipReason)
	}
	if o.skipped["qq"] {
		t.Error("qq 这一轮问到过(不在本轮名单里),不算跳过")
	}
	for _, s := range o.enabled {
		if s == "kuwo" {
			t.Error("本地排队没问 kuwo,这一轮不算它")
		}
	}
	d.statsSkips = nil
	o = lyricSourceOutcomeFromDecision(d, all, all, breakerReason)
	if !o.skipped["qq"] || o.skipReason["qq"] != lyricSourceCooldownReasonServerError {
		t.Errorf("没有本轮名单:退回 SourcesSkipped + 熔断器原因: %v %v", o.skipped, o.skipReason)
	}
}
