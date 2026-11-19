package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

var miguParitySource = providerParitySource{
	name: lyricSourceMigu,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := miguLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "migu", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	},
	reset: func(t *testing.T) {
		miguMu.Lock()
		saved := miguCache
		miguCache = map[string]miguResult{}
		miguMu.Unlock()
		miguAlbumCoverMu.Lock()
		savedCovers := miguAlbumCoverCache
		miguAlbumCoverCache = map[string]string{}
		miguAlbumCoverMu.Unlock()
		t.Cleanup(func() {
			miguMu.Lock()
			miguCache = saved
			miguMu.Unlock()
			miguAlbumCoverMu.Lock()
			miguAlbumCoverCache = savedCovers
			miguAlbumCoverMu.Unlock()
		})
	},
	cacheKeys: func() []string {
		miguMu.Lock()
		defer miguMu.Unlock()
		var keys []string
		for k := range miguCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		miguAlbumCoverMu.Lock()
		defer miguAlbumCoverMu.Unlock()
		var out []string
		for id, cover := range miguAlbumCoverCache {
			out = append(out, "album cover "+id+"="+cover)
		}
		return out
	},
}

const (
	miguParityTr = "[00:01.00]第一行\n[00:05.00]第二行\n[00:09.00]第三行\n[00:13.00]第四行\n"
	// 一条带齐译文、逐字、专辑、封面图、能估出时长(128k 的 3200000 字节 = 200 秒)的条目。
	miguParityFullItem = `{"name":"oh well","singers":[{"name":"Ariana Grande"}],"albums":[{"id":"9","name":"petal"}],` +
		`"imgItems":[{"img":"https://d.musicapp.migu.cn/i/small.jpg","imgSizeType":"03"}],` +
		`"lyricUrl":"https://d.musicapp.migu.cn/l/1.lrc","trcUrl":"https://d.musicapp.migu.cn/l/tr.lrc","mrcurl":"https://d.musicapp.migu.cn/l/1.mrc",` +
		`"newRateFormats":[{"format":"020007","size":"3200000","fileType":"mp3"}]}`
	miguParityOtherItem  = `{"name":"7 rings","singers":[{"name":"Ariana Grande"}],"lyricUrl":"https://d.musicapp.migu.cn/l/7.lrc"}`
	miguParityAlbumCover = `{"code":"000000","resource":[{"resourceType":"2003","albumId":"9","imgItems":[{"img":"https://d.musicapp.migu.cn/i/album.jpg","imgSizeType":"03"}]}]}`
	miguParityJadeite    = `{"code":"000000","songResultData":{"resultList":[[{"name":"oh well","album":"petal","albumId":"9","duration":200,` +
		`"lrcUrl":"https://d.musicapp.migu.cn/l/1.lrc","img3":"https://d.musicapp.migu.cn/i/j.jpg","singerList":[{"name":"Ariana Grande"}]}]]}}`
)

func miguParitySearch(items ...string) string {
	return `{"code":"000000","songResultData":{"result":[` + strings.Join(items, ",") + `]}}`
}

// miguParityFake:search 答 search_all.do(主机、检索词),jadeite 答另一套搜索,files 是歌词文件(路径结尾 → 应答),
// 没列的文件 404;专辑信息接口回 miguParityAlbumCover。
type miguParityFake struct {
	search  func(host, text string) parityReply
	jadeite parityReply
	files   map[string]parityReply
}

func (f miguParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		switch {
		case strings.HasSuffix(r.target, "/content/search_all.do"):
			return f.search(r.Host, r.URL.Query().Get("text"))
		case strings.HasSuffix(r.target, "/music_search/v3/search/searchAll"):
			return f.jadeite
		case strings.HasSuffix(r.target, miguAlbumInfoPath):
			return parityOK(miguParityAlbumCover)
		}
		for suffix, reply := range f.files {
			if strings.HasSuffix(r.target, suffix) {
				return reply
			}
		}
		return parityStatus(http.StatusNotFound)
	}
}

func TestMiguProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "Ariana Grande", "oh well", "petal"
	allFiles := map[string]parityReply{"/l/1.lrc": parityOK(miguFakeLRC), "/l/tr.lrc": parityOK(miguParityTr), "/l/1.mrc": parityOK(miguMRCFixtureHex)}
	found := func(string, string) parityReply { return parityOK(miguParitySearch(miguParityFullItem)) }
	hit := miguParityFake{search: found, files: allFiles, jadeite: parityStatus(http.StatusNotFound)}
	with := func(edit func(*miguParityFake)) func(parityRequest) parityReply {
		f := hit
		f.files = map[string]parityReply{}
		for k, v := range hit.files {
			f.files[k] = v
		}
		edit(&f)
		return f.handler()
	}
	cases := []providerParityCase{
		{
			name: "「歌手 歌名」那条就命中:译文、逐字、专辑封面都取", artist: artist, title: title, album: album, durationSecs: 200,
			handle: hit.handler(), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if r.lyr != miguFakeLRC || r.tr != miguParityTr || !strings.Contains(r.yrc, "(1000,300,0)你") || r.matchTitle != "oh well" || r.matchArtist != "Ariana Grande" ||
					r.matchAlbum != "petal" || r.srcDur != 200 || r.matchCover != "https://d.musicapp.migu.cn/i/album.jpg" || r.plainOnly {
					t.Errorf("正文、译文、逐字、歌名、歌手、专辑、时长、专辑封面都该带上:%+v", r)
				}
			},
		},
		{
			name: "「歌手 歌名」挑不出,只按歌名的命中", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(_, text string) parityReply {
					if text == "Ariana Grande oh well" {
						return parityOK(miguParitySearch(miguParityOtherItem))
					}
					return parityOK(miguParitySearch(miguParityFullItem))
				}
			}),
			wantRequests: 6, wantLyrics: true,
		},
		{
			name: "两条都挑不出", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(string, string) parityReply { return parityOK(miguParitySearch(miguParityOtherItem)) }
			}),
			wantRequests: 2,
		},
		{
			name: "第一台搜索主机 500:换下一台", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(host, _ string) parityReply {
					if strings.HasPrefix(host, "pd.musicapp.migu.cn") {
						return parityStatus(http.StatusInternalServerError)
					}
					return parityOK(miguParitySearch(miguParityFullItem))
				}
			}),
			wantRequests: 6, wantLyrics: true,
		},
		{
			name: "三台搜索主机都没问成:另一套搜索顶上", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(string, string) parityReply { return parityStatus(http.StatusInternalServerError) }
				f.jadeite = parityOK(miguParityJadeite)
			}),
			wantRequests: 6, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.srcDur != 200 || o.result.matchAlbum != "petal" {
					t.Errorf("另一套搜索给的时长、专辑该带上:%+v", o.result)
				}
			},
		},
		{
			name: "搜索哪一路都没问成:不补搜", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(string, string) parityReply { return parityStatus(http.StatusInternalServerError) }
				f.jadeite = parityStatus(http.StatusInternalServerError)
			}),
			wantRequests: 4,
		},
		{
			name: "只有纯文本:标 plainOnly,不取译文", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.files["/l/1.lrc"] = parityOK("@migu music@\n@migu music@\nline one\nline two\n")
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || o.result.lyr != "line one\nline two\n" || o.result.tr != "" {
					t.Errorf("应交纯文本、不带译文:%+v", o.result)
				}
			},
		},
		{
			name: "第一名的歌词文件 https、http 都取不到:用第二名,不进缓存", artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(string, string) parityReply {
					return parityOK(miguParitySearch(strings.ReplaceAll(miguParityFullItem, "/l/1.lrc", "/l/gone.lrc"), miguParityFullItem))
				}
				f.files["/l/gone.lrc"] = parityStatus(http.StatusInternalServerError)
			}),
			wantRequests: 7, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 0 {
					t.Errorf("有一份没问成,这一轮不完整不进缓存:%v", o.cached)
				}
			},
		},
		{
			name: "译文文件取不到:正文照交,不进缓存", artist: artist, title: title, album: album, durationSecs: 200,
			handle:       with(func(f *miguParityFake) { delete(f.files, "/l/tr.lrc") }),
			wantRequests: 6, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.tr != "" || o.result.yrc == "" || len(o.cached) != 0 {
					t.Errorf("没有译文、逐字照取、不进缓存:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 200,
			handle: hit.handler(), wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "Ariana Grande|oh well|petal|200" {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑和取整的时长:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "oh well (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 200,
			handle: with(func(f *miguParityFake) {
				f.search = func(string, string) parityReply {
					return parityOK(miguParitySearch(strings.ReplaceAll(miguParityFullItem, `"name":"oh well"`, `"name":"oh well (#2)"`)))
				}
			}),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "oh well (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "Ariana Grande|oh well (#2)|") {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			// 暂停按主机记:三台搜索主机和另一套搜索各撞一次。
			name: "后台吃到 429:撞到的主机各自暂停后台请求", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 200,
			handle: func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }, wantRequests: 4,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused pd.musicapp.migu.cn") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 200)...)
	runProviderParity(t, miguParitySource, cases)
}

func TestMiguProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, miguParitySource, "Ariana Grande", "oh well", 200)
}

func TestMiguProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, miguParitySource, "Ariana Grande", "oh well", 200, parityNotFound)
}
