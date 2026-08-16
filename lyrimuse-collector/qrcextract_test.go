package main

import "testing"

// 2026-08-16 实测回归:QQ 的 QRC 正文里**有字面双引号、且不转义成 &quot;**。
// 原来的非贪婪正则 `LyricContent="(.*?)"` 会在第一个引号处收尾,PRINCE - Little Red
// Corvette 的 8508 字节正文只截出 1604 字节(丢 81%)。表现是"标着有逐字,前半段有效果、
// 后面没了"——截断后的 YRC 仍然非空,hasWordTiming 照样为真、打分照拿逐字加权。
func TestExtractQRCLyricContentKeepsLiteralQuotes(t *testing.T) {
	// 真实结构:LyricContent 是最后一个属性,后面紧跟自闭合
	xml := `<?xml version="1.0" encoding="utf-8"?>` + "\n" +
		`<QrcInfos><QrcHeadInfo SaveTime="1" Version="1"/><LyricInfo LyricCount="1">` +
		`<Lyric_1 LyricType="1" LyricContent="[48794,2069]And (48962,124)you say ` +
		`&quot;A&quot; "What have I got to lose" and more(1,2)` + "\n" +
		`[51000,900]last line(51000,900)` + "\n" +
		`"/>` + "\n</LyricInfo>\n</QrcInfos>"

	got := extractQRCLyricContent(xml)
	if got == "" {
		t.Fatal("截出空串")
	}
	// 关键:字面引号后面的内容必须还在
	for _, want := range []string{"What have I got to lose", "and more", "last line"} {
		if !contains(got, want) {
			t.Errorf("正文在字面引号处被截断了,丢了 %q\n实际截出: %q", want, got)
		}
	}
	// &quot; 该被反转义成真正的引号
	if !contains(got, `"A"`) {
		t.Errorf("&quot; 没有被反转义: %q", got)
	}
	// 结尾的 "/> 本身不该混进正文
	if contains(got, `"/>`) {
		t.Errorf("正文里混进了结构标记 \"/>: %q", got)
	}
}

// `" />`(引号和自闭合之间有空白)也要认。
func TestExtractQRCLyricContentToleratesSpaceBeforeSelfClose(t *testing.T) {
	xml := `<Lyric_1 LyricContent="[1,2]hi(1,2)" />`
	if got := extractQRCLyricContent(xml); got != "[1,2]hi(1,2)" {
		t.Errorf("got %q", got)
	}
}

func TestExtractQRCLyricContentMissing(t *testing.T) {
	if got := extractQRCLyricContent(`<QrcInfos><LyricInfo LyricCount="0"/></QrcInfos>`); got != "" {
		t.Errorf("没有 LyricContent 时应返回空串,得到 %q", got)
	}
	if got := extractQRCLyricContent(""); got != "" {
		t.Errorf("空输入应返回空串,得到 %q", got)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
