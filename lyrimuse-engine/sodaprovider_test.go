package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// sodaParitySource:汽水的对拍。曲目 id 先取客户端的播放队列缓存(默认指到不存在的路径,要它的场景在 prepare 里换),
// 拿不到再搜;取词两个主机都不行时取曲目分享页(主机不归汽水名下,列在 extraHosts 里)。
var sodaParitySource = providerParitySource{
	name: lyricSourceSoda,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r, noLyrics := sodaLyric(ctx, artist, srcTitle, album, durationSecs)
		noVocals := r.fromLocalClient && (r.noVocals || sodaLocalInstrumental(artist, srcTitle, album, durationSecs))
		return lyricSourceResult{source: "soda", lyr: r.lyrics, yrc: r.yrc, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, trackFoundNoLyrics: noLyrics, noVocals: noVocals, identityFromLocalClient: r.fromLocalClient}
	},
	reset: func(t *testing.T) {
		sodaMu.Lock()
		savedCache, savedSugLyrics := sodaCache, sodaSuggestLyrics
		sodaCache, sodaSuggestLyrics = map[string]sodaResult{}, map[string]sodaResult{}
		sodaMu.Unlock()
		sodaSearchMu.Lock()
		savedSearch := sodaSearchCache
		sodaSearchCache = map[string]sodaSearchCacheEntry{}
		sodaSearchMu.Unlock()
		sodaSuggestMetaMu.Lock()
		savedMeta := sodaSuggestMeta
		sodaSuggestMeta = map[string]sodaSearchItem{}
		sodaSuggestMetaMu.Unlock()
		parserDriftMu.Lock()
		savedDrift := parserDrift
		parserDrift = map[string]*parserDriftEntry{}
		parserDriftMu.Unlock()
		savedFailure := sodaLastFailureReasonNow()
		sodaSetLastFailureReason("")
		t.Cleanup(func() {
			sodaMu.Lock()
			sodaCache, sodaSuggestLyrics = savedCache, savedSugLyrics
			sodaMu.Unlock()
			sodaSearchMu.Lock()
			sodaSearchCache = savedSearch
			sodaSearchMu.Unlock()
			sodaSuggestMetaMu.Lock()
			sodaSuggestMeta = savedMeta
			sodaSuggestMetaMu.Unlock()
			parserDriftMu.Lock()
			parserDrift = savedDrift
			parserDriftMu.Unlock()
			sodaSetLastFailureReason(savedFailure)
		})
		resetSodaLocalIndex(t, filepath.Join(t.TempDir(), "no-soda-client", "QueueCache"))
	},
	cacheKeys: func() []string {
		sodaMu.Lock()
		defer sodaMu.Unlock()
		var keys []string
		for k := range sodaCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		out := []string{"last failure=" + sodaLastFailureReasonNow()}
		sodaSearchMu.Lock()
		for k, v := range sodaSearchCache {
			out = append(out, fmt.Sprintf("search cache %s items=%d host=%s", k, len(v.items), v.host))
		}
		sodaSearchMu.Unlock()
		sodaSuggestMetaMu.Lock()
		for id := range sodaSuggestMeta {
			out = append(out, "suggest meta "+id)
		}
		sodaSuggestMetaMu.Unlock()
		sodaMu.Lock()
		for id := range sodaSuggestLyrics {
			out = append(out, "suggest lyrics "+id)
		}
		sodaMu.Unlock()
		parserDriftMu.Lock()
		for name, e := range parserDrift {
			if strings.HasPrefix(name, "soda") {
				out = append(out, fmt.Sprintf("parser drift %s streak=%d detail=%q", name, e.Streak, e.Detail))
			}
		}
		parserDriftMu.Unlock()
		sort.Strings(out[1:])
		return append(out, parityEndpointHealth(lyricSourceSoda)...)
	},
	headers:    []string{"User-Agent"},
	extraHosts: []string{"music.douyin.com"},
}

const (
	sodaParityID    = "6705555863068739585"
	sodaParityCover = "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc~tplv-b829550vbb-resize:0:0.jpg"
	sodaParityTr    = "[00:19.65]译文第一句\n[00:27.41]译文第二句\n[00:50.05]译文第三句"
)

// sodaParityFake 按接口分发汽水的请求;没给的接口回 404。
type sodaParityFake struct {
	// search:整页搜索(两个主机同一个路径,r.target 里有主机);suggest:搜索联想。
	search, suggest func(r parityRequest) parityReply
	// seo:seo_track(两个主机),id 是曲目 id;share:曲目分享页。
	seo   func(r parityRequest, id string) parityReply
	share func(r parityRequest, id string) parityReply
}

func (f sodaParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		id := r.URL.Query().Get("track_id")
		switch {
		case r.URL.Path == sodaSearchPath && f.search != nil:
			return f.search(r)
		case r.URL.Path == sodaSuggestPath && f.suggest != nil:
			return f.suggest(r)
		case r.URL.Path == sodaSeoTrackPath && f.seo != nil:
			return f.seo(r, id)
		case r.target == sodaSharePageURL && f.share != nil:
			return f.share(r, id)
		}
		return parityStatus(http.StatusNotFound)
	}
}

// sodaParitySeo:一条曲目的 seo_track 应答。content 为空是曲库有这首、平台没给词;instrumental 标 vocal==2。
func sodaParitySeo(id, name, artist string, durationMs int64, content string, instrumental bool) parityReply {
	resp := sodaTestSeoFor(id, name, artist, durationMs, content)
	if content != "" {
		resp.Lyric.Translations = map[string]string{"cn": sodaParityTr}
	}
	if instrumental {
		resp.SeoTrack.Track.Vocal = sodaLocalVocalInstrumental
	}
	b, _ := json.Marshal(resp)
	return parityOK(string(b))
}

type sodaParityHit struct {
	id, name, artist, album string
	durationMs              int64
}

func sodaParitySearch(hits ...sodaParityHit) parityReply {
	var data []map[string]any
	for _, h := range hits {
		data = append(data, map[string]any{"entity": map[string]any{"track": map[string]any{
			"id": h.id, "name": h.name, "duration": h.durationMs,
			"artists": []map[string]any{{"name": h.artist}}, "album": map[string]any{"name": h.album},
		}}})
	}
	b, _ := json.Marshal(map[string]any{"result_groups": []map[string]any{{"id": "tracks", "data": data}}})
	return parityOK(string(b))
}

// sodaParityQueue:把客户端的播放队列缓存指到一份只有这一条曲目的假文件。vocal 为 2、不带人声起点是纯音乐条目的形状。
func sodaParityQueue(name, artist, album string, durationMs int64, instrumental bool) func(t *testing.T) {
	return func(t *testing.T) {
		vocal, firstVocal := 1, int64(15000)
		if instrumental {
			vocal, firstVocal = sodaLocalVocalInstrumental, -1
		}
		track := sodaTestTrack(name, artist, album, durationMs, vocal, firstVocal)
		track["id"] = sodaParityID
		resetSodaLocalIndex(t, writeTestSodaQueue(t, []map[string]any{track}))
	}
}

// sodaParityQueueTracks:同 sodaParityQueue,队列里放这几条。
func sodaParityQueueTracks(tracks ...map[string]any) func(t *testing.T) {
	return func(t *testing.T) { resetSodaLocalIndex(t, writeTestSodaQueue(t, tracks)) }
}

// sodaParityTrack:队列里方大同的一条。id 为空是不带曲目 id 的条目。
func sodaParityTrack(id, name, album string, instrumental bool) map[string]any {
	vocal, firstVocal := 1, int64(15000)
	if instrumental {
		vocal, firstVocal = sodaLocalVocalInstrumental, -1
	}
	track := sodaTestTrack(name, "方大同", album, 222653, vocal, firstVocal)
	if id != "" {
		track["id"] = id
	}
	return track
}

func TestSodaProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "方大同", "Sorry", "未来"
	found := sodaParityHit{sodaParityID, "Sorry", "方大同", "未来", 222653}
	hit := sodaParityFake{
		search: func(parityRequest) parityReply { return sodaParitySearch(found) },
		seo: func(_ parityRequest, id string) parityReply {
			return sodaParitySeo(id, "Sorry", "方大同", 222653, sodaTestLyricContent, false)
		},
	}
	with := func(edit func(*sodaParityFake)) func(parityRequest) parityReply {
		f := hit
		edit(&f)
		return f.handler()
	}
	queued := sodaParityQueue("Sorry", "方大同", "未来", 222653, false)
	queuedInstrumental := sodaParityQueue("Sorry", "方大同", "未来", 222653, true)
	noLyricsSeo := func(instrumental bool) func(parityRequest, string) parityReply {
		return func(_ parityRequest, id string) parityReply {
			return sodaParitySeo(id, "Sorry", "方大同", 222653, "", instrumental)
		}
	}
	sharePage := func(parityRequest, string) parityReply {
		return parityOK(string(sodaTestSharePage(`{` + sodaTestShareTrackInfo + `,"songMakerTeamSentences":[],"lyrics":{"lyricType":"krc","sentences":[` +
			`{"startMs":0,"endMs":20700,"text":"当我","words":[{"startMs":19650,"endMs":20020,"text":"当"},{"startMs":20330,"endMs":20700,"text":"我"}]},` +
			`{"startMs":27410,"endMs":28500,"text":"伤你","words":[{"startMs":27410,"endMs":27780,"text":"伤"},{"startMs":28130,"endMs":28500,"text":"你"}]},` +
			`{"startMs":50050,"endMs":50660,"text":"I'm so","words":[{"startMs":50050,"endMs":50370,"text":"I'm "},{"startMs":50370,"endMs":50660,"text":"so"}]}]}}`)))
	}
	cases := []providerParityCase{
		{
			name: "客户端队列缓存里有这首:按它的曲目 id 直取,不搜,带本机身份", prepare: queued,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if !strings.Contains(r.lyr, "当我回头发现是我") || r.yrc == "" || !strings.Contains(r.tr, "译文第一句") || r.matchTitle != "Sorry" || r.matchArtist != "方大同" ||
					r.matchAlbum != "未来" || r.matchCover != sodaParityCover || r.srcDur != 222.653 || !r.identityFromLocalClient || r.noVocals || r.trackFoundNoLyrics {
					t.Errorf("正文、逐字、译文、歌名、歌手、专辑、封面、时长、本机身份都该带上:%+v", r)
				}
				if len(o.cached) != 1 || o.cached[0] != sodaParityID {
					t.Errorf("进程内缓存按曲目 id 记:%v", o.cached)
				}
			},
		},
		{
			name: "别的歌那一轮:客户端队列缓存给的 id 照用,不算本机身份", prepare: queued, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.identityFromLocalClient {
					t.Errorf("别的歌那一轮不算本机身份:%+v", o.result)
				}
			},
		},
		{
			name: "客户端给的 id、平台没给词、seo_track 说没有人声:交无人声信号", prepare: queued,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) { f.seo = noLyricsSeo(true) }), wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.noVocals || !o.result.trackFoundNoLyrics || !o.result.identityFromLocalClient {
					t.Errorf("应带无人声、有歌没词、本机身份:%+v", o.result)
				}
			},
		},
		{
			name: "客户端给的 id、平台没给词、队列缓存标着纯音乐:交无人声信号", prepare: queuedInstrumental,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) { f.seo = noLyricsSeo(false) }), wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.noVocals || !o.result.trackFoundNoLyrics {
					t.Errorf("队列缓存的 vocal==2 也算无人声:%+v", o.result)
				}
			},
		},
		{
			name: "客户端给的 id、平台没给词、哪边都没说无人声:只报有歌没词", prepare: queued,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) { f.seo = noLyricsSeo(false) }), wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.noVocals || !o.result.trackFoundNoLyrics || !o.result.identityFromLocalClient {
					t.Errorf("不该带无人声:%+v", o.result)
				}
			},
		},
		{
			name:    "客户端队列里同名两条挂在不同专辑下:按专辑挑",
			prepare: sodaParityQueueTracks(sodaParityTrack("other-album", "Sorry", "精选集", false), sodaParityTrack("this-album", "Sorry", "未来", false)),
			artist:  artist, title: title, album: album, durationSecs: 222.6,
			handle: hit.handler(), wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "this-album" {
					t.Errorf("应取专辑对得上的那一条:%v", o.cached)
				}
			},
		},
		{
			name:    "客户端队列里这一条标着纯音乐却没有曲目 id、搜到的那条没词:id 不是客户端给的,不交无人声信号",
			prepare: sodaParityQueueTracks(sodaParityTrack("", "Sorry", "未来", true)),
			artist:  artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) { f.seo = noLyricsSeo(false) }), wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.noVocals || o.result.identityFromLocalClient || !o.result.trackFoundNoLyrics {
					t.Errorf("搜到的 id 不带本机身份,队列缓存的纯音乐标记也不算:%+v", o.result)
				}
			},
		},
		{
			name: "客户端里没有这首:搜索命中、按搜到的 id 取词,不算本机身份", artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: hit.handler(), wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.identityFromLocalClient || o.result.noVocals || o.result.yrc == "" {
					t.Errorf("搜到的不算本机身份:%+v", o.result)
				}
			},
		},
		{
			name: "搜到的 id、seo_track 说没有人声:不是客户端给的 id,不交无人声信号", artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) { f.seo = noLyricsSeo(true) }), wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.noVocals || !o.result.trackFoundNoLyrics {
					t.Errorf("搜到的 id 只报有歌没词:%+v", o.result)
				}
			},
		},
		{
			name: "搜索第一名没词:接着取第二名", artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.search = func(parityRequest) parityReply {
					return sodaParitySearch(sodaParityHit{"71", "Sorry", "方大同", "未来", 222653}, sodaParityHit{"72", "Sorry", "方大同", "未来 (Deluxe)", 222000})
				}
				f.seo = func(_ parityRequest, id string) parityReply {
					if id == "71" {
						return sodaParitySeo(id, "Sorry", "方大同", 222653, "", false)
					}
					return sodaParitySeo(id, "Sorry", "方大同", 222000, sodaTestLyricContent, false)
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.srcDur != 222 || o.result.trackFoundNoLyrics {
					t.Errorf("应是第二名那条:%+v", o.result)
				}
			},
		},
		{
			name: "搜到的歌手、版本、时长都对不上:不取词", artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.search = func(parityRequest) parityReply {
					return sodaParitySearch(sodaParityHit{"81", "Sorry", "Justin Bieber", "Purpose", 200000}, sodaParityHit{"82", "Sorry (Live)", "方大同", "现场", 222653},
						sodaParityHit{"83", "Sorry", "方大同", "未来", 60000})
				}
			}),
			wantRequests: 1,
		},
		{
			name: "搜索的主用主机没问成:换下一台", artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.search = func(r parityRequest) parityReply {
					if strings.Contains(r.target, sodaSearchHost) {
						return parityStatus(http.StatusBadGateway)
					}
					return sodaParitySearch(found)
				}
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "host="+sodaSeoTrackHost) {
					t.Errorf("搜索缓存该记下答了话的是备用主机:%v", o.state)
				}
			},
		},
		{
			name: "整页搜索回空应答(认不出):改问联想,问到的那条取词时不再问 seo_track", artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.search = func(parityRequest) parityReply { return parityOK("") }
				f.suggest = func(parityRequest) parityReply { return parityOK(sodaTestSugSorry) }
				f.seo = func(_ parityRequest, id string) parityReply {
					if id == "81" {
						return sodaParitySeo(id, "Sorry", "Justin Bieber", 200000, sodaTestLyricContent, false)
					}
					return sodaParitySeo(id, "Sorry", "方大同", 222653, sodaTestLyricContent, false)
				}
			}),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				state := strings.Join(o.state, "\n")
				if o.result.matchArtist != "方大同" || !strings.Contains(state, "parser drift "+sodaSearchParserName) || !strings.Contains(state, "suggest meta 82") ||
					len(o.cached) != 1 || o.cached[0] != "82" {
					t.Errorf("应从联想找到方大同那条,整页搜索记一次认不出,选中的那条进缓存:%+v %v %v", o.result, o.state, o.cached)
				}
			},
		},
		{
			name: "seo_track 两个主机都没问成:取曲目分享页,不进缓存", prepare: queued,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.seo = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				f.share = sharePage
			}),
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.tr != "" || o.result.yrc == "" || len(o.cached) != 0 || !o.result.identityFromLocalClient {
					t.Errorf("分享页那份没有译文、不进缓存,本机身份照带:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "seo_track 答了却没有曲目 id、分享页也取不到:记下端点变了", prepare: queued,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.seo = func(parityRequest, string) parityReply { return parityOK(`{"lyric":{"content":""},"seo_track":{}}`) }
			}),
			wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "last failure="+lyricFailureReasonSodaEndpointChanged) || o.result.trackFoundNoLyrics {
					t.Errorf("应记 soda_endpoint_changed,不报有歌没词:%v %+v", o.state, o.result)
				}
			},
		},
		{
			name: "这一轮允许问备用主机、主用主机搜到的都取不到词:再问备用主机", ctx: withLyricSearchBackupHosts,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.search = func(r parityRequest) parityReply {
					if strings.Contains(r.target, sodaSearchHost) {
						return sodaParitySearch(sodaParityHit{"71", "Sorry Mix", "方大同", "", 160000})
					}
					return sodaParitySearch(sodaParityHit{"72", "Sorry", "方大同", "未来", 222653})
				}
			}),
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "只有逐行 LRC:收下,没有逐字", prepare: queued,
			artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.seo = func(_ parityRequest, id string) parityReply {
					return sodaParitySeo(id, "Sorry", "方大同", 222653, "[00:19.65]当我回头\n[00:27.41]伤你最多\n[00:50.05]I'm so sorry", false)
				}
			}),
			wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.yrc != "" {
					t.Errorf("逐行那种没有逐字:%+v", o.result)
				}
			},
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: hit.handler(), wantRequests: 2, wantLyrics: true,
		},
		{
			name: "歌名带编号:拿带编号的那份去认客户端队列缓存、去挑候选",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Sorry (#2)", artist, title, album)
			},
			prepare: sodaParityQueueTracks(sodaParityTrack("plain-1", "Sorry", "未来", false), sodaParityTrack("numbered-2", "Sorry (#2)", "未来", false)),
			artist:  artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.seo = func(_ parityRequest, id string) parityReply {
					if id == "numbered-2" {
						return sodaParitySeo(id, "Sorry (#2)", "方大同", 222653, sodaTestLyricContent, false)
					}
					return sodaParitySeo(id, "Sorry", "方大同", 222653, sodaTestLyricContent, false)
				}
			}),
			wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "Sorry (#2)" || !o.result.identityFromLocalClient || len(o.cached) != 1 || o.cached[0] != "numbered-2" {
					t.Errorf("应按带编号的歌名认出客户端里带编号的那一条:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "歌名带编号、客户端队列缓存标着纯音乐:无人声也按带编号的歌名认",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Sorry (#2)", artist, title, album)
			},
			prepare: sodaParityQueueTracks(sodaParityTrack("plain-1", "Sorry", "未来", false), sodaParityTrack("numbered-2", "Sorry (#2)", "未来", true)),
			artist:  artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) { f.seo = noLyricsSeo(false) }), wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.noVocals {
					t.Errorf("应按带编号的歌名认出队列缓存里的纯音乐标记:%+v", o.result)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 222.6,
			handle: with(func(f *sodaParityFake) {
				f.search = func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }
				f.suggest = func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }
			}),
			wantRequests: 2, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused "+sodaSearchHost) {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
		{
			name: "设置里关掉:客户端队列缓存有也不读", prepare: queued, disabled: true,
			artist: artist, title: title, album: album, durationSecs: 222.6, handle: hit.handler(),
		},
		{
			name: "熔断冷却:客户端队列缓存有也不问(没有本机那条腿),记跳过", prepare: queuedInstrumental, cooling: true,
			artist: artist, title: title, album: album, durationSecs: 222.6, handle: hit.handler(), wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.noVocals || o.result.identityFromLocalClient {
					t.Errorf("冷却时什么都不交:%+v", o.result)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 222.6)...)
	runProviderParity(t, sodaParitySource, cases)
}

func TestSodaProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, sodaParitySource, "方大同", "Sorry", 222.6)
}

func TestSodaProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, sodaParitySource, "方大同", "Sorry", 222.6, parityNotFound)
}
