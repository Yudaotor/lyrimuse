package main

import (
	"context"
	"testing"
)

func TestTitleSearchContradicts(t *testing.T) {
	for _, c := range []struct {
		title, album, found string
		want                bool
	}{
		{"Look at Miss Ohio", "Lotta Love (feat. Flock of Dimes) - Single", "Sabana de luz", true},
		{"Look at Miss Ohio", "Lotta Love (feat. Flock of Dimes) - Single", "Lotta Love", false}, // 专辑名就是这首
		{`Bang Chan "Eternity"`, "", "ESCAPE (Bang Chan & Hyunjin)", true},                       // 括号里的署名不算共享
		{"Shitodo Seiten Daimeiwaku", "Yankee", "KARMA CITY", true},
		{"The Way", "", "The End", true},   // 只共享虚词
		{"Close to you", "", "千纸鹤", false}, // 跨文字判不了
		{"Uchiagehanabi", "", "春雷", false},
		{"涅槃 (Phoenix)-2019《英雄联盟》全球总决赛主题曲", "", "Phoenix", false},
		{"Love Story", "", "Love Me Like You Do", false},
		{"Friend", "", "Friends", false},
		{"Wu Kong", "", "Wukong", false},
		{"Greatdayndamornin' / Booty", "", "Medley: Greatdayndamornin' / Booty", false},
		{"Heartbreak", "", "Heartbreaker", false},
		{"Dream On", "", "Dreamer", false}, // 词前缀相同也算共享
	} {
		if got := titleSearchContradicts(c.title, c.album, c.found); got != c.want {
			t.Errorf("titleSearchContradicts(%q, %q, %q) = %v, want %v", c.title, c.album, c.found, got, c.want)
		}
	}
}

// 泛搜挑出来的曲名跟本地明摆着两首歌时,标题反查不用它;专辑名就是这首、跨文字的照旧用。ctx 已取消,别的几路联网反查都拿不到东西。
func TestTitleReverseLookupDropsContradictingArtistSearch(t *testing.T) {
	savedSearch, savedAliases := titleReverseArtistSearch, titleReverseAliases
	t.Cleanup(func() { titleReverseArtistSearch, titleReverseAliases = savedSearch, savedAliases })
	titleReverseAliases = func(context.Context, string) []string { return nil }
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	for _, c := range []struct{ title, album, found, want string }{
		{"Look at Miss Ohio", "Lotta Love (feat. Flock of Dimes) - Single", "Sabana de luz", ""},
		{"Look at Miss Ohio", "Lotta Love (feat. Flock of Dimes) - Single", "Lotta Love", "Lotta Love"},
		{"Close to you", "千纸鹤", "千纸鹤", "千纸鹤"},
	} {
		found := c.found
		titleReverseArtistSearch = func(context.Context, string, string, float64) (string, float64, bool) { return found, 0.6, true }
		got, method, _ := titleReverseLookup(ctx, "Helado Negro", c.title, c.album, 197.6, nil, "")
		if got != c.want {
			t.Errorf("%q 泛搜挑出 %q:corrected = %q (%s),want %q", c.title, c.found, got, method, c.want)
		}
		if c.want != "" && method != lyricQueryReasonTitleSearch {
			t.Errorf("%q:method = %q,want %q", c.title, method, lyricQueryReasonTitleSearch)
		}
	}
}
