package main

import (
	"net/http"
	"strings"
	"testing"
)

func qqTestItem(mid, name, singer, album string, secs float64) qqSearchItem {
	return qqSearchItem{Mid: mid, Name: name, Singer: singer, Album: album, Interval: secs}
}

// 两档歌手闸都没放行时的后备,逐档。
func TestQQFallbackCandidates(t *testing.T) {
	cases := []struct {
		name                 string
		items                []qqSearchItem
		artist, title, album string
		dur                  float64
		alias                string
		want                 string
	}{
		{"QQ 一侧的尾段", []qqSearchItem{qqTestItem("m1", "Seven (feat. Latto) - Explicit Ver.", "Jung Kook/Latto", "Seven (feat. Latto) - Explicit Ver.", 184)},
			"Jung Kook", "Seven", "", 205, "", "m1"},
		{"QQ 一侧的尾段、时长差太多", []qqSearchItem{qqTestItem("m1", "Automatic - 2004 Remastered", "宇多田ヒカル", "", 29)},
			"宇多田ヒカル", "Automatic (Remastered 2014)", "First Love (Remastered 2014)", 328, "", ""},
		{"本地一侧的尾段", []qqSearchItem{qqTestItem("m2", "什么歌", "五月天", "什么歌", 236)},
			"五月天", "什么歌 - 电影<捉妖记2>主题曲", "什么歌", 237, "", "m2"},
		{"本地一侧的尾段、本地时长未知", []qqSearchItem{qqTestItem("m2", "什么歌", "五月天", "什么歌", 236)},
			"五月天", "什么歌 - 电影<捉妖记2>主题曲", "什么歌", 0, "", ""},
		{"本地一侧的尾段、时长差超过 3%", []qqSearchItem{qqTestItem("m2", "什么歌", "五月天", "什么歌", 260)},
			"五月天", "什么歌 - 电影<捉妖记2>主题曲", "什么歌", 237, "", ""},
		{"尾段是版本限定词照样拦", []qqSearchItem{qqTestItem("m3", "落笔成书", "刘惜君", "落笔成书", 272)},
			"刘惜君", "落笔成书 - Live", "音乐缘计划 第9期 - Live", 272, "", ""},
		{"另一个署名", []qqSearchItem{qqTestItem("m4", "Time", "宇多田光", "Time", 298)},
			"宇多田ヒカル", "Time", "BADモード", 298, "宇多田光", "m4"},
		{"另一个署名、时长差超过 3%", []qqSearchItem{qqTestItem("m4", "Time", "宇多田光", "Time", 330)},
			"宇多田ヒカル", "Time", "BADモード", 298, "宇多田光", ""},
		{"另一个署名 + 本地尾段,现场版被版本闸拦掉", []qqSearchItem{
			qqTestItem("m5", "Fantastic (Live From Vevo Studios|Explicit)", "King Princess/双城之战/英雄联盟", "Fantastic (Live From Vevo Studios) [Explicit]", 187),
			qqTestItem("m6", "Fantastic (from the series Arcane League of Legends|Explicit)", "King Princess/双城之战/英雄联盟", "Arcane League of Legends: Season 2 Original Soundtrack [Explicit]", 184)},
			"Arcane", "Fantastic - from the series Arcane League of Legends", "Arcane League of Legends: Season 2 (Soundtrack from the Animated Series)", 185, "双城之战", "m6"},
		{"没有另一个署名就不放行", []qqSearchItem{qqTestItem("m4", "Time", "宇多田光", "Time", 298)},
			"宇多田ヒカル", "Time", "BADモード", 298, "", ""},
		{"同专辑同时长、唯一", []qqSearchItem{qqTestItem("m7", "갑자기", "I.O.I", "I.O.I 3rd MINI ALBUM [I.O.I : LOOP]", 195)},
			"I.O.I", "Suddenly", "I.O.I 3rd MINI ALBUM (I.O.I : LOOP) - EP", 195, "", "m7"},
		{"同专辑同时长、不唯一就放弃", []qqSearchItem{
			qqTestItem("m7", "갑자기", "I.O.I", "I.O.I 3rd MINI ALBUM [I.O.I : LOOP]", 195),
			qqTestItem("m8", "Hush", "I.O.I", "I.O.I 3rd MINI ALBUM [I.O.I : LOOP]", 195.5)},
			"I.O.I", "Suddenly", "I.O.I 3rd MINI ALBUM (I.O.I : LOOP) - EP", 195, "", ""},
		{"同专辑、时长差超过 1 秒", []qqSearchItem{qqTestItem("m7", "갑자기", "I.O.I", "I.O.I 3rd MINI ALBUM [I.O.I : LOOP]", 196.5)},
			"I.O.I", "Suddenly", "I.O.I 3rd MINI ALBUM (I.O.I : LOOP) - EP", 195, "", ""},
		{"同时长、专辑对不上", []qqSearchItem{qqTestItem("m7", "갑자기", "I.O.I", "miss me?", 195)},
			"I.O.I", "Suddenly", "I.O.I 3rd MINI ALBUM (I.O.I : LOOP) - EP", 195, "", ""},
	}
	for _, c := range cases {
		alias := c.alias
		got := qqFallbackCandidates(c.items, c.artist, c.title, c.album, c.dur, func() string { return alias })
		var mids []string
		for _, g := range got {
			mids = append(mids, g.mid)
		}
		if strings.Join(mids, ",") != c.want {
			t.Errorf("%s: got %v, want %q", c.name, mids, c.want)
		}
	}
}

// 前一档有结果就不再问下一档(联想要联网,不该白问)。
func TestQQFallbackCandidatesAsksAliasOnlyWhenNeeded(t *testing.T) {
	asked := 0
	alias := func() string { asked++; return "宇多田光" }
	items := []qqSearchItem{qqTestItem("m2", "什么歌", "五月天", "什么歌", 236)}
	if got := qqFallbackCandidates(items, "五月天", "什么歌 - 电影<捉妖记2>主题曲", "什么歌", 237, alias); len(got) != 1 || asked != 0 {
		t.Fatalf("尾段那一档有结果就停: got %+v, asked %d", got, asked)
	}
}

// 联想:手工别名表优先;纯中文名不查;跟原名一样的不算。
func TestQQArtistAlias(t *testing.T) {
	if got := qqArtistAlias("Wanting"); got != knownArtistAlias("Wanting") || got == "" {
		t.Errorf("手工别名表里有就用表里的: %q", got)
	}
	if got := qqArtistAlias("周杰伦"); got != "" {
		t.Errorf("纯中文名不查: %q", got)
	}
}

const qqTestSmartboxSinger = `{"code":0,"data":{"song":{"itemlist":[]},"album":{"itemlist":[]},"singer":{"itemlist":[{"name":"宇多田光","pic":""}]}}}`

// 端到端:搜索结果里只有 QQ 署的另一个名字,歌手联想给出这个名字之后照样挑得出。
func TestResolveQQMusicMatchUsesSingerSuggestionAlias(t *testing.T) {
	qqArtistAliasMu.Lock()
	saved := qqArtistAliasCache
	qqArtistAliasCache = map[string]string{}
	qqArtistAliasMu.Unlock()
	t.Cleanup(func() {
		qqArtistAliasMu.Lock()
		qqArtistAliasCache = saved
		qqArtistAliasMu.Unlock()
	})
	withQQFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/soso/fcgi-bin/client_search_cp"):
			return http.StatusOK, `{"code":0,"data":{"song":{"list":[{"mid":"mt1","title":"Time","interval":298,"singer":[{"name":"宇多田光"}],"album":{"name":"Time"}}]}}}`
		case strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg"):
			return http.StatusOK, qqTestSmartboxSinger
		}
		return http.StatusNotFound, ""
	})
	m := resolveQQMusicMatch(qqRoundCtx(), "宇多田ヒカル", "Time", "BADモード", 298)
	if qqMidFromURL(m.url) != "mt1" || m.artist != "宇多田光" {
		t.Fatalf("该按 QQ 的署名挑出来: %+v", m)
	}
}

// 端到端:带着「 - 宣传语」搜不到这首,去掉尾段再搜一次。
func TestResolveQQMusicMatchSearchesWithoutDashTail(t *testing.T) {
	withQQFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/soso/fcgi-bin/client_search_cp"):
			if q := r.URL.Query().Get("w"); strings.Contains(q, "主题曲") {
				return http.StatusOK, `{"code":0,"data":{"song":{"list":[{"mid":"mx","title":"突然好想你","interval":265,"singer":[{"name":"五月天"}],"album":{"name":"后青春期的诗"}}]}}}`
			}
			return http.StatusOK, `{"code":0,"data":{"song":{"list":[{"mid":"mw","title":"什么歌","interval":236,"singer":[{"name":"五月天"}],"album":{"name":"什么歌"}}]}}}`
		case strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg"):
			return http.StatusOK, `{"code":0,"data":{"song":{"itemlist":[]},"album":{"itemlist":[]},"singer":{"itemlist":[]}}}`
		}
		return http.StatusNotFound, ""
	})
	m := resolveQQMusicMatch(qqRoundCtx(), "五月天", "什么歌 - 电影<捉妖记2>主题曲", "什么歌", 237)
	if qqMidFromURL(m.url) != "mw" {
		t.Fatalf("去掉尾段再搜该挑出来: %+v", m)
	}
}
