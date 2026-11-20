package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// handwrittenQQRound:迁移前收集循环里 QQ 那个 goroutine 的整段(判跳过、认出这首、曲目 id 一到手就往通道里递、取整行与逐字、
// 封面、时长与语种、摊成结果),原样留着当参照。idCh 是那条带缓冲的通道。
func handwrittenQQRound(ctx context.Context, artist, srcTitle, album string, durationSecs float64, only map[string]bool, breakerPlan lyricSourceRoundPlan, round *lyricSourceRound, qqIDCh chan<- string) lyricSourceResult {
	if lyricSourceSkippedThisRound(ctx, "qq", only, breakerPlan, round) {
		qqIDCh <- ""
		return lyricSourceResult{source: "qq"}
	}
	match := qqMusicMatchCached(ctx, artist, srcTitle, album, durationSecs)
	qqMid := qqMidFromURL(match.url)
	qqIDCh <- qqMid
	var lyr, yrc, tr, roma string
	var qqDur float64
	var qqInstrumental, qqNoLyrics, qqPlainOnly bool
	var qqCover string
	if qqMid != "" {
		var qqLyr qqLyricResult
		lyricDone := make(chan struct{})
		go func() {
			defer close(lyricDone)
			qqLyr = qqLyric(ctx, qqMid)
		}()
		qrc := qqQRCLyric(ctx, qqMid, artist, srcTitle, album, durationSecs)
		qqCover, _, _ = qqSongCoverAndSinger(ctx, qqMid)
		<-lyricDone
		lyr, qqInstrumental, qqNoLyrics = qqLineLyric(qqLyr, qrc), qqLyr.instrumental, qqLyr.trackFoundNoLyrics
		if lyr == "" {
			if lyr = qqPlainLyric(qqLyr, qrc); lyr != "" {
				qqPlainOnly = true
			}
		}
		yrc, tr, roma = qrc.yrc, qrc.tr, qrc.roma
		lyr = attachKanaLine(lyr, qrc.kana)
		qqDur = match.interval
		if qqDur <= 0 {
			qqDur = qqSongMetaCachedOnly(qqMid).interval
		}
	}
	qqMeta := qqSongMetaCachedOnly(qqMid)
	qqLang := qqCanonicalLanguage(qqMeta)
	qqNoVocals := qqMeta.id != 0 && qqMeta.language == qqLanguagePureMusic
	return lyricSourceResult{source: "qq", lyr: lyr, yrc: yrc, tr: tr, roma: roma, matchTitle: match.title, matchArtist: match.artist, matchAlbum: match.album, matchCover: qqCover, srcDur: qqDur, language: qqLang, instrumental: qqInstrumental, noVocals: qqNoVocals, trackFoundNoLyrics: qqTrackFoundNoLyrics(qqNoLyrics, lyr, yrc), identityFromLocalClient: match.fromLocalLibrary, plainOnly: qqPlainOnly, trackIDs: qqTrackIDs(qqMid)}
}

// resetQQParityState 把 QQ 这一路的进程内状态(各级缓存、匿名会话、客户端曲库索引、本机逐字缓存的位置)换成空的,测完换回。
func resetQQParityState(t *testing.T) {
	t.Helper()
	qqURLMu.Lock()
	savedURL := qqURLCache
	qqURLCache = map[string]qqMusicMatch{}
	qqURLMu.Unlock()
	qqLyricMu.Lock()
	savedLyric := qqLyricCache
	qqLyricCache = map[string]qqLyricResult{}
	qqLyricMu.Unlock()
	qqSongDetailMu.Lock()
	savedDetail := qqSongDetailCache
	qqSongDetailCache = map[string]qqSongDetailInfo{}
	qqSongDetailMu.Unlock()
	qqSongMetaMu.Lock()
	savedMeta := qqSongMetaCache
	qqSongMetaCache = map[string]qqSongMeta{}
	qqSongMetaMu.Unlock()
	qqAlbumSongsMu.Lock()
	savedAlbumSongs := qqAlbumSongsCache
	qqAlbumSongsCache = map[string][]qqAlbumSong{}
	qqAlbumSongsMu.Unlock()
	qqAlbumNameMu.Lock()
	savedAlbumName := qqAlbumNameCache
	qqAlbumNameCache = map[string]string{}
	qqAlbumNameMu.Unlock()
	qqArtistAliasMu.Lock()
	savedAlias := qqArtistAliasCache
	qqArtistAliasCache = map[string]string{}
	qqArtistAliasMu.Unlock()
	qqSessionMu.Lock()
	savedSession, savedAt, savedFailedAt := qqSessionVal, qqSessionAt, qqSessionFailedAt
	qqSessionVal, qqSessionAt, qqSessionFailedAt = qqSessionInfo{}, time.Time{}, time.Time{}
	qqSessionMu.Unlock()
	savedRRCache := qqRRCacheOverride
	qqRRCacheOverride = filepath.Join(t.TempDir(), "no-qq-client", "rrdbcache.sqlite")
	t.Cleanup(func() {
		qqURLMu.Lock()
		qqURLCache = savedURL
		qqURLMu.Unlock()
		qqLyricMu.Lock()
		qqLyricCache = savedLyric
		qqLyricMu.Unlock()
		qqSongDetailMu.Lock()
		qqSongDetailCache = savedDetail
		qqSongDetailMu.Unlock()
		qqSongMetaMu.Lock()
		qqSongMetaCache = savedMeta
		qqSongMetaMu.Unlock()
		qqAlbumSongsMu.Lock()
		qqAlbumSongsCache = savedAlbumSongs
		qqAlbumSongsMu.Unlock()
		qqAlbumNameMu.Lock()
		qqAlbumNameCache = savedAlbumName
		qqAlbumNameMu.Unlock()
		qqArtistAliasMu.Lock()
		qqArtistAliasCache = savedAlias
		qqArtistAliasMu.Unlock()
		qqSessionMu.Lock()
		qqSessionVal, qqSessionAt, qqSessionFailedAt = savedSession, savedAt, savedFailedAt
		qqSessionMu.Unlock()
		qqRRCacheOverride = savedRRCache
	})
	resetQQLocalIndex(t, filepath.Join(t.TempDir(), "no-qq-client", "qqmusic.sqlite"))
	resetQQIPadLocalIndex(t, "")
}

// qqParityState:QQ 这一路各级缓存里的键、匿名会话的状态、按端点记的失败与拒绝计数。
func qqParityState() []string {
	var out []string
	qqSessionMu.Lock()
	out = append(out, fmt.Sprintf("session sid=%q failed=%v", qqSessionVal.sid, !qqSessionFailedAt.IsZero()))
	qqSessionMu.Unlock()
	qqLyricMu.Lock()
	for k, v := range qqLyricCache {
		out = append(out, fmt.Sprintf("lyric cache %s timed=%v instrumental=%v plain=%v", k, v.lrc != "", v.instrumental, v.plain != ""))
	}
	qqLyricMu.Unlock()
	qqSongDetailMu.Lock()
	for k := range qqSongDetailCache {
		out = append(out, "detail cache "+k)
	}
	qqSongDetailMu.Unlock()
	qqSongMetaMu.Lock()
	for k, v := range qqSongMetaCache {
		out = append(out, fmt.Sprintf("meta cache %s id=%d interval=%v language=%d", k, v.id, v.interval, v.language))
	}
	qqSongMetaMu.Unlock()
	qqAlbumSongsMu.Lock()
	for k, v := range qqAlbumSongsCache {
		out = append(out, fmt.Sprintf("album songs cache %s n=%d", k, len(v)))
	}
	qqAlbumSongsMu.Unlock()
	qqArtistAliasMu.Lock()
	for k, v := range qqArtistAliasCache {
		out = append(out, fmt.Sprintf("artist alias cache %s=%q", k, v))
	}
	qqArtistAliasMu.Unlock()
	sort.Strings(out[1:])
	return append(out, parityEndpointHealth(lyricSourceQQ)...)
}

// qqParitySource:QQ 的对拍。参照路径是迁移前那个 goroutine 的整段;递出去的曲目 id 和「一到手就递」的时点在三源联合对拍里比
// (lyricprovidertrackids_test.go),这里比结果和发出的请求。客户端曲库、本机逐字缓存默认指到不存在的路径,要它们的场景在
// prepare 里换成临时目录里合成的库。
var qqParitySource = providerParitySource{
	name: lyricSourceQQ,
	handwrittenRound: func(ctx context.Context, artist, srcTitle, album string, durationSecs float64, only map[string]bool, breakerPlan lyricSourceRoundPlan, round *lyricSourceRound) lyricSourceResult {
		return handwrittenQQRound(ctx, artist, srcTitle, album, durationSecs, only, breakerPlan, round, make(chan string, 1))
	},
	reset: resetQQParityState,
	cacheKeys: func() []string {
		qqURLMu.Lock()
		defer qqURLMu.Unlock()
		var keys []string
		for k := range qqURLCache {
			keys = append(keys, k)
		}
		return keys
	},
	state:   qqParityState,
	headers: []string{"Referer", "Cookie"},
}

// qqParityFake 按接口分发 QQ 的请求;没给的接口回 404。r.Host 是请求的主机。
type qqParityFake struct {
	// search:client_search_cp,q 是查询词;smartbox:smartbox_new.fcg(歌曲、专辑、歌手联想同一个接口)。
	search, smartbox func(r parityRequest, q string) parityReply
	// detail:单曲详情 fcg_play_single_song.fcg;lineLyric:整行歌词 fcg_query_lyric_new.fcg。mid 是 songmid。
	detail, lineLyric func(r parityRequest, mid string) parityReply
	// download:lyric_download.fcg(逐字的第二条路)。
	download func(r parityRequest) parityReply
	// musicu:客户端网关,method 是 request.method,param 是 request.param。
	musicu func(r parityRequest, method string, param map[string]any) parityReply
}

func (f qqParityFake) handler() func(parityRequest) parityReply {
	return func(r parityRequest) parityReply {
		q := r.URL.Query()
		switch {
		case r.URL.Path == "/soso/fcgi-bin/client_search_cp" && f.search != nil:
			return f.search(r, q.Get("w"))
		case r.URL.Path == "/splcloud/fcgi-bin/smartbox_new.fcg" && f.smartbox != nil:
			return f.smartbox(r, q.Get("key"))
		case r.URL.Path == "/v8/fcg-bin/fcg_play_single_song.fcg" && f.detail != nil:
			return f.detail(r, q.Get("songmid"))
		case r.URL.Path == "/lyric/fcgi-bin/fcg_query_lyric_new.fcg" && f.lineLyric != nil:
			return f.lineLyric(r, q.Get("songmid"))
		case r.URL.Path == "/qqmusic/fcgi-bin/lyric_download.fcg" && f.download != nil:
			return f.download(r)
		case r.URL.Path == "/cgi-bin/musicu.fcg" && f.musicu != nil:
			var body struct {
				Request struct {
					Method string         `json:"method"`
					Param  map[string]any `json:"param"`
				} `json:"request"`
			}
			if json.Unmarshal([]byte(r.body), &body) != nil {
				return parityStatus(http.StatusBadRequest)
			}
			return f.musicu(r, body.Request.Method, body.Request.Param)
		}
		return parityStatus(http.StatusNotFound)
	}
}

const (
	qqParityMid     = "002MiDaaaa0001"
	qqParityCover   = "https://y.qq.com/music/photo_new/T002R800x800M000alb1.jpg"
	qqParitySession = `{"session":{"uid":"1","sid":"s1","userip":"1.1.1.1"}}`
	qqParityNoSongs = `{"code":0,"data":{"song":{"list":[]}}}`
	qqParityNoBox   = `{"code":0,"data":{"song":{"itemlist":[]},"album":{"itemlist":[]},"singer":{"itemlist":[]}}}`
)

// qqParityHit:搜索结果里的一条。
type qqParityHit struct {
	mid, name, singer, album string
	interval                 int
}

func qqParitySearch(hits ...qqParityHit) parityReply {
	list := make([]map[string]any, 0, len(hits))
	for _, h := range hits {
		list = append(list, map[string]any{
			"mid": h.mid, "title": h.name, "interval": h.interval,
			"singer": []map[string]any{{"name": h.singer}}, "album": map[string]any{"name": h.album},
		})
	}
	b, _ := json.Marshal(map[string]any{"code": 0, "data": map[string]any{"song": map[string]any{"list": list}}})
	return parityOK(string(b))
}

// qqParityDetailRow:单曲详情里的一条(网页接口放在 data 数组里,网关放在 track_info 里)。
func qqParityDetailRow(id int64, interval, language int) string {
	return fmt.Sprintf(`{"id":%d,"interval":%d,"language":%d,"album":{"mid":"alb1","name":"后青春期的诗"},"singer":[{"mid":"sg1","name":"五月天"}]}`, id, interval, language)
}

func qqParityDetail(id int64, interval, language int) parityReply {
	return parityOK(`{"code":0,"data":[` + qqParityDetailRow(id, interval, language) + `]}`)
}

func qqParityLine(lyric string) parityReply {
	b, _ := json.Marshal(map[string]any{"retcode": 0, "code": 0, "lyric": lyric})
	return parityOK(string(b))
}

func TestQQProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "五月天", "突然好想你", "后青春期的诗"
	const secs = 265.4
	found := qqParityHit{qqParityMid, "突然好想你", "五月天", "后青春期的诗", 265}
	qrcCipher := qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCContent))
	kanaCipher := qqEncryptQRCForTest(t, qqTestQRCXML("[kana:1だい1いっ1く]\n"+qqTestQRCContent))
	transCipher := qqEncryptQRCForTest(t, qqTestTransLRC)
	romaCipher := qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCRoma))
	plainCipher := qqEncryptQRCForTest(t, "只有文字的第一句\n只有文字的第二句\n只有文字的第三句")
	// playLyric:网关 GetPlayLyricInfo 的两种问法。带 songMID 的是整行歌词的备用,带 songID 的是逐字、译文、罗马音。
	playLyric := func(line, qrc string) func(parityRequest, string, map[string]any) parityReply {
		return func(_ parityRequest, method string, param map[string]any) parityReply {
			switch {
			case method == "GetSession":
				return parityOK(musicuOK(qqParitySession))
			case method == "GetPlayLyricInfo" && param["songMID"] != nil && line != "":
				return parityOK(musicuOK(line))
			case method == "GetPlayLyricInfo" && param["songID"] != nil && qrc != "":
				return parityOK(musicuOK(qrc))
			}
			return parityStatus(http.StatusNotFound)
		}
	}
	fullQRC := `{"lyric":"` + qrcCipher + `","qrc_t":1,"lrc_t":0,"trans":"` + transCipher + `","roma":"` + romaCipher + `"}`
	onlyQRC := `{"lyric":"` + qrcCipher + `","qrc_t":1,"lrc_t":0,"trans":"","roma":""}`
	noQRC := `{"lyric":"","qrc_t":0,"lrc_t":0,"trans":"","roma":""}`
	hit := qqParityFake{
		search:    func(parityRequest, string) parityReply { return qqParitySearch(found) },
		detail:    func(parityRequest, string) parityReply { return qqParityDetail(97773, 265, 0) },
		lineLyric: func(parityRequest, string) parityReply { return qqParityLine(qqTestLRC) },
		musicu:    playLyric("", fullQRC),
	}
	with := func(mod func(f *qqParityFake)) func(parityRequest) parityReply {
		f := hit
		mod(&f)
		return f.handler()
	}
	want := func(what string, ok func(r lyricSourceResult) bool) func(t *testing.T, o providerParityOutcome) {
		return func(t *testing.T, o providerParityOutcome) {
			t.Helper()
			if !ok(o.result) {
				t.Errorf("%s:%+v", what, o.result)
			}
		}
	}
	matched := func(r lyricSourceResult) bool {
		return r.matchTitle == "突然好想你" && r.matchArtist == "五月天" && r.matchAlbum == "后青春期的诗" &&
			fmt.Sprint(r.trackIDs) == "["+qqParityMid+" 97773]"
	}
	local := func(t *testing.T) {
		resetQQLocalIndex(t, writeTestQQDB(t, []qqLocalRow{{Mid: "003LoCaLmid001", Name: "突然好想你", Singer: "五月天", Album: "后青春期的诗", MS: 265400}}))
	}
	searchedCache := func(t *testing.T) {
		qqURLMu.Lock()
		qqURLCache[artist+"|"+title+"|"+album+"|265"] = qqMusicMatch{url: qqSongURL("009SeArChed001"), title: "突然好想你", artist: "五月天", album: "缓存里搜来的那张"}
		qqURLMu.Unlock()
	}
	cases := append(providerParitySkipCases(artist, title, secs), []providerParityCase{
		{
			name: "搜索命中:整行、逐字、译文、罗马音、封面、时长、语种、两种曲目 ID", artist: artist, title: title, album: album, durationSecs: secs,
			handle: hit.handler(), wantRequests: 5, wantLyrics: true,
			check: want("各字段应齐", func(r lyricSourceResult) bool {
				return matched(r) && r.lyr == qqTestLRC && strings.Contains(r.yrc, "第") && r.tr == qqTestTransLRC && strings.HasPrefix(r.roma, "[00:00.000]ce shi") &&
					r.matchCover == qqParityCover && r.srcDur == 265 && r.language == songLanguageMandarin && !r.identityFromLocalClient && !r.noVocals
			}),
		},
		{
			name: "首选搜索主机没问成:换下一个主机", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(r parityRequest, _ string) parityReply {
					if r.Host == "c.y.qq.com" {
						return qqParitySearch(found)
					}
					return parityStatus(http.StatusBadGateway)
				}
			}),
			wantRequests: 6, wantLyrics: true, check: want("应从备用主机搜到", matched),
		},
		{
			name: "搜索接口回拒绝码:换下一个主机,记一次拒绝", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(r parityRequest, _ string) parityReply {
					if r.Host == "c.y.qq.com" {
						return qqParitySearch(found)
					}
					return parityOK(`{"code":500003,"data":{}}`)
				}
			}),
			wantRequests: 6, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !matched(o.result) || !strings.Contains(strings.Join(o.state, "\n"), "rejects=1") {
					t.Errorf("应从备用主机搜到、首选那个端点记一次拒绝:%+v\n%v", o.result, o.state)
				}
			},
		},
		{
			name: "两个搜索主机都没问成:退到客户端网关的搜索", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				inner := f.musicu
				f.musicu = func(r parityRequest, method string, param map[string]any) parityReply {
					if method == "DoSearchForQQMusicDesktop" {
						return parityOK(musicuOK(`{"body":{"song":{"list":[{"mid":"` + qqParityMid + `","title":"突然好想你","interval":265,"singer":[{"name":"五月天"}],"album":{"name":"后青春期的诗"}}]}}}`))
					}
					return inner(r, method, param)
				}
			}),
			wantRequests: 7, wantLyrics: true, check: want("应从网关搜到", matched),
		},
		{
			name: "正式搜索没有逐字同名的:补一次 smartbox", artist: artist, title: title, album: "", durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(parityRequest, string) parityReply {
					return qqParitySearch(qqParityHit{"004LiVeeee0001", "突然好想你 (Live)", "五月天", "诺亚方舟", 300})
				}
				f.smartbox = func(parityRequest, string) parityReply {
					return parityOK(`{"code":0,"data":{"song":{"itemlist":[{"mid":"` + qqParityMid + `","name":"突然好想你","singer":"五月天"}]},"album":{"itemlist":[]}}}`)
				}
			}),
			wantRequests: 6, wantLyrics: true,
			check: want("应挑 smartbox 补回来的逐字同名那条,时长读单曲详情的缓存", func(r lyricSourceResult) bool {
				return r.matchTitle == "突然好想你" && r.matchAlbum == "" && r.srcDur == 265 && fmt.Sprint(r.trackIDs) == "["+qqParityMid+" 97773]"
			}),
		},
		{
			name: "带歌手搜不到:只按歌名再搜", artist: "Mayday", title: title, album: "", durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(_ parityRequest, q string) parityReply {
					if q == "突然好想你" {
						return qqParitySearch(qqParityHit{qqParityMid, "突然好想你", "Mayday", "后青春期的诗", 265})
					}
					return parityOK(qqParityNoSongs)
				}
				f.smartbox = func(parityRequest, string) parityReply { return parityOK(qqParityNoBox) }
			}),
			wantRequests: 7, wantLyrics: true,
			check: want("应按歌名搜到", func(r lyricSourceResult) bool { return r.matchArtist == "Mayday" && r.lyr == qqTestLRC }),
		},
		{
			name: "歌名维度拿不出专辑证据:以专辑为锚,在曲目单里挑,时长用曲目单的", artist: artist, title: title, album: "诺亚方舟 现场", durationSecs: 300,
			handle: with(func(f *qqParityFake) {
				f.smartbox = func(parityRequest, string) parityReply {
					return parityOK(`{"code":0,"data":{"song":{"itemlist":[]},"album":{"itemlist":[{"mid":"albLive","name":"诺亚方舟 现场","singer":"五月天"}]}}}`)
				}
				inner := f.musicu
				f.musicu = func(r parityRequest, method string, param map[string]any) parityReply {
					if method == "GetAlbumSongList" {
						return parityOK(musicuOK(`{"songList":[{"songInfo":{"mid":"004LiVeeee0001","name":"突然好想你","interval":301,"singer":[{"name":"五月天"}]}}]}`))
					}
					return inner(r, method, param)
				}
			}),
			wantRequests: 7, wantLyrics: true,
			check: want("应是专辑曲目单里那条", func(r lyricSourceResult) bool {
				return r.matchAlbum == "诺亚方舟 现场" && r.srcDur == 301 && r.trackIDs[0] == "004LiVeeee0001"
			}),
		},
		{
			name: "专辑那条路没问成:回落到歌名维度那条,这份不进缓存", artist: artist, title: title, album: "诺亚方舟 现场", durationSecs: 300,
			handle: with(func(f *qqParityFake) {
				f.smartbox = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				inner := f.musicu
				f.musicu = func(r parityRequest, method string, param map[string]any) parityReply {
					if method == "DoSearchForQQMusicDesktop" {
						return parityStatus(http.StatusBadGateway)
					}
					return inner(r, method, param)
				}
			}),
			wantRequests: 23, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !matched(o.result) || len(o.cached) != 0 {
					t.Errorf("应回落到歌名维度那条、不进缓存:%+v 缓存 %v", o.result, o.cached)
				}
			},
		},
		{
			name: "没搜到这首", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(parityRequest, string) parityReply { return parityOK(qqParityNoSongs) }
				f.smartbox = func(parityRequest, string) parityReply { return parityOK(qqParityNoBox) }
			}),
			wantRequests: 6,
			check: want("应是空的", func(r lyricSourceResult) bool {
				return r.matchTitle == "" && r.trackIDs == nil && !r.trackFoundNoLyrics
			}),
		},
		{
			name: "整行接口三个主机都没问成:退到网关取整行", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				f.musicu = playLyric(`{"lyric":"`+base64.StdEncoding.EncodeToString([]byte(qqTestLRC))+`"}`, fullQRC)
			}),
			wantRequests: 8, wantLyrics: true,
			check: want("整行应取自网关", func(r lyricSourceResult) bool { return r.lyr == qqTestLRC && r.tr == qqTestTransLRC }),
		},
		{
			name: "整行接口回拒绝码:不当成没词,换主机", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(r parityRequest, _ string) parityReply {
					if r.Host == "c.y.qq.com" {
						return parityOK(`{"retcode":-1310,"code":-1310}`)
					}
					return qqParityLine(qqTestLRC)
				}
			}),
			wantRequests: 6, wantLyrics: true,
			check: want("整行应取自下一个主机", func(r lyricSourceResult) bool { return r.lyr == qqTestLRC && !r.trackFoundNoLyrics }),
		},
		{
			name: "整行接口说没词、逐字也没有:平台上有这首、没有歌词", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(parityRequest, string) parityReply {
					return parityOK(`{"retcode":-1901,"code":-1901,"subcode":-1901}`)
				}
				f.musicu = playLyric("", noQRC)
			}),
			wantRequests: 5,
			check: want("应是有歌没词", func(r lyricSourceResult) bool {
				return r.trackFoundNoLyrics && r.yrc == "" && matched(r) && r.matchCover == qqParityCover
			}),
		},
		{
			name: "整行接口说没词、逐字有:整行用逐字压出来的,不算没词", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(parityRequest, string) parityReply {
					return parityOK(`{"retcode":-1901,"code":-1901,"subcode":-1901}`)
				}
				f.musicu = playLyric("", onlyQRC)
			}),
			wantRequests: 5, wantLyrics: true,
			check: want("整行应是逐字压出来的", func(r lyricSourceResult) bool {
				return r.lyr == qqTestQRCLine && !r.trackFoundNoLyrics && r.yrc != "" && r.tr == ""
			}),
		},
		{
			name: "整行接口回纯音乐占位:带纯音乐结论,不拿逐字推翻", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(parityRequest, string) parityReply {
					return qqParityLine("[00:00:00]此歌曲为没有填词的纯音乐,请您欣赏")
				}
				f.musicu = playLyric("", noQRC)
			}),
			wantRequests: 5,
			check:        want("应是纯音乐", func(r lyricSourceResult) bool { return r.instrumental && !r.trackFoundNoLyrics && !r.plainOnly }),
		},
		{
			name: "只有不带时间戳的歌词:交纯文本", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(parityRequest, string) parityReply {
					return qqParityLine("第一句\n第二句\n第三句\n第四句")
				}
				f.musicu = playLyric("", noQRC)
			}),
			wantRequests: 5, wantLyrics: true,
			check: want("应是纯文本", func(r lyricSourceResult) bool {
				return r.plainOnly && strings.Contains(r.lyr, "第二句") && !r.trackFoundNoLyrics
			}),
		},
		{
			name: "整行接口没词、网关解出来的也只有文字:纯文本用网关那份", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.lineLyric = func(parityRequest, string) parityReply {
					return parityOK(`{"retcode":-1901,"code":-1901,"subcode":-1901}`)
				}
				f.musicu = playLyric("", `{"lyric":"`+plainCipher+`","qrc_t":0,"lrc_t":1,"trans":"","roma":""}`)
			}),
			wantRequests: 5, wantLyrics: true,
			check: want("应是网关那份纯文本", func(r lyricSourceResult) bool {
				return r.plainOnly && strings.Contains(r.lyr, "只有文字的第二句")
			}),
		},
		{
			name: "拿不到匿名会话:逐字改问 lyric_download,记下会话没拿到", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.musicu = func(parityRequest, string, map[string]any) parityReply { return parityStatus(http.StatusBadGateway) }
				f.download = func(r parityRequest) parityReply {
					if r.Host == "c.y.qq.com" {
						return parityStatus(http.StatusBadGateway)
					}
					return parityOK(qqTestLyricDownloadBody("0", qrcCipher, "[00:01.00]First line\n[00:02.00]Second line\n[00:03.00]Third line\n[00:04.00]Fourth line", romaCipher))
				}
			}),
			wantRequests: 8, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if r := o.result; !strings.Contains(r.yrc, "第") || !strings.HasPrefix(r.tr, "[00:01.00]First line") || !strings.Contains(strings.Join(o.state, "\n"), `session sid="" failed=true`) {
					t.Errorf("逐字、译文应取自 lyric_download,会话记成没拿到:%+v\n%v", r, o.state)
				}
			},
		},
		{
			name: "刚才没拿到会话、还在重试间隔里:不再问 GetSession", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				qqSessionMu.Lock()
				qqSessionFailedAt = time.Now()
				qqSessionMu.Unlock()
			},
			handle: with(func(f *qqParityFake) {
				f.download = func(parityRequest) parityReply { return parityOK(qqTestLyricDownloadBody("0", qrcCipher, "", "")) }
			}),
			wantRequests: 4, wantLyrics: true,
			check: want("逐字应取自 lyric_download", func(r lyricSourceResult) bool { return strings.Contains(r.yrc, "第") && r.tr == "" }),
		},
		{
			name: "手上有还没过期的会话:直接用", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				qqSessionMu.Lock()
				qqSessionVal, qqSessionAt = qqSessionInfo{uid: "9", sid: "kept", userip: "9.9.9.9"}, time.Now()
				qqSessionMu.Unlock()
			},
			handle: hit.handler(), wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.requests, "\n"), `"sid":"kept"`) || strings.Contains(strings.Join(o.requests, "\n"), "GetSession") {
					t.Errorf("应带着手上的会话问、不再取新的:%v", o.requests)
				}
			},
		},
		{
			name: "单曲详情三个网页主机都没问成:退到网关的详情", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.detail = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				inner := f.musicu
				f.musicu = func(r parityRequest, method string, param map[string]any) parityReply {
					if method == "get_song_detail_yqq" {
						return parityOK(musicuOK(`{"track_info":` + qqParityDetailRow(97773, 265, 1) + `}`))
					}
					return inner(r, method, param)
				}
			}),
			wantRequests: 8, wantLyrics: true,
			check: want("详情应取自网关(粤语)", func(r lyricSourceResult) bool {
				return r.language == songLanguageCantonese && r.matchCover == qqParityCover && strings.Contains(r.yrc, "第")
			}),
		},
		{
			name: "单曲详情哪条路都没问成:没有逐字、封面,只有整行和 songmid,不报语种", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.detail = func(parityRequest, string) parityReply { return parityStatus(http.StatusBadGateway) }
				f.musicu = func(parityRequest, string, map[string]any) parityReply { return parityStatus(http.StatusBadGateway) }
			}),
			wantRequests: 14, wantLyrics: true,
			check: want("应只有整行", func(r lyricSourceResult) bool {
				return r.lyr == qqTestLRC && r.yrc == "" && r.matchCover == "" && r.language == "" && !r.noVocals &&
					fmt.Sprint(r.trackIDs) == "["+qqParityMid+"]" && r.srcDur == 265
			}),
		},
		{
			name: "单曲详情的语种是纯音乐:带无人声标记", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.detail = func(parityRequest, string) parityReply { return qqParityDetail(97773, 265, qqLanguagePureMusic) }
			}),
			wantRequests: 5, wantLyrics: true,
			check: want("应带无人声标记", func(r lyricSourceResult) bool { return r.noVocals && r.language == "" }),
		},
		{
			name: "逐字正文带假名标注行:拼到整行歌词开头", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.detail = func(parityRequest, string) parityReply { return qqParityDetail(97773, 265, 3) }
				f.musicu = playLyric("", `{"lyric":"`+kanaCipher+`","qrc_t":1,"lrc_t":0,"trans":"","roma":"`+romaCipher+`"}`)
			}),
			wantRequests: 5, wantLyrics: true,
			check: want("整行应带假名行", func(r lyricSourceResult) bool {
				return strings.HasPrefix(r.lyr, "[kana:1だい1いっ1く]\n") && !strings.Contains(r.yrc, "kana") && r.roma != ""
			}),
		},
		{
			name: "搜索结果没带时长:时长读单曲详情的缓存", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(parityRequest, string) parityReply {
					return qqParitySearch(qqParityHit{qqParityMid, "突然好想你", "五月天", "后青春期的诗", 0})
				}
				f.detail = func(parityRequest, string) parityReply { return qqParityDetail(97773, 266, 0) }
			}),
			wantRequests: 5, wantLyrics: true,
			check: want("时长应是详情里的", func(r lyricSourceResult) bool { return r.srcDur == 266 }),
		},
		{
			name: "单曲详情没带时长:取逐字时报的是本地时长", artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.detail = func(parityRequest, string) parityReply { return qqParityDetail(97773, 0, 0) }
			}),
			wantRequests: 5, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.requests, "\n"), `"interval":265,`) || o.result.srcDur != 265 {
					t.Errorf("取逐字的请求应带本地时长,结果的时长用搜索结果里的:%+v\n%v", o.result, o.requests)
				}
			},
		},
		{
			name: "客户端曲库认得出这首:不搜,身份算本机给的", prepare: local, artist: artist, title: title, album: album, durationSecs: secs,
			handle:       with(func(f *qqParityFake) { f.search = nil }),
			wantRequests: 4, wantLyrics: true,
			check: want("应带本机身份", func(r lyricSourceResult) bool {
				return r.identityFromLocalClient && r.trackIDs[0] == "003LoCaLmid001" && r.srcDur == 265.4
			}),
		},
		{
			name: "别的歌那一轮:客户端曲库给的 songmid 照用,不算本机身份", prepare: local, ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: secs,
			handle:       with(func(f *qqParityFake) { f.search = nil }),
			wantRequests: 4, wantLyrics: true,
			check: want("不该带本机身份", func(r lyricSourceResult) bool {
				return !r.identityFromLocalClient && r.trackIDs[0] == "003LoCaLmid001"
			}),
		},
		{
			name: "在放的这首、进程内缓存里是搜来的那份:先问客户端曲库", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				local(t)
				searchedCache(t)
			},
			handle:       with(func(f *qqParityFake) { f.search = nil }),
			wantRequests: 4, wantLyrics: true,
			check: want("应换成本机认出的那一条", func(r lyricSourceResult) bool { return r.identityFromLocalClient && r.trackIDs[0] == "003LoCaLmid001" }),
		},
		{
			name: "别的歌那一轮、进程内缓存里是搜来的那份:照用缓存", ctx: withOtherTrackRound,
			artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) {
				local(t)
				searchedCache(t)
			},
			handle:       with(func(f *qqParityFake) { f.search = nil }),
			wantRequests: 4, wantLyrics: true,
			check: want("应照用缓存", func(r lyricSourceResult) bool {
				return r.trackIDs[0] == "009SeArChed001" && r.matchAlbum == "缓存里搜来的那张"
			}),
		},
		{
			name: "国语歌、QQ 客户端的本机缓存里有逐字:先用本机那份,不问网关", artist: artist, title: title, album: album, durationSecs: secs,
			prepare: func(t *testing.T) { qqRRCacheFixture(t, false, qqLocalCacheEntriesForTest(t, "97773")) },
			handle:  hit.handler(), wantRequests: 3, wantLyrics: true,
			check: want("逐字、译文应取自本机缓存", func(r lyricSourceResult) bool {
				return strings.Contains(r.yrc, "第") && r.tr == qqTestTransLRC && r.roma == ""
			}),
		},
		{
			name: "连问两轮:第二轮各级都读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: secs,
			handle: hit.handler(), wantRequests: 6, wantLyrics: true, check: want("各字段应齐", matched),
		},
		{
			name: "歌名带编号:交给源去搜、去取逐字的是带编号的那份", artist: artist, title: title, album: album, durationSecs: secs,
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "突然好想你 (#2)", artist, title, album)
			},
			handle: with(func(f *qqParityFake) {
				f.search = func(parityRequest, string) parityReply {
					return qqParitySearch(found, qqParityHit{"005NuMbEr00002", "突然好想你 (#2)", "五月天", "后青春期的诗", 265})
				}
			}),
			wantRequests: 6, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				songName := base64.StdEncoding.EncodeToString([]byte("突然好想你 (#2)"))
				if o.result.trackIDs[0] != "005NuMbEr00002" || !strings.Contains(strings.Join(o.requests, "\n"), `"songName":"`+songName+`"`) {
					t.Errorf("应挑带同一个编号的那条,取逐字时报的歌名也带编号:%+v\n%v", o.result, o.requests)
				}
			},
		},
		{
			name: "后台吃到 429:问到的六个主机各一次,后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: secs,
			handle: with(func(f *qqParityFake) {
				f.search = func(parityRequest, string) parityReply { return parityStatus(http.StatusTooManyRequests) }
				f.smartbox, f.musicu = f.search, func(parityRequest, string, map[string]any) parityReply {
					return parityStatus(http.StatusTooManyRequests)
				}
			}),
			wantRequests: 6, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused") {
					t.Errorf("应记下后台暂停:%v", o.state)
				}
			},
		},
	}...)
	runProviderParity(t, qqParitySource, cases)
}

func TestQQProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, qqParitySource, "五月天", "突然好想你", 265.4)
	// amll 等着这个源递编号:请求断掉、编号递出来之后它才走完。
	waitLyricRoundGoroutinesGone(t)
}

func TestQQProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, qqParitySource, "五月天", "突然好想你", 265.4, parityNotFound)
}
