package main

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// 逐字写法的 LRC:增强 LRC(行首 `[mm:ss.xx]`、每个词前 `<mm:ss.xx>`)和行内方括号(`[mm:ss.xx]词[mm:ss.xx]词[mm:ss.xx]`,
// 行首之后正文中间还有时间戳)。本地 .lrc、播放器曲库里用户自己嵌的歌词、手动粘贴进来的歌词会带这两种写法;
// 不拆的话 App 把 `<mm:ss.xx>` 当正文显示,行内方括号则一行有几个时间戳就重复几行。拆成逐行 LRC + YRC,逐字照常高亮。
// 见 09 章决策 331。

var (
	wordTimedLeadingTagRe = regexp.MustCompile(`^(?:\s*\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+`)
	wordTimedTagRe        = regexp.MustCompile(`<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>|\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]`)
	// wordTimedHintRe:正文中间出现时间标记(尖括号的,或者前面是字而不是另一个时间戳的方括号)。逐行 LRC 一处都没有。
	wordTimedHintRe = regexp.MustCompile(`<\d{1,3}:\d|[^\]\s]\s*\[\d{1,3}:\d`)
)

// wordTimedTailCapMs:最后一个词没有结束时间、整行没有逐字时,延到下一行起点,最多这么长。
const wordTimedTailCapMs = 5000

// wordTimedTagMs 把时间标签的三组捕获换成毫秒。小数位 1~3 位按右补零取前三位(.5 / .50 / .500 都是 500ms)。
func wordTimedTagMs(min, sec, frac string) int {
	m, _ := strconv.Atoi(min)
	s, _ := strconv.Atoi(sec)
	f := 0
	if frac != "" {
		f, _ = strconv.Atoi((frac + "00")[:3])
	}
	return (m*60+s)*1000 + f
}

type wordTimedWord struct {
	text  string
	start int
	end   int // -1 = 没给,按下一个词 / 下一行补
}

type wordTimedLine struct {
	start int
	text  string
	words []wordTimedWord // 空 = 这一行没有逐字时间
}

// parseWordTimedLine 拆一行。ok=false:不是带时间戳的歌词行(元信息标签、空行),原样留着。
// 只有行首时间戳、正文里没有时间标记的行返回 starts 多个(压缩写法,同一句挂在几个时间点上),inline 为假。
// inline 为真时 text 已去掉时间标记;词的起点倒退的行 words 为空,只当一行整行歌词。
func parseWordTimedLine(line string) (starts []int, text string, words []wordTimedWord, inline, ok bool) {
	lead := wordTimedLeadingTagRe.FindString(line)
	for _, m := range wordTimedTagRe.FindAllStringSubmatch(lead, -1) {
		starts = append(starts, wordTimedTagMs(m[4], m[5], m[6]))
	}
	rest := line[len(lead):]
	tags := wordTimedTagRe.FindAllStringSubmatchIndex(rest, -1)
	if len(tags) == 0 {
		if len(starts) == 0 {
			return nil, "", nil, false, false
		}
		return starts, strings.TrimSpace(rest), nil, false, true
	}
	// 正文里有时间标记:逐字行。行首第一个时间戳是行起点,没有就用第一个词的起点。
	tagMs := func(t []int) int {
		g := func(i int) string {
			if t[i] < 0 {
				return ""
			}
			return rest[t[i]:t[i+1]]
		}
		if t[2] >= 0 {
			return wordTimedTagMs(g(2), g(4), g(6))
		}
		return wordTimedTagMs(g(8), g(10), g(12))
	}
	var lineStart int
	if len(starts) > 0 {
		lineStart = starts[0]
	} else {
		lineStart = tagMs(tags[0])
	}
	if head := rest[:tags[0][0]]; strings.TrimSpace(head) != "" {
		words = append(words, wordTimedWord{text: head, start: lineStart, end: -1})
	}
	for i, t := range tags {
		end := len(rest)
		if i+1 < len(tags) {
			end = tags[i+1][0]
		}
		seg := rest[t[1]:end]
		at := tagMs(t)
		if strings.TrimSpace(seg) == "" {
			// 后面没有字的时间标记:上一个词的终点;夹在两个词中间的空白挂到上一个词尾巴上。
			if n := len(words); n > 0 {
				if words[n-1].end < 0 {
					words[n-1].end = at
				}
				words[n-1].text += seg
			}
			continue
		}
		words = append(words, wordTimedWord{text: seg, start: at, end: -1})
	}
	var b strings.Builder
	for _, w := range words {
		b.WriteString(w.text)
	}
	text = strings.TrimSpace(b.String())
	if text == "" {
		return nil, "", nil, false, false
	}
	for i := 1; i < len(words); i++ {
		if words[i].start < words[i-1].start {
			return []int{lineStart}, text, nil, true, true
		}
	}
	return []int{lineStart}, text, words, true, true
}

// splitWordTimedLRC 把逐字写法拆成逐行 LRC 和 YRC。正文里一处时间标记都没有时 ok=false,调用方原样用 lrc。
// 逐行 LRC 去掉正文里的时间标记,不带时间戳的行(元信息标签)原样保留。逐字的行至少占带时间戳的行的一半才给 YRC
// (yrc 为空 = 只洗正文):零星几行逐字不能让整份算作逐字歌词。YRC 里没有逐字的行整行算一个词,到下一行起点为止。
func splitWordTimedLRC(lrc string) (lines, yrc string, ok bool) {
	if !wordTimedHintRe.MatchString(lrc) {
		return "", "", false
	}
	var out []string
	var timed []wordTimedLine
	wordLines := 0
	for _, raw := range strings.Split(strings.ReplaceAll(lrc, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		starts, text, words, inline, isLyric := parseWordTimedLine(line)
		if !isLyric {
			out = append(out, line)
			continue
		}
		if inline {
			ok = true
			out = append(out, lrcTimestamp(starts[0])+text)
		} else {
			out = append(out, line)
		}
		if len(words) > 0 {
			wordLines++
			timed = append(timed, wordTimedLine{start: starts[0], text: text, words: words})
			continue
		}
		for _, s := range starts {
			timed = append(timed, wordTimedLine{start: s, text: text})
		}
	}
	if !ok {
		return "", "", false
	}
	if wordLines*2 < len(timed) {
		return strings.Join(out, "\n"), "", true
	}
	sort.SliceStable(timed, func(i, j int) bool { return timed[i].start < timed[j].start })
	tailEnd := func(i, from int) int {
		next := from + wordTimedTailCapMs
		if i+1 < len(timed) && timed[i+1].start > from && timed[i+1].start < next {
			next = timed[i+1].start
		}
		return next
	}
	var b strings.Builder
	for i, l := range timed {
		words := l.words
		if len(words) == 0 {
			words = []wordTimedWord{{text: l.text, start: l.start, end: -1}}
		}
		for k := range words {
			if words[k].end >= words[k].start {
				continue
			}
			if k+1 < len(words) {
				words[k].end = words[k+1].start
			} else {
				words[k].end = tailEnd(i, words[k].start)
			}
		}
		lineStart := min(l.start, words[0].start)
		lineEnd := words[len(words)-1].end
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(&b, "[%d,%d]", lineStart, lineEnd-lineStart)
		for _, w := range words {
			fmt.Fprintf(&b, "(%d,%d,0)%s", w.start, w.end-w.start, strings.ReplaceAll(w.text, "\n", " "))
		}
	}
	return strings.Join(out, "\n"), b.String(), true
}

// splitWordTimedSourceLyrics:各源交来的正文带逐字写法的,正文换成洗过的;源没有单独给逐字时间时填上拆出来的。
// 返回新 map,调用方那份原始应答不动(同 decodeLyricSourceEntities)。
func splitWordTimedSourceLyrics(raw map[string]lyricSourceResult) map[string]lyricSourceResult {
	out := make(map[string]lyricSourceResult, len(raw))
	for k, r := range raw {
		if lines, yrc, ok := splitWordTimedLRC(r.lyr); ok {
			r.lyr = lines
			if r.yrc == "" {
				r.yrc = yrc
			}
		}
		out[k] = r
	}
	return out
}
