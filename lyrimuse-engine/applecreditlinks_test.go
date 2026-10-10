package main

import (
	"context"
	"slices"
	"testing"
)

func TestAppleCreditLinkCandidates(t *testing.T) {
	got := appleCreditLinkCandidates(map[string]enrichEntry{
		"Sam Smith & Aitana|Like I Can|" + samSmithAnniversary: {AppleURL: samSmithSoloURL, DurationSecs: 166.707, SpotifyTrackID: "abcdefghijklmnopqrstuv"},
		"Sam Smith|Like I Can|In The Lonely Hour":              {AppleURL: samSmithSoloURL, DurationSecs: 167.065},
		"A & B|Song~dur2|Album":                                {AppleURL: "https://music.apple.com/us/album/song/1?i=2", ResolvedDurationSecs: 200},
		"C & D|Song|Album":                                     {AppleURL: "https://music.apple.com/us/artist/c/3"},
	})
	if len(got) != 2 {
		t.Fatalf("应挑出本地点名了合作者、链接是曲目页的两条,实得 %+v", got)
	}
	if it := got[0]; it.key != "A & B|Song~dur2|Album" || it.title != "Song" || it.trackID != "2" || it.country != "us" ||
		it.durationSecs != 200 || !slices.Equal(it.co, []string{"b"}) {
		t.Errorf("变体位标记要剥掉、时长缺了用所配歌词的: %+v", it)
	}
	if it := got[1]; it.trackID != "1763638900" || !slices.Equal(it.co, []string{"aitana"}) || it.spotifyTrackID == "" {
		t.Errorf("合唱那条: %+v", it)
	}
}

// appleCreditLinkFake:按曲目 ID 回 Apple 曲库里的那一轨;搜索回同一个匹配;记下调用次数。
type appleCreditLinkFake struct {
	songs       map[string]appleCatalogSong
	match       appleMusicMatch
	searchOK    bool
	spotify     map[string]string
	anchorURL   string
	searches    int
	onSearch    func()
	songsFailed bool
}

func (f *appleCreditLinkFake) deps() appleCreditLinkDeps {
	return appleCreditLinkDeps{
		songsByID: func(_ context.Context, _ string, ids []string) (map[string]appleCatalogSong, bool) {
			if f.songsFailed {
				return nil, false
			}
			out := map[string]appleCatalogSong{}
			for _, id := range ids {
				if s, ok := f.songs[id]; ok {
					out[id] = s
				}
			}
			return out, true
		},
		search: func(context.Context, string, string, string, float64) (appleMusicMatch, bool) {
			f.searches++
			if f.onSearch != nil {
				f.onSearch()
			}
			return f.match, f.searchOK
		},
		spotifyISRC: func(id string) (string, bool) {
			code, ok := f.spotify[id]
			return code, ok
		},
		anchor: func(string, string, string, float64) string { return f.anchorURL },
	}
}

const samSmithDuetKey = "Sam Smith & Aitana|Like I Can|" + samSmithAnniversary

func samSmithCreditFake() *appleCreditLinkFake {
	return &appleCreditLinkFake{
		songs: map[string]appleCatalogSong{
			"1763638900": {isrc: "GBUM71308834", durationSecs: 168.08, artist: "Sam Smith", title: "Like I Can"},
			"1765000001": {isrc: "GBUM72404445", durationSecs: 166.707, artist: "Sam Smith & Aitana", title: "Like I Can"},
			"555":        {isrc: "USAAA2600001", durationSecs: 200, artist: "A & B", title: "Song"},
		},
		match:    appleMusicMatch{url: samSmithSoloURL, artist: "Sam Smith", title: "Like I Can", durationSecs: 168.08, creditURL: samSmithDuetURL},
		searchOK: true,
	}
}

func TestRecheckAppleCreditLinksReplacesUncreditedLink(t *testing.T) {
	withTempMigrationState(t)
	const creditedKey = "A & B|Song|Album"
	withEnrichCache(t, map[string]enrichEntry{
		samSmithDuetKey: {AppleURL: samSmithSoloURL, DurationSecs: 166.707, ISRCs: []string{"GBUM71308834"},
			ISRCLookup: "apple:us:1763638900", CoverURL: "https://a/1200x1200bb.jpg", CoverSource: "apple"},
		creditedKey: {AppleURL: "https://music.apple.com/us/album/song/554?i=555&uo=4", DurationSecs: 200, ISRCs: []string{"USAAA2600001"}},
	})
	f := samSmithCreditFake()
	scope := migrationScopeOf(migrationAppleCreditLinks, migrationAppleCreditLinksVersion)
	if n := recheckAppleCreditLinks(context.Background(), scope, f.deps(), 0); n != 1 {
		t.Fatalf("应换一条,实换 %d", n)
	}
	e := enrichCache[samSmithDuetKey]
	if e.AppleURL != samSmithDuetURL || !slices.Equal(e.ISRCs, []string{"GBUM72404445"}) || e.ISRCLookup != "apple:us:1765000001" {
		t.Errorf("链接换成合唱那一轨,独唱的号换成合唱的: url=%q isrcs=%v lookup=%q", e.AppleURL, e.ISRCs, e.ISRCLookup)
	}
	if e.CoverURL != "https://a/1200x1200bb.jpg" || e.CoverSource != "apple" {
		t.Errorf("封面出自专辑对得上的那一轨,不动: %q %q", e.CoverURL, e.CoverSource)
	}
	if got := enrichCache[creditedKey]; got.AppleURL != "https://music.apple.com/us/album/song/554?i=555&uo=4" {
		t.Errorf("署名写全了的链接不动: %q", got.AppleURL)
	}
	if f.searches != 1 {
		t.Errorf("只有署名没写全的那条才搜,搜了 %d 次", f.searches)
	}
	if !migrationDone(migrationAppleCreditLinks, migrationAppleCreditLinksVersion) {
		t.Error("都问成了要记水位")
	}
}

// 不动的几种:Spotify 本机记着的号就是链接那一轨的;链接是目录锚点;链接那一轨时长跟本地几乎一样。
func TestRecheckAppleCreditLinksLeavesConfirmedLinks(t *testing.T) {
	cases := []struct {
		name  string
		entry enrichEntry
		fake  func(*appleCreditLinkFake)
	}{
		{"Spotify 放的就是这一份录音",
			enrichEntry{AppleURL: samSmithSoloURL, DurationSecs: 166.707, ISRCs: []string{"GBUM71308834"}, SpotifyTrackID: "abcdefghijklmnopqrstuv"},
			func(f *appleCreditLinkFake) { f.spotify = map[string]string{"abcdefghijklmnopqrstuv": "GBUM71308834"} }},
		{"目录锚点", enrichEntry{AppleURL: samSmithSoloURL, DurationSecs: 166.707},
			func(f *appleCreditLinkFake) { f.anchorURL = samSmithSoloURL }},
		{"时长几乎一样", enrichEntry{AppleURL: samSmithSoloURL, DurationSecs: 168.0}, func(*appleCreditLinkFake) {}},
	}
	for _, c := range cases {
		withTempMigrationState(t)
		withEnrichCache(t, map[string]enrichEntry{samSmithDuetKey: c.entry})
		f := samSmithCreditFake()
		c.fake(f)
		scope := migrationScopeOf(migrationAppleCreditLinks, migrationAppleCreditLinksVersion)
		if n := recheckAppleCreditLinks(context.Background(), scope, f.deps(), 0); n != 0 || enrichCache[samSmithDuetKey].AppleURL != samSmithSoloURL || f.searches != 0 {
			t.Errorf("%s:不该动,也不该搜(换 %d 条,搜 %d 次)", c.name, n, f.searches)
		}
	}
}

// 新那一轨的号跟原来的一样(同一份录音,另一张碟):链接照换,号留着。
func TestRecheckAppleCreditLinksKeepsSharedISRC(t *testing.T) {
	withTempMigrationState(t)
	withEnrichCache(t, map[string]enrichEntry{
		samSmithDuetKey: {AppleURL: samSmithSoloURL, DurationSecs: 166.707, ISRCs: []string{"GBUM71308834"}},
	})
	f := samSmithCreditFake()
	f.songs["1765000001"] = appleCatalogSong{isrc: "GBUM71308834", durationSecs: 166.707, artist: "Sam Smith & Aitana", title: "Like I Can"}
	scope := migrationScopeOf(migrationAppleCreditLinks, migrationAppleCreditLinksVersion)
	if n := recheckAppleCreditLinks(context.Background(), scope, f.deps(), 0); n != 1 {
		t.Fatalf("链接要换,实换 %d", n)
	}
	if e := enrichCache[samSmithDuetKey]; !slices.Equal(e.ISRCs, []string{"GBUM71308834"}) || e.ISRCLookup != "" {
		t.Errorf("新那一轨也是这个号,留着;原来没补过的不记成补过,留给补扫: isrcs=%v lookup=%q", e.ISRCs, e.ISRCLookup)
	}
}

// 没问成就不记水位、不改;重核期间链接被别处换过的不动。
func TestRecheckAppleCreditLinksIncompleteOrRaced(t *testing.T) {
	withTempMigrationState(t)
	withEnrichCache(t, map[string]enrichEntry{
		samSmithDuetKey: {AppleURL: samSmithSoloURL, DurationSecs: 166.707, ISRCs: []string{"GBUM71308834"}},
	})
	f := samSmithCreditFake()
	f.searchOK = false
	scope := migrationScopeOf(migrationAppleCreditLinks, migrationAppleCreditLinksVersion)
	if n := recheckAppleCreditLinks(context.Background(), scope, f.deps(), 0); n != 0 || migrationDone(migrationAppleCreditLinks, migrationAppleCreditLinksVersion) {
		t.Errorf("搜索没问成:不改、不记水位(换 %d)", n)
	}

	f = samSmithCreditFake()
	f.songsFailed = true
	if n := recheckAppleCreditLinks(context.Background(), scope, f.deps(), 0); n != 0 || migrationDone(migrationAppleCreditLinks, migrationAppleCreditLinksVersion) {
		t.Errorf("曲库没问成:不改、不记水位(换 %d)", n)
	}

	f = samSmithCreditFake()
	f.onSearch = func() {
		enrichMu.Lock()
		e := enrichCache[samSmithDuetKey]
		e.AppleURL = "https://music.apple.com/us/album/other/9?i=10"
		enrichCache[samSmithDuetKey] = e
		enrichMu.Unlock()
	}
	if n := recheckAppleCreditLinks(context.Background(), scope, f.deps(), 0); n != 0 || enrichCache[samSmithDuetKey].AppleURL != "https://music.apple.com/us/album/other/9?i=10" {
		t.Errorf("期间被换过的链接不动(换 %d)", n)
	}
}
