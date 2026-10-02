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
