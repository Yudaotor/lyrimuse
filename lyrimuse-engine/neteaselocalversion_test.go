package main

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"
)

// 同名同歌手、两张专辑各收一版、时长一样(林忆莲《至少还有你》:「林忆莲's」256621 与「属于我的林忆莲」256468)。

const (
	neteaseTestOtherPic   = "http://p4.music.126.net/a/109951163829570820.jpg"
	neteaseTestPlayingPic = "http://p4.music.126.net/b/109951171530798085.jpg"
)

// neteaseTestTrackPic 同 neteaseTestTrack,专辑带上客户端记的封面。
func neteaseTestTrackPic(id, name, artist, album string, durationMS int, pic string) string {
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

var (
	neteaseTestOtherVersion   = neteaseTestTrackPic("256621", "至少还有你", "林忆莲", "林忆莲's", 275000, neteaseTestOtherPic)
	neteaseTestPlayingVersion = neteaseTestTrackPic("256468", "至少还有你", "林忆莲", "属于我的林忆莲", 275400, neteaseTestPlayingPic)
)

func withPlayingPlayer(t *testing.T, bundleID string) {
	t.Helper()
	setNativeLyricSourcesForPlayer(bundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
}

// 封面这条路按歌名在曲库里挑时只认专辑对得上、或有一边不知道的记录:另一张专辑里时长差不到 1 秒的那一版歌词照用,封面不给。
func TestNeteaseLocalCoverNeedsAgreeingAlbum(t *testing.T) {
	withPlayingPlayer(t, "")
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{neteaseTestOtherVersion}))
	if s, ok := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275); !ok || s.ID != 256621 {
		t.Fatalf("身份那条路照旧认下另一张专辑里时长一样的那一版: ok=%v id=%d", ok, s.ID)
	}
	if got := neteaseLocalCoverURL("林忆莲", "至少还有你", "属于我的林忆莲", 275); got != "" {
		t.Errorf("另一张专辑的封面不给: %q", got)
	}
	for _, album := range []string{"", "林忆莲's"} {
		if got := neteaseLocalCoverURL("林忆莲", "至少还有你", album, 275); got != "https://p4.music.126.net/a/109951163829570820.jpg" {
			t.Errorf("专辑 %q 对得上或不知道时照给: %q", album, got)
		}
	}
}

// 网易云在放这首:按播放队列里这一版的 id 取,曲库里还没有它时用队列里那一条(封面、专辑 id 也是它的),同名的另一版不顶;
// 曲库里有了就用曲库那一条。别的歌那一轮、队列里那一条专辑对不上时照旧按歌名挑。
func TestNeteaseLocalPlayingVersionByID(t *testing.T) {
	withPlayingPlayer(t, neteaseMusicBundleID)
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{neteaseTestOtherVersion}))
	writeTestNeteaseQueue(t, []testNeteaseSong{
		{title: "别的歌", album: "别的专辑", artists: []string{"别人"}, durationMS: 200000, id: "1"},
		{title: "至少还有你", album: "属于我的林忆莲", artists: []string{"林忆莲"}, durationMS: 275400, id: "256468", albumID: "25600",
			picURL: neteaseTestPlayingPic},
	})
	playerCoverMu.Lock()
	playerCoverMemo = map[string]playerCoverAt{}
	playerCoverMu.Unlock()
	t.Cleanup(func() {
		playerCoverMu.Lock()
		playerCoverMemo = map[string]playerCoverAt{}
		playerCoverMu.Unlock()
	})
	s, ok := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275)
	if !ok || s.ID != 256468 || s.Album.ID != 25600 || s.Album.PicURL != "https://p4.music.126.net/b/109951171530798085.jpg" {
		t.Fatalf("取播放队列里这一版: ok=%v %+v", ok, s)
	}
	if got := playerCoverURLFor(neteaseMusicBundleID, "林忆莲", "至少还有你", "属于我的林忆莲", 275, kkboxPlayingInfo{}); got != "https://p4.music.126.net/b/109951171530798085.jpg" {
		t.Errorf("播放器封面是队列里这一版的: %q", got)
	}
	if s, ok := neteaseLocalSong(withOtherTrackRound(context.Background()), "林忆莲", "至少还有你", "属于我的林忆莲", 275); !ok || s.ID != 256621 {
		t.Errorf("别的歌那一轮不看播放队列: ok=%v id=%d", ok, s.ID)
	}
	if s, ok := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "林忆莲's", 275); !ok || s.ID != 256621 {
		t.Errorf("队列里那一条专辑对不上时按歌名挑: ok=%v id=%d", ok, s.ID)
	}

	inLibrary := neteaseTestTrackPic("256468", "至少还有你", "林忆莲", "属于我的林忆莲", 275400, "http://p4.music.126.net/c/3.jpg")
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, []string{neteaseTestOtherVersion, inLibrary}))
	if s, ok := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275); !ok || s.ID != 256468 ||
		s.Album.PicURL != "https://p4.music.126.net/c/3.jpg" {
		t.Errorf("曲库里有这一版时按 id 取曲库那一条: ok=%v %+v", ok, s)
	}
}

// 同名的只有另一张专辑那一版在索引里、库又变过(刚点播的这一版写进了播放历史):距上次扫描过了 neteaseLocalMissRescanMin
// 就重扫,不等 60 秒;没过就照旧用索引里那一版。
func TestNeteaseLocalOtherAlbumRescansSooner(t *testing.T) {
	withPlayingPlayer(t, "")
	path := writeTestNeteaseDB(t, []string{neteaseTestOtherVersion})
	resetNeteaseLocalIndex(t, path)
	if s, ok := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275); !ok || s.ID != 256621 {
		t.Fatalf("首次扫描只有另一版: ok=%v id=%d", ok, s.ID)
	}
	next := writeTestNeteaseDBWithHistory(t, []string{neteaseTestOtherVersion}, []string{neteaseTestPlayingVersion})
	if err := os.Rename(next, path); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Minute)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatal(err)
	}
	setScanned := func(ago time.Duration) {
		neteaseLocalMu.Lock()
		neteaseLocalScanned = time.Now().Add(-ago)
		neteaseLocalMu.Unlock()
	}
	setScanned(neteaseLocalMissRescanMin / 2)
	if s, _ := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275); s.ID != 256621 {
		t.Fatalf("距上次扫描不到 5 秒不该重扫: id=%d", s.ID)
	}
	setScanned(neteaseLocalMissRescanMin + time.Second)
	if s, ok := neteaseLocalSong(context.Background(), "林忆莲", "至少还有你", "属于我的林忆莲", 275); !ok || s.ID != 256468 {
		t.Fatalf("挑出的专辑对不上、库变过、过了 5 秒,应当重扫后取到专辑对得上的这一版: ok=%v id=%d", ok, s.ID)
	}
}

// 曲库有行、却大半解不开(或解开了没有 id、歌名):记一次认不出;认得的库清零。
func TestNeteaseLocalUndecodableRowsDrift(t *testing.T) {
	withParserDrift(t)
	refresh := func(path string) {
		resetNeteaseLocalIndex(t, path)
		neteaseLocalMu.Lock()
		refreshNeteaseLocalIndexLocked(context.Background())
		neteaseLocalMu.Unlock()
	}
	refresh(writeTestNeteaseDB(t, []string{"{这不是合法 JSON", `{"songId":"1","songName":"x"}`}))
	if got := driftStreak("netease-local-library"); got != 1 {
		t.Fatalf("一行都没解出 id、歌名,应记一次认不出: streak=%d", got)
	}
	refresh(writeTestNeteaseDB(t, append([]string{"{这不是合法 JSON"}, neteaseLocalTestTracks...)))
	if got := driftStreak("netease-local-library"); got != 0 {
		t.Fatalf("大半解得开算认得,清零: streak=%d", got)
	}
	refresh(writeTestNeteaseDB(t, nil))
	if got := driftStreak("netease-local-library"); got != 0 {
		t.Fatalf("一行都没有不算认不出: streak=%d", got)
	}
}

func TestNeteaseLinkFromPlayer(t *testing.T) {
	ids := func(id string) map[string]string { return map[string]string{neteaseMusicBundleID: id} }
	for _, c := range []struct {
		name string
		e    enrichEntry
		want string
	}{
		{"对不上换成播放器报的那首", enrichEntry{NeteaseURL: "https://music.163.com/song?id=256621", PlayerSongIDs: ids("256468")},
			"https://music.163.com/song?id=256468"},
		{"对得上不换", enrichEntry{NeteaseURL: "https://music.163.com/song?id=256468", PlayerSongIDs: ids("256468")}, ""},
		{"链接空着不补", enrichEntry{PlayerSongIDs: ids("256468")}, ""},
		{"没有播放器 id 不换", enrichEntry{NeteaseURL: "https://music.163.com/song?id=256621"}, ""},
		{"播放器报的那首判错过不换", enrichEntry{NeteaseURL: "https://music.163.com/song?id=256621", PlayerSongIDs: ids("256468"),
			NeteaseRejected: "256468"}, ""},
		{"形状不对的 id 不换", enrichEntry{NeteaseURL: "https://music.163.com/song?id=256621", PlayerSongIDs: ids("25a")}, ""},
	} {
		if got := neteaseLinkFromPlayer(c.e); got != c.want {
			t.Errorf("%s: %q", c.name, got)
		}
	}
}

func TestMigrateNeteaseLinksFromPlayer(t *testing.T) {
	withTempMigrationState(t)
	const k = "林忆莲|至少还有你|属于我的林忆莲"
	withEnrichCache(t, map[string]enrichEntry{
		k: {NeteaseURL: "https://music.163.com/song?id=256621", PlayerSongIDs: map[string]string{neteaseMusicBundleID: "256468"}, CoverSource: "qq"},
	})
	migrateNeteaseLinksFromPlayer()
	if e := enrichCache[k]; e.NeteaseURL != "https://music.163.com/song?id=256468" || e.CoverSource != "qq" {
		t.Errorf("链接换成播放器报的那首,别的不动: %+v", e)
	}
	if !migrationDone(migrationNeteaseLinksFromPlayer, migrationNeteaseLinksFromPlayerVersion) {
		t.Error("要记水位")
	}
}
