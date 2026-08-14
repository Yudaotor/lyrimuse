package main

import "testing"

// 守的是「歌词管理里出现看不出差别的重复歌」那个真实故障(2026-08-14)。用例取自用户机器上
// 真实存在的两条缓存 key 和两个导出文件名。
//
// 不可见字符一律写成转义,绝不写字面量。两个理由:字面 BOM 会让 Go 直接拒绝编译整个文件
// ("illegal byte order mark",实测踩过);字面 NBSP 在 review 时跟普通空格长得一模一样 ——
// 这个测试要守的恰恰就是"看不出差别"这件事,源码本身不该重蹈覆辙。
func TestCleanMediaTag_StripsInvisibleWhitespace(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"尾部 NBSP", "偷笑\u00a0", "偷笑"},
		{"尾部 NBSP(带感叹号)", "唉!\u00a0", "唉!"},
		{"中段 NBSP", "A\u00a0B", "A B"},
		{"全角空格", "A\u3000B", "A B"},
		{"窄不换行空格", "A\u202fB", "A B"},
		{"零宽字符直接删", "A\u200bB", "AB"},
		{"BOM 直接删", "\ufeffABC", "ABC"},
		{"连续空白折成一个", "A   B", "A B"},
		{"首尾空白去掉", "  ABC  ", "ABC"},
		{"空串原样返回", "", ""},
		{"大小写不动", "PRINCE", "PRINCE"},
		{"正常标题不受影响", "I Wanna Be Your Lover", "I Wanna Be Your Lover"},
		{"中文标题不受影响", "四人游", "四人游"},
	}
	for _, c := range cases {
		if got := cleanMediaTag(c.in); got != c.want {
			t.Errorf("%s: cleanMediaTag(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

// 洗过之后,那对真实的重复 key 必须塌缩成同一个 —— 这才是修复真正要达成的效果。
func TestCleanMediaTag_CollapsesTheRealDuplicateKeys(t *testing.T) {
	key := func(artist, title, album string) string {
		return cleanMediaTag(artist) + "|" + cleanMediaTag(title) + "|" + cleanMediaTag(album)
	}
	if a, b := key("方大同", "偷笑", "爱爱爱"), key("方大同", "偷笑\u00a0", "爱爱爱"); a != b {
		t.Fatalf("两条真实重复 key 洗完仍不相等:\n  %q\n  %q", a, b)
	}
}
