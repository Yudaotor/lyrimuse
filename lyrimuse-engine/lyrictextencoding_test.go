package main

import (
	"encoding/json"
	"errors"
	"testing"
)

// 跟 encoding/json 落盘再读回来的结果逐字一致:每个非法字节各换成一个 U+FFFD。
func TestJSONSafeStringMatchesJSONRoundTrip(t *testing.T) {
	for _, s := range []string{
		"",
		"正常的中文 lyrics",
		"\xb8\xe8\xc7\xfa\xc3\xfb Trust",
		"a\xffb\xfe\xfdc",
		"尾巴断了\xe6\xad",
		"\xed\xa0\x80",
	} {
		data, err := json.Marshal(s)
		if err != nil {
			t.Fatal(err)
		}
		var back string
		if err := json.Unmarshal(data, &back); err != nil {
			t.Fatal(err)
		}
		if got := jsonSafeString(s); got != back {
			t.Errorf("jsonSafeString(%q) = %q, json 读回来是 %q", s, got, back)
		}
	}
}

// GBK 编码的歌词文件用系统 iconv 转回 UTF-8。下面是「歌曲名 稻香」的 GBK 字节。
func TestDecodeLyricBytesGB18030(t *testing.T) {
	gbk := []byte{0xb8, 0xe8, 0xc7, 0xfa, 0xc3, 0xfb, ' ', 0xb5, 0xbe, 0xcf, 0xe3}
	if text, ok := decodeLyricBytes(gbk); !ok || text != "歌曲名 稻香" {
		t.Errorf("decodeLyricBytes(GBK) = %q, %v", text, ok)
	}
}

// 合法 UTF-8 原样返回、不起转码进程;转码失败时把非法字节换掉,并报告既不是 UTF-8 也不是 GB18030。
func TestDecodeLyricBytesFallbacks(t *testing.T) {
	saved := gb18030ToUTF8
	t.Cleanup(func() { gb18030ToUTF8 = saved })
	called := 0
	gb18030ToUTF8 = func([]byte) ([]byte, error) {
		called++
		return nil, errors.New("iconv failed")
	}
	if text, ok := decodeLyricBytes([]byte("[00:01.00]信任")); !ok || text != "[00:01.00]信任" || called != 0 {
		t.Errorf("合法 UTF-8 该原样返回且不转码: %q %v called=%d", text, ok, called)
	}
	if text, ok := decodeLyricBytes([]byte("a\xffb")); ok || text != "a�b" || called != 1 {
		t.Errorf("转不了时该把非法字节换掉: %q %v called=%d", text, ok, called)
	}
}

// 只转不合法的那几行:引擎用 UTF-8 写的中文头部(这首歌在歌词文件夹里的身份)原样留,混进来的 GBK 行转对。
// 整份按 GB18030 转的话,UTF-8 的「方大同」也会被当成 GBK 转成乱码。
func TestDecodeLyricBytesConvertsOnlyBadLines(t *testing.T) {
	gbk := []byte{0xb8, 0xe8, 0xc7, 0xfa, 0xc3, 0xfb, ' ', 0xb5, 0xbe, 0xcf, 0xe3} // 「歌曲名 稻香」
	file := append([]byte("[ar:方大同]\n[ti:苏丽珍]\n[al:爱爱爱]\n\n[00:01.00]"), gbk...)
	file = append(file, []byte("\r\n[00:02.00]你好")...)
	text, ok := decodeLyricBytes(file)
	if !ok || text != "[ar:方大同]\n[ti:苏丽珍]\n[al:爱爱爱]\n\n[00:01.00]歌曲名 稻香\r\n[00:02.00]你好" {
		t.Fatalf("decodeLyricBytes(混合) = %q, %v", text, ok)
	}
	if p := parseLyricsBytes(file); !p.ok || p.artist != "方大同" || p.title != "苏丽珍" || p.album != "爱爱爱" {
		t.Errorf("头部身份该原样留: %+v", p)
	}
}

// 坏行拼在一起只起一次转码;转出来的行数对不上就当没转成,按 json 的口径换掉非法字节。
func TestDecodeLyricBytesOneConversionForAllBadLines(t *testing.T) {
	saved := gb18030ToUTF8
	t.Cleanup(func() { gb18030ToUTF8 = saved })
	var calls []string
	gb18030ToUTF8 = func(b []byte) ([]byte, error) {
		calls = append(calls, string(b))
		return []byte("一\n二"), nil
	}
	text, ok := decodeLyricBytes([]byte("好\n\xb0\n中\n\xb1"))
	if !ok || text != "好\n一\n中\n二" || len(calls) != 1 || calls[0] != "\xb0\n\xb1" {
		t.Errorf("text=%q ok=%v calls=%q", text, ok, calls)
	}
	gb18030ToUTF8 = func([]byte) ([]byte, error) { return []byte("只有一行"), nil }
	if text, ok := decodeLyricBytes([]byte("好\n\xb0\n\xb1")); ok || text != "好\n�\n�" {
		t.Errorf("行数对不上该走兜底: %q %v", text, ok)
	}
}
