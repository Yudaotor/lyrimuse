package main

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// isLyricMarkerLine:一行歌词去掉时间戳之后只是段落标记(「[Outro]」「(Instrumental)」「【间奏】」「Chorus:」),或者
// 只有符号(「♪」「…」「~」)。这样的行不是唱的词,算末句时间(lastLRCTimestampSecs)时跟空白行、署名行一样跳过。
//
// 标记要整行就是它。带括号(「[Chorus: 某人]」,括号里可以跟演唱者)或以冒号结尾(「Chorus:」)时认 lyricMarkerLabels 里的
// 全部段落名;冒号后面还有字的(「Verse 1: 歌词」)是唱的。光秃秃一行只认 lyricBareMarkerLabels 那几个表示没人唱的词:
// 整行写着「副歌」「end」「Outro」说不准是标注还是唱的。
func isLyricMarkerLine(text string) bool {
	t := strings.TrimSpace(text)
	if t == "" {
		return false
	}
	if lyricSymbolOnly(t) {
		return true
	}
	first, _ := utf8.DecodeRuneInString(t)
	last, _ := utf8.DecodeLastRuneInString(t)
	bracketed := utf8.RuneCountInString(t) >= 2 && lyricMarkerOpen(first) && lyricMarkerClose(last)
	if bracketed {
		_, fs := utf8.DecodeRuneInString(t)
		_, ls := utf8.DecodeLastRuneInString(t)
		t = t[fs : len(t)-ls]
	}
	header := bracketed
	if i := strings.IndexAny(t, ":："); i >= 0 {
		_, cs := utf8.DecodeRuneInString(t[i:])
		if !bracketed && strings.TrimSpace(t[i+cs:]) != "" {
			return false
		}
		t = t[:i]
		header = true
	}
	if header {
		return lyricMarkerLabels[lyricMarkerKey(t)]
	}
	return lyricBareMarkerLabels[lyricMarkerKey(t)]
}

func lyricMarkerOpen(r rune) bool  { return isOpenBracket(r) || r == '〔' || r == '<' || r == '《' }
func lyricMarkerClose(r rune) bool { return isCloseBracket(r) || r == '〕' || r == '>' || r == '》' }

// lyricMarkerSymbols:只由这些符号(和空白)组成的行算标记。
const lyricMarkerSymbols = "♪♫♬♩~～…⋯.·・-—–_*•"

func lyricSymbolOnly(t string) bool {
	seen := false
	for _, r := range t {
		switch {
		case unicode.IsSpace(r):
		case strings.ContainsRune(lyricMarkerSymbols, r):
			seen = true
		default:
			return false
		}
	}
	return seen
}

// lyricMarkerKey:标记词归一成查表用的写法:小写,去掉数字、空白、连字符、点和标记符号(「Pre-Chorus 2」→「prechorus」)。
func lyricMarkerKey(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch {
		case unicode.IsSpace(r), unicode.IsDigit(r), r == '#', strings.ContainsRune(lyricMarkerSymbols, r):
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// lyricBareMarkerLabels:不带括号、不带冒号,整行就是这些词时也算标记 —— 只收表示这一段没人唱、或者歌到这里结束的说法。
var lyricBareMarkerLabels = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range []string{
		"instrumental", "间奏", "間奏", "尾奏", "前奏", "过门", "過門", "纯音乐", "純音樂", "音乐", "音樂", "伴奏",
		"结束", "結束", "完", "终", "終",
	} {
		m[w] = true
	}
	return m
}()

// lyricMarkerLabels:带括号或冒号结尾时算段落标记的词:段落名(lyricSectionWords)、lyricBareMarkerLabels,再补上几种
// 段落和结束的说法。
var lyricMarkerLabels = func() map[string]bool {
	m := map[string]bool{}
	for w := range lyricSectionWords {
		m[w] = true
	}
	for w := range lyricBareMarkerLabels {
		m[w] = true
	}
	for _, w := range []string{
		"music", "musicalinterlude", "instrumentalbreak", "inst", "solo", "guitarsolo", "pianosolo", "break",
		"end", "ending", "fadeout", "spokenword", "副歌", "主歌", "桥段", "橋段",
	} {
		m[w] = true
	}
	return m
}()
