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
