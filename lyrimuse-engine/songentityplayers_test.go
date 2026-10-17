package main

import (
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// 放过这条写法的播放器按第一次放的先后记,不重复、空串不记、记满为止。
func TestNotePlayerLocked(t *testing.T) {
	var e enrichEntry
	if !notePlayerLocked(&e, "com.apple.Music") || notePlayerLocked(&e, "com.apple.Music") || notePlayerLocked(&e, "") {
		t.Fatalf("第一次记、重复不记、空串不记: %v", e.Players)
	}
	notePlayerLocked(&e, "com.spotify.client")
	if !slices.Equal(e.Players, []string{"com.apple.Music", "com.spotify.client"}) {
		t.Errorf("按先后排: %v", e.Players)
	}
	for i := 0; i < maxNotedPlayers+3; i++ {
		notePlayerLocked(&e, fmt.Sprintf("x.%d", i))
	}
	if len(e.Players) != maxNotedPlayers {
		t.Errorf("最多记 %d 个: %d", maxNotedPlayers, len(e.Players))
	}
}

// 播放时每一拍进来的那条路(条目已经存在的分支)记下播放器,跟别的「变了才落盘」的字段一起落盘。
func TestTrackEnrichmentNotesPlayer(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func trackEnrichment(")
	if i < 0 {
		t.Fatal("找不到 trackEnrichment")
	}
	body = body[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	if !strings.Contains(body, "\t\tif notePlayerLocked(&e, bundleID) {\n\t\t\tspotifyHintDirty = true\n\t\t}\n") {
		t.Error("trackEnrichment 要记下放这首的播放器")
	}
}

// 只在用某个播放器放时才写进条目的 id 说明那个播放器放过:记在当场记下的后面,不重复;按歌名搜出来的链接不算。
func TestNotePlayersFromRecords(t *testing.T) {
	e := enrichEntry{Players: []string{appleMusicBundleID}, SpotifyTrackID: "4uLU6hMCjMI75M1A2tKUQC",
		YouTubeMusicURL: "https://music.youtube.com/watch?v=abc", NeteaseURL: "https://music.163.com/song?id=1",
		SpotifyURL: "https://open.spotify.com/search/x"}
	if !notePlayersFromRecords(&e) || notePlayersFromRecords(&e) {
		t.Fatalf("第一次补上、第二次不动: %v", e.Players)
	}
	if want := []string{appleMusicBundleID, spotifyBundleID, kasetBundleID}; !slices.Equal(e.Players, want) {
		t.Errorf("got %v, want %v", e.Players, want)
	}
	all := enrichEntry{SpotifyTrackID: "x", KKBOXURL: "x", AmazonURL: "x", SodaURL: "x", YouTubeMusicURL: "x"}
	notePlayersFromRecords(&all)
	if want := []string{spotifyBundleID, kkboxBundleID, amazonMusicBundleID, sodaMusicBundleID, kasetBundleID}; !slices.Equal(all.Players, want) {
		t.Errorf("五样 id 各对应一个播放器: %v", all.Players)
	}
	// 播放器自己给这首记的封面:键就是那个播放器,按键排、跟 id 推出来的不重复记。
	covers := enrichEntry{SpotifyTrackID: "x", PlayerCovers: map[string]string{qqMusicBundleID: "https://q", neteaseMusicBundleID: "https://n",
		spotifyBundleID: "https://s"}}
	if !notePlayersFromRecords(&covers) || !slices.Equal(covers.Players, []string{spotifyBundleID, neteaseMusicBundleID, qqMusicBundleID}) {
		t.Errorf("封面的键也记上: %v", covers.Players)
	}
}

// 没有时长的条目从收听记录补:key 对得上、记了时长的收听才算;几次时长差太多的、已经有时长的、回执行都不动。
func TestMigrateListenDurations(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"A|Song|One":  {},
		"B|Tune|Two":  {},
		"C|Air|Three": {DurationSecs: 180},
		"D|Wind|Four": {},
		"E|Rain|Five": {},
	})
	migrateListenDurations(func() []listenLogLine {
		return []listenLogLine{
			{T: "l", AR: "A", TI: "Song", AL: "One", DUR: 200},
			{T: "l", AR: "A", TI: "Song", AL: "One", DUR: 201.5},
			{T: "l", AR: "B", TI: "Tune", AL: "Two", DUR: 200},
			{T: "l", AR: "B", TI: "Tune", AL: "Two", DUR: 260},
			{T: "l", AR: "C", TI: "Air", AL: "Three", DUR: 300},
			{T: "s", AR: "D", TI: "Wind", AL: "Four", DUR: 150},
			{T: "l", AR: "E", TI: "Rain", AL: "Five", DUR: 0},
		}
	})
	enrichMu.Lock()
	got := map[string]float64{}
	for k, e := range enrichCache {
		got[k] = e.DurationSecs
	}
	enrichMu.Unlock()
	want := map[string]float64{"A|Song|One": 201.5, "B|Tune|Two": 0, "C|Air|Three": 180, "D|Wind|Four": 0, "E|Rain|Five": 0}
	if !maps.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// 存量条目启动时补记,没有这几样 id 的不动;再跑一遍没有改动。
func TestMigratePlayersFromRecords(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"a|有 Spotify id|": {SpotifyTrackID: "4uLU6hMCjMI75M1A2tKUQC"},
		"b|记过别的|":         {Players: []string{qqMusicBundleID}, KKBOXURL: "https://www.kkbox.com/tw/tc/song/x"},
		"c|没有 id|":        {NeteaseURL: "https://music.163.com/song?id=1"},
	})
	migratePlayersFromRecords()
	enrichMu.Lock()
	a, b, c := enrichCache["a|有 Spotify id|"], enrichCache["b|记过别的|"], enrichCache["c|没有 id|"]
	enrichMu.Unlock()
	if !slices.Equal(a.Players, []string{spotifyBundleID}) || !slices.Equal(b.Players, []string{qqMusicBundleID, kkboxBundleID}) || c.Players != nil {
		t.Fatalf("a=%v b=%v c=%v", a.Players, b.Players, c.Players)
	}
	enrichMu.Lock()
	enrichDirty = false
	enrichMu.Unlock()
	migratePlayersFromRecords()
	enrichMu.Lock()
	dirty := enrichDirty
	enrichMu.Unlock()
	if dirty {
		t.Error("再跑一遍不该有改动")
	}
}

// 存量条目的 Apple 链接是锚点、写法键跟锚点的名字一模一样才补记 Apple Music;别的写法借了锚点链接的、链接不是锚点的、
// 已经记过的都不动;再跑一遍没有改动。启动时排在 migratePlayersFromRecords 后面。
func TestMigratePlayersFromAppleAnchors(t *testing.T) {
	withAppleCatalogState(t)
	link := "https://music.apple.com/cn/album/party/1015771701?i=1015771708&uo=4"
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1015771708": {TrackName: "PARTY", ArtistName: "少女时代", AlbumName: "PARTY - Single", DurationSecs: 193.814, TrackViewURL: link},
	}
	appleCatalogMu.Unlock()
	withEnrichCache(t, map[string]enrichEntry{
		"少女时代|PARTY|PARTY - Single":        {AppleURL: link},
		"少女时代|PARTY~dur194|PARTY - Single": {AppleURL: link, Players: []string{spotifyBundleID}},
		"Girls' Generation|PARTY|PARTY":    {AppleURL: link, Players: []string{spotifyBundleID}},
		"少女时代|Lion Heart|Lion Heart":       {AppleURL: "https://music.apple.com/cn/album/x/1?i=2"},
		"少女时代|PARTY~dur193|PARTY - Single": {AppleURL: link, Players: []string{appleMusicBundleID}},
		"少女时代|PARTY~dur195|PARTY - Single": {AppleURL: link, PlayerSongIDs: map[string]string{appleMusicBundleID: "999"}},
	})
	migratePlayersFromAppleAnchors()
	enrichMu.Lock()
	got := map[string][]string{}
	for k, e := range enrichCache {
		got[k] = e.Players
	}
	enrichDirty = false
	enrichMu.Unlock()
	want := map[string][]string{
		"少女时代|PARTY|PARTY - Single":        {appleMusicBundleID},
		"少女时代|PARTY~dur194|PARTY - Single": {spotifyBundleID, appleMusicBundleID},
		"Girls' Generation|PARTY|PARTY":    {spotifyBundleID},
		"少女时代|Lion Heart|Lion Heart":       nil,
		"少女时代|PARTY~dur193|PARTY - Single": {appleMusicBundleID},
		"少女时代|PARTY~dur195|PARTY - Single": {appleMusicBundleID},
	}
	for k, w := range want {
		if !slices.Equal(got[k], w) {
			t.Errorf("%s: %v, want %v", k, got[k], w)
		}
	}
	enrichMu.Lock()
	songIDs := map[string]string{}
	for k, e := range enrichCache {
		songIDs[k] = e.PlayerSongIDs[appleMusicBundleID]
	}
	enrichMu.Unlock()
	if songIDs["少女时代|PARTY|PARTY - Single"] != "1015771708" || songIDs["少女时代|PARTY~dur194|PARTY - Single"] != "1015771708" ||
		songIDs["少女时代|PARTY~dur193|PARTY - Single"] != "1015771708" ||
		songIDs["Girls' Generation|PARTY|PARTY"] != "" || songIDs["少女时代|PARTY~dur195|PARTY - Single"] != "999" {
		t.Errorf("对得上的记上锚点 id(已记过 Apple Music 播放器、还没有 id 的也补),别的写法不记,已经记过的 id 不改: %v", songIDs)
	}
	migratePlayersFromAppleAnchors()
	enrichMu.Lock()
	dirty := enrichDirty
	enrichMu.Unlock()
	if dirty {
		t.Error("再跑一遍不该有改动")
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "startupStep(\"migratePlayersFromRecords\", migratePlayersFromRecords)\n\t// 存量条目按 Apple 目录锚点补记") ||
		!strings.Contains(string(src), "startupStep(\"migratePlayersFromAppleAnchors\", migratePlayersFromAppleAnchors)") {
		t.Error("启动时接在 migratePlayersFromRecords 后面")
	}
}

// 播放器报的歌曲 id 记进 PlayerSongIDs:换成最近一次的、空串不记、换整张表不原地改;它的键也算放过那个播放器。
func TestNotePlayerSongIDLocked(t *testing.T) {
	orig := map[string]string{appleMusicBundleID: "1"}
	e := enrichEntry{PlayerSongIDs: orig}
	if notePlayerSongIDLocked(&e, appleMusicBundleID, "1") || notePlayerSongIDLocked(&e, qqMusicBundleID, "") ||
		notePlayerSongIDLocked(&e, appleMusicBundleID, "") || notePlayerSongIDLocked(&e, "", "x") {
		t.Error("一样的、空串不算改动(空串也不冲掉已记的)")
	}
	if !notePlayerSongIDLocked(&e, qqMusicBundleID, "003abcDEF12345") || !notePlayerSongIDLocked(&e, appleMusicBundleID, "2") {
		t.Fatal("新的播放器、换了 id 要记")
	}
	if want := map[string]string{appleMusicBundleID: "2", qqMusicBundleID: "003abcDEF12345"}; !maps.Equal(e.PlayerSongIDs, want) || orig[appleMusicBundleID] != "1" {
		t.Errorf("got %v(原来那张表 %v 不能被改)", e.PlayerSongIDs, orig)
	}
	f := enrichEntry{PlayerSongIDs: map[string]string{neteaseMusicBundleID: "123"}}
	if !notePlayersFromRecords(&f) || !slices.Equal(f.Players, []string{neteaseMusicBundleID}) {
		t.Errorf("PlayerSongIDs 的键算放过那个播放器: %v", f.Players)
	}
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "if bundleID == appleMusicBundleID && anchorLink != \"\" &&\n\t\t\tnotePlayerSongIDLocked(&e, appleMusicBundleID, appleCatalogIDFromURL(anchorLink)) {") {
		t.Error("Apple Music 在放时,缓存命中那一支把这一拍的锚点 id 记成它报的这一首")
	}
}

// QQ 音乐、网易云在放时,从播放列表取当前这首的歌曲 id 记进 PlayerSongIDs;时长对不上、形状不对的不记。
func TestPlayerCatalogSongIDs(t *testing.T) {
	playerCatalogMu.Lock()
	clear(playerCatalogMemo)
	playerCatalogMu.Unlock()
	t.Cleanup(func() {
		playerCatalogMu.Lock()
		clear(playerCatalogMemo)
		playerCatalogMu.Unlock()
	})
	writeTestQQArchive(t, 1, []testQQSong{
		{title: "第一首", album: "甲", singerInfo: "甲", duration: 200, mid: "001aaaaBBBBccc"},
		{title: "第二首", album: "甲", singerInfo: "甲", duration: 214, mid: "002bbbbCCCCddd", albumMid: "003albumMID01"},
		{title: "第三首", album: "甲", singerInfo: "甲", duration: 230, mid: "bad!", albumMid: "003albumMID01"},
		{title: "第四首", album: "甲", singerInfo: "甲", duration: 240, mid: "004ddddEEEEfff", albumMid: "bad album"},
	})
	if mid, album := qqPlayingSong("甲", "第二首", 214); mid != "002bbbbCCCCddd" || album != "003albumMID01" {
		t.Errorf("QQ 当前这首: %q %q", mid, album)
	}
	if mid, album := qqPlayingSong("甲", "第二首", 260); mid != "" || album != "" {
		t.Errorf("时长对不上不认: %q %q", mid, album)
	}
	if mid, _ := qqPlayingSong("乙", "不在列表里", 200); mid != "" {
		t.Errorf("列表里没有这首: %q", mid)
	}
	if ids := playerCatalogIDsFor(qqMusicBundleID, "甲", "第二首", "甲", 214); ids.songID != "002bbbbCCCCddd" || ids.songAlbum != "003albumMID01" {
		t.Errorf("playerCatalogIDsFor 走 QQ 那一支: %+v", ids)
	}
	if ids := playerCatalogIDsFor(qqMusicBundleID, "甲", "第三首", "甲", 230); ids.songID != "" || ids.songAlbum != "" {
		t.Errorf("形状不对的 mid 不记,专辑跟着不记: %+v", ids)
	}
	if ids := playerCatalogIDsFor(qqMusicBundleID, "甲", "第四首", "甲", 240); ids.songID != "004ddddEEEEfff" || ids.songAlbum != "" {
		t.Errorf("形状不对的专辑 mid 不记: %+v", ids)
	}
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "第一首", album: "甲专辑", artists: []string{"甲"}, durationMS: 100000, id: "101", albumID: 7},
		{title: "第二首", album: "甲专辑", artists: []string{"甲"}, durationMS: 200000, id: "102", albumID: "3009"},
		{title: "第三首", album: "甲专辑", artists: []string{"甲"}, durationMS: 210000, id: "103", albumID: map[string]any{"x": 1}},
	})
	if id, album := neteasePlayingSong("甲", "第二首", 200); id != "102" || album != "3009" {
		t.Errorf("网易云当前这首: %q %q", id, album)
	}
	if id, album := neteasePlayingSong("甲", "第一首", 100); id != "101" || album != "7" {
		t.Errorf("专辑 id 写成数字也认: %q %q", id, album)
	}
	if id, album := neteasePlayingSong("甲", "第三首", 210); id != "103" || album != "" {
		t.Errorf("专辑 id 形状不对时只丢专辑,不连累整份队列: %q %q", id, album)
	}
	if id, _ := neteasePlayingSong("甲", "第二首", 260); id != "" {
		t.Errorf("时长对不上不认: %q", id)
	}
	if id, _ := neteasePlayingSong("乙", "不在队列里", 200); id != "" {
		t.Errorf("队列里没有这首: %q", id)
	}
	for _, raw := range []string{`""`, `"0"`, `0`, `null`, `"12a"`, `{}`} {
		if got := rawDigitsID([]byte(raw)); got != "" {
			t.Errorf("rawDigitsID(%s) = %q", raw, got)
		}
	}
	var e enrichEntry
	if !applyPlayerCatalogIDsLocked(&e, neteaseMusicBundleID, playerCatalogIDs{songID: "102", songAlbum: "3009"}) ||
		e.PlayerSongIDs[neteaseMusicBundleID] != "102" || e.PlayerAlbumIDs[neteaseMusicBundleID] != "3009" {
		t.Errorf("成对记进 PlayerSongIDs / PlayerAlbumIDs: %+v %+v", e.PlayerSongIDs, e.PlayerAlbumIDs)
	}
	if applyPlayerCatalogIDsLocked(&e, neteaseMusicBundleID, playerCatalogIDs{songID: "102", songAlbum: "3009"}) {
		t.Error("一样的不算改动")
	}
	for _, c := range []struct {
		bundleID, id string
		ok           bool
	}{
		{qqMusicBundleID, "002bbbbCCCCddd", true},
		{qqMusicBundleID, "0012345", false},
		{qqMusicBundleID, "002bbbb-CCCCddd", false},
		{neteaseMusicBundleID, "102", true},
		{neteaseMusicBundleID, "102a", false},
		{neteaseMusicBundleID, "123456789012345678901", false},
		{kugouMusicBundleID, "586000001", true},
		{kugouMusicBundleID, "58a", false},
		{appleMusicBundleID, "1015771708", false},
	} {
		if got := playerSongIDOK(c.bundleID, c.id); got != c.ok {
			t.Errorf("playerSongIDOK(%s, %q) = %v", c.bundleID, c.id, got)
		}
	}
}

// 合并两条写法时,落选那条记下的播放器报的歌曲 id,胜者没有的那几个播放器带过来,对应的播放器也记上。
func TestMergePeripheralIntoMergesPlayerSongIDs(t *testing.T) {
	winner := enrichEntry{PlayerSongIDs: map[string]string{appleMusicBundleID: "1", neteaseMusicBundleID: "5"},
		PlayerAlbumIDs: map[string]string{appleMusicBundleID: "a1"}}
	loser := enrichEntry{PlayerSongIDs: map[string]string{appleMusicBundleID: "2", qqMusicBundleID: "003abcDEF12345", neteaseMusicBundleID: "5"},
		PlayerAlbumIDs: map[string]string{appleMusicBundleID: "a2", qqMusicBundleID: "003albumMID01", neteaseMusicBundleID: "9"}}
	got := mergePeripheralInto(winner, loser)
	if want := map[string]string{appleMusicBundleID: "1", qqMusicBundleID: "003abcDEF12345", neteaseMusicBundleID: "5"}; !maps.Equal(got.PlayerSongIDs, want) {
		t.Errorf("got %v, want %v", got.PlayerSongIDs, want)
	}
	if want := map[string]string{appleMusicBundleID: "a1", qqMusicBundleID: "003albumMID01", neteaseMusicBundleID: "9"}; !maps.Equal(got.PlayerAlbumIDs, want) {
		t.Errorf("专辑 id 跟着成对的歌曲 id 走,同一首胜者没记的补上: %v", got.PlayerAlbumIDs)
	}
	if !slices.Contains(got.Players, qqMusicBundleID) || winner.PlayerSongIDs[qqMusicBundleID] != "" {
		t.Errorf("players=%v,winner 原来那张表不能被改: %v", got.Players, winner.PlayerSongIDs)
	}
}

// 合并两条写法时放过的播放器合在一起,补过来的 id 对应的播放器也记上;不改动 winner 原来那份切片。
func TestMergePeripheralIntoMergesPlayers(t *testing.T) {
	orig := make([]string, 1, 4)
	orig[0] = appleMusicBundleID
	winner := enrichEntry{Players: orig}
	loser := enrichEntry{Players: []string{qqMusicBundleID, appleMusicBundleID}, SpotifyTrackID: "x"}
	got := mergePeripheralInto(winner, loser)
	if want := []string{appleMusicBundleID, qqMusicBundleID, spotifyBundleID}; !slices.Equal(got.Players, want) {
		t.Errorf("got %v, want %v", got.Players, want)
	}
	if extended := orig[:2]; extended[1] != "" {
		t.Errorf("winner 原来的切片被写了: %v", extended)
	}
}

// 播放时那条路也按 id 补记,跟当场记下播放器挨着、一起落盘;启动时跑存量补记,排在 key 归一化之后、刷新索引之前。
func TestPlayersFromRecordsWiring(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "\t\tif notePlayersFromRecords(&e) {\n\t\t\tspotifyHintDirty = true\n\t\t}\n\t\tif notePlayerLocked(&e, bundleID) {") {
		t.Error("trackEnrichment 要按 id 补记播放器")
	}
	if !strings.Contains(string(src), "\t\tif e.DurationSecs <= 0 && durationSecs > 0 {\n\t\t\te.DurationSecs = durationSecs\n\t\t\tspotifyHintDirty = true\n\t\t}") {
		t.Error("trackEnrichment 放到没有时长的条目时补上播放器报的时长")
	}
	m, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(m)
	keys, seed, index := strings.Index(body, `startupStep("migrateEnrichKeys"`), strings.Index(body, `startupStep("migratePlayersFromRecords"`), strings.Index(body, `startupStep("refreshEnrichIndex"`)
	if keys < 0 || seed < 0 || index < 0 || !(keys < seed && seed < index) {
		t.Errorf("启动顺序: migrateEnrichKeys=%d migratePlayersFromRecords=%d refreshEnrichIndex=%d", keys, seed, index)
	}
}

// 播放器原样报的写法跟写法键不一样时才记,按播放器分开、换成最近一次的;跟键一样了就删掉;时长变体位标记不算差别。
func TestNoteReportedNameLocked(t *testing.T) {
	var e enrichEntry
	key := "方大同|偷笑|爱爱爱"
	if noteReportedNameLocked(&e, key, qqMusicBundleID, reportedName{Title: "偷笑", Artist: "方大同", Album: "爱爱爱"}) || e.Reported != nil {
		t.Fatalf("跟键一样不记: %v", e.Reported)
	}
	raw := reportedName{Title: "偷笑 (Tou Xiao)", Artist: "方大同", Album: "爱爱爱"}
	if !noteReportedNameLocked(&e, key, qqMusicBundleID, raw) || e.Reported[qqMusicBundleID] != raw {
		t.Fatalf("不一样就记: %v", e.Reported)
	}
	if noteReportedNameLocked(&e, key, qqMusicBundleID, raw) {
		t.Error("同一份不重复记")
	}
	if !noteReportedNameLocked(&e, key, qqMusicBundleID, reportedName{Title: "偷笑", Artist: "方大同", Album: "爱爱爱"}) || e.Reported != nil {
		t.Errorf("最近一次跟键一样了就删掉: %v", e.Reported)
	}
	if noteReportedNameLocked(&e, "方大同|偷笑~dur2|爱爱爱", appleMusicBundleID, reportedName{Title: "偷笑", Artist: "方大同", Album: "爱爱爱"}) {
		t.Error("时长变体位标记不算差别")
	}
	if noteReportedNameLocked(&e, key, "", raw) {
		t.Error("没有播放器不记")
	}
}

// 播放时那条路记下原始写法;合并条目时落选那条记的带过来。
func TestReportedNameWiring(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "\t\tif noteReportedNameLocked(&e, key, bundleID, reported) {\n\t\t\tspotifyHintDirty = true\n\t\t}") {
		t.Error("trackEnrichment 要记下播放器原样报的写法")
	}
	loser := enrichEntry{Reported: map[string]reportedName{qqMusicBundleID: {Title: "偷笑 (Tou Xiao)"}}}
	winner := enrichEntry{Reported: map[string]reportedName{qqMusicBundleID: {Title: "偷笑 (Live)"}}}
	if got := mergePeripheralInto(enrichEntry{}, loser); got.Reported[qqMusicBundleID].Title != "偷笑 (Tou Xiao)" {
		t.Errorf("胜者没有的带过来: %v", got.Reported)
	}
	if got := mergePeripheralInto(winner, loser); got.Reported[qqMusicBundleID].Title != "偷笑 (Live)" {
		t.Errorf("胜者有的不动: %v", got.Reported)
	}
}

// 水位到了整道跳过:收听日志都不读。
func TestMigrateListenDurationsSkipsReadingWhenDone(t *testing.T) {
	saved, savedPath, savedEpoch := migrationState, migrationStatePath, migrationEpoch
	t.Cleanup(func() { migrationState, migrationStatePath, migrationEpoch = saved, savedPath, savedEpoch })
	loadMigrationState(filepath.Join(t.TempDir(), "migrations.json"))
	markMigrationDone(migrationListenDurations, migrationListenDurationsVersion)
	migrateListenDurations(func() []listenLogLine {
		t.Fatal("水位到了不该读收听日志")
		return nil
	})
}
