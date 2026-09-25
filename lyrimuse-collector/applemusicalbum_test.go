package main

import (
	"testing"
	"time"
)

func TestMergeAlbumTracksKeepsLibraryAndAddsMissing(t *testing.T) {
	local := []albumTrack{{title: "摇篮曲", artist: "陶喆", duration: 254}}
	catalog := []albumTrack{
		{title: "黑色柳丁", artist: "陶喆", duration: 280},
		{title: "摇篮曲 ", artist: "陶喆", duration: 255},
		{title: "Katrina", artist: "陶喆", duration: 266},
	}
	got := mergeAlbumTracks(local, catalog)
	if len(got) != 3 || got[0].duration != 254 || got[1].title != "黑色柳丁" || got[2].title != "Katrina" {
		t.Fatalf("资料库那首保留资料库的写法,目录里多出来的按目录顺序追加,得到 %+v", got)
	}
	if got := mergeAlbumTracks(nil, catalog[:1]); len(got) != 1 {
		t.Errorf("资料库没收这张专辑时整张用目录的,得到 %+v", got)
	}
}

func TestAppleCatalogAlbumTracksNeedsVerifiedAnchor(t *testing.T) {
	oldWait := appleAlbumAnchorWait
	appleAlbumAnchorWait = 0
	appleCatalogMu.Lock()
	oldIndex, oldCache := appleCatalogByTrack, appleCatalogCache
	appleCatalogByTrack = map[string]appleCatalogTrack{
		appleCatalogIndexKey("摇篮曲", "黑色柳丁"): {TrackName: "摇篮曲", AlbumName: "黑色柳丁", AlbumID: 914664926},
	}
	appleCatalogCache = map[string]appleCatalogTrack{}
	appleCatalogMu.Unlock()
	appleAlbumMu.Lock()
	oldAlbums := appleAlbumCache
	appleAlbumCache = map[int64][]albumTrack{914664926: {
		{title: "黑色柳丁", artist: "陶喆", duration: 280},
		{title: "摇篮曲", artist: "陶喆", duration: 254},
	}}
	appleAlbumMu.Unlock()
	t.Cleanup(func() {
		appleAlbumAnchorWait = oldWait
		appleCatalogMu.Lock()
		appleCatalogByTrack, appleCatalogCache = oldIndex, oldCache
		appleCatalogMu.Unlock()
		appleAlbumMu.Lock()
		appleAlbumCache = oldAlbums
		appleAlbumMu.Unlock()
	})

	if got := appleCatalogAlbumTracks("摇篮曲", "黑色柳丁"); len(got) != 2 || got[0].title != "黑色柳丁" {
		t.Fatalf("锚点给出专辑 id 就该取到目录曲目表,得到 %+v", got)
	}
	// 没有锚点(本地导入的文件、别的专辑):不猜专辑 id,直接放弃。
	start := time.Now()
	if got := appleCatalogAlbumTracks("别的歌", "别的专辑"); got != nil {
		t.Errorf("没有目录锚点不该取到: %+v", got)
	}
	if time.Since(start) > time.Second {
		t.Errorf("等待上限为 0 时不该等")
	}
}
