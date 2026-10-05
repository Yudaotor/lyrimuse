package main

import "testing"

// 「々」只在跟着汉字时换成那个字;没有「々」、开头的「々」、跟着假名的「々」原样。
func TestFoldIterationMark(t *testing.T) {
	for in, want := range map[string]string{
		"水樹奈々":  "水樹奈奈",
		"佐々木李子": "佐佐木李子",
		"奈々々":   "奈奈奈",
		"々木":    "々木",
		"ゆ々":    "ゆ々",
		"Nana々": "Nana々",
		"水树奈奈":  "水树奈奈",
		"":      "",
	} {
		if got := foldIterationMark(in); got != want {
			t.Errorf("foldIterationMark(%q) = %q, 要 %q", in, got, want)
		}
	}
}

// 每一段「X (Y)」换成 Y,半角全角括号都认;CV 括号、feat. / ft. / with、没闭合的括号、括号套括号不换。
func TestParenAliasNames(t *testing.T) {
	for in, want := range map[string]string{
		"水濑祈 (水瀬いのり)":      "水瀬いのり",
		"水濑祈 (水瀬いのり)/花澤香菜": "水瀬いのり/花澤香菜",
		"佐仓绫音、水濑祈 (水瀬いのり)": "佐仓绫音/水瀬いのり",
		"風鳴翼 (水樹奈々)":       "水樹奈々",
		"Jennie（제니）":       "제니",
		"歌手甲":              "",
		"角色甲(CV:声优甲)":      "",
		"歌手甲 (feat. 歌手乙)":  "",
		"歌手甲 (ft. 歌手乙)":    "",
		"歌手甲 (with 歌手乙)":   "",
		"歌手甲 (别名":          "",
		"歌手甲 (别名 (外文名))":   "",
		"(别名)":             "",
	} {
		if got := parenAliasNames(in); got != want {
			t.Errorf("parenAliasNames(%q) = %q, 要 %q", in, got, want)
		}
	}
}

// 接进歌手比对之后:「々」两边写法对得上(CV 署名、合唱名单里也算);括号里的名字当同一位演唱者的另一个名字,
// 两个方向都认;合作者、不同的人、截短的名字仍然对不上。
func TestArtistMatchesNameForms(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"水树奈奈", "水樹奈々", true},
		{"佐佐木李子", "佐々木李子", true},
		{"水树奈奈", "風鳴翼(CV:水樹奈々)", true},
		{"水树奈奈/高垣彩阳", "風鳴翼(CV:水樹奈々) & 雪音クリス(CV:高垣彩陽)", true},
		{"水树奈", "水樹奈々", false},
		{"水濑祈 (水瀬いのり)", "水瀬いのり", true},
		{"水瀬いのり", "水濑祈 (水瀬いのり)", true},
		{"水濑祈 (水瀬いのり)", "チノ(CV.水瀬いのり)", true},
		{"佐仓绫音/水濑祈 (水瀬いのり)", "ココア(佐倉綾音) & チノ(CV.水瀬いのり)", true},
		{"風鳴翼 (水樹奈々)", "水樹奈々", true},
		{"Jennie（제니）", "제니", true},
		{"水濑祈 (水瀬いのり)", "花澤香菜", false},
		{"歌手甲 (feat. 歌手乙)", "歌手乙", false},
		{"歌手甲 (别名甲)", "别名乙", false},
		{"歌手甲 (别名甲)", "歌手甲-", false},
	}
	for _, c := range cases {
		if got := artistMatches(c.a, c.b); got != c.want {
			t.Errorf("artistMatches(%q, %q) = %v, 要 %v", c.a, c.b, got, c.want)
		}
		if got := lyricSourceArtistMatches(c.a, c.b); got != c.want {
			t.Errorf("lyricSourceArtistMatches(%q, %q) = %v, 要 %v", c.a, c.b, got, c.want)
		}
	}
}

// 两边都是多人名单、只能按段求交集对上时,段里的「々」同样展开(artistCreditParts 那一处)。
func TestLyricSourceArtistMatchesIterationMarkParts(t *testing.T) {
	if !lyricSourceArtistMatches("水树奈奈/歌手甲", "水樹奈々、歌手乙") {
		t.Error("「水树奈奈/歌手甲」跟「水樹奈々、歌手乙」有同一位歌手,该对得上")
	}
	if lyricSourceArtistMatches("水树奈奈/歌手甲", "水樹奈、歌手乙") {
		t.Error("「水树奈奈」跟「水樹奈」不是同一个人")
	}
}

// 「中文名 英文名」连写的署名:一头是一整段汉字(至少两个字)、其余都是拉丁字母或数字写的词才拆;全角空格也算空白。
func TestBilingualNameParts(t *testing.T) {
	cases := []struct {
		in, han, other string
		ok             bool
	}{
		{"田馥甄 hebe tien", "田馥甄", "hebe tien", true},
		{"anson lo 卢瀚霆", "卢瀚霆", "anson lo", true},
		{"g.e.m. 邓紫棋", "邓紫棋", "g.e.m.", true},
		{"八三夭 831", "八三夭", "831", true},
		{"田馥甄\u3000hebe", "田馥甄", "hebe", true},
		{"田馥甄", "", "", false},
		{"hebe tien", "", "", false},
		{"田馥甄 林宥嘉", "", "", false},
		{"鹤 the crane", "", "", false},
		{"田馥甄 feat. lara", "", "", false},
		{"田馥甄 x lara", "", "", false},
		{"田馥甄 hebe-", "", "", false},
		{"hebe 田馥甄 tien", "", "", false},
		{"田馥甄 hebe/tien", "", "", false},
		{"田馥甄- hebe tien", "", "", false},
		{"", "", "", false},
	}
	for _, c := range cases {
		han, other, ok := bilingualNameParts(c.in)
		if han != c.han || other != c.other || ok != c.ok {
			t.Errorf("bilingualNameParts(%q) = %q, %q, %v, 要 %q, %q, %v", c.in, han, other, ok, c.han, c.other, c.ok)
		}
	}
}

// bilingualHanPart 先归一化(繁转简、小写)再拆,给出的汉字段是 artistMatches 的写法。
func TestBilingualHanPart(t *testing.T) {
	for in, want := range map[string]string{
		"田馥甄 Hebe Tien": "田馥甄",
		"Anson Lo 盧瀚霆":  "卢瀚霆",
		"周杰倫 Jay Chou":  "周杰伦",
		"八三夭 831":       "八三夭",
		"田馥甄":           "",
		"Hebe Tien":     "",
		"鹤 The Crane":   "",
	} {
		if got := bilingualHanPart(in); got != want {
			t.Errorf("bilingualHanPart(%q) = %q, 要 %q", in, got, want)
		}
	}
}
