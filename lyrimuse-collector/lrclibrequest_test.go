package main

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// lrclibFake 把发往 lrclib.net 的请求转到本地 TLS 假服务器,记下每个请求的路径与参数。
type lrclibFake struct {
	mu   sync.Mutex
	reqs []*url.URL
}

func (f *lrclibFake) requests() []*url.URL {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*url.URL(nil), f.reqs...)
}

// withLRCLIBFake:handle 返回状态码、额外响应头和响应体。出站闸、熔断器与 LRCLIB 缓存都换新的。
func withLRCLIBFake(t *testing.T, handle func(r *http.Request) (int, http.Header, string)) *lrclibFake {
	t.Helper()
	resetSourceCachesForTest(t)
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	lrclibMu.Lock()
	savedCache := lrclibCache
	lrclibCache = map[string]lrclibResult{}
	lrclibMu.Unlock()
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
		lrclibMu.Lock()
		lrclibCache = savedCache
		lrclibMu.Unlock()
	})
	f := &lrclibFake{}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := *r.URL
		f.mu.Lock()
		f.reqs = append(f.reqs, &u)
		f.mu.Unlock()
		status, header, body := handle(r)
		for k, vs := range header {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	setSharedLyricSourceTransport(&http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	})
	return f
}

const lrclibSyncedFixture = `[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n[00:04.00]d`

func TestLRCLIBDurationParam(t *testing.T) {
	for _, c := range []struct {
		in   float64
		want string
	}{
		{0, ""}, {0.5, ""}, {1, "1.00"}, {211.666, "211.67"}, {3600, "3600.00"}, {3600.5, ""},
	} {
		if got := lrclibDurationParam(c.in); got != c.want {
			t.Errorf("lrclibDurationParam(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 两级 get 都带本地时长;带专辑那一级查不到才去掉专辑。
func TestLRCLIBGetSendsDuration(t *testing.T) {
	f := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		if r.URL.Path == "/api/get" && r.URL.Query().Get("album_name") == "" {
			return http.StatusOK, nil, `{"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"` + lrclibSyncedFixture + `"}`
		}
		return http.StatusNotFound, nil, `{"statusCode":404,"name":"TrackNotFound"}`
	})
	r := resolveLRCLIBLyric(qqRoundCtx(), "Artist", "Song", "Album", 199.6)
	if r.lyrics == "" || r.plainOnly {
		t.Fatalf("应拿到不带专辑那一级的时间轴歌词: %+v", r)
	}
	reqs := f.requests()
	if len(reqs) != 2 {
		t.Fatalf("应只发两次 get,实际 %d 次: %v", len(reqs), reqs)
	}
	for i, wantAlbum := range []string{"Album", ""} {
		q := reqs[i].Query()
		if reqs[i].Path != "/api/get" || q.Get("duration") != "199.60" || q.Get("album_name") != wantAlbum {
			t.Errorf("第 %d 个请求 %s?%s,期望 /api/get duration=199.60 album_name=%q", i+1, reqs[i].Path, reqs[i].RawQuery, wantAlbum)
		}
	}
}

// 本地时长未知:不带 duration,跟原来一样按名字查。
func TestLRCLIBGetWithoutKnownDuration(t *testing.T) {
	f := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		return http.StatusOK, nil, `{"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"` + lrclibSyncedFixture + `"}`
	})
	if r := resolveLRCLIBLyric(qqRoundCtx(), "Artist", "Song", "", 0); r.lyrics == "" {
		t.Fatalf("应拿到歌词: %+v", r)
	}
	for _, u := range f.requests() {
		if strings.Contains(u.RawQuery, "duration=") {
			t.Fatalf("时长未知时不该带 duration: %s", u.RawQuery)
		}
	}
}

func TestLRCLIBOverloadWait(t *testing.T) {
	for _, c := range []struct {
		status int
		ra     string
		want   time.Duration
		ok     bool
	}{
		{503, "1", time.Second, true}, {503, " 2 ", 2 * time.Second, true}, {503, "3", 0, false},
		{503, "", 0, false}, {503, "Wed, 21 Oct 2026 07:28:00 GMT", 0, false}, {429, "1", 0, false}, {500, "1", 0, false},
	} {
		if got, ok := lrclibOverloadWait(c.status, c.ra); got != c.want || ok != c.ok {
			t.Errorf("lrclibOverloadWait(%d, %q) = %v, %v; want %v, %v", c.status, c.ra, got, ok, c.want, c.ok)
		}
	}
}

// withLRCLIBInstantPause 把过载重试的等待换成不真等,记下每次要等多久。
func withLRCLIBInstantPause(t *testing.T) *[]time.Duration {
	t.Helper()
	var waits []time.Duration
	saved := lrclibOverloadPause
	lrclibOverloadPause = func(ctx context.Context, d time.Duration) bool {
		waits = append(waits, d)
		return ctx.Err() == nil
	}
	t.Cleanup(func() { lrclibOverloadPause = saved })
	return &waits
}

var lrclibOverloaded = http.Header{"Retry-After": {"1"}}

// 503 + Retry-After: 1:等一秒再发一次,拿到就用。
func TestLRCLIBRetriesOnceAfterOverload(t *testing.T) {
	waits := withLRCLIBInstantPause(t)
	calls := 0
	f := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		calls++
		if calls == 1 {
			return http.StatusServiceUnavailable, lrclibOverloaded, `{"statusCode":503,"name":"ServerOverloaded"}`
		}
		return http.StatusOK, nil, `{"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"` + lrclibSyncedFixture + `"}`
	})
	r := resolveLRCLIBLyric(qqRoundCtx(), "Artist", "Song", "", 200)
	if r.lyrics == "" {
		t.Fatalf("重试那一次拿到了,应当用上: %+v", r)
	}
	if n := len(f.requests()); n != 2 || len(*waits) != 1 || (*waits)[0] != time.Second {
		t.Fatalf("应只发两次、按 Retry-After 等 1 秒: requests=%d waits=%v", n, *waits)
	}
}

// 一直过载:每个请求只重试一次;不是 503、或 Retry-After 太长的不重试。
func TestLRCLIBOverloadRetryIsBounded(t *testing.T) {
	waits := withLRCLIBInstantPause(t)
	var reply func() (int, http.Header)
	f := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		st, h := reply()
		return st, h, `{}`
	})
	for _, c := range []struct {
		name      string
		reply     func() (int, http.Header)
		wantReqs  int
		wantWaits int
	}{
		{"一直 503", func() (int, http.Header) { return http.StatusServiceUnavailable, lrclibOverloaded }, 2, 1},
		{"Retry-After 太长", func() (int, http.Header) { return http.StatusServiceUnavailable, http.Header{"Retry-After": {"30"}} }, 1, 0},
		{"404", func() (int, http.Header) { return http.StatusNotFound, nil }, 1, 0},
	} {
		reply = c.reply
		before, beforeWaits := len(f.requests()), len(*waits)
		var out lrclibSearchItem
		if lrclibRequest(qqRoundCtx(), "https://lrclib.net/api/get?artist_name=a&track_name=b", time.Second, &out) {
			t.Fatalf("%s: 不该算问成", c.name)
		}
		if got := len(f.requests()) - before; got != c.wantReqs {
			t.Errorf("%s: 发了 %d 次,期望 %d 次", c.name, got, c.wantReqs)
		}
		if got := len(*waits) - beforeWaits; got != c.wantWaits {
			t.Errorf("%s: 等了 %d 次,期望 %d 次", c.name, got, c.wantWaits)
		}
	}
}
