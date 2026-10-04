package main

import (
	"reflect"
	"testing"
)

func TestKKBOXAlbumTrackArtists(t *testing.T) {
	tracks := []albumTrack{
		{title: "人生海海", artist: "五月天"},
		{title: "温柔", artist: "五月天/孙燕姿"},
		{title: "知足", artist: "五月天/告五人"},
		{title: "别的歌", artist: "Someone"},
	}
	got := kkboxAlbumTrackArtists(tracks, "五月天 (Mayday), 孫燕姿 (Yanzi Sun)")
	want := []string{"五月天 (Mayday)", "五月天 (Mayday), 孫燕姿 (Yanzi Sun)", "五月天/告五人", "Someone"}
	var artists []string
	for _, tr := range got {
		artists = append(artists, tr.artist)
	}
	if !reflect.DeepEqual(artists, want) {
		t.Errorf("got %q want %q", artists, want)
	}
	if tracks[0].artist != "五月天" {
		t.Error("不改原切片")
	}
	if got := kkboxAlbumTrackArtists(tracks[:1], "五月天"); got[0].artist != "五月天" {
		t.Errorf("KKBOX 报的就是不带别名的写法:照它, got %q", got[0].artist)
	}
}

func TestKKBOXBareArtist(t *testing.T) {
	for in, want := range map[string]string{
		"五月天 (Mayday)": "五月天", "Taylor Swift": "Taylor Swift", "蕭秉治Xiao Bing Chih": "蕭秉治Xiao Bing Chih",
	} {
		if got := kkboxBareArtist(in); got != want {
			t.Errorf("%q: got %q want %q", in, got, want)
		}
	}
}

// 当前这首的单曲详情给出专辑 id,缓存里有这张专辑的曲目表就用它(曲目自己不带歌手的用批量详情补,没有就是专辑歌手)。
func TestKKBOXAlbumTracksFromCache(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "al1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/A1?terr=tw",
		`{"data":{"id":"A1","name":"The Fate of Ophelia","artist_roles":{"main_artists":[{"name":"Taylor Swift (泰勒絲)"}]},"album":{"id":"ALB","name":"The Life of a Showgirl: The Encore"},"duration_ms":226063}}`)
	testChromiumCacheEntry(t, cache, "al2_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=A2&plain=0",
		`{"data":[{"id":"A2","name":"Elizabeth Taylor","artist_roles":{"main_artists":[{"name":"Taylor Swift (泰勒絲)"}],"featured_artists":[{"name":"Guest"}]},"duration_ms":208274}]}`)
	got, ok := kkboxAlbumTracks("Taylor Swift (泰勒絲)", "The Fate of Ophelia")
	if !ok || len(got) != 3 {
		t.Fatalf("got %+v ok=%v", got, ok)
	}
	if got[1].artist != "Taylor Swift (泰勒絲), Guest" || got[1].duration != 208.274 {
		t.Errorf("有批量详情的那首照详情: %+v", got[1])
	}
	if got[2].artist != "Taylor Swift (泰勒絲)" || got[2].title != "Opalite" {
		t.Errorf("没有详情的那首用专辑歌手: %+v", got[2])
	}
	if _, ok := kkboxAlbumTracks("Taylor Swift", "Not Played"); ok {
		t.Error("缓存里没有这首的单曲详情:拿不到专辑 id,退回")
	}
}
