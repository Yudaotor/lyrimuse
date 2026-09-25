package main

import (
	"path/filepath"
	"testing"
)

// 形状照搬真机:Track 的第 3 个字段是所属专辑 {1: gid, 2: 名};Album 的第 11 个字段按碟重复,
// 每碟 {1: 碟号, 3: 曲目 {1: gid}…}。外层都是 {1: 版本, 2: Any{type_url, value}}。
func testSpotifyTrackInAlbum(ms int64, albumGID []byte) []byte {
	zz := uint64(ms<<1) ^ uint64(ms>>63)
	v := pbMsg(pbStr(2, "ignored"), pbBytes(3, pbMsg(pbBytes(1, albumGID), pbStr(2, "专辑"))), pbVarint(7, zz))
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
}

func testSpotifyAlbum(discs ...[]int) []byte {
	v := pbMsg(pbStr(2, "专辑"))
	for i, disc := range discs {
		d := pbMsg(pbVarint(1, uint64(i+1)))
		for _, n := range disc {
			_, gid := testSpotifyID(n)
			d = append(d, pbBytes(3, pbMsg(pbBytes(1, gid)))...)
		}
		v = append(v, pbBytes(11, d)...)
	}
	return pbMsg(pbVarint(1, 9), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Album"), pbBytes(2, v))))
}

// newTestSpotifyAlbumEnv:曲目 1..4 有元数据,5 没有;当前这首是 1,属于专辑 100,
// 专辑曲目表是 碟一 [2, 1] + 碟二 [5, 3]。withAlbum=false 时缓存里没有这张专辑。
func newTestSpotifyAlbumEnv(t *testing.T, withAlbum, withHint bool) {
	t.Helper()
	newTestSpotifyEnv(t, testSpotifyState([][]int{{1}}, 1), testSpotifyMetas(1, 2, 3, 4))
	albumID, albumGID := testSpotifyID(100)
	track1, _ := testSpotifyID(1)
	entries := []testLDBEntry{
		// 比 newTestSpotifyEnv 写的那条 sequence 大:同一个 key 取最新的,换成带专辑字段的版本。
		{key: string(spotifyXmetaKey(spotifyTrackKind, track1)), seq: 1000, value: string(testSpotifyTrackInAlbum(1000, albumGID))},
	}
	if withAlbum {
		entries = append(entries, testLDBEntry{
			key: string(spotifyXmetaKeyURI(spotifyAlbumKind, "spotify:album:"+albumID)), seq: 1001,
			value: string(testSpotifyAlbum([]int{2, 1}, []int{5, 3})),
		})
	}
	testWriteTable(t, filepath.Join(spotifyActiveUserDir(), "primary.ldb", "000002.ldb"), entries, 2, true)
	enrichMu.Lock()
	old := spotifyTrackIDHints
	spotifyTrackIDHints = map[string]string{}
	if withHint {
		spotifyTrackIDHints[enrichKey("甲", "歌1", "专辑1")] = track1
	}
	enrichMu.Unlock()
	t.Cleanup(func() { enrichMu.Lock(); spotifyTrackIDHints = old; enrichMu.Unlock() })
}

// 用 Spotify 听歌时同专辑兜底先走客户端缓存:按碟、按碟内顺序,名字 / 第一位歌手 / 时长都是 Spotify 自己的;
// 没有元数据的那首跳过,不拿空名字去猜。当前这首也在表里,由 prefetchAlbumSiblings 自己剔掉。
func TestAlbumTracksSpotifyUsesClientCache(t *testing.T) {
	newTestSpotifyAlbumEnv(t, true, true)
	tracks, ok := albumTracks("甲", "歌1", "专辑1", spotifyBundleID)
	if !ok {
		t.Fatal("客户端缓存里有这张专辑,该取到")
	}
	var got []string
	for _, tr := range tracks {
		got = append(got, tr.title+"/"+tr.artist)
	}
	want := []string{"歌2/甲", "歌1/甲", "歌3/甲"}
	if len(got) != len(want) {
		t.Fatalf("得到 %v,期望 %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("得到 %v,期望 %v", got, want)
		}
	}
	if tracks[0].duration != 2 {
		t.Errorf("时长该来自 Spotify 元数据(2 秒),得到 %v", tracks[0].duration)
	}
}

// 这张专辑没被客户端加载过 / 换曲时没记下曲目 id:本地这条放弃,交给网易云那条。
func TestSpotifyAlbumTracksGivesUpWithoutCacheOrHint(t *testing.T) {
	newTestSpotifyAlbumEnv(t, false, true)
	if got, ok := spotifyAlbumTracks("甲", "歌1", "专辑1"); ok {
		t.Errorf("缓存里没有这张专辑,不该取到: %+v", got)
	}
	newTestSpotifyAlbumEnv(t, true, false)
	if got, ok := spotifyAlbumTracks("甲", "歌1", "专辑1"); ok {
		t.Errorf("没有曲目 id 就不知道是哪张专辑,不该取到: %+v", got)
	}
}

func TestSpotifyParseAlbumRejectsOtherTypes(t *testing.T) {
	if ids := spotifyParseAlbumTrackIDs(testSpotifyTrack(1000)); len(ids) != 0 {
		t.Errorf("Track 的值不该被当成 Album: %v", ids)
	}
	if id := spotifyParseTrackAlbumID(testSpotifyTrack(1000)); id != "" {
		t.Errorf("没有专辑字段的 Track 不该解出专辑 id: %q", id)
	}
	if ids := spotifyParseAlbumTrackIDs([]byte("不是 protobuf")); len(ids) != 0 {
		t.Errorf("垃圾输入该返回空: %v", ids)
	}
}

// 专辑 key 的形状照抄真机:`!xmeta#cache#` 01 29 `#` 长度 uri `#`。
func TestSpotifyAlbumXmetaKeyShape(t *testing.T) {
	got := spotifyXmetaKeyURI(spotifyAlbumKind, "spotify:album:01mDyY0OcuqHnvTbEKBH0s")
	want := "!xmeta#cache#\x01)#$spotify:album:01mDyY0OcuqHnvTbEKBH0s#"
	if string(got) != want {
		t.Errorf("得到 %q,期望 %q", got, want)
	}
}
