package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// lyricSourceBodyRejects:当前共享出站闸里这个地址的接口记着几次被拒。
func lyricSourceBodyRejects(u *url.URL) int {
	g := sharedHostGuard()
	g.mu.Lock()
	defer g.mu.Unlock()
	if h := g.health[guardEndpointKey(u)]; h != nil {
		return h.rejects
	}
	return 0
}

func lyricSourceBodyAnswer(t *testing.T, body string) (*http.Request, *http.Response) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "https://api.example-lyrics.test/search?q=x", nil)
	if err != nil {
		t.Fatal(err)
	}
	return req, &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Request: req}
}

// 空应答体(只有空白也算)记一次被拒;有内容的应答(没搜到的 [] / {} 也是)不记,解不动的也不记。
func TestDecodeLyricSourceJSONEmptyBodyIsRejection(t *testing.T) {
	saved := sharedHostGuard()
	t.Cleanup(func() { setSharedHostGuard(saved) })
	for name, tc := range map[string]struct {
		body     string
		rejected bool
		decodes  bool
	}{
		"空应答体":    {"", true, false},
		"只有空白":    {" \r\n\t", true, false},
		"没搜到 {}":  {"{}", false, true},
		"没搜到 []":  {"[]", false, true},
		"null":    {"null", false, true},
		"不是 JSON": {"<html>", false, false},
		"后面带东西":   {`{"a":1} trailing`, false, true},
	} {
		setSharedHostGuard(newHostGuard(time.Now))
		req, resp := lyricSourceBodyAnswer(t, tc.body)
		var out any
		err := decodeLyricSourceJSON(req, resp, 1<<20, &out)
		if got := errors.Is(err, errLyricSourceEmptyAnswer); got != tc.rejected {
			t.Errorf("%s: 空应答错误=%v, want %v (err=%v)", name, got, tc.rejected, err)
		}
		if (err == nil) != tc.decodes {
			t.Errorf("%s: err=%v, want decodes=%v", name, err, tc.decodes)
		}
		want := 0
		if tc.rejected {
			want = 1
		}
		if n := lyricSourceBodyRejects(req.URL); n != want {
			t.Errorf("%s: 被拒计数 %d, want %d", name, n, want)
		}
	}
}

// 不另认拒绝的接口解得动就清掉拒绝计数;另认拒绝的(Judged)不替调用方清,否则同一次应答先清零再加一,永远攒不满。
func TestDecodeLyricSourceJSONAcceptsOnlyWhenNotJudged(t *testing.T) {
	saved := sharedHostGuard()
	t.Cleanup(func() { setSharedHostGuard(saved) })
	setSharedHostGuard(newHostGuard(time.Now))

	req, resp := lyricSourceBodyAnswer(t, "")
	_ = decodeLyricSourceJSON(req, resp, 1<<20, new(any))
	_, resp = lyricSourceBodyAnswer(t, "{}")
	if err := decodeJudgedLyricSourceJSON(req, resp, 1<<20, new(any)); err != nil {
		t.Fatal(err)
	}
	if n := lyricSourceBodyRejects(req.URL); n != 1 {
		t.Errorf("Judged 解得动不该清拒绝计数, got %d", n)
	}
	_, resp = lyricSourceBodyAnswer(t, "{}")
	if err := decodeLyricSourceJSON(req, resp, 1<<20, new(any)); err != nil {
		t.Fatal(err)
	}
	if n := lyricSourceBodyRejects(req.URL); n != 0 {
		t.Errorf("解得动该清拒绝计数, got %d", n)
	}
}

// 各歌词源的接口:连着回 200 + 空应答体,接口熔断跳闸、之后不再发出去;连着答「没有」(有内容的应答)照常问、不跳闸。
func TestLyricSourceEmptyAnswersTripEndpointBreaker(t *testing.T) {
	type source struct {
		target   string // 计数用的 scheme://host/path
		notFound string // 正常的「没有」
		call     func(ctx context.Context)
	}
	sources := map[string]source{
		"deezer 搜索": {"https://api.deezer.com/search", `{"data":[],"total":0}`,
			func(ctx context.Context) { _, _ = deezerSearch(ctx, "a", "b") }},
		"deezer ISRC": {"https://api.deezer.com/track/isrc:USX", `{"error":{"type":"DataException","code":800}}`,
			func(ctx context.Context) { _, _ = deezerTrackByISRC(ctx, "USX") }},
		"deezer 换票": {"https://auth.deezer.com/login/anonymous", `{"jwt":"x"}`,
			func(ctx context.Context) { _ = deezerFetchJWT(ctx) }},
		"酷我搜索": {"https://search.kuwo.cn/r.s", `{"abslist":[]}`,
			func(ctx context.Context) { _, _ = kuwoSearchAt(ctx, kuwoSearchEndpoints[0], "x") }},
		"酷我取词": {"https://www.kuwo.cn/openapi/v1/www/lyric/getlyric", `{"code":200,"data":{"lrclist":[]}}`,
			func(ctx context.Context) { _, _ = kuwoFetchLyricAt(ctx, "https://www.kuwo.cn", "1") }},
		"VIBE": {"https://apis.naver.com/vibeWeb/musicapiweb/vibe/v4/lyric/1", `{}`,
			func(ctx context.Context) { _ = vibeGetJSON(ctx, vibeAPIBase+"/vibe/v4/lyric/1", new(any)) }},
		"LRCLIB": {"https://lrclib.net/api/search", `[]`,
			func(ctx context.Context) {
				_ = lrclibRequest(ctx, "https://lrclib.net/api/search?q=x", time.Second, new(any))
			}},
		"酷狗 songsearch": {kugouSongSearchEndpoint, `{"status":1,"error_code":0,"data":{"lists":[]}}`,
			func(ctx context.Context) { _, _ = kugouSongSearch(ctx, "x") }},
		"酷狗 m.kugou.com": {"https://m.kugou.com/app/i/getSongInfo.php", `{}`,
			func(ctx context.Context) {
				_ = kugouGet(ctx, "https://m.kugou.com/app/i/getSongInfo.php?hash=x", new(any))
			}},
		"QQ 网关": {"https://u.y.qq.com/cgi-bin/musicu.fcg", `{"code":0,"request":{"code":0,"data":{}}}`,
			func(ctx context.Context) { _, _, _ = qqMusicuPostAt(ctx, "u.y.qq.com", []byte("{}")) }},
		"QQ 单曲详情": {"https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg", `{"data":[]}`,
			func(ctx context.Context) { _, _, _ = qqSongDetailWebAt(ctx, "c.y.qq.com", "m") }},
		"QQ 专辑曲目": {"https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg", `{"code":0,"data":{"list":[]}}`,
			func(ctx context.Context) { _, _ = qqAlbumSongsWebAt(ctx, "c.y.qq.com", "a") }},
		"QQ 整行歌词": {"https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", `{"code":-1901,"lyric":""}`,
			func(ctx context.Context) { _, _ = resolveQQLyricAt(ctx, "c.y.qq.com", "m") }},
		"QQ 智能联想": {"https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg", `{"code":0,"data":{}}`,
			func(ctx context.Context) { _, _ = qqSmartboxAt(ctx, "c.y.qq.com", "x") }},
		"咪咕搜索": {"https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do", `{"code":"000000","songResultData":{"result":[]}}`,
			func(ctx context.Context) { _, _ = miguSearchAt(ctx, "pd.musicapp.migu.cn", "x") }},
		"AMLL": {amllAPIBase + "/v1/lyrics/get", `{"data":{"lyrics":""}}`,
			func(ctx context.Context) { _, _, _ = amllFetchAPI(ctx, "ncm-lyrics", "1") }},
		"Apple Music 店面": {applemusicStorefrontsURL + "zz", `{"data":[]}`,
			func(ctx context.Context) { _ = applemusicStorefrontEnglishTag(ctx, "zz", "tok") }},
	}
	const calls = 2 * endpointTripAfter
	for name, src := range sources {
		// 交替:偶发的空应答隔着正常应答,不凑成「连着被拒」。
		for _, mode := range []string{"空应答", "没有", "交替"} {
			var mu sync.Mutex
			n := 0
			f := withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
				mu.Lock()
				defer mu.Unlock()
				n++
				if mode == "空应答" || (mode == "交替" && n%2 == 1) {
					return http.StatusOK, ""
				}
				return http.StatusOK, src.notFound
			})
			for range calls {
				src.call(qqRoundCtx())
			}
			want := calls
			if mode == "空应答" {
				want = endpointTripAfter
			}
			if got := f.count(src.target); got != want {
				t.Errorf("%s(%s):发出 %d 次, want %d", name, mode, got, want)
			}
		}
	}
}

// 歌词源读 200 应答体走 lyricsourcebody.go 的共用入口,不直接在 resp.Body 上解码:那样空应答体只是一次 EOF 失败、喂不到接口熔断。
// 只查打歌词源的文件(用 lyricHTTPClient 的)。
func TestLyricSourceBodiesUseSharedReader(t *testing.T) {
	// 例外:请求不过出站闸,接口熔断拦不住,报了也没用。
	exempt := map[string]string{
		"petitlyrics.go": "GetPetitLyricsData.php 是 POST,不在 guardReadOnlyPOST 里",
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") || exempt[f] != "" {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if !strings.Contains(src, "lyricHTTPClient(") {
			continue
		}
		for i, line := range strings.Split(src, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			if strings.Contains(line, "NewDecoder(resp.Body)") || strings.Contains(line, "NewDecoder(io.LimitReader(resp.Body") {
				t.Errorf("%s:%d 读歌词源应答体改用 decodeLyricSourceJSON / decodeJudgedLyricSourceJSON: %s", f, i+1, strings.TrimSpace(line))
			}
		}
	}
	if _, err := os.Stat("petitlyrics.go"); err != nil {
		t.Errorf("例外名单里的文件不在了,删掉那一条: %v", err)
	}
}

// Deezer GraphQL 先读整段再看状态码(401 要重换票),判空走 rejectEmptyLyricSourceBody:连着回空应答体同样跳闸。
func TestDeezerPipeEmptyAnswersTripEndpointBreaker(t *testing.T) {
	deezerClearJWT()
	t.Cleanup(deezerClearJWT)
	f := withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		if strings.HasPrefix(target, "https://auth.deezer.com/") {
			return http.StatusOK, `{"jwt":"x"}`
		}
		return http.StatusOK, ""
	})
	for range endpointTripAfter + 2 {
		_, _, _ = deezerPipeQuery(qqRoundCtx(), "op", "query", nil, "")
	}
	if n := f.count(deezerPipeAPI); n != endpointTripAfter {
		t.Errorf("跳闸后不该再发出去, 实际发了 %d 次", n)
	}
}

// 应答体里另认拒绝码的接口(酷狗搜索)用 Judged:连着回拒绝码要跳闸,共用入口不能先替它记 Accepted。
func TestKugouSongSearchRejectionCodesTripEndpointBreaker(t *testing.T) {
	f := withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		return http.StatusOK, `{"status":0,"error_code":20010}`
	})
	for range endpointTripAfter + 2 {
		_, _ = kugouSongSearch(qqRoundCtx(), "x")
	}
	if n := f.count(kugouSongSearchEndpoint); n != endpointTripAfter {
		t.Errorf("连着回拒绝码该跳闸, 实际发了 %d 次", n)
	}
}
