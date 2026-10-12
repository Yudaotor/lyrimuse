package main

import (
	"fmt"
	"maps"
	"os"
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
	migrateListenDurations([]listenLogLine{
		{T: "l", AR: "A", TI: "Song", AL: "One", DUR: 200},
		{T: "l", AR: "A", TI: "Song", AL: "One", DUR: 201.5},
		{T: "l", AR: "B", TI: "Tune", AL: "Two", DUR: 200},
		{T: "l", AR: "B", TI: "Tune", AL: "Two", DUR: 260},
		{T: "l", AR: "C", TI: "Air", AL: "Three", DUR: 300},
		{T: "s", AR: "D", TI: "Wind", AL: "Four", DUR: 150},
		{T: "l", AR: "E", TI: "Rain", AL: "Five", DUR: 0},
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
