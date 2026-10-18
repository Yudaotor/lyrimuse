package main

import (
	"net/http"
	"strings"
	"testing"
)

func TestVibeSongTitleStripsReadingSuffix(t *testing.T) {
	for in, want := range map[string]string{
		"晴天(청천)": "晴天",
		"夜に駆ける (밤을 달리다, Into The Night / Yoru ni Kakeru)": "夜に駆ける",
		"밤편지 (Through the Night)":                         "밤편지 (Through the Night)", // 韩文歌名自己的括号留着
		"晴天 (Live)":                                       "晴天 (Live)",               // 没有韩文的括号留着
		"Lemon (라이브 버전)":                                  "Lemon (라이브 버전)",          // 版本说明留着
		"夜に駆ける (MR)":                                      "夜に駆ける (MR)",
		"Blinding Lights":                                 "Blinding Lights",
		"그대에게 (다시 만나)":                                    "그대에게 (다시 만나)", // 韩文歌名带韩文括号也留着
	} {
		if got := vibeSongTitle(in); got != want {
			t.Errorf("vibeSongTitle(%q) = %q,期望 %q", in, got, want)
		}
	}
}

func TestVibePlayTimeSecs(t *testing.T) {
	for in, want := range map[string]float64{"03:21": 201, "04:25": 265, "1:02:03": 3723, "00:00": 0, "": 0, "3:x": 0} {
		if got := vibePlayTimeSecs(in); got != want {
			t.Errorf("vibePlayTimeSecs(%q) = %v,期望 %v", in, got, want)
		}
	}
}

func TestVibeBuildLRCAndTranslation(t *testing.T) {
	starts := []float64{13.7, 27.67, 30.31, 29}
	orig := []string{"Yeah", "I've been tryna call", "", "倒退的一句"}
	ko := []string{"", "자꾸만 전화기를 들어요", "", "x"}
	if got, want := vibeBuildLRC(starts, orig), "[00:13.70]Yeah\n[00:27.67]I've been tryna call\n[00:30.31]\n"; got != want {
		t.Errorf("正文 = %q,期望 %q(空句只留时间戳、时间倒退的丢掉)", got, want)
	}
	if got, want := vibeBuildTranslation(starts, ko), "[00:27.67]자꾸만 전화기를 들어요\n"; got != want {
		t.Errorf("译文 = %q,期望 %q(没译的句子不写)", got, want)
	}
}

func TestVibeLyricTracksPicksOriginalAndKorean(t *testing.T) {
	orig, ko := vibeLyricTracks([]vibeLyricContent{{LanguageType: "default", Text: []string{"a"}}, {LanguageType: "ko", Text: []string{"가"}}})
	if len(orig) != 1 || orig[0] != "a" || len(ko) != 1 || ko[0] != "가" {
		t.Errorf("外语歌: 原文 %v / 译文 %v", orig, ko)
	}
	orig, ko = vibeLyricTracks([]vibeLyricContent{{LanguageType: "ko", Text: []string{"가"}}})
	if len(orig) != 1 || orig[0] != "가" || ko != nil {
		t.Errorf("只有韩文那一份时它就是原文、没有译文: 原文 %v / 译文 %v", orig, ko)
	}
}

func vibeItem(title, artist, album, playTime string) vibeSearchItem {
	it := vibeSearchItem{TrackID: 1, Title: title, PlayTime: playTime, HasLyric: true, HasSyncLyric: true}
	for _, a := range strings.Split(artist, ", ") {
		it.Artists = append(it.Artists, vibeArtist{Name: a})
	}
	it.Album.Title = album
	return it
}

func TestVibeCandidateScoreGates(t *testing.T) {
	cases := []struct {
		name  string
		item  vibeSearchItem
		local [3]string
		dur   float64
		ok    bool
	}{
		{"本名(英文名) 对英文名", vibeItem("밤편지", "아이유(IU)", "밤편지", "04:13"), [3]string{"IU", "밤편지", ""}, 253, true},
		{"本名(英文名) 对本名", vibeItem("밤편지", "아이유(IU)", "밤편지", "04:13"), [3]string{"아이유", "밤편지", ""}, 253, true},
		{"多人署名", vibeItem("STAY", "The Kid LAROI, Justin Bieber", "STAY", "02:20"), [3]string{"The Kid LAROI & Justin Bieber", "STAY", ""}, 141, true},
		{"歌手音译对不上、同名同专辑时长吻合", vibeItem("晴天(청천)", "주걸륜", "葉惠美", "04:30"), [3]string{"周杰伦", "晴天", "叶惠美"}, 269.5, true},
		{"歌手对不上、专辑也对不上", vibeItem("晴天(청천)", "주걸륜", "Greatest Hits", "04:30"), [3]string{"周杰伦", "晴天", "叶惠美"}, 269.5, false},
		{"别的歌手同名歌", vibeItem("밤편지", "모두의MR", "MR 반주", "04:11"), [3]string{"IU", "밤편지", ""}, 253, false},
		{"现场版对录音室", vibeItem("晴天 (Live)", "주걸륜", "2004無與倫比演唱會 (Live)", "04:58"), [3]string{"주걸륜", "晴天", "叶惠美"}, 269, false},
		{"时长差太多", vibeItem("밤편지", "아이유(IU)", "밤편지", "06:13"), [3]string{"IU", "밤편지", ""}, 253, false},
		{"没有歌词", func() vibeSearchItem {
			it := vibeItem("밤편지", "아이유(IU)", "밤편지", "04:13")
			it.HasLyric, it.HasSyncLyric = false, false
			return it
		}(), [3]string{"IU", "밤편지", ""}, 253, false},
	}
	for _, c := range cases {
		got := vibeCandidateScore(c.item, c.local[0], c.local[1], c.local[2], c.dur) >= 0
		if got != c.ok {
			t.Errorf("%s: 过闸 = %v,期望 %v", c.name, got, c.ok)
		}
	}
	// 同样过闸时有同步歌词、时长更贴近的分高。
	a := vibeCandidateScore(vibeItem("밤편지", "아이유(IU)", "밤편지", "04:13"), "IU", "밤편지", "", 253)
	b := vibeCandidateScore(vibeItem("밤편지", "아이유(IU)", "밤편지", "04:40"), "IU", "밤편지", "", 253)
	if a <= b {
		t.Errorf("时长贴近的应该分高: %d vs %d", a, b)
	}
}

func TestVibeCoverURLDropsResizeQuery(t *testing.T) {
	if got := vibeCoverURL("https://musicmeta-phinf.pstatic.net/album/002/923/2923941.jpg?type=r480Fll&v=1"); got != "https://musicmeta-phinf.pstatic.net/album/002/923/2923941.jpg" {
		t.Errorf("去掉缩放参数拿原图: %q", got)
	}
	if got := vibeCoverURL("http://example.com/a.jpg"); got != "" {
		t.Errorf("不是 https 的不要: %q", got)
	}
}

const vibeTestSearch = `{"response":{"result":{"tracks":[` +
	`{"trackId":11,"trackTitle":"밤편지","artists":[{"artistName":"아이유(IU)"}],"album":{"albumTitle":"밤편지","imageUrl":"https://musicmeta-phinf.pstatic.net/album/1.jpg?type=r480Fll"},"playTime":"04:13","hasLyric":true,"hasSyncLyric":true},` +
	`{"trackId":12,"trackTitle":"밤편지","artists":[{"artistName":"아이유(IU)"}],"album":{"albumTitle":"Palette","imageUrl":""},"playTime":"04:14","hasLyric":true,"hasSyncLyric":true}]}}}`

const vibeTestSync = `{"response":{"result":{"lyric":{"hasSyncLyric":true,"syncLyric":{"startTimeIndex":[1,2,3,4],` +
	`"contents":[{"languageType":"ko","text":["하나","둘","셋","넷"]}]}}}}}`

func TestResolveVibeLyricEndToEnd(t *testing.T) {
	var queries []string
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/vibeWeb/musicapiweb/v4/search/track"):
			q := r.URL.Query().Get("query")
			queries = append(queries, q)
			if q == "밤편지 아이유" {
				return http.StatusOK, `{"response":{"result":{"tracks":[]}}}`
			}
			return http.StatusOK, vibeTestSearch
		case strings.HasSuffix(target, "/vibe/v4/lyric/11"):
			return http.StatusOK, vibeTestSync
		}
		return http.StatusNotFound, ""
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := resolveVibeLyric(ctx, "아이유", "밤편지", "밤편지", 253)
	if len(queries) != 2 || queries[1] != "밤편지" {
		t.Fatalf("「歌名 歌手」一条都没有时只按歌名再搜一次: %v", queries)
	}
	if !strings.HasPrefix(r.lyrics, "[00:01.00]하나\n") || r.plainOnly || r.tr != "" {
		t.Fatalf("韩文原文就是正文、没有译文: %+v", r)
	}
	if r.title != "밤편지" || r.artist != "아이유(IU)" || r.album != "밤편지" || r.durationSecs != 253 ||
		r.cover != "https://musicmeta-phinf.pstatic.net/album/1.jpg" {
		t.Errorf("元数据: %+v", r)
	}
	if !sub.complete(ctx) {
		t.Errorf("都问成了应算完整")
	}
}

func TestResolveVibeLyricPlainAndRankedFailure(t *testing.T) {
	for _, c := range []struct {
		name         string
		firstDown    bool
		wantPlain    bool
		wantComplete bool
	}{
		{"第一名只有纯文本、第二名有同步", false, false, true},
		{"第一名没问成、退到第二名", true, false, false},
	} {
		withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/v4/search/track"):
				return http.StatusOK, vibeTestSearch
			case strings.HasSuffix(target, "/vibe/v4/lyric/11"):
				if c.firstDown {
					return http.StatusBadGateway, ""
				}
				return http.StatusOK, `{"response":{"result":{"lyric":{"hasSyncLyric":false,"normalLyric":{"text":"하나\n둘"}}}}}`
			case strings.HasSuffix(target, "/vibe/v4/lyric/12"):
				return http.StatusOK, vibeTestSync
			}
			return http.StatusNotFound, ""
		})
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		r := resolveVibeLyric(ctx, "IU", "밤편지", "", 253)
		if r.lyrics == "" || r.plainOnly != c.wantPlain || r.album != "Palette" {
			t.Errorf("%s: 应挑第二名带同步的那份: %+v", c.name, r)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("%s: complete = %v,期望 %v", c.name, got, c.wantComplete)
		}
	}
	// 全都只有纯文本:交名次最高的那份,plainOnly。
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		if strings.HasSuffix(target, "/v4/search/track") {
			return http.StatusOK, vibeTestSearch
		}
		return http.StatusOK, `{"response":{"result":{"lyric":{"hasSyncLyric":false,"normalLyric":{"text":"하나\n둘"}}}}}`
	})
	r := resolveVibeLyric(qqRoundCtx(), "IU", "밤편지", "", 253)
	if !r.plainOnly || r.lyrics != "하나\n둘" || r.album != "밤편지" {
		t.Errorf("全是纯文本时交第一名的纯文本: %+v", r)
	}
}

// 组装 vibe 候选:韩文译文只在译文语言是韩文时写进结果、记 ko;只有纯文本的交 plainOnly(分数恒 -1)。
func TestRankLyricSourceResultsVibe(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	var lrc, tr strings.Builder
	for i := 0; i < 20; i++ {
		ts := formatLRCStamp((10 + i*10) * 1000)
		lrc.WriteString(ts + "Line " + string(rune('A'+i)) + "\n")
		tr.WriteString(ts + "번역 " + string(rune('A'+i)) + "\n")
	}
	find := func(r lyricSourceResult) scoredLyricCandidateResult {
		r.source = "vibe"
		for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, map[string]lyricSourceResult{"vibe": r}) {
			if c.Source == "vibe" {
				return c
			}
		}
		t.Fatal("没有 vibe 候选")
		return scoredLyricCandidateResult{}
	}
	setFeatures(featureFlags{LyricsTranslationLanguage: "ko"})
	if c := find(lyricSourceResult{lyr: lrc.String(), tr: tr.String(), srcDur: 220}); c.LyricsTr == "" || c.LyricsTrLang != "ko" {
		t.Errorf("译文语言是韩文时写进结果、记 ko: tr=%v lang=%q", c.LyricsTr != "", c.LyricsTrLang)
	}
	setFeatures(featureFlags{LyricsTranslationLanguage: "en"})
	if c := find(lyricSourceResult{lyr: lrc.String(), tr: tr.String(), srcDur: 220}); c.LyricsTr != "" {
		t.Errorf("译文语言不是韩文时不写: lang=%q", c.LyricsTrLang)
	}
	if c := find(lyricSourceResult{lyr: "하나\n둘\n셋", plainOnly: true}); !c.PlainTextOnly || c.Score >= 0 {
		t.Errorf("只有纯文本的交 plainOnly、分数恒 -1: plain=%v score=%d", c.PlainTextOnly, c.Score)
	}
}

func TestVibeQueryText(t *testing.T) {
	for in, want := range map[string]string{
		"LOVE (feat. BUMKEY & Paloalto)":            "LOVE",
		"Mine Tonight (Feat. JINBO the SuperFreak)": "Mine Tonight",
		"attention (with Justin Bieber)":            "attention",
		"Stay With Me feat. Nicki Minaj":            "Stay With Me",
		"I Don't Love You":                          "I Dont Love You",
		"KUNICHI’S CALL":                            "KUNICHIS CALL",
		"Me & You":                                  "Me You",
		"주문(MIROTIC)":                               "주문(MIROTIC)",
		"MOONLIGHT SUNRISE (Jonas Blue Remix)":      "MOONLIGHT SUNRISE (Jonas Blue Remix)",
		"Without You":                               "Without You",
		"반타01 & MPT":                                "반타01 MPT",
	} {
		if got := vibeQueryText(in); got != want {
			t.Errorf("vibeQueryText(%q) = %q,期望 %q", in, got, want)
		}
	}
}

func TestVibeCandidateScoreAdultAndAbsoluteDuration(t *testing.T) {
	it := vibeItem("가끔 난 날 안 믿어", "씨잼", "킁", "03:20")
	if vibeCandidateScore(it, "씨잼", "가끔 난 날 안 믿어", "", 200) < 0 {
		t.Fatal("普通曲目应过闸")
	}
	it.IsAdult = true
	if vibeCandidateScore(it, "씨잼", "가끔 난 날 안 믿어", "", 200) >= 0 {
		t.Error("19 禁曲目取不到词,不该选")
	}
	// 211 秒对 228 秒:比例只差 7%,但差了 17 秒,是另一版
	if vibeCandidateScore(vibeItem("Heaven", "에일리(Ailee)", "Heaven", "03:31"), "Ailee", "Heaven", "", 228) >= 0 {
		t.Error("时长差超过 8 秒应淘汰")
	}
	if vibeCandidateScore(vibeItem("Heaven", "에일리(Ailee)", "Heaven", "03:31"), "Ailee", "Heaven", "", 218) < 0 {
		t.Error("差 7 秒仍在容差里")
	}
}

func TestResolveVibeLyricQueryCleanupAndForbidden(t *testing.T) {
	const search = `{"response":{"result":{"tracks":[` +
		`{"trackId":21,"trackTitle":"Love (Feat. Bumkey, Paloalto)","artists":[{"artistName":"프라이머리"}],"album":{"albumTitle":"LP"},"playTime":"04:22","hasLyric":true,"hasSyncLyric":true},` +
		`{"trackId":22,"trackTitle":"Love (Feat. Bumkey, Paloalto)","artists":[{"artistName":"프라이머리"}],"album":{"albumTitle":"Part 3"},"playTime":"04:21","hasLyric":true,"hasSyncLyric":true}]}}}`
	for _, c := range []struct {
		name         string
		status       int
		wantComplete bool
	}{
		{"第一名 403(19 禁)", http.StatusForbidden, true},
		{"第一名 404", http.StatusNotFound, true},
		{"第一名 502", http.StatusBadGateway, false},
	} {
		var queries []string
		withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/v4/search/track"):
				queries = append(queries, r.URL.Query().Get("query"))
				return http.StatusOK, search
			case strings.HasSuffix(target, "/vibe/v4/lyric/21"):
				return c.status, `{"response":{"message":{"apiStatusCode":"NO_PERMISSON"}}}`
			case strings.HasSuffix(target, "/vibe/v4/lyric/22"):
				return http.StatusOK, vibeTestSync
			}
			return http.StatusNotFound, ""
		})
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		r := resolveVibeLyric(ctx, "프라이머리 & 다이나믹 듀오", "LOVE (feat. BUMKEY & Paloalto)", "LP", 262)
		if len(queries) == 0 || queries[0] != "LOVE 프라이머리" {
			t.Errorf("%s: 检索词去掉 feat 段、只带第一位歌手: %v", c.name, queries)
		}
		if r.album != "Part 3" {
			t.Errorf("%s: 第一名取不到时退到第二名: %+v", c.name, r)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("%s: complete = %v,期望 %v(403 / 404 是答了没有)", c.name, got, c.wantComplete)
		}
	}
}

// 清理过的两次都没过闸、原歌名被改过时,再按原样的歌名搜一次(歌名跟专辑同名、合作者写法跟 VIBE 一致的那种)。
func TestResolveVibeLyricFallsBackToRawTitle(t *testing.T) {
	var queries []string
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/v4/search/track"):
			q := r.URL.Query().Get("query")
			queries = append(queries, q)
			if q == "evermore (feat. Bon Iver)" {
				return http.StatusOK, `{"response":{"result":{"tracks":[{"trackId":31,"trackTitle":"evermore (Feat. Bon Iver)","artists":[{"artistName":"Taylor Swift"}],"album":{"albumTitle":"evermore"},"playTime":"05:04","hasLyric":true,"hasSyncLyric":true}]}}}`
			}
			return http.StatusOK, `{"response":{"result":{"tracks":[{"trackId":32,"trackTitle":"willow","artists":[{"artistName":"Taylor Swift"}],"album":{"albumTitle":"evermore"},"playTime":"03:34","hasLyric":true,"hasSyncLyric":true}]}}}`
		case strings.HasSuffix(target, "/vibe/v4/lyric/31"):
			return http.StatusOK, vibeTestSync
		}
		return http.StatusNotFound, ""
	})
	r := resolveVibeLyric(qqRoundCtx(), "Taylor Swift & Bon Iver", "evermore (feat. Bon Iver)", "evermore", 304)
	if len(queries) != 3 || queries[2] != "evermore (feat. Bon Iver)" || r.lyrics == "" {
		t.Fatalf("应按原样的歌名再搜一次并找到: queries=%v r=%+v", queries, r)
	}
}
