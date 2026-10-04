package main

import (
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// 不带 hash 查回的歌词候选怎么挑:按顺序第一条歌名、歌手、版本、时长都过的;本地时长未知一条都不收。
func TestKugouKeywordCandidate(t *testing.T) {
	cand := func(id, song, singer string, ms int) kugouLyricCandidate {
		return kugouLyricCandidate{ID: id, AccessKey: "k", Song: song, Singer: singer, Duration: ms}
	}
	for _, c := range []struct {
		name  string
		cands []kugouLyricCandidate
		dur   float64
		want  string
	}{
		{"按顺序取第一条过闸的", []kugouLyricCandidate{cand("a", "别的歌", "陈奕迅", 283000), cand("b", "浮夸", "陈奕迅", 283500), cand("c", "浮夸", "陈奕迅", 283000)}, 283, "b"},
		{"歌手对不上", []kugouLyricCandidate{cand("a", "浮夸", "张三", 283000)}, 283, ""},
		{"时长差超过 3%", []kugouLyricCandidate{cand("a", "浮夸", "陈奕迅", 30000)}, 283, ""},
		{"本地时长未知", []kugouLyricCandidate{cand("a", "浮夸", "陈奕迅", 283000)}, 0, ""},
		{"版本限定词不一致", []kugouLyricCandidate{cand("a", "浮夸 (Live)", "陈奕迅", 283000)}, 283, ""},
		{"没有 id", []kugouLyricCandidate{{AccessKey: "k", Song: "浮夸", Singer: "陈奕迅", Duration: 283000}}, 283, ""},
	} {
		got, ok := kugouKeywordCandidate(c.cands, "陈奕迅", "浮夸", c.dur)
		if ok != (c.want != "") || (ok && got.ID != c.want) {
			t.Errorf("%s: got %q (found=%v), want %q", c.name, got.ID, ok, c.want)
		}
	}
}

// 端到端:按 hash 查不到候选、第一条候选只是没词的占位、或者搜歌挑不出时,不带 hash 再查一次;本地时长未知、查候选没问成、
// 下载没问成、搜歌整个没问成时不查。
func TestResolveKugouLyricKeywordFallback(t *testing.T) {
	const keywordHit = `{"status":200,"candidates":[{"id":"9","accesskey":"k","song":"浮夸","singer":"陈奕迅","duration":283000}]}`
	const noPick = `{"status":1,"errcode":0,"data":{"info":[{"hash":"x","songname":"别的歌","singername":"陈奕迅","album_name":"别的专辑","duration":200}]}}`
	for _, c := range []struct {
		name         string
		search       func() (int, string)
		hashSearch   func() (int, string)
		download     func(id, fmt string) (int, string) // nil:一律给正常的 KRC
		dur          float64
		wantKeyword  int32
		wantLRC      bool
		wantAlbum    string
		wantDuration float64
	}{
		{"按 hash 查不到候选", func() (int, string) { return http.StatusOK, kgSearchHit },
			func() (int, string) { return http.StatusOK, `{"status":200,"candidates":[]}` }, nil, 283, 1, true, "U87", 283},
		{"挑中的曲目是另一个版本:身份用候选的", func() (int, string) {
			return http.StatusOK, strings.Replace(kgSearchHit, `"duration":283`, `"duration":400`, 1)
		},
			func() (int, string) { return http.StatusOK, `{"status":200,"candidates":[]}` }, nil, 283, 1, true, "", 283},
		{"第一条候选只是没词的占位", func() (int, string) { return http.StatusOK, kgSearchHit },
			func() (int, string) { return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}` },
			func(id, _ string) (int, string) {
				if id == "9" {
					return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, kgTestKRC) + `"}`
				}
				return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, "[ar:arkady sevidov]\n[1580,1000]<0,1000,0>纯音乐，请欣赏") + `"}`
			}, 283, 1, true, "U87", 283},
		{"搜歌挑不出", func() (int, string) { return http.StatusOK, noPick }, nil, nil, 283, 1, true, "", 283},
		{"本地时长未知不查", func() (int, string) { return http.StatusOK, noPick }, nil, nil, 0, 0, false, "", 0},
		{"查候选没问成不查", func() (int, string) { return http.StatusOK, kgSearchHit },
			func() (int, string) { return http.StatusServiceUnavailable, "" }, nil, 283, 0, false, "", 0},
		{"下载没问成不查", func() (int, string) { return http.StatusOK, kgSearchHit },
			func() (int, string) { return http.StatusOK, `{"status":200,"candidates":[{"id":"1","accesskey":"k"}]}` },
			func(_, _ string) (int, string) { return http.StatusServiceUnavailable, "" }, 283, 0, false, "", 0},
		{"搜歌整个没问成不查", func() (int, string) { return http.StatusServiceUnavailable, "" }, nil, nil, 283, 0, false, "", 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			var keyword int32
			var keywordHosts []string
			withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
				switch {
				case strings.HasSuffix(target, "/api/v3/search/song"), target == "https://songsearch.kugou.com/song_search_v2":
					return c.search()
				case strings.HasSuffix(target, ".kugou.com/search"):
					if r.URL.Query().Get("hash") == "" {
						atomic.AddInt32(&keyword, 1)
						keywordHosts = append(keywordHosts, strings.Split(r.Host, ":")[0])
						return http.StatusOK, keywordHit
					}
					return c.hashSearch()
				case strings.HasSuffix(target, ".kugou.com/download"):
					if c.download != nil {
						return c.download(r.URL.Query().Get("id"), r.URL.Query().Get("fmt"))
					}
					return http.StatusOK, `{"status":200,"content":"` + kgTestKRCContent(t, kgTestKRC) + `"}`
				}
				return http.StatusNotFound, ""
			})
			res := resolveKugouLyric(qqRoundCtx(), "陈奕迅", "浮夸", "U87", c.dur)
			if keyword != c.wantKeyword {
				t.Errorf("不带 hash 查了 %d 次,期望 %d", keyword, c.wantKeyword)
			}
			if len(keywordHosts) > 0 && keywordHosts[0] != "krcs.kugou.com" {
				t.Errorf("不带 hash 先问 krcs: %v", keywordHosts)
			}
			if (res.lrc != "") != c.wantLRC || res.album != c.wantAlbum || res.durationSecs != c.wantDuration {
				t.Errorf("got lrc=%v album=%q dur=%v", res.lrc != "", res.album, res.durationSecs)
			}
		})
	}
}
