package main

import "strings"

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

func dashTailSplit(name string) (head, tail string, ok bool) {
	i := strings.LastIndex(name, " - ")
	if i <= 0 {
		return "", "", false
	}
	head, tail = strings.TrimSpace(name[:i]), strings.TrimSpace(name[i+len(" - "):])
	return head, tail, head != "" && tail != ""
}
