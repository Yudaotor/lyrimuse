package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

var genieParitySource = providerParitySource{
	name: lyricSourceGenie,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := genieLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "genie", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	},
	reset: func(t *testing.T) {
		genieMu.Lock()
		saved := genieCache
		genieCache = map[string]genieResult{}
		genieMu.Unlock()
		t.Cleanup(func() {
			genieMu.Lock()
			genieCache = saved
			genieMu.Unlock()
		})
	},
	cacheKeys: func() []string {
		genieMu.Lock()
		defer genieMu.Unlock()
		var keys []string
		for k := range genieCache {
			keys = append(keys, k)
		}
		return keys
	},
	headers: []string{"User-Agent"},
}

const genieParityEmpty = `{"searchResult":{"result":{"songs":{"items":[]}}}}`

func genieIsSearch(r parityRequest) bool {
	return strings.HasSuffix(r.target, "/search/category/songs.json")
}

// genieParityFake:Genie 头两条检索词是并发发的,假服务器让它们一起到(pairGate)再各自答;paired 是并发的那两条,
// 别的检索词(按原样歌名补搜的第三条)单独来、不配对。search 答检索、lyric 答取词(按 songid)。
// search 返回 nil 表示把这条检索挂到这一轮结束(parityHang):带歌手的那条有候选或失败时源不再等另一条,另一条的应答
// 到得早晚会让这一轮记下的东西时有时无,所以一律挂住。
func genieParityFake(paired []string, search func(query string) *parityReply, lyric func(songID string) parityReply) func(parityRequest) parityReply {
	gate := &pairGate{}
	return func(r parityRequest) parityReply {
		if genieIsSearch(r) {
			q := r.URL.Query().Get("query")
			if q == paired[0] || q == paired[1] {
				if !gate.arrive() {
					return pairGateTimedOut
				}
			} else if len(paired) < 3 || q != paired[2] {
				return parityReply{status: 598, body: "unexpected query " + q}
			}
			if reply := search(q); reply != nil {
				return *reply
			}
			return parityHang(r)
		}
		return lyric(r.URL.Query().Get("songid"))
	}
}

func genieReply(body string) *parityReply { return &parityReply{body: body} }

func TestGenieProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "검정치마", "Antifreeze", "201"
	pair := []string{"Antifreeze 검정치마", "Antifreeze"}
	// 带歌手的那条给结果,只按歌名的那条挂住。
	hits := func(q string) *parityReply {
		if q != pair[0] {
			return nil
		}
		return genieReply(genieTestSearch)
	}
	none := func(string) *parityReply { return genieReply(genieParityEmpty) }
	// 带歌手的那条失败、源当场返回,并发的另一条挂到这一轮结束。
	failFirst := func(status int) func(string) *parityReply {
		return func(q string) *parityReply {
			if q == pair[0] {
				return &parityReply{status: status}
			}
			return nil
		}
	}
	syncFor := func(ids ...string) func(string) parityReply {
		return func(id string) parityReply {
			for _, want := range ids {
				if id == want {
					return parityOK(genieTestSync)
				}
			}
			return parityOK(genieNoLyrics)
		}
	}
	cases := []providerParityCase{
		{
			name: "「歌名 歌手」那条就命中", artist: artist, title: title, album: album, durationSecs: 242,
			handle: genieParityFake(pair, hits, syncFor("11")), wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if r.matchTitle != "Antifreeze" || r.matchArtist != "검정치마" || r.matchAlbum != "201" || r.srcDur != 242 ||
					r.matchCover != "https://image.genie.co.kr/Y/IMAGE/IMG_ALBUM/1_600x600.JPG" || r.plainOnly {
					t.Errorf("歌名、歌手、专辑、时长、封面都该带上:%+v", r)
				}
			},
		},
		{
			name: "带歌手的一条都没有,只按歌名的命中", artist: artist, title: title, album: album, durationSecs: 242,
			handle: genieParityFake(pair, func(q string) *parityReply {
				if q == "Antifreeze 검정치마" {
					return genieReply(genieParityEmpty)
				}
				return genieReply(genieTestSearch)
			}, syncFor("11")),
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "哪一条都没搜到", artist: artist, title: title, album: album, durationSecs: 242,
			handle: genieParityFake(pair, none, syncFor()), wantRequests: 2,
		},
		{
			name: "搜索没问成", artist: artist, title: title, album: album, durationSecs: 242,
			handle: genieParityFake(pair, failFirst(http.StatusBadGateway), syncFor()), wantRequests: 2,
		},
		{
			name: "第一名没有同步歌词,第二名有", artist: artist, title: title, durationSecs: 242,
			handle: genieParityFake(pair, hits, syncFor("12")), wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.plainOnly || o.result.matchAlbum != "201 (Special Edition)" || len(o.cached) != 1 {
					t.Errorf("应挑第二名带同步的那份,「没有」是答了、照样进缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "第一名取词 500:退到第二名,不进缓存", artist: artist, title: title, durationSecs: 242,
			handle: genieParityFake(pair, hits, func(id string) parityReply {
				if id == "11" {
					return parityReply{status: http.StatusInternalServerError, body: "<html>error</html>"}
				}
				return parityOK(genieTestSync)
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 0 || o.result.matchAlbum != "201 (Special Edition)" {
					t.Errorf("退到第二名、这一轮不完整不进缓存:%v %+v", o.cached, o.result)
				}
			},
		},
		{
			name: "都没有同步歌词:交第一名的纯文本,标 plainOnly", artist: artist, title: title, durationSecs: 242,
			handle: genieParityFake(pair, hits, syncFor()), wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || o.result.lyr != "우린 오래 전부터" || o.result.matchAlbum != "201" {
					t.Errorf("应交第一名的纯文本:%+v", o.result)
				}
			},
		},
		{
			name: "清理过的两条都没过闸:按原样的歌名再搜一次", artist: "Taylor Swift & Bon Iver", title: "evermore (feat. Bon Iver)", album: "evermore", durationSecs: 304,
			handle: genieParityFake([]string{"evermore Taylor Swift", "evermore", "evermore (feat. Bon Iver)"}, func(q string) *parityReply {
				if q == "evermore (feat. Bon Iver)" {
					return genieReply(`{"searchResult":{"result":{"songs":{"items":[{"song_id":31,"song_name":{"original":"evermore (Feat. Bon Iver)"},"artist_name":{"original":"Taylor Swift"},"album_name":{"original":"evermore"},"duration":{"time":304},"lyrics":"x","service_available":{"lyrics_service_yn":"Y"}}]}}}}`)
				}
				return genieReply(`{"searchResult":{"result":{"songs":{"items":[{"song_id":32,"song_name":{"original":"willow"},"artist_name":{"original":"Taylor Swift"},"album_name":{"original":"evermore"},"duration":{"time":214},"lyrics":"x","service_available":{"lyrics_service_yn":"Y"}}]}}}}`)
			}, syncFor("31")),
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 242,
			handle: genieParityFake(pair, hits, syncFor("11")), wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "검정치마|Antifreeze|201|242" {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑和取整的时长:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Antifreeze (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 242,
			// 检索词里不带编号(lyricQueryTitle 去掉了),挑候选和缓存的键按带编号的歌名。
			handle: genieParityFake(pair, func(q string) *parityReply {
				if q != pair[0] {
					return nil
				}
				return genieReply(strings.ReplaceAll(genieTestSearch, `{"original":"Antifreeze"}`, `{"original":"Antifreeze (#2)"}`))
			}, syncFor("11")),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "Antifreeze (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "검정치마|Antifreeze (#2)|") {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 242,
			handle: genieParityFake(pair, failFirst(http.StatusTooManyRequests), syncFor()), wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused app.genie.co.kr") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 242)...)
	runProviderParity(t, genieParitySource, cases)
}

func TestGenieProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, genieParitySource, "검정치마", "Antifreeze", 242)
}

func TestGenieProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, genieParitySource, "검정치마", "Antifreeze", 242, parityNotFound)
}
