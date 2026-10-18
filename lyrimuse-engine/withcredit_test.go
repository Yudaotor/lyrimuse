package main

import "testing"

// 「(with 某某)」合作署名:交给各源的搜索名留着,拼成一个搜索词时去掉;key 规则、歌曲实体的去括号歌名照旧剥。
func TestWithCreditSearchTitle(t *testing.T) {
	for _, c := range []struct{ title, search, query string }{
		{"一秒 (with 陈奕迅)", "一秒 (with 陈奕迅)", "一秒"},
		{"STAY (With Justin Bieber)", "STAY (With Justin Bieber)", "STAY"},
		{"等你下课（with 杨瑞代）", "等你下课（with 杨瑞代）", "等你下课"},
		{"Song (Live) (with X)", "Song (Live) (with X)", "Song (Live)"},
		{"Song (with X) (Red Bean)", "Song (with X)", "Song"},
		{"Dancing With A Stranger (Remix)", "Dancing With A Stranger (Remix)", "Dancing With A Stranger (Remix)"},
		{"Song (without you)", "Song", "Song"},
		{"Song (Red Bean)", "Song", "Song"},
	} {
		search := lyricSearchTitle(c.title)
		if search != c.search {
			t.Errorf("lyricSearchTitle(%q) = %q,期望 %q", c.title, search, c.search)
		}
		if got := lyricQueryTitle(search); got != c.query {
			t.Errorf("lyricQueryTitle(%q) = %q,期望 %q", search, got, c.query)
		}
	}
	// 结尾不是 with 的歌名原样拼搜索词,不顺手剥掉别的括号。
	if got := lyricQueryTitle("Song (Red Bean)"); got != "Song (Red Bean)" {
		t.Errorf("不带 with 的歌名应原样拼搜索词: %q", got)
	}
	if got := normEnrichTitle("一秒 (with 陈奕迅)"); got != "一秒" {
		t.Errorf("key 规则照旧剥掉 with: %q", got)
	}
}

// 留着署名挑候选:源把署名写进歌名(「一秒 with 陳奕迅」)时认得出是同一首,拿剥过的歌名去比认不出。
func TestWithCreditCandidateSameName(t *testing.T) {
	if !lyricTitleSameName("一秒 with 陳奕迅", lyricSearchTitle("一秒 (with 陈奕迅)")) {
		t.Error("带署名的搜索名应认得出「一秒 with 陳奕迅」")
	}
	if !lyricTitleAccepted("一秒", lyricSearchTitle("一秒 (with 陈奕迅)")) {
		t.Error("不带署名的同名候选照样收")
	}
}

// 歌曲实体的去括号歌名不受影响:两层括号里有 with 时照旧都剥掉。
func TestWithCreditSongBareTitleUnchanged(t *testing.T) {
	if songBareTitle("Song (Red Bean) (with X)") != songBareTitle("Song") {
		t.Error("歌曲实体的去括号歌名应照旧剥掉 with 和译名")
	}
}
