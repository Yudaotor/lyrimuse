package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// withDeferredEnrichSaves:按真机的节奏落盘(整份落盘延后一小时、小文件攒一小时、写小文件这一步不真写),主缓存指到临时文件
// (单条快照跟着写到它旁边),待落盘记账换一份空的;返回主缓存路径。测试结束还原。
func withDeferredEnrichSaves(t *testing.T) string {
	t.Helper()
	restoreEnrichSaveStateOnCleanup(t)
	path := filepath.Join(t.TempDir(), "lyrimuse-enrich-cache.json")
	enrichMu.Lock()
	savedKeys, savedSeq, savedPath, savedDirty := enrichPendingKeys, enrichPendingSeq, enrichPath, enrichDirty
	enrichPendingKeys, enrichPath = map[string]uint64{}, path
	enrichMu.Unlock()
	savedNow, savedDelay := enrichPendingNow, enrichPendingWriteDelay
	enrichPendingNow, enrichPendingWriteDelay = func() {}, time.Hour
	enrichBackgroundSaveDelay = time.Hour
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled = true
	cancelEnrichDeferredSaveLocked()
	enrichSaveThrottleMu.Unlock()
	stopEnrichPendingTimer()
	t.Cleanup(func() {
		stopEnrichPendingTimer()
		enrichPendingNow, enrichPendingWriteDelay = savedNow, savedDelay
		enrichMu.Lock()
		enrichPendingKeys, enrichPendingSeq, enrichPath, enrichDirty = savedKeys, savedSeq, savedPath, savedDirty
		enrichMu.Unlock()
	})
	return path
}

func stopEnrichPendingTimer() {
	enrichPendingTimerMu.Lock()
	if enrichPendingTimer != nil {
		enrichPendingTimer.Stop()
		enrichPendingTimer = nil
	}
	enrichPendingTimerMu.Unlock()
}

// enrichSavesDeferred:这批改动没有当场整份写主缓存,写小文件、延后整份落盘都排上了。
func enrichSavesDeferred(path string) error {
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		return fmt.Errorf("当场整份写了主缓存(%v)", err)
	}
	enrichSaveThrottleMu.Lock()
	deferred := enrichDeferredSaveTimer != nil
	enrichSaveThrottleMu.Unlock()
	enrichPendingTimerMu.Lock()
	pending := enrichPendingTimer != nil
	enrichPendingTimerMu.Unlock()
	if !deferred || !pending {
		return fmt.Errorf("写小文件排上了 %v、延后整份落盘排上了 %v", pending, deferred)
	}
	return nil
}

// readPlayingSnapshot:单条快照里记的 key 和条目;还没有快照返回空。
func readPlayingSnapshot(t *testing.T) (string, enrichEntry) {
	t.Helper()
	b, err := os.ReadFile(playingEntryPath())
	if err != nil {
		return "", enrichEntry{}
	}
	var f playingEntryFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("单条快照解不开: %v", err)
	}
	return f.Key, f.Entry
}

// 一批改动之后:小文件里攒得下就不当场整份写(排一次写小文件、一次延后整份落盘),这批里有正在播的那首就重写它的单条快照;
// 攒满了才当场整份写。
func TestSaveEnrichPendingBatchDefersUnlessPendingFull(t *testing.T) {
	path := withDeferredEnrichSaves(t)
	playing, other := "甲|歌1|专辑1", "乙|歌2|专辑2"
	enrichPlayingKey.Store(&playing)
	withEnrichCache(t, map[string]enrichEntry{playing: {SpotifyAlbumID: "x"}, other: {SpotifyAlbumID: "y"}})
	enrichMu.Lock()
	enrichPendingKeys[playing], enrichPendingKeys[other] = 1, 2
	enrichDirty = true
	enrichMu.Unlock()

	saveEnrichPendingBatch([]string{other})
	if k, _ := readPlayingSnapshot(t); k != "" {
		t.Errorf("这批里没有正在播的那首,不写单条快照: %q", k)
	}
	saveEnrichPendingBatch([]string{other, playing})
	if err := enrichSavesDeferred(path); err != nil {
		t.Fatal(err)
	}
	if k, e := readPlayingSnapshot(t); k != playing || e.SpotifyAlbumID != "x" {
		t.Errorf("这批里有正在播的那首,重写它的单条快照: %q %+v", k, e)
	}

	enrichMu.Lock()
	for i := range enrichPendingMaxKeys - 2 {
		enrichPendingKeys[strings.Repeat("k", i+1)] = uint64(i + 3)
	}
	enrichMu.Unlock()
	saveEnrichPendingBatch(nil)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("小文件攒满了,应当当场整份写: %v", err)
	}
}

// 播放器报的这一首成对记:歌曲 id 换了、没给新专辑时旧专辑跟着删;同一首没读到专辑的留着;换整张表、不原地改。
func TestNotePlayerSongLocked(t *testing.T) {
	orig := map[string]string{neteaseMusicBundleID: "a1"}
	e := enrichEntry{PlayerSongIDs: map[string]string{neteaseMusicBundleID: "1"}, PlayerAlbumIDs: orig}
	if notePlayerSongLocked(&e, neteaseMusicBundleID, "", "a2") || notePlayerSongLocked(&e, neteaseMusicBundleID, "1", "") ||
		notePlayerSongLocked(&e, neteaseMusicBundleID, "1", "a1") {
		t.Error("空的歌曲 id、同一首这一拍没读到专辑、一样的都不算改动")
	}
	if !notePlayerSongLocked(&e, neteaseMusicBundleID, "1", "a2") || e.PlayerAlbumIDs[neteaseMusicBundleID] != "a2" || orig[neteaseMusicBundleID] != "a1" {
		t.Errorf("同一首换了专辑: %v(原来那张表不能被改: %v)", e.PlayerAlbumIDs, orig)
	}
	if !notePlayerSongLocked(&e, neteaseMusicBundleID, "2", "") || e.PlayerSongIDs[neteaseMusicBundleID] != "2" || e.PlayerAlbumIDs != nil {
		t.Errorf("换了一首、没给专辑,旧专辑跟着删: %v %v", e.PlayerSongIDs, e.PlayerAlbumIDs)
	}
	if !notePlayerSongLocked(&e, qqMusicBundleID, "003abcDEF12345", "003albumMID01") || e.PlayerAlbumIDs[qqMusicBundleID] != "003albumMID01" {
		t.Errorf("新的播放器两样都记: %v", e.PlayerAlbumIDs)
	}
}

// 播放器报的专辑挂在播放器那一种命名空间上(跟歌曲 id 成对的才算):同一张专辑里歌曲 id 不同的否决,同一首照常连上。
func TestPlayerAlbumIDsVeto(t *testing.T) {
	ne := func(song, album string) enrichEntry {
		return enrichEntry{DurationSecs: 200, NeteaseURL: "https://music.163.com/song?id=9",
			PlayerSongIDs: map[string]string{neteaseMusicBundleID: song}, PlayerAlbumIDs: map[string]string{neteaseMusicBundleID: album}}
	}
	names := map[string]string{"netease_song:9": "Find Love"}
	vs := []songVariant{
		songTestVariant("Singer|Find Love|Album", ne("1", "500"), names),
		songTestVariant("Singer|Find Love|Album (Deluxe)", ne("2", "500"), names),
	}
	b, of := songTestBuild(t, vs, nil)
	if songTestSame(of, vs[0].key, vs[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "same_album:"+songIDNeteaseSongPlayer {
		t.Errorf("网易云报的同一张专辑里歌曲 id 不同:否决, %+v", b.vetoed)
	}
	vs = []songVariant{
		songTestVariant("Singer|Find Love|Album", ne("1", "500"), names),
		songTestVariant("Singer|Find Love|Album (Deluxe)", ne("1", "500"), names),
	}
	if _, of := songTestBuild(t, vs, nil); !songTestSame(of, vs[0].key, vs[1].key) {
		t.Error("同一张专辑里的同一首照常连上")
	}
	lone := songTestVariant("Singer|Find Love|Album", enrichEntry{PlayerAlbumIDs: map[string]string{neteaseMusicBundleID: "500"}}, nil)
	if lone.albums[songIDNeteaseSongPlayer] != "" {
		t.Errorf("没有成对的歌曲 id 时不挂专辑: %v", lone.albums)
	}
}

// Spotify、Amazon 存量按记下的曲目 id 读本机缓存补专辑、歌手 id:只补没有的;Amazon 的专辑名要对得上;缓存里没有的不动。
func TestBackfillPlayerAlbumIDsFromClientCache(t *testing.T) {
	cachePath := withDeferredEnrichSaves(t)
	playing := "甲|歌1|专辑1"
	enrichPlayingKey.Store(&playing)
	newTestSpotifyAlbumEnv(t, false, true)
	localStorage, _ := useTempAmazonData(t)
	bad := strings.ReplaceAll(strings.ReplaceAll(amazonTestCatalogValue, "B0TESTAAA2", "B0TESTBAD1"), "B0TESTALB1", "bad-album")
	testWriteLog(t, filepath.Join(localStorage, "000016.log"), [][]testLDBEntry{{
		{key: "*.MusicContent.CacheEntry.PrimeCatalog_KATANA_B0TESTBAD1", seq: 9, value: bad},
	}})
	track1, _ := testSpotifyID(1)
	album1, _ := testSpotifyID(100)
	track2, _ := testSpotifyID(2)
	asinURL := amazonTrackURL("asin://B0TESTAAA2")
	withEnrichCache(t, map[string]enrichEntry{
		"甲|歌1|专辑1":      {Players: []string{spotifyBundleID}, SpotifyTrackID: track1},
		"甲|歌1|专辑1 ~ 已有": {Players: []string{spotifyBundleID}, SpotifyTrackID: track1, SpotifyAlbumID: "keepkeepkeepkeepkeep12"},
		"甲|歌2|专辑1":      {Players: []string{spotifyBundleID}, SpotifyTrackID: track2},
		"Ella Langley & Morgan Wallen|I Can't Love You Anymore [Explicit]|I Can't Love You Anymore": {AmazonURL: asinURL},
		"Ella Langley & Morgan Wallen|I Can't Love You Anymore [Explicit]|Different Album":          {AmazonURL: asinURL},
		"别人|没缓存|专辑": {AmazonURL: amazonTrackURL("asin://B0NOTHERE1")},
		"Ella Langley & Morgan Wallen|I Can't Love You Anymore (Bad)|I Can't Love You Anymore": {AmazonURL: amazonTrackURL("asin://B0TESTBAD1")},
		"ella langley|i cant love you anymore|x":                                               {AmazonURL: asinURL, Reported: map[string]reportedName{amazonMusicBundleID: {Title: "I Can't Love You Anymore [Explicit]", Artist: "Ella Langley & Morgan Wallen", Album: "I Can't Love You Anymore"}}},
	})
	if n := backfillPlayerAlbumIDsFromClientCache(); n != 3 {
		t.Errorf("补了 %d 条", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["甲|歌1|专辑1"]; e.SpotifyAlbumID != album1 {
		t.Errorf("Spotify 按曲目 id 补专辑: %+v", e)
	}
	if e := enrichCache["甲|歌1|专辑1 ~ 已有"]; e.SpotifyAlbumID != "keepkeepkeepkeepkeep12" {
		t.Errorf("已有的不动: %+v", e)
	}
	if e := enrichCache["甲|歌2|专辑1"]; e.SpotifyAlbumID != "" {
		t.Errorf("缓存里没有专辑字段的不补: %+v", e)
	}
	if e := enrichCache["Ella Langley & Morgan Wallen|I Can't Love You Anymore [Explicit]|I Can't Love You Anymore"]; e.AmazonAlbumASIN != "B0TESTALB1" || e.AmazonArtistASIN != "B0TESTART1" {
		t.Errorf("Amazon 按 ASIN 补专辑、歌手: %+v", e)
	}
	if e := enrichCache["ella langley|i cant love you anymore|x"]; e.AmazonAlbumASIN != "B0TESTALB1" {
		t.Errorf("报过原样写法的按原样的专辑名比: %+v", e)
	}
	if e := enrichCache["Ella Langley & Morgan Wallen|I Can't Love You Anymore [Explicit]|Different Album"]; e.AmazonAlbumASIN != "" {
		t.Errorf("专辑名对不上的不补: %+v", e)
	}
	if e := enrichCache["别人|没缓存|专辑"]; e.AmazonAlbumASIN != "" {
		t.Errorf("目录缓存里没有的不补: %+v", e)
	}
	if e := enrichCache["Ella Langley & Morgan Wallen|I Can't Love You Anymore (Bad)|I Can't Love You Anymore"]; e.AmazonAlbumASIN != "" {
		t.Errorf("专辑 ASIN 形状不对的不补: %+v", e)
	}
	if got := songSortedKeys(enrichPendingKeys); !slices.Equal(got, []string{
		"Ella Langley & Morgan Wallen|I Can't Love You Anymore [Explicit]|I Can't Love You Anymore",
		"ella langley|i cant love you anymore|x", "甲|歌1|专辑1"}) {
		t.Errorf("补上的条目记进待落盘: %q", got)
	}
	if err := enrichSavesDeferred(cachePath); err != nil {
		t.Error(err)
	}
	if k, e := readPlayingSnapshot(t); k != playing || e.SpotifyAlbumID != album1 {
		t.Errorf("补到正在播的那首,重写它的单条快照: %q %+v", k, e)
	}
}

// 网易云存量按客户端播放历史认放的是哪一首:歌名歌手(报过原样写法的按它)与时长对得上且只有一首时记歌曲 id 与专辑;有歌曲 id 的
// 按 id 补专辑;本机曲库里的、没在网易云上放过的、时长对不上的、同名几个版本分不清的不动。
func TestBackfillNeteasePlayerSongsFromHistory(t *testing.T) {
	path := writeTestNeteaseDBWithHistory(t,
		[]string{neteaseTestTrack("201", "只在曲库", "丁", "专辑E", 100000)},
		[]string{
			neteaseTestTrack("101", "第一首", "甲", "专辑A", 200000),
			neteaseTestTrack("102", "同名", "乙", "专辑B", 180000),
			neteaseTestTrack("103", "同名", "乙", "专辑C", 181000),
			neteaseTestTrack("104", "有 id", "丙", "专辑D", 150000),
			neteaseTestTrack("106", "现场", "庚", "演唱会", 200000),
			`{"id":"105","name":"无专辑","artists":[{"id":"1","name":"己"}],"album":{"id":0,"name":""},"duration":120000}`,
		})
	old := neteaseLocalDBOverride
	neteaseLocalDBOverride = path
	t.Cleanup(func() { neteaseLocalDBOverride = old })
	cachePath := withDeferredEnrichSaves(t)
	playing := "甲|第一首|专辑A"
	enrichPlayingKey.Store(&playing)
	ne := []string{neteaseMusicBundleID}
	withEnrichCache(t, map[string]enrichEntry{
		"甲|第一首|专辑A":               {Players: ne, DurationSecs: 200},
		"Jia & Wu|First Song|专辑A": {Players: ne, DurationSecs: 200, Reported: map[string]reportedName{neteaseMusicBundleID: {Artist: "甲", Title: "第一首"}}},
		"乙|同名|专辑B":                {Players: ne, DurationSecs: 180},
		"丙|别的写法|专辑D":              {Players: ne, PlayerSongIDs: map[string]string{neteaseMusicBundleID: "104"}},
		"己|无专辑|":                  {Players: ne, DurationSecs: 120},
		"丙|有 id|专辑D ~ 已有":         {Players: ne, PlayerSongIDs: map[string]string{neteaseMusicBundleID: "104"}, PlayerAlbumIDs: map[string]string{neteaseMusicBundleID: "77"}},
		"丁|只在曲库|专辑E":              {Players: ne, DurationSecs: 100},
		"甲|第一首|专辑A ~ 别家":          {Players: []string{appleMusicBundleID}, DurationSecs: 200},
		"甲|第一首|专辑A ~ 长":           {Players: ne, DurationSecs: 300},
		"庚|现场|录音室专辑":              {Players: ne, DurationSecs: 211},
	})
	if n := backfillNeteasePlayerSongsFromHistory(context.Background()); n != 4 {
		t.Errorf("补了 %d 条", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, k := range []string{"甲|第一首|专辑A", "Jia & Wu|First Song|专辑A"} {
		if e := enrichCache[k]; e.PlayerSongIDs[neteaseMusicBundleID] != "101" || e.PlayerAlbumIDs[neteaseMusicBundleID] != "900101" {
			t.Errorf("%s: %v %v", k, e.PlayerSongIDs, e.PlayerAlbumIDs)
		}
	}
	if e := enrichCache["丙|别的写法|专辑D"]; e.PlayerAlbumIDs[neteaseMusicBundleID] != "900104" {
		t.Errorf("有歌曲 id 的按 id 补专辑(写法跟历史里的歌名对不上也认): %v", e.PlayerAlbumIDs)
	}
	if e := enrichCache["己|无专辑|"]; e.PlayerSongIDs[neteaseMusicBundleID] != "105" || e.PlayerAlbumIDs != nil {
		t.Errorf("历史里专辑 id 为 0 的只记歌曲: %v %v", e.PlayerSongIDs, e.PlayerAlbumIDs)
	}
	if e := enrichCache["丙|有 id|专辑D ~ 已有"]; e.PlayerAlbumIDs[neteaseMusicBundleID] != "77" {
		t.Errorf("已有的不动: %v", e.PlayerAlbumIDs)
	}
	for _, k := range []string{"乙|同名|专辑B", "丁|只在曲库|专辑E", "甲|第一首|专辑A ~ 别家", "甲|第一首|专辑A ~ 长", "庚|现场|录音室专辑"} {
		if e := enrichCache[k]; e.PlayerSongIDs != nil || e.PlayerAlbumIDs != nil {
			t.Errorf("%s 不该补: %v %v", k, e.PlayerSongIDs, e.PlayerAlbumIDs)
		}
	}
	if got := songSortedKeys(enrichPendingKeys); !slices.Equal(got, []string{"Jia & Wu|First Song|专辑A", "丙|别的写法|专辑D", "己|无专辑|", "甲|第一首|专辑A"}) {
		t.Errorf("补上的条目记进待落盘: %q", got)
	}
	if err := enrichSavesDeferred(cachePath); err != nil {
		t.Error(err)
	}
	if k, e := readPlayingSnapshot(t); k != playing || e.PlayerSongIDs[neteaseMusicBundleID] != "101" {
		t.Errorf("补到正在播的那首,重写它的单条快照: %q %+v", k, e.PlayerSongIDs)
	}
}

// 接线:引擎起来后三种存量补记都跑一次。
func TestPlayerCatalogSweepWiring(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if !strings.Contains(read("poller.go"), "go startPlayerCatalogSweep(ctx)") ||
		!strings.Contains(read("playercatalogbackfill.go"), "\tbackfillSodaPagesFromClientCache()\n\tbackfillPlayerAlbumIDsFromClientCache()\n\tbackfillNeteasePlayerSongsFromHistory(ctx)\n\tbackfillKugouPlayerSongsFromLibrary()\n") {
		t.Error("poller 起补扫,补扫依次跑汽水歌曲页、Spotify / Amazon 专辑、网易云播放历史、酷狗曲库")
	}
}

// testKugouLibRow 是客户端曲库 Allmusic 表里的一行(真机 mixId 是文本、albumId 是整数)。
type testKugouLibRow struct {
	musicName, singer, hash string
	seconds                 float64
	mixID                   string
	albumID, plays          int
}

// writeTestKugouLibrary 建一份带 mixId、albumId、totalPlayCount 的曲库,指过去,测试结束还原。
func writeTestKugouLibrary(t *testing.T, rows []testKugouLibRow) {
	t.Helper()
	var sql strings.Builder
	sql.WriteString("CREATE TABLE Allmusic(musicname TEXT, singer TEXT, albumname TEXT, musichash TEXT, musictime REAL, mixId TEXT, albumId INTEGER, totalPlayCount INTEGER);\n")
	for _, r := range rows {
		fmt.Fprintf(&sql, "INSERT INTO Allmusic VALUES('%s','%s','专辑','%s',%v,'%s',%d,%d);\n",
			strings.ReplaceAll(r.musicName, "'", "''"), strings.ReplaceAll(r.singer, "'", "''"), r.hash, r.seconds, r.mixID, r.albumID, r.plays)
	}
	path := filepath.Join(t.TempDir(), "kugou3.sqlite")
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sql.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("建曲库失败: %v %s", err, out)
	}
	old := kugouLibraryDBOverride
	kugouLibraryDBOverride = path
	t.Cleanup(func() { kugouLibraryDBOverride = old })
}

// 酷狗此刻在放的这首:「此刻在播」plist 里当前曲目的 hash 到曲库查 mixId 与专辑 id;歌名、署名、时长对不上,曲库里没有这个 hash
// 都不认。
func TestKugouPlayingSong(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{{"甲、乙 - 第一首", "甲", "AAAA01", 200}, {"丙 - 第二首", "丙", "AAAA02", 230}}, 0)
	old := kugouNowPlayingOverride
	kugouNowPlayingOverride = kugouQueuePlistOverride
	t.Cleanup(func() { kugouNowPlayingOverride = old })
	writeTestKugouLibrary(t, []testKugouLibRow{{"甲、乙 - 第一首", "甲", "aaaa01", 200, "586000001", 70001, 3}})
	for _, artist := range []string{"甲", "乙"} {
		if mix, album := kugouPlayingSong(artist, "第一首", 200); mix != "586000001" || album != "70001" {
			t.Errorf("%s: %q %q", artist, mix, album)
		}
	}
	for name, c := range map[string]struct {
		artist, title string
		dur           float64
	}{
		"歌名不同": {"甲", "第二首", 200}, "署名对不上": {"丁", "第一首", 200}, "时长对不上": {"甲", "第一首", 300},
	} {
		if mix, _ := kugouPlayingSong(c.artist, c.title, c.dur); mix != "" {
			t.Errorf("%s 不认: %q", name, mix)
		}
	}
	ids := playerCatalogIDsFor(kugouMusicBundleID, "甲", "第一首", "", 200)
	if ids.songID != "586000001" || ids.songAlbum != "70001" {
		t.Errorf("playerCatalogIDsFor 走酷狗那一支: %+v", ids)
	}
	var e enrichEntry
	if !applyPlayerCatalogIDsLocked(&e, kugouMusicBundleID, ids) || e.PlayerSongIDs[kugouMusicBundleID] != "586000001" || e.PlayerAlbumIDs[kugouMusicBundleID] != "70001" {
		t.Errorf("成对记进 PlayerSongIDs / PlayerAlbumIDs: %v %v", e.PlayerSongIDs, e.PlayerAlbumIDs)
	}
	env.writeQueue([]testKugouPlistSong{{"丙 - 第二首", "丙", "AAAA02", 230}}, 0)
	if mix, _ := kugouPlayingSong("丙", "第二首", 230); mix != "" {
		t.Errorf("曲库里没有这个 hash: %q", mix)
	}
}

// 酷狗存量按曲库里放过的歌认:歌名(去掉「歌手 - 」)、署名(报过原样写法的按它)、时长对得上且只有一首才记;没放过的、
// 同名几首分不清的、没在酷狗上放过的、已经有 id 的不动。
func TestBackfillKugouPlayerSongsFromLibrary(t *testing.T) {
	newTestKugouPlistEnv(t)
	writeTestKugouLibrary(t, []testKugouLibRow{
		{"甲 - 第一首", "甲", "AAAA01", 200, "586000001", 70001, 2},
		{"乙 - 同名", "乙", "AAAA02", 180, "586000002", 70002, 1},
		{"乙 - 同名", "乙", "AAAA03", 181, "586000003", 70003, 1},
		{"丙 - 没放过", "丙", "AAAA04", 150, "586000004", 70004, 0},
		{"丁、戊 - 合唱", "丁", "AAAA05", 210, "586000005", 0, 4},
	})
	cachePath := withDeferredEnrichSaves(t)
	playing := "甲|第一首|专辑"
	enrichPlayingKey.Store(&playing)
	kg := []string{kugouMusicBundleID}
	withEnrichCache(t, map[string]enrichEntry{
		"甲|第一首|专辑":      {Players: kg, DurationSecs: 200},
		"Jia|First|专辑":  {Players: kg, DurationSecs: 200, Reported: map[string]reportedName{kugouMusicBundleID: {Artist: "甲", Title: "第一首"}}},
		"乙|同名|专辑":       {Players: kg, DurationSecs: 180},
		"丙|没放过|专辑":      {Players: kg, DurationSecs: 150},
		"戊|合唱|专辑":       {Players: kg, DurationSecs: 210},
		"甲|第一首|专辑 ~ 别家": {Players: []string{appleMusicBundleID}, DurationSecs: 200},
		"甲|第一首|专辑 ~ 长":  {Players: kg, DurationSecs: 300},
		"甲|第一首|专辑 ~ 已有": {Players: kg, DurationSecs: 200, PlayerSongIDs: map[string]string{kugouMusicBundleID: "9"}},
	})
	if n := backfillKugouPlayerSongsFromLibrary(); n != 3 {
		t.Errorf("补了 %d 条", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, k := range []string{"甲|第一首|专辑", "Jia|First|专辑"} {
		if e := enrichCache[k]; e.PlayerSongIDs[kugouMusicBundleID] != "586000001" || e.PlayerAlbumIDs[kugouMusicBundleID] != "70001" {
			t.Errorf("%s: %v %v", k, e.PlayerSongIDs, e.PlayerAlbumIDs)
		}
	}
	if e := enrichCache["戊|合唱|专辑"]; e.PlayerSongIDs[kugouMusicBundleID] != "586000005" || e.PlayerAlbumIDs != nil {
		t.Errorf("全署名里有这位歌手也认;专辑 id 为 0 的只记歌曲: %v %v", e.PlayerSongIDs, e.PlayerAlbumIDs)
	}
	for _, k := range []string{"乙|同名|专辑", "丙|没放过|专辑", "甲|第一首|专辑 ~ 别家", "甲|第一首|专辑 ~ 长"} {
		if e := enrichCache[k]; e.PlayerSongIDs != nil {
			t.Errorf("%s 不该补: %v", k, e.PlayerSongIDs)
		}
	}
	if e := enrichCache["甲|第一首|专辑 ~ 已有"]; e.PlayerSongIDs[kugouMusicBundleID] != "9" {
		t.Errorf("已有的不动: %v", e.PlayerSongIDs)
	}
	if got := songSortedKeys(enrichPendingKeys); !slices.Equal(got, []string{"Jia|First|专辑", "戊|合唱|专辑", "甲|第一首|专辑"}) {
		t.Errorf("补上的条目记进待落盘: %q", got)
	}
	if err := enrichSavesDeferred(cachePath); err != nil {
		t.Error(err)
	}
	if k, e := readPlayingSnapshot(t); k != playing || e.PlayerSongIDs[kugouMusicBundleID] != "586000001" {
		t.Errorf("补到正在播的那首,重写它的单条快照: %q %+v", k, e.PlayerSongIDs)
	}
}

// 客户端曲库的位置:新位置、老位置只有一份在就用它,两份都在用改得晚的,都不在返回新位置。
func TestKugouLibraryDBPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	old := kugouLibraryDBOverride
	kugouLibraryDBOverride = ""
	t.Cleanup(func() { kugouLibraryDBOverride = old })
	current := filepath.Join(home, "Library/Containers/com.kugou.mac.Music/Data/Library/Application Support/com.kugou.mac.Music/kugou3.sqlite")
	legacy := filepath.Join(home, "Library/Containers/com.kugou.mac.Music/Data/Documents/kugou3.sqlite")
	if got := kugouLibraryDBPath(); got != current {
		t.Errorf("都不在: %s", got)
	}
	write := func(p string, at time.Time) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	write(legacy, now.Add(-time.Hour))
	if got := kugouLibraryDBPath(); got != legacy {
		t.Errorf("只有老位置: %s", got)
	}
	write(current, now.Add(-2*time.Hour))
	if got := kugouLibraryDBPath(); got != legacy {
		t.Errorf("两份都在,老位置的改得晚: %s", got)
	}
	write(current, now)
	if got := kugouLibraryDBPath(); got != current {
		t.Errorf("两份都在,新位置的改得晚: %s", got)
	}
}
