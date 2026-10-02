package main

import (
	"encoding/xml"
	"fmt"
	"strings"
	"testing"
)

const amllTTMLOpen = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"` +
	` xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">`

// 注音(tts:ruby)整组收成一个词:正文只要 base 的字,注音不进正文,时间取注音上的;整组没有时间时正文照样有这个字。
func TestParseAMLLTTMLRuby(t *testing.T) {
	raw := amllTTMLOpen + `<head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head><body><div>` +
		`<p begin="25.000" end="27.000"><span begin="25.000" end="25.300">Dai</span> <span begin="25.300" end="25.577">dai,</span> ` +
		`<span tts:ruby="container"><span tts:ruby="base">行</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="25.577" end="25.824">い</span></span></span>` +
		`<span tts:ruby="container"><span tts:ruby="base">く,</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="25.824" end="26.346">こう</span></span></span>` +
		` <span begin="26.400" end="27.000">dale</span></p>` +
		`<p begin="30.000" end="31.000"><span tts:ruby="container"><span tts:ruby="base">夢</span><span tts:ruby="text">ゆめ</span></span></p>` +
		`</div></body></tt>`
	for name, parse := range map[string]func(string) (amllResult, bool){
		"parseAMLLTTML":    parseAMLLTTML,
		"parseAMLLTTMLFor": func(s string) (amllResult, bool) { return parseAMLLTTMLFor(s, "zh") },
	} {
		r, ok := parse(raw)
		if !ok {
			t.Fatalf("%s: 解析失败", name)
		}
		if r.lrc != "[00:25.00]Dai dai, 行く, dale\n[00:30.00]夢\n" {
			t.Errorf("%s: 注音不该进正文: %q", name, r.lrc)
		}
		if want := "[25000,2000](25000,300,0)Dai (25300,277,0)dai, (25577,247,0)行(25824,522,0)く, (26400,600,0)dale\n"; r.yrc != want {
			t.Errorf("%s: 逐字时间取注音上的:\n got %q\nwant %q", name, r.yrc, want)
		}
	}
}

// 字面文本(没有逐字数据的行、head 里的译文)里的注音同样只取 base 的字。
func TestTTMLLiteralTextRuby(t *testing.T) {
	var line ttmlLine
	if err := xml.Unmarshal([]byte(`<p xmlns:tts="http://www.w3.org/ns/ttml#styling">今日も<span tts:ruby="container">`+
		`<span tts:ruby="base">夢</span><span tts:ruby="text">ゆめ</span></span>を見る</p>`), &line); err != nil {
		t.Fatal(err)
	}
	if got := ttmlLiteralText(line.Kids); got != "今日も夢を見る" {
		t.Errorf("got %q", got)
	}
}

const amllMultiLangTTML = amllTTMLOpen + `<head><metadata/></head><body><div>` +
	`<p begin="1.000" end="2.000"><span begin="1.000" end="2.000">Hello</span>` +
	`<span ttm:role="x-translation" xml:lang="zh-CN">你好</span><span ttm:role="x-translation" xml:lang="ja">こんにちは</span></p>` +
	`<p begin="3.000" end="4.000"><span begin="3.000" end="4.000">World</span>` +
	`<span ttm:role="x-translation" xml:lang="ja">世界(ja)</span><span ttm:role="x-translation">世界</span></p>` +
	`</div></body></tt>`

// 行内译文整首挑一种语言:跟目标语言最贴的那个,一行没有那种语言时取没标语言的那段;一个都不贴时取先出现的。
// parseAMLLTTML 照旧每行取第一段。
func TestParseAMLLTTMLForTranslationLang(t *testing.T) {
	for _, c := range []struct {
		target, tr, lang string
	}{
		{"zh", "[00:01.00]你好\n[00:03.00]世界\n", "zh"},
		{"ja", "[00:01.00]こんにちは\n[00:03.00]世界(ja)\n", "ja"},
		{"en", "[00:01.00]你好\n[00:03.00]世界\n", "zh"},
	} {
		r, ok := parseAMLLTTMLFor(amllMultiLangTTML, c.target)
		if !ok || r.tr != c.tr || r.trLang != c.lang {
			t.Errorf("目标 %s: tr=%q lang=%q", c.target, r.tr, r.trLang)
		}
	}
	r, _ := parseAMLLTTML(amllMultiLangTTML)
	if r.tr != "[00:01.00]你好\n[00:03.00]世界(ja)\n" || r.trLang != "" {
		t.Errorf("parseAMLLTTML 每行取第一段、不记语言: tr=%q lang=%q", r.tr, r.trLang)
	}

	hant := strings.Replace(amllMultiLangTTML, `xml:lang="zh-CN"`, `xml:lang="zh-Hant"`, 1)
	if r, _ := parseAMLLTTMLFor(hant, "zh"); r.trLang != "zh-Hant" || !strings.HasPrefix(r.tr, "[00:01.00]你好") {
		t.Errorf("只有繁体时照样挑中文、记成 zh-Hant: tr=%q lang=%q", r.tr, r.trLang)
	}
	untagged := strings.NewReplacer(` xml:lang="zh-CN"`, "", ` xml:lang="ja"`, "").Replace(amllMultiLangTTML)
	if r, _ := parseAMLLTTMLFor(untagged, "en"); r.trLang != "" || r.translationLang("en") != "en" {
		t.Errorf("都没标语言时不记语言、按目标语言算: lang=%q", r.trLang)
	}
}

func TestAMLLTranslationLangRank(t *testing.T) {
	for _, c := range []struct {
		tag, target string
		want        int
	}{
		{"zh-CN", "zh", 2}, {"zh-Hans", "zh", 2}, {"zh", "zh", 2}, {"zh-Hant", "zh", 1}, {"zh-TW", "zh", 1},
		{"en-US", "en", 2}, {"ja", "en", 0}, {"", "en", 0},
	} {
		if got := amllTranslationLangRank(c.tag, c.target); got != c.want {
			t.Errorf("rank(%q, %q) = %d, want %d", c.tag, c.target, got, c.want)
		}
	}
	for tag, want := range map[string]string{"zh-CN": "zh", "zh_TW": "zh-Hant", "zh-Hant-HK": "zh-Hant", "EN-us": "en", "": ""} {
		if got := amllTrLangTag(tag); got != want {
			t.Errorf("amllTrLangTag(%q) = %q, want %q", tag, got, want)
		}
	}
}

func amllHeadTTML(head, body string) string {
	return amllTTMLOpen + `<head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">` + head +
		`</iTunesMetadata></metadata></head><body><div>` + body + `</div></body></tt>`
}

const amllHeadBody = `<p begin="1.000" end="2.000" itunes:key="L1"><span begin="1.000" end="2.000">One</span></p>` +
	`<p begin="3.000" end="4.000" itunes:key="L2"><span begin="3.000" end="4.000">Two</span></p>`

// 行内一段译文都没有时用 head 里的:replacement 不算译文,subtitle 和没写 type 的按目标语言挑;按 key 对回正文行首,
// 对不上的丢掉。行内有译文时不看 head;parseAMLLTTML 不看 head。
func TestParseAMLLTTMLForHeadTranslation(t *testing.T) {
	raw := amllHeadTTML(`<translations>`+
		`<translation type="replacement" xml:lang="zh-Hans"><text for="L1">替换</text></translation>`+
		`<translation type="subtitle" xml:lang="ja"><text for="L1">日本語</text><text for="L2">二行目</text></translation>`+
		`<translation xml:lang="zh-Hans"><text for="L2">第二句</text><text for="L1"><span begin="1.0" end="2.0">第一</span> <span begin="1.5" end="2.0">句</span></text><text for="L9">对不上</text></translation>`+
		`</translations>`, amllHeadBody)
	if r, _ := parseAMLLTTMLFor(raw, "zh"); r.tr != "[00:01.00]第一 句\n[00:03.00]第二句\n" || r.trLang != "zh" {
		t.Errorf("目标中文: tr=%q lang=%q", r.tr, r.trLang)
	}
	if r, _ := parseAMLLTTMLFor(raw, "ja"); r.tr != "[00:01.00]日本語\n[00:03.00]二行目\n" || r.trLang != "ja" {
		t.Errorf("目标日文: tr=%q lang=%q", r.tr, r.trLang)
	}
	if r, _ := parseAMLLTTML(raw); r.tr != "" {
		t.Errorf("parseAMLLTTML 不看 head: %q", r.tr)
	}
	onlyReplacement := amllHeadTTML(`<translations><translation type="replacement" xml:lang="zh-Hans"><text for="L1">替换</text></translation></translations>`, amllHeadBody)
	if r, _ := parseAMLLTTMLFor(onlyReplacement, "zh"); r.tr != "" {
		t.Errorf("replacement 不算译文: %q", r.tr)
	}
	inline := amllHeadTTML(`<translations><translation type="subtitle" xml:lang="zh-Hans"><text for="L1">头部</text></translation></translations>`,
		`<p begin="1.000" end="2.000" itunes:key="L1"><span begin="1.000" end="2.000">One</span><span ttm:role="x-translation" xml:lang="zh-CN">行内</span></p>`)
	if r, _ := parseAMLLTTMLFor(inline, "zh"); r.tr != "[00:01.00]行内\n" {
		t.Errorf("行内有译文时不看 head: %q", r.tr)
	}
}

// 行内一段罗马音都没有时用 head 里的音译:span 之间原文有空白照原文;没有空白时按正文的词间空白补,正文是中文时每个
// 音节之间都补;一个 span 中间的空白去掉。行内有罗马音时不看 head。
func TestParseAMLLTTMLForHeadTransliteration(t *testing.T) {
	ja := amllHeadTTML(`<transliterations><transliteration><text for="L1">`+
		`<span begin="1.510" end="1.690">Mi</span><span begin="1.690" end="2.140">juku</span>`+
		`<span begin="3.210" end="3.370">mu</span><span begin="3.370" end="3.490">j</span><span begin="3.490" end="3.630">o</span><span begin="3.630" end="3.770">u</span>`+
		`<span begin="4.860" end="5.030">u tsu ku</span><span begin="5.030" end="5.200">shi</span></text></transliteration></transliterations>`,
		`<p begin="1.510" end="5.200" itunes:key="L1"><span begin="1.510" end="1.690">未</span><span begin="1.690" end="2.140">熟</span> `+
			`<span begin="3.210" end="3.370">無</span><span begin="3.370" end="3.490">ジ</span><span begin="3.490" end="3.630">ョ</span><span begin="3.630" end="3.770">ウ</span> `+
			`<span begin="4.860" end="5.030">美</span><span begin="5.030" end="5.200">し</span></p>`)
	if r, _ := parseAMLLTTMLFor(ja, "zh"); r.roma != "[00:01.51]Mijuku mujou utsukushi\n" {
		t.Errorf("日文按正文的词间空白分词: %q", r.roma)
	}

	zh := amllHeadTTML(`<transliterations><transliteration xml:lang="zh-Latn-jyutping"><text for="L1">`+
		`<span begin="1.0" end="1.5">sai3</span><span begin="1.5" end="2.0">jyu5</span></text></transliteration></transliterations>`,
		`<p begin="1.000" end="2.000" itunes:key="L1"><span begin="1.0" end="1.5">细</span><span begin="1.5" end="2.0">雨</span></p>`)
	if r, _ := parseAMLLTTMLFor(zh, "zh"); r.roma != "[00:01.00]sai3 jyu5\n" {
		t.Errorf("中文每个音节之间都补空格: %q", r.roma)
	}

	apple := amllHeadTTML(`<transliterations><transliteration xml:lang="ja-Latn"><text for="L1">`+
		`<span begin="1.0" end="1.2">maru</span><span begin="1.2" end="1.4">de</span> <span begin="1.4" end="2.0">kono</span></text></transliteration></transliterations>`,
		`<p begin="1.000" end="2.000" itunes:key="L1"><span begin="1.0" end="1.2">ま</span><span begin="1.2" end="1.4">るで</span><span begin="1.4" end="2.0">この</span></p>`)
	if r, _ := parseAMLLTTMLFor(apple, "zh"); r.roma != "[00:01.00]marude kono\n" {
		t.Errorf("原文 span 之间的空白照原文: %q", r.roma)
	}

	inline := amllHeadTTML(`<transliterations><transliteration><text for="L1"><span begin="1.0" end="2.0">head</span></text></transliteration></transliterations>`,
		`<p begin="1.000" end="2.000" itunes:key="L1"><span begin="1.0" end="2.0">夢</span><span ttm:role="x-roman">yume</span></p>`)
	if r, _ := parseAMLLTTMLFor(inline, "zh"); r.roma != "[00:01.00]yume\n" {
		t.Errorf("行内有罗马音时不看 head: %q", r.roma)
	}
	if r, _ := parseAMLLTTML(ja); r.roma != "" {
		t.Errorf("parseAMLLTTML 不看 head: %q", r.roma)
	}
}

// 组装 amll 候选:按 ISRC / 歌名在索引里找到的报索引里的元数据、不借封面;译文按 TTML 标的语言判能不能用、标什么。
func TestRankLyricSourceResultsAMLLIndexMatch(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsTranslationLanguage: "en"})

	var lrc, tr strings.Builder
	for i := 0; i < 20; i++ {
		ts := formatLRCTime((10 + i*10) * 1000)
		lrc.WriteString(ts + fmt.Sprintf("Line number %d of the song\n", i))
		tr.WriteString(ts + fmt.Sprintf("Translated line %d\n", i))
	}
	amllOf := func(r amllResult) map[string]lyricSourceResult {
		r.lrc, r.tr = lrc.String(), tr.String()
		return map[string]lyricSourceResult{
			"netease": {source: "netease", ne: neteaseInfo{Cover: "https://example.com/ne.jpg"}},
			"amll":    {source: "amll", amll: r},
		}
	}
	find := func(rs []scoredLyricCandidateResult) scoredLyricCandidateResult {
		for _, r := range rs {
			if r.Source == "amll" {
				return r
			}
		}
		t.Fatal("没有 amll 候选")
		return scoredLyricCandidateResult{}
	}

	got := find(rankLyricSourceResults("Michael Jackson", "Black or White", "Dangerous", 210,
		amllOf(amllResult{trLang: "en", platform: "", matchTitle: "Black Or White", matchArtist: "Michael Jackson", matchAlbum: "Dangerous (Special Edition)"})))
	if got.Title != "Black Or White" || got.Album != "Dangerous (Special Edition)" || got.CoverURL != "" {
		t.Errorf("索引找到的报索引里的元数据、不借封面: %+v", got)
	}
	if got.LyricsTr == "" || got.LyricsTrLang != "en" {
		t.Errorf("英文译文配英文目标该收下、标 en: lang=%q tr=%v", got.LyricsTrLang, got.LyricsTr != "")
	}

	got = find(rankLyricSourceResults("Michael Jackson", "Black or White", "Dangerous", 210,
		amllOf(amllResult{trLang: "zh", platform: "ncm-lyrics"})))
	if got.LyricsTr != "" {
		t.Errorf("中文译文配英文目标不该收下: %q", got.LyricsTrLang)
	}
	if got.Title != "Black or White" || got.CoverURL != "https://example.com/ne.jpg" {
		t.Errorf("按网易云 ID 取到的沿用本地元数据、借网易云封面: %+v", got)
	}

	got = find(rankLyricSourceResults("Michael Jackson", "Black or White", "Dangerous", 210, amllOf(amllResult{})))
	if got.LyricsTr == "" || got.LyricsTrLang != "en" {
		t.Errorf("没标语言时按目标语言算: lang=%q tr=%v", got.LyricsTrLang, got.LyricsTr != "")
	}

	setFeatures(featureFlags{LyricsTranslationLanguage: "zh"})
	got = find(rankLyricSourceResults("Michael Jackson", "Black or White", "Dangerous", 210, amllOf(amllResult{trLang: "zh-Hant"})))
	if got.LyricsTr == "" || got.LyricsTrLang != "zh-Hant" {
		t.Errorf("繁体译文配中文目标收下、照实标 zh-Hant: lang=%q tr=%v", got.LyricsTrLang, got.LyricsTr != "")
	}
}
