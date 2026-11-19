package main

import (
	"context"
	"net/http"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// handwrittenKuwoSourceResult:迁移前 enrich.go 里的 kuwoSourceResult,逐字段留着当参照(不跟 kuwo.go 里那份共用)。
func handwrittenKuwoSourceResult(r kuwoResult) lyricSourceResult {
	return lyricSourceResult{
		source: "kuwo", lyr: r.lyrics, yrc: r.yrc,
		matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover,
		srcDur: r.durationSecs, identityFromLocalClient: r.fromLocalClient,
	}
}

// kuwoParitySource:酷我的对拍。三档跳过同酷狗(熔断冷却时仍读客户端落盘的那份歌词),参照路径是迁移前那个 goroutine 的
// 整段。本机歌词目录默认指到不存在的路径,要本机那份的场景在 prepare 里换。
var kuwoParitySource = providerParitySource{
	name: lyricSourceKuwo,
	handwrittenRound: func(ctx context.Context, artist, srcTitle, album string, durationSecs float64, only map[string]bool, breakerPlan lyricSourceRoundPlan, round *lyricSourceRound) lyricSourceResult {
		if only != nil && !only["kuwo"] {
			return lyricSourceResult{source: "kuwo"}
		}
		switch lyricSourceSkipFor("kuwo", lyricSourceEnabled, breakerPlan) {
		case lyricSourceSkipDisabled:
			return lyricSourceResult{source: "kuwo"}
		case lyricSourceSkipCooling:
			if r, ok := kuwoLocalLyric(artist, srcTitle, durationSecs); ok {
				return handwrittenKuwoSourceResult(r)
			}
			round.markSkippedBecause("kuwo", sharedLyricSourceBreaker().cooldownReason("kuwo"))
			return lyricSourceResult{source: "kuwo"}
		}
		return handwrittenKuwoSourceResult(kuwoLyric(ctx, artist, srcTitle, album, durationSecs))
	},
	reset: func(t *testing.T) {
		kuwoMu.Lock()
		saved := kuwoCache
		kuwoCache = map[string]kuwoResult{}
		kuwoMu.Unlock()
		t.Cleanup(func() {
			kuwoMu.Lock()
			kuwoCache = saved
			kuwoMu.Unlock()
		})
		resetKuwoLocalIndex(t, filepath.Join(t.TempDir(), "no-kuwo-client"))
	},
	cacheKeys: func() []string {
		kuwoMu.Lock()
		defer kuwoMu.Unlock()
		var keys []string
		for k := range kuwoCache {
			keys = append(keys, k)
		}
		return keys
	},
	state:   func() []string { return parityEndpointHealth(lyricSourceKuwo) },
	headers: []string{"Referer", "User-Agent"},
}

// kwParityFake 按接口分发酷我的请求;没给的接口回 404。
type kwParityFake struct {
	// search:四个搜索端点同一套参数(r.target 是哪一个)。
	search func(r parityRequest) parityReply
	// lyric:网页端 getlyric(三个主机);mobi:mlyric 的 mobi.s,lrcx 是 "1"(逐字)或 "0"(逐行)。
	lyric func(r parityRequest, musicID string) parityReply
	mobi  func(r parityRequest, musicID, lrcx string) parityReply
}

func (f kwParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		switch {
		case slices.Contains(kuwoSearchEndpoints, r.target) && f.search != nil:
			return f.search(r)
		case strings.HasSuffix(r.URL.Path, "/openapi/v1/www/lyric/getlyric") && f.lyric != nil:
			return f.lyric(r, r.URL.Query().Get("musicId"))
		case r.URL.Path == "/mobi.s" && f.mobi != nil:
			return f.mobi(r, r.URL.Query().Get("rid"), r.URL.Query().Get("lrcx"))
		}
		return parityStatus(http.StatusNotFound)
	}
}

const kwParityCover = "https://img1.kuwo.cn/star/albumcover/0/38/70/3416909732.jpg"

// kwParityItem:搜索结果里的一条。
func kwParityItem(rid, name, artist, album string, secs int) string {
	return `{"MUSICRID":"MUSIC_` + rid + `","SONGNAME":"` + name + `","ARTIST":"` + artist + `","ALBUM":"` + album + `","DURATION":"` + strconv.Itoa(secs) +
		`","web_albumpic_short":"120/38/70/3416909732.jpg"}`
}

func kwParitySearch(items ...string) parityReply {
	return parityOK(`{"abslist":[` + strings.Join(items, ",") + `]}`)
}

// kwParityLyric:getlyric 的应答,每句隔 lastSecs/5 秒、末句落在 lastSecs;mark 写进每一句好认是哪一条的词。
func kwParityLyric(mark string, lastSecs int) parityReply {
	var lines []string
	for i := 1; i <= 5; i++ {
		lines = append(lines, `{"time":"`+strconv.Itoa(lastSecs*i/5)+`.5","lineLyric":"`+mark+`第`+strconv.Itoa(i)+`句"}`)
	}
	return parityOK(`{"code":200,"data":{"lrclist":[` + strings.Join(lines, ",") + `]}}`)
}

const kwParityLrcx = "[kuwo:071]\n[ti:雨眠]\n" +
	"[00:42.500]<1183,-1183>第<2231,-541>一\n[01:24.500]<1183,-1183>第<2231,-541>二\n[02:06.500]<1183,-1183>第<2231,-541>三\n"

// kwParityLocalText:客户端落盘的那份逐字歌词。
const kwParityLocalText = "[kuwo:071]\n[ver:v1.0]\n[ti:雨眠]\n[ar:五月天]\n[al:177031]\n[offset:0]\n" +
	"[00:12.500]<1183,-1183>本<2231,-541>机\n[00:20.000]<1183,-1183>那<2231,-541>份\n[00:30.000]<1183,-1183>最<2231,-541>后\n"

// kwParityLocal:把客户端的歌词目录指到一个放着这几份 .lrcx 的临时目录(文件名 → 正文)。
func kwParityLocal(files map[string]string) func(t *testing.T) {
	return func(t *testing.T) {
		dir := t.TempDir()
		resetKuwoLocalIndex(t, dir)
		for name, text := range files {
			writeTestKuwoLrcx(t, dir, name, text, time.Time{})
		}
	}
}

func TestKuwoProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "五月天", "雨眠", "爱情万岁"
	lrcx := string(kuwoEncodeLrcxForTest(t, kwParityLrcx))
	mobiLRC := kuwoFakeMobiBody(t, "[ti:雨眠]\n[00:42.50]兜底第一句\n[01:24.50]兜底第二句\n[02:06.50]兜底第三句\n[03:30.50]兜底第四句")
	item := kwParityItem("214900", "雨眠", "五月天", "爱情万岁", 222)
	hit := kwParityFake{
		search: func(parityRequest) parityReply { return kwParitySearch(item) },
		lyric:  func(parityRequest, string) parityReply { return kwParityLyric("", 210) },
		mobi: func(_ parityRequest, _, kind string) parityReply {
			if kind == "1" {
				return parityOK(lrcx)
			}
			return parityStatus(http.StatusNotFound)
		},
	}
	with := func(edit func(*kwParityFake)) func(parityRequest) parityReply {
		f := hit
		edit(&f)
		return f.handler()
	}
	twoItems := func(parityRequest) parityReply {
		return kwParitySearch(item, kwParityItem("214901", "雨眠", "五月天", "别的专辑", 222))
	}
	local := kwParityLocal(map[string]string{"五月天 - 雨眠 - 214900.lrcx": kwParityLocalText})
	localThenSearchedCache := func(t *testing.T) {
		local(t)
		kuwoMu.Lock()
		kuwoCache[artist+"|"+title+"|"+album] = kuwoResult{lyrics: "[00:01.00]搜来的那份\n[00:02.00]第二句\n[00:03.00]第三句", title: title, artist: artist}
		kuwoMu.Unlock()
	}
	onlyKuwo := func(ctx context.Context) context.Context { return withLyricSourceOnly(ctx, []string{lyricSourceKuwo}) }
	onlyOther := func(ctx context.Context) context.Context {
		return withLyricSourceOnly(ctx, []string{"provider-test-other"})
	}
	wantLocal := func(identity bool) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			r := o.result
			if !strings.Contains(r.lyr, "本机") || r.yrc == "" || r.identityFromLocalClient != identity {
				t.Errorf("应是本机那份、本机身份=%v:%+v", identity, r)
			}
		}
	}
	wantMark := func(mark string) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			if !strings.Contains(o.result.lyr, mark+"第1句") {
				t.Errorf("应采纳「%s」那一条的词:%+v", mark, o.result)
			}
		}
	}
	cases := []providerParityCase{
		{
			name: "搜索命中:取词、逐字、封面都带", artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !strings.Contains(r.lyr, "第1句") || r.yrc == "" || r.matchTitle != "雨眠" || r.matchArtist != "五月天" || r.matchAlbum != "爱情万岁" ||
					r.matchCover != kwParityCover || r.srcDur != 222 || r.identityFromLocalClient {
					t.Errorf("正文、逐字、歌名、歌手、专辑、封面、时长都该带上,不算本机身份:%+v", r)
				}
				if len(o.cached) != 1 || o.cached[0] != "五月天|雨眠|爱情万岁" {
					t.Errorf("进程内缓存的键应是歌手、歌名、专辑:%v", o.cached)
				}
			},
		},
		{
			name: "两条候选并发取词:按名次采纳第一名", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = twoItems
				f.lyric = func(_ parityRequest, id string) parityReply { return kwParityLyric(id, 210) }
			}),
			wantRequests: 4, wantLyrics: true, check: wantMark("214900"),
		},
		{
			name: "第一名没有词(空列表):采纳第二名", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = twoItems
				f.lyric = func(_ parityRequest, id string) parityReply {
					if id == "214900" {
						return parityOK(`{"code":200,"data":{"lrclist":[]}}`)
					}
					return kwParityLyric(id, 210)
				}
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				wantMark("214901")(t, o)
				if o.result.matchAlbum != "别的专辑" {
					t.Errorf("身份应是第二名那一条:%+v", o.result)
				}
			},
		},
		{
			name: "第一名的词末句对不上曲长(截断):采纳对得上的第二名", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = twoItems
				f.lyric = func(_ parityRequest, id string) parityReply {
					if id == "214900" {
						return kwParityLyric(id, 60)
					}
					return kwParityLyric(id, 210)
				}
			}),
			wantRequests: 4, wantLyrics: true, check: wantMark("214901"),
		},
		{
			name: "第一名取词没问成、用了第二名:不进缓存", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = twoItems
				f.lyric = func(_ parityRequest, id string) parityReply {
					if id == "214900" {
						return parityStatus(http.StatusNotFound)
					}
					return kwParityLyric(id, 210)
				}
			}),
			wantRequests: 8, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				wantMark("214901")(t, o)
				if len(o.cached) != 0 {
					t.Errorf("名次更靠前的那条没问成,这一份不该进缓存:%v", o.cached)
				}
			},
		},
		{
			name: "search.kuwo.cn 两种协议都没问成:换 kuwo.cn 上的搜索端点", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = func(r parityRequest) parityReply {
					if strings.Contains(r.target, "search.kuwo.cn") {
						return parityStatus(http.StatusInternalServerError)
					}
					return kwParitySearch(item)
				}
			}),
			wantRequests: 5, wantLyrics: true,
		},
		{
			name: "网页端取词三个主机都没问成:mlyric 的逐行那一档兜底", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.lyric = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				f.mobi = func(_ parityRequest, _, kind string) parityReply {
					if kind == "1" {
						return parityOK(lrcx)
					}
					return parityOK(mobiLRC)
				}
			}),
			wantRequests: 6, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(o.result.lyr, "兜底第一句") {
					t.Errorf("整行应来自 mlyric 的逐行那一档:%+v", o.result)
				}
			},
		},
		{
			name: "网页端取词回拒绝码(code 不是 200):记拒绝,mlyric 兜底", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.lyric = func(parityRequest, string) parityReply {
					return parityOK(`{"code":-1,"msg":"参数错误","success":false}`)
				}
				f.mobi = func(_ parityRequest, _, kind string) parityReply {
					if kind == "1" {
						return parityOK(lrcx)
					}
					return parityOK(mobiLRC)
				}
			}),
			wantRequests: 6, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "rejects=1") {
					t.Errorf("被拒的取词端点应记一次拒绝:%v", o.state)
				}
			},
		},
		{
			name: "逐字接口两个主机都没问成:整行照交,不进缓存", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.mobi = func(parityRequest, string, string) parityReply { return parityStatus(http.StatusBadGateway) }
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc != "" || len(o.cached) != 0 {
					t.Errorf("缺了逐字的这一份不该进缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "一条都没搜到", artist: artist, title: title, album: album, durationSecs: 222,
			handle:       with(func(f *kwParityFake) { f.search = func(parityRequest) parityReply { return kwParitySearch() } }),
			wantRequests: 1,
		},
		{
			name: "搜到的歌手、时长都对不上:不取词", artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = func(parityRequest) parityReply {
					return kwParitySearch(kwParityItem("1", "雨眠", "别的歌手", "x", 222), kwParityItem("2", "雨眠", "五月天", "x", 60))
				}
			}),
			wantRequests: 1,
		},
		{
			name: "本机歌词精确命中:不取词,只为封面搜一次,带本机身份", prepare: local, artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				wantLocal(true)(t, o)
				if o.result.matchCover != kwParityCover || o.result.matchAlbum != "" || o.result.srcDur != 0 {
					t.Errorf("封面按本机那份的曲目 id 在搜索结果里认,专辑、时长不报:%+v", o.result)
				}
			},
		},
		{
			name:    "本机歌词宽松命中(歌名多一段副标题):不算本机身份",
			prepare: kwParityLocal(map[string]string{"五月天 - 雨眠 (电视剧《某某》片尾曲) - 214900.lrcx": kwParityLocalText}),
			artist:  artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true, check: wantLocal(false),
		},
		{
			name: "别的歌那一轮:本机歌词命中也不算本机身份", prepare: local, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true, check: wantLocal(false),
		},
		{
			name: "在放的这首、进程内缓存里是搜来的那份:先问本机歌词", prepare: localThenSearchedCache,
			artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true, check: wantLocal(true),
		},
		{
			name: "别的歌那一轮、进程内缓存里是搜来的那份:照用缓存", prepare: localThenSearchedCache, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(o.result.lyr, "搜来的那份") {
					t.Errorf("应照用缓存里搜来的那份:%+v", o.result)
				}
			},
		},
		{
			name: "熔断冷却、本机歌词命中:不发请求、不记跳过,封面不补", prepare: local, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				wantLocal(true)(t, o)
				if o.result.matchCover != "" || len(o.cached) != 0 {
					t.Errorf("冷却时只读本机那份:不补封面、不进进程内缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "熔断冷却、别名轮名单里有它、本机歌词命中", prepare: local, cooling: true, ctx: onlyKuwo,
			artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true, check: wantLocal(true),
		},
		{
			name:    "熔断冷却、本机歌词里只有别的歌:记跳过",
			prepare: kwParityLocal(map[string]string{"五月天 - 别的歌 - 1.lrcx": kwParityLocalText}),
			cooling: true, artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 0, wantSkips: true,
		},
		{
			name: "熔断冷却、本机那份比歌还长(另一个版本):不用它,记跳过", prepare: local, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 20,
			handle: hit.handler(), wantRequests: 0, wantSkips: true,
		},
		{
			name: "设置里关掉:本机歌词有也不读", prepare: local, disabled: true,
			artist: artist, title: title, album: album, durationSecs: 222, handle: hit.handler(),
		},
		{
			name: "设置里关掉、又在熔断冷却:本机歌词有也不读、不记跳过", prepare: local, disabled: true, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 222, handle: hit.handler(),
		},
		{
			name: "别名轮名单外:本机歌词有也不读", prepare: local, ctx: onlyOther,
			artist: artist, title: title, album: album, durationSecs: 222, handle: hit.handler(),
		},
		{
			name: "别名轮名单外、又在熔断冷却:本机歌词有也不读、不记跳过", prepare: local, cooling: true, ctx: onlyOther,
			artist: artist, title: title, album: album, durationSecs: 222, handle: hit.handler(),
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
		},
		{
			name: "歌名带编号:挑候选、记缓存都按带编号的那份",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "雨眠 (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = func(parityRequest) parityReply {
					return kwParitySearch(kwParityItem("214900", "雨眠 (#2)", "五月天", "爱情万岁", 222))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "雨眠 (#2)" || len(o.cached) != 1 || o.cached[0] != "五月天|雨眠 (#2)|爱情万岁" {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "歌名带编号、熔断冷却:本机歌词按带编号的歌名认",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "雨眠 (#2)", artist, title, album)
			},
			prepare: kwParityLocal(map[string]string{
				"五月天 - 雨眠 (#2) - 214902.lrcx": kwParityLocalText,
				"五月天 - 雨眠 - 214900.lrcx":      strings.Replace(kwParityLocalText, "本", "错", 1),
			}),
			cooling: true, artist: artist, title: title, album: album, durationSecs: 222,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "雨眠 (#2)" || !strings.Contains(o.result.lyr, "本机") {
					t.Errorf("应读到带编号的那一份:%+v", o.result)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停,同一主机后面那个端点被闸拦下、这一轮记成跳过", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 222,
			handle: with(func(f *kwParityFake) {
				f.search = func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }
			}),
			wantRequests: 3, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused search.kuwo.cn") || o.skips[lyricSourceKuwo] != "paused" {
					t.Errorf("后台档 429 后后台请求应暂停、跳过原因是 paused:%v %v", o.state, o.skips)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 222)...)
	runProviderParity(t, kuwoParitySource, cases)
}

func TestKuwoProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, kuwoParitySource, "五月天", "雨眠", 222)
}

func TestKuwoProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, kuwoParitySource, "五月天", "雨眠", 222, parityNotFound)
}
