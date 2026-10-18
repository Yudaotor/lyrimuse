package main

import "strings"

// containsCode:源码契约的宽松比对。源码和片段都把连续空白(空格、Tab、换行)压成一个空格,片段再去掉首尾空白,然后找。
// 缩进、断行变了不算违约;要判「单独一行」「行首」这类版式的别用它,还用 strings.Contains。片段压完是空的返回 false。
func containsCode(src, snippet string) bool {
	needle := collapseCodeSpace(snippet, true)
	if needle == "" {
		return false
	}
	return strings.Contains(collapseCodeSpace(src, false), needle)
}

// collapseCodeSpace 把连续的空格 / Tab / 换行压成一个空格;trim 时去掉首尾空白。
func collapseCodeSpace(s string, trim bool) string {
	var b strings.Builder
	b.Grow(len(s))
	pending := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			pending = true
			continue
		}
		if pending && !(trim && b.Len() == 0) {
			b.WriteByte(' ')
		}
		pending = false
		b.WriteByte(c)
	}
	if pending && !trim {
		b.WriteByte(' ')
	}
	return b.String()
}

// countCode:片段在源码里不重叠地出现几次,比对口径同 containsCode。片段压完是空的返回 0。
func countCode(src, snippet string) int {
	needle := collapseCodeSpace(snippet, true)
	if needle == "" {
		return 0
	}
	return strings.Count(collapseCodeSpace(src, false), needle)
}
