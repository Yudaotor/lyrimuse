package main

import (
	"strings"
	"unicode"
)

// dropScriptVariantLines 去掉社区译文里「只是原文换了种写法」的行:跟同一时间戳的原文行在转成
// 简体、去掉标点空白、统一小写之后完全相同;或者两边都几乎全是汉字、只差很少几个字(见
// isNearHanVariant)。
//
// 典型来源是 Musixmatch:同一首中文歌在它那里同时有繁体、简体两个版本时,「中文译文」就是另一个
// 版本,挂在原文下面等于把原文再显示一遍。必须**逐行**判、不能整份判:中文歌带英文副歌时,译文里
// 中文行是照抄、英文行是真翻译,整份丢掉会把真翻译一起扔了。全部行都被去掉时返回空串。
//
// 对齐靠时间戳:buildTranslatedLRC 产出的译文行沿用原文行的时间戳。
func dropScriptVariantLines(originalLRC, translationLRC string) string {
	orig := map[string]string{}
	for _, l := range parseLRCLines(originalLRC) {
		if _, ok := orig[l.tag]; !ok {
			orig[l.tag] = scriptVariantKey(l.text)
		}
	}
	var b strings.Builder
	for _, l := range parseLRCLines(translationLRC) {
		if key, ok := orig[l.tag]; ok && key != "" {
			if tr := scriptVariantKey(l.text); tr == key || isNearHanVariant(key, tr) {
				continue
			}
		}
		b.WriteString(l.tag)
		b.WriteString(l.text)
		b.WriteByte('\n')
	}
	return b.String()
}

// isNearHanVariant 两个归一后的串是不是「同一句中文的两种写法」。完全相等之外还要这一档,因为:
// OpenCC 词库不单独转「著」这类繁简同形字(「逼著」转完还是「逼著」,译文写「逼着」),译者也会
// 手滑打错字(「正好」写成「真好」)。只在两边都至少 80% 是汉字时才判:英文原句配中文译文不会落进来,
// 真正的中文改写(粤语改国语)用词差得远,也落不进 20% 的编辑距离里。
func isNearHanVariant(a, b string) bool {
	ra, rb := []rune(a), []rune(b)
	if !mostlyHan(ra) || !mostlyHan(rb) {
		return false
	}
	longer := len(ra)
	if len(rb) > longer {
		longer = len(rb)
	}
	// 4 个字以下只认完全相等:短句里差一个字就可能是真翻译(粤语「我哋」对国语「我们」)。
	if longer < 4 {
		return false
	}
	allowed := longer / 5
	if allowed < 1 {
		allowed = 1
	}
	return runeEditDistance(ra, rb) <= allowed
}

func mostlyHan(rs []rune) bool {
	if len(rs) == 0 {
		return false
	}
	han := 0
	for _, r := range rs {
		if unicode.Is(unicode.Han, r) {
			han++
		}
	}
	return han*5 >= len(rs)*4
}

// scriptVariantKey 比较用的归一形式:繁转简 + 只留字母数字 + 小写。
func scriptVariantKey(s string) string {
	var b strings.Builder
	for _, r := range toSimplified(s) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}
