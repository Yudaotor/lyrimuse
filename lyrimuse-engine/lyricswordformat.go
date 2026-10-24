package main

import (
	"bytes"
	"compress/zlib"
	"encoding/xml"
	"fmt"
	"hash/crc32"
	"io"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// 歌词文件夹里逐字歌词的文件格式。缓存里一律是 YRC 语法;这里只管写进文件夹、从文件夹读回来的那一份,
// 设置里选(features.json 的 lyrics_word_formats,第一个是主格式,其余是另外多存的副本)。见 11 章决策 144。
//
// 每种格式分三步:encodeLyricsWordText 把缓存内容写成这种格式的明文,sealLyricsWordFile 把明文封成文件字节
// (QRC / KRC 是 QQ 音乐、酷狗客户端本地文件的加密写法,其余原样),openLyricsWordFile / decodeLyricsWordText
// 反过来。判「文件是不是导出时那一份」一律比明文(lyricsWordFileMatches),不靠解码后跟缓存比:增强 LRC、TTML
// 写不下 YRC 的全部细节,解码回来不一定跟缓存一样。

type lyricsWordFormat string

const (
	lyricsWordYRC  lyricsWordFormat = "yrc"
	lyricsWordTTML lyricsWordFormat = "ttml"
	lyricsWordQRC  lyricsWordFormat = "qrc"
	lyricsWordKRC  lyricsWordFormat = "krc"
	lyricsWordELRC lyricsWordFormat = "enhanced-lrc"
)

// lyricsWordFormatsAll:全部格式。顺序也是主格式那份文件不在时,从文件夹里别的格式里取的先后。
var lyricsWordFormatsAll = []lyricsWordFormat{lyricsWordYRC, lyricsWordTTML, lyricsWordQRC, lyricsWordKRC, lyricsWordELRC}

func (f lyricsWordFormat) suffix() string {
	switch f {
	case lyricsWordTTML:
		return ".ttml"
	case lyricsWordQRC:
		return ".qrc"
	case lyricsWordKRC:
		return ".krc"
	case lyricsWordELRC:
		return ".enhanced.lrc"
	}
	return ".yrc"
}

// lyricsWordFormatOfSuffix:文件后缀对应的逐字格式。不是逐字文件的后缀(.lrc / .tr.lrc / .roma.lrc)返回 false。
func lyricsWordFormatOfSuffix(suffix string) (lyricsWordFormat, bool) {
	for _, f := range lyricsWordFormatsAll {
		if f.suffix() == suffix {
			return f, true
		}
	}
	return "", false
}

// lyricsWordFormatNamed:设置里写的格式名(lyricsWordYRC 等的值)对应的格式,认不得返回 false。
func lyricsWordFormatNamed(s string) (lyricsWordFormat, bool) {
	for _, f := range lyricsWordFormatsAll {
		if string(f) == s {
			return f, true
		}
	}
	return "", false
}

// resolveLyricsWordFormats:设置里的格式名单去掉认不得的、重复的;一个都不剩时只写 YRC。
func resolveLyricsWordFormats(names []string) []lyricsWordFormat {
	var out []lyricsWordFormat
	for _, n := range names {
		if f, ok := lyricsWordFormatNamed(n); ok && !slices.Contains(out, f) {
			out = append(out, f)
		}
	}
	if len(out) == 0 {
		return []lyricsWordFormat{lyricsWordYRC}
	}
	return out
}

// lyricsWordFileInput:写一份逐字文件要用的缓存内容。
type lyricsWordFileInput struct {
	artist, title, album, source string
	manual                       bool
	// yrc:写进文件的逐字。括号里拆出来的背景人声已经接回主句(parenBGFileForm),跟 .lrc 一致。
	yrc string
	// nativeYRC / bg:缓存原样的逐字和背景人声轨,TTML 用 —— 它有背景人声这一项,用不着接回括号。
	nativeYRC, bg string
	// durationSecs:整首时长,QRC 的 SaveTime 写它(QQ 音乐本地文件就是这么写的)。
	durationSecs float64
}

func (in lyricsWordFileInput) header() string {
	return lyricsFileHeader(in.artist, in.title, in.album, in.source, in.manual)
}

// lyricsWordFileParsed:从一份逐字文件读出来的身份和内容。
type lyricsWordFileParsed struct {
	parsedLyricsFile // body 是转成 YRC 语法的逐字
	// bg / hasBG:文件自己带的背景人声轨(只有 TTML 有这一项)。hasBG=false 时调用方按原来的规则处理背景人声。
	bg    string
	hasBG bool
}

// ---- YRC 行的通用拆法 ----

var (
	lyricsWordYRCHeadRe  = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
	lyricsWordYRCTokenRe = regexp.MustCompile(`\((\d+),(\d+),(\d+)\)`)
)

type yrcDocWord struct {
	start, dur int
	text       string
}

// yrcDocLine:YRC 的一行。timed=false 是没有 [行始,行长] 的行(标签行、空行),raw 原样。
// lead 是第一个词条之前的文字(不规范的数据才有)。
type yrcDocLine struct {
	timed      bool
	raw        string
	start, dur int
	lead       string
	words      []yrcDocWord
}

func parseYRCDoc(yrc string) []yrcDocLine {
	var out []yrcDocLine
	for _, l := range strings.Split(yrc, "\n") {
		m := lyricsWordYRCHeadRe.FindStringSubmatchIndex(l)
		if m == nil {
			out = append(out, yrcDocLine{raw: l})
			continue
		}
		line := yrcDocLine{timed: true}
		line.start, _ = strconv.Atoi(l[m[2]:m[3]])
		line.dur, _ = strconv.Atoi(l[m[4]:m[5]])
		rest := l[m[1]:]
		locs := lyricsWordYRCTokenRe.FindAllStringSubmatchIndex(rest, -1)
		if len(locs) == 0 {
			line.lead = rest
			out = append(out, line)
			continue
		}
		line.lead = rest[:locs[0][0]]
		for i, lc := range locs {
			end := len(rest)
			if i+1 < len(locs) {
				end = locs[i+1][0]
			}
			s, _ := strconv.Atoi(rest[lc[2]:lc[3]])
			d, _ := strconv.Atoi(rest[lc[4]:lc[5]])
			line.words = append(line.words, yrcDocWord{start: s, dur: d, text: rest[lc[1]:end]})
		}
		out = append(out, line)
	}
	return out
}

// wordsWithLead:把第一个词条之前的文字并进第一个词。写不出「没有时间的文字」的格式用。
func (l yrcDocLine) wordsWithLead() []yrcDocWord {
	if l.lead == "" || len(l.words) == 0 {
		return l.words
	}
	ws := append([]yrcDocWord(nil), l.words...)
	ws[0].text = l.lead + ws[0].text
	return ws
}

// ---- 编码 ----

// encodeLyricsWordText:缓存内容写成格式 f 的明文(加密之前)。
func encodeLyricsWordText(f lyricsWordFormat, in lyricsWordFileInput) string {
	switch f {
	case lyricsWordTTML:
		return encodeTTMLWordText(in)
	case lyricsWordQRC:
		return encodeQRCWordText(in)
	case lyricsWordKRC:
		return encodeKRCWordText(in)
	case lyricsWordELRC:
		return encodeEnhancedLRCWordText(in)
	}
	return in.header() + in.yrc
}

func encodeQRCWordText(in lyricsWordFileInput) string {
	var b strings.Builder
	b.WriteString(in.header())
	for i, l := range parseYRCDoc(in.yrc) {
		if i > 0 {
			b.WriteString("\n")
		}
		if !l.timed {
			b.WriteString(l.raw)
			continue
		}
		fmt.Fprintf(&b, "[%d,%d]", l.start, l.dur)
		if len(l.words) == 0 {
			b.WriteString(l.lead)
			continue
		}
		for _, w := range l.wordsWithLead() {
			fmt.Fprintf(&b, "%s(%d,%d)", w.text, w.start, w.dur)
		}
	}
	// QQ 音乐本地 .qrc 的外壳。正文里的引号、& 照原样写,不转义:QQ 自己就是这么写的,别的工具(LDDC 等)按原样取。
	return fmt.Sprintf("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<QrcInfos>\n<QrcHeadInfo SaveTime=\"%d\" Version=\"100\"/>\n"+
		"<LyricInfo LyricCount=\"1\">\n<Lyric_1 LyricType=\"1\" LyricContent=\"%s\"/>\n</LyricInfo>\n</QrcInfos>",
		int(in.durationSecs+0.5), b.String())
}

func encodeKRCWordText(in lyricsWordFileInput) string {
	var b strings.Builder
	b.WriteString(in.header())
	for i, l := range parseYRCDoc(in.yrc) {
		if i > 0 {
			b.WriteString("\n")
		}
		if !l.timed {
			b.WriteString(l.raw)
			continue
		}
		fmt.Fprintf(&b, "[%d,%d]", l.start, l.dur)
		if len(l.words) == 0 {
			b.WriteString(l.lead)
			continue
		}
		// KRC 的词始是相对行始的偏移,可以是负数(词比行头早一点开始)。
		for _, w := range l.wordsWithLead() {
			fmt.Fprintf(&b, "<%d,%d,0>%s", w.start-l.start, w.dur, w.text)
		}
	}
	return b.String()
}

// lrcCentiTime:增强 LRC 的时间 mm:ss.xx(百分之一秒,舍去不足 10 毫秒的部分,同 formatLRCTime)。
func lrcCentiTime(ms int) string {
	t := formatLRCTime(ms)
	return t[1 : len(t)-1]
}

func encodeEnhancedLRCWordText(in lyricsWordFileInput) string {
	var b strings.Builder
	b.WriteString(in.header())
	for i, l := range parseYRCDoc(in.yrc) {
		if i > 0 {
			b.WriteString("\n")
		}
		if !l.timed {
			b.WriteString(l.raw)
			continue
		}
		b.WriteString(formatLRCTime(l.start))
		ws := l.wordsWithLead()
		if len(ws) == 0 {
			b.WriteString(l.lead)
			continue
		}
		// 每个词前面写它的起点;跟下一个词之间有空档时多写一个这个词的终点,最后一个词后面写终点。
		// 行尾比最后一个词晚结束的,再写一个行尾。
		for j, w := range ws {
			fmt.Fprintf(&b, "<%s>%s", lrcCentiTime(w.start), w.text)
			end := w.start + w.dur
			if j+1 == len(ws) || ws[j+1].start != end {
				fmt.Fprintf(&b, "<%s>", lrcCentiTime(end))
			}
		}
		last := ws[len(ws)-1]
		if lineEnd := l.start + l.dur; lineEnd > last.start+last.dur {
			fmt.Fprintf(&b, "<%s>", lrcCentiTime(lineEnd))
		}
	}
	return b.String()
}

// ttmlClockTime:TTML 的时间,m:ss.mmm,过了一小时写 h:mm:ss.mmm。
func ttmlClockTime(ms int) string {
	if ms < 0 {
		ms = 0
	}
	if ms >= 3600000 {
		return fmt.Sprintf("%d:%02d:%02d.%03d", ms/3600000, (ms/60000)%60, (ms/1000)%60, ms%1000)
	}
	return fmt.Sprintf("%d:%02d.%03d", ms/60000, (ms/1000)%60, ms%1000)
}

func ttmlEscape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

// lyricsWordTTMLNS:TTML 里记文件头(歌手、歌名、专辑、来源、手改)那个元素的命名空间。
const lyricsWordTTMLNS = "https://github.com/Yudaotor/lyrimuse/ns/lyrics-file"

func encodeTTMLWordText(in lyricsWordFileInput) string {
	bgByHead := map[string][]yrcDocWord{}
	for _, l := range parseYRCDoc(in.bg) {
		if !l.timed || len(l.words) == 0 {
			continue
		}
		head := fmt.Sprintf("%d,%d", l.start, l.dur)
		if _, dup := bgByHead[head]; !dup {
			bgByHead[head] = l.wordsWithLead()
		}
	}
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	b.WriteString(`<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="` + ttmMetadataNS + `" xmlns:itunes="` + itunesTTMLNS +
		`" xmlns:amll="http://www.example.com/ns/amll" xmlns:lyrimuse="` + lyricsWordTTMLNS + `" itunes:timing="Word">` + "\n")
	b.WriteString("<head><metadata>\n")
	fmt.Fprintf(&b, "<amll:meta key=\"musicName\" value=\"%s\"/>\n", ttmlEscape(in.title))
	if in.artist != "" {
		fmt.Fprintf(&b, "<amll:meta key=\"artists\" value=\"%s\"/>\n", ttmlEscape(in.artist))
	}
	if in.album != "" {
		fmt.Fprintf(&b, "<amll:meta key=\"album\" value=\"%s\"/>\n", ttmlEscape(in.album))
	}
	fmt.Fprintf(&b, "<lyrimuse:file ar=\"%s\" ti=\"%s\" al=\"%s\" source=\"%s\"", ttmlEscape(in.artist), ttmlEscape(in.title),
		ttmlEscape(in.album), ttmlEscape(in.source))
	if in.manual {
		b.WriteString(` manual="1"`)
	}
	b.WriteString("/>\n</metadata></head>\n<body><div>\n")
	writeSpans := func(ws []yrcDocWord) {
		for _, w := range ws {
			fmt.Fprintf(&b, "<span begin=\"%s\" end=\"%s\">%s</span>", ttmlClockTime(w.start), ttmlClockTime(w.start+w.dur), ttmlEscape(w.text))
		}
	}
	for _, l := range parseYRCDoc(in.nativeYRC) {
		ws := l.wordsWithLead()
		if !l.timed || len(ws) == 0 {
			continue
		}
		fmt.Fprintf(&b, "<p begin=\"%s\" end=\"%s\">", ttmlClockTime(l.start), ttmlClockTime(l.start+l.dur))
		writeSpans(ws)
		if bg := bgByHead[fmt.Sprintf("%d,%d", l.start, l.dur)]; len(bg) > 0 {
			b.WriteString(`<span ttm:role="x-bg">`)
			writeSpans(bg)
			b.WriteString(`</span>`)
		}
		b.WriteString("</p>\n")
	}
	b.WriteString("</div></body>\n</tt>\n")
	return b.String()
}

// ---- 封装 / 拆封(加密) ----

// lyricsQRCFileHeader:QQ 音乐本地 .qrc 解开最外层异或之后开头固定的 11 字节,后面才是 3DES 密文。
const lyricsQRCFileHeader = "[offset:0]\n"

// lyricsQMC1Key:QQ 音乐本地 .qrc 最外层按位置异或用的 128 字节密钥(社区逆向的公开算法,同 LDDC 的 qmc1_decrypt)。
var lyricsQMC1Key = [128]byte{
	0xc3, 0x4a, 0xd6, 0xca, 0x90, 0x67, 0xf7, 0x52, 0xd8, 0xa1, 0x66, 0x62, 0x9f, 0x5b, 0x09, 0x00,
	0xc3, 0x5e, 0x95, 0x23, 0x9f, 0x13, 0x11, 0x7e, 0xd8, 0x92, 0x3f, 0xbc, 0x90, 0xbb, 0x74, 0x0e,
	0xc3, 0x47, 0x74, 0x3d, 0x90, 0xaa, 0x3f, 0x51, 0xd8, 0xf4, 0x11, 0x84, 0x9f, 0xde, 0x95, 0x1d,
	0xc3, 0xc6, 0x09, 0xd5, 0x9f, 0xfa, 0x66, 0xf9, 0xd8, 0xf0, 0xf7, 0xa0, 0x90, 0xa1, 0xd6, 0xf3,
	0xc3, 0xf3, 0xd6, 0xa1, 0x90, 0xa0, 0xf7, 0xf0, 0xd8, 0xf9, 0x66, 0xfa, 0x9f, 0xd5, 0x09, 0xc6,
	0xc3, 0x1d, 0x95, 0xde, 0x9f, 0x84, 0x11, 0xf4, 0xd8, 0x51, 0x3f, 0xaa, 0x90, 0x3d, 0x74, 0x47,
	0xc3, 0x0e, 0x74, 0xbb, 0x90, 0xbc, 0x3f, 0x92, 0xd8, 0x7e, 0x11, 0x13, 0x9f, 0x23, 0x95, 0x5e,
	0xc3, 0x00, 0x09, 0x5b, 0x9f, 0x62, 0x66, 0xa1, 0xd8, 0x52, 0xf7, 0x67, 0x90, 0xca, 0xd6, 0x4a,
}

// qmc1XOR 原地做 QQ 音乐本地文件那层异或,加密解密是同一个运算。
func qmc1XOR(data []byte) {
	for i := range data {
		k := i & 0x7f
		if i > 0x7fff {
			k = (i % 0x7fff) & 0x7f
		}
		data[i] ^= lyricsQMC1Key[k]
	}
}

func zlibBytes(s string) []byte {
	var b bytes.Buffer
	w := zlib.NewWriter(&b)
	_, _ = w.Write([]byte(s))
	_ = w.Close()
	return b.Bytes()
}

// sealLyricsWordFile:明文封成文件字节。QRC:zlib → 补零到 8 的倍数 → 3DES → 前面加 11 字节头 → 整份异或;
// KRC:zlib → 异或 → 前面加 "krc1"。
func sealLyricsWordFile(f lyricsWordFormat, plain string) []byte {
	switch f {
	case lyricsWordQRC:
		z := zlibBytes(plain)
		if pad := len(z) % 8; pad != 0 {
			z = append(z, make([]byte, 8-pad)...)
		}
		out := append([]byte(lyricsQRCFileHeader), qm3DESEncrypt(qrcDESKey, z)...)
		qmc1XOR(out)
		return out
	case lyricsWordKRC:
		z := zlibBytes(plain)
		for i := range z {
			z[i] ^= krcXORKey[i%len(krcXORKey)]
		}
		return append([]byte("krc1"), z...)
	}
	return []byte(plain)
}

// openLyricsWordFile:文件字节还原成明文。QRC / KRC 加密的、明文的都认(别的工具导出的明文版)。
func openLyricsWordFile(f lyricsWordFormat, data []byte) (string, bool) {
	switch f {
	case lyricsWordQRC:
		// 明文版是 XML;加密版的字节别拿去按文本转码(不是 UTF-8 的整份会按 GB18030 / Big5 逐个试,又慢又没用)。
		if t := bytes.TrimLeft(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf")), " \t\r\n"); bytes.HasPrefix(t, []byte("<?xml")) || bytes.HasPrefix(t, []byte("<QrcInfos")) {
			return openPlainLyricsText(data)
		}
		if len(data) <= len(lyricsQRCFileHeader) {
			return "", false
		}
		x := append([]byte(nil), data...)
		qmc1XOR(x)
		body := x[len(lyricsQRCFileHeader):]
		if len(body)%8 != 0 {
			return "", false
		}
		zr, err := zlib.NewReader(bytes.NewReader(qm3DESDecrypt(qrcDESKey, body)))
		if err != nil {
			return "", false
		}
		defer zr.Close()
		out, err := io.ReadAll(io.LimitReader(zr, krcDecompressedMaxBytes+1))
		if err != nil || len(out) > krcDecompressedMaxBytes {
			return "", false
		}
		return string(out), true
	case lyricsWordKRC:
		if bytes.HasPrefix(data, []byte("krc1")) {
			if s := decryptKRCBytes(data); s != "" {
				return s, true
			}
		}
		return openPlainLyricsText(data)
	}
	return openPlainLyricsText(data)
}

// openPlainLyricsText:文本文件按 decodeLyricBytes 的规矩转成 UTF-8,去掉 BOM。
func openPlainLyricsText(data []byte) (string, bool) {
	text, _ := decodeLyricBytes(data)
	return strings.TrimPrefix(text, "\ufeff"), true
}

// ---- 解码 ----

// decodeLyricsWordText:格式 f 的明文还原成身份 + YRC 语法的逐字。认不出身份时 ok=false。
func decodeLyricsWordText(f lyricsWordFormat, plain string) lyricsWordFileParsed {
	switch f {
	case lyricsWordTTML:
		return decodeTTMLWordText(plain)
	case lyricsWordQRC:
		p := parseLyricsBytes([]byte(extractQRCLyricContent(plain)))
		p.body = qrcToYRC(p.body)
		return lyricsWordFileParsed{parsedLyricsFile: p}
	case lyricsWordKRC:
		p := parseLyricsBytes([]byte(plain))
		p.body = krcToYRC(p.body)
		return lyricsWordFileParsed{parsedLyricsFile: p}
	case lyricsWordELRC:
		p := parseLyricsBytes([]byte(plain))
		p.body = enhancedLRCToYRC(p.body)
		return lyricsWordFileParsed{parsedLyricsFile: p}
	}
	return lyricsWordFileParsed{parsedLyricsFile: parseLyricsBytes([]byte(plain))}
}

var (
	enhancedLRCLineRe   = regexp.MustCompile(`^\[(\d+):(\d+)(?:[.:](\d{1,3}))?\]`)
	enhancedLRCMarkerRe = regexp.MustCompile(`<(\d+):(\d+)(?:[.:](\d{1,3}))?>`)
)

func enhancedLRCMs(m []string) int {
	mm, _ := strconv.Atoi(m[1])
	ss, _ := strconv.Atoi(m[2])
	frac := 0
	if m[3] != "" {
		frac, _ = strconv.Atoi(m[3])
		for i := len(m[3]); i < 3; i++ {
			frac *= 10
		}
	}
	return mm*60000 + ss*1000 + frac
}

// enhancedLRCToYRC:增强 LRC 转成 YRC 语法。两个时间标记之间的文字是一个词,从前一个标记唱到后一个;
// 两个标记挨着(中间没字)是一段空档;最后一个标记是这一行的终点。没有标记的行整行算一个词,唱到下一行的起点。
// 不带时间戳的行(标签行)原样留着。
func enhancedLRCToYRC(body string) string {
	type line struct {
		raw   string
		timed bool
		start int
		text  string
		marks [][2]int // 标记在 text 里的 [起, 止] 下标
		times []int
	}
	var lines []line
	for _, raw := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		m := enhancedLRCLineRe.FindStringSubmatch(raw)
		if m == nil {
			lines = append(lines, line{raw: raw})
			continue
		}
		l := line{timed: true, start: enhancedLRCMs(m), text: raw[len(m[0]):]}
		for _, loc := range enhancedLRCMarkerRe.FindAllStringSubmatchIndex(l.text, -1) {
			l.marks = append(l.marks, [2]int{loc[0], loc[1]})
			l.times = append(l.times, enhancedLRCMs([]string{"", l.text[loc[2]:loc[3]], l.text[loc[4]:loc[5]], substrOrEmpty(l.text, loc[6], loc[7])}))
		}
		lines = append(lines, l)
	}
	nextStart := func(i int) int {
		for j := i + 1; j < len(lines); j++ {
			if lines[j].timed && lines[j].start > lines[i].start {
				return lines[j].start
			}
		}
		return lines[i].start + wordTimedTailCapMs
	}
	var out []string
	for i, l := range lines {
		if !l.timed {
			out = append(out, l.raw)
			continue
		}
		if len(l.marks) == 0 {
			text := strings.TrimSpace(l.text)
			end := nextStart(i)
			if text == "" {
				out = append(out, fmt.Sprintf("[%d,%d]", l.start, end-l.start))
				continue
			}
			out = append(out, fmt.Sprintf("[%d,%d](%d,%d,0)%s", l.start, end-l.start, l.start, end-l.start, text))
			continue
		}
		var b strings.Builder
		lead := l.text[:l.marks[0][0]]
		end := l.times[len(l.times)-1]
		fmt.Fprintf(&b, "[%d,%d]", l.start, max(end-l.start, 0))
		for k := 0; k+1 < len(l.marks); k++ {
			text := l.text[l.marks[k][1]:l.marks[k+1][0]]
			if k == 0 {
				text = lead + text
			}
			if text == "" {
				continue
			}
			fmt.Fprintf(&b, "(%d,%d,0)%s", l.times[k], max(l.times[k+1]-l.times[k], 0), text)
		}
		// 最后一个标记后面还有字(没写终点的写法):这个词唱到下一行的起点。
		if tail := l.text[l.marks[len(l.marks)-1][1]:]; tail != "" {
			t := l.times[len(l.times)-1]
			fmt.Fprintf(&b, "(%d,%d,0)%s", t, max(nextStart(i)-t, 0), tail)
		}
		out = append(out, b.String())
	}
	return strings.Join(out, "\n")
}

func substrOrEmpty(s string, a, b int) string {
	if a < 0 || b < 0 {
		return ""
	}
	return s[a:b]
}

type ttmlLyricsFileHead struct {
	File struct {
		Ar     string `xml:"ar,attr"`
		Ti     string `xml:"ti,attr"`
		Al     string `xml:"al,attr"`
		Source string `xml:"source,attr"`
		Manual string `xml:"manual,attr"`
	} `xml:"head>metadata>file"`
}

func decodeTTMLWordText(plain string) lyricsWordFileParsed {
	var head ttmlLyricsFileHead
	if err := xml.Unmarshal([]byte(plain), &head); err != nil {
		return lyricsWordFileParsed{}
	}
	r, ok := parseTTMLLyrics(plain, "", false)
	if !ok {
		return lyricsWordFileParsed{}
	}
	p := parsedLyricsFile{
		artist: head.File.Ar, title: head.File.Ti, album: head.File.Al,
		source: head.File.Source, manual: head.File.Manual == "1",
		body: strings.TrimSuffix(r.yrc, "\n"),
	}
	p.ok = p.title != ""
	return lyricsWordFileParsed{parsedLyricsFile: p, bg: strings.TrimSuffix(r.bg, "\n"), hasBG: true}
}

// lyricsWordFileMatches:文件字节是不是按 in 导出的那一份(比明文:加密那两种每次压缩、补齐出来的字节不必一样)。
func lyricsWordFileMatches(f lyricsWordFormat, data []byte, in lyricsWordFileInput) bool {
	plain, ok := openLyricsWordFile(f, data)
	return ok && plain == encodeLyricsWordText(f, in)
}

// lyricsAllFileSuffixes:歌词文件夹里这边会写的全部后缀(逐行三种 + 每种逐字格式)。
func lyricsAllFileSuffixes() []string {
	out := append([]string(nil), lyricsFileSuffixes[:3]...)
	for _, f := range lyricsWordFormatsAll {
		out = append(out, f.suffix())
	}
	return out
}

// lyricsWordFileRecognized:这份逐字文件是不是这边导出的写法(解得开、认得出头部)。
func lyricsWordFileRecognized(f lyricsWordFormat, data []byte) bool {
	plain, ok := openLyricsWordFile(f, data)
	return ok && decodeLyricsWordText(f, plain).ok
}

// lyricsFileRecognized:按文件名后缀认这份文件是不是这边导出的。
func lyricsFileRecognized(name string, data []byte) bool {
	if f, ok := lyricsWordFormatOfSuffix(lyricsFileSuffixOf(name)); ok {
		return lyricsWordFileRecognized(f, data)
	}
	return parseLyricsBytes(data).ok
}

// lyricsWordFileFormatVersion:各格式写法的版本,算进 lyricsWordFileSource。encode* 改了、同样的缓存会写出不一样的文件时加一,
// 不然文件状态记录里旧的指纹还对得上,文件不会重写。
const lyricsWordFileFormatVersion = 1

// lyricsWordFileSource:写格式 f 的逐字文件时用的缓存内容的指纹(恒不为 0)。括号背景人声接回的写法(parenBGFileFormVersion)
// 也算进来:它变了,接回之后的逐字跟着变。
func lyricsWordFileSource(f lyricsWordFormat, header, source, lrc, yrc, bg string, durationSecs float64) uint32 {
	c := crc32.ChecksumIEEE([]byte{lyricsWordFileFormatVersion, parenBGFileFormVersion})
	for _, s := range []string{string(f), header, source, lrc, yrc, bg} {
		c = crc32.Update(c, crc32.IEEETable, []byte(s))
		c = crc32.Update(c, crc32.IEEETable, []byte{0})
	}
	if f == lyricsWordQRC {
		c = crc32.Update(c, crc32.IEEETable, []byte(strconv.Itoa(int(durationSecs+0.5))))
	}
	if c == 0 {
		c = 1
	}
	return c
}

// lyricsWordFileEncodes:导出时真的编码了的逐字文件数(没变的文件按指纹跳过,不算)。全量导出结束时有就记一行日志。
var lyricsWordFileEncodes atomic.Int64

// lyricsWordFormatsApplied:歌词文件夹眼下按哪几种格式写的(导入以其中第一个为准、导出写这几种)。为 nil 时跟设置走。
// 设置在运行中改了,由 switchLyricsWordFormats 先按旧的导入一遍、再换成新的、整份导出。
var lyricsWordFormatsApplied atomic.Pointer[[]lyricsWordFormat]

// lyricsWordFormatsInUse 至少有一个(主格式在最前):设置快照没经过 resolveLyricsWordFormats(一次性子命令、单测)时只写 YRC。
func lyricsWordFormatsInUse() []lyricsWordFormat {
	if p := lyricsWordFormatsApplied.Load(); p != nil && len(*p) > 0 {
		return *p
	}
	if fs := features().LyricsWordFormats; len(fs) > 0 {
		return fs
	}
	return []lyricsWordFormat{lyricsWordYRC}
}

// importedWordFile:导入时读到的一份逐字文件。
type importedWordFile struct {
	plain  string
	parsed lyricsWordFileParsed
}

// pickImportedWordFile:这一组里逐字以哪种格式的文件为准。主格式(lyricsWordFormatsInUse 的第一个)那份读得出就用它,
// 不然按 lyricsWordFormatsAll 的先后取第一份读得出的。variantBody 按后缀判这份文件头部是不是这一首。
func pickImportedWordFile(words map[lyricsWordFormat]importedWordFile, variantBody func(string) (string, bool)) (lyricsWordFormat, bool) {
	order := append([]lyricsWordFormat{lyricsWordFormatsInUse()[0]}, lyricsWordFormatsAll...)
	for _, f := range order {
		if _, ok := words[f]; !ok {
			continue
		}
		if _, ok := variantBody(f.suffix()); ok {
			return f, true
		}
	}
	return "", false
}

// withWordBodyAsYRC:让 variantBody(".yrc") 取的是 suffix 那份逐字文件(已经转成 YRC 语法)。后面的导入逻辑都按 .yrc 写。
func withWordBodyAsYRC(variantBody func(string) (string, bool), suffix string) func(string) (string, bool) {
	return func(s string) (string, bool) {
		if s == ".yrc" {
			return variantBody(suffix)
		}
		return variantBody(s)
	}
}

// importedWordFileUnchanged:这份逐字文件还是按缓存导出的那一份(明文一样)。fileYRC 是括号背景人声接回之后的逐字,
// hasFileForm 为 false 时用缓存原样的。
func importedWordFileUnchanged(w importedWordFile, f lyricsWordFormat, key string, e enrichEntry, fileYRC string, hasFileForm bool) bool {
	if e.LyricsYRC.IsZero() {
		return false
	}
	if !hasFileForm {
		fileYRC = e.LyricsYRC.String()
	}
	return w.plain == encodeLyricsWordText(f, lyricsWordInputOf(key, e, fileYRC))
}

// lyricsWordInputOf:按缓存条目拼导出逐字文件要用的内容,fileYRC 是写进文件的逐字(括号背景人声接回之后的)。
func lyricsWordInputOf(key string, e enrichEntry, fileYRC string) lyricsWordFileInput {
	artist, title, album := splitEnrichKey(key)
	return lyricsWordFileInput{artist: artist, title: title, album: album, source: e.LyricsSource, manual: e.ManualLyrics,
		yrc: fileYRC, nativeYRC: e.LyricsYRC.String(), bg: e.LyricsBG.String(), durationSecs: e.DurationSecs}
}

// lyricsFileIdentity:按后缀把一份歌词文件的头部读出来(逐字各格式先解开)。
func lyricsFileIdentity(suffix string, data []byte) parsedLyricsFile {
	if f, ok := lyricsWordFormatOfSuffix(suffix); ok {
		plain, opened := openLyricsWordFile(f, data)
		if !opened {
			return parsedLyricsFile{}
		}
		return decodeLyricsWordText(f, plain).parsedLyricsFile
	}
	return parseLyricsBytes(data)
}

// lyricsWordEncoded:一份逐字文件编好的明文和文件字节。
type lyricsWordEncoded struct {
	plain  string
	sealed []byte
}

// encodeLyricsWordFile 编一份逐字文件,计入 lyricsWordFileEncodes。
func encodeLyricsWordFile(f lyricsWordFormat, in lyricsWordFileInput) lyricsWordEncoded {
	lyricsWordFileEncodes.Add(1)
	plain := encodeLyricsWordText(f, in)
	return lyricsWordEncoded{plain: plain, sealed: sealLyricsWordFile(f, plain)}
}

// lyricsWordJob:并行预编码时一条要导出的歌词。in.yrc 留空,由预编码按 lrc / nativeYRC / bg 接回括号背景人声再填。
type lyricsWordJob struct {
	base, header, lrc string
	in                lyricsWordFileInput
}

// lyricsWordPreEncoded:一条歌词预编好的逐字文件,和顺带算出的括号背景人声接回之后的正文 / 逐字(formed 为 true 时有)。
type lyricsWordPreEncoded struct {
	files            map[lyricsWordFormat]lyricsWordEncoded
	formed           bool
	fileLRC, fileYRC string
}

// preEncodeLyricsWordFiles 并行编好 n 条里要重写的逐字文件(按 formats 每种一份),结果按下标放。jobAt 给出第 i 条(没有逐字时 false);
// unchanged 判这份文件没动过、指纹也一样(不用编)。只用一半的核:导出跑在后台,别把整机占满。
func preEncodeLyricsWordFiles(n int, formats []lyricsWordFormat, jobAt func(int) (lyricsWordJob, bool),
	unchanged func(name string, src uint32) bool) []lyricsWordPreEncoded {
	out := make([]lyricsWordPreEncoded, n)
	next := atomic.Int64{}
	var wg sync.WaitGroup
	for w := 0; w < max(1, runtime.NumCPU()/2); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				job, ok := jobAt(i)
				if !ok {
					continue
				}
				p := &out[i]
				for _, f := range formats {
					src := lyricsWordFileSource(f, job.header, job.in.source, job.lrc, job.in.nativeYRC, job.in.bg, job.in.durationSecs)
					if unchanged(job.base+f.suffix(), src) {
						continue
					}
					if !p.formed {
						p.fileLRC, p.fileYRC = parenBGFileForm(job.in.source, job.lrc, job.in.nativeYRC, job.in.bg)
						p.formed = true
						p.files = map[lyricsWordFormat]lyricsWordEncoded{}
					}
					job.in.yrc = p.fileYRC
					p.files[f] = encodeLyricsWordFile(f, job.in)
				}
			}
		}()
	}
	wg.Wait()
	return out
}
