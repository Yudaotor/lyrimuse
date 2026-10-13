package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// resetSodaPreviewSearch 换上假的搜索、清掉搜索结果缓存,测试结束时还原。
func resetSodaPreviewSearch(t *testing.T, fn func(ctx context.Context, artist, title, album string, mr float64) (sodaPreview, bool)) {
	t.Helper()
	clear := func() {
		sodaPreviewMu.Lock()
		sodaPreviewCache = map[string]sodaPreviewCacheEntry{}
		sodaPreviewInflight = map[string]bool{}
		sodaPreviewMu.Unlock()
	}
	clear()
	old := sodaPreviewSearchFn
	sodaPreviewSearchFn = fn
	t.Cleanup(func() {
		sodaPreviewSearchFn = old
		clear()
	})
}

// waitSodaPreviewSearched 等后台那次搜索落进缓存,返回这一条。
func waitSodaPreviewSearched(t *testing.T, key string) sodaPreviewCacheEntry {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		sodaPreviewMu.Lock()
		e, ok := sodaPreviewCache[key]
		inflight := sodaPreviewInflight[key]
		sodaPreviewMu.Unlock()
		if ok && !inflight {
			return e
		}
		if time.Now().After(deadline) {
			t.Fatal("后台搜索没有落进缓存")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// ageSodaPreviewEntry 把缓存里这一条的搜索时刻往前拨。
func ageSodaPreviewEntry(key string, d time.Duration) {
	sodaPreviewMu.Lock()
	e := sodaPreviewCache[key]
	e.at = time.Now().Add(-d)
	sodaPreviewCache[key] = e
	sodaPreviewMu.Unlock()
}

func TestSodaPreviewRetryAfter(t *testing.T) {
	cases := []struct {
		misses int
		want   time.Duration
	}{{1, 5 * time.Second}, {2, 15 * time.Second}, {3, sodaPreviewNegativeTTL}, {9, sodaPreviewNegativeTTL}}
	for _, c := range cases {
		if got := sodaPreviewRetryAfter(c.misses); got != c.want {
			t.Errorf("没搜到 %d 次之后隔 %v 再搜,want %v", c.misses, got, c.want)
		}
	}
}

// 搜索没搜到:隔 5 秒、再隔 15 秒各再搜一次,第三次还没有才等 10 分钟;隔了 10 分钟以上再搜的从头数。
func TestSodaPreviewSearchRetriesSoonAfterMiss(t *testing.T) {
	calls := 0
	resetSodaPreviewSearch(t, func(context.Context, string, string, string, float64) (sodaPreview, bool) {
		calls++
		return sodaPreview{}, false
	})
	key := normLoose("方大同") + "|" + normLoose("南音")
	ask := func() {
		if _, ok := sodaPreviewFor("方大同", "南音", "Soulboy", 30, nil); ok {
			t.Fatal("搜索没搜到,不该报找到")
		}
	}
	ask()
	if e := waitSodaPreviewSearched(t, key); e.misses != 1 || calls != 1 {
		t.Fatalf("第一次没搜到: misses=%d calls=%d", e.misses, calls)
	}
	ask()
	if calls != 1 {
		t.Fatalf("刚没搜到,5 秒之内不再搜: calls=%d", calls)
	}
	ageSodaPreviewEntry(key, 6*time.Second)
	ask()
	if e := waitSodaPreviewSearched(t, key); e.misses != 2 || calls != 2 {
		t.Fatalf("过了 5 秒再搜一次: misses=%d calls=%d", e.misses, calls)
	}
	ageSodaPreviewEntry(key, 10*time.Second)
	ask()
	if calls != 2 {
		t.Fatalf("第二次没搜到之后要隔 15 秒: calls=%d", calls)
	}
	ageSodaPreviewEntry(key, 16*time.Second)
	ask()
	if e := waitSodaPreviewSearched(t, key); e.misses != 3 || calls != 3 {
		t.Fatalf("过了 15 秒再搜一次: misses=%d calls=%d", e.misses, calls)
	}
	ageSodaPreviewEntry(key, 5*time.Minute)
	ask()
	if calls != 3 {
		t.Fatalf("连着三次没搜到,10 分钟之内不再搜: calls=%d", calls)
	}
	ageSodaPreviewEntry(key, sodaPreviewNegativeTTL+time.Second)
	ask()
	if e := waitSodaPreviewSearched(t, key); e.misses != 1 || calls != 4 {
		t.Fatalf("隔了 10 分钟再搜,没搜到从头数: misses=%d calls=%d", e.misses, calls)
	}
}

// 报的是试听段的长度(30 / 60 秒)、试听段又没查到:一直算没结论;本机缓存说这首整首就这么长才放行。别的短时长只在搜索在途时算。
func TestSodaPreviewLookupPendingHoldsPreviewLengths(t *testing.T) {
	resetSodaLocalIndex(t, writeTestSodaQueue(t, []map[string]any{{
		"id": "7", "name": "前奏", "duration": 30000,
		"artists": []map[string]any{{"id": "1", "name": "方大同"}}, "album": map[string]any{"id": "2", "name": "橙月"},
	}}))
	db := filepath.Join(t.TempDir(), "entries.db")
	if err := os.WriteFile(db, testSodaPreviewRecord("8", "间奏", "方大同", 60000, 0, 60000), 0o644); err != nil {
		t.Fatal(err)
	}
	old := sodaPreloadOverride
	sodaPreloadOverride = db
	resetPreloadIndex := func() {
		sodaPreloadIndexMu.Lock()
		sodaPreloadIndexMod, sodaPreloadIndexSize, sodaPreloadIndexTrack = time.Time{}, 0, nil
		sodaPreloadIndexMu.Unlock()
	}
	resetPreloadIndex()
	t.Cleanup(func() {
		sodaPreloadOverride = old
		resetPreloadIndex()
	})
	resetSodaPreviewSearch(t, nil)

	cases := []struct {
		title string
		dur   float64
		want  bool
	}{
		{"南音", 30, true},
		{"南音", 29.0, true},
		{"南音", 60.001, true},
		{"南音", 45, false},
		{"南音", 200, false},
		{"前奏", 30, false}, // 队列缓存里整首 30 秒
		{"间奏", 60, false}, // 音频缓存库里整首 60 秒
		{"间奏", 30, true},  // 整首 60 秒,报 30 秒对不上
	}
	for _, c := range cases {
		if got := sodaPreviewLookupPending("方大同", c.title, c.dur); got != c.want {
			t.Errorf("%s 报 %v 秒: pending=%v want %v", c.title, c.dur, got, c.want)
		}
	}
	sodaPreviewMu.Lock()
	sodaPreviewInflight[normLoose("方大同")+"|"+normLoose("南音")] = true
	sodaPreviewMu.Unlock()
	if !sodaPreviewLookupPending("方大同", "南音", 45) {
		t.Error("搜索在途时什么时长都算没结论")
	}
}

func sodaPreviewTick(pos float64, at time.Time, pending bool) snapshot {
	return snapshot{Title: "南音", Artist: "方大同", Album: "Soulboy", Bundle: sodaMusicBundleID, Duration: 30,
		Playing: true, Rate: 1, Position: pos, AnchorTS: at, SodaPreviewPending: pending}
}

// 试听段一直没结论:放满 30 秒、换歌收尾都不提交收听;中途有了结论(这首整首就 30 秒)照常提交。
func TestHandleSodaPreviewPendingWithholdsListen(t *testing.T) {
	at := handleClock()
	next := handleSong("十年", 0, at(40))
	p := handleTestPoller(t, sodaPreviewTick(0, at(0), true), next)
	for s := 0; s <= 30; s += 5 {
		handleTick(p, at(s), sodaPreviewTick(float64(s), at(s), true))
	}
	first := p.sess
	if first.submitting || len(p.submitsInflight) != 0 {
		t.Fatalf("没结论时过了半程也不提交: submitting=%v inflight=%d played=%v", first.submitting, len(p.submitsInflight), first.playedSecs)
	}
	handleTick(p, at(40), next)
	if !first.ended || first.submitting || len(p.submitsInflight) != 0 {
		t.Fatalf("换歌收尾也不提交: ended=%v submitting=%v inflight=%d", first.ended, first.submitting, len(p.submitsInflight))
	}

	q := handleTestPoller(t, sodaPreviewTick(0, at(0), true))
	for s := 0; s <= 25; s += 5 {
		handleTick(q, at(s), sodaPreviewTick(float64(s), at(s), s < 10))
	}
	if !q.sess.submitting && len(q.submitsInflight) == 0 {
		t.Fatalf("有了结论之后照常提交: played=%v pending=%v", q.sess.playedSecs, q.sess.sodaPreviewPending)
	}
}

// 搜索落空之后:报 30 秒的这一拍仍算没结论(不建条目、不记收听),报整首的照常。
func TestLiveAppSodaPreviewPendingAfterMiss(t *testing.T) {
	resetSodaPreviewSearch(t, func(context.Context, string, string, string, float64) (sodaPreview, bool) {
		return sodaPreview{}, false
	})
	liveAppSodaPreview(sodaMusicBundleID, "南音", "方大同", "Soulboy", 30)
	waitSodaPreviewSearched(t, normLoose("方大同")+"|"+normLoose("南音"))
	if _, _, known, pending := liveAppSodaPreview(sodaMusicBundleID, "南音", "方大同", "Soulboy", 30); known || !pending {
		t.Fatalf("搜索落空、报 30 秒: known=%v pending=%v", known, pending)
	}
	if _, _, known, pending := liveAppSodaPreview(sodaMusicBundleID, "南音", "方大同", "Soulboy", 200); known || pending {
		t.Fatalf("报整首: known=%v pending=%v", known, pending)
	}
}
