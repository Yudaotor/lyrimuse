package main

import (
	"reflect"
	"testing"
)

// normalizeArtistCreditHanAnd 的判据——见其声明处头注(方大同 & Fiona Sit《Four Tour》案)。
func TestNormalizeArtistCreditHanAnd(t *testing.T) {
	cases := []struct{ in, want, why string }{
		{"Khalil Fong和Fiona Sit", "Khalil Fong&Fiona Sit", "两侧都是拉丁字母,当分隔符"},
		{"A和B和C", "A&B&C", "连续多个'和'都要各自独立判断,不能漏掉后半段"},
		{"李和平", "李和平", "纯中文人名本身含'和',两侧中文段各只有1字,不达标,原样保留"},
		{"和平", "和平", "'和'在开头,左侧没有字符,原样保留"},
		{"Khalil Fong和", "Khalil Fong和", "'和'在末尾,右侧没有字符,原样保留"},
		{"陶喆、卢广仲", "陶喆、卢广仲", "完全不含'和',原样返回(走快速路径)"},
		{"", "", "空串"},
		{"周杰伦 & 派伟俊", "周杰伦 & 派伟俊", "不含'和'时原样返回,不误伤已有的'&'分隔符"},
		// 2026-08-31 真实bug(陶喆《再見你好嗎》专辑"那個女孩(feat. 盧廣仲)"案,见头注):
		// 两侧都是中文、且各自≥2字时也当连接词。
		{"陶喆和盧廣仲", "陶喆&盧廣仲", "两侧都是≥2字的中文段,当分隔符"},
		{"陶喆和盧廣仲和蔡健雅", "陶喆&盧廣仲&蔡健雅", "连续多个中文'和'同样要各自独立判断"},
		{"阿三和四", "阿三和四", "右侧中文段只有1字('四'),不达标,原样保留"},
		{"陶喆和盧廣仲、蔡健雅", "陶喆&盧廣仲、蔡健雅", "中文段的边界到已有分隔符('、')为止,不跨过去连着数"},
	}
	for _, c := range cases {
		if got := normalizeArtistCreditHanAnd(c.in); got != c.want {
			t.Errorf("normalizeArtistCreditHanAnd(%q) = %q, want %q (%s)", c.in, got, c.want, c.why)
		}
	}
}

// artistCreditParts 接上 normalizeArtistCreditHanAnd 之后的端到端行为——这是
// lastfmcollapse.go/enrich.go 那几处"是不是合唱串"判断实际读到的结果。
func TestArtistCreditPartsHanAnd(t *testing.T) {
	if got := artistCreditParts("Khalil Fong和Fiona Sit"); !reflect.DeepEqual(got, []string{"khalil fong", "fiona sit"}) {
		t.Errorf("artistCreditParts(%q) = %v, want [khalil fong fiona sit]", "Khalil Fong和Fiona Sit", got)
	}
	if got := artistCreditParts("李和平"); len(got) != 1 || got[0] != "李和平" {
		t.Errorf("artistCreditParts(纯中文含'和'的人名) = %v, 不该被切开", got)
	}
	if got := artistCreditParts("陶喆和盧廣仲"); !reflect.DeepEqual(got, []string{"陶喆", "卢广仲"}) {
		t.Errorf("artistCreditParts(%q) = %v, want [陶喆 卢广仲]（含 toSimplified）", "陶喆和盧廣仲", got)
	}
}

// lyricPrimaryQueryArtist 是"首歌手变体轮"实际用来判断"要不要多试一个检索词"的入口——
// 中文"和"连接的合唱串之前在这里恒为空(取不出首歌手,变体轮永远不触发),现在应该能
// 正确取出首歌手。
func TestLyricPrimaryQueryArtistHanAnd(t *testing.T) {
	if got := lyricPrimaryQueryArtist("Khalil Fong和Fiona Sit"); got != "Khalil Fong" {
		t.Errorf("lyricPrimaryQueryArtist(%q) = %q, want %q", "Khalil Fong和Fiona Sit", got, "Khalil Fong")
	}
	// 陶喆《再見你好嗎》专辑"那個女孩(feat. 盧廣仲)"真实案例:本地标签"陶喆和盧廣仲"
	// 之前恒取不出首歌手(整串被当成一个谁都不认识的艺人名),七个源全部搜不到;单独查
	// "陶喆"四个源立刻命中、分数都在 800 分以上。
	if got := lyricPrimaryQueryArtist("陶喆和盧廣仲"); got != "陶喆" {
		t.Errorf("lyricPrimaryQueryArtist(%q) = %q, want %q", "陶喆和盧廣仲", got, "陶喆")
	}
}
