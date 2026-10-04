package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// ytmusicFakeReq:假服务器收到的一个请求。
type ytmusicFakeReq struct {
	target, query, visitor, clientName string
	body                               map[string]any
}

// withYtmusicFake:所有主机都打到一台假服务器上,handle 按请求决定应答;返回收到的 YouTube Music 请求(按到达顺序)。
// 换的是整个进程共用的歌词源传输层,别的用例留在后台的请求(网易云搜索之类)也会走进来:不是发给 YouTube Music 的
// 不记、不交给 handle,回 404。
func withYtmusicFake(t *testing.T, handle func(w http.ResponseWriter, req ytmusicFakeReq)) func() []ytmusicFakeReq {
	t.Helper()
	var mu sync.Mutex
	var got []ytmusicFakeReq
	withAMLLFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		if !ytmusicFakeTarget(target) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		req := ytmusicFakeReq{target: target, query: r.URL.RawQuery, visitor: r.Header.Get("X-Goog-Visitor-Id")}
		if r.Method == http.MethodPost {
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &req.body)
			if c, ok := req.body["context"].(map[string]any); ok {
				if cl, ok := c["client"].(map[string]any); ok {
					req.clientName, _ = cl["clientName"].(string)
				}
			}
		}
		mu.Lock()
		got = append(got, req)
		mu.Unlock()
		handle(w, req)
	})
	return func() []ytmusicFakeReq {
		mu.Lock()
		defer mu.Unlock()
		return append([]ytmusicFakeReq(nil), got...)
	}
}

// ytmusicFakeTarget:这个请求是不是发给 YouTube Music 的(ytmusicAPIBases 里的主机)。
func ytmusicFakeTarget(target string) bool {
	for _, base := range ytmusicAPIBases {
		if target == base || strings.HasPrefix(target, base+"/") {
			return true
		}
	}
	return false
}

const (
	ytmSearchURL = "https://music.youtube.com/youtubei/v1/search"
	ytmNextURL   = "https://music.youtube.com/youtubei/v1/next"
	ytmBrowseURL = "https://music.youtube.com/youtubei/v1/browse"
	ytmHomeURL   = "https://music.youtube.com/"
)

func ytmFakeSearch(items ...string) string {
	return `{"responseContext":{"visitorData":"VD1"},"contents":{"list":[` + strings.Join(items, ",") + `]}}`
}

const ytmFakeNext = `{"responseContext":{"visitorData":"VD-next"},"contents":{"tabs":[{"tabRenderer":{"endpoint":{"browseEndpoint":{` +
	`"browseId":"MPLYt_x1","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_LYRICS"}}}}}}]}}`

func ytmFakeTimed(source string) string {
	var lines []string
	for i, text := range []string{"Hello, it's me", "I was wondering", "If after all these years", "You'd like to meet"} {
		start := 1000 + i*4000
		lines = append(lines, `{"lyricLine":"`+text+`","cueRange":{"startTimeMilliseconds":"`+itoa(start)+`","endTimeMilliseconds":"`+itoa(start+3500)+`"}}`)
	}
	return `{"contents":{"elementRenderer":{"newElement":{"type":{"componentType":{"model":{"timedLyricsModel":{"lyricsData":{` +
		`"timedLyricsData":[` + strings.Join(lines, ",") + `],"sourceMessage":"` + source + `"}}}}}}}}}`
}

func ytmFakePlain(source string) string {
	return `{"contents":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{` +
		`"description":{"runs":[{"text":"Line one\nLine two\nLine three"}]},"footer":{"runs":[{"text":"` + source + `"}]}}}]}}}`
}

const ytmFakeNoLyrics = `{"contents":{"messageRenderer":{"text":{"runs":[{"text":"Lyrics not available"}]}}}}`

// 三跳走通:第一次请求不带 visitor id,之后带应答里给的那个;next 只带 videoId;LyricFind 的逐行歌词收下,不再多问 Web 那一次。
func TestResolveYTMusicLyricTimedLyricFind(t *testing.T) {
	resetYtmusicRegionState(t)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
		case req.target == ytmNextURL:
			_, _ = io.WriteString(w, ytmFakeNext)
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	r := resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295)
	if !isTimedLRC(r.lyrics) || r.plainOnly || r.title != "Hello" || r.durationSecs != 295 {
		t.Fatalf("该拿到 LyricFind 的逐行歌词: %+v", r)
	}
	got := reqs()
	if len(got) != 3 {
		t.Fatalf("三跳各一次,不查首页、不问 Web 那一次: %+v", got)
	}
	if got[0].visitor != "" || got[1].visitor != "VD1" || got[2].visitor != "VD1" {
		t.Errorf("第一次不带 visitor id,之后带应答里给的: %q %q %q", got[0].visitor, got[1].visitor, got[2].visitor)
	}
	if _, has := got[1].body["playlistId"]; has || got[1].body["videoId"] != "vid1" {
		t.Errorf("next 只带 videoId,别带电台列表: %v", got[1].body)
	}
	for _, r := range got {
		if !strings.Contains(r.query, "prettyPrint=false") {
			t.Errorf("%s 要带 prettyPrint=false: %q", r.target, r.query)
		}
	}
}

// 带时间戳的是 Musixmatch 供的:不收,也不再问 Web 那一次(纯文本也是同一家)。
func TestResolveYTMusicLyricRejectsMusixmatch(t *testing.T) {
	resetYtmusicRegionState(t)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
		case req.target == ytmNextURL:
			_, _ = io.WriteString(w, ytmFakeNext)
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: Musixmatch"))
		default:
			_, _ = io.WriteString(w, ytmFakePlain("Source: LyricFind"))
		}
	})
	if r := resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295); r.lyrics != "" {
		t.Fatalf("Musixmatch 供的不收: %+v", r)
	}
	if n := len(reqs()); n != 3 {
		t.Errorf("不该再问 Web 那一次,实际 %d 个请求", n)
	}
}

// Android 身份给了别家的逐行(不够三行、算不上带时间戳的歌词):不再问 Web 那一次,纯文本也是同一家。
func TestResolveYTMusicLyricSparseOtherProviderSkipsPlain(t *testing.T) {
	resetYtmusicRegionState(t)
	sparse := `{"contents":{"timedLyricsModel":{"lyricsData":{"timedLyricsData":[` +
		`{"lyricLine":"Hello, it's me","cueRange":{"startTimeMilliseconds":"1000","endTimeMilliseconds":"4500"}},` +
		`{"lyricLine":"I was wondering","cueRange":{"startTimeMilliseconds":"5000","endTimeMilliseconds":"8500"}}` +
		`],"sourceMessage":"Source: Musixmatch"}}}}`
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
		case req.target == ytmNextURL:
			_, _ = io.WriteString(w, ytmFakeNext)
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, sparse)
		default:
			_, _ = io.WriteString(w, ytmFakePlain("Source: LyricFind"))
		}
	})
	if r := resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295); r.lyrics != "" {
		t.Fatalf("别家的不收: %+v", r)
	}
	if n := len(reqs()); n != 3 {
		t.Errorf("不该再问 Web 那一次,实际 %d 个请求", n)
	}
}

// Android 身份拿不到带时间戳的:Web 身份再问一次,来源是 LyricFind 的纯文本交成 plainOnly;是别家的不收。
func TestResolveYTMusicLyricPlainFallback(t *testing.T) {
	for _, c := range []struct {
		source string
		want   bool
	}{{"Source: LyricFind", true}, {"Source: Musixmatch", false}} {
		resetYtmusicRegionState(t)
		withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
			switch {
			case req.target == ytmSearchURL:
				_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
			case req.target == ytmNextURL:
				_, _ = io.WriteString(w, ytmFakeNext)
			case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
				_, _ = io.WriteString(w, ytmFakeNoLyrics)
			case req.target == ytmBrowseURL && req.clientName == ytmusicWebClientName:
				_, _ = io.WriteString(w, ytmFakePlain(c.source))
			default:
				w.WriteHeader(http.StatusNotFound)
			}
		})
		r := resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295)
		if c.want != (r.plainOnly && r.lyrics == "Line one\nLine two\nLine three") || (!c.want && r.lyrics != "") {
			t.Errorf("%s: got %+v", c.source, r)
		}
	}
}

// 搜歌一条结果都没有时查一次首页;是地区限制提示页就记下,之后这一源一个请求都不发。挑不出(有结果但对不上)不查。
func TestResolveYTMusicLyricRegionCheck(t *testing.T) {
	resetYtmusicRegionState(t)
	var items []string
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch req.target {
		case ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(items...))
		case ytmHomeURL:
			_, _ = io.WriteString(w, "<html>YouTube Music is not available in your area</html>")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	items = []string{ytmusicSearchItemJSON("Another Song", "Someone • X • 3:00", "vid9", "MUSIC_VIDEO_TYPE_ATV")}
	resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295)
	for _, r := range reqs() {
		if r.target == ytmHomeURL {
			t.Fatal("搜到了东西只是对不上,不该查首页")
		}
	}
	items = nil
	resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295)
	home := 0
	for _, r := range reqs() {
		if r.target == ytmHomeURL {
			home++
		}
	}
	if home != 1 || !ytmusicRegionBlockedNow(time.Now()) || ytmusicLastFailureReasonNow() != lyricFailureReasonLyricFindRegionRestricted {
		t.Fatalf("搜不到时该查一次首页并记成受限: home=%d blocked=%v reason=%q", home, ytmusicRegionBlockedNow(time.Now()), ytmusicLastFailureReasonNow())
	}
	before := len(reqs())
	if r := resolveYTMusicLyric(qqRoundCtx(), "Adele", "Hello", "25", 295); r.lyrics != "" || len(reqs()) != before {
		t.Errorf("受限期间不该发请求: %d → %d", before, len(reqs()))
	}
	if _, err := ytmusicOriginalArtistNames(context.Background(), "陈奕迅", "浮夸", 0); err == nil {
		t.Error("受限期间编目那一路该当没查成(不缓存成「没有」)")
	}
}

// 接线:lyricfind 只有纯文本时一路带着 plainOnly 进候选,判成「只有纯文本」那一档(分数恒 -1、能手动采纳),
// 不是「没有时间戳」那一档。
func TestLyricFindPlainOnlyThroughPipeline(t *testing.T) {
	saved := features()
	t.Cleanup(func() {
		setFeatures(saved)
		ytmusicMu.Lock()
		delete(ytmusicCache, "Adele|Hello|25")
		ytmusicMu.Unlock()
	})
	featuresRef().LyricsSources = map[string]bool{"lyricfind": true}
	resetYtmusicRegionState(t)
	withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
		case req.target == ytmNextURL:
			_, _ = io.WriteString(w, ytmFakeNext)
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeNoLyrics)
		case req.target == ytmBrowseURL && req.clientName == ytmusicWebClientName:
			_, _ = io.WriteString(w, ytmFakePlain("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	_, got := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "Adele", "Hello", "25", 295, nil)
	for _, r := range got {
		if r.Source != "lyricfind" {
			continue
		}
		if !r.PlainTextOnly || r.Score >= 0 || len(r.ScoreTerms) == 0 || r.ScoreTerms[0].Kind != scoreRejectPlainTextOnly {
			t.Fatalf("该判成只有纯文本: %+v", r)
		}
		return
	}
	t.Fatalf("没有 lyricfind 候选: %+v", got)
}

// 搜歌带的界面语言:按歌手名的文字;歌手只有汉字、歌名或专辑带假名时用 ja;拉丁字母的歌手不带。
func TestYtmusicSearchHL(t *testing.T) {
	for _, c := range []struct{ artist, title, album, want string }{
		{"陈奕迅", "浮夸", "U87", "zh-CN"},
		{"周杰倫", "晴天", "葉惠美", "zh-TW"},
		{"米津玄師", "ゆめうつつ - Daydream", "LOST CORNER", "ja"},
		{"米津玄師", "Lemon", "STRAY SHEEP", "zh-TW"},
		{"のぶなが", "深海少女", "", "ja"},
		{"아이유", "밤편지", "Palette", "ko"},
		{"YOASOBI", "夜に駆ける", "THE BOOK", ""},
		{"Eason Chan", "浮夸", "U87", ""},
	} {
		if got := ytmusicSearchHL(c.artist, c.title, c.album); got != c.want {
			t.Errorf("%s / %s: got %q, want %q", c.artist, c.title, got, c.want)
		}
	}
}

// 搜歌请求真的带上了界面语言;拉丁字母的歌手不带。
func TestYtmusicSearchSongSendsHL(t *testing.T) {
	resetYtmusicRegionState(t)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("浮夸", "陈奕迅 • U87 • 4:42", "vid2", "MUSIC_VIDEO_TYPE_ATV")))
	})
	if _, ok, _ := ytmusicSearchSong(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 282); !ok {
		t.Fatal("该挑中")
	}
	ytmusicSearchSong(qqRoundCtx(), "Adele", "Hello", "25", 295)
	got := reqs()
	hl := func(r ytmusicFakeReq) any {
		c, _ := r.body["context"].(map[string]any)
		cl, _ := c["client"].(map[string]any)
		return cl["hl"]
	}
	if len(got) != 2 {
		t.Fatalf("该是两次搜歌请求: %+v", got)
	}
	if hl(got[0]) != "zh-CN" || hl(got[1]) != nil {
		t.Errorf("hl 不对: %v / %v", hl(got[0]), hl(got[1]))
	}
}

// Web 身份应答里的纯文本:description 是正文、footer 是来源;「Lyrics not available」那一页取不到东西。
func TestYtmusicParsePlainLyrics(t *testing.T) {
	text, src := ytmusicParsePlainLyrics([]byte(ytmFakePlain("Source: LyricFind")))
	if text != "Line one\nLine two\nLine three" || src != "Source: LyricFind" {
		t.Errorf("got %q / %q", text, src)
	}
	if text, _ := ytmusicParsePlainLyrics([]byte(ytmFakeNoLyrics)); text != "" {
		t.Errorf("没有歌词的那一页不该取到东西: %q", text)
	}
}

// ytmFakeVideoNext:照真实 next 应答的形状造(只留用得到的那几层)—— 这一版的登记信息(类型、时长、专辑、缩略图)和歌词页入口。
func ytmFakeVideoNext(videoID, videoType string) string {
	return `{"responseContext":{"visitorData":"VD-next"},"contents":{"tabs":[` +
		`{"tabRenderer":{"content":{"playlistPanelRenderer":{"contents":[{"playlistPanelVideoRenderer":{"videoId":"` + videoID + `",` +
		`"title":{"runs":[{"text":"Levitating"}]},"lengthText":{"runs":[{"text":"3:23"}]},` +
		`"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/lev=w60-h60-l90-rj","width":60,"height":60},` +
		`{"url":"https://lh3.googleusercontent.com/lev=w544-h544-l90-rj","width":544,"height":544}]},` +
		`"navigationEndpoint":{"watchEndpoint":{"videoId":"` + videoID + `","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"` + videoType + `"}}}},` +
		`"longBylineText":{"runs":[{"text":"Dua Lipa"},{"text":" • "},{"text":"Future Nostalgia","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_lev",` +
		`"browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}},{"text":" • "},{"text":"2020"}]}}}]}}}},` +
		`{"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"MPLYt_v1","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_TRACK_LYRICS"}}}}}}]}}`
}

func forgetYtmusicCache(t *testing.T, keys ...string) {
	t.Helper()
	t.Cleanup(func() {
		ytmusicMu.Lock()
		for _, k := range keys {
			delete(ytmusicCache, k)
		}
		ytmusicMu.Unlock()
	})
}

// 有 videoId:取 Kaset 给它配的音轨版本那一页,不搜;next 按传进来的界面语言问;LyricFind 的逐行歌词连同那一版的登记信息
// 收下,标成身份来自播放器;同一版再问走缓存。
func TestYtmusicVideoLyricTakesPairedAudioVersion(t *testing.T) {
	resetYtmusicRegionState(t)
	withKasetAudioVideoIDs(t)
	noteKasetAudioVideoIDs(map[string]string{"TUVcZfQe-Kw": "OsfAnsMY21M"})
	forgetYtmusicCache(t, ytmusicVideoCacheKey("zh-CN", "OsfAnsMY21M"))
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmNextURL:
			id, _ := req.body["videoId"].(string)
			_, _ = io.WriteString(w, ytmFakeVideoNext(id, ytmusicVideoTypeATV))
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	r := ytmusicVideoLyric(qqRoundCtx(), "TUVcZfQe-Kw", "zh-CN")
	if !isTimedLRC(r.lyrics) || r.plainOnly || !r.fromLocalClient || r.title != "Levitating" || r.artist != "Dua Lipa" ||
		r.album != "Future Nostalgia" || r.durationSecs != 203 || r.cover != "https://lh3.googleusercontent.com/lev=s0" {
		t.Fatalf("该拿到音轨版本那一页的 LyricFind 逐行歌词和登记信息: %+v", r)
	}
	got := reqs()
	if len(got) != 2 || got[0].target != ytmNextURL || got[1].target != ytmBrowseURL || got[1].body["browseId"] != "MPLYt_v1" {
		t.Fatalf("next 一次、browse 一次,不搜: %+v", got)
	}
	client, _ := got[0].body["context"].(map[string]any)["client"].(map[string]any)
	if got[0].body["videoId"] != "OsfAnsMY21M" || client["hl"] != "zh-CN" {
		t.Errorf("问的是配的音轨版本、按传进来的界面语言: %v", got[0].body)
	}
	if again := ytmusicVideoLyric(qqRoundCtx(), "TUVcZfQe-Kw", "zh-CN"); again != r || len(reqs()) != 2 {
		t.Errorf("同一版再问该走缓存: %+v, %d 个请求", again, len(reqs()))
	}
}

// 放的是 MV、队列里没给它配音轨版本:问一次 next 看出不是音轨版本就放弃,不取它的歌词页。
func TestYtmusicVideoLyricSkipsMusicVideo(t *testing.T) {
	resetYtmusicRegionState(t)
	withKasetAudioVideoIDs(t)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		if req.target == ytmNextURL {
			id, _ := req.body["videoId"].(string)
			_, _ = io.WriteString(w, ytmFakeVideoNext(id, ytmusicVideoTypeOMV))
			return
		}
		_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
	})
	if r := ytmusicVideoLyric(qqRoundCtx(), "TUVcZfQe-Kw", ""); r != (ytmusicResult{}) {
		t.Fatalf("不是音轨版本不取: %+v", r)
	}
	if got := reqs(); len(got) != 1 {
		t.Errorf("只问一次 next: %+v", got)
	}
}

// ctx 上有 videoId 时先按它取;那一版的歌词不是 LyricFind 供的,照旧按名字搜,搜到的不标身份来自播放器。
func TestYtmusicLyricFallsBackToSearch(t *testing.T) {
	resetYtmusicRegionState(t)
	withKasetAudioVideoIDs(t)
	forgetYtmusicCache(t, "Adele|Hello|25")
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
		case req.target == ytmNextURL && req.body["videoId"] == "YQHsXMglC9A":
			_, _ = io.WriteString(w, ytmFakeVideoNext("YQHsXMglC9A", ytmusicVideoTypeATV))
		case req.target == ytmNextURL:
			_, _ = io.WriteString(w, ytmFakeNext)
		case req.target == ytmBrowseURL && req.body["browseId"] == "MPLYt_v1":
			_, _ = io.WriteString(w, ytmFakeTimed("Source: Musixmatch"))
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	r := ytmusicLyric(withYouTubeMusicVideoID(qqRoundCtx(), "YQHsXMglC9A"), "Adele", "Hello", "25", 295)
	if !isTimedLRC(r.lyrics) || r.fromLocalClient || r.title != "Hello" {
		t.Fatalf("该退回按名字搜、不标身份来自播放器: %+v", r)
	}
	if got := reqs(); len(got) != 5 || got[0].body["videoId"] != "YQHsXMglC9A" || got[2].target != ytmSearchURL {
		t.Errorf("先 next + browse 那一版,再按名字三跳: %+v", got)
	}
}

// 接线:按 videoId 取到的 lyricfind 候选带着身份来自播放器进打分,用 Kaset 放时拿同源加权。
func TestLyricFindVideoIdentityThroughPipeline(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"lyricfind": true}
	setNativeLyricSourcesForPlayer(kasetBundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	resetYtmusicRegionState(t)
	withKasetAudioVideoIDs(t)
	forgetYtmusicCache(t, ytmusicVideoCacheKey("", "OsfAnsMY21M"))
	withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmNextURL:
			id, _ := req.body["videoId"].(string)
			_, _ = io.WriteString(w, ytmFakeVideoNext(id, ytmusicVideoTypeATV))
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	ctx := withYouTubeMusicVideoID(qqRoundCtx(), "OsfAnsMY21M")
	_, got := fetchScoredLyricCandidatesStreaming(ctx, "Dua Lipa", "Levitating", "Future Nostalgia", 0, nil)
	for _, r := range got {
		if r.Source != "lyricfind" {
			continue
		}
		native := false
		for _, term := range r.ScoreTerms {
			native = native || term.Kind == scoreTermNativeSource
		}
		if !r.IdentityFromLocalClient || !native {
			t.Fatalf("该带着身份来自播放器、拿同源加权: %+v", r)
		}
		return
	}
	t.Fatalf("没有 lyricfind 候选: %+v", got)
}
