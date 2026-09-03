package main

import "testing"

// 2026-09-03 真实bug:周杰伦《妳聽得到》在「搜索候选歌词」里只出 1 个候选(LRCLIB),
// 网易云/QQ/酷狗一条都没有 —— 转换后的搜索词是「妳听得到」而它们曲库里叫「你听得到」。
// 单字隔离实测(见 hanvariants.go 头注的 A/B 表)坐实了病根就是「妳」这一个字。
func TestHanVariantsFoldsSearchTerms(t *testing.T) {
	cases := []struct{ in, want string }{
		// 这一条就是那个真实bug:繁体 + 异体字混在一起,两层都要生效
		{"妳聽得到", "你听得到"},
		// 异体字在纯简体语境里同样要折(艺人/专辑已经是简体时也不能漏)
		{"妳听得到", "你听得到"},
		{"祂的孩子", "他的孩子"},
		{"牠的名字", "它的名字"},
		{"細雨濛濛", "细雨蒙蒙"},
		// 不该动的:本身就是大陆通用字的一律原样
		{"你听得到", "你听得到"},
		{"周杰伦", "周杰伦"},
		// 非汉字原样穿过
		{"Hello 妳好", "Hello 你好"},
	}
	for _, c := range cases {
		if got := toSimplified(c.in); got != c.want {
			t.Errorf("toSimplified(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 表本身的不变量。⚠️ 这些断言守的是"生成器别产出会互相打架的条目",不是抽查几个字:
// 表是 scripts/gen-han-variants.py 从 Unihan + OpenCC 推出来的,改了推导规则要能在这里露馅。
func TestHanVariantsTableInvariants(t *testing.T) {
	if len(hanVariantMap) < 100 {
		t.Fatalf("异体字表只有 %d 条,像是 embed 没读到(产物在 dictionary/HanVariants.txt)", len(hanVariantMap))
	}
	for src, dst := range hanVariantMap {
		if src == dst {
			t.Errorf("%c → 自己,这条没有意义", src)
		}
		// 不许成链(A→B 且 B→C):逐字替换只跑一遍,成链就意味着结果取决于遍历顺序。
		if next, ok := hanVariantMap[dst]; ok {
			t.Errorf("%c → %c → %c 成链了,逐字替换只跑一遍,结果会不确定", src, dst, next)
		}
		// 目标字必须是 OpenCC 眼里已经无需再转的形态(否则这一层的产物还要再过一遍繁简)
		if again := toSimplified(string(dst)); again != string(dst) {
			t.Errorf("%c → %c,但 %c 自己还会被繁简转换改成 %s", src, dst, dst, again)
		}
	}
}

// 幂等:折过一遍的结果再折不该再变(前一条的"不成链"是它的结构性保证,这条是行为验证)。
func TestHanVariantsIdempotent(t *testing.T) {
	for _, s := range []string{"妳聽得到", "祂與牠", "細雨濛濛", "痲痺"} {
		once := toSimplified(s)
		if twice := toSimplified(once); twice != once {
			t.Errorf("toSimplified 不幂等:%q → %q → %q", s, once, twice)
		}
	}
}
