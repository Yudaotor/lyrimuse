package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// amllParitySource:amll 的对拍。只开着它的一轮里网易云、QQ 都被跳过,它等到的两个编号都是空串,手上只剩播放侧记下的
// Apple / Spotify 编号和索引;网易云、QQ 的编号怎么到它手上在三源联合对拍里比(lyricprovidertrackids_test.go)。
// 索引照单测总入口的默认(没有),播放侧记下的编号先清空,要它们的场景在 prepare 里造。
var amllParitySource = providerParitySource{
	name: lyricSourceAMLL,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		return handwrittenAMLLRound(ctx, "", "", artist, title, srcTitle, album, durationSecs, func(string) bool { return false })
	},
	reset: func(t *testing.T) {
		resetAMLLParityState(t)
		withCleanPlaybackHints(t)
		saved := sharedAMLLIndexStore()
		setSharedAMLLIndexStore(newAMLLIndexStore("", time.Now))
		t.Cleanup(func() { setSharedAMLLIndexStore(saved) })
	},
	cacheKeys: func() []string { return nil },
	state:     amllParityState,
}

const (
	amllParityAppleID   = 1440857781
	amllParitySpotifyID = "3n3Ppam7vgaVa1iaRUc9Lp"
	amllParityAppleFile = "/am-lyrics/1440857781.ttml"
)

// amllParityServe:库里有这几份(`平台目录/编号`),首选镜像上直接取得到;别的回 404。
func amllParityServe(files map[string]string) func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		for file, ttml := range files {
			if r.Host == "raw.githubusercontent.com" && strings.HasSuffix(r.URL.Path, "/"+file+".ttml") {
				return parityOK(ttml)
			}
		}
		return parityStatus(http.StatusNotFound)
	}
}

// amllParityIndex:装一份够新的索引,占位条目之外加这几条。
func amllParityIndex(entries ...amllIndexEntry) func(t *testing.T) {
	return func(t *testing.T) {
		amllTestStore(t, append(amllFillerEntries(), entries...), time.Now(), time.Now)
	}
}

func TestAMLLProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "五月天", "突然好想你", "后青春期的诗"
	const secs = 210
	playingApple := func(t *testing.T) { notePlayingAppleCatalogID(artist, title, album, amllParityAppleID) }
	playingSpotify := func(t *testing.T) { notePlayingSpotifyTrackID(artist, title, album, amllParitySpotifyID) }
	both := func(t *testing.T) {
		playingApple(t)
		playingSpotify(t)
	}
	want := func(what string, ok func(r amllResult) bool) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			t.Helper()
			if !ok(o.result.amll) {
				t.Errorf("%s:%+v", what, o.result.amll)
			}
		}
	}
	inState := func(needle string) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			t.Helper()
			if !strings.Contains(strings.Join(o.state, "\n"), needle) {
				t.Errorf("状态里应有 %q:%v", needle, o.state)
			}
		}
	}
	indexed := amllIndexEntry{Titles: []string{"突然好想你"}, Artists: []string{"五月天"}, Albums: []string{"后青春期的诗"}, Apple: []string{"a1"}}
	cases := append(providerParitySkipCases(artist, title, secs), []providerParityCase{
		{
			name: "没有编号也没有索引:一个请求都不发,记下这一轮没法查", artist: artist, title: title, album: album, durationSecs: secs,
			handle: parityNotFound, wantRequests: 0,
			check: func(t *testing.T, o providerParityOutcome) {
				want("应是空的", func(r amllResult) bool { return r.empty() })(t, o)
				inState("amll skipped for missing ids=true")(t, o)
			},
		},
		{
			name: "播放侧记下了 Apple 目录 id:按它取", prepare: playingApple, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}), wantRequests: 1,
			check: want("应取自 am-lyrics", func(r amllResult) bool {
				return r.platform == "am-lyrics" && strings.Contains(r.lrc, "第一句") && r.matchTitle == "" &&
					r.pageURL == "https://github.com/amll-dev/amll-ttml-db/blob/main/am-lyrics/1440857781.ttml"
			}),
		},
		{
			name: "播放侧记下了 Spotify 曲目 id:按它取", prepare: playingSpotify, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"spotify-lyrics/" + amllParitySpotifyID: amllTestTTML}), wantRequests: 1,
			check: want("应取自 spotify-lyrics", func(r amllResult) bool { return r.platform == "spotify-lyrics" && !r.empty() }),
		},
		{
			name: "两个都记下、库里没有 Apple 那份:接着按 Spotify 的取", prepare: both, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"spotify-lyrics/" + amllParitySpotifyID: amllTestTTML}), wantRequests: 2,
			check: want("应取自 spotify-lyrics", func(r amllResult) bool { return r.platform == "spotify-lyrics" }),
		},
		{
			name: "两个都记下、Apple 那份取到了:不再问 Spotify 的", prepare: both, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML, "spotify-lyrics/" + amllParitySpotifyID: amllTestTTML}), wantRequests: 1,
			check: want("应取自 am-lyrics", func(r amllResult) bool { return r.platform == "am-lyrics" }),
		},
		{
			name: "别的歌那一轮:播放侧记下的编号不给", prepare: both, ctx: withOtherTrackRound, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}), wantRequests: 0,
			check: want("应是空的", func(r amllResult) bool { return r.empty() }),
		},
		{
			name: "播放器报的是繁体标签、检索词转成了简体:播放侧的编号按原样标签认",
			prepare: func(t *testing.T) {
				notePlayingAppleCatalogID("王力宏", "公轉自轉", "公轉.自轉", amllParityAppleID)
			},
			ctx: func(ctx context.Context) context.Context {
				return withSearchQueryOriginal(ctx, "王力宏", "公轉自轉", "公轉.自轉")
			},
			artist: "王力宏", title: "公转自转", album: "公转.自转", durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}), wantRequests: 1,
			check: want("应取自 am-lyrics", func(r amllResult) bool { return r.platform == "am-lyrics" }),
		},
		{
			name: "首选镜像没问成:换下一个镜像", prepare: playingApple, artist: artist, title: title, album: album, durationSecs: secs,
			handle: func(r parityRequest) parityReply {
				if r.Host == "raw.githubusercontent.com" {
					return parityStatus(http.StatusBadGateway)
				}
				if strings.HasSuffix(r.URL.Path, amllParityAppleFile) {
					return parityOK(amllTestTTML)
				}
				return parityStatus(http.StatusNotFound)
			},
			wantRequests: 2, check: want("应从备用镜像取到", func(r amllResult) bool { return r.platform == "am-lyrics" }),
		},
		{
			name: "三个镜像都没问成:问官方接口,TTML 包在 JSON 里", prepare: playingApple, artist: artist, title: title, album: album, durationSecs: secs,
			handle: func(r parityRequest) parityReply {
				if r.Host != "api.amll.dev" {
					return parityStatus(http.StatusBadGateway)
				}
				if r.URL.Query().Get("appleMusicId") != "1440857781" {
					return parityStatus(http.StatusNotFound)
				}
				b, _ := json.Marshal(map[string]any{"status": 200, "data": map[string]any{"id": 1, "lyrics": amllTestTTML, "format": "ttml"}})
				return parityOK(string(b))
			},
			wantRequests: 4, check: want("应从官方接口取到", func(r amllResult) bool { return r.platform == "am-lyrics" && !r.empty() }),
		},
		{
			name: "三个镜像都没问成、官方接口回 404:库里没有", prepare: playingApple, artist: artist, title: title, album: album, durationSecs: secs,
			handle: func(r parityRequest) parityReply {
				if r.Host != "api.amll.dev" {
					return parityStatus(http.StatusBadGateway)
				}
				return parityStatus(http.StatusNotFound)
			},
			wantRequests: 4, check: want("应是空的", func(r amllResult) bool { return r.empty() }),
		},
		{
			name: "取回来的 TTML 解不开:记一次解析漂移", prepare: playingApple, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": "<tt>不是歌词</tt>"}), wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				want("应是空的", func(r amllResult) bool { return r.empty() })(t, o)
				inState("ttml not parseable: am-lyrics/1440857781")(t, o)
			},
		},
		{
			name: "索引够新、编号不在索引里:不发请求", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				playingApple(t)
				amllParityIndex()(t)
			},
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}), wantRequests: 0,
			check: func(t *testing.T, o providerParityOutcome) {
				want("应是空的", func(r amllResult) bool { return r.empty() })(t, o)
				inState("amll skipped for missing ids=false")(t, o)
			},
		},
		{
			name: "索引够新、编号在索引里:照取", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				playingApple(t)
				amllParityIndex(amllIndexEntry{Titles: []string{"别的歌名"}, Apple: []string{"1440857781"}})(t)
			},
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}), wantRequests: 1,
			check: want("应取自 am-lyrics", func(r amllResult) bool { return r.platform == "am-lyrics" }),
		},
		{
			name: "索引里登记的编号取回来是 404:记一次解析漂移", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				playingApple(t)
				amllParityIndex(amllIndexEntry{Titles: []string{"别的歌名"}, Apple: []string{"1440857781"}})(t)
			},
			handle: parityNotFound, wantRequests: 1, check: inState("indexed id answered 404: am-lyrics/1440857781"),
		},
		{
			name: "手上没有编号、索引里按歌名歌手专辑找得到:报索引里的元数据,不带平台", prepare: amllParityIndex(indexed),
			artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/a1": amllTestTTML}), wantRequests: 1,
			check: want("应是按歌名找到的那份", func(r amllResult) bool {
				return !r.empty() && r.platform == "" && r.matchTitle == "突然好想你" && r.matchArtist == "五月天" && r.matchAlbum == "后青春期的诗" &&
					r.pageURL == "https://github.com/amll-dev/amll-ttml-db/blob/main/am-lyrics/a1.ttml"
			}),
		},
		{
			name: "按歌名找到的那份歌词长度对不上这首:不要", prepare: amllParityIndex(indexed),
			artist: artist, title: title, album: album, durationSecs: 400,
			handle: amllParityServe(map[string]string{"am-lyrics/a1": amllTestTTML}), wantRequests: 1,
			check: want("应是空的", func(r amllResult) bool { return r.empty() }),
		},
		{
			name: "没给专辑:不按歌名找", prepare: amllParityIndex(indexed), artist: artist, title: title, album: "", durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/a1": amllTestTTML}), wantRequests: 0,
			check: want("应是空的", func(r amllResult) bool { return r.empty() }),
		},
		{
			name:    "这条录音的 ISRC 在索引里:专辑对不上也按它找",
			prepare: amllParityIndex(amllIndexEntry{Titles: []string{"突然好想你"}, Artists: []string{"Mayday"}, Albums: []string{"别的专辑"}, ISRCs: []string{"TWA530887508"}, NCM: []string{"n9"}}),
			ctx:     func(ctx context.Context) context.Context { return withRecordingISRC(ctx, "tw-a53-08-87508") },
			artist:  artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"ncm-lyrics/n9": amllTestTTML}), wantRequests: 1,
			check: want("应是按 ISRC 找到的那份", func(r amllResult) bool {
				return !r.empty() && r.matchAlbum == "别的专辑" && r.matchArtist == "Mayday"
			}),
		},
		{
			name: "歌名带编号:在索引里按带编号的那份找", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: amllParityIndex(
				amllIndexEntry{Titles: []string{"突然好想你 (#3)"}, Artists: []string{"五月天"}, Albums: []string{"后青春期的诗"}, Apple: []string{"a3"}},
				amllIndexEntry{Titles: []string{"突然好想你 (#2)"}, Artists: []string{"五月天"}, Albums: []string{"后青春期的诗"}, Apple: []string{"a2"}},
			),
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "突然好想你 (#2)", artist, title, album)
			},
			handle: amllParityServe(map[string]string{"am-lyrics/a2": amllTestTTML, "am-lyrics/a3": amllTestTTML}), wantRequests: 1,
			check: want("应挑带同一个编号的那条", func(r amllResult) bool { return r.matchTitle == "突然好想你 (#2)" }),
		},
		{
			name: "行内译文有几种语言:按设置里的译文语言挑", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				playingApple(t)
				featuresRef().LyricsTranslationLanguage = "ja"
			},
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllMultiLangTTML}), wantRequests: 1,
			check: want("译文应是日语那一段", func(r amllResult) bool {
				return r.trLang == "ja" && strings.Contains(r.tr, "こんにちは")
			}),
		},
		{
			name: "连问两轮:没有进程内缓存,第二轮照样取", rounds: 2, prepare: playingApple, artist: artist, title: title, album: album, durationSecs: secs,
			handle: amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}), wantRequests: 2,
			check: want("应取自 am-lyrics", func(r amllResult) bool { return r.platform == "am-lyrics" }),
		},
		{
			name: "后台吃到 429:三个镜像和官方接口各问到一次,后台请求暂停", prepare: playingApple, ctx: withBackgroundOutbound,
			artist: artist, title: title, album: album, durationSecs: secs,
			handle:       func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) },
			wantRequests: 4, check: inState("background paused"),
		},
	}...)
	runProviderParity(t, amllParitySource, cases)
}

// amllParitySourceWithPlaybackID:同 amllParitySource,另外播放侧已经为这首记下 Apple 目录 id(取消用例要它真的发请求)。
func amllParitySourceWithPlaybackID(artist, title string) providerParitySource {
	s := amllParitySource
	reset := s.reset
	s.reset = func(t *testing.T) {
		reset(t)
		notePlayingAppleCatalogID(artist, title, "", amllParityAppleID)
	}
	return s
}

func TestAMLLProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, amllParitySourceWithPlaybackID("五月天", "突然好想你"), "五月天", "突然好想你", 210)
	waitLyricRoundGoroutinesGone(t)
}

func TestAMLLProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, amllParitySourceWithPlaybackID("五月天", "突然好想你"), "五月天", "突然好想你", 210,
		amllParityServe(map[string]string{"am-lyrics/1440857781": amllTestTTML}))
}
