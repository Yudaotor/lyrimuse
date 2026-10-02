package main

import (
	"context"
	"testing"
)

func TestAppleTrackURLParts(t *testing.T) {
	cases := []struct{ url, country, id string }{
		{"https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", "us", "1450557781"},
		{"https://music.apple.com/cn/album/x/1400595841?uo=4&i=1400596082", "cn", "1400596082"},
		{"https://music.apple.com/us/album/be-alright/1450557780", "", ""},
		{"https://open.spotify.com/track/abc", "", ""},
	}
	for _, c := range cases {
		if country, id := appleTrackURLParts(c.url); country != c.country || id != c.id {
			t.Errorf("appleTrackURLParts(%q) = %q, %q; want %q, %q", c.url, country, id, c.country, c.id)
		}
	}
}

func TestAppleSingleLinkCandidates(t *testing.T) {
	entries := map[string]enrichEntry{
		"Dean Lewis|Be Alright|Be Alright - Single": {
			AppleURL: "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", DurationSecs: 196},
		"Dean Lewis|Be Alright~dur2|Be Alright - Single": {
			AppleURL: "https://music.apple.com/us/album/x/1?i=2", ResolvedDurationSecs: 230},
		"Dean Lewis|Waves|A Place We Knew":    {AppleURL: "https://music.apple.com/us/album/x/3?i=4"},
		"Dean Lewis|Hold On|Hold On - Single": {},
	}
	got := map[string]appleLinkRecheckItem{}
	for _, it := range appleSingleLinkCandidates(entries) {
		got[it.key] = it
	}
	if len(got) != 2 {
		t.Fatalf("应只挑出两条专辑名只是曲名、带曲目页链接的,实得 %v", got)
	}
	if it := got["Dean Lewis|Be Alright|Be Alright - Single"]; it.country != "us" || it.trackID != "1450557781" || it.durationSecs != 196 || it.artist != "Dean Lewis" {
		t.Errorf("条目字段不对: %+v", it)
	}
	if it := got["Dean Lewis|Be Alright~dur2|Be Alright - Single"]; it.durationSecs != 230 {
		t.Errorf("时长变体条目:曲名去掉 ~durN 再比、没有 duration_secs 时用 resolved,实得 %+v", it)
	}
}

func TestAppleSingleLinkStale(t *testing.T) {
	cases := []struct {
		name                    string
		entryArtist, linkArtist string
		entrySecs, linkSecs     float64
		want                    bool
	}{
		{"别人的同名单曲", "Dean Lewis", "Parmalee", 196, 201.027, true},
		{"同一种文字的伴奏带,时长只差 0.57s", "Mrs. GREEN APPLE", "Uta-Cha-Oh", 188.348, 187.776, true},
		{"换了文字写法的同一份录音", "Ian 陈卓贤", "Ian Chan", 209.630, 209.631, false},
		{"同一个歌手", "Dean Lewis", "Dean Lewis", 196, 196.373, false},
		{"链接那边没有署名,无从判定", "Dean Lewis", "", 196, 201, false},
		{"本地时长未知,判不了就不动", "Kun", "蔡徐坤", 0, 237.183, false},
		{"同一种文字的另一种写法、时长几乎一样", "丢火车", "丢火车乐队", 189.4, 189.42, false},
	}
	for _, c := range cases {
		if got := appleSingleLinkStale(c.entryArtist, c.entrySecs, c.linkArtist, c.linkSecs); got != c.want {
			t.Errorf("%s: appleSingleLinkStale = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestClearStaleAppleLink(t *testing.T) {
	fromApple := clearStaleAppleLink(enrichEntry{
		AppleURL: "u", PeripheralRetryCount: 5, CoverURL: "c", CoverSource: "apple", CoverAlbum: "a", AccentColor: "#fff",
		MotionCoverURL: "m", MotionPreviewURL: "p", MotionCoverChecked: true, MotionCoverIdentityVerified: true,
	})
	if fromApple.AppleURL != "" || fromApple.PeripheralRetryCount != 0 || fromApple.CoverURL != "" || fromApple.CoverSource != "" ||
		fromApple.CoverAlbum != "" || fromApple.AccentColor != "" || fromApple.MotionCoverURL != "" || fromApple.MotionPreviewURL != "" ||
		fromApple.MotionCoverChecked || fromApple.MotionCoverIdentityVerified {
		t.Errorf("封面出自同一次 Apple 匹配时应一起清掉: %+v", fromApple)
	}
	fromDevice := clearStaleAppleLink(enrichEntry{AppleURL: "u", CoverURL: "file:///x.jpg", CoverSource: "device", MotionCoverURL: "m"})
	if fromDevice.AppleURL != "" || fromDevice.CoverURL != "file:///x.jpg" || fromDevice.MotionCoverURL != "m" {
		t.Errorf("别处来的封面不动: %+v", fromDevice)
	}
}

func TestRecheckAppleSingleLinksClearsOnlyWrongOnes(t *testing.T) {
	lookup := `{"results":[` +
		`{"wrapperType":"track","trackId":1450557781,"artistName":"Parmalee","trackTimeMillis":201027},` +
		`{"wrapperType":"track","trackId":1700000001,"artistName":"Ian Chan","trackTimeMillis":209631}]}`
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(string) (int, string) { return 200, lookup })
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })
	const wrongKey, rightKey = "Dean Lewis|Be Alright|Be Alright - Single", "Ian 陈卓贤|无垢|无垢 - Single"
	enrichCache = map[string]enrichEntry{
		wrongKey: {AppleURL: "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", DurationSecs: 196,
			CoverURL: "https://p/1200x1200bb.jpg", CoverSource: "apple"},
		rightKey: {AppleURL: "https://music.apple.com/us/album/wugou/1700000000?i=1700000001", DurationSecs: 209.63},
	}
	if n := recheckAppleSingleLinks(context.Background(), migrationScopeOf(migrationAppleSingleLinks, migrationAppleSingleLinksVersion), 0); n != 1 {
		t.Fatalf("应只清一条,实清 %d", n)
	}
	if e := enrichCache[wrongKey]; e.AppleURL != "" || e.CoverURL != "" {
		t.Errorf("别人的同名单曲那条应清掉链接和封面: %+v", e)
	}
	if e := enrichCache[rightKey]; e.AppleURL == "" {
		t.Error("换了文字写法的同一份录音应保留链接")
	}
}

func TestRecheckAppleSingleLinksKeepsAllWhenLookupFails(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(string) (int, string) { return 503, "" })
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })
	const key = "Dean Lewis|Be Alright|Be Alright - Single"
	enrichCache = map[string]enrichEntry{
		key: {AppleURL: "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", DurationSecs: 196},
	}
	if n := recheckAppleSingleLinks(context.Background(), migrationScopeOf(migrationAppleSingleLinks, migrationAppleSingleLinksVersion), 0); n != 0 || enrichCache[key].AppleURL == "" {
		t.Errorf("没问成时一条都不该动,实清 %d", n)
	}
}
