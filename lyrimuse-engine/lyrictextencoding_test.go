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
