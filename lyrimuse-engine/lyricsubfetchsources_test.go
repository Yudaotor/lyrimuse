package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// 各源「排在前面的没问成、退到后面的」时记一次没问成,这一份不进缓存;问全了照常算完整。见 lyricsubfetch.go。

// 酷我:时长最贴近的那条取词没问成、退到下一条:不完整。那条答了「没有词」、退到下一条:完整。
func TestKuwoRankedFetchFailureIsIncomplete(t *testing.T) {
	const search = `{"abslist":[` +
		`{"MUSICRID":"MUSIC_1","SONGNAME":"雨眠","ARTIST":"五月天","ALBUM":"","DURATION":"222"},` +
		`{"MUSICRID":"MUSIC_2","SONGNAME":"雨眠","ARTIST":"五月天","ALBUM":"","DURATION":"240"}]}`
	const lines = `{"code":200,"data":{"lrclist":[{"time":"1.0","lineLyric":"一"},{"time":"2.0","lineLyric":"二"},{"time":"3.0","lineLyric":"三"},{"time":"4.0","lineLyric":"四"}]}}`
	for _, c := range []struct {
		name         string
		firstDown    bool
		wantComplete bool
	}{
		{"第一名没问成", true, false},
		{"第一名答了没有词", false, true},
	} {
		withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "search.kuwo.cn/r.s"):
				return http.StatusOK, search
			case strings.HasSuffix(target, "/openapi/v1/www/lyric/getlyric"):
				if r.URL.Query().Get("musicId") == "1" {
					if c.firstDown {
						return http.StatusBadGateway, ""
					}
					return http.StatusOK, `{"code":200,"data":{"lrclist":[]}}`
				}
				return http.StatusOK, lines
			case strings.HasSuffix(target, "mlyric.kuwo.cn/mobi.s"):
				if r.URL.Query().Get("lrcx") == "0" && c.firstDown {
					return http.StatusBadGateway, ""
				}
				return http.StatusOK, "TP=none\r\n\r\n"
			}
			return http.StatusNotFound, ""
		})
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		r := resolveKuwoLyric(ctx, "五月天", "雨眠", "", 222)
		if r.lyrics == "" {
			t.Fatalf("%s: 应退到第二条: %+v", c.name, r)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("%s: complete = %v,期望 %v", c.name, got, c.wantComplete)
		}
	}
}

// 酷狗查专辑封面:没问成记一次;404(没有这张专辑)不算。
func TestKugouAlbumCoverFailureIsIncomplete(t *testing.T) {
	for _, c := range []struct {
		status       int
		wantComplete bool
	}{
		{http.StatusBadGateway, false}, {http.StatusNotFound, true},
	} {
		withKugouFake(t, func(target string) (int, string) { return c.status, "" })
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		if got := kugouAlbumCoverURL(ctx, "123"); got != "" {
			t.Fatalf("取不到封面应为空: %q", got)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("status %d: complete = %v,期望 %v", c.status, got, c.wantComplete)
		}
	}
}

// 汽水:seo_track 没问成、改用分享页(不带译文):不完整,不进缓存。
func TestSodaSharePageResultNotCached(t *testing.T) {
	sharePage := string(sodaTestSharePage(`{` + sodaTestShareTrackInfo + `,"lyrics":{"lyricType":"krc","sentences":[` +
		`{"startMs":19650,"endMs":26500,"text":"当我","words":[{"startMs":19650,"endMs":20020,"text":"当"}]},` +
		`{"startMs":27410,"endMs":34380,"text":"伤你","words":[{"startMs":27410,"endMs":27780,"text":"伤"}]}]}}`))
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://beta-luna.douyin.com/luna/h5/seo_track", "https://api.qishui.com/luna/h5/seo_track":
			return http.StatusBadGateway, ""
		case "https://music.douyin.com/qishui/share/track":
			return http.StatusOK, sharePage
		}
		return http.StatusNotFound, ""
	})
	sodaMu.Lock()
	saved := sodaCache
	sodaCache = map[string]sodaResult{}
	sodaMu.Unlock()
	t.Cleanup(func() {
		sodaMu.Lock()
		sodaCache = saved
		sodaMu.Unlock()
	})
	r, _ := sodaLyricByID(qqRoundCtx(), "6705555863068739585", "a", "b")
	if r.empty() {
		t.Fatal("分享页给了词,应当交出")
	}
	sodaMu.Lock()
	_, cached := sodaCache["6705555863068739585"]
	sodaMu.Unlock()
	if cached {
		t.Fatal("分享页那份不带译文,不该缓存")
	}
}

// LyricFind:带时间戳那一趟没问成(所有主机都失败)记一次。
func TestYtmusicTimedLyricsFailureIsIncomplete(t *testing.T) {
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) { return http.StatusBadGateway, nil, "" })
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	if lrc, _ := ytmusicFetchTimedLyrics(ctx, "MPLYt_x"); lrc != "" {
		t.Fatalf("没问成应为空: %q", lrc)
	}
	if sub.complete(ctx) {
		t.Fatal("没问成应记下")
	}
}

// Apple Music:按名字搜索没问成记一次;按目录 id 取到 404(没上架)不算。
func TestApplemusicSearchFailureIsIncomplete(t *testing.T) {
	withApplemusicCreds(t, "cn")
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		if strings.HasSuffix(r.URL.Path, "/search") {
			return http.StatusInternalServerError, nil, ""
		}
		return http.StatusNotFound, nil, ""
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	if got := applemusicSongByID(ctx, "cn", "9", "test-dev-token"); got != nil || !sub.complete(ctx) {
		t.Fatalf("目录 id 404 是没上架、不算没问成: %v complete=%v", got, sub.complete(ctx))
	}
	if got := applemusicNameCandidates(ctx, "cn", "A", "T", "", 200, "test-dev-token"); got != nil || sub.complete(ctx) {
		t.Fatalf("搜索没问成应记下: %v complete=%v", got, sub.complete(ctx))
	}
}

// Apple Music:纯文本结果是在搜索没问成时退下来的就不缓存;带时间轴的照缓存。
func TestApplemusicPlainOnlyCachedOnlyWhenComplete(t *testing.T) {
	withApplemusicCreds(t, "cn")
	t.Setenv("HOME", t.TempDir()) // 别读到这台机器上 Music.app 的本地歌词缓存
	applemusicMu.Lock()
	saved := applemusicCache
	applemusicCache = map[string]applemusicResult{}
	applemusicMu.Unlock()
	t.Cleanup(func() {
		applemusicMu.Lock()
		applemusicCache = saved
		applemusicMu.Unlock()
	})
	song := amTestSong("9", "革命", "范逸臣", "无乐不作", 240000, false)
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/songs/9"):
			b, _ := json.Marshal(map[string]any{"data": []applemusicSong{song}})
			return http.StatusOK, nil, string(b)
		case strings.HasSuffix(r.URL.Path, "/songs/9/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestUntimedTTML)
		case strings.HasSuffix(r.URL.Path, "/search"):
			return http.StatusInternalServerError, nil, ""
		}
		return http.StatusNotFound, nil, ""
	})
	r := applemusicLyric(qqRoundCtx(), "范逸臣", "革命", "无乐不作", 240, "9", "")
	if !r.plainOnly {
		t.Fatalf("前提:目录 id 那条只有纯文本: %+v", r)
	}
	applemusicMu.Lock()
	n := len(applemusicCache)
	applemusicMu.Unlock()
	if n != 0 {
		t.Fatal("搜索没问成时退下来的纯文本不该缓存")
	}
}

// Musixmatch:说有字幕却没问成(拒绝码、连不上)记一次;404 是这首没有,不记。
func TestMusixmatchSubtitleFailureIsIncomplete(t *testing.T) {
	t.Cleanup(func() { musixmatchSetLastFailureReason("") })
	var code string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"message":{"header":{"status_code":` + code + `},"body":{}}}`))
	}))
	defer srv.Close()
	savedBases := musixmatchBases
	musixmatchBases = []string{srv.URL + "/"}
	t.Cleanup(func() { musixmatchBases = savedBases })
	musixmatchTokenMu.Lock()
	savedTok, savedExp := musixmatchToken, musixmatchTokenExpiry
	musixmatchToken, musixmatchTokenExpiry = "tok", time.Now().Add(time.Hour)
	musixmatchTokenMu.Unlock()
	t.Cleanup(func() {
		musixmatchTokenMu.Lock()
		musixmatchToken, musixmatchTokenExpiry = savedTok, savedExp
		musixmatchTokenMu.Unlock()
	})
	for _, c := range []struct {
		code         string
		wantComplete bool
	}{
		{"500", false}, {"404", true},
	} {
		code = c.code
		ctx, sub := withLyricSubFetch(context.Background())
		if lrc := musixmatchSubtitleLRC(ctx, 1); lrc != "" {
			t.Fatalf("%s: 应为空: %q", c.code, lrc)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("status_code %s: complete = %v,期望 %v", c.code, got, c.wantComplete)
		}
	}
	srv.Close()
	ctx, sub := withLyricSubFetch(context.Background())
	musixmatchSubtitleLRC(ctx, 1)
	if sub.complete(ctx) {
		t.Error("连不上也应记下")
	}
}

// Deezer:搜索说有同步歌词的那条取词没问成、退到下一条:不完整。
func TestDeezerRankedFetchFailureIsIncomplete(t *testing.T) {
	for _, c := range []struct {
		name         string
		firstDown    bool
		wantComplete bool
	}{
		{"第一条没问成", true, false},
		{"都问成了", false, true},
	} {
		withDeezerFake(t, func(call dzCall) (int, string) {
			switch call.op {
			case "SearchTracks":
				return http.StatusOK, dzSearchResponse(
					dzHit{"1", "稻香", "周杰伦", "魔杰座", 223, true},
					dzHit{"2", "稻香", "周杰伦", "魔杰座", 223, true})
			case "SynchronizedTrackLyrics":
				if c.firstDown && fmt.Sprint(call.vars["trackId"]) == "1" {
					return http.StatusInternalServerError, ""
				}
				return http.StatusOK, dzLyricsResponse(dzSixLines...)
			}
			return 0, ""
		})
		ctx, sub := withLyricSubFetch(context.Background())
		if r := resolveDeezerLyric(ctx, "周杰伦", "稻香", "魔杰座", 223, ""); r.lyrics == "" {
			t.Fatalf("%s: 应拿到歌词: %+v", c.name, r)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("%s: complete = %v,期望 %v", c.name, got, c.wantComplete)
		}
	}
}

// 咪咕:排在前面那条取词没问成、退到下一条:不完整;都问成了:完整。
func TestMiguRankedFetchFailureIsIncomplete(t *testing.T) {
	const hit = `{"code":"000000","songResultData":{"result":[` +
		`{"name":"oh well","singers":[{"name":"Ariana Grande"}],"lyricUrl":"https://d.musicapp.migu.cn/l/1.lrc"},` +
		`{"name":"oh well","singers":[{"name":"Ariana Grande"}],"lyricUrl":"https://d.musicapp.migu.cn/l/2.lrc"}]}}`
	for _, c := range []struct {
		name         string
		firstDown    bool
		wantComplete bool
	}{
		{"第一条没问成", true, false},
		{"都问成了", false, true},
	} {
		withKugouFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/content/search_all.do"):
				return http.StatusOK, hit
			case strings.HasSuffix(target, "/l/1.lrc"):
				if c.firstDown {
					return http.StatusInternalServerError, ""
				}
				return http.StatusOK, miguFakeLRC
			case strings.HasSuffix(target, "/l/2.lrc"):
				return http.StatusOK, miguFakeLRC
			}
			return http.StatusNotFound, ""
		})
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		if r := resolveMiguLyric(ctx, "Ariana Grande", "oh well", "", 0); r.lyrics == "" {
			t.Fatalf("%s: 应拿到歌词: %+v", c.name, r)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("%s: complete = %v,期望 %v", c.name, got, c.wantComplete)
		}
	}
}

// 网易云:查询词没问成记一次(带专辑名、最可能命中对的版本的那条没问成时,后面挑中的不进缓存)。
func TestNeteaseSearchQueryFailureIsIncomplete(t *testing.T) {
	t.Setenv("HOME", t.TempDir()) // 别读到这台机器上网易云客户端的本地曲库
	withNeteaseFake(t, func(target string) (int, string) {
		if strings.Contains(target, "/search/") || strings.Contains(target, "cloudsearch") {
			return http.StatusInternalServerError, ""
		}
		return http.StatusNotFound, ""
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	resolveNeteaseInfo(ctx, "陈奕迅", "浮夸", "U87", 283.5)
	if sub.complete(ctx) {
		t.Fatal("查询词没问成应记下")
	}
}

// 酷狗:搜索词没问成记一次(前面的词没问成、后面的挑中时不进缓存)。
func TestKugouSearchFailureIsIncomplete(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	withKugouFake(t, func(target string) (int, string) { return http.StatusBadGateway, "" })
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	resolveKugouLyric(ctx, "陈奕迅", "浮夸", "U87", 283)
	if sub.complete(ctx) {
		t.Fatal("搜索没问成应记下")
	}
}
