package main

import "testing"

// 小数位按 App 侧 LRCParser 的规则:补齐 / 截断到 3 位再当毫秒。1 位小数原来被读成 ×10ms。
func TestLRCFracMsMatchesApp(t *testing.T) {
	cases := map[string]int{"": 0, "5": 500, "05": 50, "50": 500, "123": 123, "1234": 123, "0": 0}
	for in, want := range cases {
		if got := lrcFracMs(in); got != want {
			t.Errorf("lrcFracMs(%q) = %d, want %d", in, got, want)
		}
	}
	m := lrcTimestampCaptureRe.FindStringSubmatch("[01:02.5]x")
	if m == nil || lrcStampMs(m) != 62500 {
		t.Errorf("lrcStampMs([01:02.5]) = %v, want 62500", m)
	}
}
