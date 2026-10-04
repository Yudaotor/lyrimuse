package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// withArtistSourceAliases 换上一份别名表(换表时刻记为 at),测试结束还原。
func withArtistSourceAliases(t *testing.T, tab artistSourceAliasTable, at time.Time) {
	t.Helper()
	artistSourceAliasMu.RLock()
	saved, savedAt := artistSourceAliases, artistSourceAliasAt
	artistSourceAliasMu.RUnlock()
	setArtistSourceAliases(tab, at)
	t.Cleanup(func() { setArtistSourceAliases(saved, savedAt) })
}

func TestBilingualNameHalves(t *testing.T) {
	yes := map[string][2]string{
		"BTS (防弹少年团)":      {"BTS", "防弹少年团"},
		"BTS(防弹少年团)":       {"BTS", "防弹少年团"},
		"盧廣仲 (Crowd Lu)":   {"盧廣仲", "Crowd Lu"},
		"茜拉（Shila Amzah）":  {"茜拉", "Shila Amzah"},
		"i-dle (아이들)":      {"i-dle", "아이들"},
		"五月天 阿信 (Ashin)":   {"五月天 阿信", "Ashin"},
		"HEARTSTEEL (心之钢)": {"HEARTSTEEL", "心之钢"},
	}
	for in, want := range yes {
		a, b, ok := bilingualNameHalves(in)
		if !ok || a != want[0] || b != want[1] {
			t.Errorf("%q: got (%q, %q, %v), want (%q, %q)", in, a, b, ok, want[0], want[1])
		}
	}
	for _, in := range []string{
		"Young K (DAY6)", // 两半同一种文字:成员加团名
		"曾溢(小五)",
		"Taylor Swift (Taylor's Version)",
		"Coldplay、BTS (防弹少年团)", // 合唱串
		"陶喆 (feat. David Tao)", // 客串署名
		"A (B) (防弹少年团)",        // 前一半自己带括号
		"(G)I-DLE",
		"Official髭男dism",
		"BTS",
		"防弹少年团",
	} {
		if a, b, ok := bilingualNameHalves(in); ok {
			t.Errorf("%q 不该算双语写法, got (%q, %q)", in, a, b)
		}
	}
}

func TestDeriveArtistSourceAliases(t *testing.T) {
	s := func(artist, title, credit string) sourceCreditSample {
		return sourceCreditSample{artist: artist, title: title, credit: credit}
	}
	samples := []sourceCreditSample{
		// 判据 2:三首不同的歌都署成另一种文字的同一个名字;同一首出现两次只算一首
		s("王子", "1999 (Edit)", "Prince"),
		s("王子", "The Guilty Ones", "Prince"),
		s("王子", "The Guilty Ones", "Prince"),
		s("王子", "Why You Wanna Treat Me So Bad?", "Prince"),
		// 去重后只有两首
		s("音乐顽童", "Buddy", "Musiq Soulchild"),
		s("音乐顽童", "teachme", "Musiq Soulchild"),
		s("音乐顽童", "teachme", "Musiq Soulchild"),
		// 同一种文字的两个名字:不学
		s("The Time", "Jungle Love", "Prince"),
		s("The Time", "777-9311", "Prince"),
		s("The Time", "The Bird", "Prince"),
		// 署成别人的只有三首,署成自己的四首:不过半
		s("某歌手", "A", "Adele"), s("某歌手", "B", "Adele"), s("某歌手", "C", "Adele"),
		s("某歌手", "D", "某歌手"), s("某歌手", "E", "某歌手"), s("某歌手", "F", "某歌手"), s("某歌手", "G", "某歌手"),
		// 过半,但不到署名不是它自己的那些歌的三分之二
		s("群星", "A", "Adele"), s("群星", "B", "Adele"), s("群星", "C", "Adele"),
		s("群星", "D", "Coldplay"), s("群星", "E", "Coldplay"),
		// 合唱里有它自己的署名算署的是它自己,不进「署名不是它自己」那一栏
		s("林忆莲", "A", "Sandy Lam"), s("林忆莲", "B", "Sandy Lam"), s("林忆莲", "C", "Sandy Lam"),
		s("林忆莲", "D", "林忆莲、李宗盛"), s("林忆莲", "E", "李宗盛 & 林忆莲"),
		// 合唱串标签不学
		s("王子 & 某人", "A", "Prince"), s("王子 & 某人", "B", "Prince"), s("王子 & 某人", "C", "Prince"),
		// 判据 1:源署名里的双语写法出现在三首歌上(含不带空格的写法);标签自己的双语写法两首;只有一首的不收
		s("防弹少年团", "Boy With Luv", "BTS (防弹少年团)"),
		s("防弹少年团", "Dynamite", "BTS(防弹少年团)"),
		s("BTS", "Butter", "BTS (防弹少年团)"),
		s("盧廣仲 (Crowd Lu)", "魚仔", ""),
		s("盧廣仲 (Crowd Lu)", "刻在我心底的名字", ""),
		s("某乐队", "X", "Some Band (某乐队)"),
	}
	want := artistSourceAliasTable{
		aliases: map[string][]string{
			"王子":      {"Prince"},
			"林忆莲":     {"Sandy Lam"},
			"bts":     {"防弹少年团"},
			"防弹少年团":   {"BTS"},
			"卢广仲":     {"Crowd Lu"},
			"crowdlu": {"盧廣仲"},
		},
		translated: map[string]bool{"王子": true, "林忆莲": true},
	}
	got := deriveArtistSourceAliases(samples)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("别名表:\n got  %+v\n want %+v", got, want)
	}

	reversed := make([]sourceCreditSample, len(samples))
	for i, x := range samples {
		reversed[len(samples)-1-i] = x
	}
	if again := deriveArtistSourceAliases(reversed); !reflect.DeepEqual(again, got) {
		t.Errorf("结果跟样本顺序有关:\n got  %+v\n want %+v", again, got)
	}
}

func TestMergeAliasedArtistsAcrossScripts(t *testing.T) {
	withArtistSourceAliases(t, deriveArtistSourceAliases([]sourceCreditSample{
		{artist: "王子", title: "1999 (Edit)", credit: "Prince"},
		{artist: "王子", title: "The Guilty Ones", credit: "Prince"},
		{artist: "王子", title: "Why You Wanna Treat Me So Bad?", credit: "Prince"},
		{artist: "防弹少年团", title: "Boy With Luv", credit: "BTS (防弹少年团)"},
		{artist: "BTS", title: "Butter", credit: "BTS (防弹少年团)"},
	}), time.Now())

	t.Run("译名并进原名,显示原名", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Prince", PlayCount: 1975},
			{Name: "卢广仲", PlayCount: 364},
			{Name: "王子", PlayCount: 12},
			{Name: "防弹少年团", PlayCount: 7},
			{Name: "BTS", PlayCount: 5},
			{Name: "盧廣仲 (Crowd Lu)", PlayCount: 4},
			{Name: "The Time", PlayCount: 3},
		})
		want := []lastfmChartEntry{
			{Name: "Prince", PlayCount: 1987},
			{Name: "卢广仲", PlayCount: 368},
			{Name: "防弹少年团", PlayCount: 12},
			{Name: "The Time", PlayCount: 3},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("got %+v\nwant %+v", got, want)
		}
	})

	t.Run("榜上的双语写法拆两半并,不抢显示名", func(t *testing.T) {
		got := mergeAliasedArtists([]lastfmChartEntry{
			{Name: "Taylor Swift", PlayCount: 209},
			{Name: "Taylor Swift (泰勒絲)", PlayCount: 16},
			{Name: "DAY6", PlayCount: 9},
			{Name: "Young K (DAY6)", PlayCount: 2},
		})
		want := []lastfmChartEntry{
			{Name: "Taylor Swift", PlayCount: 225},
			{Name: "DAY6", PlayCount: 9},
			{Name: "Young K (DAY6)", PlayCount: 2},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("got %+v\nwant %+v", got, want)
		}
	})
}

func TestRefreshArtistSourceAliases(t *testing.T) {
	withArtistSourceAliases(t, artistSourceAliasTable{}, time.Time{})
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })

	decided := func(credit string) enrichEntry {
		return enrichEntry{LyricsDecisionApplied: &lyricsDecision{Winner: "qq", WinnerArtist: credit}}
	}
	prince := map[string]enrichEntry{
		"王子|1999 (Edit)|":                    decided("Prince"),
		"王子|The Guilty Ones|Timeless":        decided("Prince"),
		"王子|Why You Wanna Treat Me So Bad?|": decided("Prince"),
	}
	has := func() bool { return reflect.DeepEqual(artistAlternateNames("王子"), []string{"Prince"}) }

	enrichCache = prince
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	refreshArtistSourceAliases(now)
	if !has() {
		t.Fatalf("第一次就该算出来, got %v", artistAlternateNames("王子"))
	}
	enrichCache = map[string]enrichEntry{}
	refreshArtistSourceAliases(now.Add(30 * time.Minute))
	if !has() {
		t.Error("不到 artistSourceAliasMaxAge 不该重算")
	}
	refreshArtistSourceAliases(now.Add(artistSourceAliasMaxAge))
	if has() {
		t.Error("满 artistSourceAliasMaxAge 该重算")
	}
	enrichCache = prince
	refreshArtistSourceAliases(now.Add(-time.Minute))
	if !has() {
		t.Error("时钟往回拨了也该重算")
	}
}

func TestLoadArtistSourceAliases(t *testing.T) {
	withArtistSourceAliases(t, artistSourceAliasTable{}, time.Time{})
	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse-enrich-cache.json")
	cache := map[string]any{
		"王子|1999 (Edit)|": map[string]any{
			"lyrics_decision_applied": map[string]any{"winner": "qq", "winner_artist": "Prince"}},
		// 没有 winner_artist 时按胜出来源去候选里找
		"王子|The Guilty Ones|": map[string]any{
			"lyrics_decision_applied": map[string]any{"winner": "kugou", "candidates": []any{
				map[string]any{"source": "netease", "artist": "王子"},
				map[string]any{"source": "kugou", "artist": "Prince"},
			}}},
		"王子|Why You Wanna Treat Me So Bad?|": map[string]any{
			"lyrics_decision_applied": map[string]any{"winner": "kugou", "winner_artist": "Prince"}},
		"盧廣仲 (Crowd Lu)|魚仔|":       map[string]any{},
		"盧廣仲 (Crowd Lu)|刻在我心底的名字|": map[string]any{},
	}
	data, err := json.Marshal(cache)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	loadArtistSourceAliases(path)
	if got := artistAlternateNames("王子"); !reflect.DeepEqual(got, []string{"Prince"}) {
		t.Errorf("王子: got %v", got)
	}
	if got := artistAlternateNames("卢广仲"); !reflect.DeepEqual(got, []string{"Crowd Lu"}) {
		t.Errorf("卢广仲: got %v", got)
	}

	// 读不出来:表不动
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	loadArtistSourceAliases(path)
	loadArtistSourceAliases(filepath.Join(dir, "missing.json"))
	if got := artistAlternateNames("王子"); !reflect.DeepEqual(got, []string{"Prince"}) {
		t.Errorf("读坏文件之后表变了: got %v", got)
	}
}
