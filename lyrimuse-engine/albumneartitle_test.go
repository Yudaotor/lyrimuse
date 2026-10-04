package main

import "testing"

// 网易云专辑 18907《八度空间》的曲目表(/api/v1/album/18907 实测),本地是 Spotify 报的
// 「火車叼位去」274s。见 09 章决策 69。
var bapianTracks = []albumTrack{
	{title: "半兽人", duration: 247.0},
	{title: "半岛铁盒", duration: 319.4},
	{title: "暗号", duration: 271.0},
	{title: "龙拳", duration: 274.0},
	{title: "火车叨位去", duration: 276.0},
	{title: "分裂", duration: 254.0},
	{title: "爷爷泡的茶", duration: 240.0},
	{title: "回到过去", duration: 233.0},
	{title: "米兰的小铁匠", duration: 238.654},
	{title: "最后的战役", duration: 251.0},
}

func TestAlbumTrackByNearTitleOneWrongChar(t *testing.T) {
	if got, _, ok := bestAlbumTrackByDurationDetailed(bapianTracks, 274); !ok || got != "龙拳" {
		t.Fatalf("前提变了:纯时长判据应挑中相邻的《龙拳》, got %q ok=%v", got, ok)
	}
	got, diff, found, ambiguous := albumTrackByNearTitle(bapianTracks, "火車叼位去", 274)
	if !found || ambiguous || got != "火车叨位去" || diff != 2 {
		t.Fatalf("got %q diff=%v found=%v ambiguous=%v, want 火车叨位去 diff=2", got, diff, found, ambiguous)
	}
}

func TestAlbumTrackByNearTitleRejects(t *testing.T) {
	cases := []struct {
		name   string
		tracks []albumTrack
		local  string
		dur    float64
	}{
		{"译名没有文字重叠,留给纯时长判据", []albumTrack{{title: "回留", duration: 236.343}}, "Revisited", 236.344},
		{"两个字的标题错一个字不算近似", []albumTrack{{title: "暗语", duration: 271}}, "暗号", 271},
		{"系列曲目只差数字", []albumTrack{{title: "Interlude 2", duration: 60}}, "Interlude 3", 60},
		{"超出近似标题的时长容差", []albumTrack{{title: "火车叨位去", duration: 280}}, "火车叼位去", 274},
	}
	for _, c := range cases {
		if got, _, found, ambiguous := albumTrackByNearTitle(c.tracks, c.local, c.dur); found || ambiguous {
			t.Errorf("%s: got %q found=%v ambiguous=%v, want 不命中", c.name, got, found, ambiguous)
		}
	}
}

func TestAlbumTrackByNearTitleAmbiguous(t *testing.T) {
	tracks := []albumTrack{{title: "Hello World", duration: 200}, {title: "Hello Worlds", duration: 201}, {title: "Hallo World", duration: 200}}
	if got, _, found, ambiguous := albumTrackByNearTitle(tracks, "Hello Wordl", 200); found || !ambiguous {
		t.Fatalf("两首不同标题同样近,应判歧义: got %q found=%v ambiguous=%v", got, found, ambiguous)
	}
	// 更近的一首把歧义解开。
	tracks = append(tracks, albumTrack{title: "Hello Wordl", duration: 200})
	if got, _, found, ambiguous := albumTrackByNearTitle(tracks, "Hello Wordl", 200); !found || ambiguous || got != "Hello Wordl" {
		t.Fatalf("got %q found=%v ambiguous=%v", got, found, ambiguous)
	}
}

func TestAlbumTrackByNearTitleSameTitleTwice(t *testing.T) {
	tracks := []albumTrack{{title: "火车叨位去 (Live)", duration: 275}, {title: "火车叨位去", duration: 278}, {title: "火车叨位去", duration: 276}}
	got, diff, found, ambiguous := albumTrackByNearTitle(tracks, "火车叼位去", 274)
	if !found || ambiguous || diff != 2 || got != "火车叨位去" {
		t.Fatalf("同名重复收录不算歧义,先比完整标题、再比时长: got %q diff=%v found=%v ambiguous=%v", got, diff, found, ambiguous)
	}
}

func TestRuneEditDistance(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0}, {"abc", "", 3}, {"火车叼位去", "火车叨位去", 1}, {"kitten", "sitting", 3}, {"ab", "ba", 2},
	}
	for _, c := range cases {
		if got := runeEditDistance([]rune(c.a), []rune(c.b)); got != c.want {
			t.Errorf("runeEditDistance(%q,%q)=%d want %d", c.a, c.b, got, c.want)
		}
	}
}
