package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const testSodaAlbumPage = `<html><script nonce="x">_ROUTER_DATA = {"loaderData":{"album_layout":null,"album_page":{"albumInfo":{"id":"b","name":"私人珍藏","count_tracks":2},` +
	`"trackList":[{"id":"1","name":"惯坏","duration":246987,"artists":[{"id":"a","name":"泳儿"}]},` +
	`{"id":"2","name":"一分之二","duration":282801,"artists":[{"name":"HUSH"},{"name":"孙盛希"}]},` +
	`{"id":"3","name":"","duration":1,"artists":[{"name":"泳儿"}]}]}}};
function runWindowFn(){}</script></html>`

func TestSodaParseAlbumPage(t *testing.T) {
	got := sodaParseAlbumPage([]byte(testSodaAlbumPage), "b")
	if len(got) != 2 || got[0].title != "惯坏" || got[0].artist != "泳儿" || got[0].duration != 246.987 || got[1].artist != "HUSH/孙盛希" {
		t.Fatalf("该取到两首(空名字那条跳过),多位歌手用 / 连,得到 %+v", got)
	}
	if got := sodaParseAlbumPage([]byte(testSodaAlbumPage), "别的专辑"); got != nil {
		t.Errorf("页面上的专辑 id 对不上时不该认: %+v", got)
	}
	if got := sodaParseAlbumPage([]byte("<html>404</html>"), "b"); got != nil {
		t.Errorf("没有嵌入数据时不该认: %+v", got)
	}
}

func TestAlbumTracksSodaUsesSodaAlbum(t *testing.T) {
	path := filepath.Join(t.TempDir(), "entries.db")
	rec := testSodaPreloadRecord("1", "惯坏", []string{"泳儿"}, "私人珍藏", 246987, uint32(time.Now().Unix()))
	if err := os.WriteFile(path, rec, 0o644); err != nil {
		t.Fatal(err)
	}
	oldPath := sodaPreloadOverride
	sodaPreloadOverride = path
	sodaAlbumMu.Lock()
	oldCache := sodaAlbumCache
	// testSodaPreloadRecord 里专辑 id 写的是 "b"。
	sodaAlbumCache = map[string][]albumTrack{"b": {
		{title: "原来爱情那么难", artist: "泳儿", duration: 242.493},
		{title: "惯坏", artist: "泳儿", duration: 246.987},
	}}
	sodaAlbumMu.Unlock()
	t.Cleanup(func() {
		sodaPreloadOverride = oldPath
		sodaAlbumMu.Lock()
		sodaAlbumCache = oldCache
		sodaAlbumMu.Unlock()
	})

	tracks, ok := albumTracks("泳儿", "惯坏", "私人珍藏", sodaMusicBundleID)
	if !ok || len(tracks) != 2 || tracks[0].title != "原来爱情那么难" {
		t.Fatalf("该取到汽水专辑的曲目表,得到 ok=%v %+v", ok, tracks)
	}
	// 专辑名对不上本地标签:不认这个专辑 id,交给网易云那条。
	if got, ok := sodaAlbumTracks("泳儿", "惯坏", "完全不同的专辑"); ok {
		t.Errorf("专辑名对不上时不该取到: %+v", got)
	}
}
