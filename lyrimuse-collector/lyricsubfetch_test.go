package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/base64"
	"net/http"
	"strings"
	"sync"
	"testing"
)

func TestLyricSubFetchComplete(t *testing.T) {
	ctx, f := withLyricSubFetch(context.Background())
	if !f.complete(ctx) {
		t.Fatal("什么都没发生时应当算完整")
	}
	noteLyricSubFetchFailure(context.Background()) // 没挂记录器:什么都不做
	inner, g := withLyricSubFetch(ctx)
	noteLyricSubFetchFailure(inner)
	if !f.complete(ctx) || g.complete(inner) {
		t.Fatal("内层的失败只记在内层")
	}
	noteLyricSubFetchFailure(ctx)
	if f.complete(ctx) {
		t.Fatal("记过失败就不完整")
	}
	c, cancel := context.WithCancel(context.Background())
	c, h := withLyricSubFetch(c)
	cancel()
	if h.complete(c) {
		t.Fatal("ctx 被取消就不完整")
	}
}

func resetSourceCachesForTest(t *testing.T) {
	t.Helper()
	neteaseMu.Lock()
	savedNE := neteaseCache
	neteaseCache = map[string]neteaseCacheEntry{}
	neteaseMu.Unlock()
	kugouMu.Lock()
	savedKG := kugouCache
	kugouCache = map[string]kugouResult{}
	kugouMu.Unlock()
	lrclibMu.Lock()
	savedLR := lrclibCache
	lrclibCache = map[string]lrclibResult{}
	lrclibMu.Unlock()
	t.Cleanup(func() {
		neteaseMu.Lock()
		neteaseCache = savedNE
		neteaseMu.Unlock()
		kugouMu.Lock()
		kugouCache = savedKG
		kugouMu.Unlock()
		lrclibMu.Lock()
		lrclibCache = savedLR
		lrclibMu.Unlock()
	})
}

// 网易云:取词两个接口都没问成、封面照样拿到时,这份结果不进缓存,下一次重新取词。
func TestNeteaseLookupSkipsCacheWhenLyricFetchFails(t *testing.T) {
	resetSourceCachesForTest(t)
	lyricOK := false
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520}]}}`
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case strings.HasSuffix(target, "/api/song/lyric/v1"):
			if lyricOK {
				return http.StatusOK, `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(neV1Lyric) + `},"yrc":{"lyric":""}}`
			}
			return http.StatusInternalServerError, ""
		case strings.HasSuffix(target, "/api/song/lyric"):
			return http.StatusInternalServerError, ""
		}
		return http.StatusNotFound, ""
	})
	first := neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if first.Lyrics != "" || first.Cover == "" {
		t.Fatalf("前提:没取到词、拿到了封面: %+v", first)
	}
	searches := f.count("music.163.com/api/search/get")
	neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if f.count("music.163.com/api/search/get") == searches {
		t.Fatal("没取到词的结果不该进缓存")
	}
	lyricOK = true
	neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	searches = f.count("music.163.com/api/search/get")
	got := neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if got.Lyrics == "" || f.count("music.163.com/api/search/get") != searches {
		t.Fatalf("完整的结果应当缓存: lyrics=%q", got.Lyrics)
	}
}

// 网易云:v1 没问成、退到老歌词接口拿到了整行,但这次缺的逐字是故障造成的,这份结果不进缓存。
func TestNeteaseLookupSkipsCacheWhenOnlyOldLyricEndpointAnswers(t *testing.T) {
	resetSourceCachesForTest(t)
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520}]}}`
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case strings.HasSuffix(target, "/api/song/lyric/v1"):
			return http.StatusInternalServerError, ""
		case strings.HasSuffix(target, "/api/song/lyric"):
			return http.StatusOK, `{"code":200,"lrc":{"lyric":"[00:28.948]有人问我\n[00:36.141]我期待\n[00:44.000]第三句\n[00:52.000]第四句"}}`
		}
		return http.StatusNotFound, ""
	})
	first := neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if first.Lyrics == "" || first.YRC != "" {
		t.Fatalf("前提:老接口给了整行、没有逐字: %+v", first)
	}
	searches := f.count("music.163.com/api/search/get")
	neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if f.count("music.163.com/api/search/get") == searches {
		t.Fatal("缺逐字是因为 v1 没问成,这份结果不该进缓存")
	}
}

// 酷狗:整行拿到了、逐字那一趟两个主机都没问成,这份结果不进缓存。
func TestKugouLyricSkipsCacheWhenKRCDownloadFails(t *testing.T) {
	resetSourceCachesForTest(t)
	t.Setenv("HOME", t.TempDir()) // 别读到这台机器上酷狗客户端的本地缓存
	lrc := "[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n"
	var mu sync.Mutex
	downloads := 0
	krcOK := false
	f := withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "http://mobilecdn.kugou.com/api/v3/search/song":
			return http.StatusOK, kgSearchHit
		case "http://krcs.kugou.com/search":
			return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}`
		case "http://lyrics.kugou.com/download", "http://krcs.kugou.com/download":
			mu.Lock()
			downloads++
			n := downloads
			mu.Unlock()
			if n == 1 || krcOK { // 第一次是整行,之后是逐字
				return http.StatusOK, `{"status":200,"content":"` + base64.StdEncoding.EncodeToString([]byte(lrc)) + `"}`
			}
			return http.StatusServiceUnavailable, ""
		}
		return http.StatusNotFound, ""
	})
	if r := kugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283); r.lrc != lrc {
		t.Fatalf("前提:整行拿到了: %+v", r)
	}
	searches := f.count("http://mobilecdn.kugou.com/api/v3/search/song")
	mu.Lock()
	downloads, krcOK = 0, true
	mu.Unlock()
	kugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if f.count("http://mobilecdn.kugou.com/api/v3/search/song") == searches {
		t.Fatal("逐字没问成的结果不该进缓存")
	}
	searches = f.count("http://mobilecdn.kugou.com/api/v3/search/song")
	kugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if f.count("http://mobilecdn.kugou.com/api/v3/search/song") != searches {
		t.Fatal("完整的结果应当缓存")
	}
}

// 酷我逐字、咪咕逐字:一个主机都没问成记失败;问成了、解不开的是这首没有,不记。
func TestKuwoAndMiguWordTimingFetchReportFailures(t *testing.T) {
	status := http.StatusServiceUnavailable
	withKugouFake(t, func(target string) (int, string) {
		if status != http.StatusOK {
			return status, ""
		}
		return http.StatusOK, "garbage"
	})
	ctx, f := withLyricSubFetch(qqRoundCtx())
	kuwoFetchLrcxYRC(ctx, "123")
	if f.complete(ctx) {
		t.Error("酷我 lrcx 两个主机都没问成应当记失败")
	}
	ctx, f = withLyricSubFetch(qqRoundCtx())
	miguFetchMRCYRC(ctx, "https://d.musicapp.migu.cn/x.mrc")
	if f.complete(ctx) {
		t.Error("咪咕 MRC 没问成应当记失败")
	}
	status = http.StatusOK
	ctx, f = withLyricSubFetch(qqRoundCtx())
	kuwoFetchLrcxYRC(ctx, "123")
	miguFetchMRCYRC(ctx, "https://d.musicapp.migu.cn/x.mrc")
	if !f.complete(ctx) {
		t.Error("问成了、内容解不开是这首没有逐字,不该记失败")
	}
}

// LRCLIB:get 层只有纯文本、或时长对不上时不提前收工,search 层的带时间轴版本优先;search 也没有才用兜底。
func TestLRCLIBGetPlainOrMismatchFallsThroughToSearch(t *testing.T) {
	resetSourceCachesForTest(t)
	synced := `[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n[00:04.00]d`
	var getBody, searchBody string
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://lrclib.net/api/get":
			return http.StatusOK, getBody
		case "https://lrclib.net/api/search":
			return http.StatusOK, searchBody
		}
		return http.StatusNotFound, ""
	})
	searchHit := `[{"trackName":"Song","artistName":"Artist","albumName":"Album","duration":200,"syncedLyrics":"` + synced + `"}]`
	cases := []struct {
		name      string
		get       string
		search    string
		wantPlain bool
		wantDur   float64
	}{
		{"get 纯文本 → search 带时间轴", `{"trackName":"Song","artistName":"Artist","duration":200,"plainLyrics":"a\nb"}`, searchHit, false, 200},
		{"get 时长差很多 → search 对得上", `{"trackName":"Song","artistName":"Artist","duration":600,"syncedLyrics":"` + synced + `"}`, searchHit, false, 200},
		{"get 纯文本、search 也没有 → 用纯文本兜底", `{"trackName":"Song","artistName":"Artist","duration":200,"plainLyrics":"a\nb"}`, `[]`, true, 200},
		{"get 带时间轴、时长对得上 → 直接用", `{"trackName":"Song","artistName":"Artist","duration":201,"syncedLyrics":"` + synced + `"}`, `[]`, false, 201},
	}
	for _, c := range cases {
		getBody, searchBody = c.get, c.search
		r := resolveLRCLIBLyric(qqRoundCtx(), "Artist", "Song", "", 200)
		if r.lyrics == "" || r.plainOnly != c.wantPlain || r.durationSecs != c.wantDur {
			t.Errorf("%s: got %+v", c.name, r)
		}
	}
}

// KRC 解压封顶:压缩炸弹不解。正常大小照常解。
func TestDecryptKRCBytesCapsDecompressedSize(t *testing.T) {
	encode := func(payload []byte) []byte {
		var z bytes.Buffer
		w := zlib.NewWriter(&z)
		w.Write(payload)
		w.Close()
		body := z.Bytes()
		out := append([]byte("krc1"), make([]byte, len(body))...)
		for i, b := range body {
			out[4+i] = b ^ krcXORKey[i%len(krcXORKey)]
		}
		return out
	}
	if got := decryptKRCBytes(encode([]byte("[0,100]<0,100,0>词"))); got != "[0,100]<0,100,0>词" {
		t.Fatalf("正常 KRC 应当解开: %q", got)
	}
	if got := decryptKRCBytes(encode(make([]byte, krcDecompressedMaxBytes+1))); got != "" {
		t.Fatalf("超过上限的不该解: %d 字节", len(got))
	}
}

// 网易云:v1 没问成、它的 eapi 写法答了(带逐字),这份结果是完整的,进缓存。
func TestNeteaseLookupCachesWhenEapiLyricAnswers(t *testing.T) {
	resetSourceCachesForTest(t)
	f := withNeteaseFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/api/search/get"):
			return http.StatusOK, `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520}]}}`
		case strings.HasSuffix(target, "/api/song/detail"):
			return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
		case strings.HasSuffix(target, "/api/song/lyric/v1"):
			return http.StatusInternalServerError, ""
		case target == "music.163.com/eapi/song/lyric/v1":
			return http.StatusOK, `{"code":200,"lrc":{"lyric":"[00:28.948]有人问我\n[00:36.141]我期待\n[00:44.000]第三句\n[00:52.000]第四句"},"yrc":{"lyric":"[28948,2000](28948,500,0)有(29448,500,0)人"}}`
		}
		return http.StatusNotFound, ""
	})
	first := neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if first.Lyrics == "" || first.YRC == "" {
		t.Fatalf("前提:eapi 给了整行和逐字: %+v", first)
	}
	searches := f.count("music.163.com/api/search/get")
	neteaseLookupAll(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283)
	if f.count("music.163.com/api/search/get") != searches {
		t.Fatal("eapi 答了、结果完整,第二次该命中缓存")
	}
}
