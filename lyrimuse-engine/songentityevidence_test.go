package main

import "testing"

// 两份同源歌词独立不独立:网易云按写法上那个 id 比(就是歌词出处);QQ、Apple 的链接是另外单独查的,按正文比;
// 有一边不知道来源时也按正文比。
func TestSongLyricsIndependentSourceIDs(t *testing.T) {
	lrc := songTestLRC(1000, songTestWords("same", 30))
	other := songTestLRC(1000, songTestWords("diff", 30))
	mk := func(key, src, lyrics string, e enrichEntry) *songVariant {
		e.DurationSecs, e.ResolvedDurationSecs, e.Lyrics, e.LyricsSource = 200, 200, bt(lyrics), src
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

// 记了来路的号按记的级别;没记的(这一机制之前写进来的)按写法有没有版本词推断。
func TestSongVariantISRCLevels(t *testing.T) {
	level := func(key string, e enrichEntry) songIDLevel {
		v := songVariantOf(key, e, false)
		_, l := v.gradedID(songIDISRC)
		return l
	}
	code := "USAAA1100001"
	if l := level("A|Song (Live)|Tour", enrichEntry{ISRCs: []string{code}, ISRCLevels: map[string]string{code: isrcLevelPlayer}}); l != songIDPlayer {
		t.Errorf("带版本词的写法上播放器给的号:player,实得 %v", l)
	}
	if l := level("A|Song|Album", enrichEntry{ISRCs: []string{code}, ISRCLevels: map[string]string{code: isrcLevelSearched}}); l != songIDSearched {
		t.Errorf("记成 searched 的号不当证据,实得 %v", l)
	}
	if l := level("A|Song|Album", enrichEntry{ISRCs: []string{code}}); l != songIDVerified {
		t.Errorf("没记级别、没有版本词:verified,实得 %v", l)
	}
	if l := level("A|Song (Live)|Tour", enrichEntry{ISRCs: []string{code}}); l != songIDSearched {
		t.Errorf("没记级别、带版本词:searched,实得 %v", l)
	}
}

// 主歌手:MusicBrainz 名字缓存里登记的别的名字(中文别名、MusicBrainz 别名列表)对得上的算同一个人;不含汉字、去掉空格
// 不到 3 个字符的别名不用;两份缓存都没登记的照旧认不出。
func TestSongArtistMatchCachedNames(t *testing.T) {
	withCachedAliases(t, map[string]string{"Wang Leehom": "王力宏"})
	withCachedMBAliases(t, map[string][]string{
		"Musiq":        {"Musiq Soulchild"},
		"宇多田ヒカル":       {"Hikaru Utada", "宇多田光"},
		"Short Cutter": {"S C"},
	})
	cases := []struct {
		a, b string
		want bool
	}{
		{"Wang Leehom", "王力宏", true},
		{"Musiq Soulchild", "Musiq", true},
		{"宇多田光", "宇多田ヒカル", true},
		{"Short Cutter", "S C", false},
		{"Musiq", "Musiq Soulchild Band", false},
		{"Nobody Here", "Somebody Else", false},
	}
	for _, c := range cases {
		if got := songArtistMatch(c.a, c.b); got != c.want {
			t.Errorf("songArtistMatch(%q, %q) = %v,应为 %v", c.a, c.b, got, c.want)
		}
	}
	// 歌手写法不同、时长对得上的同一首,经名字缓存并成一个实体
	_, of := songTestBuild(t, []songVariant{
		songTestVariant("Musiq Soulchild|Love|Aijuswannasing", enrichEntry{DurationSecs: 300}, nil),
		songTestVariant("Musiq|Love|Aijuswannasing", enrichEntry{DurationSecs: 300.4}, nil),
	}, nil)
	if !songTestSame(of, "Musiq Soulchild|Love|Aijuswannasing", "Musiq|Love|Aijuswannasing") {
		t.Error("MusicBrainz 别名列表认出同一个人,同名同时长的应当并成一首")
	}
}

// 空格隔开的双语署名只多认 CJK 那一半;拉丁那一半、文字交替三段以上、同一种文字、带括号的都不拆。
func TestSongArtistMatchSpacedBilingual(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"田馥甄 Hebe Tien", "田馥甄", true},
		{"曹格", "Gary 曹格", true},
		{"TIA LEE 李毓芬", "李毓芬", true},
		{"Lee 木子", "Lee", false},
		{"田馥甄 Hebe Tien", "Hebe Tien", false},
		{"Hebe 田馥甄 Tien", "田馥甄", false},
		{"五月天 阿信", "五月天", false},
	}
	for _, c := range cases {
		if got := songArtistMatch(c.a, c.b); got != c.want {
			t.Errorf("songArtistMatch(%q, %q) = %v,应为 %v", c.a, c.b, got, c.want)
		}
	}
	for name, want := range map[string]string{
		"田馥甄 Hebe Tien":      "田馥甄",
		"TIA LEE 李毓芬":        "李毓芬",
		"Hebe 田馥甄 Tien":      "",
		"Taylor Swift":       "",
		"TF家族 Boys":          "",
		"周杰伦 feat. Lara":     "",
		"Taylor Swift (泰勒絲)": "",
	} {
		if got := songSpacedBilingualCJK(name); got != want {
			t.Errorf("songSpacedBilingualCJK(%q) = %q,应为 %q", name, got, want)
		}
	}
	_, of := songTestBuild(t, []songVariant{
		songTestVariant("田馥甄 Hebe Tien|烏鴉|", enrichEntry{DurationSecs: 225}, nil),
		songTestVariant("田馥甄|乌鸦|要去什麼地方", enrichEntry{DurationSecs: 224.91}, nil),
	}, nil)
	if !songTestSame(of, "田馥甄 Hebe Tien|烏鴉|", "田馥甄|乌鸦|要去什麼地方") {
		t.Error("双语署名的 CJK 那一半就是另一边的歌手,同一写法族、时长对得上的应当并成一首")
	}
}
