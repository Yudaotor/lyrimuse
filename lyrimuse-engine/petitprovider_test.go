package main

import (
	"context"
	"encoding/base64"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"testing"
)

var petitParitySource = providerParitySource{
	name: lyricSourcePetitLyrics,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := petitLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "petitlyrics", lyr: r.lyrics, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, isrc: r.isrc, plainOnly: r.plainOnly}
	},
	reset: func(t *testing.T) {
		petitMu.Lock()
		saved := petitCache
		petitCache = map[string]petitResult{}
		petitMu.Unlock()
		savedIdx := petitClientIdx.Load()
		petitClientIdx.Store(0)
		t.Cleanup(func() {
			petitMu.Lock()
			petitCache = saved
			petitMu.Unlock()
			petitClientIdx.Store(savedIdx)
		})
	},
	cacheKeys: func() []string {
		petitMu.Lock()
		defer petitMu.Unlock()
		var keys []string
		for k := range petitCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string { return []string{"client=" + strconv.Itoa(int(petitClientIdx.Load()))} },
}

// petitParityFake:form 是解析好的请求体。search 答检索,fetch 答按 id 取(id、要的那一档)。
func petitParityFake(search func(host string, form neturl.Values) parityReply, fetch func(host, id, lyricsType string) parityReply) func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		form, _ := neturl.ParseQuery(r.body)
		if id := form.Get("key_lyricsId"); id != "" {
			return fetch(r.Host, id, form.Get("lyricsType"))
		}
		return search(r.Host, form)
	}
}

func petitParityNoFetch(_, id, _ string) parityReply {
	return parityReply{status: 597, body: "unexpected fetch of " + id}
}

func TestPetitProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "Ayumu Imazu", "結び", "結び"
	const isrc = "JPPO02604160"
	official := petitTestSongISRC(isrc, "1", "結び", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync)
	hit := petitParityFake(func(string, neturl.Values) parityReply { return parityOK(petitTestResponse(official)) }, petitParityNoFetch)
	plain := func(text string) string { return base64.StdEncoding.EncodeToString([]byte(text)) }
	lineSyncFake := func(text string) func(parityRequest) parityReply {
		return petitParityFake(func(string, neturl.Values) parityReply {
			return parityOK(petitTestResponse(
				petitTestSong("21", "GOD_i", "Number_i", "GOD_i", 215000, "1", "1", ""),
				petitTestSong("22", "GOD_i", "Number_i", "GOD_i", 215000, "2", "1", ""),
			))
		}, func(_, id, lyricsType string) parityReply {
			if lyricsType == petitTypePlain {
				return parityOK(petitTestResponse(petitTestSong(id, "GOD_i", "Number_i", "GOD_i", 215000, "1", "1", plain(text))))
			}
			return parityOK(petitTestResponse(petitTestSong(id, "GOD_i", "Number_i", "GOD_i", 215000, "2", "1",
				petitTestLineSync([]int{135, 545, 787, 1084}, 0xa4ce, true, 64))))
		})
	}
	origArtist, origTitle, origAlbum := "米津玄師", "烏 - Raven", "烏 - Raven - Single"
	queryArtist, queryTitle, queryAlbum := searchQueryFields(origArtist, origTitle, origAlbum)
	if queryTitle == origTitle {
		t.Fatalf("前提:这首的检索词会被归一成另一种写法,得到 %q", queryTitle)
	}
	cases := []providerParityCase{
		{
			name: "带歌手的那条就命中:官方逐字,封面按 ISRC 借 Deezer 的", artist: artist, title: title, album: album, durationSecs: 207,
			alsoEnable: []string{lyricSourceDeezer},
			prepare: func(t *testing.T) {
				withPetitCoverFake(t, map[string]deezerTrack{isrc: petitDzTrack("Ayumu Imazu", "musubi", 207)})
			},
			handle: hit, wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if r.yrc == "" || r.isrc != isrc || r.matchTitle != "結び" || r.matchArtist != "Ayumu Imazu" || r.matchAlbum != "結び" || r.srcDur != 206.998 ||
					r.matchCover != "https://cdn-images.dzcdn.net/images/cover/aa/1800x1800-000000-80-0-0.jpg" || r.plainOnly {
					t.Errorf("逐字、ISRC、歌名、歌手、专辑、时长、封面都该带上:%+v", r)
				}
				if !strings.Contains(o.requests[0], "clientAppId=p1110417") || !strings.Contains(o.requests[0], "key_duration=207000") {
					t.Errorf("请求体该带客户端编号和毫秒时长:%v", o.requests)
				}
			},
		},
		{
			name: "官方那份没带正文:按 id 取逐字", artist: "Mrs. GREEN APPLE", title: "ライラック", album: "ライラック - Single", durationSecs: 288,
			handle: petitParityFake(func(string, neturl.Values) parityReply {
				user := petitTestWSY(petitChars(3000, 200, "別の"), petitChars(6000, 200, "時間軸"), petitChars(9000, 200, "です"))
				return parityOK(petitTestResponse(
					petitTestSong("1", "ライラック", "Mrs. GREEN APPLE", "ライラック", 288100, "3", "0", user),
					petitTestSong("2", "ライラック", "Mrs. GREEN APPLE", "ライラック", 288100, "3", "1", ""),
					petitTestSong("3", "ライラック", "BLANKEY JET CITY", "ライラック", 290000, "3", "1", ""),
				))
			}, func(_, id, _ string) parityReply {
				return parityOK(petitTestResponse(petitTestSong("2", "ライラック", "Mrs. GREEN APPLE", "ライラック", 288100, "3", "1", petitTestSync)))
			}),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(o.result.lyr, "過ぎてゆくんだ") || o.result.yrc == "" {
					t.Errorf("应选官方那份逐字:%+v", o.result)
				}
			},
		},
		{
			name: "带歌手的一条都没有,只按歌名的命中;官方那份三组客户端都取不到,退到下一名、不进缓存", artist: "米津玄師", title: "Lemon", album: "Lemon", durationSecs: 255,
			handle: petitParityFake(func(_ string, form neturl.Values) parityReply {
				if form.Get("key_artist") != "" {
					return parityOK(petitTestResponse())
				}
				return parityOK(petitTestResponse(
					petitTestSong("4", "Lemon", "米津玄師", "Lemon", 255000, "3", "0", petitTestSync),
					petitTestSong("5", "Lemon", "米津玄師", "Lemon", 255000, "3", "1", ""),
				))
			}, func(string, string, string) parityReply { return parityStatus(http.StatusBadGateway) }),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc == "" || len(o.cached) != 0 {
					t.Errorf("用下一名的逐字、这一轮不完整不进缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "当前这组客户端编号被作废:换下一组", artist: artist, title: title, album: album, durationSecs: 207,
			handle: petitParityFake(func(host string, _ neturl.Values) parityReply {
				if strings.HasPrefix(host, "p1.") {
					return parityOK(`<response><status>` + petitStatusUnknownClient + `</status></response>`)
				}
				return parityOK(petitTestResponse(official))
			}, petitParityNoFetch),
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.state[len(o.state)-1] != "client=1" {
					t.Errorf("换过去之后停在第二组:%v", o.state)
				}
			},
		},
		{
			name: "哪一条都没搜到", artist: artist, title: title, album: album, durationSecs: 207,
			handle: petitParityFake(func(string, neturl.Values) parityReply { return parityOK(petitTestResponse()) }, petitParityNoFetch), wantRequests: 2,
		},
		{
			name: "应答的状态码不是成功:什么都不给", artist: artist, title: title, album: album, durationSecs: 207,
			handle: petitParityFake(func(string, neturl.Values) parityReply {
				return parityOK(`<response><status>8150f001</status></response>`)
			}, petitParityNoFetch),
			wantRequests: 1,
		},
		{
			name: "只有逐行:时间和纯文本配成 LRC", artist: "Number_i", title: "GOD_i", album: "GOD_i - Single", durationSecs: 215,
			handle: lineSyncFake("一行目\r\n二行目\r\n三行目\r\n四行目"), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.plainOnly || !strings.HasPrefix(o.result.lyr, "[00:01.35]一行目\n[00:05.45]二行目\n") {
					t.Errorf("应配成逐行 LRC:%+v", o.result)
				}
			},
		},
		{
			name: "逐行的行数配不上:交纯文本,标 plainOnly", artist: "Number_i", title: "GOD_i", album: "GOD_i - Single", durationSecs: 215,
			handle: lineSyncFake("一行目\r\n二行目"), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || o.result.lyr != "一行目\n二行目" {
					t.Errorf("应退成纯文本:%+v", o.result)
				}
			},
		},
		{
			name: "检索词被归一过:按播放器原样的写法搜",
			ctx: func(ctx context.Context) context.Context {
				return withSearchQueryOriginal(ctx, origArtist, origTitle, origAlbum)
			},
			artist: queryArtist, title: queryTitle, album: queryAlbum, durationSecs: 248.5,
			handle: petitParityFake(func(_ string, form neturl.Values) parityReply {
				if form.Get("key_title") != origTitle {
					return parityOK(petitTestResponse())
				}
				return parityOK(petitTestResponse(petitTestSong("3", origTitle, origArtist, origTitle, 248494, "3", "0", petitTestSync)))
			}, petitParityNoFetch),
			wantRequests: 1, wantLyrics: true,
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 207,
			handle: hit, wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "Ayumu Imazu|結び|結び|207" {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑和取整的时长:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "結び (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 207,
			handle: petitParityFake(func(string, neturl.Values) parityReply {
				return parityOK(petitTestResponse(petitTestSongISRC(isrc, "1", "結び (#2)", "Ayumu Imazu", "結び", 206998, "3", "1", petitTestSync)))
			}, petitParityNoFetch),
			wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "結び (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "Ayumu Imazu|結び (#2)|") {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			// 它的请求是 POST、不在出站闸认的只读 POST 里(guardReadOnlyPOST),429 不触发后台暂停,也不换客户端。
			name: "吃到 429:什么都不给,不换客户端", artist: artist, title: title, album: album, durationSecs: 207,
			handle: func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }, wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.state[len(o.state)-1] != "client=0" {
					t.Errorf("429 不算这组客户端坏了:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 207)...)
	runProviderParity(t, petitParitySource, cases)
}

func TestPetitProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, petitParitySource, "Ayumu Imazu", "結び", 207)
}

func TestPetitProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, petitParitySource, "Ayumu Imazu", "結び", 207, parityNotFound)
}
