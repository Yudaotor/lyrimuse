package main

import (
	"net/http"
	"strings"
	"testing"
)

func TestGenieParseSyncLyric(t *testing.T) {
	lines, found, err := genieParseSyncLyric(`GenieCallback({"13110":" 둘 ","7340":"하나","x":"버림","20320":""});`)
	if err != nil || !found || len(lines) != 3 {
		t.Fatalf("按起点排序、去掉认不出的键: %v %v %v", lines, found, err)
	}
	if lines[0] != (genieLine{7340, "하나"}) || lines[1] != (genieLine{13110, "둘"}) || lines[2] != (genieLine{20320, ""}) {
		t.Errorf("顺序和去空白: %v", lines)
	}
	if _, found, err := genieParseSyncLyric("NOT FOUND LYRICS\n"); found || err != nil {
		t.Errorf("没有同步歌词: found=%v err=%v", found, err)
	}
	if _, _, err := genieParseSyncLyric("<html>error</html>"); err == nil {
		t.Error("形状认不出来应报错")
	}
}

func TestGeniePrefixHeaderLines(t *testing.T) {
	l := func(texts ...string) []genieLine {
		out := make([]genieLine, len(texts))
		for i, s := range texts {
			out[i] = genieLine{i * 1000, s}
		}
		return out
	}
	for _, c := range []struct {
		name  string
		lines []genieLine
		want  int
	}{
		{"歌名 + 歌手两行", l("Antifreeze", "검정치마 (The Black Skirts)", "우린 오래 전부터"), 2},
		{"只有歌手一行", l("검정치마", "우린 오래 전부터"), 1},
		{"「歌名 - 歌手」一行", l("Antifreeze - 검정치마", "우린 오래 전부터"), 1},
		{"只有一行跟歌名相同:可能是唱出来的第一句,不去", l("Antifreeze", "우린 오래 전부터"), 0},
		{"没有抬头", l("우린 오래 전부터", "검정치마"), 0},
		{"开头连唱三遍歌名:没有歌手那一行,不去", l("Antifreeze", "Antifreeze", "Antifreeze", "우린"), 0},
	} {
		if got := geniePrefixHeaderLines(c.lines, "Antifreeze", "검정치마"); got != c.want {
			t.Errorf("%s: got %d want %d", c.name, got, c.want)
		}
	}
	if got := genieBuildLRC(l("Antifreeze", "검정치마", "우린", ""), "Antifreeze", "검정치마"); got != "[00:02.25]우린\n[00:03.25]\n" {
		t.Errorf("拼 LRC 去掉抬头、起点后移 250ms、空句只留时间戳: %q", got)
	}
}

func genieItem(id int64, name, artist, album string, secs float64, lyrics string) genieSearchItem {
	it := genieSearchItem{SongID: id, Name: genieText{name}, Artist: genieText{artist}, Album: genieText{album}, Lyrics: lyrics}
	it.Duration.Time = secs
	it.Service.Lyrics = "Y"
	return it
}

func TestGenieCandidateScoreGates(t *testing.T) {
	ok := genieItem(1, "밤편지", "아이유 (IU)", "밤편지", 253, "")
	if genieCandidateScore(ok, "IU", "밤편지", "밤편지", 253) < 0 {
		t.Error("「本名 (别名)」歌手、同名同长应过")
	}
	noLyric := ok
	noLyric.Service.Lyrics = "N"
	if genieCandidateScore(noLyric, "IU", "밤편지", "밤편지", 253) >= 0 {
		t.Error("没开歌词服务的淘汰")
	}
	mr := genieItem(2, "밤편지 (아이유 (IU)) (MR)", "Musicsum (뮤직섬)", "뮤직섬 MR반주 2017", 254, "")
	if genieCandidateScore(mr, "IU", "밤편지", "밤편지", 253) >= 0 {
		t.Error("别家的伴奏版淘汰")
	}
	if genieCandidateScore(genieItem(3, "밤편지", "아이유 (IU)", "밤편지", 263, ""), "IU", "밤편지", "밤편지", 253) >= 0 {
		t.Error("时长差 10 秒淘汰")
	}
	if genieCandidateScore(genieItem(4, "밤편지 (Live)", "아이유 (IU)", "콘서트", 253, ""), "IU", "밤편지", "밤편지", 253) >= 0 {
		t.Error("现场版淘汰")
	}
	if genieCandidateScore(genieItem(5, "晴天 ( 청천 )", "주걸륜 (Jay Chou)", "엽혜미(葉惠美)", 270, ""), "Jay Chou", "晴天", "", 270) < 0 {
		t.Error("歌名的韩文读音括号去掉后照样认")
	}
	if genieCandidateScore(genieItem(8, "晴天 ( 청천 )", "주걸륜 (Jay Chou)", "葉惠美", 270, ""), "周杰伦", "晴天", "葉惠美", 270) < 0 {
		t.Error("歌手写法对不上时,去掉读音括号的歌名走三角验证(同名 + 同专辑 + 同长)")
	}
	if genieCandidateScore(genieItem(9, "Through the Night", "아이유 (IU)", "밤편지", 253, ""), "IU", "밤편지", "밤편지", 253) >= 0 {
		t.Error("歌名对不上的淘汰(歌手、专辑、时长都对也不行)")
	}
	if a, b := genieCandidateScore(genieItem(6, "밤편지", "IU", "밤편지", 253, ""), "IU", "밤편지", "", 253),
		genieCandidateScore(genieItem(7, "밤편지", "IU", "밤편지", 259, ""), "IU", "밤편지", "", 253); a <= b {
		t.Errorf("时长越近分越高: %d vs %d", a, b)
	}
}

const genieTestSearch = `{"searchResult":{"result":{"songs":{"items":[
 {"song_id":11,"song_name":{"original":"Antifreeze"},"artist_name":{"original":"검정치마"},"album_name":{"original":"201"},
  "duration":{"time":242},"image_path":"/Y/IMAGE/IMG_ALBUM/1_600x600.JPG","lyrics":"우린 오래 전부터","service_available":{"lyrics_service_yn":"Y"}},
 {"song_id":12,"song_name":{"original":"Antifreeze"},"artist_name":{"original":"검정치마"},"album_name":{"original":"201 (Special Edition)"},
  "duration":{"time":243},"image_path":"/Y/IMAGE/IMG_ALBUM/2_600x600.JPG","lyrics":"우린 오래 전부터","service_available":{"lyrics_service_yn":"Y"}},
 {"song_id":13,"song_name":{"original":"Antifreeze (검정치마) (MR)"},"artist_name":{"original":"Musicsum (뮤직섬)"},"album_name":{"original":"MR"},
  "duration":{"time":242},"lyrics":"","service_available":{"lyrics_service_yn":"Y"}}]}}}}`

const genieTestSync = `GenieCallback({"10":"Antifreeze","8060":"검정치마 (The Black Skirts)","16020":"우린 오래 전부터","20050":"어쩔 수 없는 거였어","24000":"우주 속을 홀로 떠돌며"});`

func TestResolveGenieLyricEndToEnd(t *testing.T) {
	var queries []string
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/search/category/songs.json"):
			q := r.URL.Query().Get("query")
			queries = append(queries, q)
			if q == "Antifreeze 검정치마" {
				return http.StatusOK, `{"searchResult":{"result":{"songs":{"items":[]}}}}`
			}
			return http.StatusOK, genieTestSearch
		case strings.HasSuffix(target, "/app/purchase/get_msl.asp") && r.URL.Query().Get("songid") == "11":
			return http.StatusOK, genieTestSync
		}
		return http.StatusOK, genieNoLyrics
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := resolveGenieLyric(ctx, "검정치마", "Antifreeze", "201", 242)
	if len(queries) != 2 || queries[1] != "Antifreeze" {
		t.Fatalf("「歌名 歌手」一条都没有时只按歌名再搜一次: %v", queries)
	}
	if r.lyrics != "[00:16.27]우린 오래 전부터\n[00:20.30]어쩔 수 없는 거였어\n[00:24.25]우주 속을 홀로 떠돌며\n" || r.plainOnly {
		t.Fatalf("去掉歌名 / 歌手两行抬头: %+v", r)
	}
	if r.title != "Antifreeze" || r.artist != "검정치마" || r.album != "201" || r.durationSecs != 242 ||
		r.cover != "https://image.genie.co.kr/Y/IMAGE/IMG_ALBUM/1_600x600.JPG" {
		t.Errorf("元数据: %+v", r)
	}
	if !sub.complete(ctx) {
		t.Error("都问成了应算完整")
	}
}

func TestResolveGenieLyricPlainAndFailure(t *testing.T) {
	// 第一名没有同步歌词(「NOT FOUND LYRICS」)、第二名有:挑第二名;「没有」是答了,这一轮照样完整。
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/search/category/songs.json"):
			return http.StatusOK, genieTestSearch
		case r.URL.Query().Get("songid") == "12":
			return http.StatusOK, genieTestSync
		}
		return http.StatusOK, genieNoLyrics
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := resolveGenieLyric(ctx, "검정치마", "Antifreeze", "", 242)
	if r.plainOnly || r.album != "201 (Special Edition)" || !sub.complete(ctx) {
		t.Errorf("挑第二名带同步的那份、算完整: %+v complete=%v", r, sub.complete(ctx))
	}
	// 第一名取词 500(没问成):退到第二名,这一轮不算完整、不进缓存。
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/search/category/songs.json"):
			return http.StatusOK, genieTestSearch
		case r.URL.Query().Get("songid") == "11":
			return http.StatusInternalServerError, "<html>error</html>"
		}
		return http.StatusOK, genieTestSync
	})
	ctx, sub = withLyricSubFetch(qqRoundCtx())
	if r := resolveGenieLyric(ctx, "검정치마", "Antifreeze", "", 242); r.lyrics == "" || sub.complete(ctx) {
		t.Errorf("第一名没问成时退到第二名、不算完整: %+v complete=%v", r, sub.complete(ctx))
	}
	// 都没有同步歌词:交名次最高那条的纯文本。
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		if strings.HasSuffix(target, "/search/category/songs.json") {
			return http.StatusOK, genieTestSearch
		}
		return http.StatusOK, genieNoLyrics
	})
	if r := resolveGenieLyric(qqRoundCtx(), "검정치마", "Antifreeze", "", 242); !r.plainOnly || r.lyrics != "우린 오래 전부터" || r.album != "201" {
		t.Errorf("全是纯文本时交第一名的纯文本: %+v", r)
	}
}

// 组装 genie 候选:同步歌词照常打分,只有纯文本的交 plainOnly(分数恒 -1)。
func TestRankLyricSourceResultsGenie(t *testing.T) {
	var lrc strings.Builder
	for i := 0; i < 20; i++ {
		lrc.WriteString(formatLRCStamp((10+i*10)*1000) + "Line " + string(rune('A'+i)) + "\n")
	}
	find := func(r lyricSourceResult) scoredLyricCandidateResult {
		r.source = "genie"
		for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, map[string]lyricSourceResult{"genie": r}) {
			if c.Source == "genie" {
				return c
			}
		}
		t.Fatal("没有 genie 候选")
		return scoredLyricCandidateResult{}
	}
	if c := find(lyricSourceResult{lyr: lrc.String(), srcDur: 220, matchTitle: "Song", matchArtist: "Artist"}); c.PlainTextOnly || c.LyricsTr != "" {
		t.Errorf("同步歌词照常进候选、没有译文: %+v", c)
	}
	if c := find(lyricSourceResult{lyr: "하나\n둘\n셋", plainOnly: true}); !c.PlainTextOnly || c.Score >= 0 {
		t.Errorf("只有纯文本的交 plainOnly、分数恒 -1: plain=%v score=%d", c.PlainTextOnly, c.Score)
	}
}
