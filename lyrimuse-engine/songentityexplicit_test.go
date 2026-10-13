package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Spotify 元数据第 9 个字段是 explicit:为 1 才算;没有、为 0、解不开都不算。
func TestSpotifyTrackExplicit(t *testing.T) {
	rec := func(v []byte) []byte {
		return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
	}
	if !spotifyTrackExplicit(rec(pbMsg(pbStr(2, "歌"), pbVarint(9, 1)))) {
		t.Error("第 9 个字段为 1")
	}
	for name, v := range map[string][]byte{
		"没有这个字段": rec(pbMsg(pbStr(2, "歌"))),
		"为 0":    rec(pbMsg(pbStr(2, "歌"), pbVarint(9, 0))),
		"解不开":    []byte("garbage"),
	} {
		if spotifyTrackExplicit(v) {
			t.Errorf("%s 不算", name)
		}
	}
}

// 带 Spotify 曲目 id 的写法,元数据标了 explicit 的记成不删减版;没标的、没有 Spotify 曲目 id 的不记。
func TestAttachSpotifyExplicit(t *testing.T) {
	vs := []songVariant{
		songTestVariant("A|1|X", enrichEntry{SpotifyTrackID: "0000000000000000000001"}, nil),
		songTestVariant("A|2|X", enrichEntry{SpotifyTrackID: "0000000000000000000002"}, nil),
		songTestVariant("A|3|X", enrichEntry{}, nil),
	}
	attachSpotifyExplicit(vs, func(id string) bool { return id == "0000000000000000000001" })
	for i, want := range []string{"explicit", "", ""} {
		if vs[i].playerExplicitness != want {
			t.Errorf("#%d %q,应为 %q", i, vs[i].playerExplicitness, want)
		}
	}
}

// Apple 的删减标记只认 Apple Music 播放器报的那一首;检索配的链接上的不认;explicit / clean 之外的取值不认。
func TestAttachAppleNamesContentRating(t *testing.T) {
	link := func(id string) string { return "https://music.apple.com/cn/album/x/1?i=" + id }
	vs := []songVariant{
		songTestVariant("A|1|X", enrichEntry{AppleURL: link("100"), PlayerSongIDs: map[string]string{appleMusicBundleID: "100"}}, nil),
		songTestVariant("A|2|X", enrichEntry{AppleURL: link("200")}, nil),
		songTestVariant("A|3|X", enrichEntry{PlayerSongIDs: map[string]string{appleMusicBundleID: "300"}}, nil),
		songTestVariant("A|4|X", enrichEntry{PlayerSongIDs: map[string]string{appleMusicBundleID: "400"}}, nil),
	}
	attachAppleNames(vs, map[string]appleCatalogNames{
		"100": {ContentRating: "clean", Rated: true},
		"200": {ContentRating: "explicit", Rated: true},
		"300": {Rated: true},
		"400": {ContentRating: "unknown", Rated: true},
	})
	for i, want := range []string{"clean", "", "", ""} {
		if vs[i].playerExplicitness != want {
			t.Errorf("#%d %q,应为 %q", i, vs[i].playerExplicitness, want)
		}
	}
}

// 删减版否决(两条写法靠同一个 ISRC 连着):歌名、专辑名没标明的用播放器给的;标明的为准;一边不知道不否决。
func TestExplicitVetoUsesPlayerFlags(t *testing.T) {
	build := func(xFlag string, xTitle string) (*songEntityBuild, map[string]string, []songVariant) {
		x := songTestVariant("Singer|"+xTitle+"|Album", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA2600001"}}, nil)
		x.playerExplicitness = xFlag
		y := songTestVariant("Singer|Song (Clean)|Album", enrichEntry{DurationSecs: 200.5, ISRCs: []string{"USAAA2600001"}}, nil)
		vs := []songVariant{x, y}
		b, of := songTestBuild(t, vs, nil)
		return b, of, vs
	}
	b, of, vs := build("explicit", "Song")
	if songTestSame(of, vs[0].key, vs[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "explicit" {
		t.Errorf("播放器标了 explicit、对面歌名标了删减版:否决, %+v", b.vetoed)
	}
	if _, of, vs := build("", "Song"); !songTestSame(of, vs[0].key, vs[1].key) {
		t.Error("一边不知道,不否决")
	}
	if _, of, vs := build("explicit", "Song [Clean]"); !songTestSame(of, vs[0].key, vs[1].key) {
		t.Error("歌名标明的为准:两边都是删减版")
	}
}

// 建表时按写法的 Spotify 曲目 id 读本机元数据:标了 explicit 的才算。
func TestSpotifyExplicitForVariants(t *testing.T) {
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1}}, 1), testSpotifyMetas(1, 2))
	id1, _ := testSpotifyID(1)
	id2, _ := testSpotifyID(2)
	v := pbMsg(pbStr(2, "歌2"), pbVarint(9, 1))
	rec := pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
	testWriteTable(t, filepath.Join(spotifyActiveUserDir(), "primary.ldb", "000009.ldb"),
		[]testLDBEntry{{key: string(spotifyXmetaKey(spotifyTrackKind, id2)), seq: 5000, value: string(rec)}}, 2, true)
	vs := []songVariant{
		songTestVariant("A|1|X", enrichEntry{SpotifyTrackID: id1}, nil),
		songTestVariant("A|2|X", enrichEntry{SpotifyTrackID: id2}, nil),
	}
	explicit := spotifyExplicitForVariants(vs)
	if explicit(id1) || !explicit(id2) {
		t.Errorf("id1=%v id2=%v", explicit(id1), explicit(id2))
	}
}

// 曲库 songs 应答里取删减标记,跟别的字段一起换成按 id 的记录。
func TestAppleCatalogSongsFrom(t *testing.T) {
	got, ok := appleCatalogSongsFrom([]byte(`{"data":[{"id":"1","attributes":{"name":"A","artistName":"B","albumName":"C","durationInMillis":200000,` +
		`"isrc":"USAAA2600001","audioLocale":"en-US","contentRating":"explicit"}},{"id":"2","attributes":{"name":"D"}}]}`))
	want := appleCatalogSong{isrc: "USAAA2600001", durationSecs: 200, artist: "B", title: "A", album: "C", audioLocale: "en-US", contentRating: "explicit"}
	if !ok || got["1"] != want || got["2"].contentRating != "" {
		t.Errorf("got %+v ok %v", got, ok)
	}
	if _, ok := appleCatalogSongsFrom([]byte("{")); ok {
		t.Error("解不开的算没问成")
	}
}

// 接线:常驻进程的建表准备和 song-entities 命令都挂 Spotify 的删减标记。
func TestSpotifyExplicitWiring(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if !strings.Contains(read("songentityincremental.go"), "attachSpotifyExplicit(vs, spotifyExplicitForVariants(vs))") ||
		!strings.Contains(read("songentitycli.go"), "attachSpotifyExplicit(variants, spotifyExplicitForVariants(variants))") {
		t.Error("两处都挂")
	}
}
