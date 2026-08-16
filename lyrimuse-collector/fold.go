package main

import (
	"strings"
	"unicode"
)

// foldDiacritics 把拉丁字母上的变音符号折掉:Beyoncé → Beyonce、Sigur Rós → Sigur Ros。
//
// 为什么需要:歌词源的曲库对同一个艺人/曲名的写法并不统一(播放器标签带变音、某个源的
// 库里是无变音的 ASCII 写法,或反过来),normLoose 只做小写化+去标点,'é' 和 'e' 在它眼里
// 仍是两个字符,于是匹配直接判负、召回丢失。这跟这个项目已经实锤过的繁简同一形状的问题
// (toSimplified 下沉进 normLoose 之前,繁体艺人名四个源全查不到候选),修法也照它:在
// normLoose 里下沉一次,全部源的匹配同时受益。
//
// ⚠️ 手写映射表而不是引 golang.org/x/text/unicode/norm:这个 collector 是**零依赖**的,
// 而且是有意为之 —— 当初正是因为 gocc 间接依赖 GPL-2.0-only 的 cedar-go 跟本项目
// GPL-3.0 不兼容才把它换成自带词典的实现(见 t2s.go)。为一个字符折叠拉回一整棵
// x/text 依赖树不划算。
//
// 覆盖范围:西欧/北欧/中东欧拉丁字母的常见变音形式,以及 ß/ø/æ/đ 这类**不是**"字母+
// 组合符号"、无法靠分解处理的独立字母。中日韩不受影响(不在表里,原样返回)。
var diacriticFolds = map[rune]string{
	'á': "a", 'à': "a", 'â': "a", 'ä': "a", 'ã': "a", 'å': "a", 'ā': "a", 'ă': "a", 'ą': "a",
	'é': "e", 'è': "e", 'ê': "e", 'ë': "e", 'ē': "e", 'ĕ': "e", 'ė': "e", 'ę': "e", 'ě': "e",
	'í': "i", 'ì': "i", 'î': "i", 'ï': "i", 'ī': "i", 'į': "i", 'ı': "i",
	'ó': "o", 'ò': "o", 'ô': "o", 'ö': "o", 'õ': "o", 'ō': "o", 'ő': "o",
	'ú': "u", 'ù': "u", 'û': "u", 'ü': "u", 'ū': "u", 'ů': "u", 'ű': "u", 'ų': "u",
	'ý': "y", 'ÿ': "y",
	'ñ': "n", 'ń': "n", 'ň': "n", 'ņ': "n",
	'ç': "c", 'ć': "c", 'č': "c", 'ĉ': "c",
	'š': "s", 'ś': "s", 'ş': "s", 'ș': "s",
	'ž': "z", 'ź': "z", 'ż': "z",
	'ł': "l", 'ľ': "l", 'ĺ': "l",
	'ř': "r", 'ŕ': "r",
	'ť': "t", 'ţ': "t", 'ț': "t",
	'ď': "d", 'đ': "d",
	'ğ': "g", 'ģ': "g",
	'ķ': "k", 'ĥ': "h", 'ĵ': "j", 'ŵ': "w",
	// 独立字母/合字:不是"基字母 + 组合符号",Unicode 分解也拆不开,只能显式列。
	'ø': "o", 'œ': "oe", 'æ': "ae", 'ß': "ss", 'þ': "th", 'ð': "d",
}

// 大写形式由小写表自动派生,不手写第二份 —— 手写必漏(2026-08-16 第一版就漏了整组大写,
// 断言当场逮住"Æther" 没被折成 "Aether")。unicode.ToLower 对表里每个字符都是安全的:
// 它们全是有大小写形态的拉丁字母。
var diacriticFoldsUpper = func() map[rune]string {
	m := make(map[rune]string, len(diacriticFolds))
	for r, folded := range diacriticFolds {
		upper := unicode.ToUpper(r)
		if upper == r {
			continue // 没有大写形态(比如 ß 的大写在实践中仍写作 ss)
		}
		// 折叠结果也跟着变大写:Æ → AE 而不是 ae,保持原文的大小写观感。
		m[upper] = strings.ToUpper(folded)
	}
	return m
}()

func foldRune(r rune) (string, bool) {
	if folded, ok := diacriticFolds[r]; ok {
		return folded, true
	}
	folded, ok := diacriticFoldsUpper[r]
	return folded, ok
}

// foldDiacritics 折叠字符串里的全部变音字符。表里没有的原样保留(中日韩、数字、符号)。
func foldDiacritics(s string) string {
	// 绝大多数字符串一个变音字符都没有,先扫一遍避免无谓的 Builder 分配。
	hasAny := false
	for _, r := range s {
		if _, ok := foldRune(r); ok {
			hasAny = true
			break
		}
	}
	if !hasAny {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if folded, ok := foldRune(r); ok {
			b.WriteString(folded)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}
