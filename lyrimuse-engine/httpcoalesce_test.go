package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func withCoalesceTestServer(t *testing.T, delay time.Duration) (*httptest.Server, *int32) {
	t.Helper()
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		select {
		case <-time.After(delay):
		case <-r.Context().Done():
			return
		}
		w.Header().Set("X-Path", r.URL.Path)
		io.WriteString(w, "body:"+r.URL.RawQuery)
	}))
	t.Cleanup(srv.Close)
	saved := httpCoalesceHostOK
	httpCoalesceHostOK = func(string) bool { return true }
	t.Cleanup(func() { httpCoalesceHostOK = saved })
	return srv, &hits
}

// waitCoalesceHits 等服务端收到至少 n 次请求,最多等 2 秒。
func waitCoalesceHits(t *testing.T, hits *int32, n int32) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadInt32(hits) < n {
		if time.Now().After(deadline) {
			t.Fatalf("服务端 2 秒内没收到第 %d 次请求", n)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func coalesceGet(t *testing.T, ctx context.Context, url string, hdr map[string]string) (string, error) {
	t.Helper()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return string(b), err
}

func TestHTTPCoalesceSharesInflightRequest(t *testing.T) {
	srv, hits := withCoalesceTestServer(t, 150*time.Millisecond)
	var wg sync.WaitGroup
	bodies := make([]string, 5)
	for i := range bodies {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b, err := coalesceGet(t, context.Background(), srv.URL+"/lyric?id=1", nil)
			if err != nil {
				t.Error(err)
			}
			bodies[i] = b
		}(i)
		time.Sleep(5 * time.Millisecond)
	}
	wg.Wait()
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("5 个同时在途的相同请求应当只发 1 次,发了 %d 次", n)
	}
	for i, b := range bodies {
		if b != "body:id=1" {
			t.Fatalf("第 %d 个拿到 %q", i, b)
		}
	}
	// 不在途了就不合并(不是缓存)。
	if _, err := coalesceGet(t, context.Background(), srv.URL+"/lyric?id=1", nil); err != nil {
		t.Fatal(err)
	}
	if n := atomic.LoadInt32(hits); n != 2 {
		t.Fatalf("前一个已经结束,这次应当真的再发一次: %d", n)
	}
}

func TestHTTPCoalesceKeepsDifferentRequestsApart(t *testing.T) {
	srv, hits := withCoalesceTestServer(t, 100*time.Millisecond)
	var wg sync.WaitGroup
	for _, c := range []struct {
		q   string
		hdr map[string]string
	}{{"id=1", nil}, {"id=2", nil}, {"id=1", map[string]string{"Referer": "x"}}} {
		wg.Add(1)
		go func(q string, h map[string]string) {
			defer wg.Done()
			if _, err := coalesceGet(t, context.Background(), srv.URL+"/lyric?"+q, h); err != nil {
				t.Error(err)
			}
		}(c.q, c.hdr)
	}
	wg.Wait()
	if n := atomic.LoadInt32(hits); n != 3 {
		t.Fatalf("URL 或请求头不同的不该合并: 发了 %d 次", n)
	}
	// POST 不合并。
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/x", nil)
	if _, ok := httpCoalesceKey(req); ok {
		t.Fatal("POST 不该合并")
	}
}

// 发出去的那个被自己的 ctx 取消了:等它的那个 ctx 还活着,自己重发,不跟着失败。
func TestHTTPCoalesceFollowerRetriesWhenLeaderCancelled(t *testing.T) {
	srv, hits := withCoalesceTestServer(t, 200*time.Millisecond)
	leaderCtx, cancel := context.WithCancel(context.Background())
	leaderErr := make(chan error, 1)
	go func() {
		_, err := coalesceGet(t, leaderCtx, srv.URL+"/lyric?id=9", nil)
		leaderErr <- err
	}()
	// 等发出去的那个真到了服务端再往下:只睡固定时长的话,机器忙时取消落在请求到达之前,服务端只见到
	// 重发的那一次(hits=1),断言失败 —— 那是测试自己的时序假设,不是代码的竞态。
	waitCoalesceHits(t, hits, 1)
	followerBody := make(chan string, 1)
	go func() {
		b, err := coalesceGet(t, context.Background(), srv.URL+"/lyric?id=9", nil)
		if err != nil {
			t.Error(err)
		}
		followerBody <- b
	}()
	time.Sleep(30 * time.Millisecond)
	cancel()
	if err := <-leaderErr; err == nil {
		t.Fatal("被取消的那个应当返回错误")
	}
	select {
	case b := <-followerBody:
		if b != "body:id=9" {
			t.Fatalf("等的那个应当自己重发拿到结果: %q", b)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("等的那个没有自己重发")
	}
	if n := atomic.LoadInt32(hits); n != 2 {
		t.Fatalf("应当发了 2 次(被取消的 + 自己重发的): %d", n)
	}
}

// 等到别人那次合并结果的请求也记进自己那一轮(withNetworkRound):它没真发请求,不记的话一轮里问成的恰好都是等结果的那几个时,
// 这一轮会被当成一个请求都没成。
func TestHTTPCoalesceFollowerCountsInItsNetworkRound(t *testing.T) {
	srv, hits := withCoalesceTestServer(t, 150*time.Millisecond)
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := coalesceGet(t, context.Background(), srv.URL+"/lyric?id=7", nil); err != nil {
			t.Error(err)
		}
	}()
	waitCoalesceHits(t, hits, 1)
	ctx, round := withNetworkRound(context.Background())
	if _, err := coalesceGet(t, ctx, srv.URL+"/lyric?id=7", nil); err != nil {
		t.Fatal(err)
	}
	<-done
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("应当合并成一次请求: %d", n)
	}
	if a, f := round(); a != 1 || f != 0 {
		t.Errorf("等到合并结果的那个要记成这一轮成功一次: attempts=%d failures=%d", a, f)
	}
}
