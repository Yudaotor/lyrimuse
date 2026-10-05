package main

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 歌词抬头行(「曲名 - 歌手」/「歌手 - 曲名」)的判据,逐条镜像 Swift 侧
// LyricsSyncEngine.looksLikeHeaderLine 及其辅助函数(headerSplitCandidates / headerTitleForms /
// headerMatchVariants / scriptRuns / longEnoughForHeaderMatch)。两边各维护一份,改一边必须同步改另一边。
// 繁简孪生:Swift 用 HanScript.sibling 给歌名、歌手各生成另一种写法;这里两侧都过 toSimplified 再比,
// 效果相同。翻译选行另有一档更宽的判据(looksLikeTranslationHeaderLine),不在镜像范围内。
//
// 两条取舍跟着一起镜像,少一条就会开始吞真歌词:
//  1. 只在第一条正文行认。调用方负责只对第一行问。
//  2. 歌名侧是"去括号后等值",不是"出现在行内";歌手侧才用 contains,而且用原文不去括号 ——
//     抬头里歌手名常写在括号里(「First Love - 宇多田光 (宇多田ヒカル)」)。

// looksLikeLyricHeaderLine:这一行是不是抬头。歌名或歌手为空时一律不认。
func looksLikeLyricHeaderLine(text, title, artist string) bool {
	if title == "" || artist == "" {
		return false
	}
	titles := headerKeySet(headerTitleForms(title))
	artists := headerKeyList(headerMatchVariants(artist))
	// 「翻唱者 - 原唱《歌名》」:书名号里等于歌名、书名号外含歌手。
	if open := strings.Index(text, "《"); open >= 0 {
		if n := strings.Index(text[open:], "》"); n > 0 {
			inside := headerKey(text[open+len("《") : open+n])
			outside := headerKey(text[:open] + text[open+n+len("》"):])
			if titles[inside] && headerContainsAny(outside, artists) {
				return true
			}
		}
	}
	// 括号里的、按字形切出的写法(headerExtraTitleForms)只跟完整歌名比,不跟歌名按字形切出的段比:
	// 两边都切段再比,共有一段(「再会吧」)就算,太松。
	fullTitles := headerKeySet([]string{title, stripHeaderBrackets(title)})
	for _, sp := range headerSplitCandidates(text) {
		leftRaw, rightRaw := headerKey(sp[0]), headerKey(sp[1])
		if leftRaw == "" || rightRaw == "" {
			continue
		}
		// 歌名侧去括号、不去括号各比一次:抬头写裸歌名时本地标签常带「(Remastered)」,反过来抬头也会把
		// 歌名的一部分写进括号(「达尔文 II (进化版)」配「达尔文 II 进化版」)。
		leftTitle := titles[headerKey(stripHeaderBrackets(sp[0]))] || titles[leftRaw] ||
			headerAnyIn(headerExtraTitleForms(sp[0]), fullTitles)
		rightTitle := titles[headerKey(stripHeaderBrackets(sp[1]))] || titles[rightRaw] ||
			headerAnyIn(headerExtraTitleForms(sp[1]), fullTitles)
		if leftTitle && headerContainsAny(rightRaw, artists) {
			return true
		}
		if rightTitle && headerContainsAny(leftRaw, artists) {
			return true
		}
	}
	return false
}

// lyricHeaderTagRe 歌词文件头部的 [ti:] / [ar:]。同 Swift 侧 LRCParser.headerTagRegex。
var lyricHeaderTagRe = regexp.MustCompile(`(?im)^\s*\[(ti|ar)\s*:([^\]\r\n]*)\]`)

// lyricHeaderTags 歌词自己写的歌名、歌手([ti:] / [ar:],各取第一个非空的)。抬头行用的是这一套写法,跟播放器报的
// 常不是同一种语种或写法。同 Swift 侧 LRCParser.headerTags。
func lyricHeaderTags(lrc string) (title, artist string) {
	for _, m := range lyricHeaderTagRe.FindAllStringSubmatch(lrc, -1) {
		value := strings.TrimSpace(m[2])
		if value == "" {
			continue
		}
		if strings.EqualFold(m[1], "ti") {
			if title == "" {
				title = value
			}
		} else if artist == "" {
			artist = value
		}
	}
	return title, artist
}

// looksLikeLyricHeaderLineTagged:播放器报的和歌词标签里的歌名、歌手两两搭配,任一搭配成立就是抬头;判据本身
// 不放宽。同 Swift 侧 LyricsSyncEngine.looksLikeHeaderLine(_:trackTitle:trackArtist:tags:)。
func looksLikeLyricHeaderLineTagged(text, title, artist, tagTitle, tagArtist string) bool {
	for _, t := range []string{title, tagTitle} {
		for _, a := range []string{artist, tagArtist} {
			if t != "" && a != "" && looksLikeLyricHeaderLine(text, t, a) {
				return true
			}
		}
	}
	return false
}

// headerSplitCandidates 把一行切成抬头的两段:先认带空格的 " - " / " – " / " — " / " － " 和「——」,只有一处时直接用
// (「W-H-Y - 王力宏」这种歌名自带连字符的也能切开);都没有时退回"整行只有一个裸连字符"
// (「陳柏宇-最後的擁抱」)。切不开返回 nil。
func headerSplitCandidates(text string) [][2]string {
	for _, sep := range []string{" - ", " – ", " — ", " － ", "——"} {
		parts := strings.Split(text, sep)
		if len(parts) == 2 {
			return [][2]string{{parts[0], parts[1]}}
		}
		// 歌名自己带分隔符(「月を見ていた - Moongazing - 米津玄師」):每个分隔处都切一次。
		if len(parts) > 2 {
			var out [][2]string
			for k := 1; k < len(parts); k++ {
				out = append(out, [2]string{strings.Join(parts[:k], sep), strings.Join(parts[k:], sep)})
			}
			return out
		}
	}
	idx, n := -1, 0
	for i, r := range text {
		if r == '-' || r == '–' || r == '—' || r == '－' {
			if idx < 0 {
				idx = i
			}
			n++
		}
	}
	if n != 1 {
		return nil
	}
	_, size := utf8.DecodeRuneInString(text[idx:])
	return [][2]string{{text[:idx], text[idx+size:]}}
}

// headerExtraTitleForms 一段里还能再拆出来的歌名写法:括号里的(「가위바위보 (Rock Paper Scissors)」)、
// 按字形切开的(「日出君 Sunrise again」)。返回比对用的 key。
func headerExtraTitleForms(side string) []string {
	forms := headerScriptRuns(stripHeaderBrackets(side))
	depth := 0
	var inner strings.Builder
	for _, r := range side {
		switch r {
		case '(', '[', '（', '［':
			depth++
			if depth == 1 {
				inner.Reset()
			}
		case ')', ']', '）', '］':
			if depth == 1 {
				forms = append(forms, inner.String())
			}
			if depth > 0 {
				depth--
			}
		default:
			if depth > 0 {
				inner.WriteRune(r)
			}
		}
	}
	return headerKeyList(forms)
}

func headerAnyIn(keys []string, set map[string]bool) bool {
	for _, k := range keys {
		if set[k] {
			return true
		}
	}
	return false
}

// headerTitleForms 歌名可以长成的样子:原样、去括号、去掉「 - 版本」尾巴(Apple Music 的
// 「Love Outrolude - Instrumental」,抬头只写「Love Outrolude」)、按字形切出的段(双语歌名
// 「日出 The Dawn」靠它拆开)。不设长度下限:这一侧是等值判定,一两个字的歌名(「追」「GF」)不会误杀。
func headerTitleForms(s string) []string {
	stripped := stripHeaderBrackets(s)
	out := []string{s, stripped}
	if parts := strings.Split(stripped, " - "); len(parts) == 2 {
		out = append(out, parts[0])
	}
	out = append(out, headerScriptRuns(stripped)...)
	return headerDedupTrim(out, false)
}

// headerMatchVariants 把歌手标签拆成可以单独比对的若干段:整串、去括号、按分隔符拆出的每一段
// (feat. 当分隔符)、按字形切出的每一段。拆出来的段按长度下限筛:汉字段 ≥2 字,拉丁段 ≥4 个字母数字 ——
// 拉丁段放宽会把 "The"/"You" 这类词当成歌手段,英文歌词里几乎必然出现。整串标签本身不受这道下限,
// 只要有 2 个字母数字(「Jam」「SZA」「BY2」)。
func headerMatchVariants(s string) []string {
	var whole []string
	for _, base := range []string{s, stripHeaderBrackets(s)} {
		if len([]rune(headerNorm(base))) >= 2 {
			whole = append(whole, base)
		}
	}
	var pieces []string
	for _, base := range []string{s, stripHeaderBrackets(s)} {
		if base == "" {
			continue
		}
		pieces = append(pieces, base)
		flattened := replaceFoldASCII(base, "feat.", "/")
		pieces = append(pieces, strings.FieldsFunc(flattened, func(r rune) bool {
			return strings.ContainsRune("&/、,，;；|-–—", r)
		})...)
		pieces = append(pieces, headerScriptRuns(base)...)
	}
	return headerDedupTrim(append(headerDedupTrim(whole, false), headerDedupTrim(pieces, true)...), false)
}

func headerDedupTrim(in []string, needLength bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, raw := range in {
		p := strings.TrimSpace(raw)
		if p == "" || seen[p] || (needLength && !headerLongEnough(p)) {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return out
}

// headerLongEnough 汉字段和拉丁段各自的长度下限,见 headerMatchVariants。
func headerLongEnough(s string) bool {
	han, alnum := 0, 0
	for _, r := range s {
		if isHanLike(r) {
			han++
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			alnum++
		}
	}
	if han > 0 {
		return han >= 2
	}
	return alnum >= 4
}

// isHanLike 与 Swift 侧 CharacterSet.hanLike 同一范围:假名 + 汉字基本区 / 扩展 A / 兼容表意。
func isHanLike(r rune) bool {
	return (r >= 0x3040 && r <= 0x30FF) || (r >= 0x3400 && r <= 0x4DBF) ||
		(r >= 0x4E00 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF)
}

// headerScriptRuns 按字形把一段文本切成连续的汉字 / 假名段和连续的其它字母数字段,非字母数字处断开。
func headerScriptRuns(s string) []string {
	var runs []string
	var cur strings.Builder
	state := 0 // 0 = 空, 1 = 汉字段, 2 = 其它
	flush := func() {
		if cur.Len() > 0 {
			runs = append(runs, cur.String())
			cur.Reset()
		}
	}
	for _, r := range s {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			flush()
			state = 0
			continue
		}
		next := 2
		if isHanLike(r) {
			next = 1
		}
		if state != 0 && state != next {
			flush()
		}
		state = next
		cur.WriteRune(r)
	}
	flush()
	return runs
}

// replaceFoldASCII 不分大小写地把 old(纯 ASCII)换成 new。
func replaceFoldASCII(s, old, new string) string {
	lower := strings.ToLower(s)
	var b strings.Builder
	for {
		i := strings.Index(lower, old)
		if i < 0 {
			b.WriteString(s)
			return b.String()
		}
		b.WriteString(s[:i])
		b.WriteString(new)
		s, lower = s[i+len(old):], lower[i+len(old):]
	}
}

// headerKey 抬头比对用的归一:转简体、只留字母数字、小写。
func headerKey(s string) string {
	return headerNorm(toSimplified(s))
}

func headerKeySet(forms []string) map[string]bool {
	m := map[string]bool{}
	for _, f := range forms {
		if k := headerKey(f); k != "" {
			m[k] = true
		}
	}
	return m
}

func headerKeyList(forms []string) []string {
	var out []string
	for _, f := range forms {
		if k := headerKey(f); k != "" {
			out = append(out, k)
		}
	}
	return out
}

func headerContainsAny(s string, subs []string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// headerNorm 只留字母和数字再小写 —— 空格/标点/大小写在抬头和本地标签之间从来对不齐。
func headerNorm(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

// stripHeaderBrackets 去掉成对括号及其内容再去首尾空白:抬头写的常是裸曲名,而本地标签带着
// "(Remastered 2014)" 这类后缀,不去掉两边永远对不上。
func stripHeaderBrackets(s string) string {
	var b strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '(', '[', '（', '［':
			depth++
		case ')', ']', '）', '］':
			if depth > 0 {
				depth--
			}
		default:
			if depth == 0 {
				b.WriteRune(r)
			}
		}
	}
	return strings.TrimSpace(b.String())
}
