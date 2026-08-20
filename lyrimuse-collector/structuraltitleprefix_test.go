package main

import (
	"reflect"
	"testing"
)

// 2026-08-17 用户报「这首歌找不到歌词」:D'Angelo《Voodoo》里那首,Apple Music 报的标题是
// "Medley: Greatdayndamornin' / Booty",而五个歌词源的曲库里都叫
// "Greatdayndamornin'/Booty"。实测带前缀搜 **五源全 0 条**,去掉前缀(歌手/专辑不动)
// **五源全命中**、最高 1270 分。
//
// 两道闸都得改:searchTitleVariants(拿什么去搜)和 lyricTitleAccepted(候选算不算这首歌)。
const medleyLocal = "Medley: Greatdayndamornin' / Booty"

func TestStripStructuralTitlePrefix(t *testing.T) {
	cases := []struct{ in, want string }{
		{medleyLocal, "Greatdayndamornin' / Booty"},
		{"Interlude: Something", "Something"},
		{"medley: lower case label", "lower case label"}, // 标签大小写不敏感
		{"Medley:NoSpace", "NoSpace"},

		// ⚠️ 不在白名单里的一律原样返回 —— 否则 "Foo: Bar" 会被切成 "Bar"、
		// 跟另一首真叫 "Bar" 的歌混为一谈。
		{"Foo: Bar", "Foo: Bar"},
		{"Medleys: X", "Medleys: X"}, // 要求整段相等，不是前缀
		{"Untitled (How Does It Feel)", "Untitled (How Does It Feel)"},
		{"No colon here", "No colon here"},
		{": leading colon", ": leading colon"}, // 冒号在最前面，前面没有标签
		{"", ""},
	}
	for _, c := range cases {
		if got := stripStructuralTitlePrefix(c.in); got != c.want {
			t.Errorf("stripStructuralTitlePrefix(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSearchTitleVariantsStructuralPrefix(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		// 本次新增:裸曲名优先,原样标题留作兜底。
		{medleyLocal, []string{"Greatdayndamornin' / Booty", medleyLocal}},

		// ⚠️ 下面这些是改动前就有的行为,不能被改坏。
		{"Automatic (Remastered 2014)", []string{"Automatic", "Automatic (Remastered 2014)"}},
		// 版本限定词(另一次录音)→ 原样标题优先,见 searchTitleVariants 注释。
		{"Billie Jean (Single Version)", []string{"Billie Jean (Single Version)", "Billie Jean"}},
		// 没有任何装饰 → 只有一个变体,不多打请求。
		{"Voodoo", []string{"Voodoo"}},
		{"Foo: Bar", []string{"Foo: Bar"}},
	}
	for _, c := range cases {
		if got := searchTitleVariants(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("searchTitleVariants(%q) = %#v, want %#v", c.in, got, c.want)
		}
	}
}

func TestLyricTitleAcceptedStructuralPrefix(t *testing.T) {
	cases := []struct {
		candidate, local string
		want             bool
		why              string
	}{
		// 本次修的正题:两种斜杠写法都要认。
		{"Greatdayndamornin'/Booty", medleyLocal, true, "源曲库里的裸曲名"},
		{"Greatdayndamornin' / Booty", medleyLocal, true, "斜杠两边带空格的写法"},
		{medleyLocal, "Greatdayndamornin'/Booty", true, "反向(前缀在候选那一侧)"},

		// ⚠️ 最关键的回归守卫:这一条**不能**变成子串包含。
		// lyricTitleAccepted 的注释把这个定时炸弹写得很清楚。
		{"Real Love", "Real Love Baby", false, "子串,但两边都没有结构性前缀可砍"},
		{"Booty", medleyLocal, false, "串烧里的半首歌不算这首歌"},
		{"Greatdayndamornin'", medleyLocal, false, "同上,另外半首"},
		{"Bar", "Foo: Bar", false, "Foo 不在白名单,砍不掉"},

		// 改动前就成立的三条退路,不能丢。
		{"Automatic", "Automatic (Remastered 2014)", true, "各自去括号后相等"},
		{"Voodoo", "Voodoo", true, "完全相等"},
		{"Something Else", "Voodoo", false, "毫无关系"},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.want {
			t.Errorf("lyricTitleAccepted(%q, %q) = %v, want %v —— %s",
				c.candidate, c.local, got, c.want, c.why)
		}
	}
}
