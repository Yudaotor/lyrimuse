package main

import "strings"

// titleMaskApostrophes:弯引号当撇号用(「****in’」对「fuckin'」)。
var titleMaskApostrophes = strings.NewReplacer("\u2019", "'", "\u2018", "'")

// titleMaskCompatible:local 歌名里有星号(播放器、平台把脏话打了码:「****」「他*的」「b***h」),other 跟它逐字对得上 ——
// 字数一样,每个位置要么相同(不分大小写,撇号的几种写法算同一个)、要么有一边是星号。other 也打着码的照样算。
// local 没有星号返回 false。见 09 章决策 325。
func titleMaskCompatible(local, other string) bool {
	if !strings.Contains(local, "*") {
		return false
	}
	a := []rune(strings.ToLower(titleMaskApostrophes.Replace(foldQuoteLookalikes(cleanMediaTag(local)))))
	b := []rune(strings.ToLower(titleMaskApostrophes.Replace(foldQuoteLookalikes(cleanMediaTag(other)))))
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] && a[i] != '*' && b[i] != '*' {
			return false
		}
	}
	return true
}

// titleCacheKeyPart:歌名在按 normLoose 拼的缓存键里的那一段。整个打了码的歌名(「****」)normLoose 之后是空串,同一张专辑
// 两首这样的歌会落到同一个键,改用原样小写。
func titleCacheKeyPart(title string) string {
	if k := normLoose(title); k != "" || !strings.Contains(title, "*") {
		return k
	}
	return strings.ToLower(cleanMediaTag(title))
}
