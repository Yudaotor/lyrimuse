package main

import (
	"strings"
	"testing"
)

// 2026-09-02 接回 QQ GetPlayLyricInfo 的 trans/roma 两轨。下面的样本按当天直连接口看到的
// 真实形态仿写(米津玄師 Lemon / Taylor Swift Cruel Summer 的结构,正文换成占位文字),
// 钉住的是清洗规则,不是某首歌的内容。

// trans 轨解出来是普通逐行 LRC,夹着三类要剔掉的行:无时间戳的 [kana:] 元数据、`//`
// 占位行(对应标题/词曲署名行)、[00:00.00] 上的版权声明。
func TestQQAuxiliaryPlainToLRCCleansTranslationTrack(t *testing.T) {
	plain := strings.Join([]string{
		"[ti:示例曲目]",
		"[ar:示例歌手]",
		"[kana:1よね1づ1けん1し]",
		"[offset:0]",
		"[00:00.00]QQ音乐享有本翻译作品的著作权",
		"[00:00.39]//",
		"[00:00.79]//",
		"[00:01.19]第一句译文",
		"[00:06.04]第二句 译文里带空格",
		"[00:08.51]第三句译文",
		"[00:10.00]   ",
		"",
	}, "\n")
	got := qqAuxiliaryPlainToLRC(plain)
	want := strings.Join([]string{
		"[offset:0]",
		"[00:01.19]第一句译文",
		"[00:06.04]第二句 译文里带空格",
		"[00:08.51]第三句译文",
	}, "\n")
	if got != want {
		t.Fatalf("清洗结果不对\n实际:\n%s\n期望:\n%s", got, want)
	}
}

// roma 轨沿用 QRC 的 XML 包装 + 逐字计时,要压成逐行 LRC:[行始,行长]→[mm:ss.SSS],
// 去掉 (词始,词长),只剩计时没有文字的行丢掉,音节间空格保留一个。
func TestQQAuxiliaryPlainToLRCConvertsQRCRomaTrack(t *testing.T) {
	content := strings.Join([]string{
		"[ti:示例曲目]",
		"[offset:0]",
		"[0,529](496,33)",
		"[530,529](970,88)",
		"[1547,1151]yu (1547,223)me (1771,152)na (1924,223)ra (2147,164)ba (2312,386)",
		"[62880,4001]do (62880,303)re (63184,351)ho (63536,167)do (63703,447)",
		"[125001,900]i (125001,184)ma (125185,191)",
	}, "\n")
	xml := `<?xml version="1.0" encoding="utf-8"?>` + "\n" +
		`<QrcInfos><QrcHeadInfo SaveTime="1" Version="1"/><LyricInfo LyricCount="1">` +
		`<Lyric_1 LyricType="1" LyricContent="` + content + "\n" + `"/>` + "\n</LyricInfo>\n</QrcInfos>"
	got := qqAuxiliaryPlainToLRC(xml)
	want := strings.Join([]string{
		"[offset:0]",
		"[00:01.547]yu me na ra ba",
		"[01:02.880]do re ho do",
		"[02:05.001]i ma",
	}, "\n")
	if got != want {
		t.Fatalf("QRC 罗马音转逐行 LRC 不对\n实际:\n%s\n期望:\n%s", got, want)
	}
}

// 正文里的括号(如「(よねづ けんし)」这种歌手名注音)不是计时标记,不能被当成 (词始,词长)
// 剥掉;只有「(数字,数字)」才是。
func TestQRCToLineLRCKeepsTextParentheses(t *testing.T) {
	got := qrcToLineLRC("[0,529]Lemon - (0,33)米(33,66)津(99,33) ((232,33)よ(265,33)ね(298,33))(497,33)")
	if got != "[00:00.000]Lemon - 米津 (よね)" {
		t.Fatalf("实际 %q", got)
	}
}

// 清洗完不到 3 行带戳就当没有(isTimedLRC 口径),别把一两行残片当成一份译文。
func TestQQAuxiliaryPlainToLRCRejectsTooFewLines(t *testing.T) {
	if got := qqAuxiliaryPlainToLRC("[00:00.00]//\n[00:01.19]只有一句\n[00:02.00]只有两句"); got != "" {
		t.Fatalf("两行残片应当被丢弃,实际 %q", got)
	}
	if got := qqAuxiliaryPlainToLRC(""); got != "" {
		t.Fatalf("空输入应返回空串,实际 %q", got)
	}
}

// 版权声明只认带「著作权」的那句;歌词正文里恰好出现「QQ音乐」不能被误杀。
func TestIsQQTranslationNotice(t *testing.T) {
	cases := map[string]bool{
		"QQ音乐享有本翻译作品的著作权":  true,
		"本翻译作品的著作权归QQ音乐所有": true,
		"我在QQ音乐上听到这首歌":     false,
		"著作权":              false,
	}
	for text, want := range cases {
		if got := isQQTranslationNotice(text); got != want {
			t.Errorf("isQQTranslationNotice(%q) = %v, want %v", text, got, want)
		}
	}
}

// QRC 正文第一行的 `[kana:…]` 假名标注要单独摘出来(原样、含方括号、读音里的 (起始,时长)
// 一并保留——App 侧 KanaAnnotation 自己会剥),剩下的正文再进 qrcToYRC;逐字数据里不该再
// 出现这一行(留在里面会被词级重排搅乱,App 也不从 YRC 读它)。
func TestSplitQRCKanaLine(t *testing.T) {
	content := strings.Join([]string{
		"[ti:示例]",
		"[kana:1よね1づ1けん1し1ゆ(1547,224)め(1771,153)]",
		"[1547,1152]夢(1547,377)な(1924,223)ら(2147,165)ば(2312,387)",
	}, "\n")
	kana, rest := splitQRCKanaLine(content)
	if kana != "[kana:1よね1づ1けん1し1ゆ(1547,224)め(1771,153)]" {
		t.Fatalf("kana 行摘错: %q", kana)
	}
	if strings.Contains(rest, "[kana:") || !strings.Contains(rest, "[1547,1152]") || !strings.Contains(rest, "[ti:示例]") {
		t.Fatalf("剩余正文不对: %q", rest)
	}
	if strings.Contains(qrcToYRC(rest), "kana") {
		t.Fatalf("YRC 里不该有 kana 行")
	}
	if k, r := splitQRCKanaLine("[0,10]a(0,10)"); k != "" || r != "[0,10]a(0,10)" {
		t.Fatalf("没有 kana 行时应原样返回,实际 %q / %q", k, r)
	}
}

// 拼进整行歌词最前面;整行歌词已带 [kana:](酷狗形态)或任一侧为空时不动。
func TestAttachKanaLine(t *testing.T) {
	lrc := "[00:00.00]标题\n[00:01.54]夢ならば"
	if got := attachKanaLine(lrc, "[kana:1ゆめ]"); got != "[kana:1ゆめ]\n"+lrc {
		t.Fatalf("实际 %q", got)
	}
	if got := attachKanaLine(lrc, ""); got != lrc {
		t.Fatalf("kana 为空应原样返回,实际 %q", got)
	}
	if got := attachKanaLine("", "[kana:1ゆめ]"); got != "" {
		t.Fatalf("歌词为空应原样返回,实际 %q", got)
	}
	already := "[kana:1あ]\n" + lrc
	if got := attachKanaLine(already, "[kana:1ゆめ]"); got != already {
		t.Fatalf("已带 kana 行不应重复拼,实际 %q", got)
	}
}

// v11 回归:跨源共识正文要跳过 `[kana:]`/`[ti:]`/`[offset:]` 这类元数据标签行——E2E 实测
// 《Lemon》的 QQ 候选拼上 1700+ 字符的假名行后,3-gram 相似度掉到阈值以下、250 分共识没了。
// 同时守住两条边界:无时间戳的纯文本行(lrclib plainOnly 那种)仍算正文;时间戳行不受影响。
func TestLyricConsensusBodyIgnoresMetaTagLines(t *testing.T) {
	plain := "[00:01.54]夢ならば\n[00:02.88]どれほどよかったでしょう"
	withMeta := "[kana:1ゆ(1547,224)め(1771,153)1いま]\n[ti:Lemon]\n[ar:米津玄師]\n[offset:0]\n" + plain
	if got, want := lyricConsensusBody(withMeta), lyricConsensusBody(plain); got != want {
		t.Fatalf("元数据标签行不该进共识正文\n实际 %q\n期望 %q", got, want)
	}
	if lyricConsensusBody("hello world\nsecond line") == "" {
		t.Fatal("无时间戳的纯文本行仍应算正文")
	}
	for line, want := range map[string]bool{
		"[kana:1ゆめ]":      true,
		"  [offset:0]  ":  true,
		"[00:01.54]夢ならば":  false,
		"[Chorus]":        false,
		"[kana:1ゆめ] 夢ならば": false,
		"夢ならば":            false,
	} {
		if got := isLRCMetaTagLine(line); got != want {
			t.Errorf("isLRCMetaTagLine(%q) = %v, want %v", line, got, want)
		}
	}
}
