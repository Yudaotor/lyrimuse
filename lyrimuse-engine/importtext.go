package main

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"
)

// 导入歌词文件的文本整理(importlyrics.go 用):转码前的字节整理、LyricsX(.lrcx)的译文与逐字行、有没有真的歌词行。

// importNormalizeText:文本类文件转码前的整理。带 BOM 的 UTF-16 转成 UTF-8(Windows 记事本存的「Unicode」);末尾补齐用的
// NUL 去掉(有的播放器导出的文件这样补位);换行统一成 \n(只用 CR 换行的老文件)。去掉末尾 NUL 之后中间还有 NUL 的是二进制
// (加密的逐字文件、拖错的音频),原样交回,别动它的字节。
func importNormalizeText(data []byte) []byte {
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xFE}):
		return importNormalizeText(decodeUTF16(data[2:], false))
	case bytes.HasPrefix(data, []byte{0xFE, 0xFF}):
		return importNormalizeText(decodeUTF16(data[2:], true))
	}
	trimmed := bytes.TrimRight(data, "\x00")
	if bytes.IndexByte(trimmed, 0) >= 0 {
		return data
	}
	if bytes.IndexByte(trimmed, '\r') >= 0 {
		trimmed = bytes.ReplaceAll(trimmed, []byte("\r\n"), []byte("\n"))
		trimmed = bytes.ReplaceAll(trimmed, []byte("\r"), []byte("\n"))
	}
	return trimmed
}

// decodeUTF16:UTF-16 字节(不含 BOM)转成 UTF-8。奇数长度时最后半个字丢掉。
func decodeUTF16(b []byte, bigEndian bool) []byte {
	units := make([]uint16, len(b)/2)
	for i := range units {
		if bigEndian {
			units[i] = uint16(b[2*i])<<8 | uint16(b[2*i+1])
		} else {
			units[i] = uint16(b[2*i+1])<<8 | uint16(b[2*i])
		}
	}
	return []byte(string(utf16.Decode(units)))
}

var (
	// importLeadingTagsRe:行首连着的方括号标签(时间戳、[offset:] 这类),数有没有歌词字的时候去掉。
	importLeadingTagsRe = regexp.MustCompile(`^(?:\s*\[[^\]]*\])+`)
	// importLyricsXExtraRe:LyricsX 的附加行,`[时间][tr:语言]译文` 或 `[时间][tt]<偏移,字位>…<行长>`。
	importLyricsXExtraRe = regexp.MustCompile(`^\s*\[(\d+):(\d+)(?:[.:](\d{1,3}))?\]\[(tr:[^\]]*|tt)\](.*)$`)
	importLyricsXMainRe  = regexp.MustCompile(`^\s*\[(\d+):(\d+)(?:[.:](\d{1,3}))?\](.*)$`)
	importLyricsXWordRe  = regexp.MustCompile(`<(\d+),(\d+)>`)
	importLyricsXEndRe   = regexp.MustCompile(`<(\d+)>\s*$`)
)

// importHasLyricText:有没有一行真的歌词字(去掉行首的时间戳和标签之后不是空的)。只有标签、只有时间戳的文件不算。
func importHasLyricText(text string) bool {
	for _, l := range strings.Split(text, "\n") {
		if strings.TrimSpace(importLeadingTagsRe.ReplaceAllString(l, "")) != "" {
			return true
		}
	}
	return false
}

// importStampMs:LRC 时间戳的三段(分、秒、小数)换成毫秒,小数按右补零取三位。
func importStampMs(min, sec, frac string) int {
	m, _ := strconv.Atoi(min)
	s, _ := strconv.Atoi(sec)
	f := 0
	if frac != "" {
		f, _ = strconv.Atoi((frac + "00")[:3])
	}
	return m*60000 + s*1000 + f
}

func importAngleStamp(ms int) string {
	return "<" + strings.Trim(lrcTimestamp(ms), "[]") + ">"
}

// splitLyricsXLRC:LyricsX 的 .lrcx 正文拆成正文、译文,逐字行([tt])换成增强 LRC 的行内时间戳并进正文那一行
// (交给 splitWordTimedLRC 出逐字)。不是 LyricsX 的写法时 ok=false,原样交回。
func splitLyricsXLRC(body string) (lrc, tr string, ok bool) {
	lines := strings.Split(body, "\n")
	type extra struct {
		tr string
		tt string
	}
	extras := map[int]*extra{}
	for _, l := range lines {
		m := importLyricsXExtraRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		ok = true
		at := importStampMs(m[1], m[2], m[3])
		e := extras[at]
		if e == nil {
			e = &extra{}
			extras[at] = e
		}
		if m[4] == "tt" {
			e.tt = m[5]
		} else if e.tr == "" {
			e.tr = strings.TrimSpace(m[5])
		}
	}
	if !ok {
		return body, "", false
	}
	var mainOut, trOut []string
	for _, l := range lines {
		if importLyricsXExtraRe.MatchString(l) {
			continue
		}
		m := importLyricsXMainRe.FindStringSubmatch(l)
		if m == nil {
			mainOut = append(mainOut, l)
			continue
		}
		at := importStampMs(m[1], m[2], m[3])
		text := m[4]
		e := extras[at]
		if e != nil && e.tr != "" {
			trOut = append(trOut, lrcTimestamp(at)+e.tr)
		}
		if e != nil && e.tt != "" {
			if timed, good := lyricsXWordLine(at, text, e.tt); good {
				mainOut = append(mainOut, lrcTimestamp(at)+timed)
				continue
			}
		}
		mainOut = append(mainOut, l)
	}
	return strings.Join(mainOut, "\n"), strings.Join(trOut, "\n"), true
}

// lyricsXWordLine:LyricsX 一行的逐字(`<偏移毫秒,字位>…<行长毫秒>`,字位从 0 数,按字符算)换成增强 LRC 的
// `<时间>字<时间>字…<行末>`。字位不递增、超出这一行时 good=false。
func lyricsXWordLine(start int, text, tt string) (string, bool) {
	runes := []rune(text)
	marks := importLyricsXWordRe.FindAllStringSubmatch(tt, -1)
	end := importLyricsXEndRe.FindStringSubmatch(tt)
	if len(marks) == 0 || end == nil {
		return "", false
	}
	type mark struct{ off, idx int }
	var ms []mark
	for _, m := range marks {
		off, _ := strconv.Atoi(m[1])
		idx, _ := strconv.Atoi(m[2])
		if idx > len(runes) || (len(ms) > 0 && (idx < ms[len(ms)-1].idx || off < ms[len(ms)-1].off)) {
			return "", false
		}
		ms = append(ms, mark{off, idx})
	}
	total, _ := strconv.Atoi(end[1])
	if total < ms[len(ms)-1].off {
		total = ms[len(ms)-1].off
	}
	var b strings.Builder
	if ms[0].idx > 0 {
		b.WriteString(string(runes[:ms[0].idx]))
	}
	for i, m := range ms {
		next := len(runes)
		if i+1 < len(ms) {
			next = ms[i+1].idx
		}
		if next == m.idx {
			continue
		}
		b.WriteString(importAngleStamp(start + m.off))
		b.WriteString(string(runes[m.idx:next]))
	}
	b.WriteString(importAngleStamp(start + total))
	return b.String(), true
}

// importCompanionMatches:译文 / 读音文件配不配这份正文:去掉后缀的文件名相同(不分大小写)。
func importCompanionMatches(main, companion string) bool {
	return strings.EqualFold(importStem(main), importStem(companion))
}
