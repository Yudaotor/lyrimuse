package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

var vibeParitySource = providerParitySource{
	name: lyricSourceVibe,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := vibeLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "vibe", lyr: r.lyrics, tr: r.tr, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs, plainOnly: r.plainOnly}
	},
	reset: func(t *testing.T) {
		vibeMu.Lock()
		saved := vibeCache
		vibeCache = map[string]vibeResult{}
		vibeMu.Unlock()
		t.Cleanup(func() {
			vibeMu.Lock()
			vibeCache = saved
			vibeMu.Unlock()
		})
	},
	cacheKeys: func() []string {
		vibeMu.Lock()
		defer vibeMu.Unlock()
		var keys []string
		for k := range vibeCache {
			keys = append(keys, k)
		}
		return keys
	},
}

const (
	vibeParityEmpty = `{"response":{"result":{"tracks":[]}}}`
	vibeParityPlain = `{"response":{"result":{"lyric":{"hasSyncLyric":false,"normalLyric":{"text":"하나\n둘"}}}}}`
	// 外语歌:原文一份、韩文译文一份。
	vibeParityForeignSearch = `{"response":{"result":{"tracks":[{"trackId":41,"trackTitle":"Blinding Lights","artists":[{"artistName":"The Weeknd"}],` +
		`"album":{"albumTitle":"After Hours","imageUrl":"https://musicmeta-phinf.pstatic.net/album/4.jpg?type=r480Fll"},"playTime":"03:20","hasLyric":true,"hasSyncLyric":true}]}}}`
	vibeParityForeignSync = `{"response":{"result":{"lyric":{"hasSyncLyric":true,"syncLyric":{"startTimeIndex":[1,2,3,4],` +
		`"contents":[{"languageType":"default","text":["Yeah","I've been tryna call","I've been on my own","for long enough"]},{"languageType":"ko","text":["예","전화하려 했어","혼자였어","충분히 오래"]}]}}}}}`
)

func vibeIsSearch(r parityRequest) bool { return strings.HasSuffix(r.target, "/v4/search/track") }

// vibeParityHit:哪条检索词都给同一份结果,两条候选都取得到带同步的歌词。
func vibeParityHit(r parityRequest) parityReply {
	switch {
	case vibeIsSearch(r):
		return parityOK(vibeTestSearch)
	case strings.Contains(r.target, "/vibe/v4/lyric/"):
		return parityOK(vibeTestSync)
	}
	return parityStatus(http.StatusNotFound)
}

func TestVibeProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title, album = "아이유", "밤편지", "밤편지"
	cases := []providerParityCase{
		{
			name: "「歌名 歌手」那条就命中", artist: artist, title: title, album: album, durationSecs: 253,
			handle: vibeParityHit, wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if r.matchTitle != "밤편지" || r.matchArtist != "아이유(IU)" || r.matchAlbum != "밤편지" || r.srcDur != 253 ||
					r.matchCover != "https://musicmeta-phinf.pstatic.net/album/1.jpg" || r.plainOnly || r.tr != "" {
					t.Errorf("歌名、歌手、专辑、时长、封面都该带上,韩文歌没有译文:%+v", r)
				}
			},
		},
		{
			name: "带歌手的一条都没有,只按歌名的命中", artist: artist, title: title, album: album, durationSecs: 253,
			handle: func(r parityRequest) parityReply {
				if vibeIsSearch(r) && r.URL.Query().Get("query") == "밤편지 아이유" {
					return parityOK(vibeParityEmpty)
				}
				return vibeParityHit(r)
			},
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "哪一条都没搜到", artist: artist, title: title, album: album, durationSecs: 253,
			handle: func(parityRequest) parityReply { return parityOK(vibeParityEmpty) }, wantRequests: 2,
		},
		{
			name: "搜索没问成", artist: artist, title: title, album: album, durationSecs: 253,
			handle: func(parityRequest) parityReply { return parityStatus(http.StatusBadGateway) }, wantRequests: 1,
		},
		{
			name: "外语歌:韩文译文进译文轨", artist: "The Weeknd", title: "Blinding Lights", album: "After Hours", durationSecs: 200,
			handle: func(r parityRequest) parityReply {
				if vibeIsSearch(r) {
					return parityOK(vibeParityForeignSearch)
				}
				return parityOK(vibeParityForeignSync)
			},
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(o.result.tr, "전화하려 했어") || !strings.Contains(o.result.lyr, "I've been tryna call") {
					t.Errorf("原文进正文、韩文进译文:%+v", o.result)
				}
			},
		},
		{
			name: "第一名只有纯文本,第二名有同步", artist: "IU", title: title, durationSecs: 253,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/vibe/v4/lyric/11") {
					return parityOK(vibeParityPlain)
				}
				return vibeParityHit(r)
			},
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.plainOnly || o.result.matchAlbum != "Palette" {
					t.Errorf("应挑第二名带同步的那份:%+v", o.result)
				}
			},
		},
		{
			name: "全都只有纯文本:交第一名的,标 plainOnly", artist: "IU", title: title, durationSecs: 253,
			handle: func(r parityRequest) parityReply {
				if vibeIsSearch(r) {
					return parityOK(vibeTestSearch)
				}
				return parityOK(vibeParityPlain)
			},
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !o.result.plainOnly || o.result.lyr != "하나\n둘" || o.result.matchAlbum != "밤편지" {
					t.Errorf("应交第一名的纯文本:%+v", o.result)
				}
			},
		},
		{
			name: "第一名取词 502:退到第二名,不进缓存", artist: "IU", title: title, durationSecs: 253,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/vibe/v4/lyric/11") {
					return parityStatus(http.StatusBadGateway)
				}
				return vibeParityHit(r)
			},
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 0 || o.result.matchAlbum != "Palette" {
					t.Errorf("退到第二名、这一轮不完整不进缓存:%v %+v", o.cached, o.result)
				}
			},
		},
		{
			name: "第一名 403(19 禁):退到第二名,算答了、进缓存", artist: "IU", title: title, durationSecs: 253,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/vibe/v4/lyric/11") {
					return parityReply{status: http.StatusForbidden, body: `{"response":{"message":{"apiStatusCode":"NO_PERMISSON"}}}`}
				}
				return vibeParityHit(r)
			},
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 {
					t.Errorf("403 是答了没有,这一轮完整:%v", o.cached)
				}
			},
		},
		{
			name: "清理过的两条都没过闸:按原样的歌名再搜一次", artist: "Taylor Swift & Bon Iver", title: "evermore (feat. Bon Iver)", album: "evermore", durationSecs: 304,
			handle: func(r parityRequest) parityReply {
				switch {
				case vibeIsSearch(r) && r.URL.Query().Get("query") == "evermore (feat. Bon Iver)":
					return parityOK(`{"response":{"result":{"tracks":[{"trackId":31,"trackTitle":"evermore (Feat. Bon Iver)","artists":[{"artistName":"Taylor Swift"}],"album":{"albumTitle":"evermore"},"playTime":"05:04","hasLyric":true,"hasSyncLyric":true}]}}}`)
				case vibeIsSearch(r):
					return parityOK(`{"response":{"result":{"tracks":[{"trackId":32,"trackTitle":"willow","artists":[{"artistName":"Taylor Swift"}],"album":{"albumTitle":"evermore"},"playTime":"03:34","hasLyric":true,"hasSyncLyric":true}]}}}`)
				}
				return parityOK(vibeTestSync)
			},
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: album, durationSecs: 253,
			handle: vibeParityHit, wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "아이유|밤편지|밤편지|253" {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑和取整的时长:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "밤편지 (#2)", artist, title, album)
			},
			artist: artist, title: title, album: album, durationSecs: 253,
			handle: func(r parityRequest) parityReply {
				if vibeIsSearch(r) {
					return parityOK(strings.ReplaceAll(vibeTestSearch, `"trackTitle":"밤편지"`, `"trackTitle":"밤편지 (#2)"`))
				}
				return parityOK(vibeTestSync)
			},
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "밤편지 (#2)" || len(o.cached) != 1 || !strings.HasPrefix(o.cached[0], "아이유|밤편지 (#2)|") {
					t.Errorf("应挑中带编号的那条、缓存的键也按带编号的歌名:%+v %v", o.result, o.cached)
				}
			},
		},
		{
			name: "后台吃到 429:后台请求暂停", ctx: withBackgroundOutbound, artist: artist, title: title, album: album, durationSecs: 253,
			handle: func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) }, wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused apis.naver.com") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 253)...)
	runProviderParity(t, vibeParitySource, cases)
}

func TestVibeProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, vibeParitySource, "아이유", "밤편지", 253)
}

func TestVibeProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, vibeParitySource, "아이유", "밤편지", 253, vibeParityHit)
}
