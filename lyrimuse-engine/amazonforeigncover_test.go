package main

import (
	"path/filepath"
	"strings"
	"testing"
)

const (
	amazonTestSingleCover = "https://m.media-amazon.com/images/I/5194nbHWBoL._SX500_.jpg"
	amazonTestAlbumCover  = "https://m.media-amazon.com/images/I/41HYcIwgNiL._SX500_.jpg"
)

// useAmazonSingleAndAlbumVersion:目录缓存里同一位歌手、同名的两轨,B0TESTAAA2 是单曲(专辑「I Can't Love You Anymore」),
// B0TESTAAA3 收在「Greatest Hits」里、专辑图是另一张。App 报的当前曲目、队列、整份缓存的 ASIN 索引、播放器封面的记忆都换成空的。
func useAmazonSingleAndAlbumVersion(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	savedLS := amazonLocalStorageOverride
	amazonLocalStorageOverride = dir
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	noteAmazonCurrentTrack(amazonMusicBundleID, "", "", "")
	amazonQueueMu.Lock()
	savedQueue := amazonQueueASINs
	amazonQueueASINs = map[string]string{}
	amazonQueueMu.Unlock()
	resetASINs := func() {
		amazonCachedASINsMu.Lock()
		amazonCachedASINs = nil
		amazonCachedASINsMu.Unlock()
	}
	resetCovers := func() {
		playerCoverMu.Lock()
		playerCoverMemo = map[string]playerCoverAt{}
		playerCoverMu.Unlock()
	}
	resetASINs()
	resetCovers()
	t.Cleanup(func() {
		amazonLocalStorageOverride = savedLS
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
		amazonQueueMu.Lock()
		amazonQueueASINs = savedQueue
		amazonQueueMu.Unlock()
		resetASINs()
		resetCovers()
	})
	other := strings.NewReplacer(`"B0TESTAAA2"`, `"B0TESTAAA3"`,
		`"name":"I Can't Love You Anymore","asin":"B0TESTALB1"`, `"name":"Greatest Hits","asin":"B0TESTALB2"`,
		"5194nbHWBoL", "41HYcIwgNiL").Replace(amazonTestCatalogValue)
	testWriteLog(t, filepath.Join(dir, "000015.log"), [][]testLDBEntry{{
		{key: amazonCatalogKeyPrefix + "B0TESTAAA2", seq: 5, value: amazonTestCatalogValue},
		{key: amazonCatalogKeyPrefix + "B0TESTAAA3", seq: 6, value: other},
	}})
}

// 单曲那一条:缓存里同一位歌手 + 歌名只记着专辑版的 ASIN。App 还没报当前曲目时按它认到专辑版,目录里那一轨的专辑名对不上,
// 播放器封面不给;App 报出单曲的 ASIN 之后当场按它重读,不等记忆过期。专辑版那一条照常拿专辑版的图。
func TestAmazonPlayingCoverSameTitleOtherAlbum(t *testing.T) {
	useAmazonSingleAndAlbumVersion(t)
	const artist, title = "Ella Langley & Morgan Wallen", "I Can't Love You Anymore [Explicit]"
	withEnrichCache(t, map[string]enrichEntry{
		"Ella Langley & Morgan Wallen|I Can't Love You Anymore|Greatest Hits": {AmazonURL: "https://music.amazon.com/tracks/B0TESTAAA3"},
	})
	if got := playerCoverURLFor(amazonMusicBundleID, artist, title, "I Can't Love You Anymore", 229, kkboxPlayingInfo{}); got != "" {
		t.Errorf("按歌手 + 歌名认到的是专辑版,专辑对不上,不给: %q", got)
	}
	if got := playerCoverURLFor(amazonMusicBundleID, artist, title, "Greatest Hits", 229, kkboxPlayingInfo{}); got != amazonTestAlbumCover {
		t.Errorf("专辑版那一条拿专辑版的图: %q", got)
	}
	noteAmazonCurrentTrack(amazonMusicBundleID, artist, title, "asin://B0TESTAAA2")
	if got := playerCoverURLFor(amazonMusicBundleID, artist, title, "I Can't Love You Anymore", 229, kkboxPlayingInfo{}); got != amazonTestSingleCover {
		t.Errorf("App 报出单曲的 ASIN 后当场拿单曲的图: %q", got)
	}
}

func TestBuildAmazonCoverAlbums(t *testing.T) {
	useAmazonSingleAndAlbumVersion(t)
	got := buildAmazonCoverAlbums()
	if a := got[amazonTestAlbumCover]; len(a) != 1 || a[0] != (amazonCoverAlbum{name: "Greatest Hits", asin: "B0TESTALB2"}) {
		t.Errorf("专辑版那张图: %+v", a)
	}
	if a := got[amazonTestSingleCover]; len(a) != 1 || a[0].name != "I Can't Love You Anymore" {
		t.Errorf("单曲那张图: %+v", a)
	}
}

func TestAmazonForeignPlayerCover(t *testing.T) {
	coverAlbums := map[string][]amazonCoverAlbum{
		amazonTestAlbumCover:  {{name: "Greatest Works Of Art", asin: "B0CR5RZ35F"}},
		amazonTestSingleCover: {{name: "I Truly Believe", asin: "B0CR5F3MG8"}},
	}
	covers := func(c string) map[string]string { return map[string]string{amazonMusicBundleID: c} }
	for _, c := range []struct {
		name, key string
		e         enrichEntry
		foreign   bool
	}{
		{"单曲那一条记着专辑版的图", "Jay Chou|I Truly Believe|I Truly Believe", enrichEntry{PlayerCovers: covers(amazonTestAlbumCover)}, true},
		{"单曲那一条记着单曲的图", "Jay Chou|I Truly Believe|I Truly Believe", enrichEntry{PlayerCovers: covers(amazonTestSingleCover)}, false},
		{"专辑版那一条记着专辑版的图(专辑写法大小写不同)", "Jay Chou|I Truly Believe|Greatest Works of Art", enrichEntry{PlayerCovers: covers(amazonTestAlbumCover)}, false},
		{"报过原样写法的按它比", "Jay Chou|I Truly Believe|", enrichEntry{PlayerCovers: covers(amazonTestAlbumCover),
			Reported: map[string]reportedName{amazonMusicBundleID: {Album: "I Truly Believe"}}}, true},
		{"没有专辑判不了", "Jay Chou|I Truly Believe|", enrichEntry{PlayerCovers: covers(amazonTestAlbumCover)}, false},
		{"目录里没有用这张图的判不了", "Jay Chou|I Truly Believe|I Truly Believe", enrichEntry{PlayerCovers: covers("https://m.media-amazon.com/images/I/none._SX500_.jpg")}, false},
		{"别家的播放器封面不看", "Jay Chou|I Truly Believe|I Truly Believe", enrichEntry{PlayerCovers: map[string]string{neteaseMusicBundleID: amazonTestAlbumCover}}, false},
	} {
		if _, got := amazonForeignPlayerCover(c.key, c.e, coverAlbums); got != c.foreign {
			t.Errorf("%s: 判成 %v", c.name, got)
		}
	}
}

// 存量:单曲那一条用着专辑版的图当封面、记着专辑版的专辑 ASIN,三样一起清;同专辑借了这张图的一起清;专辑版那一条不动;记水位。
func TestCleanAmazonForeignPlayerCovers(t *testing.T) {
	withTempMigrationState(t)
	const single, sibling, album = "Jay Chou|I Truly Believe|I Truly Believe", "Jay Chou|I Truly Believe (Live)|I Truly Believe",
		"Jay Chou|I Truly Believe|Greatest Works Of Art"
	withEnrichCache(t, map[string]enrichEntry{
		single: {CoverURL: amazonTestAlbumCover, CoverSource: "player", CoverAlbum: "I Truly Believe", PeripheralRetryCount: 3,
			PlayerCovers:    map[string]string{amazonMusicBundleID: amazonTestAlbumCover, neteaseMusicBundleID: "https://p1.music.126.net/x/1.jpg"},
			AmazonURL:       "https://music.amazon.com/tracks/B0CR5H2FRS",
			AmazonAlbumASIN: "B0CR5RZ35F", AmazonArtistASIN: "B0012N2PF2"},
		sibling: {CoverURL: amazonTestAlbumCover, CoverSource: "player", CoverAlbum: "I Truly Believe"},
		album: {CoverURL: "file:///tmp/device.jpg", CoverSource: "device", PlayerCovers: map[string]string{amazonMusicBundleID: amazonTestAlbumCover},
			AmazonAlbumASIN: "B0CR5RZ35F"},
	})
	scope := migrationScopeOf(migrationAmazonForeignPlayerCovers, migrationAmazonForeignPlayerCoversVersion)
	n := cleanAmazonForeignPlayerCovers(scope, map[string][]amazonCoverAlbum{amazonTestAlbumCover: {{name: "Greatest Works Of Art", asin: "B0CR5RZ35F"}}})
	if n != 2 {
		t.Fatalf("单曲那一条和借图的那一条,应改 2 条,实改 %d", n)
	}
	e := enrichCache[single]
	if e.CoverURL != "" || e.CoverSource != "" || e.PeripheralRetryCount != 0 || e.AmazonAlbumASIN != "" {
		t.Errorf("封面一族、专辑 ASIN 清掉,外围补全计数归零: %+v", e)
	}
	if _, ok := e.PlayerCovers[amazonMusicBundleID]; ok || e.PlayerCovers[neteaseMusicBundleID] == "" {
		t.Errorf("只拿掉 Amazon 那张播放器封面: %v", e.PlayerCovers)
	}
	if e.AmazonArtistASIN != "B0012N2PF2" || e.AmazonURL == "" {
		t.Errorf("歌手 ASIN、曲目页不动: %+v", e)
	}
	if e := enrichCache[sibling]; e.CoverURL != "" {
		t.Errorf("同专辑借了这张图的一起清: %+v", e)
	}
	if e := enrichCache[album]; e.PlayerCovers[amazonMusicBundleID] != amazonTestAlbumCover || e.AmazonAlbumASIN != "B0CR5RZ35F" {
		t.Errorf("专辑版那一条不动: %+v", e)
	}
	if !migrationDone(migrationAmazonForeignPlayerCovers, migrationAmazonForeignPlayerCoversVersion) {
		t.Error("要记水位")
	}
}
