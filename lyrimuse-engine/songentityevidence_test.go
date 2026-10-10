package main

import "testing"

// 两份同源歌词独立不独立:网易云按写法上那个 id 比(就是歌词出处);QQ、Apple 的链接是另外单独查的,按正文比;
// 有一边不知道来源时也按正文比。
func TestSongLyricsIndependentSourceIDs(t *testing.T) {
	lrc := songTestLRC(1000, songTestWords("same", 30))
	other := songTestLRC(1000, songTestWords("diff", 30))
	mk := func(key, src, lyrics string, e enrichEntry) *songVariant {
		e.DurationSecs, e.ResolvedDurationSecs, e.Lyrics, e.LyricsSource = 200, 200, lyrics, src
		v := songTestVariant(key, e, nil)
		return &v
	}
	cases := []struct {
		name string
		x, y *songVariant
		want bool
	}{
		{"QQ 链接不同、正文一字不差",
			mk("S|T|A", "qq", lrc, enrichEntry{QQURL: "https://y.qq.com/n/ryqq/songDetail/001aaa"}),
			mk("S|T|B", "qq", lrc, enrichEntry{QQURL: "https://y.qq.com/n/ryqq/songDetail/002bbb"}), false},
		{"QQ 正文不同",
			mk("S|T|A", "qq", lrc, enrichEntry{QQURL: "https://y.qq.com/n/ryqq/songDetail/001aaa"}),
			mk("S|T|B", "qq", other, enrichEntry{QQURL: "https://y.qq.com/n/ryqq/songDetail/001aaa"}), true},
		{"Apple 链接不同、正文一字不差",
			mk("S|T|A", "applemusic", lrc, enrichEntry{AppleURL: "https://music.apple.com/us/album/x/1?i=2"}),
			mk("S|T|B", "applemusic", lrc, enrichEntry{AppleURL: "https://music.apple.com/us/album/x/1?i=3"}), false},
		{"网易云 id 不同",
			mk("S|T|A", "netease", lrc, enrichEntry{NeteaseURL: "https://music.163.com/song?id=1"}),
			mk("S|T|B", "netease", lrc, enrichEntry{NeteaseURL: "https://music.163.com/song?id=2"}), true},
		{"网易云 id 相同",
			mk("S|T|A", "netease", lrc, enrichEntry{NeteaseURL: "https://music.163.com/song?id=1"}),
			mk("S|T|B", "netease", other, enrichEntry{NeteaseURL: "https://music.163.com/song?id=1"}), false},
		{"不知道来源、正文一字不差", mk("S|T|A", "", lrc, enrichEntry{}), mk("S|T|B", "", lrc, enrichEntry{}), false},
		{"一边不知道来源、正文一字不差", mk("S|T|A", "kugou", lrc, enrichEntry{}), mk("S|T|B", "", lrc, enrichEntry{}), false},
		{"两个源", mk("S|T|A", "kugou", lrc, enrichEntry{}), mk("S|T|B", "qq", lrc, enrichEntry{}), true},
	}
	for _, c := range cases {
		if got := songLyricsIndependent(c.x, c.y, ""); got != c.want {
			t.Errorf("%s:独立=%v,要 %v", c.name, got, c.want)
		}
	}
}

// 删减版与不删减版归 explicit 那条否决、记成 explicit;版本词不同的记成 version。版次词例外要两边版本词真有差别。
func TestSongEntityVersionAndExplicitVetoes(t *testing.T) {
	explicit := []songVariant{
		songTestVariant("Singer|Track|Petal [Clean]", enrichEntry{DurationSecs: 200, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
		songTestVariant("Singer|Track|Petal [Explicit]", enrichEntry{DurationSecs: 200, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
	}
	if b, of := songTestBuild(t, explicit, nil); songTestSame(of, explicit[0].key, explicit[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "explicit" {
		t.Errorf("删减版与不删减版要否决、记成 explicit: %+v", b.vetoed)
	}
	live := []songVariant{
		songTestVariant("Singer|Track (Live)|Tour", enrichEntry{DurationSecs: 200, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
		songTestVariant("Singer|Track|Album", enrichEntry{DurationSecs: 200, SpotifyTrackID: "abcdefghijklmnopqrstuv"}, nil),
	}
	if b, of := songTestBuild(t, live, nil); songTestSame(of, live[0].key, live[1].key) || len(b.vetoed) == 0 || b.vetoed[0].reason != "version" {
		t.Errorf("现场版与录音室版要否决、记成 version: %+v", b.vetoed)
	}
	same := songTestVariant("Singer|Track|Petal [Clean]", enrichEntry{DurationSecs: 200}, nil)
	other := songTestVariant("Singer|Track|Petal [Explicit]", enrichEntry{DurationSecs: 200}, nil)
	if songOnlyAlbumEditionDiffers(&same, &other) {
		t.Error("两边版本词一样时不算「只差版次词」")
	}
}

// 检索 id 的登记歌名:组里几条写法各自推出的不是同一种写法族时当不知道,边只当计数用。
func TestSongEntityRegisteredTitleConflict(t *testing.T) {
	ne := "https://music.163.com/song?id=7"
	edge := func(regA, regB string) *songEdge {
		vs := []songVariant{
			songTestVariant("Singer|Tune|One", enrichEntry{DurationSecs: 200, NeteaseURL: ne}, map[string]string{"netease_song:7": regA}),
			songTestVariant("Singer|Tune|Two", enrichEntry{DurationSecs: 200.3, NeteaseURL: ne}, map[string]string{"netease_song:7": regB}),
		}
		b, _ := songTestBuild(t, vs, nil)
		for i := range b.edges {
			if b.edges[i].kind == songIDNeteaseSong {
				return &b.edges[i]
			}
		}
		return nil
	}
	if e := edge("Tune", "Tune"); e == nil || e.countOnly {
		t.Errorf("登记歌名一致、对得上:全量的边 %+v", e)
	}
	if e := edge("Tune", "Another Song"); e == nil || !e.countOnly {
		t.Errorf("几条写法推出的登记歌名不一致:只当计数用 %+v", e)
	}
}
