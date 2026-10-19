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

func TestAppleLinkRecheckCandidates(t *testing.T) {
	const anchorURL = "https://music.apple.com/cn/album/x/5?i=6&uo=4"
	entries := map[string]enrichEntry{
		"Dean Lewis|Be Alright|Be Alright - Single": {
			AppleURL: "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", DurationSecs: 196},
		"Dean Lewis|Be Alright~dur2|Be Alright - Single": {
			AppleURL: "https://music.apple.com/us/album/x/1?i=2", ResolvedDurationSecs: 230},
		"Dean Lewis|Waves|A Place We Knew":                {AppleURL: "https://music.apple.com/us/album/x/3?i=4"},
		"Dean Lewis|Hold On|Hold On - Single":             {},
		"Dean Lewis|Album Page|A Place We Knew":           {AppleURL: "https://music.apple.com/us/album/x/3"},
		"Dean Lewis|Anchored|A Place We Knew":             {AppleURL: anchorURL, DurationSecs: 200},
		"Dean Lewis|Stale Anchor|A Place We Knew":         {AppleURL: "https://music.apple.com/us/album/x/7?i=8", DurationSecs: 200},
		"防弹少年团|BTS (방탄소년단) 'Merry Go Round' Official MV|": {AppleURL: "https://music.apple.com/us/album/x/9?i=10", DurationSecs: 259},
	}
	anchor := func(artist, title, album string, secs float64) string {
		if title == "Anchored" || title == "Stale Anchor" {
			return anchorURL
		}
		return ""
	}
	got := map[string]appleLinkRecheckItem{}
	for _, it := range appleLinkRecheckCandidates(entries, anchor) {
		got[it.key] = it
	}
	if len(got) != 5 {
		t.Fatalf("应挑出五条带曲目页链接、链接不是锚点那一页的(单曲和非单曲都算),实得 %v", got)
	}
	if it := got["防弹少年团|BTS (방탄소년단) 'Merry Go Round' Official MV|"]; it.title != "Merry Go Round" || it.durationSecs != 0 {
		t.Errorf("MV 标题按封面那步拆开、时长当未知,实得 %+v", it)
	}
	if it := got["Dean Lewis|Be Alright|Be Alright - Single"]; it.country != "us" || it.trackID != "1450557781" || it.durationSecs != 196 ||
		it.artist != "Dean Lewis" || it.title != "Be Alright" || it.album != "Be Alright - Single" {
		t.Errorf("条目字段不对: %+v", it)
	}
	if it := got["Dean Lewis|Be Alright~dur2|Be Alright - Single"]; it.durationSecs != 230 || it.title != "Be Alright" {
		t.Errorf("时长变体条目:曲名去掉 ~durN、没有 duration_secs 时用 resolved,实得 %+v", it)
	}
	if _, ok := got["Dean Lewis|Waves|A Place We Knew"]; !ok {
		t.Error("专辑名不是曲名的条目也要重核")
	}
	if _, ok := got["Dean Lewis|Anchored|A Place We Knew"]; ok {
		t.Error("链接就是目录锚点那一页的不重核")
	}
	if _, ok := got["Dean Lewis|Stale Anchor|A Place We Knew"]; !ok {
		t.Error("有锚点、但链接指着别的曲目的照样重核")
	}
}

func TestAppleLinkMismatch(t *testing.T) {
	item := func(artist, title, album string, secs float64) appleLinkRecheckItem {
		return appleLinkRecheckItem{artist: artist, title: title, album: album, durationSecs: secs}
	}
	track := func(name, artist, album string, secs float64) itunesResult {
		return itunesResult{TrackName: name, ArtistName: artist, CollectionName: album, TrackTimeMillis: secs * 1000}
	}
	cases := []struct {
		name string
		it   appleLinkRecheckItem
		r    itunesResult
		want string
	}{
		{"同专辑的 Reprise", item("Frank Ocean", "Solo", "Blonde", 257), track("Solo (Reprise)", "Frank Ocean", "Blonde", 78.743), appleLinkAnotherVersion},
		{"Live 版", item("方大同", "HBDD", "JOURNEY TO THE WEST", 271), track("很不低调 HBDD (Live版)", "方大同", "Timeless Live", 340), appleLinkAnotherVersion},
		{"本地是 Live、链接是录音室版", item("Bon Jovi", "Livin' On A Prayer (Live)", "Slippery When Wet", 333.5), track("Livin' On a Prayer", "Bon Jovi", "Slippery When Wet", 249.3), appleLinkAnotherVersion},
		{"版本词不同但时长对得上,不动", item("New Edition", "Kinda Girls We Like", "New Edition", 200), track("Kinda Girls We Like (2016 Edit)", "New Edition", "New Edition", 200.4), ""},
		{"版本词不同、本地时长未知,不动", item("Frank Ocean", "Solo", "Blonde", 0), track("Solo (Reprise)", "Frank Ocean", "Blonde", 78.743), ""},
		{"专辑名里的现场标记一起算", item("蔡健雅", "呼吸", "My Space 演唱會紀念盤", 280), track("呼吸 (Live)", "蔡健雅", "My Space 演唱會紀念盤", 290), ""},
		{"别人的同名曲", item("The Rose", "Utopia", "HEAL", 214), track("Utopia", "Faylasuf", "Utopia", 187), appleLinkAnotherArtist},
		{"别人的同名曲、时长对得上,不动", item("JJ林俊傑", "背對背擁抱", "100天", 235.2), track("背对背拥抱", "林俊杰", "100天 (新歌+精选)", 235.3), ""},
		{"署名对不上但专辑名逐字相等,不动", item("Khalil Fong", "Three Tour", "橙月", 200), track("Three Tour", "方大同", "橙月", 230), ""},
		{"别人的同名曲、本地时长未知,不动", item("The Rose", "Utopia", "HEAL", 0), track("Utopia", "Faylasuf", "Utopia", 187), ""},
		{"商店换了文字写法、时长差 2 秒,不动", item("陈粒", "七楼", "如也", 189.3), track("七楼", "Chen Li", "Ru Ye", 191.3), ""},
		{"文字不同、时长差得远:别人的歌", item("方大同", "月亮代表我的心", "The Soulboy Collection", 204.7), track("月亮代表我的心", "Teresa Teng", "Best", 211.9), appleLinkAnotherArtist},
		{"文字不同、时长差得远、曲名繁简一样、本地没报专辑:不动", item("方大同", "春风吹", "", 220), track("春風吹", "Khalil Fong", "Soulboy", 200.6), ""},
		{"文字不同、时长差得远、曲名一样、专辑沾边:不动", item("王子", "The Guilty Ones", "Timeless Hits", 259.1), track("The Guilty Ones", "Prince", "Timeless", 254.8), ""},
		{"文字不同、时长差得远、曲名一样、专辑不沾:别人的歌", item("Khalil Fong", "Ten Reasons", "云南里", 169.3), track("Ten Reasons", "方大同", "Ten Reasons - Single", 224.5), appleLinkAnotherArtist},
		{"文字不同、时长差得远、曲名不一样:别人的歌", item("薛凯琪", "给十年后的我", "Electric Angel", 149.7), track("十年後的我", "Fiona Sit", "十年後的我 - Single", 252), appleLinkAnotherArtist},
		{"版本词不带括号、曲名一字不差,不动", item("蓝心羽", "阿拉斯加海湾 伴奏", "阿拉斯加海湾", 241), track("阿拉斯加海湾 (伴奏)", "蓝心羽", "阿拉斯加海湾", 237), ""},
		{"单曲:别人的同名单曲(v1 判据)", item("Dean Lewis", "Be Alright", "Be Alright - Single", 196), track("Be Alright", "Parmalee", "Be Alright - Single", 196.6), appleLinkAnotherArtist},
		{"单曲:换了文字写法的同一份录音", item("Ian 陈卓贤", "无垢", "无垢 - Single", 209.63), track("无垢", "Ian Chan", "无垢 - Single", 209.631), ""},
		{"同一首", item("Frank Ocean", "Solo", "Blonde", 257), track("Solo", "Frank Ocean", "Blonde", 257.38), ""},
		{"lookup 没给曲名时只核署名", item("Frank Ocean", "Solo", "Blonde", 257), track("", "Frank Ocean", "", 78.743), ""},
	}
	for _, c := range cases {
		if got := appleLinkMismatch(c.it, c.r); got != c.want {
			t.Errorf("%s: appleLinkMismatch = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestClearMismatchedAppleLink(t *testing.T) {
	appleCover := enrichEntry{AppleURL: "u", PeripheralRetryCount: 5, CoverURL: "c", CoverSource: "apple", CoverAlbum: "Blonde",
		AccentColor: "#fff", MotionCoverURL: "m"}
	kept := clearMismatchedAppleLink(appleCover, appleLinkAnotherVersion, "Blonde")
	if kept.AppleURL != "" || kept.PeripheralRetryCount != 0 || kept.CoverURL != "c" || kept.AccentColor != "#fff" || kept.MotionCoverURL != "m" {
		t.Errorf("另一个版本、Apple 封面就是本地这张专辑的:只清链接,留封面: %+v", kept)
	}
	if e := clearMismatchedAppleLink(appleCover, appleLinkAnotherVersion, "Blonde (Live)"); e.CoverURL != "" || e.MotionCoverURL != "" {
		t.Errorf("另一个版本、封面那张专辑不能当本地这张:封面一族一起清: %+v", e)
	}
	if e := clearMismatchedAppleLink(appleCover, appleLinkAnotherVersion, ""); e.CoverURL != "" {
		t.Errorf("另一个版本、本地没报专辑:封面证明不了,一起清: %+v", e)
	}
	if e := clearMismatchedAppleLink(appleCover, appleLinkAnotherArtist, "Blonde"); e.CoverURL != "" || e.AppleURL != "" {
		t.Errorf("别人的歌:封面一族一起清: %+v", e)
	}
	device := enrichEntry{AppleURL: "u", CoverURL: "file:///x.jpg", CoverSource: "device"}
	if e := clearMismatchedAppleLink(device, appleLinkAnotherVersion, ""); e.AppleURL != "" || e.CoverURL != "file:///x.jpg" {
		t.Errorf("别处来的封面不动: %+v", e)
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

func TestRecheckAppleLinksClearsOnlyWrongOnes(t *testing.T) {
	lookup := `{"results":[` +
		`{"wrapperType":"track","trackId":1450557781,"trackName":"Be Alright","collectionName":"Be Alright - Single","artistName":"Parmalee","trackTimeMillis":201027},` +
		`{"wrapperType":"track","trackId":1700000001,"trackName":"无垢","collectionName":"无垢 - Single","artistName":"Ian Chan","trackTimeMillis":209631},` +
		`{"wrapperType":"track","trackId":1146195721,"trackName":"Solo (Reprise)","collectionName":"Blonde","artistName":"Frank Ocean","trackTimeMillis":78743},` +
		`{"wrapperType":"track","trackId":1146195604,"trackName":"Solo","collectionName":"Blonde","artistName":"Frank Ocean","trackTimeMillis":257380},` +
		`{"wrapperType":"track","trackId":1500000002,"trackName":"Utopia","collectionName":"Utopia - EP","artistName":"Faylasuf","trackTimeMillis":187000}]}`
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(string) (int, string) { return 200, lookup })
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })
	const wrongKey, rightKey = "Dean Lewis|Be Alright|Be Alright - Single", "Ian 陈卓贤|无垢|无垢 - Single"
	const repriseKey, soloKey, roseKey = "Frank Ocean|Solo|Blonde", "Frank Ocean|Solo~dur2|Blonde", "The Rose|Utopia|HEAL"
	const anchoredKey = "Frank Ocean|Solo (Reprise)|Blonde"
	repriseURL := "https://music.apple.com/us/album/solo-reprise/1146195596?i=1146195721&uo=4"
	enrichCache = map[string]enrichEntry{
		wrongKey: {AppleURL: "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", DurationSecs: 196,
			CoverURL: "https://p/1200x1200bb.jpg", CoverSource: "apple"},
		rightKey: {AppleURL: "https://music.apple.com/us/album/wugou/1700000000?i=1700000001", DurationSecs: 209.63},
		repriseKey: {AppleURL: repriseURL, DurationSecs: 257, CoverURL: "https://b/1200x1200bb.jpg", CoverSource: "apple",
			CoverAlbum: "Blonde"},
		soloKey:     {AppleURL: "https://music.apple.com/us/album/solo/1146195596?i=1146195604&uo=4", DurationSecs: 257.4},
		roseKey:     {AppleURL: "https://music.apple.com/us/album/utopia/1500000001?i=1500000002&uo=4", DurationSecs: 214},
		anchoredKey: {AppleURL: repriseURL, DurationSecs: 300},
	}
	anchor := func(artist, title, album string, secs float64) string {
		if title == "Solo (Reprise)" {
			return repriseURL
		}
		return ""
	}
	if n := recheckAppleLinks(context.Background(), migrationScopeOf(migrationAppleSingleLinks, migrationAppleSingleLinksVersion), anchor, 0); n != 3 {
		t.Fatalf("应清三条,实清 %d", n)
	}
	if e := enrichCache[wrongKey]; e.AppleURL != "" || e.CoverURL != "" {
		t.Errorf("别人的同名单曲那条应清掉链接和封面: %+v", e)
	}
	if e := enrichCache[rightKey]; e.AppleURL == "" {
		t.Error("换了文字写法的同一份录音应保留链接")
	}
	if e := enrichCache[repriseKey]; e.AppleURL != "" || e.CoverURL == "" || e.PeripheralRetryCount != 0 {
		t.Errorf("指到 Reprise 的那条应清掉链接、留同一张专辑的封面: %+v", e)
	}
	if e := enrichCache[soloKey]; e.AppleURL == "" {
		t.Error("指对了的不动")
	}
	if e := enrichCache[roseKey]; e.AppleURL != "" {
		t.Errorf("别人的同名曲那条应清掉: %+v", e)
	}
	if e := enrichCache[anchoredKey]; e.AppleURL != repriseURL {
		t.Errorf("目录锚点给的链接不重核(时长再对不上也不动): %+v", e)
	}
}

func TestRecheckAppleLinksKeepsAllWhenLookupFails(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(string) (int, string) { return 503, "" })
	saved := enrichCache
	t.Cleanup(func() { enrichCache = saved })
	const key = "Dean Lewis|Be Alright|Be Alright - Single"
	enrichCache = map[string]enrichEntry{
		key: {AppleURL: "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781&uo=4", DurationSecs: 196},
	}
	if n := recheckAppleLinks(context.Background(), migrationScopeOf(migrationAppleSingleLinks, migrationAppleSingleLinksVersion), nil, 0); n != 0 || enrichCache[key].AppleURL == "" {
		t.Errorf("没问成时一条都不该动,实清 %d", n)
	}
}
