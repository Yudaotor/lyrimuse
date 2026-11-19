package main

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

var zingParitySource = providerParitySource{
	name: lyricSourceZing,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := zingLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "zing", lyr: r.lyrics, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs}
	},
	reset: resetZingState,
	cacheKeys: func() []string {
		zingMu.Lock()
		defer zingMu.Unlock()
		var keys []string
		for k := range zingCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		zingCookieMu.Lock()
		cookie := zingCookie
		zingCookieMu.Unlock()
		return []string{"cookie=" + cookie, "key=" + strconv.Itoa(int(zingKeyIdx.Load())), "last failure=" + zingLastFailureReasonNow()}
	},
	headers: []string{"Cookie"},
}

const (
	zingParitySearchURL = "https://zingmp3.vn" + zingSearchPath
	zingParityLyricURL  = "https://zingmp3.vn" + zingLyricPath
	zingParityFileURL   = "https://static-zmp3.zmdcdn.me/lyrics/a.lrc"
	zingParityNoLyric   = `{"err":0,"msg":"Success","data":{}}`
)

// zingParityFake:Zing 头两条检索词是并发发的,假服务器让检索请求两个两个地一起到(pairGate)。api 先看每个发给接口的
// 请求(检索和取词),返回非 nil 就拿它当应答(会话、密钥被拒这类);search 答检索,返回 nil 表示挂到这一轮结束
// (parityHang):带歌手的那条有候选或失败时源不再等另一条,另一条的应答到得早晚会改掉源自己的状态,所以一律挂住;
// lyric 答取词(按 id);file 答 LRC 文件。unpairedAfter 非零时只有前这么多个请求配对(之后只剩一路在发)。
type zingParityFake struct {
	api           func(r parityRequest) *parityReply
	search        func(query string) *parityReply
	lyric         func(id string) parityReply
	file          parityReply
	unpairedAfter int
}

func (f zingParityFake) handler() func(parityRequest) parityReply {
	gate := &pairGate{}
	return func(r parityRequest) parityReply {
		if r.target == zingParityFileURL {
			return f.file
		}
		if r.target == zingParitySearchURL && (f.unpairedAfter == 0 || r.nth <= f.unpairedAfter) && !gate.arrive() {
			return pairGateTimedOut
		}
		if f.api != nil {
			if reply := f.api(r); reply != nil {
				return *reply
			}
		}
		switch r.target {
		case zingParitySearchURL:
			if reply := f.search(r.URL.Query().Get("q")); reply != nil {
				return *reply
			}
			return parityHang(r)
		case zingParityLyricURL:
			return f.lyric(r.URL.Query().Get("id"))
		}
		return parityStatus(http.StatusNotFound)
	}
}

func zingParityLyricFor(ids ...string) func(string) parityReply {
	return func(id string) parityReply {
		for _, want := range ids {
			if id == want {
				return parityOK(zingTestLyric(zingParityFileURL))
			}
		}
		return parityOK(zingParityNoLyric)
	}
}

const zingParityWithArtist = "Ai Ngoài Anh VSTRA"

// zingParityHits:带歌手的那条给结果,只按歌名的那条挂住。
func zingParityHits(q string) *parityReply {
	if q != zingParityWithArtist {
		return nil
	}
	return &parityReply{body: zingTestSearch}
}

// zingParityHit:带歌手的那条就有结果,第一名取得到逐行文件和逐字。
var zingParityHit = zingParityFake{search: zingParityHits, lyric: zingParityLyricFor("ZOK1"), file: parityOK(zingTestLRC)}

func TestZingProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title = "VSTRA", "Ai Ngoài Anh"
	const withArtist = zingParityWithArtist
	hit := zingParityHit
	with := func(f zingParityFake, edit func(*zingParityFake)) func(parityRequest) parityReply {
		edit(&f)
		return f.handler()
	}
	failFirst := func(status int) func(string) *parityReply {
		return func(q string) *parityReply {
			if q == withArtist {
				return &parityReply{status: status}
			}
			return nil
		}
	}
	cases := []providerParityCase{
		{
			name: "「歌名 歌手」那条就命中", artist: artist, title: title, durationSecs: 201,
			handle: hit.handler(), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if r.lyr != zingTestLRC || !strings.HasPrefix(r.yrc, "[21840,1160](21840,280,0)Ai ") || r.matchTitle != "Ai Ngoài Anh" || r.matchArtist != "VSTRA, Tyronee" ||
					r.matchAlbum != "Ai Ngoài Anh (Single)" || r.srcDur != 200 || r.matchCover != "https://photo-zmp3.zmdcdn.me/cover/1/2/a.jpg" {
					t.Errorf("逐行、逐字、歌名、歌手、专辑、时长、封面都该带上:%+v", r)
				}
			},
		},
		{
			name: "带歌手的一条都没有,只按歌名的命中", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) {
				f.search = func(q string) *parityReply {
					if q == withArtist {
						return &parityReply{body: zingTestEmptySearch}
					}
					return &parityReply{body: zingTestSearch}
				}
			}),
			wantRequests: 5, wantLyrics: true,
		},
		{
			name: "哪一条都没搜到", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) {
				f.search = func(string) *parityReply { return &parityReply{body: zingTestEmptySearch} }
			}),
			wantRequests: 2,
		},
		{
			name: "搜索没问成", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) { f.search = failFirst(http.StatusBadGateway) }), wantRequests: 2,
		},
		{
			name: "没带会话:收到 -201 和 cookie 后带上重发", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) {
				f.api = func(r parityRequest) *parityReply {
					if c, err := r.Cookie(zingCookieName); err == nil && c.Value == "rq1" {
						return nil
					}
					return &parityReply{body: `{"err":-201,"msg":"Request has been blocked"}`, header: http.Header{"Set-Cookie": {zingCookieName + "=rq1; Path=/"}}}
				}
			}),
			wantRequests: 7, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.state[len(o.state)-3] != "cookie=rq1" {
					t.Errorf("会话 cookie 应记下:%v", o.state)
				}
			},
		},
		{
			name: "第一组密钥被拒:换第二组", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) {
				f.api = func(r parityRequest) *parityReply {
					if r.URL.Query().Get("apiKey") == zingKeys[0].apiKey {
						return &parityReply{body: `{"err":-104,"msg":"Incorect signature"}`}
					}
					return nil
				}
			}),
			wantRequests: 7, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.state[len(o.state)-2] != "key=1" || o.state[len(o.state)-1] != "last failure=" {
					t.Errorf("应换到第二组密钥、不留失败原因:%v", o.state)
				}
			},
		},
		{
			name: "两组密钥都被拒:报签名被拒、整源暂停,下一轮直接跳过", rounds: 2, artist: artist, title: title, durationSecs: 201,
			// 带歌手的那条两组密钥各被拒一次;只按歌名的那条挂在第一次上,不然它也会去撞第二组、动密钥位置和暂停状态。
			handle: with(hit, func(f *zingParityFake) {
				f.unpairedAfter = 2
				f.api = func(r parityRequest) *parityReply {
					if r.URL.Query().Get("q") != withArtist {
						return nil
					}
					return &parityReply{body: `{"err":-116,"msg":"Invalid api key"}`}
				}
				f.search = func(string) *parityReply { return nil }
			}),
			wantRequests: 3,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.state[len(o.state)-1] != "last failure="+lyricFailureReasonZingSignatureRejected || !strings.Contains(o.state[0], `reason="`+lyricSourceCooldownReasonBlocked+`"`) {
					t.Errorf("应记下签名被拒、整源暂停:%v", o.state)
				}
				// 第一轮它正常应答过(应答的内容是拒绝),近况统计那份名单不算它被跳过;跳过名单里有它。
				if o.round[0] != "skipped=[zing]" || len(o.skips) != 0 {
					t.Errorf("第二轮应因整源暂停被跳过:%v %v", o.round, o.skips)
				}
			},
		},
		{
			name: "逐行文件 404:用逐字压出来的整行", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) { f.file = parityStatus(http.StatusNotFound) }), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc == "" || len(o.cached) != 1 {
					t.Errorf("文件没有是答了,逐字照收、照进缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "逐行文件 502:整行照交,不收逐字、不进缓存", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) { f.file = parityStatus(http.StatusBadGateway) }), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc != "" || len(o.cached) != 0 {
					t.Errorf("文件没问成时核不了逐字,这一轮不完整:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "第一名没有词,用第二名", artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) { f.lyric = zingParityLyricFor("ZOK2") }), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchAlbum != "Album" || o.result.srcDur != 199 {
					t.Errorf("应是第二名那份:%+v", o.result)
				}
			},
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: "Ai Ngoài Anh (Single)", durationSecs: 201,
			handle: hit.handler(), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "VSTRA|Ai Ngoài Anh|Ai Ngoài Anh (Single)|201" {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑和取整的时长:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Ai Ngoài Anh (#2)", artist, title, "")
			},
			artist: artist, title: title, durationSecs: 201,
			// 检索词里不带编号(lyricQueryTitle 去掉了),挑候选和缓存的键按带编号的歌名。
			handle: with(hit, func(f *zingParityFake) {
				f.search = func(q string) *parityReply {
					if q != withArtist {
						return nil
					}
					return &parityReply{body: strings.ReplaceAll(zingTestSearch, `"title":"Ai Ngoài Anh",`, `"title":"Ai Ngoài Anh (#2)",`)}
				}
			}),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "Ai Ngoài Anh (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "VSTRA|Ai Ngoài Anh (#2)|") {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, durationSecs: 201,
			handle: with(hit, func(f *zingParityFake) { f.search = failFirst(http.StatusTooManyRequests) }), wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused zingmp3.vn") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 201)...)
	runProviderParity(t, zingParitySource, cases)
}

func TestZingProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, zingParitySource, "VSTRA", "Ai Ngoài Anh", 201)
}

func TestZingProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, zingParitySource, "VSTRA", "Ai Ngoài Anh", 201, zingParityHit.handler())
}
