package main

import (
	"net/http"
	"strings"
	"testing"
)

// 下面几条复用 kugoufallback_test.go 的 withKugouFake:它把真实主机名经改写的传输层指到本地
// (80 走明文、443 走 TLS),按 "scheme://主机/路径" 分发,跟哪个源无关。

func TestKuwoSearchFallsBackToHTTP(t *testing.T) {
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://search.kuwo.cn/r.s":
			return http.StatusBadGateway, ""
		case "http://search.kuwo.cn/r.s":
			return http.StatusOK, `{"abslist":[{"MUSICRID":"MUSIC_1","SONGNAME":"浮夸"}]}`
		}
		return http.StatusNotFound, ""
	})
	items, err := kuwoSearch(qqRoundCtx(), "陈奕迅", "浮夸")
	if err != nil || len(items) != 1 {
		t.Fatalf("该从 http 拿到: %+v %v", items, err)
	}
}

func TestKuwoFetchLyricFallsBackToWWW(t *testing.T) {
	f := withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://kuwo.cn/openapi/v1/www/lyric/getlyric":
			return http.StatusServiceUnavailable, ""
		case "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric":
			return http.StatusOK, `{"code":200,"data":{"lrclist":[{"lineLyric":"a","time":"1.0"}]}}`
		}
		return http.StatusNotFound, ""
	})
	lines, err := kuwoFetchLyric(qqRoundCtx(), "1")
	if err != nil || len(lines) != 1 {
		t.Fatalf("该从 www 主机拿到: %+v %v", lines, err)
	}
	if f.count("http://kuwo.cn/openapi/v1/www/lyric/getlyric") != 0 {
		t.Error("拿到了就停")
	}
}

func TestMiguSearchAndAlbumFallBackAcrossHosts(t *testing.T) {
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do",
			"https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do":
			return http.StatusInternalServerError, ""
		case "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do":
			return http.StatusOK, `{"code":"000000","songResultData":{"result":[{"id":"1","name":"浮夸"}]}}`
		case "https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do":
			return http.StatusOK, `{"code":"000000","resource":[{"resourceType":"2003","albumId":"7060","imgItems":[{"img":"https://d.musicapp.migu.cn/a.jpg","imgSizeType":"03"}]}]}`
		}
		return http.StatusNotFound, ""
	})
	items, err := miguSearch(qqRoundCtx(), "陈奕迅", "浮夸")
	if err != nil || len(items) != 1 {
		t.Fatalf("搜索该从备用主机拿到: %+v %v", items, err)
	}
	miguAlbumCoverMu.Lock()
	delete(miguAlbumCoverCache, "7060")
	miguAlbumCoverMu.Unlock()
	if cover := miguAlbumCover(qqRoundCtx(), "7060"); cover != "https://d.musicapp.migu.cn/a.jpg" {
		t.Fatalf("专辑封面该从备用主机拿到: %q", cover)
	}
}

func TestSodaSeoTrackFallsBackToQishui(t *testing.T) {
	withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://beta-luna.douyin.com/luna/h5/seo_track":
			return http.StatusBadGateway, ""
		case "https://api.qishui.com/luna/h5/seo_track":
			return http.StatusOK, `{"seo_track":{"track":{"id":"6732662878991566849","name":"浮夸"}},"lyric":{"content":""}}`
		}
		return http.StatusNotFound, ""
	})
	_, _, broken, err := sodaFetchSeoTrack(qqRoundCtx(), "6732662878991566849")
	if err != nil || broken {
		t.Fatalf("该从 api.qishui.com 拿到认得出的响应: broken=%v err=%v", broken, err)
	}
}

func TestYTMusicPostFallsBackAcrossInnerTubeHosts(t *testing.T) {
	f := withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://music.youtube.com/youtubei/v1/search":
			return http.StatusInternalServerError, ""
		case "https://youtubei.googleapis.com/youtubei/v1/search":
			return http.StatusOK, `{"ok":true}`
		}
		return http.StatusNotFound, ""
	})
	body, err := ytmusicPost(qqRoundCtx(), "search", map[string]any{"query": "x"}, "")
	if err != nil || !strings.Contains(string(body), `"ok":true`) {
		t.Fatalf("该从备用 InnerTube 主机拿到: %s %v", body, err)
	}
	if f.count("https://www.youtube.com/youtubei/v1/search") != 0 {
		t.Error("拿到了就停")
	}
}

// AMLL:原始仓库没问成换 jsDelivr;原始仓库回 404(库里没有)是答了,不换镜像。
func TestAmllFetchMirrors(t *testing.T) {
	f := withKugouFake(t, func(target string) (int, string) {
		switch target {
		case "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/ncm-lyrics/1.ttml":
			return http.StatusBadGateway, ""
		case "https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main/ncm-lyrics/1.ttml":
			return http.StatusOK, "<tt/>"
		}
		return http.StatusNotFound, ""
	})
	if body, ok := amllFetch(qqRoundCtx(), "ncm-lyrics", "1"); !ok || body != "<tt/>" {
		t.Fatalf("该从 jsDelivr 拿到: %q %v", body, ok)
	}
	if _, ok := amllFetch(qqRoundCtx(), "ncm-lyrics", "2"); ok {
		t.Fatal("库里没有的不该拿到")
	}
	if f.count("https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main/ncm-lyrics/2.ttml") != 0 {
		t.Error("原始仓库回 404 是答了,不该再问镜像")
	}
}

// 备用主机都要归到对应的歌词源,熔断和传输层分类才认得它们。
func TestFallbackHostsMapToTheirLyricSource(t *testing.T) {
	cases := map[string]string{
		"youtubei.googleapis.com":  "lyricfind",
		"www.youtube.com":          "lyricfind",
		"cdn.jsdelivr.net":         "amll",
		"fastly.jsdelivr.net":      "amll",
		"api.qishui.com":           "soda",
		"www.kuwo.cn":              "kuwo",
		"c.musicapp.migu.cn":       "migu",
		"interface3.music.163.com": "netease",
		"ioscdn.kugou.com":         "kugou",
		"shu.y.qq.com":             "qq",
	}
	for host, want := range cases {
		if got := lyricSourceForHost(host); got != want {
			t.Errorf("%s: got %q, want %q", host, got, want)
		}
	}
}
