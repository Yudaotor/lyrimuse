package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type dzCall struct {
	target, op, lang string
	vars             map[string]any
}

type dzFake struct {
	mu    sync.Mutex
	calls []dzCall
}

func (f *dzFake) count(pred func(dzCall) bool) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if pred(c) {
			n++
		}
	}
	return n
}

// dzFakeJWT 拼一张只带 exp 的票(不签名;deezerJWTExpiry 本来就不验签名)。
func dzFakeJWT(exp time.Time) string {
	payload, _ := json.Marshal(map[string]int64{"exp": exp.Unix()})
	return "e30." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
}

// withDeezerFake 把歌词源传输指到本地假服务器(同 withKugouFake),处理函数拿得到 GraphQL 的 operationName、变量和
// Accept-Language;回 0 表示不管这个请求 —— 换票请求这时回一张 6 分钟的票,别的回 404。票状态、缓存、译文语言(zh)
// 测完复原。
func withDeezerFake(t *testing.T, handle func(c dzCall) (int, string)) *dzFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	savedFeatures := features()
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	featuresRef().LyricsTranslationLanguage = "zh"
	deezerClearJWT()
	deezerMu.Lock()
	savedCache := deezerCache
	deezerCache = map[string]deezerResult{}
	deezerMu.Unlock()
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
		setFeatures(savedFeatures)
		deezerClearJWT()
		deezerMu.Lock()
		deezerCache = savedCache
		deezerMu.Unlock()
	})
	f := &dzFake{}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		c := dzCall{target: "https://" + host + r.URL.Path, lang: r.Header.Get("Accept-Language")}
		if r.Method == http.MethodPost {
			var body struct {
				OperationName string         `json:"operationName"`
				Variables     map[string]any `json:"variables"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			c.op, c.vars = body.OperationName, body.Variables
		}
		f.mu.Lock()
		f.calls = append(f.calls, c)
		f.mu.Unlock()
		if c.target == "https://auth.deezer.com/login/anonymous" {
			if status, b := handle(c); status != 0 {
				w.WriteHeader(status)
				_, _ = io.WriteString(w, b)
				return
			}
			_, _ = fmt.Fprintf(w, `{"jwt":%q}`, dzFakeJWT(time.Now().Add(6*time.Minute)))
			return
		}
		status, b := handle(c)
		if status == 0 {
			status = http.StatusNotFound
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, b)
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

type dzHit struct {
	id, title, artist, album string
	duration                 int
	sync                     bool
}

func dzSearchResponse(hits ...dzHit) string {
	edges := make([]map[string]any, 0, len(hits))
	for _, h := range hits {
		edges = append(edges, map[string]any{"node": map[string]any{
			"id": h.id, "title": h.title, "duration": h.duration, "hasSynchronizedLyrics": h.sync,
			"contributors": map[string]any{"edges": []any{map[string]any{"node": map[string]any{"name": h.artist}}}},
			"album":        map[string]any{"displayTitle": h.album, "cover": map[string]any{"urls": []string{"https://cdn-images.dzcdn.net/images/cover/abc/1000x1000-000000-80-0-0.jpg"}}},
		}})
	}
	b, _ := json.Marshal(map[string]any{"data": map[string]any{"search": map[string]any{"results": map[string]any{"tracks": map[string]any{"edges": edges}}}}})
	return string(b)
}

func dzLyricsResponse(lines ...string) string {
	var sync []map[string]any
	for i, l := range lines {
		sync = append(sync, map[string]any{"lrcTimestamp": fmt.Sprintf("[00:%02d.00]", 5+i*10), "milliseconds": (5 + i*10) * 1000, "line": l})
	}
	b, _ := json.Marshal(map[string]any{"data": map[string]any{"track": map[string]any{"lyrics": map[string]any{"text": strings.Join(lines, "\n"), "synchronizedLines": sync}}}})
	return string(b)
}

var dzSixLines = []string{"line one", "line two", "line three", "line four", "line five", "line six"}

func TestDeezerSearchLanguage(t *testing.T) {
	for in, want := range map[string]string{
		"周杰伦 稻香": "zh-CN", "米津玄師 まちがいさがし": "ja-JP", "TREASURE 묻어둔다": "ko-KR", "Michael Jackson Thriller": "en-US", "Stromae Alors on danse": "en-US",
	} {
		if got := deezerSearchLanguage(in); got != want {
			t.Errorf("deezerSearchLanguage(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDeezerJWTRejected(t *testing.T) {
	if !deezerJWTRejected(`[{"type":"JwtTokenExpiredError"}]`) || !deezerJWTRejected(`[{"type":"JwtTokenMissingError"}]`) {
		t.Error("过期 / 没带票都该认")
	}
	if deezerJWTRejected(`[{"type":"LyricsNotFoundError"}]`) {
		t.Error("没有歌词不是票的问题")
	}
}

// 6 分钟的票在有效期内复用,离到期不到提前量才换。
func TestDeezerJWTReusedWithinLifetime(t *testing.T) {
	exp := time.Now().Add(6 * time.Minute)
	f := withDeezerFake(t, func(c dzCall) (int, string) {
		return http.StatusOK, fmt.Sprintf(`{"jwt":%q}`, dzFakeJWT(exp))
	})
	auth := func() int {
		return f.count(func(c dzCall) bool { return strings.HasPrefix(c.target, "https://auth.deezer.com/") })
	}
	ctx := context.Background()
	deezerEnsureJWT(ctx)
	deezerEnsureJWT(ctx)
	if got := auth(); got != 1 {
		t.Fatalf("6 分钟的票应复用,换了 %d 次", got)
	}
	exp = time.Now().Add(deezerJWTRenewMargin / 2)
	deezerClearJWT()
	deezerEnsureJWT(ctx)
	deezerEnsureJWT(ctx)
	if got := auth(); got != 3 {
		t.Errorf("离到期不到提前量的票应当场换,累计换票 %d 次,want 3", got)
	}
}

// 中文查询按中文请求头搜;搜索说没有同步歌词的候选不取词,只对有的那条取;取词按译文语言带请求头。
func TestResolveDeezerUsesGraphQLSearch(t *testing.T) {
	f := withDeezerFake(t, func(c dzCall) (int, string) {
		switch c.op {
		case "SearchTracks":
			return http.StatusOK, dzSearchResponse(
				dzHit{"1", "稻香", "周杰伦", "魔杰座", 223, false},
				dzHit{"2", "稻香", "周杰伦", "魔杰座", 223, true},
				dzHit{"3", "稻香 (伴奏)", "卡拉OK", "伴奏合集", 223, true})
		case "SynchronizedTrackLyrics":
			return http.StatusOK, dzLyricsResponse(dzSixLines...)
		}
		return 0, ""
	})
	r := resolveDeezerLyric(context.Background(), "周杰伦", "稻香", "魔杰座", 223, "")
	if r.lyrics == "" || r.plainOnly || r.title != "稻香" {
		t.Fatalf("应取到 2 号的同步歌词: %+v", r)
	}
	if n := f.count(func(c dzCall) bool { return c.op == "SearchTracks" && c.lang == "zh-CN" }); n != 1 {
		t.Errorf("中文查询应按 zh-CN 搜一次, got %d", n)
	}
	fetched := f.count(func(c dzCall) bool { return c.op == "SynchronizedTrackLyrics" })
	only2 := f.count(func(c dzCall) bool {
		return c.op == "SynchronizedTrackLyrics" && fmt.Sprint(c.vars["trackId"]) == "2" && c.lang == deezerAcceptLanguage()
	})
	if fetched != 1 || only2 != 1 {
		t.Errorf("只该对 2 号取一次词(按译文语言带请求头): fetched=%d only2=%d", fetched, only2)
	}
	if f.count(func(c dzCall) bool { return strings.HasPrefix(c.target, "https://api.deezer.com/") }) != 0 {
		t.Error("GraphQL 搜索成了就不该再打公开搜索")
	}
}

// GraphQL 搜索没问成时退回公开搜索。
func TestResolveDeezerFallsBackToPublicSearch(t *testing.T) {
	f := withDeezerFake(t, func(c dzCall) (int, string) {
		switch {
		case c.op == "SearchTracks":
			return http.StatusInternalServerError, ""
		case c.target == "https://api.deezer.com/search":
			return http.StatusOK, `{"data":[{"id":7,"title":"Hello","duration":295,"artist":{"name":"Adele"},"album":{"title":"25"}}]}`
		case c.op == "SynchronizedTrackLyrics":
			return http.StatusOK, dzLyricsResponse(dzSixLines...)
		}
		return 0, ""
	})
	r := resolveDeezerLyric(context.Background(), "Adele", "Hello", "25", 295, "")
	if r.lyrics == "" || r.title != "Hello" {
		t.Fatalf("应退回公开搜索取到: %+v", r)
	}
	if f.count(func(c dzCall) bool { return c.target == "https://api.deezer.com/search" }) != 1 {
		t.Error("GraphQL 搜索失败时应打一次公开搜索")
	}
}

// 取词回 JwtTokenExpiredError(HTTP 200)时换一张票重试一次。
func TestDeezerFetchLyricsRetriesOnExpiredJWT(t *testing.T) {
	var mu sync.Mutex
	lyricsCalls := 0
	f := withDeezerFake(t, func(c dzCall) (int, string) {
		if c.op != "SynchronizedTrackLyrics" {
			return 0, ""
		}
		mu.Lock()
		defer mu.Unlock()
		lyricsCalls++
		if lyricsCalls == 1 {
			return http.StatusOK, `{"errors":[{"message":"Given jwt token is not valid anymore","type":"JwtTokenExpiredError"}],"data":{"track":null}}`
		}
		return http.StatusOK, dzLyricsResponse(dzSixLines...)
	})
	p, err := deezerFetchLyrics(context.Background(), "9")
	if err != nil || p.lrc == "" {
		t.Fatalf("过期票应换新重试一次后取到: err=%v %+v", err, p)
	}
	if got := f.count(func(c dzCall) bool { return strings.HasPrefix(c.target, "https://auth.deezer.com/") }); got != 2 {
		t.Errorf("应换两次票(初次 + 过期后), got %d", got)
	}
}

// 候选全都没有同步歌词:只取分数最高那条,为它的纯文本。
func TestResolveDeezerPlainWhenNoSyncedCandidate(t *testing.T) {
	f := withDeezerFake(t, func(c dzCall) (int, string) {
		switch c.op {
		case "SearchTracks":
			return http.StatusOK, dzSearchResponse(dzHit{"5", "Rice Song", "Someone", "Album", 200, false}, dzHit{"6", "Rice Song", "Someone", "Album", 200, false})
		case "SynchronizedTrackLyrics":
			return http.StatusOK, `{"data":{"track":{"lyrics":{"text":"plain one\nplain two","synchronizedLines":null}}}}`
		}
		return 0, ""
	})
	r := resolveDeezerLyric(context.Background(), "Someone", "Rice Song", "Album", 200, "")
	if !r.plainOnly || !strings.Contains(r.lyrics, "plain one") {
		t.Fatalf("应退到纯文本: %+v", r)
	}
	if n := f.count(func(c dzCall) bool { return c.op == "SynchronizedTrackLyrics" }); n != 1 {
		t.Errorf("没有同步歌词时只该取分数最高那一条, got %d", n)
	}
}
