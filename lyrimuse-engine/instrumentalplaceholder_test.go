package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

// 网易云带完整职员表的纯音乐占位:署名行是「标签 空格 冒号」或 OP / SP 版权方标签,严格版署名判据认不出。
const (
	placeholderSpacedCredits = "[00:00.00] 作曲 : 杨武韬\n[00:05.00]纯音乐，请欣赏\n[02:25.75] 吉他 : 王彬\n[02:26.75] 母带 : Simon Li@ nOiz\n"
	placeholderPublisherTags = "[00:00.00] 作曲 : 周杰伦\n[00:01.00] 编曲 : 黄雨勋\n[00:02.00] 制作人 : 周杰伦\n" +
		"[00:05.00]纯音乐，请欣赏\n[00:24.81] OP : JVR Music Int'l Ltd\n[00:25.81] SP : Universal Music Publishing Ltd\n"
)

func TestInstrumentalPlaceholderAcceptsRelaxedCreditLines(t *testing.T) {
	for _, c := range []struct {
		name string
		lrc  string
		want bool
	}{
		{"标签 空格 冒号", placeholderSpacedCredits, true},
		{"OP / SP 版权方标签", placeholderPublisherTags, true},
		{"同样的署名排版,没有占位行", "[00:00.00] 吉他 : 王彬\n[00:01.00] 母带 : X\n[00:02.00] OP : Y\n", false},
		{"占位 + 宽松署名 + 一句真歌词", "[00:00.00]纯音乐，请欣赏\n[00:01.00] 吉他 : 王彬\n[00:10.00]这里有一句真的歌词在唱\n", false},
	} {
		if got := isInstrumentalPlaceholderLyric(c.lrc); got != c.want {
			t.Errorf("%s: isInstrumentalPlaceholderLyric = %v, want %v", c.name, got, c.want)
		}
	}
	// 两份都过得了三行门槛,打分时得靠占位判定判废,不然会被当成歌词选中。
	for _, lrc := range []string{placeholderSpacedCredits, placeholderPublisherTags} {
		if !isTimedLRC(lrc) || !isCreditOnlyLRC(lrc) {
			t.Errorf("isTimedLRC=%v isCreditOnlyLRC=%v, want true/true: %q", isTimedLRC(lrc), isCreditOnlyLRC(lrc), lrc)
		}
	}
}

func neSearchWithMark(mark int64) string {
	return `{"code":200,"result":{"songs":[{"id":66282,"name":"浮夸","artists":[{"name":"陈奕迅"}],"album":{"id":6491,"name":"U87"},"duration":283520,"mark":` +
		strconv.FormatInt(mark, 10) + `}]}}`
}

func TestResolveNeteaseInfoPlaceholderAndNoVocals(t *testing.T) {
	placeholderLyric := `{"code":200,"pureMusic":true,"lrc":{"lyric":` + jsonQuoteForTest(placeholderSpacedCredits) + `}}`
	realLyric := `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest("[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n[00:13.00]第四句\n") + `}}`
	creditOnly := `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest("[00:00.00] 作曲 : 甲\n[00:01.00] 编曲 : 乙\n") + `}}`
	for _, c := range []struct {
		name         string
		mark         int64
		lyric        string
		wantLyrics   bool
		wantPure     bool
		wantNoVocals bool
		wantFound    bool
	}{
		{"纯音乐占位带职员表:不交歌词", 0, placeholderLyric, false, true, false, false},
		{"无人声位 + 只有署名:判纯音乐依据,不报平台缺词", neteaseMarkNoVocals | 1<<13, creditOnly, false, false, true, false},
		{"无人声位 + 真歌词(伴奏版):歌词照交", neteaseMarkNoVocals, realLyric, true, false, true, false},
		{"别的位:不算无人声", 1 << 29, creditOnly, false, false, false, true},
	} {
		withNeteaseFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/api/search/get"):
				return http.StatusOK, neSearchWithMark(c.mark)
			case strings.HasSuffix(target, "/api/song/detail"):
				return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
			case target == "music.163.com/api/song/lyric/v1":
				return http.StatusOK, c.lyric
			}
			return http.StatusNotFound, ""
		})
		info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
		if (info.Lyrics != "") != c.wantLyrics || info.PureMusic != c.wantPure || info.NoVocals != c.wantNoVocals || info.TrackFoundNoLyrics != c.wantFound {
			t.Errorf("%s: lyrics=%q pure=%v noVocals=%v found=%v", c.name, info.Lyrics, info.PureMusic, info.NoVocals, info.TrackFoundNoLyrics)
		}
	}
}

func TestRankEmitsNeteaseNoVocalsMarkerOnlyWithoutLyrics(t *testing.T) {
	hasMarker := func(raw map[string]lyricSourceResult) bool {
		for _, c := range rankLyricSourceResults("someone", "song", "", 0, raw) {
			if c.Instrumental && c.Source == "netease" {
				return true
			}
		}
		return false
	}
	if !hasMarker(map[string]lyricSourceResult{"netease": {source: "netease", ne: neteaseInfo{NoVocals: true}}}) {
		t.Error("网易云标了无人声、又没交歌词:该有纯音乐标记")
	}
	withLyrics := neteaseInfo{NoVocals: true, Lyrics: "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n[00:13.00]第四句\n"}
	if hasMarker(map[string]lyricSourceResult{"netease": {source: "netease", ne: withLyrics}}) {
		t.Error("有歌词的伴奏版不该带纯音乐标记")
	}
}

func TestMigrateInstrumentalPlaceholders(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	real := "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	enrichMu.Lock()
	enrichCache["a|placeholder|"] = enrichEntry{Lyrics: placeholderSpacedCredits, LyricsSource: "netease"}
	enrichCache["a|publisher|"] = enrichEntry{Lyrics: placeholderPublisherTags, LyricsSource: "netease"}
	enrichCache["a|real|"] = enrichEntry{Lyrics: real, LyricsSource: "netease"}
	enrichCache["a|manual|"] = enrichEntry{Lyrics: placeholderSpacedCredits, ManualLyrics: true}
	enrichCache["a|picked|"] = enrichEntry{Lyrics: placeholderSpacedCredits, ManualPickSHA: "x"}
	enrichCache["a|locked|"] = enrichEntry{Lyrics: placeholderSpacedCredits, LyricsSourceChoice: "netease"}
	enrichCache["a|cleared|"] = enrichEntry{Lyrics: placeholderSpacedCredits, InstrumentalCleared: true}
	enrichMu.Unlock()

	migrateInstrumentalPlaceholders()

	enrichMu.Lock()
	defer enrichMu.Unlock()
	want := map[string]bool{"a|placeholder|": true, "a|publisher|": true}
	for k, e := range enrichCache {
		if e.Instrumental != want[k] {
			t.Errorf("%s: Instrumental = %v, want %v", k, e.Instrumental, want[k])
		}
	}
	if e := enrichCache["a|placeholder|"]; e.Lyrics != placeholderSpacedCredits {
		t.Errorf("只打标、不改正文: %q", e.Lyrics)
	}
	if !migrationDone(migrationInstrumentalPlaceholder, migrationInstrumentalPlaceholderVersion) {
		t.Error("跑完要记水位")
	}
}

// 本地客户端曲库(dbTrack.jsonStr)里也带 mark,命中本地曲库时同样要带出来。
func TestNeteaseLocalSongCarriesMark(t *testing.T) {
	var m map[string]any
	if err := json.Unmarshal([]byte(neteaseTestTrack("569213220", "像我这样的人", "毛不易", "平凡的一天", 207466)), &m); err != nil {
		t.Fatal(err)
	}
	m["mark"] = neteaseMarkNoVocals | 1<<13
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{string(b)}))
	s, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "平凡的一天", 207)
	if !ok || s.Mark&neteaseMarkNoVocals == 0 {
		t.Fatalf("本地曲库命中要带上 mark: ok=%v mark=%d", ok, s.Mark)
	}
}

// 有纯音乐标记时,末句超过曲长的候选不当冠军:别名轮换个名字搜到的同名别人的歌,常常就是这种形状。
func TestPickLyricCandidateInstrumentalMarkerSkipsOvershoot(t *testing.T) {
	saved := features()
	defer func() { setFeatures(saved) }()
	setFeatures(featureFlags{LyricsSources: map[string]bool{"qq": true, "migu": true, "kugou": true}, LyricsSourceMode: lyricsModeSmart})
	overshoot := scoredLyricCandidateResult{Source: "qq", Score: 1,
		ScoreTerms: []scoreTerm{{Kind: scoreTermDurationOvershoot, Points: -700}, {Kind: scoreTermWordTiming, Points: 400}}}
	marker := scoredLyricCandidateResult{Source: "migu", Score: -1, Instrumental: true}
	fits := scoredLyricCandidateResult{Source: "kugou", Score: 200}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{overshoot, marker}); got != nil {
		t.Fatalf("有纯音乐标记、唯一的候选比曲子还长:不该选出冠军,得到 %v", got.Source)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{overshoot, marker, fits}); got == nil || got.Source != "kugou" {
		t.Fatalf("跳过超长的、选没超长的,得到 %v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{overshoot}); got == nil || got.Source != "qq" {
		t.Fatalf("没有纯音乐标记时照旧,得到 %v", got)
	}
}
