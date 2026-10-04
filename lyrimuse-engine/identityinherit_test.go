package main

import "testing"

// inheritIdentityTerms:正文互证的伙伴只在「歌名一个字都对不上」时补歌名 / 专辑两项。
func TestInheritIdentityTerms(t *testing.T) {
	const localTitle, localAlbum = "Wu Kong", "JOURNEY TO THE WEST"
	cands := []lyricCandidate{
		{source: amazonLocalLyricsSource, title: "Wu Kong", album: "JOURNEY TO THE WEST"},
		{source: "kugou", title: "悟空", album: "JTW 西游记 (BLACK)"},
		{source: "qq", title: "悟空"},
		{source: "netease", title: "Wu Kong", album: "精选集"},
		{source: "migu", title: "悟空", album: "JTW 西游记"},
	}
	peers := map[string][]string{
		amazonLocalLyricsSource: {"kugou", "qq", "netease"},
		"kugou":                 {amazonLocalLyricsSource, "qq"},
		"qq":                    {amazonLocalLyricsSource, "kugou"},
		"netease":               {amazonLocalLyricsSource},
		// migu 没有互证伙伴(时长闸 / 正文对不上)
	}
	inheritIdentityTerms(localTitle, localAlbum, cands, peers)
	got := map[string][2]int{}
	for _, c := range cands {
		got[c.source] = [2]int{c.inheritedAlbumPoints, c.inheritedTitlePoints}
	}
	want := map[string][2]int{
		amazonLocalLyricsSource: {0, 0},     // 自己就对得上,不补
		"kugou":                 {150, 120}, // 歌名、专辑都换成了另一种语言:两项都补
		"qq":                    {0, 120},   // 没报专辑名:只补歌名
		"netease":               {0, 0},     // 歌名对得上、只有专辑对不上:是另一张专辑,不补
		"migu":                  {0, 0},     // 没有互证伙伴
	}
	for s, w := range want {
		if got[s] != w {
			t.Errorf("%s: 继承 [专辑, 歌名] = %v, want %v", s, got[s], w)
		}
	}

	// 打分里取自己的和继承的里较大的那个:补上之后,两边在这两项上持平。
	for _, c := range cands[:2] {
		_, terms := scoreLyricCandidateDetailed("Khalil Fong", localTitle, localAlbum, 0,
			lyricCandidate{source: c.source, title: c.title, album: c.album, lyrics: "[00:01.00] a\n[00:05.00] b\n[00:09.00] c",
				inheritedAlbumPoints: c.inheritedAlbumPoints, inheritedTitlePoints: c.inheritedTitlePoints}, false, 0)
		if scoreTermPoints(terms, scoreTermAlbum) != 150 || scoreTermPoints(terms, scoreTermTitleMatch) != 120 {
			t.Errorf("%s: 打分后专辑 %d / 歌名 %d,want 150 / 120", c.source,
				scoreTermPoints(terms, scoreTermAlbum), scoreTermPoints(terms, scoreTermTitleMatch))
		}
	}
}
