package main

import (
	"context"
	"testing"
)

func TestArtistCreditPrimary(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Khalil Fong feat. Leehom Wang", "Khalil Fong"},
		{"Khalil Fong feat. Crush & Zion.T", "Khalil Fong"},
		{"Daniel Caesar (feat. Mustafa)", "Daniel Caesar"},
		{"A ft. B", "A"},
		{"A featuring B", "A"},
		{"Prince & The Revolution", "Prince"},
		{"Khalil Fong和Fiona Sit", "Khalil Fong"},
		{"陶喆/卢广仲", "陶喆"},
		{"K/DA", "K/DA"},
		{"AC/DC", "AC/DC"},
		{"FT Island", "FT Island"},
		{"Soft Lipa", "Soft Lipa"},
		{"Daft Punk", "Daft Punk"},
		{"方大同", "方大同"},
	}
	for _, c := range cases {
		if got := artistCreditPrimary(c.in); got != c.want {
			t.Errorf("artistCreditPrimary(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	for _, s := range []string{"Khalil Fong feat. Leehom Wang", "KnowKnow & Higher Brothers", "陶喆/卢广仲"} {
		if !isMultiArtistCredit(s) || expectsCanonicalArtist(s) {
			t.Errorf("%q 是合唱串,不该有 canonical_artist", s)
		}
	}
	for _, s := range []string{"Khalil Fong", "FT Island", "Soft Lipa", "方大同"} {
		if isMultiArtistCredit(s) || !expectsCanonicalArtist(s) {
			t.Errorf("%q 是单一歌手", s)
		}
	}
	if expectsCanonicalArtist("K/DA") {
		t.Errorf("K/DA 按 artistCreditParts 维持原判(算合唱)")
	}
}

// 缓存里按整串存下的旧条目,三个入口都不读;第一位单独查照常。
func TestCanonicalNameSkipsMultiCredit(t *testing.T) {
	withCachedAliases(t, map[string]string{
		"Khalil Fong feat. Leehom Wang": "王力宏",
		"KnowKnow & Higher Brothers":    "更高兄弟",
		"Khalil Fong":                   "方大同",
	})
	withCachedMBAliases(t, map[string][]string{"Khalil Fong feat. Leehom Wang": nil, "Khalil Fong": nil})
	withCachedQQArtistNames(t, map[string]string{"Khalil Fong feat. Leehom Wang": "王力宏", "Khalil Fong": ""})

	for _, s := range []string{"Khalil Fong feat. Leehom Wang", "KnowKnow & Higher Brothers"} {
		if got := cachedGenericArtistCanonicalName(s); got != "" {
			t.Errorf("cachedGenericArtistCanonicalName(%q) = %q, want empty", s, got)
		}
		if got := canonicalArtistViaMusicBrainz(context.Background(), s); got != "" {
			t.Errorf("canonicalArtistViaMusicBrainz(%q) = %q, want empty", s, got)
		}
		if got := resolveGenericArtistCanonicalName(context.Background(), s); got != "" {
			t.Errorf("resolveGenericArtistCanonicalName(%q) = %q, want empty", s, got)
		}
	}
	if got := cachedGenericArtistCanonicalName("Khalil Fong"); got != "方大同" {
		t.Errorf("单一歌手照常查到中文名, got %q", got)
	}
	if artistMergeNameKeyCached("Khalil Fong feat. Leehom Wang") != artistMergeNameKeyCached("方大同") {
		t.Errorf("feat. 串的归并键要落在第一位歌手上")
	}
}

// 合唱串并进第一位,不另起一行同名条目,也不并进第二位歌手。
func TestMergeAliasedArtistsFeatCredits(t *testing.T) {
	withCachedAliases(t, map[string]string{
		"Khalil Fong":                      "方大同",
		"Khalil Fong feat. Crush & Zion.T": "方大同",
		"Khalil Fong feat. Leehom Wang":    "王力宏",
	})
	withCachedMBAliases(t, map[string][]string{"Khalil Fong": nil})
	withCachedQQArtistNames(t, map[string]string{"Khalil Fong": ""})

	got := mergeAliasedArtists([]lastfmChartEntry{
		{Name: "方大同", PlayCount: 8322},
		{Name: "王力宏", PlayCount: 1916},
		{Name: "Khalil Fong feat. Crush & Zion.T", PlayCount: 2},
		{Name: "Khalil Fong feat. Leehom Wang", PlayCount: 2},
		{Name: "Khalil Fong和Fiona Sit", PlayCount: 1},
	})
	assertChart(t, got, []lastfmChartEntry{
		{Name: "方大同", PlayCount: 8327},
		{Name: "王力宏", PlayCount: 1916},
	})
}

func TestMigrateMultiCreditCanonicalArtists(t *testing.T) {
	isolateEnrichCache(t)
	savedPath := enrichPath
	t.Cleanup(func() { enrichPath = savedPath })
	enrichPath = t.TempDir() + "/cache.json"

	enrichMu.Lock()
	enrichCache["Khalil Fong feat. Leehom Wang|Flow|JOURNEY TO THE WEST"] = enrichEntry{CanonicalArtist: "王力宏"}
	enrichCache["KnowKnow & Higher Brothers|R&B All Night|Mr. Enjoy Da Money"] = enrichEntry{CanonicalArtist: "更高兄弟"}
	enrichCache["Khalil Fong|Love Song|This Love"] = enrichEntry{CanonicalArtist: "方大同"}
	enrichCache["K/DA|POP/STARS|POP/STARS"] = enrichEntry{}
	enrichMu.Unlock()

	migrateMultiCreditCanonicalArtists()

	enrichMu.Lock()
	defer enrichMu.Unlock()
	if v := enrichCache["Khalil Fong feat. Leehom Wang|Flow|JOURNEY TO THE WEST"].CanonicalArtist; v != "" {
		t.Errorf("feat. 串的 canonical 要清掉, got %q", v)
	}
	if v := enrichCache["KnowKnow & Higher Brothers|R&B All Night|Mr. Enjoy Da Money"].CanonicalArtist; v != "" {
		t.Errorf("合唱串的 canonical 要清掉, got %q", v)
	}
	if v := enrichCache["Khalil Fong|Love Song|This Love"].CanonicalArtist; v != "方大同" {
		t.Errorf("单一歌手的 canonical 不能动, got %q", v)
	}
}
