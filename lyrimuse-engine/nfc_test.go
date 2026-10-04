package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// 期望值由 Foundation 的 precomposedStringWithCanonicalMapping 算出(App 侧 cleanTag 用的同一个),
// 覆盖:分解形式的拉丁变音 / 假名浊点、越南语多个组合符的各种先后顺序、韩文字母组音节、兼容汉字、
// 被排除组合的天城文、半角片假名(兼容分解,NFC 不动)、阻挡规则。
var nfcVectors = []struct{ in, want string }{
	{"Sa\U00000304n-Z", "S\U00000101n-Z"},
	{"\U000030AF\U00003099\U000030C3\U000030C8\U00003099\U000030E2\U000030FC\U000030CB\U000030F3\U000030AF\U00003099", "\U000030B0\U000030C3\U000030C9\U000030E2\U000030FC\U000030CB\U000030F3\U000030B0"},
	{"e\U00000302\U00000323", "\U00001EC7"},
	{"e\U00000323\U00000302", "\U00001EC7"},
	{"\U000000EA\U00000323", "\U00001EC7"},
	{"\U00001EC7", "\U00001EC7"},
	{"\U00001100\U00001161\U000011A8", "\U0000AC01"},
	{"\U00001112\U00001161\U000011AB\U00001100\U00001173\U000011AF", "\U0000D55C\U0000AE00"},
	{"\U0000AC00\U000011A8", "\U0000AC00\U000011A8"},
	{"\U0000F900\U0000F901", "\U00008C48\U000066F4"},
	{"\U0000212B", "\U000000C5"},
	{"\U00002126", "\U000003A9"},
	{"A\U0000030A\U00000301", "\U000001FA"},
	{"\U00000344", "\U00000308\U00000301"},
	{"a\U00000328\U00000301", "\U00000105\U00000301"},
	{"Beyonce\U00000301", "Beyonc\U000000E9"},
	{"Beyonc\U000000E9", "Beyonc\U000000E9"},
	{"\U00005468\U00006770\U00004F26", "\U00005468\U00006770\U00004F26"},
	{"\U0000FF8A\U0000FF9F", "\U0000FF8A\U0000FF9F"},
	{"\U00000958", "\U00000915\U0000093C"},
	{"\U00000915\U0000093C", "\U00000915\U0000093C"},
	{"a\U00000301\U00000301", "\U000000E1\U00000301"},
	{"o\U00000308\U00000304", "\U0000022B"},
	{"\U000000F6\U00000304", "\U0000022B"},
	{"\U000003B1\U00000313\U00000301\U00000345", "\U00001F84"},
	{"\U00000CC6\U00000CC2\U00000CD5", "\U00000CCB"},
	{"\U000009C7\U000009BE", "\U000009CB"},
	{"x\U00000300\U00000315\U00000301", "x\U00000300\U00000301\U00000315"},
	{"\U00001E68", "\U00001E68"},
	{"s\U00000323\U00000307", "\U00001E69"},
	{"s\U00000307\U00000323", "\U00001E69"},
	{"A\U0000200D\U00000300", "A\U0000200D\U00000300"},
	{"\U00001E9B\U00000323", "\U00001E9B\U00000323"},
	{"\U00002ADC", "\U00002ADD\U00000338"},
	{"\U0001D15E", "\U0001D157\U0001D165"},
	{"\U000003A9\U00000301", "\U0000038F"},
	{"\U0000D558\U0000C774\U00000301", "\U0000D558\U0000C774\U00000301"},
}

func TestComposeNFCMatchesFoundation(t *testing.T) {
	for _, v := range nfcVectors {
		if got := composeNFC(v.in); got != v.want {
			t.Errorf("composeNFC(%+q) = %+q, want %+q", v.in, got, v.want)
		}
	}
}

// 组合表里每一对都要组得回去;每条分解展开后组合的结果再转一次不变(幂等)。
func TestComposeNFCTableRoundTrip(t *testing.T) {
	nfcOnce.Do(loadNFCTables)
	if len(nfcData.compose) < 900 || len(nfcData.decomp) < 2000 {
		t.Fatalf("NFC 表没读全: %d pairs, %d decompositions", len(nfcData.compose), len(nfcData.decomp))
	}
	for pair, c := range nfcData.compose {
		if got := composeNFC(string(pair[0]) + string(pair[1])); got != string(c) {
			t.Errorf("%U + %U → %+q, want %U", pair[0], pair[1], got, c)
		}
	}
	for cp, d := range nfcData.decomp {
		once := composeNFC(string(d))
		if again := composeNFC(once); again != once {
			t.Errorf("%U: composeNFC 不幂等 %+q → %+q", cp, once, again)
		}
	}
}

func TestComposeNFCFastPath(t *testing.T) {
	for _, s := range []string{"", "hello world", "Beyoncé", "周杰伦 - 晴天", "グッドモーニング", "한국어"} {
		if got := composeNFC(s); got != s {
			t.Errorf("已经是 NFC 的 %q 不该变: %q", s, got)
		}
	}
	allocs := testing.AllocsPerRun(100, func() { _ = composeNFC("周杰伦 - 晴天 (Live)") })
	if allocs != 0 {
		t.Errorf("快路径不该分配: %v", allocs)
	}
}

// 缓存 key 与搜索词都要过 NFC:分解形式的「Sān-Z」跟组合形式算出同一个 key、同一份搜索词。
func TestEnrichKeyAndSearchTermsAreNFC(t *testing.T) {
	nfd, nfc := "Sān-Z", "Sān-Z"
	if enrichKey(nfd, "Stars Align", "Stars Align") != enrichKey(nfc, "Stars Align", "Stars Align") {
		t.Error("分解形式与组合形式算出了两个 key")
	}
	if toSimplified(nfd) != nfc {
		t.Errorf("toSimplified(%+q) = %+q", nfd, toSimplified(nfd))
	}
	if loosenEnrichKey(enrichKey(nfd, "x", "")) != loosenEnrichKey(enrichKey(nfc, "x", "")) {
		t.Error("宽松 key 也要一致")
	}
	if !utf8.ValidString(composeNFC(strings.Repeat("ệ", 50))) {
		t.Error("输出不是合法 UTF-8")
	}
}
