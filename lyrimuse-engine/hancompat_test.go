package main

import (
	"testing"
	"unicode/utf8"
)

func TestNormalizeHanCompat(t *testing.T) {
	cases := []struct{ in, want string }{
		{"我看⾒這裡有⼈", "我看見這裡有人"},
		{"如果⻘春", "如果青春"},
		{"溺れて", "溺れて"},
		{"没有同形异码字 plain", "没有同形异码字 plain"},
		{"", ""},
	}
	for _, c := range cases {
		if got := normalizeHanCompat(c.in); got != c.want {
			t.Errorf("normalizeHanCompat(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 每个字换成一个字:注音按字数对齐,换完字数不能变。
func TestHanCompatTableOneToOne(t *testing.T) {
	if n := utf8.RuneCountInString(hanCompatPairs); n%2 != 0 {
		t.Fatalf("hanCompatPairs 字数 %d 不是偶数", n)
	}
	for from, to := range hanCompatTable {
		if !hanCompatInRange(from) {
			t.Errorf("%U 不在三个区段里", from)
		}
		if hanCompatInRange(to) && to < 0xF900 {
			t.Errorf("%U 换成的 %U 仍是部首", from, to)
		}
	}
}

func TestIsCreditLineHanCompat(t *testing.T) {
	for _, line := range []string{"制作⼈：陶喆", "录⾳：强力录音室"} {
		if !isCreditLine(line) {
			t.Errorf("isCreditLine(%q) = false, want true", line)
		}
	}
	if !isRelaxedCreditLine("录⾳ : 甲", nil) {
		t.Errorf("isRelaxedCreditLine 没认出同形异码字的署名行")
	}
}

func TestFoldHanLookalikes(t *testing.T) {
	cases := []struct{ in, want string }{
		{"給我ㄧ首歌的時間", "給我一首歌的時間"},
		{"ㄧ起走", "一起走"},
		{"走ㄧ", "走一"},
		{"⽩", "白"},
		{"ㄅㄆㄇ ㄧ", "ㄅㄆㄇ ㄧ"},
		{"ㄧ", "ㄧ"},
		{"Song ㄧ", "Song ㄧ"},
		{"plain", "plain"},
	}
	for _, c := range cases {
		if got := foldHanLookalikes(c.in); got != c.want {
			t.Errorf("foldHanLookalikes(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
