package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 里层 round 连上过哪个源要传到外层(补空扫描靠外层判断这一条是不是断网);跳过记录不往上传。
func TestLyricSourceRoundReachedPropagatesToParent(t *testing.T) {
	outerCtx, outer := withLyricSourceRound(context.Background())
	_, inner := withLyricSourceRound(outerCtx)
	if outer.reachedAny() || inner.reachedAny() {
		t.Fatal("还没连上任何源")
	}
	inner.markSkipped("qq")
	if got := outer.skippedSources(); len(got) != 0 {
		t.Fatalf("跳过记录不该传到外层: %v", got)
	}
	inner.markReached("netease")
	if !inner.reachedAny() || !outer.reachedAny() {
		t.Fatal("里层连上的源该传到外层")
	}
	var none *lyricSourceRound
	none.markReached("netease")
	if none.reachedAny() {
		t.Fatal("nil round 是空操作")
	}
}

// doHTTPTracked 只把歌词源主机的正常应答(< 500 且不是 429,404 也算)记成「连上了」。
func TestDoHTTPTrackedMarksReachedLyricSource(t *testing.T) {
	cases := []struct {
		url     string
		status  int
		reached bool
	}{
		{"https://lrclib.net/api/get", http.StatusOK, true},
		{"https://lrclib.net/api/get", http.StatusNotFound, true},
		{"https://lrclib.net/api/get", http.StatusServiceUnavailable, false},
		{"https://lrclib.net/api/get", http.StatusTooManyRequests, false},
		{"https://example.com/x", http.StatusOK, false},
	}
	for _, c := range cases {
		cli := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: c.status, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{}, Request: r}, nil
		})}
		ctx, round := withLyricSourceRound(context.Background())
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
		if err != nil {
			t.Fatal(err)
		}
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			t.Fatalf("%s %d: %v", c.url, c.status, err)
		}
		resp.Body.Close()
		if round.reachedAny() != c.reached {
			t.Errorf("%s %d: reached = %v, want %v", c.url, c.status, round.reachedAny(), c.reached)
		}
	}
}

func stubLyricsFillSweep(t *testing.T, run func(ctx context.Context, key string) lyricsSweepOutcome) (calls *[]string, waits *[]time.Duration) {
	t.Helper()
	savedRun, savedWait := lyricsFillSweepRunOne, lyricsFillSweepWait
	t.Cleanup(func() { lyricsFillSweepRunOne, lyricsFillSweepWait = savedRun, savedWait })
	var c []string
	var w []time.Duration
	lyricsFillSweepRunOne = func(ctx context.Context, key string, _ bool) lyricsSweepOutcome {
		c = append(c, key)
		return run(ctx, key)
	}
	lyricsFillSweepWait = func(_ context.Context, d time.Duration) { w = append(w, d) }
	return &c, &w
}

// 断网的那一条不算进度、原地等一会儿再搜它;网回来了接着往下走。
func TestLyricsFillSweepRetriesSameKeyWhenOffline(t *testing.T) {
	offlineOnce := true
	calls, waits := stubLyricsFillSweep(t, func(_ context.Context, key string) lyricsSweepOutcome {
		if key == "a" && offlineOnce {
			offlineOnce = false
			return lyricsSweepOutcome{offline: true}
		}
		return lyricsSweepOutcome{filled: key == "a"}
	})
	st := runLyricsFillSweepKeys(context.Background(), []string{"a", "b"}, false, lyricsFillSweepGap, lyricsFillStatus{Running: true, Total: 2})
	if strings.Join(*calls, ",") != "a,a,b" {
		t.Fatalf("断网那条该重搜一次再往下: %v", *calls)
	}
	if len(*waits) != 2 || (*waits)[0] != lyricsFillSweepOfflineWait || (*waits)[1] != lyricsFillSweepGap {
		t.Fatalf("先等断网重试的间隔、再等正常间隔: %v", *waits)
	}
	if st.Done != 2 || st.Filled != 1 || st.Offline || st.Cancelled {
		t.Fatalf("网回来之后照常收尾: %+v", st)
	}
}

// 一直连不上:连续 lyricsFillSweepOfflineLimit 次之后停下、标 Offline,不把剩下的烧掉。
func TestLyricsFillSweepStopsWhenOfflineTooLong(t *testing.T) {
	calls, _ := stubLyricsFillSweep(t, func(context.Context, string) lyricsSweepOutcome {
		return lyricsSweepOutcome{offline: true}
	})
	st := runLyricsFillSweepKeys(context.Background(), []string{"a", "b", "c"}, false, lyricsFillSweepGap, lyricsFillStatus{Running: true, Total: 3})
	if len(*calls) != lyricsFillSweepOfflineLimit {
		t.Fatalf("该试 %d 次后停下,实际 %d 次: %v", lyricsFillSweepOfflineLimit, len(*calls), *calls)
	}
	for _, k := range *calls {
		if k != "a" {
			t.Fatalf("断网期间不该往下走到别的条目: %v", *calls)
		}
	}
	if st.Done != 0 || !st.Offline || st.Cancelled {
		t.Fatalf("停下时一条都不算、标 Offline: %+v", st)
	}
}

// 搜到一半被停:那一条什么都没写,不算进度。
func TestLyricsFillSweepCancelMidSearchDoesNotCount(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls, _ := stubLyricsFillSweep(t, func(_ context.Context, key string) lyricsSweepOutcome {
		if key == "b" {
			cancel()
		}
		return lyricsSweepOutcome{filled: true}
	})
	st := runLyricsFillSweepKeys(ctx, []string{"a", "b", "c"}, false, lyricsFillSweepGap, lyricsFillStatus{Running: true, Total: 3})
	if strings.Join(*calls, ",") != "a,b" {
		t.Fatalf("停下之后不该再搜: %v", *calls)
	}
	if st.Done != 1 || st.Filled != 1 || !st.Cancelled {
		t.Fatalf("被停的那一条不算: %+v", st)
	}
}
