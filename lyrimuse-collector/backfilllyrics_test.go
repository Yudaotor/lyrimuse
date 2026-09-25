package main

import (
	"os"
	"strings"
	"testing"
)

func TestAdoptBackfilledLyrics(t *testing.T) {
	dec := &lyricsDecision{Path: lyricsDecisionPathPeripheral, Applied: true}
	fresh := enrichEntry{
		Lyrics: "[00:01.00]hi", LyricsSource: "kugou", LyricsScore: 900, LyricsScoringVersion: lyricsScoringVersion,
		ResolvedDurationSecs: 200, LyricsTr: "[00:01.00]嗨", LyricsTrLang: "zh", LyricsRoma: "[00:01.00]hai",
		LyricsYRC: "[1000,500](1000,500,0)hi", SongLanguage: "en",
		LyricsDecision: dec, LyricsDecisionApplied: dec,
		LyricsSourcesSeen: []string{"kugou"}, LyricsSourcesResponded: []string{"kugou", "qq"}, LyricsSourcesSkipped: []string{"lrclib"},
		CoverURL: "https://example.invalid/fresh.jpg",
	}

	e := enrichEntry{CoverURL: "https://example.invalid/own.jpg", PlainLyrics: "plain"}
	if !adoptBackfilledLyrics(&e, fresh) {
		t.Fatal("空歌词条目该收下")
	}
	if e.Lyrics != fresh.Lyrics || e.LyricsSource != "kugou" || e.LyricsScore != 900 || e.LyricsScoringVersion != lyricsScoringVersion ||
		e.ResolvedDurationSecs != 200 || e.LyricsTr != fresh.LyricsTr || e.LyricsTrLang != "zh" || e.LyricsRoma != fresh.LyricsRoma ||
		e.LyricsYRC != fresh.LyricsYRC || e.SongLanguage != "en" || e.LyricsDecision != dec || e.LyricsDecisionApplied != dec ||
		len(e.LyricsSourcesSeen) != 1 || len(e.LyricsSourcesResponded) != 2 || len(e.LyricsSourcesSkipped) != 1 {
		t.Fatalf("歌词字段没收全: %+v", e)
	}
	if e.CoverURL != "https://example.invalid/own.jpg" || e.PlainLyrics != "plain" {
		t.Fatalf("歌词以外的字段不归这里管: cover=%q plain=%q", e.CoverURL, e.PlainLyrics)
	}

	for name, existing := range map[string]enrichEntry{
		"已有歌词":  {Lyrics: "[00:01.00]old", LyricsSource: "qq"},
		"手改过":   {ManualLyrics: true},
		"确证纯音乐": {Instrumental: true},
	} {
		e := existing
		if adoptBackfilledLyrics(&e, fresh) {
			t.Errorf("%s:不该收", name)
		}
		if e.Lyrics != existing.Lyrics || e.LyricsSource != existing.LyricsSource {
			t.Errorf("%s:条目被改了: %+v", name, e)
		}
	}
	e = enrichEntry{}
	if adoptBackfilledLyrics(&e, enrichEntry{LyricsDecision: dec}) || e.LyricsDecision != nil {
		t.Fatal("这一轮没选出歌词:什么都不收")
	}
}

// 接线守卫:补外围字段那一轮标自己的决策路径,收下歌词前核对改动序号。
func TestPeripheralBackfillAdoptionIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, needle := range []string{
		`resolveTrackEnrichment(ctx, artist, title, album, durationSecs, "", nil, lyricsDecisionPathPeripheral)`,
		`resolveTrackEnrichment(ctx, artist, title, album, durationSecs, deviceCoverURL, early, lyricsDecisionPathFirstResolve)`,
		"lyricsAdopted := !enrichEditedSinceLocked(key, stamp) && adoptBackfilledLyrics(&e, fresh)",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
}
