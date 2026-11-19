package main

import (
	"context"
	"encoding/base64"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// handwrittenKugouSourceResult:迁移前 enrich.go 里的 kugouSourceResult,逐字段留着当参照(不跟 kugou.go 里那份共用,
// 那份少摊一个字段对拍才看得出来)。
func handwrittenKugouSourceResult(r kugouResult) lyricSourceResult {
	return lyricSourceResult{
		source: "kugou", lyr: r.lrc, yrc: r.yrc, tr: r.tr, roma: r.roma,
		matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover,
		srcDur: r.durationSecs, language: r.language, noVocals: r.noVocals,
		identityFromLocalClient: r.fromLocalClient,
	}
}

// kugouParitySource:酷狗的对拍。它自己判三档跳过(名单外、关掉都不问;熔断冷却时仍读客户端下在本机的那份 KRC),
// 参照路径是迁移前那个 goroutine 的整段。本机缓存目录默认指到不存在的路径,要本机那份的场景在 prepare 里换。
var kugouParitySource = providerParitySource{
	name: lyricSourceKugou,
	handwrittenRound: func(ctx context.Context, artist, srcTitle, album string, durationSecs float64, only map[string]bool, breakerPlan lyricSourceRoundPlan, round *lyricSourceRound) lyricSourceResult {
		if only != nil && !only["kugou"] {
			return lyricSourceResult{source: "kugou"}
		}
		switch lyricSourceSkipFor("kugou", lyricSourceEnabled, breakerPlan) {
		case lyricSourceSkipDisabled:
			return lyricSourceResult{source: "kugou"}
		case lyricSourceSkipCooling:
			if r, ok := kugouLocalLyric(artist, srcTitle, album, durationSecs); ok {
				return handwrittenKugouSourceResult(r)
			}
			round.markSkippedBecause("kugou", sharedLyricSourceBreaker().cooldownReason("kugou"))
			return lyricSourceResult{source: "kugou"}
		}
		return handwrittenKugouSourceResult(kugouLyric(ctx, artist, srcTitle, album, durationSecs))
	},
	reset: func(t *testing.T) {
		kugouMu.Lock()
		saved := kugouCache
		kugouCache = map[string]kugouResult{}
		kugouMu.Unlock()
		t.Cleanup(func() {
			kugouMu.Lock()
			kugouCache = saved
			kugouMu.Unlock()
		})
		resetKugouLocalIndex(t, filepath.Join(t.TempDir(), "no-kugou-client"))
	},
	cacheKeys: func() []string {
		kugouMu.Lock()
		defer kugouMu.Unlock()
		var keys []string
		for k := range kugouCache {
			keys = append(keys, k)
		}
		return keys
	},
	state:   func() []string { return parityEndpointHealth(lyricSourceKugou) },
	headers: []string{"User-Agent"},
}

// kgParityFake 按接口分发酷狗的请求;没给的接口回 404。
type kgParityFake struct {
	// search:/api/v3/search/song(三台主机同一个路径,r.target 里有主机);songsearch:另一套搜索后端。
	search, songsearch func(r parityRequest) parityReply
	// lyricSearch:歌词库的 /search(krcs、lyrics 两台),带 hash 和不带 hash 的都走它。
	lyricSearch func(r parityRequest) parityReply
	// download:歌词库的 /download,format 是 krc 或 lrc。
	download func(r parityRequest, format string) parityReply
	album    func(r parityRequest) parityReply
}

func (f kgParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		var h func(parityRequest) parityReply
		switch {
		case r.URL.Path == "/api/v3/search/song":
			h = f.search
		case r.target == kugouSongSearchEndpoint:
			h = f.songsearch
		case r.URL.Path == "/search":
			h = f.lyricSearch
		case r.URL.Path == "/download" && f.download != nil:
			return f.download(r, r.URL.Query().Get("fmt"))
		case r.URL.Path == "/api/v3/album/info":
			h = f.album
		}
		if h == nil {
			return parityStatus(http.StatusNotFound)
		}
		return h(r)
	}
}

const (
	kgParityCoverTemplate = "http://imge.kugou.com/stdmusic/{size}/20150718/20150718135406912233.jpg"
	kgParityCover         = "https://imge.kugou.com/stdmusic/0/20150718/20150718135406912233.jpg"
	kgParityHashHit       = `{"status":200,"candidates":[{"id":"1","accesskey":"k","song":"浮夸","singer":"陈奕迅","duration":283000}]}`
	// kgParityLocalKRC:客户端下在本机的那份,标签跟播放器报的歌手、歌名逐字相同(精确命中)。
	kgParityLocalKRC = "[ar:陈奕迅]\n[ti:浮夸]\n[al:U87]\n[hash:abc]\n[total:0]\n[offset:0]\n" +
		"[1000,1000]<0,500,0>本<500,500,0>机\n[2000,1000]<0,500,0>那<500,500,0>份\n[30000,1000]<0,500,0>最<500,500,0>后"
)

// kgParitySong:搜索结果里的一条。cover 为空时不带封面模板(要按专辑 ID 另问)。
func kgParitySong(hash, name, album string, secs int, language, cover string) string {
	trans := `{"language":"` + language + `"`
	if cover != "" {
		trans += `,"union_cover":"` + cover + `"`
	}
	return `{"hash":"` + hash + `","songname":"` + name + `","singername":"陈奕迅","album_name":"` + album + `","album_id":"968210","duration":` +
		strconv.Itoa(secs) + `,"trans_param":` + trans + `}}`
}

func kgParitySearch(songs ...string) parityReply {
	return parityOK(`{"status":1,"errcode":0,"data":{"info":[` + strings.Join(songs, ",") + `]}}`)
}

// kgParityLocal:把客户端的本机缓存目录指到一个放着这几份 KRC 的临时目录。
func kgParityLocal(files map[string]string) func(t *testing.T) {
	return func(t *testing.T) {
		dir := t.TempDir()
		for name, body := range files {
			writeTestKRC(t, dir, name, body)
		}
		resetKugouLocalIndex(t, dir)
	}
}

func TestKugouProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "陈奕迅", "浮夸", "U87"
	krcWithTracks := kgTestKRC + "\n[language:" + krcLanguageB64(t, []map[string]any{
		{"type": 1, "language": 0, "lyricContent": [][]string{{"译一"}, {"译二"}, {"译三"}, {"译四"}}},
		{"type": 0, "language": 0, "lyricContent": [][]string{{"di ", "yi"}, {"di ", "er"}, {"di ", "san"}, {"di ", "si"}}},
	}) + "]"
	krcBody := `{"status":200,"content":"` + kgTestKRCContent(t, krcWithTracks) + `"}`
	lrcBody := `{"status":200,"content":"` + base64.StdEncoding.EncodeToString([]byte("[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句\n[00:04.00]第四句\n")) + `"}`
	song := kgParitySong("abc", "浮夸", "U87", 283, "粤语", kgParityCoverTemplate)
	hit := kgParityFake{
		search:      func(parityRequest) parityReply { return kgParitySearch(song) },
		lyricSearch: func(parityRequest) parityReply { return parityOK(kgParityHashHit) },
		download: func(_ parityRequest, format string) parityReply {
			if format == "krc" {
				return parityOK(krcBody)
			}
			return parityStatus(http.StatusNotFound)
		},
	}
	with := func(edit func(*kgParityFake)) func(parityRequest) parityReply {
		f := hit
		edit(&f)
		return f.handler()
	}
	local := kgParityLocal(map[string]string{"local.krc": kgParityLocalKRC})
	localThenSearchedCache := func(t *testing.T) {
		local(t)
		kugouMu.Lock()
		kugouCache[artist+"|"+title+"|"+album] = kugouResult{lrc: "[00:01.00]搜来的那份\n[00:02.00]第二句\n[00:03.00]第三句", title: title, artist: artist}
		kugouMu.Unlock()
	}
	onlyKugou := func(ctx context.Context) context.Context { return withLyricSourceOnly(ctx, []string{lyricSourceKugou}) }
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
	cases := []providerParityCase{
		{
			name: "搜索命中:按 hash 查歌词库、下 KRC,逐字 / 译文 / 罗马音 / 语种 / 封面都带", artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !strings.Contains(r.lyr, "第一句") || r.yrc == "" || !strings.Contains(r.tr, "译一") || !strings.Contains(r.roma, "di yi") ||
					r.matchTitle != "浮夸" || r.matchArtist != "陈奕迅" || r.matchAlbum != "U87" || r.matchCover != kgParityCover ||
					r.srcDur != 283 || r.language != songLanguageCantonese || r.noVocals || r.identityFromLocalClient {
					t.Errorf("正文、逐字、译文、罗马音、歌名、歌手、专辑、封面、时长、语种都该带上,不算本机身份:%+v", r)
				}
				if len(o.cached) != 1 || o.cached[0] != "陈奕迅|浮夸|U87" {
					t.Errorf("进程内缓存的键应是歌手、歌名、专辑:%v", o.cached)
				}
			},
		},
		{
			name: "搜索结果没带专辑封面:按专辑 ID 问 album/info", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply {
					return kgParitySearch(kgParitySong("abc", "浮夸", "U87", 283, "粤语", ""))
				}
				f.album = func(parityRequest) parityReply {
					return parityOK(`{"data":{"imgurl":"` + kgParityCoverTemplate + `"}}`)
				}
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchCover != kgParityCover {
					t.Errorf("封面应来自 album/info:%+v", o.result)
				}
			},
		},
		{
			name: "首选搜索主机没问成:换下一台", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(r parityRequest) parityReply {
					if strings.Contains(r.target, "mobilecdn.kugou.com") {
						return parityStatus(http.StatusBadGateway)
					}
					return kgParitySearch(song)
				}
			}),
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "/api/v3 三台都没问成:退到 songsearch", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply { return parityStatus(http.StatusBadGateway) }
				f.songsearch = func(parityRequest) parityReply {
					return parityOK(`{"status":1,"error_code":0,"data":{"lists":[{"FileHash":"ABC","SongName":"浮夸","SingerName":"陈奕迅","AlbumName":"U87","AlbumID":"968210","Duration":283,"trans_param":{"language":"粤语","union_cover":"` + kgParityCoverTemplate + `"}}]}}`)
				}
			}),
			wantRequests: 6, wantLyrics: true,
		},
		{
			name: "搜索被拒(errcode 不是 0):退到 songsearch", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply { return parityOK(`{"status":0,"errcode":20028,"data":{"info":[]}}`) }
				f.songsearch = func(parityRequest) parityReply {
					return parityOK(`{"status":1,"error_code":0,"data":{"lists":[{"FileHash":"ABC","SongName":"浮夸","SingerName":"陈奕迅","AlbumName":"U87","AlbumID":"968210","Duration":283,"trans_param":{"language":"粤语","union_cover":"` + kgParityCoverTemplate + `"}}]}}`)
				}
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "rejects=1") {
					t.Errorf("被拒的搜索端点应记一次拒绝:%v", o.state)
				}
			},
		},
		{
			name: "KRC 解不开:退到 fmt=lrc,只有整行", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.download = func(_ parityRequest, format string) parityReply {
					if format == "krc" {
						return parityOK(`{"status":200,"content":"bm90IGEga3Jj"}`)
					}
					return parityOK(lrcBody)
				}
			}),
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc != "" || !strings.Contains(o.result.lyr, "[00:01.00]第一句") {
					t.Errorf("应只有 fmt=lrc 的整行:%+v", o.result)
				}
			},
		},
		{
			name: "逐字那一趟没问成:整行照交,不进缓存", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.download = func(_ parityRequest, format string) parityReply {
					if format == "krc" {
						return parityStatus(http.StatusBadGateway)
					}
					return parityOK(lrcBody)
				}
			}),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 0 {
					t.Errorf("缺了逐字的这一份不该进缓存:%v", o.cached)
				}
			},
		},
		{
			name: "按 hash 查不到候选:不带 hash 再查一次", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.lyricSearch = func(r parityRequest) parityReply {
					if r.URL.Query().Get("hash") != "" {
						return parityOK(`{"status":200,"candidates":[]}`)
					}
					return parityOK(`{"status":200,"candidates":[{"id":"9","accesskey":"k","song":"浮夸","singer":"陈奕迅","duration":283000}]}`)
				}
			}),
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "搜歌挑不出、歌词库按关键词也没有", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply {
					return kgParitySearch(kgParitySong("x", "别的歌", "别的专辑", 200, "国语", ""))
				}
				f.lyricSearch = func(parityRequest) parityReply { return parityOK(`{"status":200,"candidates":[]}`) }
			}),
			wantRequests: 2,
		},
		{
			name: "挑中的那一行标着纯音乐:交无人声标记", artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply {
					return kgParitySearch(kgParitySong("abc", "浮夸", "U87", 283, kugouLanguagePureMusic, kgParityCoverTemplate))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.noVocals {
					t.Errorf("应带 noVocals:%+v", o.result)
				}
			},
		},
		{
			name: "本机缓存精确命中:不搜歌词,只为封面搜一次,带本机身份", prepare: local, artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				wantLocal(true)(t, o)
				if o.result.matchCover != kgParityCover || o.result.matchAlbum != "U87" || o.result.srcDur != 0 {
					t.Errorf("封面按本机那份的 hash 在搜索结果里认,时长不报:%+v", o.result)
				}
			},
		},
		{
			name: "本机缓存宽松命中(歌名多一段副标题):不算本机身份",
			prepare: kgParityLocal(map[string]string{
				"loose.krc": strings.Replace(kgParityLocalKRC, "[ti:浮夸]", "[ti:浮夸 (电影《某某》主题曲)]", 1),
			}),
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true, check: wantLocal(false),
		},
		{
			name: "别的歌那一轮:本机缓存命中也不算本机身份", prepare: local, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true, check: wantLocal(false),
		},
		{
			name: "在放的这首、进程内缓存里是搜来的那份:先问本机缓存", prepare: localThenSearchedCache,
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true, check: wantLocal(true),
		},
		{
			name: "别的歌那一轮、进程内缓存里是搜来的那份:照用缓存", prepare: localThenSearchedCache, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(o.result.lyr, "搜来的那份") {
					t.Errorf("应照用缓存里搜来的那份:%+v", o.result)
				}
			},
		},
		{
			name: "熔断冷却、本机缓存命中:不发请求、不记跳过,封面不补", prepare: local, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				wantLocal(true)(t, o)
				if o.result.matchCover != "" || len(o.cached) != 0 {
					t.Errorf("冷却时只读本机那份:不补封面、不进进程内缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "熔断冷却、别名轮名单里有它、本机缓存命中", prepare: local, cooling: true, ctx: onlyKugou,
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true, check: wantLocal(true),
		},
		{
			name: "熔断冷却、本机缓存里同一首有两个专辑的版本:按专辑挑",
			prepare: kgParityLocal(map[string]string{
				"a-other.krc": strings.Replace(strings.Replace(kgParityLocalKRC, "[al:U87]", "[al:别的专辑]", 1), "本", "错", 1),
				"b-u87.krc":   kgParityLocalKRC,
			}),
			cooling: true, artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchAlbum != "U87" || !strings.Contains(o.result.lyr, "本机") {
					t.Errorf("应挑专辑对得上的那一份:%+v", o.result)
				}
			},
		},
		{
			name: "熔断冷却、本机缓存里只有别的歌:记跳过",
			prepare: kgParityLocal(map[string]string{
				"other.krc": strings.Replace(kgParityLocalKRC, "[ti:浮夸]", "[ti:别的歌]", 1),
			}),
			cooling: true, artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 0, wantSkips: true,
		},
		{
			name: "熔断冷却、本机那份比歌还长(另一个版本):不用它,记跳过", prepare: local, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 20,
			handle: hit.handler(), wantRequests: 0, wantSkips: true,
		},
		{
			name: "设置里关掉:本机缓存有也不读", prepare: local, disabled: true,
			artist: artist, title: title, album: album, durationSecs: 283, handle: hit.handler(),
		},
		{
			name: "设置里关掉、又在熔断冷却:本机缓存有也不读、不记跳过", prepare: local, disabled: true, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 283, handle: hit.handler(),
		},
		{
			name: "别名轮名单外:本机缓存有也不读", prepare: local, ctx: onlyOther,
			artist: artist, title: title, album: album, durationSecs: 283, handle: hit.handler(),
		},
		{
			name: "别名轮名单外、又在熔断冷却:本机缓存有也不读、不记跳过", prepare: local, cooling: true, ctx: onlyOther,
			artist: artist, title: title, album: album, durationSecs: 283, handle: hit.handler(),
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 3, wantLyrics: true,
		},
		{
			name: "歌名带编号:拿带编号的那份去搜、去读本机缓存、记缓存",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "浮夸 (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply {
					return kgParitySearch(kgParitySong("abc", "浮夸 (#2)", "U87", 283, "粤语", kgParityCoverTemplate))
				}
				f.lyricSearch = func(parityRequest) parityReply {
					return parityOK(strings.Replace(kgParityHashHit, `"song":"浮夸"`, `"song":"浮夸 (#2)"`, 1))
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "浮夸 (#2)" || len(o.cached) != 1 || o.cached[0] != "陈奕迅|浮夸 (#2)|U87" {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "歌名带编号、熔断冷却:本机缓存按带编号的歌名认",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "浮夸 (#2)", artist, title, album)
			},
			prepare: kgParityLocal(map[string]string{
				"numbered.krc": strings.Replace(kgParityLocalKRC, "[ti:浮夸]", "[ti:浮夸 (#2)]", 1),
				"plain.krc":    strings.Replace(kgParityLocalKRC, "本", "错", 1),
			}),
			cooling: true, artist: artist, title: title, album: album, durationSecs: 283,
			handle: hit.handler(), wantRequests: 0, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "浮夸 (#2)" || !strings.Contains(o.result.lyr, "本机") {
					t.Errorf("应读到带编号的那一份:%+v", o.result)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 283,
			handle: with(func(f *kgParityFake) {
				f.search = func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }
				f.songsearch = func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }
			}),
			wantRequests: 4,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused mobilecdn.kugou.com") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 283)...)
	runProviderParity(t, kugouParitySource, cases)
}

func TestKugouProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, kugouParitySource, "陈奕迅", "浮夸", 283)
}

func TestKugouProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, kugouParitySource, "陈奕迅", "浮夸", 283, parityNotFound)
}
