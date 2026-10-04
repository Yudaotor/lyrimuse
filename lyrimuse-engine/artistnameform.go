package main

import (
	"regexp"
	"strings"
	"unicode"
)

// 歌手比对前把同一个名字的几种写法对齐。只给 artistMatches / artistCreditParts 用;搜索词、缓存 key、normLoose
// 都不经过这里。见 09 章决策 177。

// foldIterationMark 把跟在汉字后面的「々」换成那个字:中文曲库把「水樹奈々」写成「水树奈奈」、「佐々木」写成
// 「佐佐木」。别的位置的「々」原样留着。
func foldIterationMark(s string) string {
	if !strings.ContainsRune(s, '々') {
		return s
	}
	rs := []rune(s)
	for i := 1; i < len(rs); i++ {
		if rs[i] == '々' && unicode.Is(unicode.Han, rs[i-1]) {
			rs[i] = rs[i-1]
		}
	}
	return string(rs)
}

// parenAliasPart:一段署名「X (Y)」或「X（Y）」,括号里没有再套括号。
var parenAliasPart = regexp.MustCompile(`^(.+?)\s*[(（]([^()（）]+)[)）]\s*$`)

// parenAliasNames:署名里每一段「X (Y)」换成括号里的 Y,其余段原样,用 / 连起来;一段都没换时返回空串。
// 中文曲库常把日文名写成「译名 (原名)」(「水濑祈 (水瀬いのり)」),角色歌也有不带 CV 标记的「角色 (声优)」,
// 括号里的名字拿来再比一次 —— 只当同一位演唱者的另一个名字,不当角色和声优的配对。CV 括号(parseCVCredit 管)
// 和 feat. / with 这类合作者标注不换。
func parenAliasNames(s string) string {
	if !strings.ContainsAny(s, "(（") {
		return ""
	}
	parts := strings.FieldsFunc(s, isArtistCreditSep)
	changed := false
	for i, p := range parts {
		m := parenAliasPart.FindStringSubmatch(strings.TrimSpace(p))
		if m == nil {
			continue
		}
		inner := strings.TrimSpace(m[2])
		if _, cv := trimCVMarker(inner); cv || isCollaboratorNote(inner) {
			continue
		}
		parts[i] = inner
		changed = true
	}
	if !changed {
		return ""
	}
	return strings.Join(parts, "/")
}

// isCollaboratorNote:括号里写的是合作者(「feat. 某某」「ft. 某某」「with 某某」),不是同一个人的另一个名字。
func isCollaboratorNote(s string) bool {
	l := strings.ToLower(s)
	for _, p := range []string{"feat.", "feat ", "ft.", "ft ", "with "} {
		if strings.HasPrefix(l, p) {
			return true
		}
	}
	return false
}
