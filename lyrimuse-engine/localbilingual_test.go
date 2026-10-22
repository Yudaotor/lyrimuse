package main

import (
	"fmt"
	"strings"
	"testing"
)

func localLRCResult(t *testing.T, artist, title, lrc string) scoredLyricCandidateResult {
	t.Helper()
	raw := map[string]lyricSourceResult{localFileLyricsSource: {source: localFileLyricsSource, lyr: lrc, srcDur: 220,
		matchTitle: title, matchArtist: artist, identityFromLocalClient: true}}
	for _, r := range rankLyricSourceResults(artist, title, "", 220, raw) {
		if r.Source == localFileLyricsSource {
			return r
		}
	}
	t.Fatal("没有本地 .lrc 的候选")
	return scoredLyricCandidateResult{}
}

func TestRankLocalBilingualLRCMovesChineseToTranslation(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsTranslationLanguage: "zh-Hans"})
	orig := []string{"하늘을 봐", "바람이 불어", "우리 함께", "노래를 해", "밤이 깊어", "별이 빛나", "꿈을 꾸고", "다시 만나", "손을 잡고", "멀리 가자"}
	tr := []string{"看看天空", "风在吹拂", "我们一起", "唱着歌吧", "夜色渐深", "星光闪烁", "做着美梦", "再次相见", "牵着手啊", "走向远方"}
	var b strings.Builder
	for i := range orig {
		ts := formatLRCTime((10 + i*10) * 1000)
		fmt.Fprintf(&b, "%s%s\n%s%s\n", ts, orig[i], ts, tr[i])
	}
	r := localLRCResult(t, "가수", "노래", b.String())
	if containsHan(r.Lyrics) {
		t.Errorf("正文里不该再有中文译文行: %q", r.Lyrics[:60])
	}
	if !strings.Contains(r.Lyrics, formatLRCTime(10000)+orig[0]) {
		t.Errorf("原文留在正文里: %q", r.Lyrics[:60])
	}
	if !strings.Contains(r.LyricsTr, formatLRCTime(10000)+tr[0]) || r.LyricsTrLang != "zh" {
		t.Errorf("中文译文挂在原文的时间戳上、标中文: lang=%q tr=%q", r.LyricsTrLang, r.LyricsTr)
	}
}

func TestRankLocalMixedLanguageSongKeepsBothLines(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsTranslationLanguage: "zh-Hans"})
	var b strings.Builder
	for i := 0; i < 10; i++ {
		ts := formatLRCTime((10 + i*10) * 1000)
		if i%2 == 0 {
			fmt.Fprintf(&b, "%sline number %d goes here\n", ts, i)
		} else {
			fmt.Fprintf(&b, "%s第%d句中文歌词\n", ts, i)
		}
	}
	r := localLRCResult(t, "歌手", "中文歌", b.String())
	if !containsHan(r.Lyrics) || r.LyricsTr != "" {
		t.Errorf("中文歌里的中英混唱不是译文,原样留着: tr=%q", r.LyricsTr)
	}
}
