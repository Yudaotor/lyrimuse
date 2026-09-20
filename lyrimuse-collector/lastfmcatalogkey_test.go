package main

import "testing"

func TestLastfmCatalogTitleKeyFoldsSameRecording(t *testing.T) {
	same := []struct {
		name string
		a, b string
	}{
		// 本坑的原型:播放器报简体,编目里的正规条目是繁体。
		{"繁简", "那个女孩", "那個女孩"},
		// 编目里同一首歌的两条(889 / 654 听众),客串署名是歌手信息不是版本。
		{"客串署名", "那个女孩", "那個女孩 (feat. 盧廣仲)"},
		{"客串署名半角无点", "Toronto 2014", "Toronto 2014 (with Mustafa)"},
		{"客串署名 ft", "盖世英雄", "蓋世英雄 (ft. 欧阳靖)"},
		{"再版母带", "Automatic", "Automatic (Remastered 2014)"},
		{"附加曲", "一路向北", "一路向北 (bonus track)"},
		{"地区附加曲", "一路向北", "一路向北 (Japanese Bonus Track)"},
		{"分级标记", "无所谓", "無所謂 (Explicit)"},
		{"标点与空白", "Susan 说", "Susan說"},
		{"变音符号", "Creep", "Crëep"},
		{"异体字", "你听得到", "妳聽得到"},
	}
	for _, c := range same {
		t.Run(c.name, func(t *testing.T) {
			ka, kb := lastfmCatalogTitleKey(c.a), lastfmCatalogTitleKey(c.b)
			if ka == "" || ka != kb {
				t.Errorf("lastfmCatalogTitleKey(%q)=%q, (%q)=%q; want equal non-empty", c.a, ka, c.b, kb)
			}
		})
	}
}

func TestLastfmCatalogTitleKeyKeepsDistinctRecordings(t *testing.T) {
	distinct := []struct {
		name string
		a, b string
	}{
		// 真版本标记:另一份录音,合了就是把收听记到错的条目上。
		{"现场版", "流沙", "流沙 (Live)"},
		{"重混", "Melody", "Melody (Remix)"},
		{"原声版", "爱很简单", "爱很简单 (Acoustic)"},
		{"伴奏", "黑色柳丁", "黑色柳丁 (伴奏)"},
		{"中文版本词", "沙滩", "沙滩 (钢琴版)"},
		// 混着别的词:宁可漏合。
		{"现场母带混写", "Automatic", "Automatic (Live 2014 Remaster)"},
		{"现场附加曲", "一路向北", "一路向北 (Live Bonus Track)"},
		// 巧合同头的词组,不是署名。
		{"羽毛", "Fade", "Fade (Feathers)"},
		{"没有你", "Sunday", "Sunday (Without You)"},
		{"空署名", "Scream", "Scream (feat.)"},
		// 不同的歌。
		{"不同曲名", "那个女孩", "这个女孩"},
	}
	for _, c := range distinct {
		t.Run(c.name, func(t *testing.T) {
			if ka, kb := lastfmCatalogTitleKey(c.a), lastfmCatalogTitleKey(c.b); ka == kb {
				t.Errorf("lastfmCatalogTitleKey(%q) == (%q) == %q; want different", c.a, c.b, ka)
			}
		})
	}
}

func TestStripCatalogNoiseSubtitleEdgeCases(t *testing.T) {
	cases := []struct{ in, want string }{
		{"那個女孩 (feat. 盧廣仲)", "那個女孩"},
		// 连着两层噪音一路剥到底。
		{"Automatic (feat. X) (Remastered)", "Automatic"},
		// 整个曲名就是一对括号:剥完什么都不剩,原样留着。
		{"(Remastered)", "(Remastered)"},
		{"", ""},
		// 中段括号不动 —— 那种位置更可能是名字本身的一部分。
		{"Sula (与 Lampa) 的寓言", "Sula (与 Lampa) 的寓言"},
	}
	for _, c := range cases {
		if got := stripCatalogNoiseSubtitle(c.in); got != c.want {
			t.Errorf("stripCatalogNoiseSubtitle(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 已知取舍:以 with 开头的**词组**副题会被当成署名剥掉。Swift 侧同款判据接受同一个
// 残余风险(见 PlayCountFold.isCatalogNoiseSubtitle 头注),真撞上了加词组黑名单,
// 别去动「前缀后必须跟点/空格」那道守卫 —— 那道是挡 "(Feathers)" 用的。
func TestStripCatalogNoiseSubtitleKnownFalsePositive(t *testing.T) {
	if got := stripCatalogNoiseSubtitle("I Still Haven't Found (With or Without You)"); got != "I Still Haven't Found" {
		t.Errorf("stripCatalogNoiseSubtitle = %q; 取舍变了就更新这条断言和两侧头注", got)
	}
}
