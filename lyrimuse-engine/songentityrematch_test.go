package main

import (
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// 重新自动匹配之后,同一共享组跟着这一条:钉着、纯音乐、读穿着校准的不动,有逐字的不换成没逐字的,别的组不动;
// 实体里有手改原件、开关关着时一条都不跟。
func TestShareFollowRematch(t *testing.T) {
	won, plain, words := songShareLRC("won"), songShareLRC("plain"), songShareLRC("words")
	calib := songShareLRC("calibrated")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: won, LyricsSource: "qq", LyricsScore: 1200},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: plain, LyricsSource: "kugou", LyricsScore: 900},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: words, LyricsYRC: "[1000,500](1000,500,0)w", LyricsSource: "netease"},
		"A|Song|Four":  {Song: "s_000000000001", Lyrics: plain, LyricsSource: "kugou"},
		"A|Song|Five":  {Song: "s_000000000001", Lyrics: plain, Instrumental: true},
		"A|Song|Six":   {Song: "s_000000000001", SongShare: 1, Lyrics: plain},
		"A|Song|Seven": {Song: "s_000000000001", Lyrics: calib},
		"A|Song|Eight": {Song: "s_000000000001", Lyrics: calib},
		"B|Other|One":  {Song: "s_000000000002", Lyrics: plain},
	}, true, "A|Song|Four", "A|Song|Eight")
	writeSongSharePins(t, map[string]string{"A|Song|Four": "", "A|Song|Eight": songOffsetFingerprint(calib, "")})

	enrichMu.Lock()
	stamp := enrichEditStampLocked()
	enrichMu.Unlock()
	changed := shareFollowRematch("A|Song|One", time.Unix(1_000_000, 0))
	if !slices.Equal(changed, []string{"A|Song|Two"}) {
		t.Fatalf("只换能换的: %v", changed)
	}
	enrichMu.Lock()
	edited := enrichEditedSinceLocked("A|Song|Two", stamp)
	enrichMu.Unlock()
	if !edited {
		t.Error("跟着换了的要让在飞的后台任务作废")
	}
	if got, _ := cacheEntry(t, "A|Song|Two"); got.Lyrics != won || got.LyricsSource != "qq" ||
		got.LyricsDecisionApplied == nil || got.LyricsDecisionApplied.Path != lyricsDecisionPathSongEntityShare ||
		got.LyricsDecisionApplied.ReusedFrom != "A|Song|One" || got.LyricsEntityOrigin != "" {
		t.Errorf("跟着换成这一条现在那份,出处记同步: %+v", got)
	}
	if _, pre := readPreEntry(t, "A|Song|Two"); pre.Lyrics != plain {
		t.Errorf("换之前留底: %+v", pre)
	}
	for k, want := range map[string]string{"A|Song|Three": words, "A|Song|Four": plain, "A|Song|Five": plain,
		"A|Song|Six": plain, "A|Song|Seven": calib, "B|Other|One": plain} {
		if got, _ := cacheEntry(t, k); got.Lyrics != want {
			t.Errorf("%s 不动: %q", k, got.Lyrics)
		}
	}

	enrichMu.Lock()
	e := enrichCache["A|Song|Six"]
	e.SongShare, e.ManualLyrics, e.Lyrics = 0, true, songShareLRC("mine")
	enrichCache["A|Song|Six"] = e
	e = enrichCache["A|Song|Two"]
	e.Lyrics = plain
	enrichCache["A|Song|Two"] = e
	enrichMu.Unlock()
	if got := shareFollowRematch("A|Song|One", time.Now()); got != nil {
		t.Errorf("实体里有手改原件不跟: %v", got)
	}
	setFeatures(featureFlags{SongEntityShadow: true})
	enrichMu.Lock()
	e = enrichCache["A|Song|Six"]
	e.ManualLyrics, e.SongShare = false, 1
	enrichCache["A|Song|Six"] = e
	enrichMu.Unlock()
	if got := shareFollowRematch("A|Song|One", time.Now()); got != nil {
		t.Errorf("开关关着不跟: %v", got)
	}
}

// 「重新自动匹配」换了或者算下来还是这一份时让共享组跟上,跟上的条数报给 App。
func TestRematchFollowsShareGroupWired(t *testing.T) {
	src, err := os.ReadFile("lyricsrematch.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"\tcase lyricsRematchChanged, lyricsRematchUnchanged, lyricsRematchKeptWordTiming:\n\t\tif followers := shareFollowRematch(key, time.Now()); len(followers) > 0 {\n\t\t\tresult.Followers = len(followers)\n",
	} {
		if !strings.Contains(string(src), want) {
			t.Errorf("runLyricsRematchOne 里找不到: %q", want)
		}
	}
}
