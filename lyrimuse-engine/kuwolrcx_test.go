package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"strings"
	"testing"
)

// kuwoEncodeLrcxForTest 按接口的封装方式把明文包回响应体:异或 → base64 → zlib → 加头。
func kuwoEncodeLrcxForTest(t *testing.T, text string) []byte {
	t.Helper()
	data := []byte(text)
	key := []byte(kuwoLrcxKey)
	for i := range data {
		data[i] ^= key[i%len(key)]
	}
	var z bytes.Buffer
	w := zlib.NewWriter(&z)
	if _, err := w.Write([]byte(base64.StdEncoding.EncodeToString(data))); err != nil {
		t.Fatal(err)
	}
	w.Close()
	return append([]byte("tp=content\r\nlrcx=1\r\n\r\n"), z.Bytes()...)
}

func TestKuwoDecodeLrcxRoundTrip(t *testing.T) {
	text := "[kuwo:071]\n[00:19.205]<1183,-1183>I <2231,-541>never\n"
	got, err := kuwoDecodeLrcx(kuwoEncodeLrcxForTest(t, text))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got != text {
		t.Fatalf("got %q, want %q", got, text)
	}
	if _, err := kuwoDecodeLrcx([]byte("<html>blocked</html>")); err == nil {
		t.Fatal("non-lrcx body must fail")
	}
}

func TestKuwoLrcxCoefficients(t *testing.T) {
	cases := []struct {
		header string
		k1, k2 int
		ok     bool
	}{
		{"[kuwo:071]", 5, 7, true}, // 八进制 071 = 57
		{"[kuwo:060]", 4, 8, true},
		{"[kuwo:052]", 4, 2, true},
		{"[kuwo:010]", 0, 8, false},
		{"[ti:no header]", 0, 0, false},
	}
	for _, c := range cases {
		k1, k2, ok := kuwoLrcxCoefficients("[ver:v1.0]\n" + c.header + "\n")
		if ok != c.ok || (ok && (k1 != c.k1 || k2 != c.k2)) {
			t.Errorf("%s: got (%d,%d,%v), want (%d,%d,%v)", c.header, k1, k2, ok, c.k1, c.k2, c.ok)
		}
	}
}

func TestKuwoLrcxToYRC(t *testing.T) {
	text := strings.Join([]string{
		"[ml:1.0]",
		"[kuwo:071]",
		"[ti:Purple Rain]",
		"[00:09.600]<0,0> <0,0> <0,0> ",
		"[00:19.205]<1183,-1183>I <2231,-541>never <2955,715>meant",
		"[00:27.326]<0,0>我<0,0>从<0,0>未",
		"[00:27.326]<1113,-1113>I <1915,-325>never",
	}, "\n")
	got := kuwoLrcxToYRC(text)
	lines := strings.Split(got, "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 original lines (translation / placeholder lines dropped), got %d:\n%s", len(lines), got)
	}
	// I: 起点 |0|/10 = 0,终点 |2366|/14 = 169;never: 起点 1690/10 = 169,终点 2772/14 + 169 = 367;
	// meant: 起点 3670/10 = 367,终点 2240/14 + 367 = 527。
	want0 := "[19205,527](19205,169,0)I (19374,198,0)never (19572,160,0)meant"
	if lines[0] != want0 {
		t.Errorf("line 0:\n got %s\nwant %s", lines[0], want0)
	}
	if !strings.HasPrefix(lines[1], "[27326,") || strings.Contains(lines[1], "我") {
		t.Errorf("line 1 must be the original line at 27326, got %s", lines[1])
	}
}

func TestKuwoLrcxToYRCTrimsOverlap(t *testing.T) {
	// k1=5、k2=7:甲 起点 0、终点 2800/14 = 200;乙 起点 1500/10 = 150、词长 1400/14 = 100。
	// 乙的起点早于甲的终点,甲截到 150。
	text := "[kuwo:071]\n[00:01.000]<1400,-1400>甲<1450,50>乙\n"
	want := "[1000,250](1000,150,0)甲(1150,100,0)乙"
	if got := kuwoLrcxToYRC(text); got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestKuwoLrcxToYRCWithoutCoefficients(t *testing.T) {
	if got := kuwoLrcxToYRC("[00:01.000]<500,500>甲\n"); got != "" {
		t.Fatalf("no [kuwo:] header must yield empty, got %q", got)
	}
	if got := kuwoLrcxToYRC("[kuwo:071]\n[00:01.000]<0,0>甲<0,0>乙\n"); got != "" {
		t.Fatalf("all-zero lines only must yield empty, got %q", got)
	}
}
