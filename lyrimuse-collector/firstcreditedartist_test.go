package main

import "testing"

// 2026-08-23 用户报「播放记录里 K/DA 的歌手怎么是 K」。
//
// 根因:lastfmcollapse 在 scrobble **之前**把查不到编目的合credit 串折成第一位艺人,而
// firstCreditedArtist 当时把 `/` 跟逗号平级、无条件取第一段 ——
// `K/DA/Madison Beer/i-dle/Jaira Burns` 于是被劈成 `K`。日志逐字记着:
//
//	2026/08/17 17:21:14 lastfm collapse: "K/DA/Madison Beer/i-dle/Jaira Burns" -> "K"
//	2026/08/22 11:03:35 lastfm collapse: "K/DA / Madison Beer / i-dle / Jaira Burns" -> "K"
//
// 后果不可逆:`K` 在 Last.fm 上是一个**真实存在的无关歌手**(10.8 万听众),4 次播放全记
// 到了人家名下,而 K/DA(84.8 万听众)名下 0 次;Last.fm 的纠错库已冻结,全局补不回来。
//
// 更值得记住的是它为什么拖了三天:同一道守卫 2026-08-20 就加过了,但只加在 Swift 侧的
// ArtistCredit.primary(那边只管显示),**没回头修这条写侧路径**。所以这一组用例同时是
// 跨语言契约:期望值要跟 lyrimuse-selftest 里 ArtistCredit 那组逐条对得上。
func TestFirstCreditedArtistSlashInName(t *testing.T) {
	cases := []struct{ in, want, why string }{
		// 正题:名字自带斜杠,且全串没有别的分隔符 —— 必须整串保留
		{"K/DA/Madison Beer/i-dle/Jaira Burns", "K/DA",
			"头部 K 判不准 → 再吃一段得到 K/DA;这确实是个合唱串,第一位就是 K/DA"},
		{"K/DA / Madison Beer / i-dle / Jaira Burns", "K/DA",
			"带空格的斜杠写法同理(Apple Music 两种都报过)"},
		{"AC/DC", "AC/DC", "吃到整串仍判不准 = 整串本来就是一个名字,不切"},
		{"AC/DC/Guns N' Roses", "AC/DC", "AC ✗ → AC/DC ✓,别劈成 AC"},
		{"K/DA", "K/DA", "单独出现时不切"},

		// 逗号/& 先命中 —— 顺序本身就是守卫,这一档保住完整的 K/DA
		{"K/DA, Madison Beer & i-dle", "K/DA", "逗号先命中,切出完整的 K/DA"},
		{"K/DA & Madison Beer", "K/DA", "& 先命中"},

		// 该切的照切,不能因为这道守卫退化成"斜杠一律不切"
		{"陶喆/卢广仲", "陶喆", "含汉字两个字就是完整名字"},
		{"英雄联盟/Sara Skinner", "英雄联盟", "汉字头部"},
		{"VALORANT/Grabbitz", "VALORANT", "拉丁头部 ≥3"},
		{"Imagine Dragons/JID/英雄联盟/双城之战", "Imagine Dragons", "拉丁多词头部"},
		{"Sebastien Najand/英雄联盟", "Sebastien Najand", "拉丁多词头部"},

		// 原有行为不能改坏
		{"Prince & The Revolution", "Prince", "& 分隔"},
		{"陶喆、卢广仲", "陶喆", "顿号分隔"},
		{"周杰伦 & 派伟俊", "周杰伦", "全角空格 + &"},
		{"周杰伦", "周杰伦", "单人原样"},
		{"周杰伦、", "周杰伦、", "只切出一段 = 不是合唱,原样返回"},
		{"", "", "空串"},
		// 已知取舍:全单字母段的名字会退化(见 firstSlashCredit 注释)。钉住它,
		// 免得以后有人以为这是没想到的漏网,顺手"修"成一律不切、把 K/DA 又搭进去。
		{"M/A/R/R/S", "M/A", "已知退化:全单字母段,吃两段后长度达标"},

		// 2026-08-30 真实bug(方大同 & Fiona Sit《Four Tour》案,见
		// normalizeArtistCreditHanAnd 头注):中文"和"夹在两个拉丁字母段之间时当合唱
		// 连接词处理。
		{"Khalil Fong和Fiona Sit", "Khalil Fong", "中文'和'连接两个拉丁艺名,应能拆开"},
		{"A和B和C", "A", "连续多个'和'——逐 rune 判断,不会漏掉后半段"},
		// 两侧都不是拉丁字母、且中文段太短(<2字)时不当分隔符——纯中文名里恰好含"和"字
		// 不能被切碎。
		{"李和平", "李和平", "纯中文人名本身含'和',两侧中文段各只有1字,不该被切开"},
		{"和平", "和平", "'和'在开头,左侧没有字符,不该被当分隔符"},
		// 2026-08-31 真实bug(陶喆《再見你好嗎》专辑"那個女孩(feat. 盧廣仲)"案,见
		// normalizeArtistCreditHanAnd 头注):两侧都是中文、且各自≥2字时也当合唱连接词——
		// "陶喆和盧廣仲"之前恒取不出首歌手,七个源全部搜不到;单独查"陶喆"四个源立刻命中。
		{"陶喆和盧廣仲", "陶喆", "两侧都是≥2字的中文段,应能拆开"},
	}
	for _, c := range cases {
		if got := firstCreditedArtist(c.in); got != c.want {
			t.Errorf("firstCreditedArtist(%q) = %q, want %q (%s)", c.in, got, c.want, c.why)
		}
	}
}

func TestSlashHeadPlausible(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"K", false}, {"AC", false}, {"AJR", true}, {"VALORANT", true},
		{"陶喆", true}, {"周", false}, {"英雄联盟", true}, {"", false},
	}
	for _, c := range cases {
		if got := slashHeadPlausible(c.in); got != c.want {
			t.Errorf("slashHeadPlausible(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
