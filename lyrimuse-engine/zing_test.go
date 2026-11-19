package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// resetZingState 清掉进程内的 Zing 状态(缓存、cookie、当前密钥、失败原因),固定签名用的时间。
func resetZingState(t *testing.T) {
	t.Helper()
	reset := func() {
		zingMu.Lock()
		zingCache = map[string]zingResult{}
		zingMu.Unlock()
		zingCookieMu.Lock()
		zingCookie = ""
		zingCookieMu.Unlock()
		zingKeyIdx.Store(0)
		zingSetLastFailureReason("")
	}
	reset()
	savedNow := zingNow
	zingNow = func() time.Time { return time.Unix(1700000000, 0) }
	t.Cleanup(func() {
		reset()
		zingNow = savedNow
	})
}

// withZingFake 把歌词源的出站请求接到本地 TLS 假服务器(同 withKugouFakeReq),处理函数拿到完整的 ResponseWriter,
// 要下发 Set-Cookie 时用。target 是 `https://主机/路径`。
func withZingFake(t *testing.T, handle func(w http.ResponseWriter, r *http.Request, target string)) {
	t.Helper()
	resetZingState(t)
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
	})
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		handle(w, r, "https://"+host+r.URL.Path)
	}))
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	setSharedLyricSourceTransport(&http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	})
}

func TestZingSignKnownAnswer(t *testing.T) {
	// 期望值是按网页客户端的算法另行算出来的(Python hashlib / hmac)。
	secret := "acOrvUS15XRW2o9JksiK1KgQ6Vbds8ZW"
	got := zingSign(zingSearchPath, map[string]string{"q": "abc", "count": "20", "ctime": "1700000000", "page": "1", "type": "song", "version": "1.22.4"}, secret)
	if got != "12cb92bf4b8bb2436f734d9f4a0a649bdf2187cd8e475f7ad2ec9b1b5ae7592609aab5818cc65c2eebf4d59e406483d0dcae7078b944c990d1a417dcb7024668" {
		t.Errorf("搜索签名(q 不进签名): %s", got)
	}
	got = zingSign(zingLyricPath, map[string]string{"id": "ZZ8ABC", "ctime": "1700000000", "version": "1.22.4"}, secret)
	if got != "2923c9edf04c8d2e0b7844ff00a2031fa9dca1222acc0b6d1b5490fcf792aa70c8a70fbb8848c228e4fbefa774f3f9e3959b1239fa7c84c3ad95e1798ba8cb3f" {
		t.Errorf("取词签名: %s", got)
	}
}

func zw(start, end int, data string) zingWord {
	return zingWord{StartTime: start, EndTime: end, Data: data}
}

func TestZingWordSpansAndYRC(t *testing.T) {
	// 两个零时长词跟后面同一起点的词同唱 900ms:三等分。
	ws := []zingWord{zw(1000, 1000, "Anh"), zw(1000, 1000, "đã"), zw(1000, 1900, "từng"), zw(1900, 2300, "yêu")}
	if got := zingWordSpans(ws); !slices.Equal(got, [][2]int{{1000, 1300}, {1300, 1600}, {1600, 1900}, {1900, 2300}}) {
		t.Errorf("同起点平分: %v", got)
	}
	// 零时长词后面的词起点更晚:平分到它开口为止;句尾的零时长留零。
	ws = []zingWord{zw(1000, 1000, "a"), zw(1000, 1000, "b"), zw(1400, 1800, "c"), zw(2000, 2000, "d")}
	if got := zingWordSpans(ws); !slices.Equal(got, [][2]int{{1000, 1200}, {1200, 1400}, {1400, 1800}, {2000, 2000}}) {
		t.Errorf("平分到下一个词开口 / 句尾留零: %v", got)
	}
	yrc := zingBuildYRC([][]zingWord{
		{zw(1000, 1000, "Anh"), zw(1000, 1600, "yêu"), zw(1600, 2500, "em")},
		{zw(3000, 3500, " Ai "), zw(3500, 4000, "đó")},
	})
	want := "[1000,1500](1000,300,0)Anh (1300,300,0)yêu (1600,900,0)em\n[3000,1000](3000,500,0)Ai (3500,500,0)đó"
	if yrc != want {
		t.Errorf("YRC:\n%s\nwant\n%s", yrc, want)
	}
}

func TestZingWordLines(t *testing.T) {
	sents := []zingSentence{
		{Words: []zingWord{zw(1000, 1200, "Một"), zw(1200, 1200, " "), zw(1200, 1500, "hai")}},
		{Words: []zingWord{zw(0, 0, "  ")}},
		{Words: []zingWord{zw(2000, 2600, "ba")}},
	}
	got := zingWordLines(sents)
	if len(got) != 2 || len(got[0]) != 2 || zingWordLineText(got[0]) != "Một hai" || zingWordLineText(got[1]) != "ba" {
		t.Fatalf("去掉空词和空句: %+v", got)
	}
	// 跨句起点倒退(快唱时下一句比上一句尾词早开口)是正常数据。
	cross := []zingSentence{{Words: []zingWord{zw(1000, 1500, "a"), zw(1500, 2000, "b")}}, {Words: []zingWord{zw(1400, 1800, "c"), zw(1800, 2200, "d")}}}
	if zingWordLines(cross) == nil {
		t.Error("跨句起点倒退照用")
	}
	// 句内起点倒退、终点早于起点:数据坏了,整份不要。
	if zingWordLines([]zingSentence{{Words: []zingWord{zw(1000, 1500, "a"), zw(900, 1600, "b")}}}) != nil {
		t.Error("句内起点倒退应整份不要")
	}
	if zingWordLines([]zingSentence{{Words: []zingWord{zw(1000, 900, "a"), zw(1000, 1600, "b")}}}) != nil {
		t.Error("终点早于起点应整份不要")
	}
	// 每句只有一个「词」:那是逐行,不算逐字。
	if zingWordLines([]zingSentence{{Words: []zingWord{zw(1000, 1500, "câu một")}}, {Words: []zingWord{zw(2000, 2500, "câu hai")}}}) != nil {
		t.Error("全是单词句不算逐字")
	}
}

func TestZingParseLRC(t *testing.T) {
	text := "\ufeff[ar:X]\n[00:21.84]Ai ngoài anh\n\n[00:10.00][00:30.50]Lặp lại\n[00:40.00]   \n"
	got := zingParseLRC(text)
	want := []zingSyncLine{{10000, "Lặp lại"}, {21840, "Ai ngoài anh"}, {30500, "Lặp lại"}}
	if !slices.Equal(got, want) {
		t.Errorf("解析 LRC: %+v", got)
	}
}

func TestZingWordTrackAgrees(t *testing.T) {
	words := [][]zingWord{
		{zw(1000, 1500, "Anh"), zw(1500, 2000, "yêu")},
		{zw(3000, 3500, "Em"), zw(3500, 4000, "ơi")},
		{zw(5000, 5500, "Ngày"), zw(5500, 6000, "mai")},
		{zw(7000, 7500, "Trời"), zw(7500, 8000, "xanh")},
		{zw(9000, 9500, "Mây"), zw(9500, 9900, "trắng")},
	}
	lines := []zingSyncLine{{1100, "Anh yêu"}, {3000, "Em ơi!"}, {5200, "Ngày mai"}, {7000, "Trời xanh"}, {9000, "Mây trắng"}}
	if !zingWordTrackAgrees(words, lines) {
		t.Error("文字、时间都对得上应采用")
	}
	off := slices.Clone(lines)
	off[0].ms, off[1].ms = 1000+zingWordTrackMaxOffsetMs+1, 3000-zingWordTrackMaxOffsetMs-1
	if zingWordTrackAgrees(words, off) {
		t.Error("两句(40%)超出时间窗,不到八成应不用")
	}
	off = slices.Clone(lines)
	off[0].ms = 1000 + zingWordTrackMaxOffsetMs
	if !zingWordTrackAgrees(words, off) {
		t.Error("一句刚好在时间窗边上、其余对得上应采用")
	}
	other := slices.Clone(lines)
	other[2].text, other[3].text = "Khác hẳn", "Một câu khác"
	if zingWordTrackAgrees(words, other) {
		t.Error("两句文字对不上应不用")
	}
	if zingWordTrackAgrees(words, nil) || zingWordTrackAgrees(nil, lines) {
		t.Error("一边为空应不用")
	}
}

func TestZingCoverURL(t *testing.T) {
	cases := map[string]string{
		"https://photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/cover/a/b/c.jpg":  "https://photo-zmp3.zmdcdn.me/cover/a/b/c.jpg",
		"https://photo-resize-zmp3.zmdcdn.me/w94_r1x1_webp/cover/x.jpg":       "https://photo-zmp3.zmdcdn.me/cover/x.jpg",
		"https://photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/covers/b/1/x.jpg": "https://photo-zmp3.zmdcdn.me/covers/b/1/x.jpg",
		"https://photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/avatars/x.jpg":    "",
		"https://photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/banner/x.jpg":     "",
		"https://photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/coverx/x.jpg":     "",
		"https://example.com/w240/cover/x.jpg":                                "https://example.com/w240/cover/x.jpg",
		"":                                                                    "",
	}
	for in, want := range cases {
		if got := zingCoverURL(in); got != want {
			t.Errorf("%q → %q, want %q", in, got, want)
		}
	}
}

func TestZingCandidateScoreGates(t *testing.T) {
	base := zingSearchItem{EncodeID: "Z1", Title: "Ai Ngoài Anh", ArtistsNames: "VSTRA, Tyronee", Duration: 200, HasLyric: true}
	if s := zingCandidateScore(base, "VSTRA", "Ai Ngoài Anh", "", 201); s < 0 {
		t.Fatalf("同名同歌手、时长相近应过闸: %d", s)
	}
	noLyric := base
	noLyric.HasLyric = false
	if zingCandidateScore(noLyric, "VSTRA", "Ai Ngoài Anh", "", 201) >= 0 {
		t.Error("没有歌词标记的淘汰")
	}
	if zingCandidateScore(base, "VSTRA", "Ai Ngoài Em", "", 201) >= 0 {
		t.Error("歌名不同淘汰")
	}
	if zingCandidateScore(base, "Sơn Tùng M-TP", "Ai Ngoài Anh", "", 201) >= 0 {
		t.Error("歌手不同、专辑时长也认不出同一条录音的淘汰")
	}
	if zingCandidateScore(base, "VSTRA", "Ai Ngoài Anh", "", 240) >= 0 {
		t.Error("时长差 40 秒淘汰")
	}
	short := base
	short.Duration = 27
	if zingCandidateScore(short, "VSTRA", "Ai Ngoài Anh", "", 20) >= 0 {
		t.Error("短歌差 7 秒(没过 8 秒)但超出 25% 的淘汰")
	}
	remix := base
	remix.Title = "Ai Ngoài Anh (Remix)"
	if zingCandidateScore(remix, "VSTRA", "Ai Ngoài Anh", "", 201) >= 0 {
		t.Error("本地是原版、候选是 Remix 的淘汰")
	}
	far, near := base, base
	far.Duration, near.Duration = 196, 201
	if zingCandidateScore(near, "VSTRA", "Ai Ngoài Anh", "", 201) <= zingCandidateScore(far, "VSTRA", "Ai Ngoài Anh", "", 201) {
		t.Error("时长越近分越高")
	}
}

const zingTestSearch = `{"err":0,"msg":"Success","data":{"items":[
 {"encodeId":"ZREMIX","title":"Ai Ngoài Anh (Remix)","artistsNames":"VSTRA","duration":180,"hasLyric":true},
 {"encodeId":"ZOK1","title":"Ai Ngoài Anh","artistsNames":"VSTRA, Tyronee","duration":200,"hasLyric":true,
  "thumbnailM":"https://photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/cover/1/2/a.jpg","album":{"title":"Ai Ngoài Anh (Single)"}},
 {"encodeId":"ZOK2","title":"Ai Ngoài Anh","artistsNames":"VSTRA","duration":199,"hasLyric":true,"album":{"title":"Album"}},
 {"encodeId":"ZNOLYRIC","title":"Ai Ngoài Anh","artistsNames":"VSTRA","duration":200}]}}`

const zingTestEmptySearch = `{"err":0,"msg":"Success","data":{}}`

func zingTestLyric(file string) string {
	return `{"err":0,"msg":"Success","data":{"sentences":[
 {"words":[{"startTime":21840,"endTime":21840,"data":"Ai"},{"startTime":21840,"endTime":22400,"data":"ngoài"},{"startTime":22400,"endTime":23000,"data":"anh"}]},
 {"words":[{"startTime":24000,"endTime":24500,"data":"Mình"},{"startTime":24500,"endTime":25200,"data":"yêu"}]},
 {"words":[{"startTime":26000,"endTime":26400,"data":"Trời"},{"startTime":26400,"endTime":27000,"data":"xanh"}]}],
 "file":"` + file + `"}}`
}

const zingTestLRC = "[00:21.84]Ai ngoài anh\n[00:24.00]Mình yêu\n[00:26.00]Trời xanh\n"

// zingHandleSession:没带会话 cookie 的请求回 -201 并下发 cookie,同网页接口。带了才交给 next。
func zingHandleSession(w http.ResponseWriter, r *http.Request) bool {
	if c, err := r.Cookie(zingCookieName); err != nil || c.Value != "rq1" {
		http.SetCookie(w, &http.Cookie{Name: zingCookieName, Value: "rq1", Path: "/"})
		_, _ = io.WriteString(w, `{"err":-201,"msg":"Request has been blocked"}`)
		return false
	}
	return true
}

func TestResolveZingLyricEndToEnd(t *testing.T) {
	var mu sync.Mutex
	var queries, lyricIDs []string
	noSession := 0
	const fileURL = "https://static-zmp3.zmdcdn.me/lyrics/a.lrc"
	withZingFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		mu.Lock()
		defer mu.Unlock()
		if strings.HasPrefix(target, "https://zingmp3.vn/") {
			q := r.URL.Query()
			signed := map[string]string{}
			for k := range q {
				signed[k] = q.Get(k)
			}
			if q.Get("apiKey") != zingKeys[0].apiKey || q.Get("sig") != zingSign(r.URL.Path, signed, zingKeys[0].secret) {
				_, _ = io.WriteString(w, `{"err":-104,"msg":"Incorect signature"}`)
				return
			}
			if !zingHandleSession(w, r) {
				noSession++
				return
			}
		}
		switch target {
		case "https://zingmp3.vn" + zingSearchPath:
			q := r.URL.Query().Get("q")
			queries = append(queries, q)
			if q == "Ai Ngoài Anh VSTRA" {
				_, _ = io.WriteString(w, zingTestEmptySearch)
				return
			}
			_, _ = io.WriteString(w, zingTestSearch)
		case "https://zingmp3.vn" + zingLyricPath:
			id := r.URL.Query().Get("id")
			lyricIDs = append(lyricIDs, id)
			if id == "ZOK1" {
				_, _ = io.WriteString(w, zingTestLyric(fileURL))
				return
			}
			_, _ = io.WriteString(w, `{"err":0,"msg":"Success","data":{}}`)
		case fileURL:
			_, _ = io.WriteString(w, zingTestLRC)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := resolveZingLyric(ctx, "VSTRA", "Ai Ngoài Anh", "", 201)
	mu.Lock()
	sort.Strings(queries)
	sort.Strings(lyricIDs)
	gotQueries, gotIDs, gotNoSession := slices.Clone(queries), slices.Clone(lyricIDs), noSession
	mu.Unlock()
	if !slices.Equal(gotQueries, []string{"Ai Ngoài Anh", "Ai Ngoài Anh VSTRA"}) {
		t.Errorf("「歌名 歌手」和只按歌名各搜一次: %v", gotQueries)
	}
	if !slices.Equal(gotIDs, []string{"ZOK1", "ZOK2"}) {
		t.Errorf("只取过闸的(Remix、没有歌词标记的不取): %v", gotIDs)
	}
	if gotNoSession == 0 {
		t.Error("没带 cookie 的那次应收到 -201 并重发")
	}
	if r.lyrics != zingTestLRC {
		t.Errorf("逐行用 LRC 文件: %q", r.lyrics)
	}
	if r.yrc != "[21840,1160](21840,280,0)Ai (22120,280,0)ngoài (22400,600,0)anh\n[24000,1200](24000,500,0)Mình (24500,700,0)yêu\n[26000,1000](26000,400,0)Trời (26400,600,0)xanh" {
		t.Errorf("逐字: %q", r.yrc)
	}
	if r.title != "Ai Ngoài Anh" || r.artist != "VSTRA, Tyronee" || r.album != "Ai Ngoài Anh (Single)" || r.durationSecs != 200 ||
		r.cover != "https://photo-zmp3.zmdcdn.me/cover/1/2/a.jpg" {
		t.Errorf("元数据: %+v", r)
	}
	if !sub.complete(ctx) {
		t.Error("都问成了应算完整(ZOK2 回 err 0 没词是答了)")
	}
}

// zingSimpleFake:签名不校验、会话不要求的假服务器,按目标分发。
func zingSimpleFake(t *testing.T, handle func(r *http.Request, target string) (int, string)) {
	withZingFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		status, body := handle(r, target)
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	})
}

func TestResolveZingLyricWordGateAndFileFailure(t *testing.T) {
	const fileURL = "https://static-zmp3.zmdcdn.me/lyrics/b.lrc"
	search := `{"err":0,"data":{"items":[{"encodeId":"ZOK1","title":"Ai Ngoài Anh","artistsNames":"VSTRA","duration":200,"hasLyric":true}]}}`
	run := func(fileStatus int, fileBody string) (zingResult, bool) {
		zingSimpleFake(t, func(r *http.Request, target string) (int, string) {
			switch target {
			case "https://zingmp3.vn" + zingSearchPath:
				return http.StatusOK, search
			case "https://zingmp3.vn" + zingLyricPath:
				return http.StatusOK, zingTestLyric(fileURL)
			case fileURL:
				return fileStatus, fileBody
			}
			return http.StatusNotFound, ""
		})
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		r := resolveZingLyric(ctx, "VSTRA", "Ai Ngoài Anh", "", 200)
		return r, sub.complete(ctx)
	}
	// LRC 文件跟逐字对不上:逐行用文件,逐字不带。
	other := "[00:21.84]Một câu khác hẳn\n[00:24.00]Câu nữa cũng khác\n[00:26.00]Lại khác\n"
	if r, complete := run(http.StatusOK, other); r.lyrics != other || r.yrc != "" || !complete {
		t.Errorf("逐字对不上不带: %+v complete=%v", r, complete)
	}
	// 文件 404:算没有,逐行用 sentences 拼,逐字照带。
	if r, complete := run(http.StatusNotFound, ""); r.lyrics != zingTestLRC || r.yrc == "" || !complete {
		t.Errorf("文件 404 时用 sentences: %+v complete=%v", r, complete)
	}
	// 文件 500:没问成,逐行照用 sentences 拼的,逐字不带(没东西对),这一轮不算完整。
	if r, complete := run(http.StatusInternalServerError, ""); r.lyrics == "" || r.yrc != "" || complete {
		t.Errorf("文件没问成不算完整、逐字不带: %+v complete=%v", r, complete)
	}
}

func TestZingLyricCachesOnlyCompleteRounds(t *testing.T) {
	var mu sync.Mutex
	hits := 0
	fileStatus := http.StatusInternalServerError
	const fileURL = "https://static-zmp3.zmdcdn.me/lyrics/c.lrc"
	zingSimpleFake(t, func(r *http.Request, target string) (int, string) {
		mu.Lock()
		defer mu.Unlock()
		switch target {
		case "https://zingmp3.vn" + zingSearchPath:
			hits++
			return http.StatusOK, `{"err":0,"data":{"items":[{"encodeId":"ZOK1","title":"Ai Ngoài Anh","artistsNames":"VSTRA","duration":200,"hasLyric":true}]}}`
		case "https://zingmp3.vn" + zingLyricPath:
			return http.StatusOK, zingTestLyric(fileURL)
		case fileURL:
			return fileStatus, zingTestLRC
		}
		return http.StatusNotFound, ""
	})
	searches := func() int { mu.Lock(); defer mu.Unlock(); return hits }
	zingLyric(qqRoundCtx(), "VSTRA", "Ai Ngoài Anh", "", 200)
	first := searches()
	zingLyric(qqRoundCtx(), "VSTRA", "Ai Ngoài Anh", "", 200)
	if searches() == first {
		t.Fatal("没问全的结果不该进缓存")
	}
	mu.Lock()
	fileStatus = http.StatusOK
	mu.Unlock()
	zingLyric(qqRoundCtx(), "VSTRA", "Ai Ngoài Anh", "", 200)
	n := searches()
	if r := zingLyric(qqRoundCtx(), "VSTRA", "Ai Ngoài Anh", "", 200); searches() != n || r.yrc == "" {
		t.Errorf("问全了进缓存,同一首不再请求: %+v", r)
	}
}

func TestZingKeyRotationAndRejection(t *testing.T) {
	var mu sync.Mutex
	accept := map[string]bool{zingKeys[1].apiKey: true}
	seen := map[string]int{}
	zingSimpleFake(t, func(r *http.Request, target string) (int, string) {
		mu.Lock()
		defer mu.Unlock()
		k := r.URL.Query().Get("apiKey")
		seen[k]++
		if !accept[k] {
			return http.StatusOK, `{"err":-104,"msg":"Incorect signature"}`
		}
		return http.StatusOK, zingTestEmptySearch
	})
	// 第一组被拒:换第二组再发,记住第二组。
	if _, err := zingSearch(qqRoundCtx(), "x"); err != nil {
		t.Fatalf("第二组能用时应成功: %v", err)
	}
	if zingKeyIdx.Load() != 1 || seen[zingKeys[0].apiKey] != 1 || seen[zingKeys[1].apiKey] != 1 {
		t.Fatalf("应挪到第二组: idx=%d seen=%v", zingKeyIdx.Load(), seen)
	}
	if _, err := zingSearch(qqRoundCtx(), "x"); err != nil || seen[zingKeys[0].apiKey] != 1 {
		t.Fatalf("之后直接用第二组: err=%v seen=%v", err, seen)
	}
	// 全被拒(含 apiKey 不认的 -116):报失败原因、整源暂停,每组只试一次。
	mu.Lock()
	accept = map[string]bool{}
	clear(seen)
	mu.Unlock()
	if _, err := zingSearch(qqRoundCtx(), "x"); err != errZingKeysRejected {
		t.Fatalf("全被拒: %v", err)
	}
	if zingLastFailureReasonNow() != lyricFailureReasonZingSignatureRejected {
		t.Errorf("失败原因: %q", zingLastFailureReasonNow())
	}
	if seen[zingKeys[0].apiKey] != 1 || seen[zingKeys[1].apiKey] != 1 {
		t.Errorf("每组只试一次: %v", seen)
	}
	if _, blocked := sharedLyricSourceBreaker().blockedFor(lyricSourceZing); !blocked {
		t.Error("全被拒时整源暂停")
	}
	// 又答了一次 err 0:失败原因、暂停都撤掉。
	mu.Lock()
	accept = map[string]bool{zingKeys[0].apiKey: true}
	mu.Unlock()
	if _, err := zingSearch(qqRoundCtx(), "x"); err != nil {
		t.Fatalf("恢复后: %v", err)
	}
	if zingLastFailureReasonNow() != "" {
		t.Error("正经答了一次应清掉失败原因")
	}
	if _, blocked := sharedLyricSourceBreaker().blockedFor(lyricSourceZing); blocked {
		t.Error("正经答了一次应撤掉暂停")
	}
}

func TestZingCallErrorsAreNotAnswers(t *testing.T) {
	for _, body := range []string{`{"err":-1,"msg":"x"}`, `{"msg":"no err"}`, `<html>`} {
		zingSimpleFake(t, func(*http.Request, string) (int, string) { return http.StatusOK, body })
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		if r := resolveZingLyric(ctx, "VSTRA", "Ai Ngoài Anh", "", 200); r.lyrics != "" || sub.complete(ctx) {
			t.Errorf("%s:应算没问成: %+v complete=%v", body, r, sub.complete(ctx))
		}
		if zingLastFailureReasonNow() != "" {
			t.Errorf("%s:别的错误不报签名失效", body)
		}
	}
	// -201 但没下发 cookie:不重发,算没问成。
	calls := 0
	// 共享传输层把所有主机都导到假服务器;只数 Zing 的搜索请求。
	zingSimpleFake(t, func(_ *http.Request, target string) (int, string) {
		if target == "https://zingmp3.vn"+zingSearchPath {
			calls++
		}
		return http.StatusOK, `{"err":-201}`
	})
	if _, err := zingSearch(qqRoundCtx(), "x"); err == nil || calls != 1 {
		t.Errorf("没下发 cookie 的 -201 不重发: err=%v calls=%d", err, calls)
	}
	// 搜索答了没有:这一轮完整、没有结果。
	zingSimpleFake(t, func(*http.Request, string) (int, string) { return http.StatusOK, zingTestEmptySearch })
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	if r := resolveZingLyric(ctx, "VSTRA", "Ai Ngoài Anh", "", 200); r.lyrics != "" || !sub.complete(ctx) {
		t.Errorf("搜不到是答了: %+v", r)
	}
}

func TestRankLyricSourceResultsZing(t *testing.T) {
	var lrc, yrc strings.Builder
	for i := 0; i < 20; i++ {
		ms := (10 + i*10) * 1000
		w := fmt.Sprintf("Câu%c", 'A'+i)
		lrc.WriteString(formatLRCStamp(ms) + w + " một\n")
		fmt.Fprintf(&yrc, "[%d,2000](%d,1000,0)%s (%d,1000,0)một\n", ms, ms, w, ms+1000)
	}
	for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, map[string]lyricSourceResult{"zing": {source: "zing",
		lyr: lrc.String(), yrc: yrc.String(), srcDur: 220, matchTitle: "Song", matchArtist: "Artist", matchCover: "https://photo-zmp3.zmdcdn.me/cover/x.jpg"}}) {
		if c.Source == "zing" {
			if !c.HasWordTiming || c.LyricsYRC == "" || c.CoverURL == "" || c.Score < 0 {
				t.Errorf("逐字、封面进候选: %+v", c)
			}
			return
		}
	}
	t.Fatal("没有 zing 候选")
}

// 密钥全被拒之后,别名轮不再为 Zing 换写法重问;别的源不受影响。
func TestLyricSourcesWorthRetrySkipsZingAfterKeysRejected(t *testing.T) {
	resetZingState(t)
	before := lyricSourcesWorthRetry(context.Background(), nil)
	if !slices.Contains(before, lyricSourceZing) {
		t.Skipf("用例前提:zing 该在名单里(本机设置关了这个源?) %v", before)
	}
	zingSetLastFailureReason(lyricFailureReasonZingSignatureRejected)
	after := lyricSourcesWorthRetry(context.Background(), nil)
	if slices.Contains(after, lyricSourceZing) {
		t.Errorf("签名被拒时 zing 不该进别名轮: %v", after)
	}
	if len(after) != len(before)-1 {
		t.Errorf("别的源不受影响: before=%v after=%v", before, after)
	}
}
