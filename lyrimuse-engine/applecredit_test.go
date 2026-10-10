package main

import (
	"context"
	"testing"
)

// 同一张专辑的 10 周年版里同时收着独唱版和请 Aitana 合唱重录的那一版,歌名、专辑名都一样;合唱版另外单独发了单曲。
const (
	samSmithAnniversary  = "In The Lonely Hour (10th Anniversary Edition / Deluxe)"
	samSmithSoloURL      = "https://music.apple.com/us/album/like-i-can/1763638888?i=1763638900&uo=4"
	samSmithDuetURL      = "https://music.apple.com/us/album/like-i-can/1765000000?i=1765000001&uo=4"
	samSmithDuetOnAlbumU = "https://music.apple.com/us/album/like-i-can/1763638888?i=1763639999&uo=4"
)

var (
	samSmithSoloOnAnniversary = itunesResult{TrackName: "Like I Can", ArtistName: "Sam Smith",
		CollectionName: samSmithAnniversary, CollectionID: 1763638888, TrackViewURL: samSmithSoloURL,
		ArtworkURL100: "https://a/100x100bb.jpg", TrackTimeMillis: 168080}
	samSmithAitanaSingle = itunesResult{TrackName: "Like I Can", ArtistName: "Sam Smith & Aitana",
		CollectionName: "Like I Can - Single", CollectionID: 1765000000, TrackViewURL: samSmithDuetURL,
		ArtworkURL100: "https://b/100x100bb.jpg", TrackTimeMillis: 166707}
)

func TestPickAppleMusicMatchSongPageFollowsCredit(t *testing.T) {
	results := []itunesResult{samSmithSoloOnAnniversary, samSmithAitanaSingle}
	m, albumMatched := pickAppleMusicMatch(results, "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 166.707)
	if !albumMatched || m.url != samSmithSoloURL || m.cover != "https://a/1200x1200bb.jpg" || m.album != samSmithAnniversary {
		t.Fatalf("封面、专辑照旧按专辑挑:url=%q cover=%q album=%q", m.url, m.cover, m.album)
	}
	if got := m.songURL(); got != samSmithDuetURL {
		t.Errorf("歌曲页要用署名写全了 Aitana 的那一轨,实得 %q", got)
	}

	solo, _ := pickAppleMusicMatch(results, "Sam Smith", "Like I Can", samSmithAnniversary, 168.08)
	if solo.songURL() != samSmithSoloURL || solo.creditURL != "" {
		t.Errorf("本地没点名合作者时歌曲页就是按专辑挑的那一轨: %+v", solo)
	}

	same, _ := pickAppleMusicMatch(results, "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 168.0)
	if same.songURL() != samSmithSoloURL {
		t.Errorf("时长差不到 0.3 秒,按同一份录音只是署名没写合作者,不换: %q", same.songURL())
	}

	far := samSmithAitanaSingle
	far.TrackTimeMillis = 170500
	if m, _ := pickAppleMusicMatch([]itunesResult{samSmithSoloOnAnniversary, far}, "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 166.707); m.songURL() != samSmithSoloURL {
		t.Errorf("写全署名的那一轨时长差超过 1.5 秒,不是同一份录音,不换: %q", m.songURL())
	}

	other := samSmithAitanaSingle
	other.ArtistName = "Someone Else & Aitana"
	if m, _ := pickAppleMusicMatch([]itunesResult{samSmithSoloOnAnniversary, other}, "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 166.707); m.songURL() != samSmithSoloURL {
		t.Errorf("同一位合作者跟别人的同名曲没写主歌手,不换: %q", m.songURL())
	}

	remix := samSmithAitanaSingle
	remix.TrackName = "Like I Can (Remix)"
	if m, _ := pickAppleMusicMatch([]itunesResult{samSmithSoloOnAnniversary, remix}, "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 166.707); m.songURL() != samSmithSoloURL {
		t.Errorf("歌名多带版本词的混音版,不换: %q", m.songURL())
	}
}

const (
	samSmithAlbumSearch = `{"results":[{"collectionName":"` + samSmithAnniversary + `","collectionId":1763638888,"artistName":"Sam Smith",` +
		`"trackName":"Like I Can","artworkUrl100":"https://a/100x100bb.jpg"}]}`
	samSmithAlbumTracks = `{"results":[{"wrapperType":"collection","collectionName":"` + samSmithAnniversary + `"},` +
		`{"wrapperType":"track","trackName":"Like I Can","collectionName":"` + samSmithAnniversary + `","artistName":"Sam Smith",` +
		`"trackViewUrl":"` + samSmithSoloURL + `","trackTimeMillis":168080},` +
		`{"wrapperType":"track","trackName":"Like I Can","collectionName":"` + samSmithAnniversary + `","artistName":"Sam Smith & Aitana",` +
		`"trackViewUrl":"` + samSmithDuetOnAlbumU + `","trackTimeMillis":166707}]}`
	samSmithSoloOnlyTracks = `{"results":[{"wrapperType":"collection","collectionName":"` + samSmithAnniversary + `"},` +
		`{"wrapperType":"track","trackName":"Like I Can","collectionName":"` + samSmithAnniversary + `","artistName":"Sam Smith",` +
		`"trackViewUrl":"` + samSmithSoloURL + `","trackTimeMillis":168080}]}`
	// 全文搜索那一批:专辑那条只有专辑信息、没有曲目页(挑不中),合唱单曲专辑名对不上。
	samSmithMixedSearch = `{"results":[{"collectionName":"` + samSmithAnniversary + `","collectionId":1763638888,"artistName":"Sam Smith",` +
		`"trackName":"Like I Can","artworkUrl100":"https://a/100x100bb.jpg"},` +
		`{"collectionName":"Like I Can - Single","collectionId":1765000000,"artistName":"Sam Smith & Aitana","trackName":"Like I Can",` +
		`"trackViewUrl":"` + samSmithDuetURL + `","artworkUrl100":"https://b/100x100bb.jpg","trackTimeMillis":166707}]}`
)

// 按专辑名定位那条路:曲目表里同时有独唱和合唱两轨时,歌曲页用署名写全了的那一轨。
func TestAppleMatchViaAlbumSongPageFollowsCredit(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, samSmithAlbumSearch },
		func(string) (int, string) { return 200, samSmithAlbumTracks })
	got, _ := resolveAppleMusicMatchViaAlbum(context.Background(), "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 166.707)
	if got.url != samSmithSoloURL {
		t.Fatalf("曲目表里先对上的是独唱那一轨,url=%q", got.url)
	}
	if got.songURL() != samSmithDuetOnAlbumU {
		t.Errorf("歌曲页要用合唱那一轨,实得 %q", got.songURL())
	}
}

// 专辑曲目表里只有独唱那一轨时,沿用全文搜索那一批里署名写全了的那一轨(合唱单曲)。
func TestResolveAppleMusicMatchCarriesCreditedTrackFromSearch(t *testing.T) {
	withStorefrontFake(t,
		func(string) (int, string) { return 200, samSmithMixedSearch },
		func(string) (int, string) { return 200, samSmithSoloOnlyTracks })
	got, _ := resolveAppleMusicMatch(context.Background(), "Sam Smith & Aitana", "Like I Can", samSmithAnniversary, 166.707)
	if got.url != samSmithSoloURL || got.album != samSmithAnniversary {
		t.Fatalf("封面那一路仍是专辑里的那一轨: url=%q album=%q", got.url, got.album)
	}
	if got.songURL() != samSmithDuetURL {
		t.Errorf("歌曲页要用全文搜索里的合唱单曲,实得 %q", got.songURL())
	}
}
