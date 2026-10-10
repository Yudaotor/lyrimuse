package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// 播放器给的 ISRC 只认 App 报的 Amazon Music 当前曲目:不在放的时候,队列和缓存索引里同名那一条的号都不给。
func TestAmazonPlaybackISRCOnlyForCurrentTrack(t *testing.T) {
	localStorage, _ := useTempAmazonData(t)
	testWriteLog(t, filepath.Join(localStorage, "000016.log"), [][]testLDBEntry{{
		{key: "*.MusicContent.CacheEntry.PrimeCatalog_KATANA_B0TESTALB2", seq: 9, value: amazonTestAlbumLookupValue},
	}})
	reset := func() {
		amazonISRCIndexMu.Lock()
		amazonISRCIndex = nil
		amazonISRCIndexMu.Unlock()
		amazonCachedASINsMu.Lock()
		amazonCachedASINs = nil
		amazonCachedASINsMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
	withEnrichCache(t, map[string]enrichEntry{
		"Khalil Fong|Stressed|Another Album": {AmazonURL: "https://music.amazon.com/tracks/B0TESTTRK1"},
	})
	identity := amazonTrackIdentity("Khalil Fong", "Stressed")
	amazonQueueMu.Lock()
	amazonQueueASINs[identity] = "B0TESTTRK1"
	amazonQueueMu.Unlock()
	t.Cleanup(func() {
		amazonQueueMu.Lock()
		delete(amazonQueueASINs, identity)
		amazonQueueMu.Unlock()
	})
	if got := playbackISRC("Khalil Fong", "Stressed", "JOURNEY TO THE WEST"); got != "" {
		t.Errorf("没在用 Amazon Music 放这首,队列和缓存里同名那一条的号不该给: %q", got)
	}
	amazonCurrentMu.Lock()
	saved := amazonCurrentTrack
	amazonCurrentTrack.artist, amazonCurrentTrack.title, amazonCurrentTrack.trackID = "Khalil Fong", "Stressed", "asin://B0TESTTRK1"
	amazonCurrentMu.Unlock()
	t.Cleanup(func() {
		amazonCurrentMu.Lock()
		amazonCurrentTrack = saved
		amazonCurrentMu.Unlock()
	})
	if got := playbackISRC("Khalil Fong", "Stressed", "JOURNEY TO THE WEST"); got != "HKC381600015" {
		t.Errorf("App 报的当前曲目照样给: %q", got)
	}
}

func TestAmazonBorrowedISRCs(t *testing.T) {
	isrcOf := map[string]string{"B0EXPL0001": "USUM72601820", "B0EXPL0002": "USUM72601823", "B0CLEAN002": "USUM72601823",
		"B0ALBUM001": "USUG12607376"}
	entries := map[string]enrichEntry{
		"Ariana Grande|kiss me|petal [Explicit]": {AmazonURL: "https://music.amazon.com/tracks/B0EXPL0001", ISRCs: []string{"USUM72601820"}},
		"Ariana Grande|kiss me|petal [Clean]":    {ISRCs: []string{"USUM72601820"}},
		"Ariana Grande|kiss me|petal":            {ISRCs: []string{"USUM72601820"}},
		// 自己用 Amazon 放过、自己那一轨也是这个号的不动。
		"Ariana Grande|stay|petal [Explicit]": {AmazonURL: "https://music.amazon.com/tracks/B0EXPL0002", ISRCs: []string{"USUM72601823"}},
		"Ariana Grande|stay|petal [Clean]":    {AmazonURL: "https://music.amazon.com/tracks/B0CLEAN002", ISRCs: []string{"USUM72601823"}},
		// 单曲与专辑版多半是同一份录音,不动。
		"Morgan Wallen|Been By Now|Been By Now":          {AmazonURL: "https://music.amazon.com/tracks/B0ALBUM001", ISRCs: []string{"USUG12607376"}},
		"Morgan Wallen|Been By Now|Been By Now - Single": {ISRCs: []string{"USUG12607376"}},
	}
	got := amazonBorrowedISRCs(entries, entries, isrcOf)
	want := map[string][]string{"Ariana Grande|kiss me|petal [Clean]": {"USUM72601820"}}
	if len(got) != len(want) || !slices.Equal(got["Ariana Grande|kiss me|petal [Clean]"], want["Ariana Grande|kiss me|petal [Clean]"]) {
		t.Errorf("只拿删减版与不删减版对冲的那一条: %v", got)
	}
}

func TestCleanAmazonBorrowedISRCs(t *testing.T) {
	withTempMigrationState(t)
	const clean = "Ariana Grande|kiss me|petal [Clean]"
	withEnrichCache(t, map[string]enrichEntry{
		"Ariana Grande|kiss me|petal [Explicit]": {AmazonURL: "https://music.amazon.com/tracks/B0EXPL0001", ISRCs: []string{"USUM72601820"}},
		clean:                                    {ISRCs: []string{"USUM72601820"}, DurationSecs: 219.58},
	})
	scope := migrationScopeOf(migrationAmazonBorrowedISRCs, migrationAmazonBorrowedISRCsVersion)
	if n := cleanAmazonBorrowedISRCs(scope, map[string]string{"B0EXPL0001": "USUM72601820"}); n != 1 {
		t.Fatalf("应改一条,实改 %d", n)
	}
	if e := enrichCache[clean]; e.ISRCs != nil || e.DurationSecs != 219.58 {
		t.Errorf("借来的号拿掉,别的不动: %+v", e)
	}
	if !migrationDone(migrationAmazonBorrowedISRCs, migrationAmazonBorrowedISRCsVersion) {
		t.Error("要记水位")
	}
}

func TestAmazonCatalogReadable(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "plain")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !amazonCatalogReadable(dir) || !amazonCatalogReadable(filepath.Join(dir, "missing")) || !amazonCatalogReadable("") {
		t.Error("读得了、没装过都算读过")
	}
	if amazonCatalogReadable(file) {
		t.Error("读出错不算读过")
	}
}
