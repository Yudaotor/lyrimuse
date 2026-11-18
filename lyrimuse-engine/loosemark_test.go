package main

import (
	"slices"
	"testing"
)

// 婆罗米系文字和泰文的元音符号、virama、声调符号是拼写的一部分:只差这些符号的两个词在比对里不能折成同一个。
func TestNormLooseKeepsSpellingMarks(t *testing.T) {
	for _, p := range [][2]string{
		{"तेरी मेरी", "तेरे मेरे"}, // 天城文:元音符号 ी(Mc)对 े(Mn)
		{"दिल", "दल"},           // 天城文:ि(Mc)
		{"तुम ही हो", "तुम हो"}, // 天城文:去掉元音后「तमह」是「तमहह」的子串
		{"আমি", "আম"},           // 孟加拉文:ি(Mc)
		{"பால்", "பல்"},         // 泰米尔文:ா(Mc)
		{"பல", "பல்"},           // 泰米尔文:pulli(virama)
		{"ప్రేమ", "పరమ"},        // 泰卢固文
		{"ม้า", "มา"},           // 泰文:声调符号(Mn)
	} {
		if a, b := normLoose(p[0]), normLoose(p[1]); a == b {
			t.Errorf("normLoose(%q) = normLoose(%q) = %q, 两个词被折成了同一个", p[0], p[1], a)
		}
	}
	if got := normLoose("तुम ही हो"); got != "तुमहीहो" {
		t.Errorf("normLoose(तुम ही हो) = %q", got)
	}
	if looseContains("तुम ही हो", "तुम हो") {
		t.Error("looseContains(तुम ही हो, तुम हो) 为真")
	}
	if got := titleMatchTierPoints("तेरी मेरी", "तेरे मेरे"); got != 0 {
		t.Errorf("titleMatchTierPoints(तेरी मेरी, तेरे मेरे) = %d, want 0", got)
	}
	if got := titleMatchTierPoints("तेरी मेरी", "तेरी मेरी"); got != 120 {
		t.Errorf("titleMatchTierPoints(तेरी मेरी, तेरी मेरी) = %d, want 120", got)
	}
}

// 写不写两可的附加符号照旧折掉:拉丁 / 西里尔变音(含分解写法)、假名浊点、希伯来文与阿拉伯文元音点、天城文 nukta;
// chandrabindu 与 anusvara 当同一个。
func TestNormLooseFoldsOptionalMarks(t *testing.T) {
	for _, p := range [][2]string{
		{"Beyonce\u0301", "Beyonce"},
		{"Beyoncé", "Beyonce"},
		{"Spin\u0308al Tap", "Spinal Tap"},
		{"приве\u0301т", "привет"},
		{"か\u3099", "が"},
		{"שָׁלוֹם", "שלום"},
		{"حَبِيبِي", "حبيبي"},
		{"الله\u0610", "الله"}, // U+0610 的文字属性是 Arabic,不是 Inherited
		{"ज़िंदगी", "जिंदगी"},
		{"हूँ", "हूं"},
	} {
		if a, b := normLoose(p[0]), normLoose(p[1]); a != b {
			t.Errorf("normLoose(%q) = %q, normLoose(%q) = %q, 应当相同", p[0], a, p[1], b)
		}
	}
}

// 只留字母数字的几个比对键跟 normLoose 同一个口径。
func TestLooseKeysKeepSpellingMarks(t *testing.T) {
	keys := map[string]func(string) string{
		"normTimelineText": normTimelineText,
		"deezerTextKey":    deezerTextKey,
		"parenBGNormKey":   parenBGNormKey,
		"headerNorm":       headerNorm,
		"versionLabelParts": func(s string) string {
			v, _ := versionLabelParts(s)
			return v
		},
	}
	for name, key := range keys {
		if a, b := key("तेरी मेरी"), key("तेरे मेरे"); a == b {
			t.Errorf("%s 把 तेरी मेरी 与 तेरे मेरे 折成同一个 %q", name, a)
		}
		if a, b := key("Spin\u0308al"), key("Spinal"); a != b {
			t.Errorf("%s(Spin+U+0308+al) = %q, %s(Spinal) = %q", name, a, name, b)
		}
	}
}

// 组合符号跟着前一个字,不在词中间断开。
func TestTokenizersKeepSpellingMarksInWord(t *testing.T) {
	if got := sortedKeys(albumTokens("दिल से")); !slices.Equal(got, []string{"दिल", "से"}) {
		t.Errorf("albumTokens(दिल से) = %q", got)
	}
	if got := sortedKeys(albumTokens("Spin\u0308al Tap")); !slices.Equal(got, []string{"spinal", "tap"}) {
		t.Errorf("albumTokens(Spin+U+0308+al Tap) = %q", got)
	}
	if got := albumScore("आशिकी 2", "आशक"); got != 0 {
		t.Errorf("albumScore(आशिकी 2, आशक) = %d, want 0", got)
	}
	if got := versionTagTokens("দিল সে"); !slices.Equal(got, []string{"দিল", "সে"}) {
		t.Errorf("versionTagTokens(দিল সে) = %q", got)
	}
	if got := versionTagTokens("Spin\u0308al"); !slices.Equal(got, []string{"spinal"}) {
		t.Errorf("versionTagTokens(Spin+U+0308+al) = %q", got)
	}
}

// 正文词数:元音符号(含 Mc)不断词。
func TestContentWordCountSpacingMarks(t *testing.T) {
	for in, want := range map[string]int{
		"[00:01.00]আমার সোনার বাংলা":          3,
		"[00:01.00]நான் உன்னை காதலிக்கிறேன்":  3,
		"[00:01.00]तेरी मेरी कहानी":           3,
		"[00:01.00]tum hi ho, ab tum hi ho":   7,
		"[00:01.00]Je t'aime, mon cœur brisé": 5,
	} {
		if got := contentWordCount(in); got != want {
			t.Errorf("contentWordCount(%q) = %d, want %d", in, got, want)
		}
	}
}

// 重音空格判据里的「词」同样把间距组合符号算在词里。
func TestAccentSplitWordRuneSpacingMarks(t *testing.T) {
	if got := leadingLetters("কাছে café"); got != "কাছে" {
		t.Errorf("leadingLetters = %q", got)
	}
	if got := trailingLetters("x তুমি"); got != "তুমি" {
		t.Errorf("trailingLetters = %q", got)
	}
}
