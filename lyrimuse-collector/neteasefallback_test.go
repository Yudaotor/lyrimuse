package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// neFake 把网易云几个主机(真实主机名经改写的传输层)指到一个本地服务器,按 "主机/路径" 分发并计数。
type neFake struct {
	mu      sync.Mutex
	hits    map[string]int
	cookies map[string]string
}

func (f *neFake) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[key]
}

func withNeteaseFake(t *testing.T, handle func(target string) (int, string)) *neFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport
	hostGuardShared = newHostGuard(time.Now)
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	neteaseRateMu.Lock()
	savedCall, savedCooldown, savedStreak := neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak
	neteaseLastCall = time.Time{}
	neteaseCooldownUntil = map[string]time.Time{}
	neteaseBlockStreak = map[string]int{}
	neteaseRateMu.Unlock()
	t.Cleanup(func() {
		hostGuardShared, lyricSourceBreakerShared, lyricSourceTransport = savedGuard, savedBreaker, savedTransport
		neteaseRateMu.Lock()
		neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak = savedCall, savedCooldown, savedStreak
		neteaseRateMu.Unlock()
	})
	f := &neFake{hits: map[string]int{}, cookies: map[string]string{}}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		target := host + r.URL.Path
		f.mu.Lock()
		f.hits[target]++
		f.cookies[target] = r.Header.Get("Cookie")
		f.mu.Unlock()
		status, body := handle(target)
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	lyricSourceTransport = &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	return f
}

func TestNeteaseHostURLs(t *testing.T) {
	got := neteaseHostURLs("https://music.163.com/api/song/detail?ids=[1]")
	if len(got) != len(neteaseHosts) || !strings.HasPrefix(got[1], "https://interface.music.163.com/api/song/detail?") {
		t.Fatalf("该按主机展开: %v", got)
	}
	if got := neteaseHostURLs("https://p1.music.126.net/x.jpg"); len(got) != 1 {
		t.Fatalf("别的主机原样返回: %v", got)
	}
}

// 首选主机没问成就换下一个主机;响应体里的拒绝码不换主机(按路径分桶限流,换主机也是同一个桶),
// 而是由调用方换另一条路径。
func TestNeteaseFetchBodyHostFallbackAndNoHopOnRejection(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case "music.163.com/api/album/9":
			return http.StatusBadGateway, ""
		case "interface.music.163.com/api/album/9":
			return http.StatusOK, `{"code":200}`
		}
		return http.StatusNotFound, ""
	})
	body, err := neteaseFetchBody(qqRoundCtx(), "https://music.163.com/api/album/9", "os=pc", 4*time.Second)
	if err != nil || string(body) != `{"code":200}` {
		t.Fatalf("该从备用主机拿到: %s %v", body, err)
	}
	if f.cookies["interface.music.163.com/api/album/9"] != "os=pc" {
		t.Error("换了主机也要带上 cookie")
	}
	if f.count("interface3.music.163.com/api/album/9") != 0 {
		t.Error("拿到了就停")
	}

	f = withNeteaseFake(t, func(target string) (int, string) {
		switch target {
		case "music.163.com/api/search/get":
			return http.StatusOK, `{"result":{},"code":405}`
		case "music.163.com/api/search/get/web":
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":1,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":9,"name":"U87"},"duration":283000}]}}`
		}
		return http.StatusNotFound, ""
	})
	get := neteaseTestGet()
	songs, err := neteaseSearchSongs(get, "陈奕迅 浮夸")
	if err != nil || len(songs) != 1 {
		t.Fatalf("主路径被拒该换 /web 路径: %v %v", songs, err)
	}
	if f.count("interface.music.163.com/api/search/get") != 0 {
		t.Error("拒绝码不该换主机再撞同一个桶")
	}
}

// neteaseTestGet 复刻 resolveNeteaseInfo 里 get 的判定(200 + body 拒绝码当失败),给单测直接调搜索用。
func neteaseTestGet() func(string, any) error {
	return func(u string, v any) error {
		body, err := neteaseFetchBody(qqRoundCtx(), u, "", 4*time.Second)
		if err != nil {
			return err
		}
		if strings.Contains(string(body), `"code":405`) {
			return errNeteaseTestRejected
		}
		return jsonUnmarshalForTest(body, v)
	}
}

// 搜歌:search/get 两条路径几个主机都没问成,退到 cloudsearch,字段名 ar/al/dt 归一回来。
func TestNeteaseSearchSongsFallsBackToCloudSearch(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/api/search/get") || strings.HasSuffix(target, "/api/search/get/web") {
			return http.StatusInternalServerError, ""
		}
		if target == "music.163.com/api/cloudsearch/pc" {
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","dt":283520,"ar":[{"name":"陈奕迅"}],"al":{"id":6491,"name":"U87"}}]}}`
		}
		return http.StatusNotFound, ""
	})
	songs, err := neteaseSearchSongs(neteaseTestGet(), "陈奕迅 浮夸")
	if err != nil || len(songs) != 1 {
		t.Fatalf("该从 cloudsearch 拿到: %v %v", songs, err)
	}
	s := songs[0]
	if s.ID != 66282 || s.Name != "浮夸" || s.Duration != 283520 || s.Album.ID != 6491 || s.Album.Name != "U87" ||
		len(s.Artists) != 1 || s.Artists[0].Name != "陈奕迅" {
		t.Fatalf("字段没归一对: %+v", s)
	}
}

const neV1Lyric = `{"t":0,"c":[{"tx":"作词: "},{"tx":"黄伟文"}]}
{"t":800,"c":[{"tx":"作曲: "},{"tx":"C. Y. Kong"}]}
[00:28.948]有人问我 我就会讲
[00:36.141]我期待 到无奈
[00:44.000]第三句
[00:52.000]第四句`

func TestNeteaseV1LyricLines(t *testing.T) {
	got := neteaseV1LyricLines(neV1Lyric)
	if strings.Contains(got, "{") || !strings.HasPrefix(got, "[00:28.948]") || strings.Count(got, "\n") != 3 {
		t.Fatalf("JSON 署名行该剥掉、正文原样留下: %q", got)
	}
	if plain := "[00:01.00]a\n[00:02.00]b"; neteaseV1LyricLines(plain) != plain {
		t.Error("没有 JSON 行时原样返回")
	}
}

// 端到端:单曲详情的老接口几个主机都挂了退到 v3,整行歌词的老接口挂了退到 v1(剥掉 JSON 署名行)。
func TestResolveNeteaseInfoFallsBackForDetailAndLyric(t *testing.T) {
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520}]}}`
		case strings.HasSuffix(target, "/api/song/detail"), strings.HasSuffix(target, "/api/song/lyric"):
			return http.StatusInternalServerError, ""
		case target == "music.163.com/api/v3/song/detail":
			return http.StatusOK, `{"code":200,"songs":[{"al":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `},"yrc":{"lyric":""}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if info.Cover != "http://p1.music.126.net/x.jpg?param=800y800" {
		t.Errorf("封面该从 v3 详情拿到: %q", info.Cover)
	}
	if !strings.HasPrefix(info.Lyrics, "[00:28.948]") || strings.Contains(info.Lyrics, `{"t"`) {
		t.Errorf("歌词该从 v1 拿到并剥掉 JSON 署名行: %q", info.Lyrics)
	}
	for _, h := range neteaseHosts {
		if f.count(h+"/api/song/detail") != 1 || f.count(h+"/api/song/lyric") != 1 {
			t.Errorf("老接口在 %s 上该先试一次", h)
		}
	}
}

// 退到 v1 时不下「这首没词」的结论:v1 的「没词」形态没实测过。
func TestResolveNeteaseInfoV1FallbackNeverConcludesNoLyrics(t *testing.T) {
	withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520}]}}`
		case strings.HasSuffix(target, "/api/song/lyric"):
			return http.StatusInternalServerError, ""
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case target == "music.163.com/api/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":""}}`
		}
		return http.StatusNotFound, ""
	})
	info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
	if info.TrackFoundNoLyrics {
		t.Fatal("退到 v1 拿到空歌词,不该判成平台没词")
	}
	if info.Cover == "" {
		t.Error("老详情接口正常时封面照常")
	}
}

var errNeteaseTestRejected = errorString("netease test: rejected")

type errorString string

func (e errorString) Error() string { return string(e) }

func jsonUnmarshalForTest(b []byte, v any) error { return json.Unmarshal(b, v) }

func jsonQuoteForTest(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
