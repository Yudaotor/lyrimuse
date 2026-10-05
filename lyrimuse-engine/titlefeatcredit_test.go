package main

import "testing"

// 歌名括号外带合作署名(「X featuring Y」「X feat. Y」「X - Featuring Y」)时,歌名闸去掉这一段再比。
func TestStripTitleFeatCredit(t *testing.T) {
	for _, c := range []struct {
		in, want string
		ok       bool
	}{
		{"爱的初体验  featuring 周国贤", "爱的初体验  ", true},
		{"爱的初体验feat.周国贤", "爱的初体验", true},
		{"我们都有问题 feat. N.CHEN", "我们都有问题 ", true},
		{"We Own The Night - Featuring Pixie Lott", "We Own The Night - ", true},
		{"Song ft. Someone", "Song ", true},
		{"Song FEAT Someone", "Song ", true},
		{"Song feat Someone", "Song ", true},
		// 不是署名:词中间的 ft / feat、后面没跟名字、歌名本身以这几个词开头。
		{"Lift Me Up", "Lift Me Up", false},
		{"Feather", "Feather", false},
		{"Gift of Love", "Gift of Love", false},
		{"Defeat The Night", "Defeat The Night", false},
		{"Song of the Feather Moon", "Song of the Feather Moon", false},
		{"Song feat.", "Song feat.", false},
		{"Featuring Friends", "Featuring Friends", false},
		{"Ft. Lauderdale", "Ft. Lauderdale", false},
		{"", "", false},
	} {
		got, ok := stripTitleFeatCredit(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("stripTitleFeatCredit(%q) = (%q, %v), want (%q, %v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestLyricTitleAcceptedLocalFeatCredit(t *testing.T) {
	for _, c := range []struct {
		label, candidate, local string
		accept                  bool
	}{
		{"本地括号外带署名,候选只有歌名 + 版本括号", "爱的初体验 (Live)", "爱的初体验 [Live 08] featuring 周国贤", true},
		{"两边都带署名,写法不同(feat. / featuring)", "爱的初体验[Live 08]feat.周国贤", "爱的初体验 [Live 08] featuring 周国贤", true},
		{"破折号接署名", "We Own The Night", "We Own The Night - Featuring Pixie Lott", true},
		{"候选的署名在括号里", "你残忍可爱的傲慢 (feat. 王若琳)", "你残忍可爱的傲慢 feat. Joanna Wang 王若琳", true},
		{"候选署名换了一种写法", "我们都有问题 (feat. NCHEN)", "我们都有问题 feat. N.CHEN", true},
		// 只放宽本地带署名这一种,其余判定不变。
		{"本地没带署名、候选带:不认(可能是加了客串段落的另一次录音)", "Despacito feat. Justin Bieber", "Despacito", false},
		{"去掉署名之后歌名仍不同", "爱的初体验 2", "爱的初体验 featuring 周国贤", false},
		{"去掉署名之后只是前缀:照旧不认子串", "Real Love Baby", "Real Love feat. Someone", false},
		{"本地歌名以署名词开头:没有可去的", "Friends", "Featuring Friends", false},
		{"词中间的 ft 不是署名", "Lift", "Lift Me Up", false},
	} {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.accept {
			t.Errorf("%s: lyricTitleAccepted(%q, %q) = %v, want %v", c.label, c.candidate, c.local, got, c.accept)
		}
	}
}
