package main

import (
	"slices"
	"testing"
)

func TestCreditCoArtists(t *testing.T) {
	cases := []struct {
		artist, title string
		want          []string
	}{
		{"Sam Smith & Aitana", "Like I Can", []string{"aitana"}},
		{"Sam Smith", "Like I Can", nil},
		{"Khalil Fong feat. Diana Wang", "All Night (feat. Diana Wang)", []string{"diana wang"}},
		{"方大同", "Flow (feat. 王力宏)", []string{"王力宏"}},
		{"Bruno Mars", "After Last Night (with Thundercat & Bootsy Collins)", []string{"thundercat", "bootsy collins"}},
		{"Tame Impala [feat. JENNIE]", "Dracula", []string{"jennie"}},
		{"周杰伦/Lara梁心颐/杨瑞代", "比较大的大提琴", []string{"lara梁心颐", "杨瑞代"}},
		// 主歌手在合唱串里又出现一次、合作者重复写了两遍,都只算一次。
		{"Michael Jackson & Siedah Garrett & Michael Jackson feat. Siedah Garrett", "I Just Can't Stop Loving You", []string{"siedah garrett"}},
		// feat / ft 不带点、后面紧跟字母的不是合作署名。
		{"Feather", "Lift Me Up", nil},
	}
	for _, c := range cases {
		if got := creditCoArtists(c.artist, c.title); !slices.Equal(got, c.want) {
			t.Errorf("creditCoArtists(%q, %q) = %q, want %q", c.artist, c.title, got, c.want)
		}
	}
}

func TestCreditCovers(t *testing.T) {
	duet := creditCoArtists("Sam Smith & Aitana", "Like I Can")
	if creditCovers(duet, "Sam Smith", "Like I Can") {
		t.Error("只署主歌手的那一轨没写到合作者")
	}
	if !creditCovers(duet, "Sam Smith & Aitana", "Like I Can") {
		t.Error("歌手栏写了合作者")
	}
	if !creditCovers(duet, "Sam Smith", "Like I Can (with Aitana)") {
		t.Error("合作者写在歌名里也算")
	}
	if !creditCovers(nil, "Anyone", "Song") {
		t.Error("本地没点名合作者时恒为真")
	}
	if !creditCovers(creditCoArtists("Earth, Wind & Fire", "September"), "Earth, Wind and Fire", "September") {
		t.Error("团体名的拆法不同,折成 normLoose 后出现在署名里就算写到了")
	}
	if !creditCovers(creditCoArtists("方大同 & 王力宏", "Flow"), "方大同, 王力宏", "Flow") {
		t.Error("分隔符不同照样认")
	}
	if creditCovers([]string{"iu"}, "Brian", "Iugen") {
		t.Error("不到三个字的名字不靠包含认")
	}
}
