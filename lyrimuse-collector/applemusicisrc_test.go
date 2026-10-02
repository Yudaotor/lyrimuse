package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// amTestISRCBody 拼一份 /songs?filter[isrc]= 的应答。
func amTestISRCBody(songs ...applemusicSong) string {
	if songs == nil {
		songs = []applemusicSong{}
	}
	b, _ := json.Marshal(map[string][]applemusicSong{"data": songs})
	return string(b)
}

func amTestIsISRCLookup(r *http.Request, code string) bool {
	return r.URL.Path == "/v1/catalog/cn/songs" && r.URL.Query().Get("filter[isrc]") == code
}

const amTestOtherUntimedTTML = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="None"><body><div>` +
	`<p>另一句</p><p>另一份</p></div></body></tt>`

// 按 ISRC 直取的条目怎么挑:没词的、时长差太多的、没有 id 的不要;专辑跟本地相同或互相包含的进 onAlbum(本地没有专辑名时
// 全进),其余进 offAlbum;组内有时间轴的排前面、同档专辑更像的排前面;每组最多三条。
func TestApplemusicISRCCandidates(t *testing.T) {
	noLyrics := amTestSong("nolyrics", "Toxic", "VALORANT", "Toxic - Single", 213000, true)
	noLyrics.Attributes.HasLyrics = false
	ids := func(ss []applemusicSong) string {
		var out []string
		for _, s := range ss {
			out = append(out, s.ID)
		}
		return strings.Join(out, ",")
	}
	for _, c := range []struct {
		name  string
		songs []applemusicSong
		album string
		dur   float64
		want  string // onAlbum|offAlbum
	}{
		{"没词的、时长差超过 12% 的、没有 id 的不要", []applemusicSong{
			noLyrics,
			amTestSong("far", "Toxic", "VALORANT", "Toxic - Single", 260000, true),
			amTestSong("", "Toxic", "VALORANT", "Toxic - Single", 213000, true),
			amTestSong("ok", "Toxic (feat. AUDREY NUNA)", "VALORANT", "Toxic (feat. AUDREY NUNA) - Single", 213000, true)},
			"Toxic", 213, "ok|"},
		{"本地时长未知照样收", []applemusicSong{amTestSong("ok", "Toxic", "VALORANT", "Toxic - Single", 260000, true)}, "Toxic", 0, "ok|"},
		{"有时间轴的排前面", []applemusicSong{
			amTestSong("plain", "Toxic", "VALORANT", "Toxic", 213000, false),
			amTestSong("timed", "Toxic", "VALORANT", "Toxic - Single", 213000, true)},
			"Toxic", 213, "timed,plain|"},
		{"同档专辑更像的排前面", []applemusicSong{
			amTestSong("dlx", "Kiss It Better", "Rihanna", "ANTI (Deluxe)", 253000, true),
			amTestSong("std", "Kiss It Better", "Rihanna", "ANTI", 253000, true)},
			"ANTI", 253, "std,dlx|"},
		{"只挂在合辑下的进 offAlbum", []applemusicSong{
			amTestSong("comp", "When I Was Your Man", "Bruno Mars", "Chilled R&B", 214000, true),
			amTestSong("orig", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true)},
			"Unorthodox Jukebox", 214, "orig|comp"},
		{"本地没有专辑名时全进 onAlbum", []applemusicSong{
			amTestSong("comp", "When I Was Your Man", "Bruno Mars", "Chilled R&B", 214000, true),
			amTestSong("orig", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true)},
			"", 214, "comp,orig|"},
		{"每组最多三条", []applemusicSong{
			amTestSong("a", "X", "Y", "A", 200000, true), amTestSong("b", "X", "Y", "A", 200000, true),
			amTestSong("c", "X", "Y", "A", 200000, true), amTestSong("d", "X", "Y", "A", 200000, true),
			amTestSong("e", "X", "Y", "E", 200000, true), amTestSong("f", "X", "Y", "F", 200000, true),
			amTestSong("g", "X", "Y", "G", 200000, true), amTestSong("h", "X", "Y", "H", 200000, true)},
			"A", 200, "a,b,c|e,f,g"},
	} {
		on, off := applemusicISRCCandidates(c.songs, c.album, c.dur)
		if got := ids(on) + "|" + ids(off); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// 按 ISRC 直取到的条目有带时间轴的词:直接用它,不再按名字搜(名字搜出来的同名另一版不会顶替它)。
func TestApplemusicPrefersISRCRecording(t *testing.T) {
	withApplemusicCreds(t, "cn")
	var searches, lookups int32
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			atomic.AddInt32(&searches, 1)
			return http.StatusOK, nil, amTestSearchBody(amTestSong("std", "Kiss It Better", "Rihanna", "ANTI", 253000, true))
		case amTestIsISRCLookup(r, "QM5FT1600115"):
			atomic.AddInt32(&lookups, 1)
			return http.StatusOK, nil, amTestISRCBody(amTestSong("dlx", "Kiss It Better", "Rihanna", "ANTI (Deluxe)", 253000, true))
		case strings.HasSuffix(r.URL.Path, "/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	r := resolveApplemusicLyric(qqRoundCtx(), "Rihanna", "Kiss It Better", "ANTI", 253, "QM5FT1600115")
	if r.album != "ANTI (Deluxe)" || !isTimedLRC(r.lyrics) || r.plainOnly {
		t.Fatalf("该用按 ISRC 直取到的那一条: album=%q plainOnly=%v lyrics=%q", r.album, r.plainOnly, r.lyrics)
	}
	if lookups != 1 || searches != 0 {
		t.Errorf("ISRC 直取到了就不该再按名字搜: lookups=%d searches=%d", lookups, searches)
	}
}

// 按 ISRC 拿不到带时间轴的词时退回按名字搜;两边都只有纯文本时交 ISRC 直取的那份;同一条曲目不取两次。
func TestApplemusicISRCFallsBackToNameSearch(t *testing.T) {
	const code = "USAT21206701"
	for _, c := range []struct {
		name        string
		isrc        string
		lookup      func() (int, string) // ISRC 直取的应答
		isrcTTML    string               // 曲目 i 的歌词,空串是不带时间的那份
		search      string               // 按名字搜:空串照常答 nameSong,"down" 几个主机都 503,"empty" 一条都没有
		nameSong    applemusicSong
		nameTTML    string
		wantTitle   string
		wantPlain   bool
		wantLookups int32
		wantFetches map[string]int32 // 曲目 id → 取词次数
	}{
		{"查无此曲", code, func() (int, string) { return http.StatusOK, amTestISRCBody() }, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man", false, 1, map[string]int32{"n": 1}},
		{"条目时长对不上", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (Live)", "Bruno Mars", "Live", 300000, true))
		}, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man", false, 1, map[string]int32{"i": 0, "n": 1}},
		{"直取的问不通", code, func() (int, string) { return http.StatusServiceUnavailable, "" }, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man", false, 2, map[string]int32{"n": 1}},
		{"直取的只有纯文本、名字搜到带时间轴的", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (ISRC)", "Bruno Mars", "Unorthodox Jukebox", 214000, false))
		}, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man", false, 1, map[string]int32{"i": 1, "n": 1}},
		{"两边都只有纯文本,交直取的那份", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (ISRC)", "Bruno Mars", "Unorthodox Jukebox", 214000, false))
		}, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, false), amTestOtherUntimedTTML,
			"When I Was Your Man (ISRC)", true, 1, map[string]int32{"i": 1, "n": 1}},
		{"直取的和名字搜到的是同一条,不取两次", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, false))
		}, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, false), amTestUntimedTTML,
			"When I Was Your Man", true, 1, map[string]int32{"n": 1}},
		{"直取的只有纯文本、名字搜问不通", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (ISRC)", "Bruno Mars", "Unorthodox Jukebox", 214000, false))
		}, "", "down",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man (ISRC)", true, 1, map[string]int32{"i": 1, "n": 0}},
		{"直取的只有纯文本、名字搜不到", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (ISRC)", "Bruno Mars", "Unorthodox Jukebox", 214000, false))
		}, "", "empty",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man (ISRC)", true, 1, map[string]int32{"i": 1, "n": 0}},
		{"条目只挂在合辑下:先用名字挑的", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (ISRC)", "Bruno Mars", "Música de domingo", 214000, true))
		}, amTestLineTTML, "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man", false, 1, map[string]int32{"i": 0, "n": 1}},
		{"条目只挂在合辑下、名字挑不出:用合辑那条", code, func() (int, string) {
			return http.StatusOK, amTestISRCBody(amTestSong("i", "When I Was Your Man (ISRC)", "Bruno Mars", "Música de domingo", 214000, true))
		}, amTestLineTTML, "empty",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man (ISRC)", false, 1, map[string]int32{"i": 1, "n": 0}},
		{"没有 ISRC 就不问", "", func() (int, string) { return http.StatusOK, amTestISRCBody() }, "", "",
			amTestSong("n", "When I Was Your Man", "Bruno Mars", "Unorthodox Jukebox", 214000, true), amTestLineTTML,
			"When I Was Your Man", false, 0, map[string]int32{"n": 1}},
	} {
		t.Run(c.name, func(t *testing.T) {
			withApplemusicCreds(t, "cn")
			var lookups int32
			fetches := map[string]*int32{"i": new(int32), "n": new(int32)}
			withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
				switch {
				case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
					switch c.search {
					case "down":
						return http.StatusServiceUnavailable, nil, ""
					case "empty":
						return http.StatusOK, nil, amTestSearchBody()
					}
					return http.StatusOK, nil, amTestSearchBody(c.nameSong)
				case r.URL.Path == "/v1/catalog/cn/songs":
					atomic.AddInt32(&lookups, 1)
					if r.URL.Query().Get("filter[isrc]") != code {
						return http.StatusNotFound, nil, ""
					}
					status, body := c.lookup()
					return status, nil, body
				case r.URL.Path == "/v1/catalog/cn/songs/i/syllable-lyrics":
					atomic.AddInt32(fetches["i"], 1)
					if c.isrcTTML != "" {
						return http.StatusOK, nil, amTestLyricsBody(c.isrcTTML)
					}
					return http.StatusOK, nil, amTestLyricsBody(amTestUntimedTTML)
				case r.URL.Path == "/v1/catalog/cn/songs/n/syllable-lyrics":
					atomic.AddInt32(fetches["n"], 1)
					return http.StatusOK, nil, amTestLyricsBody(c.nameTTML)
				}
				return http.StatusNotFound, nil, ""
			})
			r := resolveApplemusicLyric(qqRoundCtx(), "Bruno Mars", "When I Was Your Man", "Unorthodox Jukebox", 214, c.isrc)
			if r.empty() || r.title != c.wantTitle || r.plainOnly != c.wantPlain {
				t.Fatalf("got title=%q plainOnly=%v lyrics=%q", r.title, r.plainOnly, r.lyrics)
			}
			if lookups != c.wantLookups {
				t.Errorf("按 ISRC 直取问了 %d 次,期望 %d", lookups, c.wantLookups)
			}
			for id, want := range c.wantFetches {
				if got := atomic.LoadInt32(fetches[id]); got != want {
					t.Errorf("曲目 %s 取词 %d 次,期望 %d", id, got, want)
				}
			}
		})
	}
}

// 按 ISRC 直取到的条目取词时令牌被拒:整路放弃,不再按名字搜(搜到了也一样取不了词)。
func TestApplemusicISRCTokenRejectedStops(t *testing.T) {
	withApplemusicCreds(t, "cn")
	var searches int32
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			atomic.AddInt32(&searches, 1)
			return http.StatusOK, nil, amTestSearchBody(amTestSong("std", "Kiss It Better", "Rihanna", "ANTI", 253000, true))
		case amTestIsISRCLookup(r, "QM5FT1600115"):
			return http.StatusOK, nil, amTestISRCBody(amTestSong("dlx", "Kiss It Better", "Rihanna", "ANTI (Deluxe)", 253000, true))
		case strings.HasSuffix(r.URL.Path, "/syllable-lyrics"):
			return http.StatusUnauthorized, nil, ""
		}
		return http.StatusNotFound, nil, ""
	})
	if r := resolveApplemusicLyric(qqRoundCtx(), "Rihanna", "Kiss It Better", "ANTI", 253, "QM5FT1600115"); !r.empty() || searches != 0 {
		t.Fatalf("令牌被拒该整路放弃: lyrics=%q searches=%d", r.lyrics, searches)
	}
}

// ISRC 进缓存键:同一首歌先没有 ISRC(首播那一拍 Spotify 的索引还没建好)、后来有了,后一次不能被前一次的缓存挡住。
func TestApplemusicLyricCacheKeyIncludesISRC(t *testing.T) {
	withApplemusicCreds(t, "cn")
	applemusicMu.Lock()
	saved := applemusicCache
	applemusicCache = map[string]applemusicResult{}
	applemusicMu.Unlock()
	t.Cleanup(func() {
		applemusicMu.Lock()
		applemusicCache = saved
		applemusicMu.Unlock()
	})
	var lookups int32
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			return http.StatusOK, nil, amTestSearchBody(amTestSong("std", "测试曲", "测试歌手", "测试专辑", 200000, true))
		case amTestIsISRCLookup(r, "TEST00000001"):
			atomic.AddInt32(&lookups, 1)
			return http.StatusOK, nil, amTestISRCBody(amTestSong("dlx", "测试曲", "测试歌手", "测试专辑 (Deluxe)", 200000, true))
		case strings.HasSuffix(r.URL.Path, "/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	if r := applemusicLyric(qqRoundCtx(), "测试歌手", "测试曲", "测试专辑", 200, "", ""); r.album != "测试专辑" {
		t.Fatalf("没有 ISRC 时按名字搜: album=%q", r.album)
	}
	if r := applemusicLyric(qqRoundCtx(), "测试歌手", "测试曲", "测试专辑", 200, "", "TEST00000001"); r.album != "测试专辑 (Deluxe)" || lookups != 1 {
		t.Fatalf("有了 ISRC 该重新取: album=%q lookups=%d", r.album, lookups)
	}
}
