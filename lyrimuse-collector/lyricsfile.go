package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// LRCLIB 应答里的 lyricsfile 是一份 YAML(1.0 版,LRCGET 定义):metadata(title / artist / album / duration_ms /
// offset_ms / language / instrumental)、lines[](text、start_ms、end_ms,可带逐字的 words[]:text、start_ms、end_ms)、
// plain。逐字的词文本自带尾随空格(最后一个词除外)。
//
// 两种生成器的写法都要认:LRCGET 前端(npm yaml,双引号、序列缩进在键下面、超过 80 列的字符串折行)和服务端 /
// LRCGET 后端(serde_yaml,单引号、序列跟键对齐)。这里只解析块风格的子集:映射、序列、普通 / 单引号 / 双引号
// 标量(可折行)、块标量(| >)、空的 [] {}、注释。非空的流式集合、锚点、别名、标签一律当解析失败,宁可不出逐字。

// lyricsfileExtras:lyricsfile 里接得上的三样,都可以是空串。metadata.offset_ms 不处理:服务端生成 syncedLyrics 时
// 没加它,三样都跟着逐行轨用原始时间才对得上。
type lyricsfileExtras struct {
	yrc  string // 逐字 YRC(YRCParser 的语法)
	roma string // 逐行罗马音 LRC,见 lyricsfileRomaLRC
	kana string // `[kana:…]` 假名标注行,见 lyricsfileKanaLine
}

// lyricsfileExtrasFrom 解析一次文档,取出逐字、罗马音、假名标注。synced 是同一条目的 syncedLyrics,假名标注按它的
// 正文行对齐。解析不了时全为空。
func lyricsfileExtrasFrom(doc, synced string) lyricsfileExtras {
	root, ok := parseLyricsfileYAML(doc)
	if !ok {
		return lyricsfileExtras{}
	}
	top, _ := root.(map[string]any)
	lines, _ := top["lines"].([]any)
	meta, _ := top["metadata"].(map[string]any)
	romaID, kanaID := lyricsfileTransliterationIDs(meta)
	return lyricsfileExtras{
		yrc:  lyricsfileYRC(lines),
		roma: lyricsfileRomaLRC(lines, romaID),
		kana: lyricsfileKanaLine(lines, kanaID, synced),
	}
}

// lyricsfileWordsToYRC 只取逐字 YRC。没有逐字、解析不了时返回空串。
func lyricsfileWordsToYRC(doc string) string {
	return lyricsfileExtrasFrom(doc, "").yrc
}

// lyricsfileYRC 把 lines[].words[] 转成 YRC:词文本原样拼(自带尾随空格),词缺 end_ms 取下一个词的起点 / 行尾,
// 词的起点倒退或结束早于开始的那一行整行不要。
func lyricsfileYRC(lines []any) string {
	var b strings.Builder
	for _, ln := range lines {
		line, _ := ln.(map[string]any)
		if line == nil {
			continue
		}
		words, _ := line["words"].([]any)
		if len(words) == 0 {
			continue
		}
		type word struct {
			text       string
			start, end int64
			hasEnd     bool
		}
		var ws []word
		for _, wv := range words {
			w, _ := wv.(map[string]any)
			text, _ := w["text"].(string)
			start, ok := yamlInt(w["start_ms"])
			if !ok || strings.TrimSpace(text) == "" {
				continue
			}
			end, hasEnd := yamlInt(w["end_ms"])
			ws = append(ws, word{text: strings.ReplaceAll(text, "\n", " "), start: start, end: end, hasEnd: hasEnd})
		}
		if len(ws) == 0 {
			continue
		}
		lineEnd, lineHasEnd := yamlInt(line["end_ms"])
		ordered := true
		for i := range ws {
			if !ws[i].hasEnd {
				switch {
				case i+1 < len(ws):
					ws[i].end = ws[i+1].start
				case lineHasEnd:
					ws[i].end = lineEnd
				default:
					ws[i].end = ws[i].start
				}
			}
			if ws[i].end < ws[i].start || (i > 0 && ws[i].start < ws[i-1].start) {
				ordered = false
				break
			}
		}
		if !ordered {
			continue
		}
		lineStart := ws[0].start
		if s, ok := yamlInt(line["start_ms"]); ok && s < lineStart {
			lineStart = s
		}
		if !lineHasEnd || lineEnd < ws[len(ws)-1].end {
			lineEnd = ws[len(ws)-1].end
		}
		fmt.Fprintf(&b, "[%d,%d]", lineStart, lineEnd-lineStart)
		for _, w := range ws {
			fmt.Fprintf(&b, "(%d,%d,0)%s", w.start, w.end-w.start, w.text)
		}
		b.WriteString("\n")
	}
	return strings.TrimSuffix(b.String(), "\n")
}

// lyricsfileTransliterationIDs:metadata.transliterations 里声明的音译 id。系统(BCP 47,如 ja-Latn / ja-Hrkt)的文字
// 子标签是 Latn 的当罗马音,Hrkt / Hira 的当假名读音;没声明时按 LRCGET 的默认 id(romaji / hira)认。
func lyricsfileTransliterationIDs(meta map[string]any) (roma, kana string) {
	list, _ := meta["transliterations"].([]any)
	for _, v := range list {
		m, _ := v.(map[string]any)
		id, _ := m["id"].(string)
		system, _ := m["system"].(string)
		parts := strings.Split(system, "-")
		if id == "" || len(parts) < 2 {
			continue
		}
		switch strings.ToLower(parts[1]) {
		case "latn":
			if roma == "" {
				roma = id
			}
		case "hrkt", "hira":
			if kana == "" {
				kana = id
			}
		}
	}
	if len(list) == 0 {
		return "romaji", "hira"
	}
	return roma, kana
}

// lyricsfileTranslit 取一行或一个词的 transliteration[id]。
func lyricsfileTranslit(node map[string]any, id string) string {
	if id == "" {
		return ""
	}
	t, _ := node["transliteration"].(map[string]any)
	v, _ := t[id].(string)
	return strings.TrimSpace(v)
}

// lyricsfileLineText:一行的正文 —— 有逐字时是词文本拼起来(跟服务端生成 syncedLyrics 的口径一致),否则是 text。
func lyricsfileLineText(line map[string]any) string {
	if words, _ := line["words"].([]any); len(words) > 0 {
		var b strings.Builder
		for _, wv := range words {
			w, _ := wv.(map[string]any)
			t, _ := w["text"].(string)
			b.WriteString(t)
		}
		return strings.TrimSpace(b.String())
	}
	t, _ := line["text"].(string)
	return strings.TrimSpace(t)
}

// lyricsfileRomaLRC 拼逐行罗马音:每行取整行的 transliteration[romaID],挂在这一行的 start_ms 上;整行没有、但每个
// 词都有(词文本本身就是拉丁字母的也算)时,把词的罗马音用空格连起来。一行都没有时返回空串。
func lyricsfileRomaLRC(lines []any, romaID string) string {
	if romaID == "" {
		return ""
	}
	var b strings.Builder
	for _, ln := range lines {
		line, _ := ln.(map[string]any)
		start, ok := yamlInt(line["start_ms"])
		if !ok || lyricsfileLineText(line) == "" {
			continue
		}
		roma := lyricsfileTranslit(line, romaID)
		if roma == "" {
			words, _ := line["words"].([]any)
			parts := make([]string, 0, len(words))
			for _, wv := range words {
				w, _ := wv.(map[string]any)
				text, _ := w["text"].(string)
				r := lyricsfileTranslit(w, romaID)
				if r == "" && dominantScript(text) == scriptLatin {
					r = strings.TrimSpace(text)
				}
				if r == "" {
					if strings.TrimSpace(text) == "" {
						continue
					}
					parts = nil
					break
				}
				parts = append(parts, r)
			}
			roma = strings.Join(parts, " ")
		}
		if roma == "" {
			continue
		}
		b.WriteString(formatLRCTime(int(start)))
		b.WriteString(strings.ReplaceAll(roma, "\n", " "))
		b.WriteString("\n")
	}
	return strings.TrimSuffix(b.String(), "\n")
}

// lyricsfileKanaLine 按 synced 的正文行(带时间戳、去掉时间戳后非空,跟 App 的 KanaAnnotation.bodyLines 同一口径)
// 拼 `[kana:…]` 行:条目是「覆盖几个待标字的单个数字 + 读音」,按顺序对齐正文里的待标字(kanaNeedsAnnotation)。
// 这一行在 lyricsfile 里有逐字、词带假名读音时按词出条目(去掉跟读音头尾相同的假名,只留汉字那段的读音);读音缺失、
// 拆不出、或这一行找不到逐字时,这几个字出空读音条目占位,保证对齐。一个带读音的条目都没有时返回空串。
func lyricsfileKanaLine(lines []any, kanaID, synced string) string {
	if kanaID == "" || synced == "" {
		return ""
	}
	type word struct{ text, reading string }
	byText := map[string][]word{}
	for _, ln := range lines {
		line, _ := ln.(map[string]any)
		words, _ := line["words"].([]any)
		text := lyricsfileLineText(line)
		if len(words) == 0 || text == "" {
			continue
		}
		if _, seen := byText[text]; seen {
			continue
		}
		ws := make([]word, 0, len(words))
		for _, wv := range words {
			w, _ := wv.(map[string]any)
			t, _ := w["text"].(string)
			ws = append(ws, word{text: t, reading: lyricsfileTranslit(w, kanaID)})
		}
		byText[text] = ws
	}
	var b strings.Builder
	annotated := false
	emitBlank := func(s string) {
		for _, r := range s {
			if kanaNeedsAnnotation(r) {
				b.WriteString("1")
			}
		}
	}
	for _, body := range kanaBodyLines(synced) {
		ws, ok := byText[body]
		if !ok {
			emitBlank(body)
			continue
		}
		for _, w := range ws {
			n, reading, clean := kanaEntryFor(w.text, w.reading)
			switch {
			case n == 0:
			case clean && n <= 9:
				fmt.Fprintf(&b, "%d%s", n, reading)
				annotated = annotated || reading != ""
			default:
				emitBlank(w.text)
			}
		}
	}
	if !annotated {
		return ""
	}
	return "[kana:" + b.String() + "]"
}

// kanaEntryFor:一个词的条目。n 是词里待标字的个数;待标字连成一段时 clean 为真,reading 是汉字那段的读音:读音头尾
// 带着跟词里相同的假名(「教え」→おしえ)就去掉,不带(「失っ」→うしな,只注了汉字)原样用;读音缺失时为空串。待标字
// 被假名隔开(「引き返す」)、或剩下的读音不全是平假名时 clean 为假,调用方逐字出空条目。
func kanaEntryFor(text, reading string) (n int, kanaReading string, clean bool) {
	runes := []rune(text)
	first, last := -1, -1
	for i, r := range runes {
		if kanaNeedsAnnotation(r) {
			n++
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if n == 0 {
		return 0, "", true
	}
	if last-first+1 != n {
		return n, "", false
	}
	if reading == "" {
		return n, "", true
	}
	prefix := toHiragana(strings.TrimSpace(string(runes[:first])))
	suffix := toHiragana(strings.TrimSpace(string(runes[last+1:])))
	mid := toHiragana(reading)
	if prefix != "" && strings.HasPrefix(mid, prefix) {
		mid = mid[len(prefix):]
	}
	if suffix != "" && strings.HasSuffix(mid, suffix) {
		mid = mid[:len(mid)-len(suffix)]
	}
	if mid == "" {
		return n, "", false
	}
	for _, c := range mid {
		if c == '(' || c == ')' || (c >= '0' && c <= '9') || !(unicode.In(c, unicode.Hiragana) || c == 'ー') {
			return n, "", false
		}
	}
	return n, mid, true
}

// kanaNeedsAnnotation:待标字 —— CJK 统一表意文字(含扩展 A)与叠字符号「々」。必须跟 App 的 KanaAnnotation.needsAnnotation
// 同步改(对不齐时 App 整份弃用、不报错),TestKanaAnnotationMirrorsSwift 钉着。
func kanaNeedsAnnotation(r rune) bool {
	return r == '々' || (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF)
}

// kanaBodyLines:LRC 的正文行(带时间戳、去掉时间戳后非空)。必须跟 App 的 KanaAnnotation.bodyLines 同步改,理由同上。
func kanaBodyLines(lrc string) []string {
	var out []string
	for _, line := range strings.Split(strings.ReplaceAll(lrc, "\r\n", "\n"), "\n") {
		if !kanaLRCTimeTag.MatchString(line) {
			continue
		}
		if text := strings.TrimSpace(kanaLRCTimeTag.ReplaceAllString(line, "")); text != "" {
			out = append(out, text)
		}
	}
	return out
}

var kanaLRCTimeTag = regexp.MustCompile(`\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]`)

// toHiragana 把片假名转成平假名(长音符「ー」等其余字符不动)。
func toHiragana(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 0x30A1 && r <= 0x30F6 {
			return r - 0x60
		}
		return r
	}, s)
}

// yamlInt 把解析出来的标量读成整数;null、缺省、读不出来时 ok 为 false。
func yamlInt(v any) (int64, bool) {
	s, ok := v.(string)
	if !ok {
		return 0, false
	}
	s = strings.TrimSpace(s)
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		return n, true
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return int64(f), true
	}
	return 0, false
}

type yamlLine struct {
	indent  int
	content string // 去掉缩进之后的内容
}

type yamlParser struct {
	lines []yamlLine
	pos   int
	err   bool
}

// parseLyricsfileYAML 把文档解析成 map[string]any / []any / string / nil 组成的树。
func parseLyricsfileYAML(doc string) (any, bool) {
	p := &yamlParser{}
	for _, raw := range strings.Split(strings.ReplaceAll(doc, "\r\n", "\n"), "\n") {
		trimmed := strings.TrimLeft(raw, " ")
		if strings.HasPrefix(trimmed, "\t") {
			return nil, false
		}
		if t := strings.TrimSpace(trimmed); t == "---" || t == "..." {
			continue
		}
		p.lines = append(p.lines, yamlLine{indent: len(raw) - len(trimmed), content: strings.TrimRight(trimmed, " \t")})
	}
	p.skipBlank()
	if p.pos >= len(p.lines) {
		return nil, false
	}
	v := p.parseBlock(p.lines[p.pos].indent)
	p.skipBlank()
	if p.err || p.pos < len(p.lines) {
		return nil, false
	}
	return v, true
}

func (p *yamlParser) skipBlank() {
	for p.pos < len(p.lines) {
		c := p.lines[p.pos].content
		if c != "" && !strings.HasPrefix(c, "#") {
			return
		}
		p.pos++
	}
}

// parseBlock 解析从当前行开始、缩进正好是 indent 的一个块(映射或序列)。
func (p *yamlParser) parseBlock(indent int) any {
	p.skipBlank()
	if p.pos >= len(p.lines) || p.lines[p.pos].indent != indent {
		return nil
	}
	if isYAMLSeqItem(p.lines[p.pos].content) {
		return p.parseSeq(indent)
	}
	if _, _, ok := splitYAMLKey(p.lines[p.pos].content); ok {
		return p.parseMap(indent)
	}
	p.err = true
	return nil
}

func isYAMLSeqItem(c string) bool { return c == "-" || strings.HasPrefix(c, "- ") }

func (p *yamlParser) parseSeq(indent int) []any {
	out := []any{}
	for !p.err {
		p.skipBlank()
		if p.pos >= len(p.lines) || p.lines[p.pos].indent != indent || !isYAMLSeqItem(p.lines[p.pos].content) {
			break
		}
		line := p.lines[p.pos]
		rest := strings.TrimLeft(strings.TrimPrefix(line.content, "-"), " ")
		if rest == "" {
			p.pos++
			p.skipBlank()
			if p.pos < len(p.lines) && p.lines[p.pos].indent > indent {
				out = append(out, p.parseBlock(p.lines[p.pos].indent))
			} else {
				out = append(out, nil)
			}
			continue
		}
		// 「- key: value」:这一项是映射,第一个键就写在短横线后面,后续的键对齐到它的列上。
		itemIndent := indent + (len(line.content) - len(rest))
		if _, _, ok := splitYAMLKey(rest); ok {
			p.lines[p.pos] = yamlLine{indent: itemIndent, content: rest}
			out = append(out, p.parseMap(itemIndent))
			continue
		}
		if isYAMLSeqItem(rest) {
			p.err = true
			break
		}
		p.pos++
		out = append(out, p.parseScalar(rest, indent))
	}
	return out
}

func (p *yamlParser) parseMap(indent int) map[string]any {
	out := map[string]any{}
	for !p.err {
		p.skipBlank()
		if p.pos >= len(p.lines) || p.lines[p.pos].indent != indent {
			break
		}
		key, rest, ok := splitYAMLKey(p.lines[p.pos].content)
		if !ok {
			p.err = true
			break
		}
		p.pos++
		if rest == "" {
			// 值写在下一行:更深的缩进是嵌套块;跟键同一列的「- 」是序列(serde_yaml 的写法);都不是就是 null。
			p.skipBlank()
			switch {
			case p.pos < len(p.lines) && p.lines[p.pos].indent > indent:
				out[key] = p.parseBlock(p.lines[p.pos].indent)
			case p.pos < len(p.lines) && p.lines[p.pos].indent == indent && isYAMLSeqItem(p.lines[p.pos].content):
				out[key] = p.parseSeq(indent)
			default:
				out[key] = nil
			}
			continue
		}
		out[key] = p.parseScalar(rest, indent)
	}
	return out
}

// splitYAMLKey 拆出「key: rest」。键只认普通写法和引号写法;值为空时 rest 为空串。
func splitYAMLKey(c string) (key, rest string, ok bool) {
	if c == "" || strings.HasPrefix(c, "- ") || c == "-" || strings.HasPrefix(c, "? ") {
		return "", "", false
	}
	if c[0] == '"' || c[0] == '\'' {
		val, n, ok := readYAMLQuoted(c)
		if !ok {
			return "", "", false
		}
		after := c[n:]
		if after == ":" {
			return val, "", true
		}
		if strings.HasPrefix(after, ": ") {
			return val, strings.TrimSpace(after[2:]), true
		}
		return "", "", false
	}
	if i := strings.Index(c, ": "); i > 0 {
		return strings.TrimSpace(c[:i]), strings.TrimSpace(c[i+2:]), true
	}
	if strings.HasSuffix(c, ":") && len(c) > 1 {
		return strings.TrimSpace(c[:len(c)-1]), "", true
	}
	return "", "", false
}

// parseScalar 解析写在键(或短横线)后面的值 rest;parentIndent 是键所在的缩进,更深的后续行是这个值的续行。
func (p *yamlParser) parseScalar(rest string, parentIndent int) any {
	switch {
	case rest == "[]":
		return []any{}
	case rest == "{}":
		return map[string]any{}
	case rest[0] == '[' || rest[0] == '{' || rest[0] == '&' || rest[0] == '*' || rest[0] == '!':
		p.err = true
		return nil
	case rest[0] == '|' || rest[0] == '>':
		return p.parseBlockScalar(rest, parentIndent)
	case rest[0] == '"' || rest[0] == '\'':
		text := rest
		for {
			val, n, ok := readYAMLQuoted(text)
			if ok {
				if tail := strings.TrimSpace(text[n:]); tail != "" && !strings.HasPrefix(tail, "#") {
					p.err = true
					return nil
				}
				return val
			}
			// 引号没在这一行收尾:接上下一行(折行),空行算一个换行。
			if p.pos >= len(p.lines) {
				p.err = true
				return nil
			}
			next := p.lines[p.pos]
			p.pos++
			if next.content == "" {
				text += "\n"
			} else if strings.HasSuffix(text, "\\") && rest[0] == '"' {
				text = text[:len(text)-1] + next.content
			} else {
				text += " " + next.content
			}
		}
	}
	val := stripYAMLComment(rest)
	// 普通标量的续行:缩进比键深、不是注释。
	for p.pos < len(p.lines) {
		next := p.lines[p.pos]
		if next.content == "" || strings.HasPrefix(next.content, "#") || next.indent <= parentIndent {
			break
		}
		val += " " + stripYAMLComment(next.content)
		p.pos++
	}
	switch val {
	case "~", "null", "Null", "NULL":
		return nil
	}
	return val
}

// parseBlockScalar 读 | / > 块标量:后面所有比键深的行(含空行)都是它的内容。
func (p *yamlParser) parseBlockScalar(header string, parentIndent int) any {
	var parts []string
	contentIndent := -1
	for p.pos < len(p.lines) {
		next := p.lines[p.pos]
		if next.content != "" && next.indent <= parentIndent {
			break
		}
		if next.content != "" && contentIndent < 0 {
			contentIndent = next.indent
		}
		line := next.content
		if next.content != "" && next.indent > contentIndent && contentIndent >= 0 {
			line = strings.Repeat(" ", next.indent-contentIndent) + line
		}
		parts = append(parts, line)
		p.pos++
	}
	sep := "\n"
	if header[0] == '>' {
		sep = " "
	}
	text := strings.Join(parts, sep)
	if !strings.Contains(header, "-") {
		text = strings.TrimRight(text, "\n ") + "\n"
	}
	return strings.TrimRight(text, " ")
}

func stripYAMLComment(s string) string {
	if i := strings.Index(s, " #"); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

// readYAMLQuoted 读开头的单引号 / 双引号字符串,返回值、它在 s 里占的字节数;没收尾时 ok 为 false。
func readYAMLQuoted(s string) (val string, n int, ok bool) {
	q := s[0]
	var b strings.Builder
	for i := 1; i < len(s); {
		c := s[i]
		if q == '\'' {
			if c == '\'' {
				if i+1 < len(s) && s[i+1] == '\'' {
					b.WriteByte('\'')
					i += 2
					continue
				}
				return b.String(), i + 1, true
			}
			b.WriteByte(c)
			i++
			continue
		}
		switch c {
		case '"':
			return b.String(), i + 1, true
		case '\\':
			if i+1 >= len(s) {
				return "", 0, false
			}
			r, width, good := yamlEscape(s[i+1:])
			if !good {
				return "", 0, false
			}
			b.WriteString(r)
			i += 1 + width
		default:
			b.WriteByte(c)
			i++
		}
	}
	return "", 0, false
}

// yamlEscape 读双引号字符串里反斜杠后面的转义,返回替换文字与转义本身占的字节数。
func yamlEscape(s string) (string, int, bool) {
	simple := map[byte]string{'n': "\n", 't': "\t", 'r': "\r", '0': "\x00", '"': `"`, '\\': `\`, '/': "/", ' ': " ",
		'_': "\u00a0", 'N': "\u0085", 'L': "\u2028", 'P': "\u2029", 'a': "\a", 'b': "\b", 'e': "\x1b", 'f': "\f", 'v': "\v"}
	if r, ok := simple[s[0]]; ok {
		return r, 1, true
	}
	width := map[byte]int{'x': 2, 'u': 4, 'U': 8}[s[0]]
	if width == 0 || len(s) < 1+width {
		return "", 0, false
	}
	n, err := strconv.ParseUint(s[1:1+width], 16, 32)
	if err != nil || !utf8.ValidRune(rune(n)) {
		return "", 0, false
	}
	return string(rune(n)), 1 + width, true
}
