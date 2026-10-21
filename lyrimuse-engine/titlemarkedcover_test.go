package main

import (
	"context"
	"testing"
)

func TestTitleMarkedCover(t *testing.T) {
	for _, c := range []struct {
		title string
		want  bool
	}{
		{"メランコリーキッチン - 米津玄師 / dongdang (cover)", true},
		{"Song (Cover)", true},
		{"Song [Acoustic Cover]", true},
		{"Song - Cover Version", true},
		{"Song (Covered)", true},
		{"Song covered by Someone", true},
		{"海阔天空(翻唱)", true},
		{"夜曲（翻自 周杰伦）", true},
		{"Song (カバー)", true},
		{"Song (커버)", true},
		{"Cover Me", false},
		{"Take Cover", false},
		{"Cover Me (Live)", false},
		{"Undercover (Remix)", false},
		{"Covers", false},
		{"Song - Discover", false},
	} {
		if got := titleMarkedCover(c.title); got != c.want {
			t.Errorf("titleMarkedCover(%q) = %v, want %v", c.title, got, c.want)
		}
	}
}

// 歌名写明是翻唱:歌手泛搜、专辑曲目表里只凭时长挑的都不用;专辑那一路有近似标题佐证的照用;没写翻唱的照旧用。
// ctx 已取消,别的几路联网反查都拿不到东西。
func TestTitleReverseLookupSkipsDurationOnlyPicksForCovers(t *testing.T) {
	savedSearch, savedAlbum, savedAliases := titleReverseArtistSearch, titleReverseAlbumSearch, titleReverseAliases
	t.Cleanup(func() {
		titleReverseArtistSearch, titleReverseAlbumSearch, titleReverseAliases = savedSearch, savedAlbum, savedAliases
	})
	titleReverseAliases = func(context.Context, string) []string { return nil }
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	none := func(context.Context, string, string, float64) (string, float64, bool) { return "", 0, false }
	noAlbum := func(context.Context, string, string, string, float64) (string, float64, bool, bool) {
		return "", 0, false, false
	}
	const cover = "メランコリーキッチン - 米津玄師 / dongdang (cover)"
	for _, c := range []struct {
		name, title, search, album string
		backed                     bool
		want, method               string
	}{
		{"翻唱 泛搜凭时长", cover, "Oh... (Cover)", "", false, "", ""},
		{"翻唱 专辑凭时长", cover, "", "Oh... (Cover)", false, "", ""},
		{"翻唱 专辑有近似标题佐证", cover, "", "メランコリーキッチン (Cover)", true, "メランコリーキッチン (Cover)", "title-from-album"},
		{"没写翻唱 泛搜凭时长", "メランコリーキッチン", "Oh...", "", false, "Oh...", lyricQueryReasonTitleSearch},
		{"没写翻唱 专辑凭时长", "メランコリーキッチン", "", "Oh...", false, "Oh...", "title-from-album"},
	} {
		titleReverseArtistSearch, titleReverseAlbumSearch = none, noAlbum
		if c.search != "" {
			found := c.search
			titleReverseArtistSearch = func(context.Context, string, string, float64) (string, float64, bool) { return found, 1, true }
		}
		if c.album != "" {
			found, backed := c.album, c.backed
			titleReverseAlbumSearch = func(context.Context, string, string, string, float64) (string, float64, bool, bool) {
				return found, 1, backed, true
			}
		}
		got, method, _ := titleReverseLookup(ctx, "dongdang", c.title, "", 241, nil, "", false)
		if got != c.want || (c.want != "" && method != c.method) {
			t.Errorf("%s: corrected = %q (%s),want %q (%s)", c.name, got, method, c.want, c.method)
		}
	}
}
