package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCrossScriptBase(t *testing.T) {
	for _, c := range []struct {
		local, canonical string
		want             bool
	}{
		{"KUSUSHIKI", "クスシキ", true},
		{"Ao To Natsu", "青と夏", true},
		{"Tsumi to Batsu to Ame to Kiss", "罪と罰と雨とキス (佐野勇斗&吉田仁人)", true},
		{"In My Room", "First Love (feat. デヴィッド・サンボーン)", false},
		{"GIRL", "GIRL (feat. 呂布)", false},
		{"花束", "花束", false},
		{"Hanataba", "", false},
		{"", "花束", false},
		{"(Untitled)", "無題", false},
	} {
		if got := crossScriptBase(c.local, c.canonical); got != c.want {
			t.Errorf("crossScriptBase(%q, %q) = %v, want %v", c.local, c.canonical, got, c.want)
		}
	}
}

// 挑曲目时跨文字那一档按去掉括号部分比:只有客串者名单是假名的别的曲目不算。
func TestAppleStorefrontTrackMatchesBracketKana(t *testing.T) {
	feat := itunesResult{TrackName: "First Love (feat. デヴィッド・サンボーン)", TrackTimeMillis: 300500}
	if appleStorefrontTrackMatches("In My Room", 300, feat) {
		t.Error("只有括号里是假名的另一首歌不该算跨文字的同一条录音")
	}
	kana := itunesResult{TrackName: "クスシキ", TrackTimeMillis: 300050}
	if !appleStorefrontTrackMatches("KUSUSHIKI", 300, kana) {
		t.Error("罗马字对假名、时长对得上,该认")
	}
}

func isrcSong(name, artist string, ms int) applemusicSong {
	var s applemusicSong
	s.Attributes.Name, s.Attributes.ArtistName, s.Attributes.DurationInMillis = name, artist, ms
	return s
}

// 一个 ISRC 挂着几个发行时取时长最接近、且在容差内的那条(曲名和署名都取它的);都不在容差内时为空;没有本地时长取第一条有曲名的。
func TestPickISRCSong(t *testing.T) {
	songs := []applemusicSong{isrcSong("花束 (Live)", "back number (Live)", 290000), isrcSong("花束", "back number", 286250), isrcSong("花束 -remaster-", "back number", 283000)}
	if got := pickISRCSong(songs, 286); got != (originRecording{title: "花束", artist: "back number"}) {
		t.Errorf("got %+v", got)
	}
	if got := pickISRCSong([]applemusicSong{isrcSong("花束", "back number", 250000)}, 286); got != (originRecording{}) {
		t.Errorf("时长差太远该是空: %+v", got)
	}
	if got := pickISRCSong([]applemusicSong{isrcSong(" ", "back number", 0), isrcSong("花束", "back number", 250000)}, 0); got.title != "花束" {
		t.Errorf("没有本地时长取第一条有曲名的: %+v", got)
	}
}

// withTestDevToken:内存里放一个没过期的 developer token,用例结束换回原样。
func withTestDevToken(t *testing.T) {
	t.Helper()
	applemusicDevTokenMu.Lock()
	savedTok, savedExp := applemusicDevToken, applemusicDevTokenExpires
	applemusicDevToken, applemusicDevTokenExpires = "test-token", time.Now().Add(24*time.Hour)
	applemusicDevTokenMu.Unlock()
	t.Cleanup(func() {
		applemusicDevTokenMu.Lock()
		applemusicDevToken, applemusicDevTokenExpires = savedTok, savedExp
		applemusicDevTokenMu.Unlock()
	})
}

// resetOriginTitleState:清空 ISRC 查曲库的结论和区服曲名缓存,用例结束换回原样。
func resetOriginTitleState(t *testing.T) {
	t.Helper()
	appleMusicISRCMu.Lock()
	savedISRC := appleMusicISRCCache
	appleMusicISRCCache = map[string]originRecording{}
	appleMusicISRCMu.Unlock()
	appleStorefrontTitleMu.Lock()
	savedTitles := appleStorefrontTitleCache
	appleStorefrontTitleCache = map[string]string{}
	appleStorefrontTitleMu.Unlock()
	t.Cleanup(func() {
		appleMusicISRCMu.Lock()
		appleMusicISRCCache = savedISRC
		appleMusicISRCMu.Unlock()
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache = savedTitles
		appleStorefrontTitleMu.Unlock()
	})
}

// isrcCatalogHandler:应答 Apple Music 曲库的 songs?filter[isrc],songs 按「storefront|isrc」给,把「storefront|isrc」记进 got;
// 不是这个接口时返回 false。
func isrcCatalogHandler(songs map[string][]applemusicSong, mu *sync.Mutex, got *[]string) func(http.ResponseWriter, *http.Request, string) bool {
	return func(w http.ResponseWriter, r *http.Request, target string) bool {
		const prefix = "https://amp-api.music.apple.com/v1/catalog/"
		if !strings.HasPrefix(target, prefix) || !strings.HasSuffix(target, "/songs") {
			return false
		}
		key := strings.TrimSuffix(strings.TrimPrefix(target, prefix), "/songs") + "|" + r.URL.Query().Get("filter[isrc]")
		mu.Lock()
		*got = append(*got, key)
		mu.Unlock()
		b, _ := json.Marshal(struct {
			Data []applemusicSong `json:"data"`
		}{songs[key]})
		_, _ = w.Write(b)
		return true
	}
}

// withISRCCatalogFake:Apple Music 曲库的 songs?filter[isrc] 换成假服务器(isrcCatalogHandler);返回收到的「storefront|isrc」。
func withISRCCatalogFake(t *testing.T, songs map[string][]applemusicSong) func() []string {
	t.Helper()
	var mu sync.Mutex
	var got []string
	catalog := isrcCatalogHandler(songs, &mu, &got)
	withAMLLFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		if !catalog(w, r, target) {
			w.WriteHeader(http.StatusNotFound)
		}
	})
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), got...)
	}
}

// 按 ISRC 在原产地商店查曲名和署名;结论按 isrc|storefront 记住,同一个再问不发请求。
func TestAppleMusicRecordingByISRC(t *testing.T) {
	withTestDevToken(t)
	resetOriginTitleState(t)
	reqs := withISRCCatalogFake(t, map[string][]applemusicSong{"jp|JPU901900001": {isrcSong("水平線", "back number", 285396)}})
	want := originRecording{title: "水平線", artist: "back number"}
	if got := appleMusicRecordingByISRC(qqRoundCtx(), "JPU901900001", "jp", 285); got != want {
		t.Fatalf("got %+v", got)
	}
	if got := appleMusicRecordingByISRC(qqRoundCtx(), "JPU901900001", "jp", 285); got != want {
		t.Fatalf("第二次 got %+v", got)
	}
	if got := appleMusicRecordingByISRC(qqRoundCtx(), "JPU901900001", "kr", 285); got != (originRecording{}) {
		t.Fatalf("kr 没有这条: %+v", got)
	}
	if rs := reqs(); strings.Join(rs, ",") != "jp|JPU901900001,kr|JPU901900001" {
		t.Errorf("请求不对: %q", rs)
	}
}

const originJapaneseLRC = "[00:05.00]あの日の空を覚えている\n[00:10.00]君と歩いた道の先に\n[00:15.00]まだ知らない明日がある\n" +
	"[00:20.00]風が吹いて花が咲いて\n[00:25.00]ただ前を向いて歩いていく"

// 原产地曲名:先按 ISRC 查(带回署名),没有 ISRC、或查到的跟本地曲名没换文字时用区服遍历的结论(不打请求、没有署名);
// 只有括号里换了文字的结论不算;样本里没有原产地文字时不查。
func TestLyricOriginRecording(t *testing.T) {
	withTestDevToken(t)
	resetOriginTitleState(t)
	reqs := withISRCCatalogFake(t, map[string][]applemusicSong{
		"jp|JPPO02100112": {isrcSong("旅路", "藤井 風", 277000)},
		"jp|JPU901900001": {isrcSong("水平線", "back number", 285396)},
		"jp|JPU901900002": {isrcSong("In My Room", "宇多田ヒカル", 300000)},
		"jp|JPU901900003": {isrcSong("Tabiji", "藤井 風", 277000)},
	})
	samples := []string{originJapaneseLRC}
	appleStorefrontTitleMu.Lock()
	appleStorefrontTitleCache[normLoose("Fujii Kaze")+"|"+normLoose("LOVE ALL SERVE ALL")+"|"+normLoose("Tabiji")] = "旅路"
	appleStorefrontTitleCache[normLoose("宇多田光")+"|"+normLoose("First Love")+"|"+normLoose("In My Room")] = "First Love (feat. デヴィッド・サンボーン)"
	appleStorefrontTitleMu.Unlock()
	for _, c := range []struct {
		name, artist, title, album, isrc string
		dur                              float64
		samples                          []string
		want                             originRecording
	}{
		{"有 ISRC 先按 ISRC 查,带回署名", "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", "JPPO02100112", 277, samples, originRecording{"旅路", "藤井 風"}},
		{"没有 ISRC 用区服遍历的结论", "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", "", 277, samples, originRecording{title: "旅路"}},
		{"ISRC 查到的没换文字时用区服遍历的结论", "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", "JPU901900003", 277, samples, originRecording{title: "旅路"}},
		{"只有括号里换了文字的结论不算", "宇多田光", "In My Room", "First Love", "JPU901900002", 300, samples, originRecording{}},
		{"区服遍历没有结论时按 ISRC 查", "back number", "Suiheisen", "Suiheisen - Single", "JPU901900001", 285, samples, originRecording{"水平線", "back number"}},
		{"样本里没有原产地文字时不查", "back number", "Suiheisen", "Suiheisen - Single", "JPU901900001", 285, []string{"[00:01.00]plain english words"}, originRecording{}},
	} {
		if got := lyricOriginRecording(qqRoundCtx(), c.artist, c.title, c.album, c.dur, c.samples, c.isrc); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
	if rs := reqs(); strings.Join(rs, ",") != "jp|JPPO02100112,jp|JPU901900003,jp|JPU901900002,jp|JPU901900001" {
		t.Errorf("请求不对(没有 ISRC、没有原产地、同一个 ISRC 再问时都不该发): %q", rs)
	}
}

// 标题反查的原产地曲名:区服遍历的结论只有括号里换了文字时不用、改按 ISRC 查;遍历结论是跨文字的就用它、不发请求。
func TestTitleReverseOriginTitle(t *testing.T) {
	withTestDevToken(t)
	resetOriginTitleState(t)
	reqs := withISRCCatalogFake(t, map[string][]applemusicSong{"jp|JPU901900001": {isrcSong("水平線", "back number", 285396)}})
	appleStorefrontArtistMu.Lock()
	savedNames := appleStorefrontArtistCache
	appleStorefrontArtistCache = map[string][]string{}
	appleStorefrontArtistMu.Unlock()
	t.Cleanup(func() {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache = savedNames
		appleStorefrontArtistMu.Unlock()
	})
	// 两样缓存都在,区服遍历直接回、不打 iTunes。
	seed := func(artist, album, title, canonical string) {
		key := normLoose(artist) + "|" + normLoose(album)
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache[key] = nil
		appleStorefrontArtistMu.Unlock()
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache[key+"|"+normLoose(title)] = canonical
		appleStorefrontTitleMu.Unlock()
	}
	seed("back number", "Suiheisen - Single", "Suiheisen", "Suiheisen (feat. 誰か)")
	seed("Mrs. GREEN APPLE", "KUSUSHIKI - Single", "KUSUSHIKI", "クスシキ")
	samples := []string{originJapaneseLRC}
	if got := titleReverseOriginTitle(qqRoundCtx(), "back number", "Suiheisen", "Suiheisen - Single", 285, samples, "JPU901900001"); got != "水平線" {
		t.Errorf("遍历结论只有括号里换了文字,该按 ISRC 查: %q", got)
	}
	if got := titleReverseOriginTitle(qqRoundCtx(), "Mrs. GREEN APPLE", "KUSUSHIKI", "KUSUSHIKI - Single", 300, samples, "JPU901900099"); got != "クスシキ" {
		t.Errorf("遍历结论跨文字就用它: %q", got)
	}
	if rs := reqs(); strings.Join(rs, ",") != "jp|JPU901900001" {
		t.Errorf("只有第一首该问曲库: %q", rs)
	}
}

// 可信的录音 ISRC:已被认可、时长对得上的 Apple Music 候选里分数最高的;判废的、时长对不上的不算。
func TestTrustedRecordingISRC(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "applemusic", Score: -1, ISRC: "REJECTED", SourceReportedDurationSecs: 277},
		{Source: "applemusic", Score: 800, ISRC: "FARAWAY", SourceReportedDurationSecs: 200},
		{Source: "applemusic", Score: 900, ISRC: "JPPO02100112", SourceReportedDurationSecs: 277},
		{Source: "qq", Score: 950, ISRC: "NOTAPPLE", SourceReportedDurationSecs: 277},
	}
	if got := trustedRecordingISRC("nobody", "nothing", "", 277, results); got != "JPPO02100112" {
		t.Errorf("got %q", got)
	}
	if got := trustedRecordingISRC("nobody", "nothing", "", 277, results[:2]); got != "" {
		t.Errorf("判废的、时长对不上的不算: %q", got)
	}
}

// 原产地曲名轮:缺着的源拿原产地曲名问一轮,补上的候选带改写记号;已经齐了、或者拿不到原产地曲名时一个请求都不发。
func TestOriginTitleRound(t *testing.T) {
	saved, savedResolve := features(), musixmatchResolve
	t.Cleanup(func() { setFeatures(saved); musixmatchResolve = savedResolve })
	featuresRef().LyricsSources = map[string]bool{"musixmatch": true, "lrclib": true}
	var mxCalls int
	musixmatchResolve = func(context.Context, string, string, float64, string, string) musixmatchResult {
		mxCalls++
		return musixmatchResult{}
	}
	resetOriginTitleState(t)
	lr := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		if r.URL.Path == "/api/get" && r.URL.Query().Get("track_name") == "旅路" {
			b, _ := json.Marshal(lrclibSearchItem{TrackName: "旅路", ArtistName: "Fujii Kaze", AlbumName: "LOVE ALL SERVE ALL", Duration: 277, SyncedLyrics: originJapaneseLRC})
			return http.StatusOK, nil, string(b)
		}
		if r.URL.Path == "/api/search" {
			return http.StatusOK, nil, "[]"
		}
		return http.StatusNotFound, nil, `{"code":404}`
	})
	base := []scoredLyricCandidateResult{{Source: "musixmatch", Score: 900, Lyrics: originJapaneseLRC, Title: "Tabiji", Artist: "Fujii Kaze", SourceReportedDurationSecs: 277}}

	if _, got := originTitleRound(qqRoundCtx(), "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", 277, neteaseInfo{}, base, nil); len(got) != 1 || len(lr.requests()) != 0 {
		t.Fatalf("拿不到原产地曲名时原样返回、不发请求: %+v / %v", got, lr.requests())
	}
	appleStorefrontTitleMu.Lock()
	appleStorefrontTitleCache[normLoose("Fujii Kaze")+"|"+normLoose("LOVE ALL SERVE ALL")+"|"+normLoose("Tabiji")] = "旅路"
	appleStorefrontTitleMu.Unlock()
	updates := 0
	_, got := originTitleRound(qqRoundCtx(), "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", 277, neteaseInfo{}, base,
		func(neteaseInfo, []scoredLyricCandidateResult, int, int) { updates++ })
	if updates == 0 {
		t.Error("这一轮要往搜歌弹窗推进度")
	}
	var lrclib *scoredLyricCandidateResult
	for i := range got {
		if got[i].Source == "lrclib" {
			lrclib = &got[i]
		}
	}
	if lrclib == nil || lrclib.Score < 0 || lrclib.RetryMethod != lyricQueryReasonTitleStorefront || lrclib.RetriedTitle != "旅路" {
		t.Fatalf("该补上一条带改写记号、可用的 lrclib 候选: %+v", got)
	}
	for _, u := range lr.requests() {
		if q := u.Query().Get("track_name"); q != "" && q != "旅路" {
			t.Errorf("这一轮只拿原产地曲名问: %v", u)
		}
	}
	n := len(lr.requests())
	if _, again := originTitleRound(qqRoundCtx(), "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", 277, neteaseInfo{}, got, nil); len(again) != len(got) || len(lr.requests()) != n {
		t.Errorf("没有缺着的源时不发请求: %d -> %d", n, len(lr.requests()))
	}
	if mxCalls != 0 {
		t.Errorf("已经有可用候选的 musixmatch 不该再问,问了 %d 次", mxCalls)
	}
}

// 原产地署名跟本地不同时,先用本地署名配原产地曲名问,还缺着的源再拿原产地署名问一次(第一次已经补上的源不再问);
// 两个署名归一相同时只问一次;没有缺着的源时连曲库都不查。
func TestOriginTitleRoundOriginArtist(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"musixmatch": true, "lrclib": true}
	resetMusixmatchCacheForTest(t)
	var mu sync.Mutex
	var mxArtists []string
	musixmatchResolve = func(_ context.Context, artist, title string, _ float64, _, _ string) musixmatchResult {
		mu.Lock()
		mxArtists = append(mxArtists, artist)
		mu.Unlock()
		if title != "旅路" {
			return musixmatchResult{}
		}
		return musixmatchResult{lrc: originJapaneseLRC, title: "旅路", artist: artist, durationSecs: 277}
	}
	withTestDevToken(t)
	resetOriginTitleState(t)
	resetSourceCachesForTest(t)
	var catalogReqs []string
	var lrclibGets []string
	catalog := isrcCatalogHandler(map[string][]applemusicSong{
		"jp|JPPO02100112": {isrcSong("旅路", "藤井 風", 277000)},
		"jp|JPPO02100113": {isrcSong("旅路", "FUJII KAZE", 277000)},
		"jp|JPPO02100114": {isrcSong("旅路", "藤井 風", 277000)},
	}, &mu, &catalogReqs)
	withAMLLFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		if catalog(w, r, target) {
			return
		}
		q := r.URL.Query()
		switch {
		case target == "https://lrclib.net/api/get":
			mu.Lock()
			lrclibGets = append(lrclibGets, q.Get("artist_name")+"/"+q.Get("track_name"))
			mu.Unlock()
			if q.Get("track_name") == "旅路" && q.Get("artist_name") == "藤井 風" {
				b, _ := json.Marshal(lrclibSearchItem{TrackName: "旅路", ArtistName: "藤井 風", AlbumName: "LOVE ALL SERVE ALL", Duration: 277, SyncedLyrics: originJapaneseLRC})
				_, _ = w.Write(b)
				return
			}
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"code":404}`))
		case target == "https://lrclib.net/api/search":
			_, _ = w.Write([]byte("[]"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	useUnthrottledGuard(t)
	gets := func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), lrclibGets...)
	}
	catalogAsked := func(key string) bool {
		mu.Lock()
		defer mu.Unlock()
		for _, k := range catalogReqs {
			if k == key {
				return true
			}
		}
		return false
	}
	base := func(isrc string) []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{{Source: "applemusic", Score: 950, Lyrics: originJapaneseLRC, Title: "Tabiji", Artist: "Fujii Kaze", SourceReportedDurationSecs: 277, ISRC: isrc}}
	}
	bySource := func(rs []scoredLyricCandidateResult, s string) *scoredLyricCandidateResult {
		for i := range rs {
			if rs[i].Source == s {
				return &rs[i]
			}
		}
		return nil
	}

	_, got := originTitleRound(qqRoundCtx(), "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", 277, neteaseInfo{}, base("JPPO02100112"), nil)
	for _, s := range []string{"musixmatch", "lrclib"} {
		if c := bySource(got, s); c == nil || c.Score < 0 || c.RetryMethod != lyricQueryReasonTitleStorefront || c.RetriedTitle != "旅路" {
			t.Fatalf("%s 该补上一条带改写记号、可用的候选: %+v", s, got)
		}
	}
	if strings.Join(mxArtists, ",") != "Fujii Kaze" {
		t.Errorf("musixmatch 用本地署名那一次就补上了,原产地署名那一次不该再问它: %q", mxArtists)
	}
	var artists []string
	for _, g := range gets() {
		a, track, _ := strings.Cut(g, "/")
		if track != "旅路" {
			t.Errorf("这一轮只拿原产地曲名问: %q", g)
		}
		if len(artists) == 0 || artists[len(artists)-1] != a {
			artists = append(artists, a)
		}
	}
	if strings.Join(artists, ",") != "Fujii Kaze,藤井 風" {
		t.Errorf("lrclib 先用本地署名、再用原产地署名: %q", artists)
	}

	resetMusixmatchCacheForTest(t)
	mxArtists = nil
	n := len(gets())
	if _, again := originTitleRound(qqRoundCtx(), "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", 277, neteaseInfo{}, base("JPPO02100113"), nil); bySource(again, "lrclib") != nil {
		t.Errorf("原产地署名跟本地归一相同时不再补: %+v", again)
	}
	if strings.Join(mxArtists, ",") != "Fujii Kaze" {
		t.Errorf("两个署名归一相同时只用本地署名问: %q", mxArtists)
	}
	for _, g := range gets()[n:] {
		if a, _, _ := strings.Cut(g, "/"); a != "Fujii Kaze" {
			t.Errorf("两个署名归一相同时只用本地署名问: %q", g)
		}
	}

	full := append([]scoredLyricCandidateResult(nil), got...)
	for i := range full {
		if full[i].Source == "applemusic" {
			full[i].ISRC = "JPPO02100114"
		}
	}
	if _, same := originTitleRound(qqRoundCtx(), "Fujii Kaze", "Tabiji", "LOVE ALL SERVE ALL", 277, neteaseInfo{}, full, nil); len(same) != len(full) || catalogAsked("jp|JPPO02100114") {
		t.Errorf("没有缺着的源时不该查曲库: %v", catalogReqs)
	}
}

// 接线:可用源够数、走不到标题反查时跑原产地曲名轮;标题反查与提前跑的反查都带上录音的 ISRC。
func TestOriginTitleRoundIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, n := range []string{
		"\t} else {\n\t\t// 可用源已经够数、走不到上面的标题反查时,缺着的源可能只是拿罗马字的本地曲名搜不到原文登记的这首歌,见 originTitleRound。\n\t\tne, results = originTitleRound(ctx, artist, title, album, durationSecs, ne, results, onUpdate)\n\t}\n\t// 还缺着的源换一种曲名写法再问一次",
		"titleSpec = startTitleReverseSpec(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results),\n\t\t\t\ttrustedRecordingISRC(artist, title, album, durationSecs, results))",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
	tr, err := os.ReadFile("titlereverse.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{
		"storefrontTitle := titleReverseOriginTitle(ctx, artist, title, album, durationSecs, samples, isrc)\n\tstorefrontOK := storefrontTitle != \"\"",
		"case storefrontOK:\n\t\tcorrectedTitle, retryMethod, titleArtist = storefrontTitle, lyricQueryReasonTitleStorefront, artist",
		"s.corrected, s.method, s.artist = titleReverseLookup(c, artist, title, album, durationSecs, samples, isrc)",
	} {
		if !strings.Contains(string(tr), n) {
			t.Errorf("titlereverse.go 缺 %q", n)
		}
	}
}
