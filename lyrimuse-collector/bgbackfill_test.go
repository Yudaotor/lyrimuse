package main

import (
	"strconv"
	"strings"
	"testing"
)

func TestNeedsBackgroundVocalsBackfill(t *testing.T) {
	base := enrichEntry{Lyrics: "[00:01.00]x", LyricsSource: "amll"}
	cases := []struct {
		name string
		mod  func(*enrichEntry)
		want bool
	}{
		{"amll 没取过", func(e *enrichEntry) {}, true},
		{"applemusic 没取过", func(e *enrichEntry) { e.LyricsSource = "applemusic" }, true},
		{"已取过", func(e *enrichEntry) { e.LyricsBGChecked = lyricsBGParserVersion }, false},
		{"只按背景人声那一版取过,还要补词曲作者", func(e *enrichEntry) { e.LyricsBGChecked = 1 }, true},
		{"别的源", func(e *enrichEntry) { e.LyricsSource = "netease" }, false},
		{"手改过", func(e *enrichEntry) { e.ManualLyrics = true }, false},
		{"没有词", func(e *enrichEntry) { e.Lyrics = "" }, false},
	}
	for _, c := range cases {
		e := base
		c.mod(&e)
		if got := needsBackgroundVocalsBackfill(e); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

func TestBackgroundAlignsWithLyrics(t *testing.T) {
	yrc := "[13719,582](13719,144,0)What\n[15253,680](15253,300,0)Where\n"
	lrc := "[00:13.71]What you doing?\n[00:15.25]Where you at?\n"
	bg := "[13719,582](14457,218,0)(What\n[15253,680](16114,227,0)(Where\n"
	if !backgroundAlignsWithLyrics(bg, yrc, lrc) {
		t.Error("行头跟逐字轨完全相同,应当对得上")
	}
	if !backgroundAlignsWithLyrics(bg, "", lrc) {
		t.Error("没有逐字时按 LRC 时间戳,10ms 精度的差值应当放行")
	}
	if backgroundAlignsWithLyrics("[20000,500](20100,300,0)(oh)\n", yrc, lrc) {
		t.Error("挂不到任何主句的背景人声应当拒绝")
	}
	if backgroundAlignsWithLyrics("", yrc, lrc) {
		t.Error("空的背景人声不算对得上")
	}
}

func TestNeteaseSongIDFromURL(t *testing.T) {
	cases := map[string]string{
		"https://music.163.com/song?id=1824927085": "1824927085",
		"https://music.163.com/#/search?s=foo":     "",
		"https://y.qq.com/n/ryqq/songDetail/abc":   "",
		"":                                         "",
	}
	for in, want := range cases {
		if got := neteaseSongIDFromURL(in); got != want {
			t.Errorf("neteaseSongIDFromURL(%q) = %q, want %q", in, got, want)
		}
	}
}

// amll 胜出时它的背景人声原样进结果。
func TestRankCarriesBackgroundVocalsFromWinner(t *testing.T) {
	var lrc, yrc strings.Builder
	for i := 0; i < 12; i++ {
		ms := 10000 + i*4000
		lrc.WriteString(formatLRCTime(ms) + "Line number " + string(rune('A'+i)) + " goes here\n")
		yrc.WriteString("[" + strconv.Itoa(ms) + ",3000](" + strconv.Itoa(ms) + ",3000,0)Line number " + string(rune('A'+i)) + " goes here\n")
	}
	bg := "[10000,3000](13100,500,0)(ooh)\n"
	raw := map[string]lyricSourceResult{
		"amll": {source: "amll", amll: amllResult{lrc: lrc.String(), yrc: yrc.String(), bg: bg}},
	}
	scored := rankLyricSourceResults("someone", "song", "", 60, raw)
	if len(scored) == 0 || scored[0].Source != "amll" {
		t.Fatalf("amll 应当胜出: %+v", scored)
	}
	if scored[0].LyricsBG != bg {
		t.Errorf("结果里的背景人声 = %q", scored[0].LyricsBG)
	}
}
