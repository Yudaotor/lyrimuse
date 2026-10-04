package main

import (
	"reflect"
	"sort"
	"strings"
	"testing"
)

func sortedTagKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// 全角括号跟半角一样算括号:限定词、去括号、标题闸都认。
func TestFullWidthBracketsCountAsBrackets(t *testing.T) {
	cases := []struct {
		in       string
		stripped string
		segs     []string
	}{
		{"憂愁（Live in summer）", "憂愁", []string{"Live in summer"}},
		{"迷宫【Live】", "迷宫", []string{"Live"}},
		{"歌［Remix］｛Demo｝", "歌", []string{"Remix", "Demo"}},
		{"兜圈（live)", "兜圈", []string{"live"}}, // 全角开、半角收也认
		{"没有括号", "没有括号", nil},
	}
	for _, c := range cases {
		if got := stripParens(c.in); got != c.stripped {
			t.Errorf("stripParens(%q) = %q, want %q", c.in, got, c.stripped)
		}
		if got := parentheticalSegments(c.in); !reflect.DeepEqual(got, c.segs) {
			t.Errorf("parentheticalSegments(%q) = %q, want %q", c.in, got, c.segs)
		}
	}
	if tags := titleVersionTags("憂愁（Live in summer）"); !tags["live"] {
		t.Errorf("全角括号里的 Live 应当认出: %v", sortedTagKeys(tags))
	}
	// 蘇打綠《憂愁（Live in summer）》:本地全角、候选半角,同一个现场版,不该判版本不符。
	if versionTagsMismatch("憂愁（Live in summer）", "", "憂愁 (Live in summer)", "") {
		t.Error("全角/半角写法的同一个现场版不该判成版本不符")
	}
	// 反过来:本地录音室版、候选是全角括号的现场版,要判版本不符。
	if !versionTagsMismatch("兜圈", "", "兜圈（live)", "") {
		t.Error("全角括号的现场版冒充录音室版应当判出来")
	}
	if !lyricTitleAccepted("爱如潮水（R&B版）", "爱如潮水") || !lyricTitleAccepted("爱如潮水", "爱如潮水（R&B版）") {
		t.Error("全角括号尾巴去掉之后同名,标题闸应当放行")
	}
}

// 艺人名的括号别名兜底只认半角(全角会让另一版本进严格档,见 artistMatches 末尾注释)。
func TestArtistAliasFallbackStaysHalfWidth(t *testing.T) {
	if !artistMatches("丁世光(Dean Ting)", "丁世光") {
		t.Error("半角括号别名应当照旧认")
	}
	if artistMatches("Jennie（제니）", "JENNIE") {
		t.Error("全角括号别名这一处不扩")
	}
}

// 拉丁限定词按词匹配:挤掉空格之后凑出来的 live/demo/edit 不算。
func TestTitleVersionTagsMatchWholeWords(t *testing.T) {
	cases := map[string][]string{
		"Song (Come Alive)":        nil,
		"Song (feat. Clive)":       nil,
		`Song (From "Deliver Us")`: nil,
		"Song (feat. Demons)":      nil,
		"Song (Deluxe Edition)":    nil,
		"Song (Lively Mix)":        nil,
		"Song (Liverpool 1999)":    nil,
		"Song (Live)":              {"live"},
		"Song (Live at Wembley)":   {"live"},
		"Song - Live":              {"live"},
		"Song (2011Live)":          {"live"}, // 粘连写法
		"Song (Remixes)":           {"remix"},
		"Song (Remixed)":           {"remix"},
		"Song (Demos)":             {"demo"},
		"Song (Radio Edit)":        {"edit", "radio edit"},
		"Song (Edit)":              {"edit"},
		"Song (Acoustic Version)":  {"acoustic"},
		"Song (A Cappella)":        {"a cappella"},
		"Song (Acapella)":          {"a cappella"},
		"Song (Club Mix)":          {"club mix"},
		"Song (现场)":                {"live"},
		"Song (現場)":                {"live"},
		"Erotic City (Make Love Not War Erotic City Come Alive)": nil,
	}
	for title, want := range cases {
		got := sortedTagKeys(titleVersionTags(title))
		if len(got) == 0 {
			got = nil
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("titleVersionTags(%q) = %v, want %v", title, got, want)
		}
	}
}

// segmentVersionTags 的中文路径也做繁简:(現場) 跟 (现场) 一样。
func TestSegmentVersionTagsFoldsTraditional(t *testing.T) {
	if !segmentVersionTags("現場")["live"] || !segmentVersionTags("现场")["live"] {
		t.Fatal("繁简两种写法都应当认出 live")
	}
}

// 专辑词元跟 normLoose 同一口径:繁简、变音折叠。
func TestAlbumTokensFoldScriptAndDiacritics(t *testing.T) {
	if !reflect.DeepEqual(albumTokens("低等動物 精選"), albumTokens("低等动物 精选")) {
		t.Errorf("繁简应当折叠: %v vs %v", sortedTagKeys(albumTokens("低等動物 精選")), sortedTagKeys(albumTokens("低等动物 精选")))
	}
	if !reflect.DeepEqual(albumTokens("Café Tacvba Live"), albumTokens("Cafe Tacvba Live")) {
		t.Error("变音应当折叠")
	}
	if albumScore("低等動物 (Live)", "低等动物 精选") < 1 {
		t.Error("繁简不同的同名专辑至少要有一个共享词元")
	}
}

// 时间戳判定:空行不进分母;整份同一个时间戳是纯文本;不带小数的时间戳也认。
func TestIsTimedLRCEdgeCases(t *testing.T) {
	cases := map[string]bool{
		"[00:01.00]a\n[00:02.00]b\n[00:03.00]c":                    true,
		"[00:01.00]a\n\n[00:02.00]b\n\n[00:03.00]c\n\n":            true, // 每句之间空一行
		"[00:00.00]a\n[00:00.00]b\n[00:00.00]c\n[00:00.00]d":       false,
		"[00:00.00]a\n[00:00.00]b\n[00:05.00]c":                    false, // 只有两个不同的值
		"[00:01]a\n[00:02]b\n[00:03]c":                             true,  // 不带小数
		"[ar:x]\n[ti:y]\n[00:01.00]a\n[00:02.00]b\n[00:03.00]c":    true,
		"[00:01.00]作词：x\nplain\nplain\nplain\nplain\nplain\nplain": false,
		"": false,
	}
	for in, want := range cases {
		if got := isTimedLRC(in); got != want {
			t.Errorf("isTimedLRC(%q) = %v, want %v", in, got, want)
		}
	}
}

// 纯音乐占位按行判:真歌词或元数据行里出现「纯音乐」不再判废。
func TestIsCreditOnlyLRCInstrumentalMarkerPerLine(t *testing.T) {
	if !isCreditOnlyLRC("[00:00.00]作曲：某某\n[00:01.00]纯音乐，请欣赏") {
		t.Error("只有署名和纯音乐占位的应当判成没正文")
	}
	real := "[00:01.00]我听着这首纯音乐\n[00:05.00]想起你\n[00:09.00]那年夏天\n[00:13.00]的风"
	if isCreditOnlyLRC(real) {
		t.Error("真歌词里出现「纯音乐」三个字不该判废")
	}
	withMeta := "[al:纯音乐合集]\n[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句"
	if isCreditOnlyLRC(withMeta) {
		t.Error("元数据行里出现「纯音乐」不该判废")
	}
}

// 曲末时间取所有够格行里所有时间戳的最大值。
func TestLastLRCTimestampHandlesCompressedLRC(t *testing.T) {
	cases := []struct {
		lrc  string
		want float64
	}{
		{"[00:10.00][02:50.00]副歌\n[01:00.00]主歌\n[01:10.00]桥段", 170},
		{"[02:40.82][01:15.68]副歌\n[00:30.00]主歌\n[00:40.00]桥段", 160.82},
		{"[00:10.00]a\n[00:20.00]b\n[03:00.00]", 20},      // 空白尾行跳过
		{"[00:10.00]a\n[00:20.00]b\n[00:40.00]作曲：某某", 20}, // 尾部署名行跳过
		{"[00:10]a\n[01:05]b\n[00:30]c", 65},              // 不带小数
		{"[00:01.5]a\n[00:02.50]b\n[00:03.500]c", 3.5},
	}
	for _, c := range cases {
		got, ok := lastLRCTimestampSecs(c.lrc)
		if !ok || got < c.want-0.001 || got > c.want+0.001 {
			t.Errorf("lastLRCTimestampSecs(%q) = %v,%v, want %v", c.lrc, got, ok, c.want)
		}
	}
	if got := lastLRCTimestampMs("[00:10.00][02:50.00]副歌\n[01:00.00]主歌"); got != 170000 {
		t.Errorf("lastLRCTimestampMs = %d, want 170000", got)
	}
	if got := lastLRCTimestampMs("[00:10] [01:20]a\n[00:30]b"); got != 80000 {
		t.Errorf("lastLRCTimestampMs(不带小数、中间有空格) = %d, want 80000", got)
	}
}

// 艺人名折叠变音,防仿冒照旧。
func TestArtistMatchesFoldsDiacritics(t *testing.T) {
	if !artistMatches("Beyoncé", "Beyonce") || !artistMatches("Elley Duhé", "elley duhe") {
		t.Error("只差变音的应当认作同一人")
	}
	if !lyricSourceArtistMatches("Yamê, Tiakola", "Yame/Tiakola") {
		t.Error("多人署名逐段比时也折叠变音")
	}
	if artistMatches("周杰伦-", "周杰伦") || artistMatches("Beyoncé.", "Beyonce") {
		t.Error("折叠不碰标点,仿冒写法照旧不认")
	}
}

// 双语写法:尾巴是版本限定词时不算。
func TestBilingualTitleTailIsNotAVersionTag(t *testing.T) {
	if bilingualTitleEqual("稻香", "稻香live") || bilingualTitleEqual("稻香", "稻香remix") {
		t.Error("尾巴是版本词的不是英文别名")
	}
	if !bilingualTitleEqual("稻香", "稻香ricefield") {
		t.Error("真正的英文别名照旧认")
	}
	if !strings.Contains(normLoose("稻香 Live"), "live") {
		t.Fatal("前提:normLoose 保留拉丁字母")
	}
}
