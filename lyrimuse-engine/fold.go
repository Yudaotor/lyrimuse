package main

import (
	"strings"
	"unicode"
)

// foldDiacritics 把拉丁字母上的变音符号折掉:Beyoncé → Beyonce、Sigur Rós → Sigur Ros。
//
// 为什么需要:歌词源的曲库对同一个艺人/曲名的写法并不统一(播放器标签带变音、某个源的
// 库里是无变音的 ASCII 写法,或反过来),normLoose 只做小写化+去标点,'é' 和 'e' 在它眼里
// 仍是两个字符,于是匹配直接判负、召回丢失。这跟这个项目已经坐实的繁简同一形状的问题
// (toSimplified 下沉进 normLoose 之前,繁体艺人名四个源全查不到候选),修法也照它:在
// normLoose 里下沉一次,全部源的匹配同时受益。
//
// 手写映射表而不是引 golang.org/x/text/unicode/norm:这个引擎是**零依赖**的,
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
	// 汉语拼音的第三声与 ü 系列(第一、二、四声大多已在上面):「Zhōu」折了、「Zhǒu」不折的话,
	// 同一个拼音名两种标调写法在匹配里就是两个人。
	'ǎ': "a", 'ǐ': "i", 'ǒ': "o", 'ǔ': "u", 'ǖ': "u", 'ǘ': "u", 'ǚ': "u", 'ǜ': "u",
	// 越南语:带声调的元音与 ơ / ư。
	'ạ': "a", 'ả': "a", 'ấ': "a", 'ầ': "a", 'ẩ': "a", 'ẫ': "a", 'ậ': "a", 'ắ': "a", 'ằ': "a", 'ẳ': "a", 'ẵ': "a", 'ặ': "a",
	'ẹ': "e", 'ẻ': "e", 'ẽ': "e", 'ế': "e", 'ề': "e", 'ể': "e", 'ễ': "e", 'ệ': "e",
	'ỉ': "i", 'ĩ': "i", 'ị': "i",
	'ọ': "o", 'ỏ': "o", 'ố': "o", 'ồ': "o", 'ổ': "o", 'ỗ': "o", 'ộ': "o",
	'ơ': "o", 'ớ': "o", 'ờ': "o", 'ở': "o", 'ỡ': "o", 'ợ': "o",
	'ụ': "u", 'ủ': "u", 'ũ': "u", 'ư': "u", 'ứ': "u", 'ừ': "u", 'ử': "u", 'ữ': "u", 'ự': "u",
	'ỳ': "y", 'ỵ': "y", 'ỷ': "y", 'ỹ': "y",
}

// 大写形式由小写表自动派生,不手写第二份 —— 手写必漏(就漏了整组大写,
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

// foldFullwidthAlnum 把全角的拉丁字母、数字换成半角,全角空格换成普通空格:「ＬＯＶＥ １２」→「LOVE 12」。日文标签常这么写,
// 各源曲库存的多是半角,不折的话标题、歌手逐字符比都对不上(normLoose 只转小写,全角转小写还是全角)。
// 全角标点不动:比对时 normLoose 本来就丢标点,查询词里国内几家平台的曲名又常带全角括号,换掉反而对不上。
func foldFullwidthAlnum(s string) string {
	if !strings.ContainsFunc(s, isFullwidthAlnumOrSpace) {
		return s
	}
	return strings.Map(func(r rune) rune {
		switch {
		case r == '\u3000':
			return ' '
		case isFullwidthAlnumOrSpace(r):
			return r - 0xFEE0
		}
		return r
	}, s)
}

func isFullwidthAlnumOrSpace(r rune) bool {
	return r == '\u3000' || (r >= '０' && r <= '９') || (r >= 'Ａ' && r <= 'Ｚ') || (r >= 'ａ' && r <= 'ｚ')
}

const (
	devanagariChandrabindu = rune(0x0901)
	devanagariAnusvara     = rune(0x0902)
	devanagariNukta        = rune(0x093C)
)

// looseMark:比对用的归一化里组合符号 r 留不留、留成什么。婆罗米系文字(天城文、孟加拉文、泰米尔文、泰卢固文……)
// 和泰文的元音符号、virama、声调符号是拼写的一部分,去掉就成了另一个词(दिल 与 दल 只差一个元音符号),
// 跟字母一样留下。折掉的是写不写两可的那类:通用组合附加符号(文字属性 Inherited:拉丁、希腊、西里尔的变音,
// 假名浊点)、希伯来文与阿拉伯文的元音点、天城文 nukta;天城文 chandrabindu 折成 anusvara。见 09 章决策 384。
func looseMark(r rune) (rune, bool) {
	switch {
	case !unicode.Is(unicode.M, r), r == devanagariNukta, unicode.In(r, unicode.Inherited, unicode.Hebrew, unicode.Arabic):
		return 0, false
	case r == devanagariChandrabindu:
		return devanagariAnusvara, true
	}
	return r, true
}

// looseKeyRune:比对键里留下的字符 —— 字母、数字,加上 looseMark 留下的组合符号。
func looseKeyRune(r rune) (rune, bool) {
	if unicode.IsLetter(r) || unicode.IsDigit(r) {
		return r, true
	}
	return looseMark(r)
}
