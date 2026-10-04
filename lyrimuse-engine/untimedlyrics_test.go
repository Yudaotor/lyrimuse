package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

func TestUntimedLyricsText(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"统一换行、连续空行收成一行", "The Root - D'Angelo\r\n\r\n\r\none, two, three, four....\r\nShe done worked a root.", "The Root - D'Angelo\n\none, two, three, four....\nShe done worked a root."},
		{"去掉元数据标签行和署名行", "[ti:示例]\n[ar:歌手]\n作曲 : 某某\n第一句\n第二句\n第三句", "第一句\n第二句\n第三句"},
		{"去掉行首零星的时间戳", "[00:00:00]第一句\n第二句\n第三句", "第一句\n第二句\n第三句"},
		{"不到三行正文不交", "N/A", ""},
		{"口白占位不交", "[00:00:00]此歌曲为没有填词的口白，请您欣赏", ""},
		{"只有署名不交", "作词 : 甲\n作曲 : 乙\n编曲 : 丙", ""},
		{"纯音乐占位不交", "[00:00:00]此歌曲为没有填词的纯音乐，请您欣赏", ""},
	} {
		if got := untimedLyricsText(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// QQ 整行接口答的是不带时间戳的歌词:理好放进 plain,不算「这首没词」。
func TestQQLineLyricKeepsUntimedText(t *testing.T) {
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/lyric/fcgi-bin/fcg_query_lyric_new.fcg") {
			return http.StatusOK, `{"retcode":0,"code":0,"lyric":"The Root - D'Angelo\r\n\r\none, two, three, four....\r\nShe done worked a root.\r\nDone worked a root that will not be reversed"}`
		}
		return http.StatusNotFound, ""
	})
	res := resolveQQLyric(qqRoundCtx(), "m1")
	if res.lrc != "" || res.trackFoundNoLyrics || res.plain != "The Root - D'Angelo\n\none, two, three, four....\nShe done worked a root.\nDone worked a root that will not be reversed" {
		t.Fatalf("不带时间戳的歌词该进 plain: %+v", res)
	}
	if got := qqPlainLyric(res, qqQRCResult{}); got != res.plain {
		t.Errorf("没有带时间戳的就交纯文本: %q", got)
	}
	if got := qqPlainLyric(res, qqQRCResult{line: qqTestQRCLine}); got != "" {
		t.Errorf("QRC 压得出整行就不交纯文本: %q", got)
	}
	if got := qqPlainLyric(qqLyricResult{instrumental: true, plain: "a\nb\nc"}, qqQRCResult{}); got != "" {
		t.Errorf("纯音乐不交纯文本: %q", got)
	}
}

// 网关解开的不是 QRC:带时间戳的整行 LRC 进 line,不带时间戳的歌词理好进 plain。
func TestQQPlayLyricInfoNonQRCBody(t *testing.T) {
	for _, c := range []struct{ name, body, wantLine, wantPlain string }{
		{"纯文本", "第一句\n第二句\n第三句\n第四句", "", "第一句\n第二句\n第三句\n第四句"},
		{"整行 LRC", qqTestLRC, qqTestLRC, ""},
	} {
		resetQQSessionForTest(t)
		qqSessionFetch = func(ctx context.Context) ([]byte, error) {
			return []byte(`{"session":{"uid":"1","sid":"s1","userip":"1.1.1.1"}}`), nil
		}
		cipher := qqEncryptQRCForTest(t, c.body)
		withQQFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
				return http.StatusOK, `{"code":0,"data":[` + qqDetailRow + `]}`
			case target == "u.y.qq.com/musicu:GetPlayLyricInfo":
				return http.StatusOK, musicuOK(`{"lyric":"` + cipher + `","qrc_t":0,"lrc_t":1709258656,"trans":"","roma":""}`)
			}
			return http.StatusNotFound, ""
		})
		res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269)
		if res.line != c.wantLine || res.plain != c.wantPlain || res.yrc != "" {
			t.Errorf("%s: line=%q plain=%q yrc=%q", c.name, res.line, res.plain, res.yrc)
		}
	}
}

// 网易云只有不带时间戳的歌词:理好放进 PlainLyrics;判成纯音乐时不给。
func TestResolveNeteaseInfoKeepsUntimedText(t *testing.T) {
	for _, c := range []struct{ name, lyric, want string }{
		{"纯文本", `{"code":200,"lrc":{"lyric":` + jsonQuoteForTest(`{"c":[{"tx":"作曲: "},{"tx":"某某"}]}`+"\n第一句\n第二句\n第三句") + `}}`, "第一句\n第二句\n第三句"},
		{"纯音乐", `{"code":200,"pureMusic":true,"lrc":{"lyric":"[00:00.00]纯音乐，请欣赏"}}`, ""},
	} {
		withNeteaseFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/api/search/get"):
				return http.StatusOK, neSearchOne
			case strings.HasSuffix(target, "/api/song/detail"):
				return http.StatusOK, `{"code":200,"songs":[{"album":{"picUrl":"http://p1.music.126.net/x.jpg"}}]}`
			case target == "music.163.com/api/song/lyric/v1":
				return http.StatusOK, c.lyric
			}
			return http.StatusNotFound, ""
		})
		info := resolveNeteaseInfo(qqRoundCtx(), "陈奕迅", "浮夸", "U87", 283.5)
		if info.Lyrics != "" || info.PlainLyrics != c.want {
			t.Errorf("%s: lyrics=%q plain=%q", c.name, info.Lyrics, info.PlainLyrics)
		}
	}
}

// 两家的纯文本进打分结果时是「仅纯文本」候选(恒 -1,只在别家都没有带时间戳的时候兜底)。
func TestRankKeepsNeteaseAndQQPlainText(t *testing.T) {
	raw := map[string]lyricSourceResult{
		"qq":      {source: "qq", lyr: "第一句\n第二句\n第三句", plainOnly: true},
		"netease": {source: "netease", ne: neteaseInfo{PlainLyrics: "甲\n乙\n丙"}},
	}
	got := map[string]scoredLyricCandidateResult{}
	for _, c := range rankLyricSourceResults("someone", "song", "", 0, raw) {
		got[c.Source] = c
	}
	for src, want := range map[string]string{"qq": "第一句\n第二句\n第三句", "netease": "甲\n乙\n丙"} {
		c, ok := got[src]
		if !ok || !c.PlainTextOnly || c.Lyrics != want || c.Score >= 0 {
			t.Errorf("%s 该是仅纯文本候选: %+v", src, c)
		}
	}
}
