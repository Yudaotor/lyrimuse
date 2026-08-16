package main

import (
	"testing"
	"unicode"
)

func TestFoldDiacritics(t *testing.T) {
	cases := map[string]string{
		"Beyoncé":     "Beyonce",
		"Rosalía":     "Rosalia",
		"Sigur Rós":   "Sigur Ros",
		"Mötley Crüe": "Motley Crue",
		"Björk":       "Bjork",
		"Céline Dion": "Celine Dion",
		"Antônio":     "Antonio",
		"Håkan":       "Hakan",
		"Renée":       "Renee",
		// 独立字母/合字：分解拆不开，靠显式映射
		"Straße": "Strasse",
		"Søren":  "Soren",
		// 不该动的：中日韩、ASCII、数字、符号
		"周杰伦":         "周杰伦",
		"宇多田ヒカル":      "宇多田ヒカル",
		"Taylor Swift": "Taylor Swift",
		"2Pac":         "2Pac",
		"AC/DC":        "AC/DC",
		"":             "",
		// 大写形式：第一版漏了整组大写，靠这几条守住
		"Æther":  "AEther",
		"ÅKERFELDT": "AKERFELDT",
		"ÑOÑO":   "NONO",
		"Ø":      "O",
	}
	for in, want := range cases {
		if got := foldDiacritics(in); got != want {
			t.Errorf("foldDiacritics(%q) = %q, want %q", in, got, want)
		}
	}
}

// 真正要的效果：带变音和不带变音的写法必须匹配得上 —— 这正是召回丢失的形态。
// 表的完整性：每个小写条目都必须有对应的大写覆盖，否则"Å"这类会静默漏网。
func TestFoldTableCoversUppercase(t *testing.T) {
	for r := range diacriticFolds {
		upper := unicode.ToUpper(r)
		if upper == r {
			continue
		}
		if _, ok := foldRune(upper); !ok {
			t.Errorf("大写 %q (来自 %q) 没有被覆盖", string(upper), string(r))
		}
	}
}

func TestNormLooseFoldsDiacritics(t *testing.T) {
	pairs := [][2]string{
		{"Beyoncé", "Beyonce"},
		{"Sigur Rós", "sigur ros"},
		{"Mötley Crüe", "Motley Crue"},
		{"Rosalía - MALAMENTE", "Rosalia MALAMENTE"},
	}
	for _, p := range pairs {
		if normLoose(p[0]) != normLoose(p[1]) {
			t.Errorf("normLoose(%q)=%q != normLoose(%q)=%q",
				p[0], normLoose(p[0]), p[1], normLoose(p[1]))
		}
	}
	// ⚠️ 反向保证：折叠不能把本来不同的名字揉成同一个。
	if normLoose("Sade") == normLoose("Suede") {
		t.Error("折叠过度：Sade 和 Suede 不该相等")
	}
	// 繁简处理必须仍然生效（折叠是加在它后面的，不能顶掉它）
	if normLoose("周杰倫") != normLoose("周杰伦") {
		t.Error("繁简归一被破坏了")
	}
}
