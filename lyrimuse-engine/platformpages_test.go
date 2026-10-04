package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"
)

func resetPlatformPagesForTest(t *testing.T) {
	t.Helper()
	platformPagesMu.Lock()
	old, oldPath := platformPagesCache, platformPagesPath
	platformPagesCache = platformPagesFile{Artists: map[string]platformArtistPages{}, Albums: map[string]platformAlbumPages{},
		Tracks: map[string]platformTrackPages{}}
	platformPagesPath = ""
	platformPagesMu.Unlock()
	t.Cleanup(func() {
		platformPagesMu.Lock()
		platformPagesCache, platformPagesPath = old, oldPath
		platformPagesMu.Unlock()
	})
}

func TestPickArtistPlatformPages(t *testing.T) {
	var rels mbURLRelations
	raw := `{"relations":[
		{"url":{"resource":"https://open.spotify.com/album/1C2h7mLntPSeVYciMRTF4a"}},
		{"url":{"resource":"https://open.spotify.com/artist/3fMbdgg4jU18AjLCKBhRSm"}},
		{"url":{"resource":"https://music.apple.com/us/album/x/1"}},
		{"url":{"resource":"https://music.apple.com/us/artist/michael-jackson/32940"}}]}`
	if err := json.Unmarshal([]byte(raw), &rels); err != nil {
		t.Fatal(err)
	}
	got := pickArtistPlatformPages(rels)
	want := platformArtistPages{Spotify: "3fMbdgg4jU18AjLCKBhRSm", Apple: "https://music.apple.com/us/artist/michael-jackson/32940"}
	if got != want {
		t.Fatalf("got %+v, want %+v (专辑链接不当歌手页)", got, want)
	}
	if id := spotifyIDFromURL("https://open.spotify.com/artist/short", "artist"); id != "" {
		t.Fatalf("不是 22 位 base62 的 ID 不收,得到 %q", id)
	}
	if id := spotifyIDFromURL("https://open.spotify.com/intl-ja/album/6k7RVZ7bSL9ryReb8RLYRI", "album"); id != "6k7RVZ7bSL9ryReb8RLYRI" {
		t.Fatalf("带语言前缀的链接也要认,得到 %q", id)
	}
}

func TestPickReleaseSpotifyAlbum(t *testing.T) {
	var b mbReleaseBrowse
	raw := `{"releases":[{"relations":[{"url":{"resource":"https://www.discogs.com/release/1"}}]},
		{"relations":[{"url":{"resource":"https://open.spotify.com/album/0oX4SealMgNXrvRDhqqOKg"}}]}]}`
	if err := json.Unmarshal([]byte(raw), &b); err != nil {
		t.Fatal(err)
	}
	if got := pickReleaseSpotifyAlbum(b); got != "0oX4SealMgNXrvRDhqqOKg" {
		t.Fatalf("got %q", got)
	}
	if got := pickReleaseSpotifyAlbum(mbReleaseBrowse{}); got != "" {
		t.Fatalf("没有 Spotify 链接时返回空,得到 %q", got)
	}
}

func TestPlatformAlbumSearchTitles(t *testing.T) {
	cases := map[string][]string{
		"Xscape (Deluxe)":              {"Xscape (Deluxe)", "Xscape"},
		"First Love (Remastered 2014)": {"First Love (Remastered 2014)", "First Love"},
		"Dangerous":                    {"Dangerous"},
		"晴天 - Single":                  {"晴天 - Single", "晴天"},
		"Blonde (Live)":                {"Blonde (Live)"}, // 不是再版 / 加料版的括号不去
		"100种生活（豪华版）":                  {"100种生活（豪华版）", "100种生活"},
	}
	for in, want := range cases {
		if got := platformAlbumSearchTitles(in); !reflect.DeepEqual(got, want) {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
}

func TestMBLuceneQuote(t *testing.T) {
	if got := mbLuceneQuote(`He said "hi" \o/`); got != `"He said \"hi\" \\o/"` {
		t.Fatalf("got %s", got)
	}
}

func TestPlatformAlbumKey(t *testing.T) {
	if got := platformAlbumKey(" Michael Jackson ", "Xscape (Deluxe)"); got != "michael jackson|xscape (deluxe)" {
		t.Fatalf("got %q", got)
	}
}

func fakePlatformSource(calls *[]string) platformPagesSource {
	return platformPagesSource{
		topArtists: func(_ context.Context, period string) ([]lastfmChartEntry, error) {
			return []lastfmChartEntry{{Name: "Prince"}, {Name: "Michael Jackson"}, {Name: "无名氏"}}, nil
		},
		topAlbums: func(_ context.Context, period string) ([]lastfmChartEntry, error) {
			return []lastfmChartEntry{{Name: "Dangerous", Artist: "Michael Jackson"}, {Name: "15", Artist: "无名氏"}}, nil
		},
		artistPages: func(_ context.Context, mbid string) (platformArtistPages, int, error) {
			*calls = append(*calls, "artist:"+mbid)
			if mbid == "mb-fail" {
				return platformArtistPages{}, 1, errors.New("503")
			}
			return platformArtistPages{Spotify: "sp-" + mbid}, 1, nil
		},
		albumSpotify: func(_ context.Context, mbid, album string) (string, int, error) {
			*calls = append(*calls, "album:"+mbid+"/"+album)
			return "al-" + album, 2, nil
		},
		artistMbid: func(name string) string {
			return map[string]string{"Prince": "mb-prince", "Michael Jackson": "mb-mj"}[name]
		},
	}
}

func TestWarmPlatformPagesFillsAndDedupes(t *testing.T) {
	resetPlatformPagesForTest(t)
	var calls []string
	now := time.Unix(1_800_000_000, 0)
	if !warmPlatformPages(context.Background(), now, 60, fakePlatformSource(&calls)) {
		t.Fatal("第一轮应当有变化")
	}
	// 四个时段给的是同一批条目:每位歌手、每张专辑只查一次;没有 mbid 的跳过
	want := []string{"artist:mb-prince", "artist:mb-mj", "album:mb-mj/Dangerous"}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %q, want %q", calls, want)
	}
	if got := platformPagesCache.Artists["mb-mj"].Spotify; got != "sp-mb-mj" {
		t.Fatalf("歌手结果没落进缓存: %q", got)
	}
	if got := platformPagesCache.Albums[platformAlbumKey("Michael Jackson", "Dangerous")].Spotify; got != "al-Dangerous" {
		t.Fatalf("专辑结果没落进缓存: %q", got)
	}
	calls = nil
	if warmPlatformPages(context.Background(), now.Add(time.Hour), 60, fakePlatformSource(&calls)) || len(calls) != 0 {
		t.Fatalf("间隔没到不应再跑: calls=%q", calls)
	}
	calls = nil
	if !warmPlatformPages(context.Background(), now.Add(platformPagesCheckInterval), 60, fakePlatformSource(&calls)) || len(calls) != 0 {
		t.Fatalf("间隔到了再跑一轮,但已有结论的条目不重查: calls=%q", calls)
	}
	calls = nil
	warmPlatformPages(context.Background(), now.Add(platformPagesRetryAfter+platformPagesCheckInterval), 60, fakePlatformSource(&calls))
	if len(calls) != 3 {
		t.Fatalf("过了重查期限要重查: calls=%q", calls)
	}
}

func TestWarmPlatformPagesBudgetAndFailures(t *testing.T) {
	resetPlatformPagesForTest(t)
	var calls []string
	src := fakePlatformSource(&calls)
	src.artistMbid = func(name string) string {
		return map[string]string{"Prince": "mb-fail", "Michael Jackson": "mb-mj"}[name]
	}
	warmPlatformPages(context.Background(), time.Unix(1_800_000_000, 0), 2, src)
	// 预算 2:两位歌手各 1 个请求就用完,专辑这轮不查
	if want := []string{"artist:mb-fail", "artist:mb-mj"}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %q, want %q", calls, want)
	}
	if _, ok := platformPagesCache.Artists["mb-fail"]; ok {
		t.Fatal("没问成的不记结论,下轮再查")
	}
	now := time.Unix(1_800_000_000, 0)
	if got, want := platformPagesCache.Updated, now.Add(platformPagesPartialRetry-platformPagesCheckInterval).Unix(); got != want {
		t.Fatalf("额度用完没查完:时间戳 %d,want %d(半小时后接着查)", got, want)
	}
	calls = nil
	warmPlatformPages(context.Background(), now.Add(platformPagesPartialRetry), 60, src)
	if len(calls) == 0 {
		t.Fatal("半小时后应当接着查")
	}
}

func TestWarmPlatformPagesCancelledDoesNotStamp(t *testing.T) {
	resetPlatformPagesForTest(t)
	ctx, cancel := context.WithCancel(context.Background())
	var calls []string
	src := fakePlatformSource(&calls)
	inner := src.artistPages
	src.artistPages = func(c context.Context, mbid string) (platformArtistPages, int, error) {
		defer cancel() // 查完第一位歌手时进程退出
		return inner(c, mbid)
	}
	if !warmPlatformPages(ctx, time.Unix(1_800_000_000, 0), 60, src) {
		t.Fatal("已经查到的结果要落盘")
	}
	if len(calls) != 1 {
		t.Fatalf("取消后不再发请求: calls=%q", calls)
	}
	if platformPagesCache.Updated != 0 {
		t.Fatal("被取消的一轮不盖时间戳,下次启动接着查")
	}
}

func TestWarmPlatformPagesSkipsWhenLastfmEmpty(t *testing.T) {
	resetPlatformPagesForTest(t)
	src := platformPagesSource{
		topArtists: func(context.Context, string) ([]lastfmChartEntry, error) { return nil, errors.New("down") },
		topAlbums:  func(context.Context, string) ([]lastfmChartEntry, error) { return nil, errors.New("down") },
	}
	now := time.Unix(1_800_000_000, 0)
	if warmPlatformPages(context.Background(), now, 60, src) {
		t.Fatal("Last.fm 一条都没取到时这轮不算数")
	}
	if len(platformPagesCache.Artists) != 0 || len(platformPagesCache.Albums) != 0 {
		t.Fatal("不算数的一轮不记结论")
	}
	if got, want := platformPagesCache.Updated, now.Add(platformPagesPartialRetry-platformPagesCheckInterval).Unix(); got != want {
		t.Fatalf("Updated = %d, want %d: 取不到也要退避到 %v 之后,不能每 5 秒一拍就重发", got, want, platformPagesPartialRetry)
	}
	if warmPlatformPages(context.Background(), now.Add(time.Minute), 60, src) {
		t.Fatal("退避期内不该再跑")
	}
}

func TestParseSpotifyEmbedAlbum(t *testing.T) {
	page := `<html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"name":"Prince","trackList":[
		{"title":"I Wanna Be Your Lover","uri":"spotify:track:4yrM5BVyJzy5Ed4GPO6e8j"},
		{"title":"Sexy Dancer","uri":"spotify:track:3KgByVmDzMkOXwtbqbqjBn"},
		{"title":"Bad","uri":"spotify:episode:3KgByVmDzMkOXwtbqbqjBn"},
		{"title":"Short","uri":"spotify:track:short"}]}}}}}}</script></html>`
	got := parseSpotifyEmbedAlbum([]byte(page))
	want := []spotifyAlbumTrack{{"I Wanna Be Your Lover", "4yrM5BVyJzy5Ed4GPO6e8j"}, {"Sexy Dancer", "3KgByVmDzMkOXwtbqbqjBn"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v(不是曲目、ID 不合法的跳过)", got, want)
	}
	if got := parseSpotifyEmbedAlbum([]byte("<html>no data</html>")); got != nil {
		t.Fatalf("页面不是预期形状时返回空: %+v", got)
	}
}

func TestMatchSpotifyAlbumTrack(t *testing.T) {
	list := []spotifyAlbumTrack{
		{"When We're Dancing Close and Slow", "1oZNh749l4OIJYgrnpENZG"},
		{"Purple Rain - 2015 Paisley Park Remaster", "54X78diSLoUDI3joC2bjMz"},
		{"Take Me with U (Live)", "0000000000000000000001"},
	}
	cases := map[string]string{
		"When We're Dancing Close And Slow": "1oZNh749l4OIJYgrnpENZG", // 大小写、标点不计
		"Purple Rain":                       "54X78diSLoUDI3joC2bjMz", // Spotify 那边带再版尾巴
		"Purple Rain (Remastered 2015)":     "54X78diSLoUDI3joC2bjMz", // 两边写法不同的再版尾巴
		"Take Me with U":                    "",                       // Live 是另一份录音,不当同一首
		"":                                  "",
	}
	for title, want := range cases {
		if got := matchSpotifyAlbumTrack(list, title); got != want {
			t.Errorf("%q: got %q, want %q", title, got, want)
		}
	}
}

func TestEnrichAlbumsFor(t *testing.T) {
	enrichMu.Lock()
	old := enrichCache
	enrichCache = map[string]enrichEntry{
		enrichKey("Prince", "Sexy Dancer", "Prince"):                            {},
		enrichKey("Prince", "Sexy Dancer", "The Hits/The B-Sides"):              {},
		enrichKey("Prince", "Sexy Dancer", "Prince") + "x":                      {},
		enrichKey("Prince", "Sexy Dancer (Remastered)", "Ultimate"):             {},
		enrichKey("Prince", "Sexy Dancer", ""):                                  {},
		enrichKey("Prince", "Bambi", "Prince"):                                  {},
		enrichKeyDurationVariant(enrichKey("Prince", "Sexy Dancer", "Live"), 2): {},
	}
	enrichMu.Unlock()
	t.Cleanup(func() { enrichMu.Lock(); enrichCache = old; enrichMu.Unlock() })
	got := enrichAlbumsFor("Prince", "Sexy Dancer", 5)
	want := []string{"Prince", "Princex", "The Hits/The B-Sides"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q(不管专辑、空专辑与时长变体不算)", got, want)
	}
	if got := enrichAlbumsFor("Prince", "Sexy Dancer", 1); !reflect.DeepEqual(got, []string{"Prince"}) {
		t.Fatalf("最多 n 个: %q", got)
	}
}

func TestWarmPlatformPagesTracks(t *testing.T) {
	resetPlatformPagesForTest(t)
	var calls []string
	src := fakePlatformSource(&calls)
	src.topArtists = func(context.Context, string) ([]lastfmChartEntry, error) { return nil, nil }
	src.topAlbums = func(context.Context, string) ([]lastfmChartEntry, error) { return nil, nil }
	src.topTracks = func(context.Context, string) ([]lastfmChartEntry, error) {
		return []lastfmChartEntry{
			{Name: "I Wanna Be Your Lover", Artist: "Prince"},
			{Name: "Sexy Dancer", Artist: "Prince"},
			{Name: "Nowhere", Artist: "Prince"},
			{Name: "Unknown Album Song", Artist: "Prince"},
		}, nil
	}
	src.trackAlbums = func(artist, title string, n int) []string {
		if title == "Unknown Album Song" {
			return nil
		}
		return []string{"Prince"}
	}
	src.albumSpotify = func(_ context.Context, mbid, album string) (string, int, error) {
		calls = append(calls, "album:"+album)
		return "6k7RVZ7bSL9ryReb8RLYRI", 2, nil
	}
	src.albumTracks = func(_ context.Context, id string) ([]spotifyAlbumTrack, error) {
		calls = append(calls, "embed:"+id)
		return []spotifyAlbumTrack{{"I Wanna Be Your Lover", "4yrM5BVyJzy5Ed4GPO6e8j"}, {"Sexy Dancer", "3KgByVmDzMkOXwtbqbqjBn"}}, nil
	}
	if !warmPlatformPages(context.Background(), time.Unix(1_800_000_000, 0), 60, src) {
		t.Fatal("应当有变化")
	}
	// 同一张专辑:MusicBrainz 只查一次、嵌入页只取一次
	if want := []string{"album:Prince", "embed:6k7RVZ7bSL9ryReb8RLYRI"}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %q, want %q", calls, want)
	}
	tracks := platformPagesCache.Tracks
	if got := tracks[platformAlbumKey("Prince", "Sexy Dancer")].Spotify; got != "3KgByVmDzMkOXwtbqbqjBn" {
		t.Fatalf("Sexy Dancer: %q", got)
	}
	if e, ok := tracks[platformAlbumKey("Prince", "Nowhere")]; !ok || e.Spotify != "" {
		t.Fatalf("专辑里对不上的歌记成查过没有: %+v ok=%v", e, ok)
	}
	if _, ok := tracks[platformAlbumKey("Prince", "Unknown Album Song")]; ok {
		t.Fatal("歌词缓存里还没专辑的歌不记结论")
	}
	if got := platformPagesCache.Albums[platformAlbumKey("Prince", "Prince")].Spotify; got != "6k7RVZ7bSL9ryReb8RLYRI" {
		t.Fatalf("顺带查到的专辑也落进缓存: %q", got)
	}
}

func TestWarmPlatformPagesTrackEmbedFailureNotRecorded(t *testing.T) {
	resetPlatformPagesForTest(t)
	var calls []string
	src := fakePlatformSource(&calls)
	src.topArtists = func(context.Context, string) ([]lastfmChartEntry, error) { return nil, nil }
	src.topAlbums = func(context.Context, string) ([]lastfmChartEntry, error) { return nil, nil }
	src.topTracks = func(context.Context, string) ([]lastfmChartEntry, error) {
		return []lastfmChartEntry{{Name: "Sexy Dancer", Artist: "Prince"}}, nil
	}
	src.trackAlbums = func(string, string, int) []string { return []string{"Prince"} }
	src.albumTracks = func(context.Context, string) ([]spotifyAlbumTrack, error) { return nil, errors.New("timeout") }
	warmPlatformPages(context.Background(), time.Unix(1_800_000_000, 0), 60, src)
	if _, ok := platformPagesCache.Tracks[platformAlbumKey("Prince", "Sexy Dancer")]; ok {
		t.Fatal("嵌入页没取成时不记结论,下轮再查")
	}
}

// 嵌入页拿到了但认不出曲目表:报错(这一首不记成「查过、没有」)并记进认不出计数。
func TestSpotifyEmbedAlbumTracksUnrecognizedPage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `<html><body>redesigned</body></html>`)
	}))
	defer srv.Close()
	oldBase, oldClient := spotifyEmbedBaseURL, spotifyEmbedClient
	spotifyEmbedBaseURL, spotifyEmbedClient = srv.URL+"/", srv.Client()
	parserDriftMu.Lock()
	delete(parserDrift, spotifyEmbedParserName)
	parserDriftMu.Unlock()
	t.Cleanup(func() {
		spotifyEmbedBaseURL, spotifyEmbedClient = oldBase, oldClient
		parserDriftMu.Lock()
		delete(parserDrift, spotifyEmbedParserName)
		parserDriftMu.Unlock()
	})
	if _, err := spotifyEmbedAlbumTracks(context.Background(), "0qGQrHicD7qXuz5VMlDuCe"); !errors.Is(err, errPageUnrecognized) {
		t.Fatalf("err = %v, want errPageUnrecognized", err)
	}
	parserDriftMu.Lock()
	e := parserDrift[spotifyEmbedParserName]
	parserDriftMu.Unlock()
	if e == nil || e.Streak != 1 {
		t.Fatalf("认不出计数 = %+v, want 1", e)
	}
}
