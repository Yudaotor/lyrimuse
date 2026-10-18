package main

import "testing"

// 同一位歌手的两种写法:只差中日韩字之间的分隔符(两个方向);候选是「中文名英文名」连写、其中一半跟本地整个名字相等(只认这个
// 方向,本地是双语署名的见决策 180)。仿冒号的尾巴、上传者加的通用词、太短的英文名、合作署名都不认。
func TestArtistNameFormMatches(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"小宇-宋念宇", "小宇 宋念宇", true},
		{"G.E.M.邓紫棋", "邓紫棋", true},
		{"G.E.M.邓紫棋", "鄧紫棋", true},
		{"袁娅维TIA RAY", "袁娅维", true},
		{"JJ林俊傑", "林俊杰", true},
		{"法兰Fran", "法蘭", true},
		{"TANK 吕建忠", "Tank", true},
		{"周杰伦 - Jay Chou", "Jay Chou", true},
		{"邓紫棋", "G.E.M.邓紫棋", false},
		{"小宇 宋念宇", "小宇-宋念宇", true},
		{"周杰伦-", "周杰伦", false},
		{"周杰伦-翻唱", "周杰伦", false},
		{"邓紫棋Cover", "邓紫棋", false},
		{"邓紫棋 Fans", "邓紫棋", false},
		{"en王翊恩", "en", false},
		{"en王翊恩", "王翊恩", true},
		{"李Ann", "李", false},
		{"周杰伦Jay林俊杰", "周杰伦", false},
		{"周杰伦&林俊杰JJ", "周杰伦", false},
		{"Jay&周杰伦", "周杰伦", false},
		{"林俊杰JJ周杰伦Jay", "Jay", false},
		{"G.E.M.邓紫棋", "G.E.M.", true},
		{"G.E.M.邓紫棋", "林俊杰", false},
		{"袁娅维TIA RAY", "TIA", false},
	} {
		if got := artistNameFormMatches(c.a, c.b); got != c.want {
			t.Errorf("artistNameFormMatches(%q, %q) = %v,期望 %v", c.a, c.b, got, c.want)
		}
	}
	// 只接在酷我挑候选上;通用的歌手闸不变(别的源有「歌手名包含」那一档,按弱证据配更严的时长)。
	for _, c := range []struct {
		artist string
		want   bool
	}{{"G.E.M.邓紫棋", true}, {"邓紫棋Cover", false}} {
		item := kuwoSearchItem{SongName: "唯一", Artist: c.artist, Album: "T.I.M.E.", Duration: "253"}
		if got := kuwoCandidateScore(item, "邓紫棋", "唯一", "T.I.M.E. - EP", 253) >= 0; got != c.want {
			t.Errorf("酷我 %q: 收下 %v,期望 %v", c.artist, got, c.want)
		}
	}
	if lyricSourceArtistMatches("G.E.M.邓紫棋", "邓紫棋") {
		t.Error("通用歌手闸不变")
	}
}
