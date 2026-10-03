package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

const testAnchorWeiyiURL = "https://music.apple.com/cn/album/%E5%94%AF%E4%B8%80/1717030435?i=1717030438&uo=4"

// 按 ID 查回来的锚点连同答话那个商店的 Apple Music 页一起存下。
func TestAppleCatalogLookupKeepsTrackViewURL(t *testing.T) {
	withAppleCatalogState(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"results":[{"wrapperType":"track","trackName":"唯一","artistName":"邓紫棋","collectionName":"T.I.M.E. - EP",` +
			`"collectionId":1717030435,"trackNumber":2,"trackTimeMillis":253735,"trackViewUrl":"` + testAnchorWeiyiURL + `"}]}`))
	}))
	t.Cleanup(srv.Close)
	appleCatalogLookupURL = srv.URL
	tr, ok, _ := appleCatalogLookup(1717030438)
	if !ok || tr.TrackViewURL != testAnchorWeiyiURL {
		t.Fatalf("应存下页面地址: %+v ok=%v", tr, ok)
	}
	if got := appleCatalogTrackViewURL("1717030438"); got != testAnchorWeiyiURL {
		t.Errorf("锚点缓存里应有页面地址,实得 %q", got)
	}
}

// 取链接:署名、专辑、时长都要对得上;同一张专辑上同名的两条按时长分;播放路径填的索引优先;旧锚点没有页面地址时给空。
func TestAppleCatalogLinkFor(t *testing.T) {
	withAppleCatalogState(t)
	const first, second = "https://music.apple.com/cn/album/x/9?i=1", "https://music.apple.com/cn/album/x/9?i=17"
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1717030438": {TrackName: "唯一", ArtistName: "邓紫棋", AlbumName: "T.I.M.E. - EP", AlbumID: 1717030435, DurationSecs: 253.735,
			TrackViewURL: testAnchorWeiyiURL},
		"312654337": {TrackName: "唯一", ArtistName: "王力宏", AlbumName: "The Only One", AlbumID: 312654283, DurationSecs: 262.013},
		"1":         {TrackName: "Love Never Felt So Good", ArtistName: "Michael Jackson", AlbumName: "XSCAPE (Deluxe)", DurationSecs: 234.9, TrackViewURL: first},
		"17":        {TrackName: "Love Never Felt So Good", ArtistName: "Michael Jackson", AlbumName: "XSCAPE (Deluxe)", DurationSecs: 245.7, TrackViewURL: second},
	}
	appleCatalogMu.Unlock()
	cases := []struct {
		name, artist, title, album string
		secs                       float64
		want                       string
	}{
		{"署名专辑时长都对得上", "邓紫棋", "唯一", "T.I.M.E. - EP", 254, testAnchorWeiyiURL},
		{"时长未知、只有一条", "邓紫棋", "唯一", "T.I.M.E. - EP", 0, testAnchorWeiyiURL},
		{"别人的同名歌", "周杰伦", "唯一", "T.I.M.E. - EP", 254, ""},
		{"没报专辑名", "邓紫棋", "唯一", "", 254, ""},
		{"时长差得远", "邓紫棋", "唯一", "T.I.M.E. - EP", 300, ""},
		{"旧锚点没有页面地址", "王力宏", "唯一", "The Only One", 262, ""},
		{"同名两条按时长挑", "Michael Jackson", "Love Never Felt So Good", "XSCAPE (Deluxe)", 245.5, second},
		{"同名两条、时长未知不挑", "Michael Jackson", "Love Never Felt So Good", "XSCAPE (Deluxe)", 0, ""},
	}
	for _, c := range cases {
		if got := appleCatalogLinkFor(c.artist, c.title, c.album, c.secs); got != c.want {
			t.Errorf("%s: 得到 %q,想要 %q", c.name, got, c.want)
		}
	}
	// 播放路径刚核对过的那条(索引)优先于落盘缓存里同一个键下的几条。
	appleCatalogMu.Lock()
	appleCatalogByTrack[appleCatalogIndexKey("Love Never Felt So Good", "XSCAPE (Deluxe)")] = appleCatalogCache["1"]
	appleCatalogMu.Unlock()
	if got := appleCatalogLinkFor("Michael Jackson", "Love Never Felt So Good", "XSCAPE (Deluxe)", 0); got != first {
		t.Errorf("索引里那条优先,得到 %q", got)
	}
}

func TestPickAppleCatalogAnchor(t *testing.T) {
	two := []appleCatalogTrack{{DurationSecs: 234.9}, {DurationSecs: 245.7}}
	cases := []struct {
		name string
		fits []appleCatalogTrack
		secs float64
		want int
	}{
		{"没有候选", nil, 200, -1},
		{"时长未知、一条", two[:1], 0, 0},
		{"时长未知、两条分不出", two, 0, -1},
		{"挑最接近的", two, 245, 1},
		{"差 1.9 秒还算", two[:1], 236.8, 0},
		{"差 2.1 秒不算", two[:1], 237, -1},
		{"锚点没有时长的不认", []appleCatalogTrack{{}}, 200, -1},
	}
	for _, c := range cases {
		if got := pickAppleCatalogAnchor(c.fits, c.secs); got != c.want {
			t.Errorf("%s: 得到 %d,想要 %d", c.name, got, c.want)
		}
	}
}

func TestApplyAppleCatalogLinkLocked(t *testing.T) {
	e := enrichEntry{AppleURL: "https://music.apple.com/us/album/x/1?i=2"}
	if applyAppleCatalogLinkLocked(&e, "") || e.AppleURL == "" {
		t.Error("没有锚点链接时不动")
	}
	if !applyAppleCatalogLinkLocked(&e, testAnchorWeiyiURL) || e.AppleURL != testAnchorWeiyiURL {
		t.Errorf("有锚点链接时换成它: %q", e.AppleURL)
	}
	if applyAppleCatalogLinkLocked(&e, testAnchorWeiyiURL) {
		t.Error("已经是它时报没改(不用落盘)")
	}
}

// 挑候选:空链接补、指向别的曲目 ID 的换,时长变体键按去掉后缀的标题找;已经指向其中一条的、没报专辑名的、
// 署名或时长对不上的不动。
func TestAppleCatalogLinkCandidates(t *testing.T) {
	anchors := map[string][]appleCatalogAnchorEntry{}
	add := func(id string, tr appleCatalogTrack) {
		k := appleCatalogIndexKey(tr.TrackName, tr.AlbumName)
		anchors[k] = append(anchors[k], appleCatalogAnchorEntry{trackID: id, track: tr})
	}
	add("1717030438", appleCatalogTrack{TrackName: "唯一", ArtistName: "邓紫棋", AlbumName: "T.I.M.E. - EP", DurationSecs: 253.735})
	add("312654337", appleCatalogTrack{TrackName: "唯一", ArtistName: "王力宏", AlbumName: "The Only One", DurationSecs: 262.013})
	add("597217626", appleCatalogTrack{TrackName: "一个人想着一个人", ArtistName: "曾沛慈", AlbumArtist: "群星",
		AlbumName: "终极一班2 (电视原声带)", DurationSecs: 243.667})
	add("1890111303", appleCatalogTrack{TrackName: "We on Fire", ArtistName: "&TEAM", AlbumName: "We on Fire - EP", DurationSecs: 190})
	add("1", appleCatalogTrack{TrackName: "Love Never Felt So Good", ArtistName: "Michael Jackson", AlbumName: "XSCAPE (Deluxe)", DurationSecs: 234.9})
	add("17", appleCatalogTrack{TrackName: "Love Never Felt So Good", ArtistName: "Michael Jackson", AlbumName: "XSCAPE (Deluxe)", DurationSecs: 245.7})
	const otherEdition = "https://music.apple.com/us/album/x/1890111301?i=1890111736&uo=4"
	entries := map[string]enrichEntry{
		"邓紫棋|唯一|T.I.M.E. - EP": {DurationSecs: 254},
		"曾沛慈|一个人想着一个人|终极一班2 (电视原声带)": {AppleURL: "https://music.apple.com/cn/album/x/597217620?i=597217626&uo=4",
			DurationSecs: 244},
		"&TEAM|We on Fire|We on Fire - EP":                               {AppleURL: otherEdition, ResolvedDurationSecs: 190.4},
		"Michael Jackson|Love Never Felt So Good|XSCAPE (Deluxe)":        {ResolvedDurationSecs: 234.9},
		"Michael Jackson|Love Never Felt So Good~dur246|XSCAPE (Deluxe)": {DurationSecs: 245.7},
		"王力宏|唯一|The Only One":                                            {DurationSecs: 300},
		"周杰伦|唯一|T.I.M.E. - EP":                                           {DurationSecs: 254},
		"邓紫棋|唯一|":                                                        {DurationSecs: 254},
	}
	got := appleCatalogLinkCandidates(entries, anchors)
	want := []appleCatalogLinkCandidate{
		{key: "&TEAM|We on Fire|We on Fire - EP", url: otherEdition, trackID: "1890111303"},
		{key: "Michael Jackson|Love Never Felt So Good|XSCAPE (Deluxe)", url: "", trackID: "1"},
		{key: "Michael Jackson|Love Never Felt So Good~dur246|XSCAPE (Deluxe)", url: "", trackID: "17"},
		{key: "邓紫棋|唯一|T.I.M.E. - EP", url: "", trackID: "1717030438"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("候选不对:\n得到 %+v\n想要 %+v", got, want)
	}
}

// 端到端:旧锚点先按 ID 批量补页面地址(中国区没有的再问美区),再把对得上的条目换成锚点的页面;对不上的不动。
func TestMigrateAppleCatalogLinks(t *testing.T) {
	withAppleCatalogState(t)
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(country string) (int, string) {
			switch country {
			case "cn":
				return 200, `{"results":[{"wrapperType":"track","trackId":1717030438,"artistName":"邓紫棋","trackTimeMillis":253735,` +
					`"trackViewUrl":"` + testAnchorWeiyiURL + `"}]}`
			case "us":
				return 200, `{"results":[{"wrapperType":"track","trackId":555,"artistName":"Artist","trackTimeMillis":200000,` +
					`"trackViewUrl":"https://music.apple.com/us/album/song/554?i=555&uo=4"}]}`
			}
			return 200, `{"results":[]}`
		})
	const teamAnchor = "https://music.apple.com/cn/album/x/1890111301?i=1890111303&uo=4"
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1717030438": {TrackName: "唯一", ArtistName: "邓紫棋", AlbumName: "T.I.M.E. - EP", DurationSecs: 253.735},
		"555":        {TrackName: "Song", ArtistName: "Artist", AlbumName: "Album", DurationSecs: 200},
		"1890111303": {TrackName: "We on Fire", ArtistName: "&TEAM", AlbumName: "We on Fire - EP", DurationSecs: 190, TrackViewURL: teamAnchor},
	}
	appleCatalogMu.Unlock()
	const untouched = "https://music.apple.com/us/album/x/3?i=4&uo=4"
	withEnrichCache(t, map[string]enrichEntry{
		"邓紫棋|唯一|T.I.M.E. - EP":             {DurationSecs: 254},
		"Artist|Song|Album":                {AppleURL: "https://music.apple.com/us/album/x/1?i=2&uo=4", DurationSecs: 200},
		"&TEAM|We on Fire|We on Fire - EP": {AppleURL: "https://music.apple.com/us/album/x/1890111301?i=1890111736&uo=4", DurationSecs: 190},
		"Other|Untouched|Album":            {AppleURL: untouched},
	})
	// 先让分桶索引建起来:补到页面地址后它得失效,缓存命中那条路才取得到新地址。
	if got := appleCatalogLinkFor("Artist", "Song", "Album", 200); got != "" {
		t.Fatalf("补之前锚点还没有页面地址: %q", got)
	}
	n, complete := migrateAppleCatalogLinks(context.Background(), migrationScopeOf(migrationAppleCatalogLinks, migrationAppleCatalogLinksVersion), 0)
	if n != 3 || !complete {
		t.Fatalf("应换 3 条且都问成了,实得 %d complete=%v", n, complete)
	}
	if got := appleCatalogLinkFor("Artist", "Song", "Album", 200); got != "https://music.apple.com/us/album/song/554?i=555&uo=4" {
		t.Errorf("补到之后取链接应拿到新地址: %q", got)
	}
	wantURLs := map[string]string{
		"邓紫棋|唯一|T.I.M.E. - EP":             testAnchorWeiyiURL,
		"Artist|Song|Album":                "https://music.apple.com/us/album/song/554?i=555&uo=4",
		"&TEAM|We on Fire|We on Fire - EP": teamAnchor,
		"Other|Untouched|Album":            untouched,
	}
	for k, want := range wantURLs {
		if got := enrichCache[k].AppleURL; got != want {
			t.Errorf("%s: 链接 %q,想要 %q", k, got, want)
		}
	}
	if appleCatalogTrackViewURL("555") == "" || appleCatalogTrackViewURL("1717030438") == "" {
		t.Error("补到的页面地址应写回锚点缓存")
	}
}

// 查询没问成:要补页面地址的那条不动、不算完成;锚点本来就有页面地址的照样换。
func TestMigrateAppleCatalogLinksKeepsEntriesWhenLookupFails(t *testing.T) {
	withAppleCatalogState(t)
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(string) (int, string) { return 503, "" })
	const teamAnchor = "https://music.apple.com/cn/album/x/1890111301?i=1890111303&uo=4"
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1717030438": {TrackName: "唯一", ArtistName: "邓紫棋", AlbumName: "T.I.M.E. - EP", DurationSecs: 253.735},
		"1890111303": {TrackName: "We on Fire", ArtistName: "&TEAM", AlbumName: "We on Fire - EP", DurationSecs: 190, TrackViewURL: teamAnchor},
	}
	appleCatalogMu.Unlock()
	withEnrichCache(t, map[string]enrichEntry{
		"邓紫棋|唯一|T.I.M.E. - EP":             {DurationSecs: 254},
		"&TEAM|We on Fire|We on Fire - EP": {AppleURL: "https://music.apple.com/us/album/x/1890111301?i=1890111736&uo=4", DurationSecs: 190},
	})
	n, complete := migrateAppleCatalogLinks(context.Background(), migrationScopeOf(migrationAppleCatalogLinks, migrationAppleCatalogLinksVersion), 0)
	if n != 1 || complete {
		t.Fatalf("应只换锚点已有页面地址的那 1 条、不算完成,实得 %d complete=%v", n, complete)
	}
	if got := enrichCache["邓紫棋|唯一|T.I.M.E. - EP"].AppleURL; got != "" {
		t.Errorf("没问成的那条不该动: %q", got)
	}
	if got := enrichCache["&TEAM|We on Fire|We on Fire - EP"].AppleURL; got != teamAnchor {
		t.Errorf("锚点已有页面地址的照样换: %q", got)
	}
}

// 问 Apple 的这段时间里条目被别处改写过(比如这首正好重新解析了):写回时链接不是当初读的那个,不动。
func TestMigrateAppleCatalogLinksSkipsEntriesChangedMeanwhile(t *testing.T) {
	withAppleCatalogState(t)
	const key, changed = "邓紫棋|唯一|T.I.M.E. - EP", "https://music.apple.com/cn/album/x/1?i=2&uo=4"
	withStorefrontFake(t,
		func(string) (int, string) { return 200, storefrontNoResult },
		func(string) (int, string) {
			enrichMu.Lock()
			e := enrichCache[key]
			e.AppleURL = changed
			enrichCache[key] = e
			enrichMu.Unlock()
			return 200, `{"results":[{"wrapperType":"track","trackId":1717030438,"trackViewUrl":"` + testAnchorWeiyiURL + `"}]}`
		})
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1717030438": {TrackName: "唯一", ArtistName: "邓紫棋", AlbumName: "T.I.M.E. - EP", DurationSecs: 253.735},
	}
	appleCatalogMu.Unlock()
	withEnrichCache(t, map[string]enrichEntry{key: {DurationSecs: 254}})
	n, complete := migrateAppleCatalogLinks(context.Background(), migrationScopeOf(migrationAppleCatalogLinks, migrationAppleCatalogLinksVersion), 0)
	if n != 0 || !complete {
		t.Fatalf("改写过的那条不换,实得 %d complete=%v", n, complete)
	}
	if got := enrichCache[key].AppleURL; got != changed {
		t.Errorf("别处写下的链接不该被盖掉: %q", got)
	}
}

// 旧锚点播到时补一次页面地址:没有页面地址才查,在飞时不起第二次,Apple 答过(哪怕没给页面地址)不再查。
func TestAppleCatalogLinkRefetch(t *testing.T) {
	withAppleCatalogState(t)
	appleCatalogMu.Lock()
	oldInflight, oldRefetched := appleCatalogInflight, appleCatalogLinkRefetched
	appleCatalogInflight, appleCatalogLinkRefetched = map[int64]bool{}, map[int64]bool{}
	appleCatalogCache = map[string]appleCatalogTrack{
		"1717030438": {TrackName: "唯一", ArtistName: "邓紫棋", AlbumName: "T.I.M.E. - EP"},
		"999":        {TrackName: "No Link", ArtistName: "X", AlbumName: "Y"},
		"597217626":  {TrackName: "一个人想着一个人", TrackViewURL: "https://music.apple.com/cn/album/x/597217620?i=597217626&uo=4"},
	}
	appleCatalogMu.Unlock()
	t.Cleanup(func() {
		appleCatalogMu.Lock()
		appleCatalogInflight, appleCatalogLinkRefetched = oldInflight, oldRefetched
		appleCatalogMu.Unlock()
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("id") == "999" {
			_, _ = w.Write([]byte(`{"results":[{"wrapperType":"track","trackName":"No Link","artistName":"X","collectionName":"Y"}]}`))
			return
		}
		_, _ = w.Write([]byte(`{"results":[{"wrapperType":"track","trackName":"唯一","artistName":"邓紫棋","collectionName":"T.I.M.E. - EP",` +
			`"collectionId":1717030435,"trackTimeMillis":253735,"trackViewUrl":"` + testAnchorWeiyiURL + `"}]}`))
	}))
	t.Cleanup(srv.Close)
	appleCatalogLookupURL = srv.URL
	if appleCatalogLinkRefetchWanted(597217626) {
		t.Error("已有页面地址的不用查")
	}
	if appleCatalogLinkRefetchWanted(42) || appleCatalogLinkRefetchWanted(-5) {
		t.Error("不在缓存里的、不像目录 ID 的不归这里查")
	}
	if !appleCatalogLinkRefetchWanted(1717030438) {
		t.Fatal("旧锚点要补页面地址")
	}
	if appleCatalogLinkRefetchWanted(1717030438) {
		t.Error("在飞时不再起第二次")
	}
	refetchAppleCatalogTrackLink(1717030438)
	if got := appleCatalogTrackViewURL("1717030438"); got != testAnchorWeiyiURL {
		t.Errorf("补到的页面地址应写进缓存: %q", got)
	}
	if appleCatalogLinkRefetchWanted(1717030438) {
		t.Error("补上之后不再查")
	}
	if !appleCatalogLinkRefetchWanted(999) {
		t.Fatal("另一条旧锚点也要补")
	}
	refetchAppleCatalogTrackLink(999)
	if appleCatalogLinkRefetchWanted(999) {
		t.Error("Apple 答了、只是没给页面地址的,这个进程里不再查")
	}
}

// 三处调用别丢:缓存命中那条(锚点异步到位后靠它换链接)、解析时写链接那一行、播到旧锚点时补页面地址;启动挂上存量迁移。
func TestAppleCatalogLinkCallSites(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("读 %s: %v", name, err)
		}
		return string(b)
	}
	enrich, appsrc, mainSrc := read("enrich.go"), read("appsource.go"), read("main.go")
	for _, needle := range []string{
		"anchorLink := appleCatalogLinkFor(artist, title, album, durationSecs)",
		"if applyAppleCatalogLinkLocked(&e, anchorLink) {",
		"if u := appleCatalogLinkFor(artist, title, album, durationSecs); u != \"\" {",
	} {
		if !strings.Contains(enrich, needle) {
			t.Errorf("enrich.go 缺: %s", needle)
		}
	}
	if !strings.Contains(appsrc, "prefetchAppleCatalogTrackLink(trackID)") {
		t.Error("appsource.go 缺播到旧锚点时补页面地址")
	}
	if !strings.Contains(mainSrc, "startAppleCatalogLinkMigration(ctx)") {
		t.Error("main.go 缺启动存量迁移")
	}
}
