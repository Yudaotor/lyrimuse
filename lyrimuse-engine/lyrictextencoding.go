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
// 其余的行按 GB18030(GBK 的超集,咪咕个别文件是这个编码)转;还转不了就把非法字节换成 U+FFFD。ok=false = 有的行
// 既不是 UTF-8 也不是 GB18030。
//
// 别整份转:一份文件可能只有一部分是 GBK(引擎用 UTF-8 写的头部和正文里混进了一段咪咕的 GBK 译文),整份按 GB18030
// 转会把 UTF-8 的中文歌手名、歌名也转成乱码,而歌词文件夹导入拿主歌词文件的头部当这首歌的身份,乱码身份会新建
// 一条幽灵条目。按换行切开不会切坏字:GB18030 的多字节序列里没有 0x0A。
func decodeLyricBytes(data []byte) (text string, ok bool) {
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
	if out, err := gb18030ToUTF8(bytes.Join(src, []byte("\n"))); err == nil && utf8.Valid(out) {
		if conv := bytes.Split(out, []byte("\n")); len(conv) == len(bad) {
			for j, i := range bad {
				lines[i] = conv[j]
			}
			return string(bytes.Join(lines, []byte("\n"))), true
		}
	}
	return jsonSafeString(string(data)), false
}

// gb18030ToUTF8 用系统自带的 iconv 转码:引擎不引入外部依赖,这条路只有遇到非 UTF-8 的歌词文件才走到。单测替换。
var gb18030ToUTF8 = func(data []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/iconv", "-f", "GB18030", "-t", "UTF-8")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Output()
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
