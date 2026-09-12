package main

import "testing"

// cjkSpaceStripped:CJK 姓名之间的空格。2026-09-12 的真实案例 —— 伊藤 美奈子
// 《雨のメヌエット》(专辑 TENDERLY)**九个源零候选**,把歌手名的空格去掉再搜,网易云
// 立刻给出完整候选(日文原词 + 中文译文 + 逐行罗马音,score 379)。判据与理由见其头注。
func TestCJKSpaceStripped(t *testing.T) {
	cases := []struct{ in, want, why string }{
		// ---- 正向:空白两侧都是 CJK,该去 ----
		{"伊藤 美奈子", "伊藤美奈子", "真实案例(汉字姓名 + 半角空格)"},
		{"伊藤　美奈子", "伊藤美奈子", "全角空格 —— 日文写法里更常见的那一种"},
		{"坂本 龍一", "坂本龍一", "繁体/日本新字体汉字"},
		{"宇多田 ヒカル", "宇多田ヒカル", "汉字 + 片假名"},
		{"방탄 소년단", "방탄소년단", "谚文(韩文同样没有词间空格的必要)"},
		{"伊藤  美奈子", "伊藤美奈子", "连续多个空白整段去掉"},

		// ---- 反向:必须返回空串(= 没有变体可言,别造无意义的重搜)----
		{"伊藤美奈子", "", "本来就没空格"},
		{"The Beatles", "", "⚠️ 拉丁名的词间空格是分词必需的,去掉就没人认了"},
		{"Sleeping With Sirens", "", "⚠️ 同上,多词拉丁乐队名"},
		{"Gary 曹格", "", "⚠️ 空白左侧是拉丁字母 —— 这个形态归 hanOnlyPortion 管"},
		{"UMI & 金泰亨", "", "合credit 连接词两侧不是 CJK,归 firstCreditedArtist 管"},
		{" 伊藤美奈子 ", "", "⚠️ 首尾空白不算 CJK↔CJK,那是 TrimSpace 的活"},
		{"", "", "空串"},
		{"   ", "", "全是空白"},
	}
	for _, c := range cases {
		if got := cjkSpaceStripped(c.in); got != c.want {
			t.Errorf("cjkSpaceStripped(%q) = %q, want %q — %s", c.in, got, c.want, c.why)
		}
	}
}

// lyricPrimaryQueryArtist 的集成:CJK 去空格是"合credit 拆不出变体"时的退路,
// 且不能改变任何既有形态的结论。
func TestLyricPrimaryQueryArtistCJKSpace(t *testing.T) {
	cases := []struct{ artist, want, why string }{
		{"伊藤 美奈子", "伊藤美奈子", "单人 + CJK 空格 → 走新增的退路"},
		{"伊藤 美奈子 & 某某", "伊藤美奈子", "合credit 切出首歌手后,顺带也去掉它的空格"},

		// ---- 以下全是既有行为,一个都不许变 ----
		{"UMI & 金泰亨", "UMI", "⚠️ 既有:没有 CJK 空格时一字不动"},
		{"陶喆、卢广仲", "陶喆", "⚠️ 既有:顿号合credit"},
		{"The Beatles", "", "⚠️ 既有:拉丁单人/乐队名没有变体"},
		{"Gary 曹格", "", "⚠️ 既有:英文名+中文名拼接仍然交给 hanOnlyPortion"},
	}
	for _, c := range cases {
		if got := lyricPrimaryQueryArtist(c.artist); got != c.want {
			t.Errorf("lyricPrimaryQueryArtist(%q) = %q, want %q — %s", c.artist, got, c.want, c.why)
		}
	}
}

// isCJKScriptRune 是 containsCJKScript 的单字符版,两者必须同一份判据
// (2026-09-12 抽取,applecatalog.go 那边改成复用它)。
func TestIsCJKScriptRuneMatchesContains(t *testing.T) {
	in := []rune{'汉', 'ひ', 'カ', '한'}
	for _, r := range in {
		if !isCJKScriptRune(r) {
			t.Errorf("isCJKScriptRune(%q) = false, want true", r)
		}
		if !containsCJKScript(string(r)) {
			t.Errorf("containsCJKScript(%q) = false, want true", r)
		}
	}
	out := []rune{'a', 'Z', '1', ' ', '&', '-', '（'}
	for _, r := range out {
		if isCJKScriptRune(r) {
			t.Errorf("isCJKScriptRune(%q) = true, want false", r)
		}
		if containsCJKScript(string(r)) {
			t.Errorf("containsCJKScript(%q) = true, want false", r)
		}
	}
}
