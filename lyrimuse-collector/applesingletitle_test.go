package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// 本地专辑名只是「<曲名> - Single」时,别人的同名单曲专辑名也逐字相等。iTunes Search 实测 dump 的两条:
// Parmalee 的同名单曲,以及 Dean Lewis 这首挂在原声单曲那张碟里的录音室版。
var (
	parmaleeBeAlright = itunesResult{
		TrackName: "Be Alright", ArtistName: "Parmalee",
		CollectionName: "Be Alright - Single", CollectionID: 1450557780,
		TrackViewURL:  "https://music.apple.com/us/album/be-alright/1450557780?i=1450557781",
		ArtworkURL100: "https://p/100x100bb.jpg", TrackTimeMillis: 201027,
	}
	deanLewisBeAlright = itunesResult{
		TrackName: "Be Alright", ArtistName: "Dean Lewis",
		CollectionName: "Be Alright (Acoustic) - Single", CollectionID: 1435118873,
		TrackViewURL:  "https://music.apple.com/us/album/be-alright/1435118873?i=1435118880",
		ArtworkURL100: "https://d/100x100bb.jpg", TrackTimeMillis: 196373,
	}
)

func TestPickAppleMusicMatchSkipsSameTitleSingleByAnotherArtist(t *testing.T) {
	got, _ := pickAppleMusicMatch([]itunesResult{parmaleeBeAlright, deanLewisBeAlright},
		"Dean Lewis", "Be Alright", "Be Alright - Single", 196.373)
	if got.url != deanLewisBeAlright.TrackViewURL {
		t.Fatalf("应选 Dean Lewis 那条,实得 url=%q album=%q", got.url, got.album)
	}
	if got.durationSecs != 196.373 {
		t.Errorf("durationSecs = %v, want 196.373", got.durationSecs)
	}
	only, _ := pickAppleMusicMatch([]itunesResult{parmaleeBeAlright}, "Dean Lewis", "Be Alright", "Be Alright - Single", 196.373)
	if only.url != "" || only.durationSecs != 0 {
		t.Errorf("只有别人的同名单曲时不该选中,实得 url=%q duration=%v", only.url, only.durationSecs)
	}
}

const (
	parmaleeSingleSearch = `{"results":[{"collectionName":"Be Alright - Single","collectionId":1450557780,"artistName":"Parmalee",` +
		`"trackName":"Be Alright","artworkUrl100":"https://p/100x100bb.jpg"}]}`
	parmaleeSingleTracks = `{"results":[{"wrapperType":"collection","collectionName":"Be Alright - Single"},` +
		`{"wrapperType":"track","trackName":"Be Alright","collectionName":"Be Alright - Single","artistName":"Parmalee",` +
		`"trackViewUrl":"https://music.apple.com/us/album/be-alright/1450557780?i=1450557781","trackTimeMillis":201027}]}`
	deanLewisSingleSearch = `{"results":[{"collectionName":"Be Alright - Single","collectionId":1400595841,"artistName":"Dean Lewis",` +
		`"trackName":"Be Alright","artworkUrl100":"https://d/100x100bb.jpg"}]}`
	deanLewisSingleTracks = `{"results":[{"wrapperType":"collection","collectionName":"Be Alright - Single"},` +
		`{"wrapperType":"track","trackName":"Be Alright","collectionName":"Be Alright - Single","artistName":"Dean Lewis",` +
		`"trackViewUrl":"https://music.apple.com/us/album/be-alright/1400595841?i=1400596082","trackTimeMillis":196373}]}`
)

// 按专辑名定位那条路:定位到的是别人的同名单曲时,链接和封面都不借。
func TestAppleMatchViaAlbumSkipsSameTitleSingleByAnotherArtist(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, parmaleeSingleSearch },
		func(string) (int, string) { return 200, parmaleeSingleTracks })
	got, _ := resolveAppleMusicMatchViaAlbum(context.Background(), "Dean Lewis", "Be Alright", "Be Alright - Single", 196.373)
	if got.url != "" || got.cover != "" {
		t.Errorf("别人的同名单曲不该被定位成本曲的专辑,实得 url=%q cover=%q", got.url, got.cover)
	}
}

func TestAppleMatchViaAlbumKeepsOwnSingle(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, deanLewisSingleSearch },
		func(string) (int, string) { return 200, deanLewisSingleTracks })
	got, _ := resolveAppleMusicMatchViaAlbum(context.Background(), "Dean Lewis", "Be Alright", "Be Alright - Single", 196.373)
	if got.url != "https://music.apple.com/us/album/be-alright/1400595841?i=1400596082" {
		t.Errorf("自己的单曲应照常定位,实得 url=%q", got.url)
	}
}

// 区服署名那条路:同一次按「艺人 + 专辑名」的搜索,单曲专辑名只是曲名时搜到的是别人的同名单曲,
// 它的署名不能被当成本地歌手在别的商店的写法。
func TestAppleStorefrontIdentitiesSkipSameTitleSingleByAnotherArtist(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, parmaleeSingleSearch },
		func(string) (int, string) { return 200, parmaleeSingleTracks })
	if names := appleStorefrontArtistIdentities(context.Background(), "Dean Lewis", "Be Alright", "Be Alright - Single", 196, nil); len(names) != 0 {
		t.Errorf("别人的同名单曲不该提供别名,实得 %v", names)
	}
}

func TestDropSingleOrEPStorefrontEntries(t *testing.T) {
	kept, dropped := dropSingleOrEPStorefrontEntries(map[string][]string{
		"deanlewis|bealrightsingle": {"Parmalee"},
		"backnumber|happyendep":     {"Rothy"},
		"方大同|橙月":                    {"Khalil Fong"},
	})
	if dropped != 2 || len(kept) != 1 || kept["方大同|橙月"] == nil {
		t.Errorf("应只留下非单曲 / EP 的条目,实得 kept=%v dropped=%d", kept, dropped)
	}
}

// 读到 v2 的缓存文件:单曲 / EP 条目丢掉、其余照用,并标记要按新版本写回。
func TestLoadAppleStorefrontArtistCacheDropsV2SingleEntries(t *testing.T) {
	appleStorefrontArtistMu.Lock()
	oldCache, oldPath, oldDirty := appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty
	appleStorefrontArtistMu.Unlock()
	t.Cleanup(func() {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty = oldCache, oldPath, oldDirty
		appleStorefrontArtistMu.Unlock()
	})
	path := filepath.Join(t.TempDir(), "storefront-artist.json")
	v2 := `{"version":2,"entries":{"deanlewis|bealrightsingle":["Parmalee"],"方大同|橙月":["Khalil Fong"]}}`
	if err := os.WriteFile(path, []byte(v2), 0o600); err != nil {
		t.Fatal(err)
	}
	loadAppleStorefrontArtistCache(path)
	appleStorefrontArtistMu.Lock()
	got, dirty := appleStorefrontArtistCache, appleStorefrontArtistDirty
	appleStorefrontArtistMu.Unlock()
	if len(got) != 1 || got["方大同|橙月"] == nil || !dirty {
		t.Errorf("v2 应丢掉单曲条目并标脏,实得 %v dirty=%v", got, dirty)
	}
}

// 同一个歌手在别的商店换了文字写法(陈卓贤 / Ian Chan),同一份单曲时长一样:照常收作别名。
func TestAppleStorefrontIdentitiesKeepCrossScriptSingleAlias(t *testing.T) {
	search := `{"results":[{"collectionName":"无垢 - Single","collectionId":9,"artistName":"Ian Chan","trackName":"无垢"}]}`
	tracks := `{"results":[{"wrapperType":"collection","collectionName":"无垢 - Single"},` +
		`{"wrapperType":"track","trackName":"无垢","collectionName":"无垢 - Single","artistName":"Ian Chan","trackTimeMillis":209631}]}`
	withStorefrontFake(t,
		func(string) (int, string) { return 200, search },
		func(string) (int, string) { return 200, tracks })
	names := appleStorefrontArtistIdentities(context.Background(), "Ian 陈卓贤", "无垢", "无垢 - Single", 209.63, nil)
	if len(names) != 1 || names[0] != "Ian Chan" {
		t.Errorf("换了文字写法的同一份单曲应收作别名,实得 %v", names)
	}
}
