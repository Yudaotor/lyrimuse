package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNeteaseHTTPSImage(t *testing.T) {
	for raw, want := range map[string]string{
		"http://p4.music.126.net/BJksZeIBiqHtIY6Tgvi1Cw==/109951169245235679.jpg": "https://p4.music.126.net/BJksZeIBiqHtIY6Tgvi1Cw==/109951169245235679.jpg",
		"https://p1.music.126.net/a.jpg":                                          "https://p1.music.126.net/a.jpg",
		"http://music.126.net/a.jpg":                                              "https://music.126.net/a.jpg",
		"http://evilmusic.126.net/a.jpg":                                          "",
		"http://example.com/a.jpg":                                                "",
		"":                                                                        "",
	} {
		if got := neteaseHTTPSImage(raw); got != want {
			t.Errorf("%q: got %q want %q", raw, got, want)
		}
	}
}

func TestAmazonJPEGImage(t *testing.T) {
	for raw, want := range map[string]string{
		"https://m.media-amazon.com/images/I/5194nbHWBoL._FMwebp_SX500_.jpg": "https://m.media-amazon.com/images/I/5194nbHWBoL._SX500_.jpg",
		"https://m.media-amazon.com/images/I/61mFfUv+jDL._FMwebp_SX500_.jpg": "https://m.media-amazon.com/images/I/61mFfUv+jDL._SX500_.jpg",
		"https://m.media-amazon.com/images/I/5194nbHWBoL._SX500_.jpg":        "https://m.media-amazon.com/images/I/5194nbHWBoL._SX500_.jpg",
		"http://m.media-amazon.com/images/I/x._FMwebp_SX500_.jpg":            "",
		"https://example.com/images/I/x._FMwebp_SX500_.jpg":                  "",
		"": "",
	} {
		if got := amazonJPEGImage(raw); got != want {
			t.Errorf("%q: got %q want %q", raw, got, want)
		}
	}
}

func TestQQMidShape(t *testing.T) {
	for mid, want := range map[string]bool{
		"002DUTz03MUKF5":        true,
		"":                      false,
		"../x":                  false,
		"abc def":               false,
		strings.Repeat("a", 33): false,
	} {
		if got := qqMidShape(mid); got != want {
			t.Errorf("%q: got %v want %v", mid, got, want)
		}
	}
}

// 记进条目:同一张不算改动,读不到不删,换整张表不动原来那张(条目是值拷贝,表跟落盘快照共用)。
func TestApplyPlayerCoverLocked(t *testing.T) {
	shared := map[string]string{neteaseMusicBundleID: "https://p1.music.126.net/a.jpg"}
	e := enrichEntry{PlayerCovers: shared}
	if applyPlayerCoverLocked(&e, neteaseMusicBundleID, "https://p1.music.126.net/a.jpg") {
		t.Error("同一张不算改动")
	}
	if applyPlayerCoverLocked(&e, qqMusicBundleID, "") {
		t.Error("没读到不算改动")
	}
	qq := "https://y.qq.com/music/photo_new/T002R800x800M000002DUTz03MUKF5.jpg"
	if !applyPlayerCoverLocked(&e, qqMusicBundleID, qq) {
		t.Error("新的一张要记下")
	}
	if e.PlayerCovers[qqMusicBundleID] != qq || e.PlayerCovers[neteaseMusicBundleID] == "" {
		t.Errorf("条目里的表: %v", e.PlayerCovers)
	}
	if len(shared) != 1 {
		t.Error("不能原地改共用的那张表")
	}
	out, err := json.Marshal(enrichEntry{PlayerCovers: map[string]string{qqMusicBundleID: qq}})
	if err != nil || !strings.Contains(string(out), `"player_covers":{"com.tencent.QQMusicMac":`) {
		t.Errorf("落盘带 player_covers: %s %v", out, err)
	}
	if strings.Contains(string(mustMarshal(t, enrichEntry{TS: 1})), "player_covers") {
		t.Error("没有时不写这个键")
	}
}

func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// 只有网易云 / QQ / KKBOX / Amazon 四家从本机数据里取;KKBOX 用同一拍取好的那份。
func TestPlayerCoverURLForPlayers(t *testing.T) {
	kk := kkboxPlayingInfo{cover: "https://i.kfs.io/album/global/1,0v1/fit/600x600.jpg"}
	if got := playerCoverURLFor(kkboxBundleID, "A", "B", "C", 200, kk); got != kk.cover {
		t.Errorf("KKBOX: %q", got)
	}
	for _, bundle := range []string{appleMusicBundleID, spotifyBundleID, kasetBundleID, ""} {
		if got := playerCoverURLFor(bundle, "A", "B", "C", 200, kk); got != "" {
			t.Errorf("%q 不从本机数据取: %q", bundle, got)
		}
	}
}

func TestNeteaseLocalTrackPicURL(t *testing.T) {
	var tr neteaseLocalTrack
	raw := `{"id":"1","name":"x","artists":[{"name":"a"}],"album":{"id":"2","name":"b","picUrl":"http://p4.music.126.net/x/1.jpg"},"duration":1000}`
	if err := json.Unmarshal([]byte(raw), &tr); err != nil || tr.Album.PicURL != "http://p4.music.126.net/x/1.jpg" {
		t.Errorf("album.picUrl: %+v %v", tr.Album, err)
	}
}

// 用 KKBOX 放的这首:单曲详情里的专辑图 600 档,不换原图。
func TestKKBOXPlayingCover(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "pc1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/PC1?terr=tw",
		`{"data":{"id":"PC1","name":"Cover Song","artist_roles":{"main_artists":[{"name":"Cover Artist"}]},"duration_ms":200690,`+
			`"album":{"name":"Cover Album","images":{"large":{"url":"https://i.kfs.io/album/global/9,0v1/fit/600x600.jpg"}}}}}`)
	c := scanKKBOXCache(kkboxCacheDir())
	if got := c.coverFor("Cover Artist", "Cover Song", 200.7); got != "https://i.kfs.io/album/global/9,0v1/fit/600x600.jpg" {
		t.Errorf("专辑图: %q", got)
	}
	if got := c.coverFor("Cover Artist", "Not Played", 0); got != "" {
		t.Errorf("没放过的歌没有专辑图: %q", got)
	}
}

func TestAmazonCatalogTrackAlbumImage(t *testing.T) {
	var tr amazonCatalogTrack
	raw := `{"title":"t","artist":{"name":"a"},"album":{"name":"b","image":"https://m.media-amazon.com/images/I/5194nbHWBoL._FMwebp_SX500_.jpg"}}`
	if !amazonFirstJSONObject([]byte("\x00\x01"+raw), &tr) || tr.Album.Image == "" {
		t.Errorf("album.image: %+v", tr.Album)
	}
}
