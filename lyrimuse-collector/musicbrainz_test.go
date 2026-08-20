package main

import "testing"

// 2026-08-05 实测排查坐实的真实 bug 的回归测试:欧美艺人在 MusicBrainz 上的中文别名
// 只是面向中文市场的译名,不该被当成 canonical_artist —— 用户反馈"历史里 Michael
// Jackson 显示成迈克尔·杰克逊,跟之前的英文名不一致"。详见 pickChineseAlias 的注释。
func TestPickChineseAlias(t *testing.T) {
	// 下面每组别名/地区都是照真实 MusicBrainz API 返回抄的(实测查过这三个艺人)。
	mjAliases := []mbAlias{
		{Name: "迈克尔·杰克逊", Locale: "yue_Hans_CN"},
		{Name: "迈克尔·杰克逊", Locale: "zh_Hans"},
	}
	chanAliases := []mbAlias{
		{Name: "陈柏宇", Locale: "zh_Hans"},
		{Name: "陳柏宇", Locale: "zh_Hant"},
	}
	douAliases := []mbAlias{
		{Name: "窦靖童", Locale: "zh_Hans"},
	}

	cases := []struct {
		label   string
		aliases []mbAlias
		country string
		want    string
	}{
		// 核心回归:美国艺人的中文译名必须被拒绝。注意它的 type/primary 跟下面港台
		// 艺人完全一样(实测坐实),所以只能靠 country 区分,见 pickChineseAlias 注释。
		{"美国艺人(Michael Jackson)的中文译名不采纳", mjAliases, "US", ""},
		{"英国艺人同理", mjAliases, "GB", ""},
		// 中文圈艺人:中文名确实是本人的名字,照常采纳。
		{"香港艺人(陈柏宇)采纳中文名", chanAliases, "HK", "陈柏宇"},
		{"大陆艺人(窦靖童)采纳中文名", douAliases, "CN", "窦靖童"},
		{"台湾/澳门/新加坡同属中文圈", chanAliases, "TW", "陈柏宇"},
		{"新加坡(华语歌手常见归属)", chanAliases, "SG", "陈柏宇"},
		// country 缺失时保守放弃,交给后面的网易云那一层接手(见函数注释)。
		{"country 缺失时不采纳", chanAliases, "", ""},
		// 大小写/空白不该影响判定。
		{"country 小写也认", chanAliases, "hk", "陈柏宇"},
		{"country 带空白也认", chanAliases, " HK ", "陈柏宇"},
		// 繁体别名会被转成简体(既有行为,不能因为这次改动丢掉)。
		{"繁体别名转简体", []mbAlias{{Name: "陳柏宇", Locale: "zh_Hant"}}, "HK", "陈柏宇"},
		// 日文 locale 的汉字别名仍要跳过(既有行为)。
		{"日文 locale 别名跳过", []mbAlias{{Name: "日本語名", Locale: "ja"}}, "HK", ""},
		{"没有任何含汉字别名", []mbAlias{{Name: "Some Latin Name", Locale: "en"}}, "HK", ""},
		{"空别名列表", nil, "HK", ""},
		// 2026-08-18 实测翻车:ØZI(TW)在 MusicBrainz 有一条 type="Legal name" 的
		// 「陳奕凡」,拿它当显示名等于把艺人改叫回身份证名。法定名/搜索提示要跳过,
		// 但后面正经的艺名别名照常采纳。
		{"法定名别名跳过", []mbAlias{{Name: "陳奕凡", Locale: "zh_Hant", Type: "Legal name"}}, "TW", ""},
		{"搜索提示别名跳过", []mbAlias{{Name: "某搜索词", Type: "Search hint"}}, "TW", ""},
		{"跳过法定名后仍采纳后面的艺名", []mbAlias{
			{Name: "陳奕凡", Locale: "zh_Hant", Type: "Legal name"},
			{Name: "街巷", Locale: "zh_Hant", Type: "Artist name"},
		}, "TW", "街巷"},
	}
	for _, c := range cases {
		if got := pickChineseAlias(c.aliases, c.country); got != c.want {
			t.Errorf("%s: pickChineseAlias(...) = %q, want %q", c.label, got, c.want)
		}
	}
}
