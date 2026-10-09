package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestLocalLibraryLinkStale(t *testing.T) {
	cases := []struct {
		name              string
		album, entryAlbum string
		secs, entrySecs   float64
		want              bool
	}{
		{"另一张专辑、差 4 秒", "100天", "我们的爱我不放手", 234.919, 238.893, true},
		{"另一张专辑、差不到 1 秒", "100天", "爱情睡醒了 电视原声", 234.919, 234.893, false},
		{"同一张专辑、繁简写法不同", "回到未來", "回到未来", 198.4, 196.0, false},
		{"条目时长未知", "100天", "我们的爱我不放手", 0, 238.893, false},
		{"本机那条时长未知", "100天", "我们的爱我不放手", 234.919, 0, false},
		{"同一张专辑、条目时长是 30 秒试听段", "最动听的...Beyond", "最动听的...Beyond", 30, 256.7, false},
		{"条目没专辑", "", "现场", 200, 300, false},
	}
	for _, c := range cases {
		if got := localLibraryLinkStale(c.album, c.entryAlbum, c.secs, c.entrySecs); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestSodaTrackIDFromURL(t *testing.T) {
	if got := sodaTrackIDFromURL(sodaTrackPageURL("7000000001")); got != "7000000001" {
		t.Errorf("分享页地址应取回曲目 id, got %q", got)
	}
	for _, u := range []string{"", "https://music.douyin.com/qishui/share/track", "https://music.douyin.com/qishui/share/track?track_id=abc"} {
		if got := sodaTrackIDFromURL(u); got != "" {
			t.Errorf("%q 不该取出 id, got %q", u, got)
		}
	}
}

func TestClearStaleLocalLibraryLinks(t *testing.T) {
	covers := map[string]string{neteaseMusicBundleID: "https://p4.music.126.net/a/1.jpg", "com.apple.Music": "file:///x.jpg"}
	e := enrichEntry{
		NeteaseURL: neteaseTestSongURL("27731362"), PlayerCovers: covers,
		QQURL: "https://y.qq.com/n/ryqq/songDetail/000AAAA0000001", QQAlbumMid: "a", QQSingerMid: "s",
		SodaURL: sodaTrackPageURL("7000000001"), SodaAlbumID: "66", SodaArtistID: "55",
		PeripheralRetryCount: peripheralBackfillMaxAttempts,
	}
	got := clearStaleLocalLibraryLinks(e, localLibraryLinkVerdict{neteaseCover: true, sodaSong: true})
	if got.NeteaseURL == "" || got.QQURL == "" || got.PeripheralRetryCount != peripheralBackfillMaxAttempts {
		t.Errorf("没判到的组不该动,只清封面和汽水的 id 不该动补全计数: %+v", got)
	}
	if _, ok := got.PlayerCovers[neteaseMusicBundleID]; ok || got.PlayerCovers["com.apple.Music"] == "" {
		t.Errorf("只清网易云那张播放器封面: %v", got.PlayerCovers)
	}
	if covers[neteaseMusicBundleID] == "" {
		t.Error("播放器封面要换一张新表,不能原地改")
	}
	if got.SodaURL != "" || got.SodaAlbumID != "" || got.SodaArtistID != "" {
		t.Errorf("汽水的链接和专辑 / 歌手 id 一起清: %+v", got)
	}
	got = clearStaleLocalLibraryLinks(e, localLibraryLinkVerdict{qqSong: true})
	if got.QQURL != "" || got.QQAlbumMid != "" || got.QQSingerMid != "" || got.PeripheralRetryCount != 0 {
		t.Errorf("QQ 链接连同专辑 / 歌手 mid 一起清,补全计数归零: %+v", got)
	}
	got = clearStaleLocalLibraryLinks(e, localLibraryLinkVerdict{neteaseSong: true})
	if got.NeteaseURL != "" || got.PeripheralRetryCount != 0 || got.QQURL == "" {
		t.Errorf("只清网易云链接,补全计数归零: %+v", got)
	}
	only := enrichEntry{PlayerCovers: map[string]string{neteaseMusicBundleID: "x"}}
	if got := clearStaleLocalLibraryLinks(only, localLibraryLinkVerdict{neteaseCover: true}); got.PlayerCovers != nil {
		t.Errorf("清完没有别的播放器封面时表置空: %v", got.PlayerCovers)
	}
}

func neteaseTestSongURL(id string) string { return "https://music.163.com/song?id=" + id }

// neteaseTestTrackWithPic:neteaseTestTrack 加上专辑图。
func neteaseTestTrackWithPic(id, name, artist, album, pic string, durationMS int) string {
	var m map[string]any
	if err := json.Unmarshal([]byte(neteaseTestTrack(id, name, artist, album, durationMS)), &m); err != nil {
		panic(err)
	}
	m["album"].(map[string]any)["picUrl"] = pic
	b, err := json.Marshal(m)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// setupLocalLibraryLinkLibraries 造三家本机数据:网易云三版《背对背拥抱》(另两版的专辑图共用一张)、两版《董小姐》,
// QQ 两首,汽水一首两人署名的现场版。
func setupLocalLibraryLinkLibraries(t *testing.T) {
	t.Helper()
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{
		neteaseTestTrackWithPic("27731362", "背对背拥抱", "林俊杰", "我们的爱我不放手", "http://p4.music.126.net/a/1.jpg", 238893),
		neteaseTestTrackWithPic("108418", "背对背拥抱", "林俊杰", "100天", "http://p3.music.126.net/b/2.jpg", 234919),
		neteaseTestTrackWithPic("26305547", "背对背拥抱", "林俊杰", "他是…JJ林俊杰", "http://p3.music.126.net/b/2.jpg", 236893),
		neteaseTestTrack("25702068", "董小姐", "宋冬野", "摩登天空7", 313320),
		neteaseTestTrack("27646198", "董小姐", "宋冬野", "安和桥北", 310213),
	}))
	resetQQLocalIndex(t, writeTestQQDB(t, []qqLocalRow{
		{Mid: "000AAAA0000001", Name: "同名曲", Singer: "歌手丙", Album: "专辑版", MS: 230000},
		{Mid: "000AAAA0000002", Name: "另一首", Singer: "歌手丙", Album: "专辑", MS: 200000},
	}))
	resetSodaLocalIndex(t, writeTestSodaQueue(t, []map[string]any{{
		"id": "7000000001", "name": "汽水曲", "duration": 180000,
		"artists": []map[string]any{{"id": "55", "name": "歌手丁"}, {"id": "56", "name": "歌手戊"}},
		"album":   map[string]any{"id": "66", "name": "现场版"},
	}}))
}

func TestRecheckLocalLibraryLinksClearsOnlyOtherVersions(t *testing.T) {
	withTempMigrationState(t)
	setupLocalLibraryLinkLibraries(t)
	const (
		otherAlbum  = "林俊杰|背对背拥抱|100天"
		sharedCover = "林俊杰|背对背拥抱|100天 (Deluxe)"
		sameAlbum   = "宋冬野|董小姐|安和桥北"
		variant     = "宋冬野|董小姐~dur2|安和桥北"
		noDuration  = "林俊杰|背对背拥抱|新地球"
		otherSong   = "林俊杰|可惜没如果|新地球"
		qqOther     = "歌手丙|同名曲|单曲版"
		qqSame      = "歌手丙|另一首|专辑"
		preview     = "宋冬野|董小姐|摩登天空7"
		sodaOther   = "歌手丁, 歌手戊|汽水曲|录音室版"
	)
	withEnrichCache(t, map[string]enrichEntry{
		otherAlbum: {NeteaseURL: neteaseTestSongURL("27731362"), DurationSecs: 234.919,
			PlayerCovers:         map[string]string{neteaseMusicBundleID: "https://p4.music.126.net/a/1.jpg"},
			PeripheralRetryCount: peripheralBackfillMaxAttempts},
		sharedCover: {DurationSecs: 234.919, PlayerCovers: map[string]string{neteaseMusicBundleID: "https://p3.music.126.net/b/2.jpg"}},
		sameAlbum:   {NeteaseURL: neteaseTestSongURL("27646198"), DurationSecs: 310.213},
		variant:     {NeteaseURL: neteaseTestSongURL("25702068"), ResolvedDurationSecs: 310.213},
		noDuration:  {NeteaseURL: neteaseTestSongURL("27731362")},
		otherSong:   {NeteaseURL: neteaseTestSongURL("27731362"), DurationSecs: 250},
		qqOther: {QQURL: "https://y.qq.com/n/ryqq/songDetail/000AAAA0000001", QQAlbumMid: "a", QQSingerMid: "s",
			DurationSecs: 200},
		qqSame:    {QQURL: "https://y.qq.com/n/ryqq/songDetail/000AAAA0000002", DurationSecs: 200.3},
		preview:   {NeteaseURL: neteaseTestSongURL("25702068"), DurationSecs: 30},
		sodaOther: {SodaURL: sodaTrackPageURL("7000000001"), SodaAlbumID: "66", SodaArtistID: "55", DurationSecs: 200},
	})

	scope := migrationScopeOf(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion)
	if n := recheckLocalLibraryLinks(context.Background(), scope); n != 4 {
		t.Errorf("应清 4 条,实清 %d", n)
	}
	if e := enrichCache[otherAlbum]; e.NeteaseURL != "" || e.PlayerCovers != nil || e.PeripheralRetryCount != 0 {
		t.Errorf("另一张专辑那版的链接和播放器封面应清掉、补全计数归零: %+v", e)
	}
	if e := enrichCache[variant]; e.NeteaseURL != "" {
		t.Errorf("标题带时长变体后缀的照样按曲名查: %+v", e)
	}
	if e := enrichCache[qqOther]; e.QQURL != "" || e.QQAlbumMid != "" || e.QQSingerMid != "" {
		t.Errorf("QQ 另一张专辑那版连同 mid 应清掉: %+v", e)
	}
	if e := enrichCache[sodaOther]; e.SodaURL != "" || e.SodaAlbumID != "" {
		t.Errorf("汽水两人署名的按单个歌手查到、应清掉: %+v", e)
	}
	for key, why := range map[string]string{
		sharedCover: "同一张专辑图有一条认得,封面不清",
		sameAlbum:   "专辑对得上的不清",
		noDuration:  "条目时长未知判不了,不清",
		otherSong:   "记下的 id 不是这一条的候选,不清",
		qqSame:      "QQ 专辑对得上的不清",
		preview:     "专辑对得上、条目时长只是试听段的不清",
	} {
		e := enrichCache[key]
		if e.NeteaseURL == "" && e.QQURL == "" && len(e.PlayerCovers) == 0 {
			t.Errorf("%s: %q 被清了", why, key)
		}
	}
	if !migrationDone(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion) {
		t.Error("三家都读成了,应记水位")
	}
}

func TestRecheckLocalLibraryLinksWaitsForUnreadableLibrary(t *testing.T) {
	withTempMigrationState(t)
	setupLocalLibraryLinkLibraries(t)
	broken := filepath.Join(t.TempDir(), "qqmusic.sqlite")
	if err := os.WriteFile(broken, []byte("not a database"), 0o644); err != nil {
		t.Fatal(err)
	}
	resetQQLocalIndex(t, broken)
	const key = "林俊杰|背对背拥抱|100天"
	withEnrichCache(t, map[string]enrichEntry{key: {NeteaseURL: neteaseTestSongURL("27731362"), DurationSecs: 234.919}})

	recheckLocalLibraryLinks(context.Background(), migrationScopeOf(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion))
	if enrichCache[key].NeteaseURL != "" {
		t.Error("读成了的那家照样判")
	}
	if migrationDone(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion) {
		t.Error("有一家读不了,不该记水位")
	}
}

func TestRecheckLocalLibraryLinksCountsMissingLibrariesAsRead(t *testing.T) {
	withTempMigrationState(t)
	const key = "林俊杰|背对背拥抱|100天"
	withEnrichCache(t, map[string]enrichEntry{key: {NeteaseURL: neteaseTestSongURL("27731362"), DurationSecs: 234.919}})

	if n := recheckLocalLibraryLinks(context.Background(), migrationScopeOf(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion)); n != 0 {
		t.Errorf("三家都没装,一条都不该清,实清 %d", n)
	}
	if !migrationDone(migrationLocalLibraryLinks, migrationLocalLibraryLinksVersion) {
		t.Error("没装的那家算读过,应记水位")
	}
}
