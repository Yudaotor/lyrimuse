package main

import (
	"strings"
	"testing"
)

// 用例照《说好不哭》的真实 TTML 结构写(amll-ttml-db ncm-lyrics/1962165963.ttml)。
const ttmlDuetSample = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"` +
	` xmlns:itunes="http://music.apple.com/lyric-ttml-internal">` +
	`<head><metadata xmlns="">` +
	`<ttm:agent type="person" xml:id="v1"/><ttm:agent type="other" xml:id="v2"/>` +
	`<ttm:agent type="group" xml:id="v1000"/>` +
	`</metadata></head>` +
	`<body dur="03:30.361"><div xmlns="" begin="00:26.510" end="03:12.000">` +
	`<p begin="00:26.510" end="00:29.400" ttm:agent="v1" itunes:key="L1">` +
	`<span begin="00:26.510" end="00:26.740">没</span><span begin="00:26.740" end="00:26.930">有</span>` +
	`<span ttm:role="x-translation" xml:lang="en">Gone</span></p>` +
	`<p begin="01:54.950" end="01:57.000" ttm:agent="v2" itunes:key="L2">` +
	`<span begin="01:54.950" end="01:55.200">电</span><span begin="01:55.200" end="01:55.500">话</span></p>` +
	`<p begin="02:18.710" end="02:20.000" ttm:agent="v1000" itunes:key="L3">` +
	`<span begin="02:18.710" end="02:19.000">眼</span><span begin="02:19.000" end="02:19.300">看</span>` +
	`<span ttm:role="x-bg" begin="02:19.300" end="02:19.900"><span begin="02:19.300" end="02:19.900">和声</span></span>` +
	`</p></div></body></tt>`

func TestParseTTMLTime(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"00:26.510", 26510},
		{"01:54.950", 114950},
		{"01:00:26.510", 3626510},
		{"0", -1},
		{"", -1},
		{"aa:bb", -1},
		{"00:-1.0", -1},
	}
	for _, c := range cases {
		if got := parseTTMLTime(c.in); got != c.want {
			t.Errorf("parseTTMLTime(%q) = %d, 期望 %d", c.in, got, c.want)
		}
	}
}

func TestParseAMLLTTMLDuet(t *testing.T) {
	r, ok := parseAMLLTTML(ttmlDuetSample)
	if !ok {
		t.Fatal("解析失败")
	}
	if !r.hasDuet {
		t.Error("两个非 group 演唱者,应判为对唱")
	}
	lrc := strings.Split(strings.TrimRight(r.lrc, "\n"), "\n")
	if len(lrc) != 3 {
		t.Fatalf("应有 3 行,实际 %d: %q", len(lrc), r.lrc)
	}
	// person 按出现顺序重编号成 v1/v2;group 统一写「合」(不用原始 xml:id v1000)
	if !strings.HasPrefix(lrc[0], "[00:26.51]v1：没有") {
		t.Errorf("第 1 行前缀不对: %q", lrc[0])
	}
	if !strings.HasPrefix(lrc[1], "[01:54.95]v2：电话") {
		t.Errorf("第 2 行前缀不对: %q", lrc[1])
	}
	if !strings.HasPrefix(lrc[2], "[02:18.71]合：眼看") {
		t.Errorf("group 应写成「合」: %q", lrc[2])
	}
	// 背景人声(x-bg)整枝跳过,不能混进主歌词
	if strings.Contains(r.lrc, "和声") {
		t.Errorf("背景人声不该进主歌词: %q", r.lrc)
	}
	// 内嵌译文单独成一份
	if !strings.Contains(r.tr, "[00:26.51]Gone") {
		t.Errorf("译文没提出来: %q", r.tr)
	}
	if strings.Contains(r.lrc, "Gone") {
		t.Errorf("译文不该混进正文: %q", r.lrc)
	}
	// 逐字:前缀是独立的一个词、时长 0
	yrc := strings.Split(strings.TrimRight(r.yrc, "\n"), "\n")
	if !strings.HasPrefix(yrc[0], "[26510,2890](26510,0,0)v1：(26510,230,0)没") {
		t.Errorf("YRC 行头不对: %q", yrc[0])
	}
	// 这份 YRC 喂给说话人识别应当认出 v1/v2/合
	sp := lyricSpeakerLabels(r.lrc)
	for _, want := range []string{"v1", "v2", "合"} {
		if !sp[want] {
			t.Errorf("说话人识别漏了 %q: %v", want, sp)
		}
	}
}

// 单人歌:TTML 规范要求也标 ttm:agent="v1",但没必要给每行都加个没用的前缀。
func TestParseAMLLTTMLSoloNoPrefix(t *testing.T) {
	solo := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">` +
		`<head><metadata xmlns=""><ttm:agent type="person" xml:id="v1"/></metadata></head>` +
		`<body><div xmlns="">` +
		`<p begin="00:01.000" end="00:02.000" ttm:agent="v1"><span begin="00:01.000" end="00:02.000">一</span></p>` +
		`<p begin="00:03.000" end="00:04.000" ttm:agent="v1"><span begin="00:03.000" end="00:04.000">二</span></p>` +
		`</div></body></tt>`
	r, ok := parseAMLLTTML(solo)
	if !ok {
		t.Fatal("解析失败")
	}
	if r.hasDuet {
		t.Error("只有一位演唱者,不该判为对唱")
	}
	if strings.Contains(r.lrc, "v1") || strings.Contains(r.lrc, "：") {
		t.Errorf("单人歌不该有前缀: %q", r.lrc)
	}
	if !strings.Contains(r.lrc, "[00:01.00]一") {
		t.Errorf("正文不对: %q", r.lrc)
	}
}

func TestParseAMLLTTMLGarbage(t *testing.T) {
	for _, s := range []string{"", "not xml", "<tt></tt>", "<tt><body></body></tt>"} {
		if _, ok := parseAMLLTTML(s); ok {
			t.Errorf("垃圾输入不该解析成功: %q", s)
		}
	}
}

// 词间空白:amll-ttml-db 里两种写法并存,两种都必须出对的结果。
//
// 2026-08-24 回归测试。原来 ttmlLine/ttmlSpan 用 `Spans []ttmlSpan` + `,chardata`
// 声明式解析,Go 会把一个元素的全部直接文本合并成一个字符串、顺序全丢,于是
// `<span>What</span> <span>a</span> <span>ride</span>` 拼成了 "Whataride"。
// 用户看到的症状是**没有翻译**:粘住的假词翻译器原样返回,translate.go 那道
// 「没翻动的行不写进译文」把整行丢掉了(实测那首歌 78 行只出了 32 行译文)。
func TestParseAMLLTTMLWordSpacing(t *testing.T) {
	// L1 空格在 span **之间**;L2 空格在 span **内部**;L3 中文逐字(本来就没有空白);
	// L4 行首行尾都有多余空白、词间是 4 个空格;
	// L5 **混合**:一个词被拆成两个没有空白的音节 + 词之间有空白 —— 这一行是
	//    「干脆用空格 join」这种偷懒修法的照妖镜,音节不能被拆开。
	sample := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">` +
		`<head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head><body><div>` +
		`<p begin="00:01.000" end="00:02.000" ttm:agent="v1"> <span begin="00:01.000" end="00:01.400">What</span> <span begin="00:01.400" end="00:01.700">a</span> <span begin="00:01.700" end="00:02.000">ride</span></p>` +
		`<p begin="00:03.000" end="00:04.000" ttm:agent="v1"><span begin="00:03.000" end="00:03.400">How </span><span begin="00:03.400" end="00:03.700">it </span><span begin="00:03.700" end="00:04.000">goes</span></p>` +
		`<p begin="00:05.000" end="00:06.000" ttm:agent="v1"><span begin="00:05.000" end="00:05.500">没</span><span begin="00:05.500" end="00:06.000">有</span></p>` +
		`<p begin="00:07.000" end="00:08.000" ttm:agent="v1">   <span begin="00:07.000" end="00:07.500">We</span>    <span begin="00:07.500" end="00:08.000">fine</span>    </p>` +
		`<p begin="00:09.000" end="00:10.000" ttm:agent="v1"> <span begin="00:09.000" end="00:09.300">ka</span><span begin="00:09.300" end="00:09.600">raoke</span> <span begin="00:09.600" end="00:10.000">night</span></p>` +
		`</div></body></tt>`
	r, ok := parseAMLLTTML(sample)
	if !ok {
		t.Fatal("解析失败")
	}
	lrc := strings.Split(strings.TrimRight(r.lrc, "\n"), "\n")
	want := []string{
		"[00:01.00]What a ride",   // span 之间的空白必须保住
		"[00:03.00]How it goes",   // span 内部的空白不能被重复加一遍
		"[00:05.00]没有",            // 中文逐字不能被塞进空格
		"[00:07.00]We fine",       // 行首行尾空白去掉、词间多个空格折成一个
		"[00:09.00]karaoke night", // 音节不拆、词间加空格
	}
	if len(lrc) != len(want) {
		t.Fatalf("应有 %d 行,实际 %d: %q", len(want), len(lrc), r.lrc)
	}
	for i, w := range want {
		if lrc[i] != w {
			t.Errorf("第 %d 行\n 实际 %q\n 期望 %q", i+1, lrc[i], w)
		}
	}

	// 不变式:YRC 每行的词原样拼起来必须**逐字节等于** LRC 同行正文。
	// Swift 侧靠 `plainText == words.joined()` 判断这一行的逐字数据可不可信,对不上
	// 就整行不染色(见 MenuBarStatusItem.karaokeFillPath 那道守卫)。
	yrc := strings.Split(strings.TrimRight(r.yrc, "\n"), "\n")
	if len(yrc) != len(lrc) {
		t.Fatalf("YRC 行数 %d != LRC 行数 %d", len(yrc), len(lrc))
	}
	for i := range lrc {
		body := lrc[i][strings.Index(lrc[i], "]")+1:]
		if joined := joinYRCWords(yrc[i]); joined != body {
			t.Errorf("第 %d 行 LRC 与 YRC 拼接不一致\n LRC %q\n YRC %q", i+1, body, joined)
		}
	}
}

// joinYRCWords 把一行 YRC 的词原样拼起来(丢掉 `[行始,行长]` 和每个 `(词始,词长,0)`),
// 也就是 Swift 侧 `words.joined()` 会得到的东西。
func joinYRCWords(line string) string {
	rest := line[strings.Index(line, "]")+1:]
	var b strings.Builder
	for len(rest) > 0 {
		if !strings.HasPrefix(rest, "(") {
			break
		}
		c := strings.Index(rest, ")")
		if c < 0 {
			break
		}
		rest = rest[c+1:]
		if nxt := strings.Index(rest, "("); nxt >= 0 {
			b.WriteString(rest[:nxt])
			rest = rest[nxt:]
		} else {
			b.WriteString(rest)
			rest = ""
		}
	}
	return b.String()
}
