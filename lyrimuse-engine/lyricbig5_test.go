package main

import (
	"errors"
	"testing"
)

// 「我愛你 不是說說而已 / 後來 終於在眼淚中明白」的 CP950 字节。「淚」的第二字节是 0x5C(反斜杠)。
const big5Lyrics = "[00:01.00]\xa7\xda\xb7R\xa7A \xa4\xa3\xacO\xbb\xa1\xbb\xa1\xa6\xd3\xa4w\x0a[00:02.00]\xab\xe1\xa8\xd3 \xb2\xd7\xa9\xf3\xa6b\xb2\xb4\xb2\x5c\xa4\xa4\xa9\xfa\xa5\xd5"

// Big5 的繁体歌词文件按 Big5 转(真调 iconv)。按 GB18030 转也「转得通」,出来的是「и稲」这种乱码。
func TestDecodeLyricBytesBig5(t *testing.T) {
	want := "[00:01.00]我愛你 不是說說而已\n[00:02.00]後來 終於在眼淚中明白"
	if text, ok := decodeLyricBytes([]byte(big5Lyrics)); !ok || text != want {
		t.Errorf("decodeLyricBytes(Big5) = %q, %v", text, ok)
	}
	// 引擎用 UTF-8 写的头部原样留,只转 Big5 那几行。
	file := "[ar:陳奕迅]\n[ti:後來]\n" + big5Lyrics
	if text, ok := decodeLyricBytes([]byte(file)); !ok || text != "[ar:陳奕迅]\n[ti:後來]\n"+want {
		t.Errorf("decodeLyricBytes(UTF-8 头部 + Big5) = %q, %v", text, ok)
	}
	// 用户自己的 Big5 文件,头部也是 Big5:歌词文件夹导入按头部认这首歌,本地 .lrc 走同一个解码。
	big5File := []byte("[ar:\xb3\xaf\xab\xb3\xa8\xb3]\x0a[ti:\xab\xe1\xa8\xd3]\x0a" + big5Lyrics)
	if p := parseLyricsBytes(big5File); p.artist != "陳奕迅" || p.title != "後來" {
		t.Errorf("歌词文件夹导入认头部: %+v", p)
	}
	if text, ok := decodeLocalLyricsFile(big5File); !ok || text != "[ar:陳奕迅]\n[ti:後來]\n"+want {
		t.Errorf("decodeLocalLyricsFile(Big5) = %q, %v", text, ok)
	}
}

// GBK 正文不能被认成 Big5:认错会把原本转得对的文件转坏。
func TestLooksLikeBig5KeepsGBK(t *testing.T) {
	for name, gbk := range map[string]string{
		"歌曲名 稻香": "\xb8\xe8\xc7\xfa\xc3\xfb \xb5\xbe\xcf\xe3",
		// 拿希腊字母「Οο」当装饰:只集中在 A6 一行码位。
		"Οο 装饰": "[00:01.20]\xa6\xaf\xa6\xcf` \xb0\xae\xc4\xe3\xb5\xc8\xd3\xda\xb0\xae\xd7\xd4\xbc\xba\xec\xe1\xa5\xe1",
		// 希腊、西里尔字母一起当装饰,落在两行码位,靠「按 Big5 读常用字不到九成」挡住。
		"ΟοЯ 装饰": "[00:01.00]\xa6\xaf\xa6\xcf\xa7\xc1 \xd0\xc7\xb9\xe2\xb2\xd3\xc0\xc3 \xd2\xb9\xc9\xee\xc8\xcb\xbe\xb2 \xcb\xbc\xc4\xee\xc2\xfb\xd1\xd3",
		// 日文假名在 A4 / A5,不算怪字。
		"日文": "[00:03.00]\xbe\xfd\xa4\xce\xa4\xb3\xa4\xc8\xa4\xac\xba\xc3\xa4\xad\xa4\xc0\xa4\xab\xa4\xe9 \xa4\xb5\xa4\xe8\xa4\xca\xa4\xe9",
		// 俄语歌整行西里尔字母,全在 A7 一行。
		"俄语": "[00:04.00]\xa7\xc1 \xa7\xe1\xa7\xe0\xa7\xde\xa7\xdf\xa7\xf0 \xa7\xe9\xa7\xe5\xa7\xd5\xa7\xdf\xa7\xe0\xa7\xd6",
	} {
		if looksLikeBig5([]byte(gbk)) {
			t.Errorf("%s:GBK 被认成了 Big5", name)
		}
	}
	if !looksLikeBig5([]byte(big5Lyrics)) {
		t.Error("Big5 没认出来")
	}
	if !looksLikeBig5([]byte("[00:05.00]\xab\xe1\xa8\xd3")) {
		t.Error("只有「後來」两个字的 Big5 行也该认出来")
	}
}

// 看着像 Big5、按 Big5 却转不了(CP950 里没有的字),退回 GB18030,不直接判失败。
func TestDecodeLyricBytesBig5FallsBackToGB18030(t *testing.T) {
	savedGB, savedBig5 := gb18030ToUTF8, big5ToUTF8
	t.Cleanup(func() { gb18030ToUTF8, big5ToUTF8 = savedGB, savedBig5 })
	var order []string
	big5ToUTF8 = func([]byte) ([]byte, error) {
		order = append(order, "big5")
		return nil, errors.New("illegal byte sequence")
	}
	gb18030ToUTF8 = func([]byte) ([]byte, error) {
		order = append(order, "gb18030")
		return []byte("一\n二"), nil
	}
	text, ok := decodeLyricBytes([]byte(big5Lyrics))
	if !ok || text != "一\n二" {
		t.Errorf("退回 GB18030 后 = %q, %v", text, ok)
	}
	if len(order) != 2 || order[0] != "big5" || order[1] != "gb18030" {
		t.Errorf("转码顺序 = %v, 要先 Big5 再 GB18030", order)
	}
}
