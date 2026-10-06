package main

import (
	"regexp"
	"strings"
)

// 歌名里「 - 尾段」的写法:汽水、QQ 的曲库(「X - Album Version」「X - Explicit Ver.」)和一部分本地标签
// (「X - 电视剧《Y》主题曲」「X - Bonus」)用它放限定词或宣传语,别的源多用括号。

// dashTailAsBracket 把最后一个「 - 」后面的尾段改成括号:「X - 尾段」→「X (尾段)」。共用的歌名闸按去括号那一档
// 认得出它,尾段留在括号里照样给版本闸判(两种位置版本闸本来就都认,见 titleQualifierSegments)。只改最后一个「 - 」,
// 前后有一边是空的就原样返回(去掉首尾空白)。
func dashTailAsBracket(name string) string {
	name = strings.TrimSpace(name)
	head, tail, ok := dashTailSplit(name)
	if !ok {
		return name
	}
	return head + " (" + tail + ")"
}

// dashTailHead 是最后一个「 - 」前面那段;没有尾段返回空串。
func dashTailHead(name string) string {
	head, _, ok := dashTailSplit(strings.TrimSpace(name))
	if !ok {
		return ""
	}
	return head
}

// promoTitleTailRe:宣传尾段的标志词 ——「主題曲」「插曲」「片尾曲」「宣傳曲」这一族。
var promoTitleTailRe = regexp.MustCompile(`(?:主題|主题|插|片尾|片頭|片头|宣傳|宣传|推廣|推广|印象|概念|廣告|广告|代言|應援|应援|形象|單元|单元)曲`)

// withoutPromoTitleTail 去掉最后一个「 - 」后面的宣传尾段(「X - 電影《Y》主題曲」→「X」),只认带
// promoTitleTailRe 标志词、不止标志词本身、也没有版本词(titleVersionTags)的尾段,别的原样返回。见 09 章决策 189。
func withoutPromoTitleTail(name string) string {
	head, tail, ok := dashTailSplit(strings.TrimSpace(name))
	if !ok || !promoTitleTailRe.MatchString(tail) || promoTitleTailRe.ReplaceAllString(tail, "") == "" ||
		len(titleVersionTags("("+tail+")")) > 0 {
		return name
	}
	return head
}

func dashTailSplit(name string) (head, tail string, ok bool) {
	i := strings.LastIndex(name, " - ")
	if i <= 0 {
		return "", "", false
	}
	head, tail = strings.TrimSpace(name[:i]), strings.TrimSpace(name[i+len(" - "):])
	return head, tail, head != "" && tail != ""
}
