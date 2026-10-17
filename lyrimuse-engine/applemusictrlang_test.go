package main

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// Apple 译文块的 xml:lang 记成译文语言:简体记 zh、繁体记 zh-Hant,没标时为空。
func TestApplemusicSubtitleTranslationLang(t *testing.T) {
	for _, c := range []struct{ attr, want string }{
		{` xml:lang="zh-Hans"`, "zh"}, {` xml:lang="zh-Hant"`, "zh-Hant"}, {` xml:lang="ja"`, "ja"}, {"", ""},
	} {
		ttml := strings.Replace(appleLocalTTML("subtitle", []string{"L1", "L2"}), ` xml:lang="zh-Hans"`, c.attr, 1)
		p, ok := applemusicParseTTML(ttml)
		if !ok || p.tr == "" {
			t.Fatalf("%q: 应解析出译文: %+v", c.attr, p)
		}
		if p.trLang != c.want {
			t.Errorf("%q: trLang = %q,期望 %q", c.attr, p.trLang, c.want)
		}
	}
}

// 组装 applemusic 候选:译文按它自己标的语言判能不能用、记什么;没标时按目标语言。
func TestRankLyricSourceResultsApplemusicTrLang(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsTranslationLanguage: "en"})

	var lrc, tr strings.Builder
	for i := 0; i < 20; i++ {
		ts := formatLRCTime((10 + i*10) * 1000)
		lrc.WriteString(ts + fmt.Sprintf("いつも line %d\n", i))
		tr.WriteString(ts + fmt.Sprintf("Translated line %d\n", i))
	}
	find := func(trLang string) scoredLyricCandidateResult {
		raw := map[string]lyricSourceResult{"applemusic": {source: "applemusic", lyr: lrc.String(), tr: tr.String(), trLang: trLang, srcDur: 220}}
		for _, r := range rankLyricSourceResults("Artist", "Song", "", 220, raw) {
			if r.Source == "applemusic" {
				return r
			}
		}
		t.Fatal("没有 applemusic 候选")
		return scoredLyricCandidateResult{}
	}
	if r := find("zh"); r.LyricsTr != "" {
		t.Errorf("中文译文不是目标语言 en,不该写进结果: %q", r.LyricsTrLang)
	}
	if r := find("en"); r.LyricsTr == "" || r.LyricsTrLang != "en" {
		t.Errorf("英文译文应写进结果、记 en: tr=%v lang=%q", r.LyricsTr != "", r.LyricsTrLang)
	}
	if r := find(""); r.LyricsTr == "" || r.LyricsTrLang != "en" {
		t.Errorf("没标语言时按目标语言: tr=%v lang=%q", r.LyricsTr != "", r.LyricsTrLang)
	}
}

// 走完整的收集:Apple 译文块标的语言经收集通道进结果(目标是简体中文、译文是繁体时记 zh-Hant)。
func TestFetchCarriesApplemusicTrLang(t *testing.T) {
	withApplemusicCreds(t, "cn")
	withEmptyApplemusicCache(t)
	var body, trs strings.Builder
	for i := 1; i <= 4; i++ {
		fmt.Fprintf(&body, `<p begin="%d.000" end="%d.900" itunes:key="L%d"><span begin="%d.000" end="%d.900">Line %d</span></p>`, i*5, i*5+4, i, i*5, i*5+4, i)
		fmt.Fprintf(&trs, `<text for="L%d">譯文第%d行</text>`, i, i)
	}
	ttml := `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="en"><head><metadata>` +
		`<iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation type="subtitle" xml:lang="zh-Hant">` + trs.String() +
		`</translation></translations></iTunesMetadata></metadata></head><body dur="0:30.000"><div>` + body.String() + `</div></body></tt>`
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			return http.StatusOK, nil, amTestSearchBody(amTestSong("1", "Song", "Artist", "Album", 30000, true))
		case strings.HasSuffix(r.URL.Path, "/songs/1/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(ttml)
		}
		return http.StatusNotFound, nil, ""
	})
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"applemusic": true}
	featuresRef().LyricsTranslationLanguage = "zh"
	_, scored := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "Artist", "Song", "Album", 30, nil)
	for _, r := range scored {
		if r.Source == "applemusic" {
			if r.LyricsTr == "" || r.LyricsTrLang != "zh-Hant" {
				t.Fatalf("译文应带上、记 zh-Hant: tr=%v lang=%q", r.LyricsTr != "", r.LyricsTrLang)
			}
			return
		}
	}
	t.Fatalf("没有 applemusic 候选: %+v", scored)
}
