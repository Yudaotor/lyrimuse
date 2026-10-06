package main

import (
	"context"
	"os"
	"strings"
	"testing"
)

// 查询词:日文歌(任一栏带假名)不繁转简,不把「夢」转成「梦」;中文照旧繁转简;中文人名的间隔号「・」不算假名。
// 两种都先把同形异码字换回标准字、去掉歌名和专辑名的宣传尾段。
func TestSearchQueryFields(t *testing.T) {
	cases := []struct {
		in, want [3]string
	}{
		{[3]string{"宇多田ヒカル", "君に夢中", "BADモード"}, [3]string{"宇多田ヒカル", "君に夢中", "BADモード"}},
		{[3]string{"宇多田ヒカル", "夢", ""}, [3]string{"宇多田ヒカル", "夢", ""}},
		{[3]string{"周杰倫", "晴天", "葉惠美"}, [3]string{"周杰伦", "晴天", "叶惠美"}},
		{[3]string{"麥可・傑克森", "顫慄", ""}, [3]string{"麦可・杰克森", "颤栗", ""}},
		{[3]string{"Utada", "First Love", ""}, [3]string{"Utada", "First Love", ""}},
		{[3]string{"周杰倫", "給我ㄧ首歌的時間", ""}, [3]string{"周杰伦", "给我一首歌的时间", ""}},
		{[3]string{"林宥嘉", "⽩", "王"}, [3]string{"林宥嘉", "白", "王"}},
		{[3]string{"宇多田ヒカル", "⽇曜日", ""}, [3]string{"宇多田ヒカル", "日曜日", ""}},
		{[3]string{"陳嘉樺", "傀 - 張藝謀<影>電影主題曲", "傀 - 張藝謀<影>電影主題曲"}, [3]string{"陈嘉桦", "傀", "傀"}},
	}
	for _, c := range cases {
		a, ti, al := searchQueryFields(c.in[0], c.in[1], c.in[2])
		if got := [3]string{a, ti, al}; got != c.want {
			t.Errorf("searchQueryFields(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 接线守卫:发查询的几处都走 searchQueryFields,别再直接 toSimplified 三栏。
func TestSearchQueryFieldsIsWired(t *testing.T) {
	for file, needle := range map[string]string{
		"enrich.go":              "artist, title, searchAlbum = searchQueryFields(artist, title, searchAlbum)",
		"searchcli.go":           "sArtist, sTitle, sAlbum := searchQueryFields(*artist, *title, *album)",
		"resynclyricscli.go":     "artist, title, album = searchQueryFields(artist, title, album)",
		"testlyricsourcescli.go": "searchQueryFields(artist, title, album)",
		"healthcheckcli.go":      "searchQueryFields(p.artist, p.title, p.album)",
	} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(b), needle) {
			t.Errorf("%s 发查询没走 searchQueryFields", file)
		}
		if strings.Contains(string(b), "toSimplified(title), toSimplified(album)") {
			t.Errorf("%s 还在直接把三栏 toSimplified 了再发查询", file)
		}
	}
}

// 同形异码字换掉之后,原样写法照旧记下来,给按原样收录的源多试一种。
func TestSearchQueryOriginalKeepsHanLookalikes(t *testing.T) {
	a, ti, al, ok := searchQueryOriginalFrom(withSearchQueryOriginal(context.Background(), "林宥嘉", "⽩", "王"))
	if !ok || a != "林宥嘉" || ti != "⽩" || al != "王" {
		t.Errorf("searchQueryOriginalFrom = %q %q %q %v, want 林宥嘉 ⽩ 王 true", a, ti, al, ok)
	}
}

// 按原样标签记下的东西:这一轮问的就是原样那组时拿原样的查,换了身份的轮次用手上这组。
func TestLyricIdentityFields(t *testing.T) {
	cases := []struct {
		orig, given, want [3]string
	}{
		{[3]string{"周杰倫", "晴天", "葉惠美"}, [3]string{"周杰伦", "晴天", "叶惠美"}, [3]string{"周杰倫", "晴天", "葉惠美"}},
		{[3]string{"五月天", "什麼歌 - 電影<捉妖記2>主題曲", "什麼歌"}, [3]string{"五月天", "什么歌", "什么歌"}, [3]string{"五月天", "什麼歌 - 電影<捉妖記2>主題曲", "什麼歌"}},
		// 别名轮、标题反查轮:手上这组不是原样那组改写出来的
		{[3]string{"周杰倫", "晴天", "葉惠美"}, [3]string{"Jay Chou", "晴天", "叶惠美"}, [3]string{"Jay Chou", "晴天", "叶惠美"}},
		{[3]string{"周杰倫", "晴天", "葉惠美"}, [3]string{"周杰伦", "晴天 (Live)", "叶惠美"}, [3]string{"周杰伦", "晴天 (Live)", "叶惠美"}},
	}
	for _, c := range cases {
		ctx := withSearchQueryOriginal(context.Background(), c.orig[0], c.orig[1], c.orig[2])
		a, ti, al := lyricIdentityFields(ctx, c.given[0], c.given[1], c.given[2])
		if got := [3]string{a, ti, al}; got != c.want {
			t.Errorf("lyricIdentityFields(orig %q, given %q) = %q, want %q", c.orig, c.given, got, c.want)
		}
	}
	if a, ti, al := lyricIdentityFields(context.Background(), "Adele", "Hello", "25"); a != "Adele" || ti != "Hello" || al != "25" {
		t.Errorf("没记原样写法时应原样返回手上这组, got %q %q %q", a, ti, al)
	}
}

// 繁体标签的歌:播放时记下的平台曲目 ID 按原样标签存,检索词是简体,要经 lyricIdentityFields 才查得到。
func TestPlaybackTrackIDsFoundForNormalizedQuery(t *testing.T) {
	const artist, title, album = "周杰倫", "給我ㄧ首歌的時間", "魔杰座"
	notePlayingAppleCatalogID(artist, title, album, 902117)
	notePlayingSpotifyTrackID(artist, title, album, "spotify-test-id")
	defer func() {
		playbackTrackIDMu.Lock()
		delete(playbackTrackIDHints, enrichKey(artist, title, album))
		playbackTrackIDMu.Unlock()
	}()
	ctx := withSearchQueryOriginal(context.Background(), artist, title, album)
	qa, qt, qal := searchQueryFields(artist, title, album)
	if a, s := playbackTrackIDsFor(qa, qt, qal); a != "" || s != "" {
		t.Fatalf("检索词本来就对不上原样标签记的提示,这个用例前提不成立: %q %q", a, s)
	}
	if a, s := playbackTrackIDsFor(lyricIdentityFields(ctx, qa, qt, qal)); a != "902117" || s != "spotify-test-id" {
		t.Errorf("playbackTrackIDsFor(lyricIdentityFields(...)) = %q %q, want 902117 spotify-test-id", a, s)
	}
}

// 接线守卫:取词那一轮查平台曲目 ID、本机客户端歌词、ISRC 都走 lyricIdentityFields。
func TestLyricIdentityFieldsIsWired(t *testing.T) {
	for file, needles := range map[string][]string{
		"enrich.go": {
			"idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)",
			"appleCatalogID, spotifyTrackID := playbackTrackIDsFor(idArtist, idTitle, idAlbum)",
			"appleID, spotifyID := musixmatchTrackIDsFor(idArtist, idTitle, idAlbum)",
			"appleID, _ := playbackTrackIDsFor(idArtist, idTitle, idAlbum)",
			"kkboxLocalLyricsFor(idArtist, idTitle, durationSecs)",
			"spotifyLocalLyricsFor(idArtist, idTitle, idAlbum)",
			"amazonLocalLyricsFor(idArtist, idTitle)",
		},
		"isrcretry.go":  {"playbackISRC(lyricIdentityFields(ctx, artist, title, album))"},
		"applemusic.go": {"applemusicLocalLyric(catalogID, idArtist, idTitle, idAlbum, durationSecs)"},
	} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, n := range needles {
			if !strings.Contains(string(b), n) {
				t.Errorf("%s 缺 %q", file, n)
			}
		}
	}
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, old := range []string{"playbackTrackIDsFor(artist, title, album)", "musixmatchTrackIDsFor(artist, title, album)", "LocalLyricsFor(artist, title"} {
		if strings.Contains(string(b), old) {
			t.Errorf("enrich.go 还在拿查询词 %q 查按原样标签记的东西", old)
		}
	}
}
