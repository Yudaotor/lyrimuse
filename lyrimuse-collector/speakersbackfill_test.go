package main

import (
	"encoding/json"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
	"testing"
)

// mxmMacroWithBody:mxmMacroFixture 的逐行歌词换成 lrc,再挂上 performer_tagging(tagging 为空串时不挂)。
func mxmMacroWithBody(t *testing.T, name, artist string, subLength float64, lrc, tagging string) string {
	t.Helper()
	var root map[string]any
	if err := json.Unmarshal([]byte(mxmMacroFixture(t, name, artist, subLength, 0, 0)), &root); err != nil {
		t.Fatal(err)
	}
	calls := root["message"].(map[string]any)["body"].(map[string]any)["macro_calls"].(map[string]any)
	sub := calls["track.subtitles.get"].(map[string]any)["message"].(map[string]any)["body"].(map[string]any)["subtitle_list"].([]any)[0]
	sub.(map[string]any)["subtitle"].(map[string]any)["subtitle_body"] = lrc
	b, _ := json.Marshal(root)
	if tagging == "" {
		return string(b)
	}
	return mxmMacroWithTagging(t, string(b), tagging)
}

// spkTaggingJSON:spkSpans 的 performer_tagging 形状。
func spkTaggingJSON(t *testing.T, spans []musixmatchPerformerSpan) string {
	t.Helper()
	var content []map[string]any
	for _, sp := range spans {
		var ps []map[string]any
		for _, id := range sp.performers {
			ps = append(ps, map[string]any{"type": "artist", "fqid": id})
		}
		content = append(content, map[string]any{"snippet": sp.text, "performers": ps})
	}
	b, _ := json.Marshal(map[string]any{"completed": true, "content": content})
	return string(b)
}

func spkBackfillEntry() enrichEntry {
	return enrichEntry{Lyrics: spkLRC(20000, spkLines...), LyricsSource: "qq", DurationSecs: 60, LyricsSourcesSeen: []string{"qq", "musixmatch"}}
}

func TestNeedsLyricSpeakersBackfill(t *testing.T) {
	base := spkBackfillEntry()
	with := func(f func(*enrichEntry)) enrichEntry {
		e := base
		f(&e)
		return e
	}
	for _, c := range []struct {
		name          string
		e             enrichEntry
		artist, title string
		want          bool
	}{
		{"多人署名、Musixmatch 给过候选", base, "A & B", "Song", true},
		{"曲名带 feat.", base, "A", "Song (feat. B)", true},
		{"单人署名", base, "A", "Song", false},
		{"补过了", with(func(e *enrichEntry) { e.LyricsSpeakersChecked = lyricsSpeakersVersion }), "A & B", "Song", false},
		{"没有词", with(func(e *enrichEntry) { e.Lyrics = "" }), "A & B", "Song", false},
		{"手改过", with(func(e *enrichEntry) { e.ManualLyrics = true }), "A & B", "Song", false},
		{"Musixmatch 没给过候选", with(func(e *enrichEntry) { e.LyricsSourcesSeen = []string{"qq"} }), "A & B", "Song", false},
		{"正文自带演唱者标记", with(func(e *enrichEntry) { e.Lyrics = spkLRC(0, "男：一", "女：二", "男：三", "女：四") }), "A & B", "Song", false},
		{"已有对得上正文的标注", with(func(e *enrichEntry) {
			e.LyricsSpeakers = &lyricSpeakers{For: lyricSpeakersFingerprint(e.Lyrics, e.LyricsYRC)}
		}), "A & B", "Song", false},
		{"标注对不上当前正文", with(func(e *enrichEntry) { e.LyricsSpeakers = &lyricSpeakers{For: "stale"} }), "A & B", "Song", true},
	} {
		if got := needsLyricSpeakersBackfill(c.e, c.artist, c.title); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"qq": true} })
	if needsLyricSpeakersBackfill(base, "A & B", "Song") {
		t.Error("Musixmatch 这个源关着时不该补问")
	}
}

// 补问一次 Musixmatch:标注换算到现有正文上、记下补过;请求带演唱者标注、只发一次 macro。
func TestBackfillLyricSpeakers(t *testing.T) {
	f := withMxmFake(t, func(action string, r *http.Request) string {
		if action == "macro.subtitles.get" {
			return mxmMacroWithBody(t, "Song", "A & B", 60, spkLRC(5000, spkLines...), spkTaggingJSON(t, spkSpans))
		}
		return mxmEmpty404
	})
	enrichCache = map[string]enrichEntry{"A & B|Song|": spkBackfillEntry()}
	enrichInflight["A & B|Song|"] = true
	backfillLyricSpeakers("A & B|Song|", "A & B", "Song", "", 60)
	e := enrichCache["A & B|Song|"]
	if e.LyricsSpeakers == nil || e.LyricsSpeakersChecked != lyricsSpeakersVersion || e.LyricsSpeakers.LRC[0] != "v1" || e.LyricsSpeakers.LRC[4] != "v2" {
		t.Fatalf("没补上: checked=%d speakers=%+v", e.LyricsSpeakersChecked, e.LyricsSpeakers)
	}
	if enrichInflight["A & B|Song|"] {
		t.Error("补完要清掉 inflight")
	}
	calls := f.called("macro.subtitles.get")
	if len(calls) != 1 {
		t.Fatalf("应只发一次 macro: %v", calls)
	}
	q, _ := neturl.ParseQuery(calls[0][strings.Index(calls[0], "?")+1:])
	if !strings.Contains(q.Get("part"), "track_performer_tagging") {
		t.Errorf("part = %q", q.Get("part"))
	}
	if n := len(f.called("crowd.track.translations.get")); n != 0 {
		t.Errorf("补标注不取译文,却发了 %d 次", n)
	}
}

// 没问成不记(下次启动后播放再试);问成了、只有一位演唱者也记下,之后不再来。
func TestBackfillLyricSpeakersOutcomes(t *testing.T) {
	withMxmFake(t, func(action string, r *http.Request) string { return mxmEmpty404 })
	enrichCache = map[string]enrichEntry{"A & B|Song|": spkBackfillEntry()}
	backfillLyricSpeakers("A & B|Song|", "A & B", "Song", "", 60)
	if e := enrichCache["A & B|Song|"]; e.LyricsSpeakersChecked != 0 || e.LyricsSpeakers != nil {
		t.Errorf("没问成不该记成补过: %+v", e)
	}
	solo := []musixmatchPerformerSpan{{text: strings.Join(spkLines, "\n"), performers: []string{spkA}}}
	withMxmFake(t, func(action string, r *http.Request) string {
		if action == "macro.subtitles.get" {
			return mxmMacroWithBody(t, "Song", "A & B", 60, spkLRC(5000, spkLines...), spkTaggingJSON(t, solo))
		}
		return mxmEmpty404
	})
	backfillLyricSpeakers("A & B|Song|", "A & B", "Song", "", 60)
	if e := enrichCache["A & B|Song|"]; e.LyricsSpeakersChecked != lyricsSpeakersVersion || e.LyricsSpeakers != nil {
		t.Errorf("只有一位演唱者:该记成补过、不写标注: %+v", e)
	}
}

// 问 Musixmatch 的这段时间里正文被换了:取回来的标注不再对应它,不写、也不记成补过。
func TestBackfillLyricSpeakersLyricsChangedMeanwhile(t *testing.T) {
	withMxmFake(t, func(action string, r *http.Request) string {
		if action == "macro.subtitles.get" {
			enrichMu.Lock()
			e := enrichCache["A & B|Song|"]
			e.Lyrics = spkLRC(30000, spkLines[:6]...)
			enrichCache["A & B|Song|"] = e
			enrichMu.Unlock()
			return mxmMacroWithBody(t, "Song", "A & B", 60, spkLRC(5000, spkLines...), spkTaggingJSON(t, spkSpans))
		}
		return mxmEmpty404
	})
	enrichCache = map[string]enrichEntry{"A & B|Song|": spkBackfillEntry()}
	backfillLyricSpeakers("A & B|Song|", "A & B", "Song", "", 60)
	if e := enrichCache["A & B|Song|"]; e.LyricsSpeakers != nil || e.LyricsSpeakersChecked != 0 {
		t.Errorf("正文中途被换了还写了标注: %+v", e)
	}
}

// 解析时 Musixmatch 给出了过身份关的候选才记成补过;没给出或被判掉的不记(播放到时还能补问)。
func TestRefreshSpeakersMarksChecked(t *testing.T) {
	for _, c := range []struct {
		name   string
		scored []scoredLyricCandidateResult
		want   int
	}{
		{"Musixmatch 给出了候选", []scoredLyricCandidateResult{{Source: "musixmatch", Score: 500}}, lyricsSpeakersVersion},
		{"Musixmatch 被判掉", []scoredLyricCandidateResult{{Source: "musixmatch", Score: -1}}, 0},
		{"Musixmatch 没应答", []scoredLyricCandidateResult{{Source: "qq", Score: 900}}, 0},
	} {
		e := spkBackfillEntry()
		refreshSpeakers(&e, c.scored)
		if e.LyricsSpeakersChecked != c.want {
			t.Errorf("%s: checked=%d, want %d", c.name, e.LyricsSpeakersChecked, c.want)
		}
	}
}

// 播放到时的派发链里有补标注这一路。
func TestLyricSpeakersBackfillIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "} else if needsLyricSpeakersBackfill(e, artist, title) && !enrichInflight[key] && speakersBackfillOnce(key) {\n") ||
		!strings.Contains(string(b), "\t\t\tgo backfillLyricSpeakers(key, artist, title, album, durationSecs)\n") {
		t.Error("trackEnrichment 的派发链缺补演唱者标注")
	}
}
