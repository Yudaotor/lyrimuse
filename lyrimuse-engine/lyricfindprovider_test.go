package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

var lyricFindParitySource = providerParitySource{
	name: lyricSourceLyricFind,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := ytmusicLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "lyricfind", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly, identityFromLocalClient: r.fromLocalClient}
	},
	reset: func(t *testing.T) {
		resetYtmusicRegionState(t)
		resetYtmusicTranslatable(t)
		withKasetAudioVideoIDs(t)
		ytmusicMu.Lock()
		saved := ytmusicCache
		ytmusicCache = map[string]ytmusicResult{}
		ytmusicMu.Unlock()
		t.Cleanup(func() {
			ytmusicMu.Lock()
			ytmusicCache = saved
			ytmusicMu.Unlock()
		})
	},
	cacheKeys: func() []string {
		ytmusicMu.Lock()
		defer ytmusicMu.Unlock()
		var keys []string
		for k := range ytmusicCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		ytmusicVisitorMu.Lock()
		visitor, blocked, checked := ytmusicVisitorID, ytmusicRegionBlocked, !ytmusicRegionCheckedAt.IsZero()
		ytmusicVisitorMu.Unlock()
		ytmusicTranslatableMu.Lock()
		remembered := len(ytmusicTranslatable)
		ytmusicTranslatableMu.Unlock()
		yes := map[bool]string{true: "yes", false: "no"}
		return []string{"visitor=" + visitor, "region checked=" + yes[checked] + " blocked=" + yes[blocked],
			"last failure=" + ytmusicLastFailureReasonNow(), "remembered for translation=" + itoa(remembered)}
	},
	headers: []string{"X-Goog-Visitor-Id"},
}

// lyricFindParityFake:search / next / browse 答 InnerTube 的三个端点(只认首选主机上的),home 答首页(查地区时才问)。
// browse 拿到的是发请求的客户端名(手机端要逐行,网页端要纯文本)。别的主机一律 failover 指定的状态,0 = 404。
type lyricFindParityFake struct {
	search func() parityReply
	next   func(videoID string) parityReply
	browse func(clientName string) parityReply
	home   parityReply
	// primaryDown:首选主机上的 InnerTube 请求一律回 502,备用主机照常答。
	primaryDown bool
}

func (f lyricFindParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		if r.target == ytmHomeURL {
			return f.home
		}
		base, endpoint, ok := strings.Cut(r.target, "/youtubei/v1/")
		if !ok {
			return parityStatus(http.StatusNotFound)
		}
		if f.primaryDown && base == ytmusicDomain {
			return parityStatus(http.StatusBadGateway)
		}
		var body map[string]any
		_ = json.Unmarshal([]byte(r.body), &body)
		switch endpoint {
		case "search":
			return f.search()
		case "next":
			id, _ := body["videoId"].(string)
			return f.next(id)
		case "browse":
			client := ""
			if c, ok := body["context"].(map[string]any); ok {
				if cl, ok := c["client"].(map[string]any); ok {
					client, _ = cl["clientName"].(string)
				}
			}
			return f.browse(client)
		}
		return parityStatus(http.StatusNotFound)
	}
}

func TestLyricFindProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "Adele", "Hello", "25"
	found := func() parityReply {
		return parityOK(ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
	}
	lyricsTab := func(string) parityReply { return parityOK(ytmFakeNext) }
	timedFrom := func(source string) func(string) parityReply {
		return func(client string) parityReply {
			if client == ytmusicMobileClientName {
				return parityOK(ytmFakeTimed(source))
			}
			return parityStatus(http.StatusNotFound)
		}
	}
	hit := lyricFindParityFake{search: found, next: lyricsTab, browse: timedFrom("Source: LyricFind"), home: parityStatus(http.StatusNotFound)}
	with := func(edit func(*lyricFindParityFake)) func(parityRequest) parityReply {
		f := hit
		edit(&f)
		return f.handler()
	}
	kaset := func(ctx context.Context) context.Context { return withYouTubeMusicVideoID(ctx, "OsfAnsMY21M") }
	videoNext := func(videoType string) func(string) parityReply {
		return func(id string) parityReply {
			if id == "OsfAnsMY21M" {
				return parityOK(ytmFakeVideoNext(id, videoType))
			}
			return parityOK(ytmFakeNext)
		}
	}
	cases := []providerParityCase{
		{
			name: "搜索、歌词页入口、逐行三跳走通", artist: artist, title: title, album: album, durationSecs: 295,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !isTimedLRC(r.lyr) || r.matchTitle != "Hello" || r.matchArtist != "Adele" || r.matchAlbum != "25" || r.srcDur != 295 || r.matchCover == "" ||
					r.plainOnly || r.identityFromLocalClient {
					t.Errorf("逐行歌词、歌名、歌手、专辑、时长、封面都该带上,按名字搜到的不算播放器给的身份:%+v", r)
				}
				if got := strings.Join(o.state, "\n"); !strings.Contains(got, "visitor=VD1") || !strings.Contains(got, "remembered for translation=1") {
					t.Errorf("第一次应答给的 visitor id 该记下、这份歌词该记给机翻那一级:%v", o.state)
				}
			},
		},
		{
			name: "同名的两版:挑时长更近的那条", artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.search = func() parityReply {
					return parityOK(ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 3:10", "vid0", "MUSIC_VIDEO_TYPE_ATV"),
						ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.srcDur != 295 {
					t.Errorf("应挑 4:55 那一版:%+v", o.result)
				}
			},
		},
		{
			name: "逐行歌词标的是别家供应商:不收,也不去问纯文本", artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) { f.browse = timedFrom("Source: Musixmatch") }), wantRequests: 3,
		},
		{
			name: "没有逐行,只有 LyricFind 的纯文本:标 plainOnly", artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.browse = func(client string) parityReply {
					if client == ytmusicMobileClientName {
						return parityOK(ytmFakeNoLyrics)
					}
					return parityOK(ytmFakePlain("Source: LyricFind"))
				}
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || o.result.lyr != "Line one\nLine two\nLine three" {
					t.Errorf("应交纯文本:%+v", o.result)
				}
			},
		},
		{
			name: "这首没有歌词页", artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.next = func(string) parityReply { return parityOK(`{"contents":{"tabs":[]}}`) }
			}),
			wantRequests: 2,
		},
		{
			name: "搜到的都对不上:不查地区", artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.search = func() parityReply {
					return parityOK(ytmFakeSearch(ytmusicSearchItemJSON("Another Song", "Someone • X • 3:00", "vid9", "MUSIC_VIDEO_TYPE_ATV")))
				}
			}),
			wantRequests: 1,
		},
		{
			name: "一条都搜不到:查一次首页,认出地区受限,下一轮不再发请求", rounds: 2, artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.search = func() parityReply { return parityOK(ytmFakeSearch()) }
				f.home = parityOK("<html>YouTube Music is not available in your area</html>")
			}),
			wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if got := strings.Join(o.state, "\n"); !strings.Contains(got, "region checked=yes blocked=yes") || !strings.Contains(got, "last failure="+lyricFailureReasonLyricFindRegionRestricted) {
					t.Errorf("应记成地区受限:%v", o.state)
				}
			},
		},
		{
			name: "首选主机 502:换备用主机", artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) { f.primaryDown = true }), wantRequests: 6, wantLyrics: true,
		},
		{
			name: "播放器报了这首的 videoId:按它直取,带播放器给的身份", ctx: kaset, artist: "Dua Lipa", title: "Levitating", album: "Future Nostalgia", durationSecs: 203,
			handle: with(func(f *lyricFindParityFake) {
				f.search = func() parityReply { return parityReply{status: 596, body: "unexpected search"} }
				f.next = videoNext(ytmusicVideoTypeATV)
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !r.identityFromLocalClient || r.matchTitle != "Levitating" || r.matchArtist != "Dua Lipa" || r.matchAlbum != "Future Nostalgia" || r.srcDur != 203 ||
					r.matchCover != "https://lh3.googleusercontent.com/lev=s0" {
					t.Errorf("该带着这一版的登记信息和播放器给的身份:%+v", r)
				}
				if len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "video|") {
					t.Errorf("按 videoId 取到的记在它自己的键下:%v", o.cached)
				}
			},
		},
		{
			name:   "播放器报了 videoId,但这一轮问的是别的歌:身份不算播放器给的",
			ctx:    func(ctx context.Context) context.Context { return withOtherTrackRound(kaset(ctx)) },
			artist: "Dua Lipa", title: "Levitating", album: "Future Nostalgia", durationSecs: 203,
			handle: with(func(f *lyricFindParityFake) { f.next = videoNext(ytmusicVideoTypeATV) }), wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.identityFromLocalClient {
					t.Errorf("别的歌那一轮不算身份由播放器给定:%+v", o.result)
				}
			},
		},
		{
			name: "播放器报的那一版是 MV:不取它的,照旧按名字搜", ctx: kaset, artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) { f.next = videoNext("MUSIC_VIDEO_TYPE_OMV") }), wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.identityFromLocalClient || o.result.matchTitle != "Hello" {
					t.Errorf("应是按名字搜到的那份:%+v", o.result)
				}
			},
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 295,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "Adele|Hello|25" {
					t.Errorf("进程内缓存的键是歌手、歌名、专辑:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Hello (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.search = func() parityReply {
					return parityOK(ytmFakeSearch(ytmusicSearchItemJSON("Hello (#2)", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "Hello (#2)" || len(o.cached) != 1 || o.cached[0] != "Adele|Hello (#2)|25" {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 295,
			handle: with(func(f *lyricFindParityFake) {
				f.search = func() parityReply { return parityStatus(http.StatusTooManyRequests) }
			}),
			wantRequests: 3,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused music.youtube.com") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 295)...)
	runProviderParity(t, lyricFindParitySource, cases)
}

func TestLyricFindProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, lyricFindParitySource, "Adele", "Hello", 295)
}

func TestLyricFindProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, lyricFindParitySource, "Adele", "Hello", 295, parityNotFound)
}
