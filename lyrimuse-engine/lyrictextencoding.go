package main

import (
	"bytes"
	"context"
	"os/exec"
	"strings"
	"time"
	"unicode/utf8"
)

// 歌词文本进缓存之前必须是合法 UTF-8。正文小文件按 encoding/json 落盘,它把每个非法字节换成 U+FFFD;内存里那份
// 要是还带着非法字节,按原样算出的正文校验值就跟读回来的内容永远对不上,每次启动都判成损坏。

// decodeLyricBytes 把一份歌词文件的字节转成文本:合法 UTF-8 原样用;不是的话按行判 —— 合法 UTF-8 的行原样留,
// 其余的行按 GB18030(GBK 的超集,咪咕个别文件是这个编码)转,看着像 Big5 的先按 Big5 转(looksLikeBig5),看着像日文
// Shift_JIS、韩文 EUC-KR 的先按它们转(looksLikeShiftJIS / looksLikeEUCKR);还转不了就把非法字节换成 U+FFFD。
// ok=false = 有的行哪种都转不了。
//
// 别整份转:一份文件可能只有一部分是 GBK(引擎用 UTF-8 写的头部和正文里混进了一段咪咕的 GBK 译文),整份按 GB18030
// 转会把 UTF-8 的中文歌手名、歌名也转成乱码,而歌词文件夹导入拿主歌词文件的头部当这首歌的身份,乱码身份会新建
// 一条幽灵条目。按换行切开不会切坏字:GB18030 和 Big5 的多字节序列里都没有 0x0A。
//
// 转出来的文本再去掉控制字符(stripLyricControlChars)。
func decodeLyricBytes(data []byte) (text string, ok bool) {
	text, ok = decodeLyricBytesRaw(data)
	return stripLyricControlChars(text), ok
}

func decodeLyricBytesRaw(data []byte) (text string, ok bool) {
	if utf8.Valid(data) {
		return string(data), true
	}
	lines := bytes.Split(data, []byte("\n"))
	var bad []int
	for i, l := range lines {
		if !utf8.Valid(l) {
			bad = append(bad, i)
		}
	}
	src := make([][]byte, len(bad))
	for j, i := range bad {
		src[j] = lines[i]
	}
	// 坏行拼在一起只起一次转码进程;转出来的行数对不上就当没转成。
	joined := bytes.Join(src, []byte("\n"))
	converters := []func([]byte) ([]byte, error){gb18030ToUTF8}
	switch {
	case looksLikeShiftJIS(joined):
		converters = []func([]byte) ([]byte, error){shiftJISToUTF8, gb18030ToUTF8}
	case looksLikeEUCKR(joined):
		converters = []func([]byte) ([]byte, error){eucKRToUTF8, gb18030ToUTF8}
	case looksLikeBig5(joined):
		converters = []func([]byte) ([]byte, error){big5ToUTF8, gb18030ToUTF8}
	}
	for _, convert := range converters {
		out, err := convert(joined)
		if err != nil || !utf8.Valid(out) {
			continue
		}
		if conv := bytes.Split(out, []byte("\n")); len(conv) == len(bad) {
			for j, i := range bad {
				lines[i] = conv[j]
			}
			return string(bytes.Join(lines, []byte("\n"))), true
		}
	}
	return jsonSafeString(string(data)), false
}

// looksLikeBig5:不是 UTF-8 的这几行是不是 Big5(繁体老歌词文件常见的编码)。Big5 按 GB18030 转大多也转得通、只是满屏怪字,
// 转码成不成判不出来,只能看双字节的首字节落在哪一行码位:
//   - 按 GB 读落进希腊、西里尔、拼音注音、制表符、自造字区(首字节 A6–AF、F8–FE)的占 5% 以上,且不止一行码位。Big5 最常用的
//     字正好排在 A4–AF;GBK 正文里这几行少见,出现也只集中在一行(俄语歌的西里尔字母、拿「Οο」当装饰)。
//   - 按 Big5 读,第一级常用字(首字节 A4–C6)占 90% 以上。GBK 的常用字按 Big5 读有一半落在第二级(C9–F9)。
//
// 两条缺一条都按 GB18030 转:认错 GBK 会把原本转得对的文件转坏,漏认 Big5 只是维持原样。依据见 09 章决策 312。
func looksLikeBig5(b []byte) bool {
	var pairs, odd, level1, level2, oddRows int
	var seenRow [256]bool
	for i := 0; i < len(b); {
		c := b[i]
		if c < 0x80 {
			i++
			continue
		}
		if i+1 >= len(b) {
			break
		}
		// GB18030 的四字节序列(第二字节是数字),Big5 里没有这种形状。
		if n := b[i+1]; n >= 0x30 && n <= 0x39 {
			i += 4
			continue
		}
		pairs++
		if c >= 0xA6 && c <= 0xAF || c >= 0xF8 {
			odd++
			if !seenRow[c] {
				seenRow[c] = true
				oddRows++
			}
		}
		switch {
		case c >= 0xA4 && c <= 0xC6:
			level1++
		case c >= 0xC9 && c <= 0xF9:
			level2++
		}
		i += 2
	}
	return pairs > 0 && odd*20 >= pairs && oddRows >= 2 && level1+level2 > 0 && level1*10 >= (level1+level2)*9
}

// looksLikeShiftJIS:是不是日文 Shift_JIS。按 Shift_JIS 的字节结构走一遍(双字节首字节 81–9F、E0–FC,半角片假名 A1–DF
// 单字节),结构对不上就不是;平假名、片假名的首字节(82、83)占双字节的四分之一以上才算:日文歌词假名多,中文 GBK 正文
// 这两个首字节是生僻字区,几乎不出现。按 GB18030 转 Shift_JIS 不报错、只是满屏怪字,认不出来就会交出乱码。
func looksLikeShiftJIS(b []byte) bool {
	var pairs, kana int
	for i := 0; i < len(b); {
		c := b[i]
		switch {
		case c < 0x80 || (c >= 0xA1 && c <= 0xDF):
			i++
			continue
		case (c >= 0x81 && c <= 0x9F) || (c >= 0xE0 && c <= 0xFC):
			if i+1 >= len(b) {
				return false
			}
			if t := b[i+1]; t < 0x40 || t == 0x7F || t > 0xFC {
				return false
			}
			pairs++
			if c == 0x82 || c == 0x83 {
				kana++
			}
			i += 2
		default:
			return false
		}
	}
	return pairs >= 4 && kana*4 >= pairs
}

// looksLikeEUCKR:是不是韩文 EUC-KR(含 CP949 的扩展区)。标准区两个字节都在 A1–FE,韩文音节在首字节 B0–C8,韩文里的汉字
// 在 CA–FD;CP949 扩展区(首字节 81–C6、尾字节落在 41–5A、61–7A、81–A0)全是音节。韩文歌词几乎全是音节,中文 GBK 正文按
// 这张表读有一半上下落进汉字区,所以音节要占九成以上才算。短的中文(「告白气球」这类四个字的歌名)常常整串落在音节区,
// 所以音节少于 `eucKRMinSyllables` 个的不认:认错会把原本转得对的 GBK 转成韩文乱码,漏认只是维持原样(同 looksLikeBig5)。
func looksLikeEUCKR(b []byte) bool {
	var hangul, hanja int
	for i := 0; i < len(b); {
		c := b[i]
		if c < 0x80 {
			i++
			continue
		}
		if i+1 >= len(b) || c == 0x80 || c == 0xFF {
			return false
		}
		t := b[i+1]
		switch {
		case c >= 0xA1 && t >= 0xA1 && t <= 0xFE:
			switch {
			case c >= 0xB0 && c <= 0xC8:
				hangul++
			case c >= 0xCA && c <= 0xFD:
				hanja++
			}
		case c <= 0xC6 && (t >= 0x41 && t <= 0x5A || t >= 0x61 && t <= 0x7A || t >= 0x81 && t <= 0xFE):
			hangul++
		default:
			return false
		}
		i += 2
	}
	return hangul >= eucKRMinSyllables && hangul*10 >= (hangul+hanja)*9
}

// eucKRMinSyllables:认 EUC-KR 至少要的音节数。一句韩文歌词就有十几二十个音节。
const eucKRMinSyllables = 16

// gb18030ToUTF8 / big5ToUTF8 用系统自带的 iconv 转码:引擎不引入外部依赖,这条路只有遇到非 UTF-8 的歌词文件才走到。单测替换。
// Big5 按 CP950(微软的 Big5)转:Windows 上产出的繁体歌词文件多是它。
var gb18030ToUTF8 = func(data []byte) ([]byte, error) { return iconvToUTF8("GB18030", data) }

var big5ToUTF8 = func(data []byte) ([]byte, error) { return iconvToUTF8("CP950", data) }

// Shift_JIS 按 CP932、EUC-KR 按 CP949(都是微软的超集,Windows 上产出的文件多是它们)转。
var shiftJISToUTF8 = func(data []byte) ([]byte, error) { return iconvToUTF8("CP932", data) }

var eucKRToUTF8 = func(data []byte) ([]byte, error) { return iconvToUTF8("CP949", data) }

func iconvToUTF8(from string, data []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/iconv", "-f", from, "-t", "UTF-8")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Output()
}

// stripLyricControlChars 去掉歌词里的控制字符(U+0000～U+001F 里除换行、回车、制表符以外的,和 U+007F)。咪咕个别歌词
// 文件末尾带两个 NUL 字节,原样存下来会让 ListenBrainz 整条拒收:它不收任何字段里带 U+0000 的提交。见 09 章决策 308。
func stripLyricControlChars(s string) string {
	if strings.IndexFunc(s, isLyricControlChar) < 0 {
		return s
	}
	return strings.Map(func(r rune) rune {
		if isLyricControlChar(r) {
			return -1
		}
		return r
	}, s)
}

func isLyricControlChar(r rune) bool {
	return r < 0x20 && r != '\n' && r != '\r' && r != '\t' || r == 0x7f
}

// jsonSafeString 跟 encoding/json 编码字符串时一样,把每个非法 UTF-8 字节各换成一个 U+FFFD。
// 别换成 strings.ToValidUTF8:它把一整段连续的非法字节只换成一个,跟 json 落盘的结果对不上。
func jsonSafeString(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) + 8)
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && n == 1 {
			b.WriteString("�")
		} else {
			b.WriteString(s[i : i+n])
		}
		i += n
	}
	return b.String()
}
