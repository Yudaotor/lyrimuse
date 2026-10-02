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

// decodeLyricBytes 把一份歌词文件的字节转成文本:合法 UTF-8 原样用;不是就按 GB18030(GBK 的超集,咪咕个别文件
// 是这个编码)转;还转不了就把非法字节换成 U+FFFD。ok=false = 既不是 UTF-8 也不是 GB18030。
func decodeLyricBytes(data []byte) (text string, ok bool) {
	if utf8.Valid(data) {
		return string(data), true
	}
	if out, err := gb18030ToUTF8(data); err == nil && utf8.Valid(out) {
		return string(out), true
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
