package main

import (
	"context"
	"crypto/aes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// neteaseParitySource:网易云的对拍。参照路径是迁移前收集循环里那个 goroutine 的整段(判跳过、查、往通道里递曲目 id、交结果),
// 递出去的 id 在三源联合对拍里比(lyricprovidertrackids_test.go),这里比结果和发出的请求。客户端曲库默认指到不存在的路径,
// 要它的场景在 prepare 里换成临时目录里合成的库。
var neteaseParitySource = providerParitySource{
	name: lyricSourceNetease,
	handwrittenRound: func(ctx context.Context, artist, srcTitle, album string, durationSecs float64, only map[string]bool, breakerPlan lyricSourceRoundPlan, round *lyricSourceRound) lyricSourceResult {
		neteaseIDCh := make(chan string, 1)
		if lyricSourceSkippedThisRound(ctx, "netease", only, breakerPlan, round) {
			neteaseIDCh <- ""
			return lyricSourceResult{source: "netease"}
		}
		info := neteaseLookup(ctx, artist, srcTitle, album, durationSecs)
		if info.SongID > 0 {
			neteaseIDCh <- strconv.FormatInt(info.SongID, 10)
		} else {
			neteaseIDCh <- ""
		}
		return lyricSourceResult{source: "netease", ne: info}
	},
	reset: func(t *testing.T) {
		neteaseMu.Lock()
		savedCache := neteaseCache
		neteaseCache = map[string]neteaseCacheEntry{}
		neteaseMu.Unlock()
		neteaseRateMu.Lock()
		savedCall, savedCooldown, savedStreak, savedSuccess := neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak, neteaseAnySuccess
		neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak, neteaseAnySuccess = time.Time{}, map[string]time.Time{}, map[string]int{}, false
		neteaseRateMu.Unlock()
		neteaseSearchJunkMu.Lock()
		savedJunk := neteaseSearchJunk
		neteaseSearchJunk = map[string]neteaseSearchJunkState{}
		neteaseSearchJunkMu.Unlock()
		savedFailure := neteaseLastFailureReasonNow()
		neteaseSetLastFailureReason("")
		t.Cleanup(func() {
			neteaseMu.Lock()
			neteaseCache = savedCache
			neteaseMu.Unlock()
			neteaseRateMu.Lock()
			neteaseLastCall, neteaseCooldownUntil, neteaseBlockStreak, neteaseAnySuccess = savedCall, savedCooldown, savedStreak, savedSuccess
			neteaseRateMu.Unlock()
			neteaseSearchJunkMu.Lock()
			neteaseSearchJunk = savedJunk
			neteaseSearchJunkMu.Unlock()
			neteaseSetLastFailureReason(savedFailure)
		})
		resetNeteaseLocalIndex(t, filepath.Join(t.TempDir(), "no-netease-client", "sqlite_storage.sqlite3"))
	},
	cacheKeys: func() []string {
		neteaseMu.Lock()
		defer neteaseMu.Unlock()
		var keys []string
		for k := range neteaseCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		out := []string{"last failure=" + neteaseLastFailureReasonNow(), fmt.Sprintf("any success=%v", neteaseSawSuccessNow())}
		neteaseRateMu.Lock()
		for bucket, until := range neteaseCooldownUntil {
			out = append(out, fmt.Sprintf("bucket %s backs off for %s", bucket, time.Until(until).Round(10*time.Second)))
		}
		for bucket, n := range neteaseBlockStreak {
			out = append(out, fmt.Sprintf("bucket %s rejected %d in a row", bucket, n))
		}
		neteaseRateMu.Unlock()
		neteaseSearchJunkMu.Lock()
		for endpoint, st := range neteaseSearchJunk {
			out = append(out, fmt.Sprintf("junk %s strikes=%d skipping=%v", endpoint, st.strikes, time.Now().Before(st.until)))
		}
		neteaseSearchJunkMu.Unlock()
		sort.Strings(out[2:])
		return append(out, parityEndpointHealth(lyricSourceNetease)...)
	},
	headers: []string{"Cookie"},
}

// neParityFake 按接口分发网易云的请求;没给的接口回 404。path 是去掉 /api/ 的接口路径,eapi 写法的带 `eapi/` 前缀
// (search/get、eapi/search/get、song/lyric/v1……),host 是请求的主机。
type neParityFake struct {
	// search:搜歌(type=1);albums:搜专辑(type=10)。q 是查询词。
	search, albums func(r parityRequest, path, q string) parityReply
	// detail:单曲详情(song/detail、v3/song/detail、eapi/song/detail);lyric:歌词(song/lyric/v1、eapi/song/lyric/v1、song/lyric)。
	detail, lyric func(r parityRequest, path string) parityReply
	// album:专辑曲目(album/<id>、v1/album/<id>、eapi/album/<id>)。
	album func(r parityRequest, path string) parityReply
}

// neParityEapiQuery 解开 eapi 请求体里加密的查询参数;解不开返回 nil。
func neParityEapiQuery(body string) map[string]string {
	raw, err := hex.DecodeString(strings.TrimPrefix(body, "params="))
	if err != nil || len(raw) == 0 || len(raw)%aes.BlockSize != 0 {
		return nil
	}
	block, _ := aes.NewCipher([]byte(neteaseEapiKey))
	for i := 0; i < len(raw); i += aes.BlockSize {
		block.Decrypt(raw[i:i+aes.BlockSize], raw[i:i+aes.BlockSize])
	}
	parts := strings.Split(string(raw[:len(raw)-int(raw[len(raw)-1])]), "-36cd479b6b5-")
	if len(parts) != 3 {
		return nil
	}
	data := map[string]string{}
	if json.Unmarshal([]byte(parts[1]), &data) != nil {
		return nil
	}
	return data
}

func (f neParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		path, eapi := strings.CutPrefix(r.URL.Path, "/eapi/")
		query := map[string]string{}
		if eapi {
			query = neParityEapiQuery(r.body)
		} else {
			path = strings.TrimPrefix(path, "/api/")
			for k, v := range r.URL.Query() {
				query[k] = v[0]
			}
		}
		name := path
		if eapi {
			name = "eapi/" + path
		}
		var h func(parityRequest, string) parityReply
		switch {
		case path == "search/get" || path == "search/get/web" || path == "cloudsearch/pc":
			search := f.search
			if query["type"] == "10" {
				search = f.albums
			}
			if search == nil {
				return parityStatus(http.StatusNotFound)
			}
			return search(r, name, query["s"])
		case path == "song/detail" || path == "v3/song/detail":
			h = f.detail
		case path == "song/lyric/v1" || path == "song/lyric":
			h = f.lyric
		case strings.HasPrefix(path, "album/") || strings.HasPrefix(path, "v1/album/"):
			h = f.album
		}
		if h == nil {
			return parityStatus(http.StatusNotFound)
		}
		return h(r, name)
	}
}

// neParitySong:搜索结果里的一条。picID 为 0 时不带封面(要另问单曲详情)。
type neParitySong struct {
	id            int64
	name, artist  string
	album         string
	albumID       int64
	ms            float64
	picID, mark   int64
	secondArtists []string
}

// neParitySearch:search/get 一类路径的应答(artists / album / duration)。
func neParitySearch(songs ...neParitySong) parityReply {
	list := make([]map[string]any, 0, len(songs))
	for _, s := range songs {
		artists := []map[string]any{{"name": s.artist}}
		for _, a := range s.secondArtists {
			artists = append(artists, map[string]any{"name": a})
		}
		list = append(list, map[string]any{
			"id": s.id, "name": s.name, "artists": artists, "duration": s.ms, "mark": s.mark,
			"album": map[string]any{"id": s.albumID, "name": s.album, "picId": s.picID},
		})
	}
	b, _ := json.Marshal(map[string]any{"code": 200, "result": map[string]any{"songs": list}})
	return parityOK(string(b))
}

// neParityCloudSearch:cloudsearch 的应答(ar / al / dt,封面直接给 picUrl)。
func neParityCloudSearch(songs ...neParitySong) parityReply {
	list := make([]map[string]any, 0, len(songs))
	for _, s := range songs {
		list = append(list, map[string]any{
			"id": s.id, "name": s.name, "ar": []map[string]any{{"name": s.artist}}, "dt": s.ms,
			"al": map[string]any{"id": s.albumID, "name": s.album, "picUrl": neParityDetailPic},
		})
	}
	b, _ := json.Marshal(map[string]any{"code": 200, "result": map[string]any{"songs": list}})
	return parityOK(string(b))
}

const (
	neParityPicID     = 109951171529987110
	neParityDetailPic = "http://p1.music.126.net/detail/x.jpg"
	neParityRejected  = `{"result":{},"code":405}`
	neParityTrans     = "[00:28.948]译一\n[00:36.141]译二\n[00:44.000]译三\n[00:52.000]译四"
	neParityRoma      = "[00:28.948]jau jan man ngo\n[00:36.141]ngo kei doi\n[00:44.000]dai saam geoi\n[00:52.000]dai sei geoi"
	neParityYRC       = "[28948,2000](28948,500,0)有(29448,500,0)人"
)

// neParityLyric:歌词接口的应答。v1 的整行带 JSON 署名行,老接口是换好的写法。
func neParityLyric(lrc, tr, roma, yrc string, pureMusic bool) parityReply {
	b, _ := json.Marshal(map[string]any{
		"code": 200, "pureMusic": pureMusic,
		"lrc": map[string]any{"lyric": lrc}, "tlyric": map[string]any{"lyric": tr},
		"romalrc": map[string]any{"lyric": roma}, "yrc": map[string]any{"lyric": yrc},
	})
	return parityOK(string(b))
}

func neParityDetail(path string) parityReply {
	if path == "v3/song/detail" {
		return parityOK(`{"code":200,"songs":[{"al":{"picUrl":"` + neParityDetailPic + `"}}]}`)
	}
	return parityOK(`{"code":200,"songs":[{"album":{"picUrl":"` + neParityDetailPic + `"}}]}`)
}

// neParityLocal:把网易云客户端曲库指到一份只有这几条曲目的合成库。
func neParityLocal(tracks ...string) func(t *testing.T) {
	return func(t *testing.T) { resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, tracks)) }
}

func TestNeteaseProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "陈奕迅", "浮夸", "U87"
	const secs = 283.5
	found := neParitySong{id: 66282, name: "浮夸", artist: "陈奕迅", album: "U87", albumID: 6491, ms: 283520, picID: neParityPicID}
	noPic := found
	noPic.picID = 0
	fullLyric := func(_ parityRequest, path string) parityReply {
		if path == "song/lyric/v1" {
			return neParityLyric(neV1Lyric, neParityTrans, neParityRoma, neParityYRC, false)
		}
		return parityStatus(http.StatusNotFound)
	}
	onPrimary := func(reply parityReply) func(parityRequest, string, string) parityReply {
		return func(_ parityRequest, path, _ string) parityReply {
			if path == "search/get" {
				return reply
			}
			return parityStatus(http.StatusNotFound)
		}
	}
	hit := neParityFake{search: onPrimary(neParitySearch(found)), lyric: fullLyric}
	with := func(mod func(f *neParityFake)) func(parityRequest) parityReply {
		f := hit
		mod(&f)
		return f.handler()
	}
	wantNE := func(what string, ok func(ne neteaseInfo) bool) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			t.Helper()
			if !ok(o.result.ne) {
				t.Errorf("%s:%+v", what, o.result.ne)
			}
		}
	}
	matched := func(ne neteaseInfo) bool {
		return ne.SongID == 66282 && ne.SongURL == "https://music.163.com/song?id=66282" && ne.Title == "浮夸" && ne.Album == "U87" &&
			ne.AlbumID == 6491 && ne.Artist == "陈奕迅" && ne.DurationSecs == 283.52
	}
	withLyrics := func(ne neteaseInfo) bool { return strings.HasPrefix(ne.Lyrics, "[00:00.00] 作词 : 黄伟文") }
	local := neParityLocal(neteaseTestTrack("66282", "浮夸", "陈奕迅", "U87", 283520))
	searchedCache := func(t *testing.T) {
		neteaseMu.Lock()
		neteaseCache[artist+"|"+title+"|"+album+"|283"] = neteaseCacheEntry{
			info: neteaseInfo{SongID: 777, SongURL: "https://music.163.com/song?id=777", Cover: "http://p1.music.126.net/cached.jpg", Lyrics: "[00:01.00]缓存里搜来的那份\n[00:02.00]第二句\n[00:03.00]第三句"},
			ts:   time.Now().Unix(),
		}
		neteaseMu.Unlock()
	}
	cases := append(providerParitySkipCases(artist, title, secs), []providerParityCase{
		{
			name: "搜索命中:整行、译文、罗马音、逐字一次取齐,封面由搜索结果的 picId 算", artist: artist, title: title, album: album, durationSecs: secs,
			handle: hit.handler(), wantRequests: 2,
			check: wantNE("各字段应齐", func(ne neteaseInfo) bool {
				return matched(ne) && withLyrics(ne) && ne.Trans == neParityTrans && ne.Roma == neParityRoma && ne.YRC == neParityYRC &&
					ne.Cover == neteasePicURL(neParityPicID)+neteaseCoverQuery && !ne.FromLocalClient
			}),
		},
		{
			name: "搜索结果不带封面:问单曲详情", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch(noPic))
				f.detail = func(_ parityRequest, path string) parityReply {
					if path == "song/detail" {
						return neParityDetail(path)
					}
					return parityStatus(http.StatusNotFound)
				}
			}),
			wantRequests: 3,
			check: wantNE("封面应取自单曲详情", func(ne neteaseInfo) bool {
				return matched(ne) && ne.Cover == neParityDetailPic+neteaseCoverQuery
			}),
		},
		{
			name: "老详情接口三个主机都没问成:退到 v3 详情", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch(noPic))
				f.detail = func(_ parityRequest, path string) parityReply {
					if path == "v3/song/detail" {
						return neParityDetail(path)
					}
					return parityStatus(http.StatusInternalServerError)
				}
			}),
			wantRequests: 6,
			check:        wantNE("封面应取自 v3 详情", func(ne neteaseInfo) bool { return ne.Cover == neParityDetailPic+neteaseCoverQuery }),
		},
		{
			name: "老详情、v3 详情都没问成:问老详情的 eapi 写法", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch(noPic))
				f.detail = func(_ parityRequest, path string) parityReply {
					if path == "eapi/song/detail" {
						return neParityDetail(path)
					}
					return parityStatus(http.StatusInternalServerError)
				}
			}),
			wantRequests: 9,
			check:        wantNE("封面应取自 eapi 详情", func(ne neteaseInfo) bool { return ne.Cover == neParityDetailPic+neteaseCoverQuery }),
		},
		{
			name: "首选搜索被拒(405):换 /web,这个桶退避、记下限流原因", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = func(_ parityRequest, path, _ string) parityReply {
					if path == "search/get/web" {
						return neParitySearch(found)
					}
					return parityOK(neParityRejected)
				}
			}),
			wantRequests: 3,
			check: func(t *testing.T, o providerParityOutcome) {
				if !matched(o.result.ne) || !strings.Contains(strings.Join(o.state, "\n"), "last failure="+lyricFailureReasonNeteaseRateLimited) ||
					!strings.Contains(strings.Join(o.state, "\n"), "bucket /api/search/get backs off for 2m0s") {
					t.Errorf("应从 /web 拿到、首选那个桶在退避:%+v\n%v", o.result.ne, o.state)
				}
			},
		},
		{
			name: "明文两条搜索都被拒:问 eapi 的 search/get", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = func(_ parityRequest, path, _ string) parityReply {
					if path == "eapi/search/get" {
						return neParitySearch(found)
					}
					return parityOK(neParityRejected)
				}
			}),
			wantRequests: 4, check: wantNE("应从 eapi 拿到", matched),
		},
		{
			name: "search/get 三条都被拒:退到 cloudsearch,字段名归一、封面用它给的 picUrl", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = func(_ parityRequest, path, _ string) parityReply {
					if path == "cloudsearch/pc" {
						return neParityCloudSearch(found)
					}
					return parityOK(neParityRejected)
				}
			}),
			wantRequests: 5,
			check: wantNE("应从 cloudsearch 拿到", func(ne neteaseInfo) bool {
				return matched(ne) && ne.Cover == neParityDetailPic+neteaseCoverQuery
			}),
		},
		{
			name: "首选主机没问成:换下一个主机", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = func(r parityRequest, path, _ string) parityReply {
					if path == "search/get" && r.Host != "music.163.com" {
						return neParitySearch(found)
					}
					return parityStatus(http.StatusBadGateway)
				}
			}),
			wantRequests: 3, check: wantNE("应从备用主机拿到", matched),
		},
		{
			name: "v1 歌词三个主机都没问成:问 v1 的 eapi 写法", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.lyric = func(_ parityRequest, path string) parityReply {
					if path == "eapi/song/lyric/v1" {
						return neParityLyric(neV1Lyric, neParityTrans, "", neParityYRC, false)
					}
					return parityStatus(http.StatusInternalServerError)
				}
			}),
			wantRequests: 5,
			check: wantNE("整行、逐字应取自 eapi 的 v1", func(ne neteaseInfo) bool {
				return withLyrics(ne) && ne.YRC == neParityYRC && ne.Roma == ""
			}),
		},
		{
			name: "v1 两种写法都没问成:退到老歌词接口,没有逐字,这份不进缓存", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.lyric = func(_ parityRequest, path string) parityReply {
					if path == "song/lyric" {
						return neParityLyric(neteaseV1LyricLines(neV1Lyric), neParityTrans, neParityRoma, "", false)
					}
					return parityStatus(http.StatusInternalServerError)
				}
			}),
			wantRequests: 8,
			check: func(t *testing.T, o providerParityOutcome) {
				if ne := o.result.ne; !withLyrics(ne) || ne.YRC != "" || ne.Trans != neParityTrans || len(o.cached) != 0 {
					t.Errorf("应有整行和译文、没有逐字、不进缓存:%+v 缓存 %v", ne, o.cached)
				}
			},
		},
		{
			name: "三条歌词接口都没问成:只有封面和链接,不进缓存,也不算「平台没有歌词」", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.lyric = func(parityRequest, string) parityReply { return parityStatus(http.StatusInternalServerError) }
			}),
			wantRequests: 10,
			check: func(t *testing.T, o providerParityOutcome) {
				if ne := o.result.ne; !matched(ne) || ne.Lyrics != "" || ne.Cover == "" || ne.TrackFoundNoLyrics || len(o.cached) != 0 {
					t.Errorf("应只有身份和封面、不进缓存:%+v 缓存 %v", ne, o.cached)
				}
			},
		},
		{
			name: "歌词接口说是纯音乐:不交歌词,带纯音乐结论", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.lyric = func(parityRequest, string) parityReply {
					return neParityLyric("[00:00.00] 作曲 : 某某\n[00:05.00]纯音乐,请欣赏\n", "", "", "", true)
				}
			}),
			wantRequests: 2,
			check: wantNE("应是纯音乐", func(ne neteaseInfo) bool {
				return ne.PureMusic && ne.Lyrics == "" && ne.PlainLyrics == "" && !ne.TrackFoundNoLyrics
			}),
		},
		{
			name: "曲库里有这首、正文只有署名:平台没有歌词", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.lyric = func(parityRequest, string) parityReply {
					return neParityLyric(`{"t":-1,"c":[{"tx":"作曲: "},{"tx":"某某"}]}`+"\n"+`{"t":-1,"c":[{"tx":"制作人: "},{"tx":"某某"}]}`+"\n", "", "", "", false)
				}
			}),
			wantRequests: 2,
			check: wantNE("应是有歌没词", func(ne neteaseInfo) bool {
				return ne.TrackFoundNoLyrics && ne.Lyrics == "" && !ne.PureMusic && ne.SongID == 66282
			}),
		},
		{
			name: "只有不带时间戳的歌词:交纯文本", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.lyric = func(parityRequest, string) parityReply {
					return neParityLyric("有人问我 我就会讲\n我期待 到无奈\n第三句\n第四句", "", "", "", false)
				}
			}),
			wantRequests: 2,
			check: wantNE("应只有纯文本", func(ne neteaseInfo) bool {
				return ne.Lyrics == "" && strings.Contains(ne.PlainLyrics, "我期待 到无奈") && !ne.TrackFoundNoLyrics
			}),
		},
		{
			name: "曲目信息带无人声位、正文只有署名:带无人声标记,不算「平台没有歌词」", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				marked := found
				marked.mark = neteaseMarkNoVocals
				f.search = onPrimary(neParitySearch(marked))
				f.lyric = func(parityRequest, string) parityReply {
					return neParityLyric("[00:00.00] 作曲 : 某某\n[00:00.00] 制作人 : 某某\n", "", "", "", false)
				}
			}),
			wantRequests: 2,
			check: wantNE("应带无人声标记", func(ne neteaseInfo) bool {
				return ne.NoVocals && !ne.PureMusic && !ne.TrackFoundNoLyrics && ne.Lyrics == ""
			}),
		},
		{
			name: "客户端曲库认得出这首:不搜,只取词,身份算本机给的", prepare: local, artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = nil
				f.detail = func(_ parityRequest, path string) parityReply { return neParityDetail(path) }
			}),
			wantRequests: 2,
			check: wantNE("应带本机身份", func(ne neteaseInfo) bool {
				return ne.FromLocalClient && ne.SongID == 66282 && withLyrics(ne)
			}),
		},
		{
			name: "别的歌那一轮:客户端曲库给的编号照用,不算本机身份", prepare: local, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = nil
				f.detail = func(_ parityRequest, path string) parityReply { return neParityDetail(path) }
			}),
			wantRequests: 2,
			check: wantNE("不该带本机身份", func(ne neteaseInfo) bool {
				return !ne.FromLocalClient && ne.SongID == 66282 && withLyrics(ne)
			}),
		},
		{
			name: "在放的这首、进程内缓存里是搜来的那份:按本机身份重走", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				local(t)
				searchedCache(t)
			},
			handle: with(func(f *neParityFake) {
				f.search = nil
				f.detail = func(_ parityRequest, path string) parityReply { return neParityDetail(path) }
			}),
			wantRequests: 2,
			check: wantNE("应换成本机认出的那一条", func(ne neteaseInfo) bool {
				return ne.FromLocalClient && ne.SongID == 66282
			}),
		},
		{
			name: "别的歌那一轮、进程内缓存里是搜来的那份:照用缓存", ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				local(t)
				searchedCache(t)
			},
			handle: hit.handler(), wantRequests: 0,
			check: wantNE("应照用缓存", func(ne neteaseInfo) bool {
				return ne.SongID == 777 && strings.Contains(ne.Lyrics, "缓存里搜来的那份")
			}),
		},
		{
			name: "几条查询词都搜不到:按专辑名找专辑、在曲目单里按时长锚定", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch())
				f.albums = func(_ parityRequest, path, _ string) parityReply {
					if path != "search/get" {
						return parityStatus(http.StatusNotFound)
					}
					return parityOK(`{"code":200,"result":{"albums":[{"id":6491,"name":"U87","artist":{"name":"陈奕迅"}}]}}`)
				}
				f.album = func(_ parityRequest, path string) parityReply {
					if path != "album/6491" {
						return parityStatus(http.StatusNotFound)
					}
					return parityOK(`{"code":200,"album":{"name":"U87","songs":[` +
						`{"id":66282,"name":"浮夸","duration":283520,"artists":[{"name":"陈奕迅"}]},` +
						`{"id":66283,"name":"夕阳无限好","duration":250000,"artists":[{"name":"陈奕迅"}]}]}}`)
				}
				f.detail = func(_ parityRequest, path string) parityReply { return neParityDetail(path) }
			}),
			wantRequests: 7,
			check: wantNE("应由专辑曲目单锚定", func(ne neteaseInfo) bool {
				return ne.SongID == 66282 && ne.AlbumID == 6491 && ne.Album == "U87" && withLyrics(ne) && ne.Cover != ""
			}),
		},
		{
			name: "同名两条都对不上专辑:身份挑不出,只给歌词", artist: "Michael Jackson", title: "Leave Me Alone", album: "世纪典藏", durationSecs: 281,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch(
					neParitySong{id: 11, name: "Leave Me Alone", artist: "Michael Jackson", album: "Bad", albumID: 1, ms: 280000, picID: neParityPicID},
					neParitySong{id: 12, name: "Leave Me Alone", artist: "Michael Jackson", album: "The Collection", albumID: 2, ms: 276000, picID: neParityPicID},
				))
				f.albums = func(parityRequest, string, string) parityReply {
					return parityOK(`{"code":200,"result":{"albums":[]}}`)
				}
			}),
			wantRequests: 5,
			check: func(t *testing.T, o providerParityOutcome) {
				if ne := o.result.ne; ne.SongID != 11 || !withLyrics(ne) || ne.Cover != "" || ne.SongURL != "" || ne.AlbumID != 0 || ne.Artist != "" || len(o.cached) != 0 {
					t.Errorf("应只给歌词和曲目 id、不给身份、不进缓存:%+v 缓存 %v", ne, o.cached)
				}
			},
		},
		{
			name: "歌名和专辑对得上、歌手写法对不上:只交规范歌手名", artist: "Eason Chan", title: title, album: album, durationSecs: 0,
			handle:       with(func(f *neParityFake) { f.search = onPrimary(neParitySearch(found)) }),
			wantRequests: 3,
			check: wantNE("应只有歌手名", func(ne neteaseInfo) bool {
				return ne == neteaseInfo{Artist: "陈奕迅"}
			}),
		},
		{
			name: "没搜到这首", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch())
				f.albums = func(_ parityRequest, path, _ string) parityReply {
					if path == "search/get" {
						return parityOK(`{"code":200,"result":{"albums":[]}}`)
					}
					return parityStatus(http.StatusNotFound)
				}
			}),
			wantRequests: 4,
			check:        wantNE("应是空的", func(ne neteaseInfo) bool { return ne == neteaseInfo{} }),
		},
		{
			name: "曲库里只剩仿冒号的歌手:封面、链接、歌手名、专辑 id 扣下,歌词和曲目 id 留着", artist: "周杰伦", title: "晴天", album: "叶惠美", durationSecs: 269,
			handle: with(func(f *neParityFake) {
				f.search = onPrimary(neParitySearch(neParitySong{id: 186016, name: "晴天", artist: "周杰伦", album: "叶惠美", albumID: 18905, ms: 269000, picID: neParityPicID}))
			}),
			wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if ne := o.result.ne; ne.SongID != 186016 || !withLyrics(ne) || ne.Cover != "" || ne.SongURL != "" || ne.Artist != "" || ne.AlbumID != 0 ||
					ne.Title != "晴天" || ne.Album != "叶惠美" || len(o.cached) != 1 {
					t.Errorf("应扣下身份、留着歌词和曲目 id,缓存里是没扣的那份:%+v 缓存 %v", ne, o.cached)
				}
			},
		},
		{
			name: "连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: secs,
			handle: hit.handler(), wantRequests: 2, check: wantNE("各字段应齐", matched),
		},
		{
			name: "歌名带编号:交给源去搜、去挑的是带编号的那份", artist: artist, title: title, album: album, durationSecs: secs,
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "浮夸 (#2)", artist, title, album)
			},
			handle: with(func(f *neParityFake) {
				second := found
				second.id, second.name = 66299, "浮夸 (#2)"
				f.search = onPrimary(neParitySearch(found, second))
			}),
			wantRequests: 2,
			check:        wantNE("应挑带同一个编号的那条", func(ne neteaseInfo) bool { return ne.SongID == 66299 && ne.Title == "浮夸 (#2)" }),
		},
		{
			name: "本地是多人署名:不拿网易云的单人署名统一写法", artist: "陈奕迅 & 王菲", title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				duet := found
				duet.secondArtists = []string{"王菲"}
				f.search = onPrimary(neParitySearch(duet))
			}),
			wantRequests: 2,
			check:        wantNE("歌手名应留空", func(ne neteaseInfo) bool { return ne.SongID == 66282 && ne.Artist == "" }),
		},
		{
			name: "歌名带括号:去括号的那份先搜", artist: artist, title: "浮夸 (Live)", album: "", durationSecs: secs,
			handle: with(func(f *neParityFake) {
				live := found
				live.name, live.album = "浮夸 (Live)", "DUO 陈奕迅2010演唱会"
				f.search = func(_ parityRequest, path, q string) parityReply {
					if path == "search/get" && q == "陈奕迅 浮夸 (Live)" {
						return neParitySearch(live)
					}
					return neParitySearch()
				}
			}),
			wantRequests: 4,
			check:        wantNE("应挑中 Live 那条", func(ne neteaseInfo) bool { return ne.Title == "浮夸 (Live)" && withLyrics(ne) }),
		},
		{
			name: "后台吃到 429:三个主机各问到一次,后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *neParityFake) {
				f.search = func(parityRequest, string, string) parityReply { return parityStatus(http.StatusTooManyRequests) }
				f.albums = f.search
			}),
			wantRequests: 3, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused") {
					t.Errorf("应记下后台暂停:%v", o.state)
				}
			},
		},
	}...)
	runProviderParity(t, neteaseParitySource, cases)
}

func TestNeteaseProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, neteaseParitySource, "陈奕迅", "浮夸", 283.5)
	// amll 等着这个源递编号:请求断掉、编号递出来之后它才走完。
	waitLyricRoundGoroutinesGone(t)
}

func TestNeteaseProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, neteaseParitySource, "陈奕迅", "浮夸", 283.5, parityNotFound)
}
