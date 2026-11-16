package main

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

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

// inheritFamilyLRC 是同一份九行正文、整体平移 shiftMs 的时间轴:平移量相同的几份是同一份副本(并成一家),
// 错开几百毫秒的是各自打轴的独立信源。
func inheritFamilyLRC(shiftMs int) string {
	texts := []string{
		"the first line of this song", "a second line follows here", "and then a third one comes",
		"fourth line keeps it going", "fifth line still singing", "sixth line nearly there",
		"seventh line of the verse", "eighth line closes it out", "ninth line for the ending",
	}
	var b strings.Builder
	for i, s := range texts {
		ms := 10_000 + i*5_000 + shiftMs
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", ms/60000, ms/1000%60, ms%1000/10, s)
	}
	return b.String()
}

func inheritedPoints(t *testing.T, localTitle, localAlbum string, cands []lyricCandidate) (map[string][]string, map[string][2]int) {
	t.Helper()
	peers, familyPeers := contentConsensusPeers("someone", localTitle, cands, 0)
	inheritIdentityTerms(localTitle, localAlbum, cands, familyPeers)
	got := map[string][2]int{}
	for _, c := range cands {
		got[c.source] = [2]int{c.inheritedAlbumPoints, c.inheritedTitlePoints}
	}
	return peers, got
}

// 互证伙伴是 LyricFind 一家:家族代表 lyricfind 那份是按原名补搜回来的(歌名 0 分),同家的 deezer 是播放器报的
// 罗马字歌名、专辑也对得上。继承取这一家里最高那档,不只看代表。
func TestInheritIdentityTermsTakesBestOfLyricFindFamily(t *testing.T) {
	const localTitle, localAlbum = "Situation", "Situation - Single"
	cands := []lyricCandidate{
		{source: "petitlyrics", title: "シチュエーション", album: "シチュエーション", lyrics: inheritFamilyLRC(0)},
		{source: lyricSourceLyricFind, title: "シチュエーション", album: "シチュエーション", lyrics: inheritFamilyLRC(300)},
		{source: lyricSourceDeezer, title: "Situation", album: "Situation - Single", lyrics: inheritFamilyLRC(-250)},
		{source: "netease", title: "シチュエーション", lyrics: inheritFamilyLRC(550)},
	}
	peers, got := inheritedPoints(t, localTitle, localAlbum, cands)
	if !reflect.DeepEqual(peers["petitlyrics"], []string{lyricSourceLyricFind, "netease"}) {
		t.Fatalf("前提:petitlyrics 的互证名单该是 [lyricfind netease](deezer 跟 lyricfind 一家、只留代表),实际 %v", peers["petitlyrics"])
	}
	want := map[string][2]int{
		"petitlyrics":        {150, 120}, // 代表 0 分,同家的 deezer 120 / 150
		"netease":            {0, 120},   // 没报专辑名:只补歌名
		lyricSourceLyricFind: {0, 0},     // 自己那一家的 deezer 不算伙伴,别家都是 0 分
		lyricSourceDeezer:    {0, 0},     // 自己就对得上
	}
	for s, w := range want {
		if got[s] != w {
			t.Errorf("%s: 继承 [专辑, 歌名] = %v, want %v", s, got[s], w)
		}
	}

	// 过不了时长闸(末句比曲长多出 5 秒以上)的候选领不到共识,也继承不到。
	cands[0].lyrics = inheritFamilyLRC(8_000)
	_, familyPeers := contentConsensusPeers("someone", localTitle, cands, 52)
	inheritIdentityTerms(localTitle, localAlbum, cands, familyPeers)
	if c := cands[0]; c.inheritedAlbumPoints != 0 || c.inheritedTitlePoints != 0 {
		t.Errorf("petitlyrics 末句超出曲长仍继承了 [%d, %d]", c.inheritedAlbumPoints, c.inheritedTitlePoints)
	}
	if c := cands[3]; c.inheritedTitlePoints != 120 {
		t.Errorf("netease 时长对得上,该照样继承歌名 120,实际 %d", c.inheritedTitlePoints)
	}
}

// 互证伙伴是时间轴同一份的副本家族(腾讯系三家):代表 qq 那份歌名、专辑都换成了中文,同家另两员一个歌名对得上、
// 一个专辑对得上。两项各取这一家里的最高档。
func TestInheritIdentityTermsTakesBestOfTimelineCopyFamily(t *testing.T) {
	const localTitle, localAlbum = "Wu Kong", "JOURNEY TO THE WEST"
	cands := []lyricCandidate{
		{source: "qq", title: "悟空", album: "西游记", lyrics: inheritFamilyLRC(0)},
		{source: "kugou", title: "Wu Kong (Live)", album: "JOURNEY TO THE WEST", lyrics: inheritFamilyLRC(0)},
		{source: "kuwo", title: "Wu Kong", album: "精选集", lyrics: inheritFamilyLRC(0)},
		{source: "netease", title: "悟空", album: "JTW 西游记", lyrics: inheritFamilyLRC(400)},
	}
	peers, got := inheritedPoints(t, localTitle, localAlbum, cands)
	if !reflect.DeepEqual(peers["netease"], []string{"qq"}) {
		t.Fatalf("前提:netease 的互证名单该只有副本家族的代表 qq,实际 %v", peers["netease"])
	}
	if w := [2]int{150, 120}; got["netease"] != w {
		t.Errorf("netease: 继承 [专辑, 歌名] = %v, want %v(歌名取 kuwo 的 120、专辑取 kugou 的 150)", got["netease"], w)
	}
	// 副本之间不互相继承:qq 的伙伴只有 netease(0 分)。
	if got["qq"] != [2]int{} {
		t.Errorf("qq: 继承 %v,want 不补(同一份副本不算伙伴)", got["qq"])
	}
}

// 伙伴家族里谁都对不上:不补。
func TestInheritIdentityTermsNothingWhenWholeFamilyScoresZero(t *testing.T) {
	const localTitle, localAlbum = "Situation", "Situation - Single"
	cands := []lyricCandidate{
		{source: "petitlyrics", title: "シチュエーション", album: "シチュエーション", lyrics: inheritFamilyLRC(0)},
		{source: lyricSourceLyricFind, title: "シチュエーション", album: "シチュエーション", lyrics: inheritFamilyLRC(300)},
		{source: lyricSourceDeezer, title: "しちゅえーしょん", album: "Best", lyrics: inheritFamilyLRC(-250)},
		{source: "qq", title: "シチュエーション", album: "シチュエーション", lyrics: inheritFamilyLRC(700)},
		{source: "kuwo", title: "シチュエーション (TV size)", album: "Anime", lyrics: inheritFamilyLRC(700)},
	}
	_, got := inheritedPoints(t, localTitle, localAlbum, cands)
	for s, g := range got {
		if g != [2]int{} {
			t.Errorf("%s: 继承 %v,want 不补(各家全员 0 分)", s, g)
		}
	}
}
