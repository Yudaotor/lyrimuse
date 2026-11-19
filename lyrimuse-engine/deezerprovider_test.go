package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

var deezerParitySource = providerParitySource{
	name: lyricSourceDeezer,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := deezerLyric(ctx, artist, srcTitle, album, durationSecs, lyricSourceISRC(ctx, artist, title, album))
		return lyricSourceResult{source: "deezer", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, songwriters: r.songwriters, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, isrc: r.isrc, plainOnly: r.plainOnly}
	},
	reset: func(t *testing.T) {
		savedFeatures, savedFailure := features(), deezerLastFailureReasonNow()
		featuresRef().LyricsTranslationLanguage = "zh"
		deezerClearJWT()
		deezerSetLastFailureReason("")
		deezerMu.Lock()
		savedCache := deezerCache
		deezerCache = map[string]deezerResult{}
		deezerMu.Unlock()
		t.Cleanup(func() {
			setFeatures(savedFeatures)
			deezerClearJWT()
			deezerSetLastFailureReason(savedFailure)
			deezerMu.Lock()
			deezerCache = savedCache
			deezerMu.Unlock()
		})
	},
	cacheKeys: func() []string {
		deezerMu.Lock()
		defer deezerMu.Unlock()
		var keys []string
		for k := range deezerCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		deezerJWTMu.Lock()
		jwt, failed := deezerJWT, !deezerJWTFailedAt.IsZero()
		deezerJWTMu.Unlock()
		return []string{"jwt=" + jwt, "jwt fetch failed=" + map[bool]string{true: "yes", false: "no"}[failed], "last failure=" + deezerLastFailureReasonNow()}
	},
	headers: []string{"Authorization", "Accept-Language"},
}

// 两张不会过期的假票(只带 exp)。
var (
	dzParityJWT    = dzFakeJWT(time.Unix(4102444800, 0))
	dzParityNewJWT = dzFakeJWT(time.Unix(4102448400, 0))
)

const (
	dzParityCover = "https://cdn-images.dzcdn.net/images/cover/abc/1000x1000-000000-80-0-0.jpg"
	dzParityISRC  = "USSM19902991"
)

// dzParityFake:auth 答换票(nil = 给 dzParityJWT;参数是这个请求在这一轮里排第几个);search / lyrics 答 GraphQL 的两种查询;public 答公开搜索接口;
// isrc 答按 ISRC 取录音。pipe 先看每个 GraphQL 请求,返回非 nil 就拿它当应答。没给的接口回 404。
type dzParityFake struct {
	auth   func(nth int) parityReply
	pipe   func(r parityRequest, op string) *parityReply
	search func(query string) parityReply
	lyrics func(trackID string) parityReply
	public func(q string) parityReply
	isrc   func(code string) parityReply
}

func (f dzParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		switch {
		case r.target == "https://auth.deezer.com/login/anonymous":
			if f.auth != nil {
				return f.auth(r.nth)
			}
			return parityOK(`{"jwt":"` + dzParityJWT + `"}`)
		case r.target == deezerPipeAPI:
			var body struct {
				OperationName string         `json:"operationName"`
				Variables     map[string]any `json:"variables"`
			}
			_ = json.Unmarshal([]byte(r.body), &body)
			if f.pipe != nil {
				if reply := f.pipe(r, body.OperationName); reply != nil {
					return *reply
				}
			}
			if body.OperationName == "SearchTracks" && f.search != nil {
				q, _ := body.Variables["query"].(string)
				return f.search(q)
			}
			if body.OperationName == "SynchronizedTrackLyrics" && f.lyrics != nil {
				id, _ := body.Variables["trackId"].(string)
				return f.lyrics(id)
			}
		case r.target == deezerSearchAPI && f.public != nil:
			return f.public(r.URL.Query().Get("q"))
		case strings.HasPrefix(r.target, deezerTrackAPI+"/isrc:") && f.isrc != nil:
			return f.isrc(strings.TrimPrefix(r.target, deezerTrackAPI+"/isrc:"))
		}
		return parityStatus(http.StatusNotFound)
	}
}

type dzParityTrack struct {
	id, title, artist, album string
	duration                 int
	sync                     bool
}

// dzParitySearch:GraphQL 搜索的应答,每条带 ISRC(dzParityISRC)和封面。
func dzParitySearch(tracks ...dzParityTrack) string {
	edges := make([]map[string]any, 0, len(tracks))
	for _, h := range tracks {
		edges = append(edges, map[string]any{"node": map[string]any{
			"id": h.id, "title": h.title, "duration": h.duration, "isrc": dzParityISRC, "hasSynchronizedLyrics": h.sync,
			"contributors": map[string]any{"edges": []any{map[string]any{"node": map[string]any{"name": h.artist}}}},
			"album":        map[string]any{"displayTitle": h.album, "cover": map[string]any{"urls": []string{dzParityCover}}},
		}})
	}
	b, _ := json.Marshal(map[string]any{"data": map[string]any{"search": map[string]any{"results": map[string]any{"tracks": map[string]any{"edges": edges}}}}})
	return string(b)
}

// dzParityPublicTrack:公开接口(搜索结果里的一条、按 ISRC 取到的一条)的形状。
func dzParityPublicTrack(t dzParityTrack) string {
	b, _ := json.Marshal(map[string]any{
		"id": 1001, "title": t.title, "duration": t.duration, "isrc": dzParityISRC,
		"artist": map[string]any{"name": t.artist}, "album": map[string]any{"title": t.album, "cover_xl": dzParityCover},
	})
	return string(b)
}

// dzParityFullLyrics:同步歌词带逐字、中文译文和作者名单。
func dzParityFullLyrics() string {
	translated := []string{"第一行", "第二行", "第三行", "第四行", "第五行", "第六行"}
	var sync, words []map[string]any
	for i, l := range dzSixLines {
		ms := (5 + i*10) * 1000
		sync = append(sync, map[string]any{"lrcTimestamp": formatLRCTime(ms), "milliseconds": ms, "line": l, "lineTranslated": translated[i]})
		var ws []map[string]any
		for j, w := range strings.Fields(l) {
			ws = append(ws, map[string]any{"start": ms + j*400, "end": ms + j*400 + 300, "word": w})
		}
		words = append(words, map[string]any{"start": ms, "end": ms + 4000, "words": ws})
	}
	b, _ := json.Marshal(map[string]any{"data": map[string]any{"track": map[string]any{"lyrics": map[string]any{
		"text": strings.Join(dzSixLines, "\n"), "writers": "Rod Temperton, Someone Else",
		"synchronizedLines": sync, "synchronizedWordByWordLines": words,
	}}}})
	return string(b)
}

func TestDeezerProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "Michael Jackson", "Thriller", "Thriller"
	track := dzParityTrack{"1001", "Thriller", "Michael Jackson", "Thriller", 357, true}
	found := func(string) parityReply { return parityOK(dzParitySearch(track)) }
	full := func(string) parityReply { return parityOK(dzParityFullLyrics()) }
	hit := dzParityFake{search: found, lyrics: full}
	with := func(edit func(*dzParityFake)) func(parityRequest) parityReply {
		f := hit
		edit(&f)
		return f.handler()
	}
	withISRC := func(ctx context.Context) context.Context { return withRecordingISRC(ctx, dzParityISRC) }
	cases := []providerParityCase{
		{
			name: "GraphQL 搜索命中:同步歌词、逐字、译文、作者都取", artist: artist, title: title, album: album, durationSecs: 357,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !strings.Contains(r.lyr, "line one") || r.yrc == "" || !strings.Contains(r.tr, "第一行") || len(r.songwriters) != 2 || r.songwriters[0] != "Rod Temperton" ||
					r.matchTitle != "Thriller" || r.matchArtist != "Michael Jackson" || r.matchAlbum != "Thriller" || r.srcDur != 357 || r.isrc != dzParityISRC ||
					r.matchCover != "https://cdn-images.dzcdn.net/images/cover/abc/1800x1800-000000-80-0-0.jpg" || r.plainOnly {
					t.Errorf("正文、逐字、译文、作者、歌名、歌手、专辑、时长、ISRC、封面都该带上:%+v", r)
				}
				if !strings.Contains(strings.Join(o.requests, "\n"), "Authorization=Bearer "+dzParityJWT) {
					t.Errorf("GraphQL 请求该带换来的票:%v", o.requests)
				}
			},
		},
		{
			name: "手上有这条录音的 ISRC:按它直取,不搜", ctx: withISRC, artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = nil
				f.isrc = func(string) parityReply { return parityOK(dzParityPublicTrack(track)) }
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || !strings.Contains(o.cached[0], "|"+dzParityISRC+"|") || !strings.Contains(strings.Join(o.requests, "\n"), "/track/isrc:"+dzParityISRC) {
					t.Errorf("应按 ISRC 直取、缓存的键带着它:%v %v", o.cached, o.requests)
				}
			},
		},
		{
			name: "按 ISRC 取到的那条时长对不上:照旧按名字搜", ctx: withISRC, artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.isrc = func(string) parityReply {
					return parityOK(dzParityPublicTrack(dzParityTrack{"1001", "Thriller", "Michael Jackson", "Thriller", 120, true}))
				}
			}),
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "GraphQL 搜索没问成:公开搜索接口顶上", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = func(string) parityReply { return parityStatus(http.StatusInternalServerError) }
				f.public = func(string) parityReply { return parityOK(`{"data":[` + dzParityPublicTrack(track) + `]}`) }
			}),
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "匿名票换不到:搜得到也取不了词,记下失败原因", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.auth = func(int) parityReply { return parityStatus(http.StatusInternalServerError) }
				f.public = func(string) parityReply { return parityOK(`{"data":[` + dzParityPublicTrack(track) + `]}`) }
			}),
			wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if got := strings.Join(o.state, "\n"); !strings.Contains(got, "last failure="+lyricFailureReasonDeezerAuthFailed) || !strings.Contains(got, "jwt fetch failed=yes") {
					t.Errorf("应记下换票失败:%v", o.state)
				}
			},
		},
		{
			name: "票被拒(401):清掉重换一张再发", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.auth = func(nth int) parityReply {
					if nth == 1 {
						return parityOK(`{"jwt":"` + dzParityJWT + `"}`)
					}
					return parityOK(`{"jwt":"` + dzParityNewJWT + `"}`)
				}
				f.pipe = func(r parityRequest, _ string) *parityReply {
					if r.Header.Get("Authorization") == "Bearer "+dzParityJWT {
						return &parityReply{status: http.StatusUnauthorized}
					}
					return nil
				}
			}),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.state[len(o.state)-3] != "jwt="+dzParityNewJWT {
					t.Errorf("应换成新票:%v", o.state)
				}
			},
		},
		{
			name: "只有纯文本:标 plainOnly", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.lyrics = func(string) parityReply {
					return parityOK(`{"data":{"track":{"lyrics":{"text":"line one\nline two","writers":"Rod Temperton"}}}}`)
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || o.result.lyr != "line one\nline two" || len(o.result.songwriters) != 1 {
					t.Errorf("应交纯文本、作者照带:%+v", o.result)
				}
			},
		},
		{
			name: "这条录音没有歌词", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.lyrics = func(string) parityReply {
					return parityOK(`{"errors":[{"type":"LyricsNotFoundError","message":"Lyrics does not exists"}],"data":{"track":{"lyrics":null}}}`)
				}
			}),
			wantRequests: 3,
		},
		{
			name: "标着没有同步歌词的不取,取标着有的那条", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = func(string) parityReply {
					return parityOK(dzParitySearch(dzParityTrack{"1002", "Thriller", "Michael Jackson", "Thriller", 357, false},
						dzParityTrack{"1003", "Thriller", "Michael Jackson", "Thriller 25", 358, true}))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchAlbum != "Thriller 25" {
					t.Errorf("应是标着有同步歌词的那条:%+v", o.result)
				}
			},
		},
		{
			name: "第一名取词没问成:接着取下一名,不进缓存", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = func(string) parityReply {
					return parityOK(dzParitySearch(track, dzParityTrack{"1003", "Thriller", "Michael Jackson", "Thriller 25", 358, true}))
				}
				f.lyrics = func(id string) parityReply {
					if id == "1001" {
						return parityStatus(http.StatusBadGateway)
					}
					return parityOK(dzParityFullLyrics())
				}
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchAlbum != "Thriller 25" || len(o.cached) != 0 {
					t.Errorf("用下一名的、这一轮不完整不进缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "一条都没搜到", artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = func(string) parityReply { return parityOK(dzParitySearch()) }
			}),
			wantRequests: 2,
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 357,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "Michael Jackson|Thriller|Thriller||") {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑、ISRC(这里没有)和译文语言:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Thriller (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = func(string) parityReply {
					return parityOK(dzParitySearch(dzParityTrack{"1001", "Thriller (#2)", "Michael Jackson", "Thriller", 357, true}))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "Thriller (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "Michael Jackson|Thriller (#2)|") {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 357,
			handle: with(func(f *dzParityFake) {
				f.search = func(string) parityReply { return parityStatus(http.StatusTooManyRequests) }
				f.public = func(string) parityReply { return parityStatus(http.StatusTooManyRequests) }
			}),
			wantRequests: 3,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused pipe.deezer.com") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 357)...)
	runProviderParity(t, deezerParitySource, cases)
}

func TestDeezerProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, deezerParitySource, "Michael Jackson", "Thriller", 357)
}

func TestDeezerProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, deezerParitySource, "Michael Jackson", "Thriller", 357, parityNotFound)
}
