package main

import "testing"

// 2026-08-17 用户报:「联网搜索候选歌词」用播放器给的完整歌手串
// "K/DA/Madison Beer/(G)I-DLE/Jaira Burns" 只搜到两条候选,把歌手手工截短成 "K/DA"
// 之后变三条(还多出一条带逐字时间轴、分数最高的 Musixmatch)。
//
// 根因:`/` 既在 isArtistCreditSep 里、又是 K/DA 这个名字自身的一部分,于是
// artistCreditParts 切出来的段里永远没有 "k/da",artistMatches 把真正的歌手判成不匹配。
// 修法是给 artistMatches 补一档"连续若干段拼回去也算"(artistCreditRunMatches)。
//
// 这一组用例的重点一半在"该放过的放过了",另一半在**不该放过的仍然拒掉** —— 新规则最大
// 的风险就是退化成任意子串匹配。
func TestArtistMatchesNameContainingSeparator(t *testing.T) {
	const long = "K/DA/Madison Beer/(G)I-DLE/Jaira Burns"
	const comma = "K/DA,Madison Beer,(G)I-DLE,Jaira Burns" // LRCLIB 实际返回的写法
	const amp = "K/DA & Madison Beer & (G)I-DLE & Jaira Burns"

	cases := []struct {
		a, b string
		want bool
		why  string
	}{
		// 本次修的正题:名字自身带分隔符,出现在合credit 串的开头。
		{"K/DA", long, true, "K/DA 是 long 开头一个 / 界定的片段"},
		{long, "K/DA", true, "反向也要成立(参数顺序无关)"},
		{"K/DA", comma, true, "逗号写法同样要认"},
		{"K/DA", amp, true, "& 写法同样要认"},

		// 修之前就成立的,不能被改坏。
		{"Madison Beer", long, true, "整段相等"},
		{"(G)I-DLE", long, true, "整段相等(带括号)"},
		{"K/DA", "K/DA", true, "完全相同"},
		{"Prince", "Prince & The Revolution", true, "整段相等"},
		{"The Revolution", "Prince & The Revolution", true, "整段相等(多词)"},
		{"陶喆", "陶喆、卢广仲", true, "顿号分隔"},

		// ⚠️ 新规则最容易踩的坑:不能退化成任意子串。
		{"an", "anna", false, "子串但不是分隔符界定的片段"},
		{"da", "dave/eve", false, "首段的前缀不算(段是 dave)"},
		{"beer", long, false, "段中间的一个词不算(段是 madison beer)"},
		{"The", "Prince & The Revolution", false, "段里的一个词不算,空白不是边界"},
		{"Madison", long, false, "同上,别把半个名字放过去"},

		// ⚠️ 故意保留的仿冒防线:结尾带分隔符的单人名切完只剩一段,
		// len(parts)<2 的守卫必须挡住它(见 artistCreditParts 注释)。
		{"周杰伦", "周杰伦、", false, "仿冒特征:尾随分隔符,不能判成同一个人"},

		// 无关的两个人。
		{"K/DA", "IU/Suga", false, "毫无关系"},
		{"", long, false, "空串"},
		{"K/DA", "", false, "空串(反向)"},
	}

	for _, c := range cases {
		if got := artistMatches(c.a, c.b); got != c.want {
			t.Errorf("artistMatches(%q, %q) = %v, want %v —— %s", c.a, c.b, got, c.want, c.why)
		}
	}
}

// artistCreditRunMatches 自己的边界判定。注意它要求调用方**已经归一化**(小写),
// 所以这里直接传小写串。
func TestArtistCreditRunMatches(t *testing.T) {
	cases := []struct {
		hay, needle string
		want        bool
	}{
		{"k/da/madison beer", "k/da", true},          // 开头
		{"madison beer/k/da", "k/da", true},          // 结尾
		{"a/k/da/b", "k/da", true},                   // 中间
		{"k/da & madison beer", "k/da", true},        // 分隔符两侧带空格
		{"prince & the revolution", "the", false},    // 空白不是边界
		{"anna", "an", false},                        // 纯子串
		{"dave/eve", "da", false},                    // 段的前缀
		{"k/da", "k/da", true},                       // 整串
		{"k/da", "k/da/x", false},                    // needle 比 hay 长
		{"", "k", false},
		{"k", "", false},
	}
	for _, c := range cases {
		if got := artistCreditRunMatches(c.hay, c.needle); got != c.want {
			t.Errorf("artistCreditRunMatches(%q, %q) = %v, want %v", c.hay, c.needle, got, c.want)
		}
	}
}
