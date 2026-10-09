package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

// 另一首歌的词:跟 rescoreTestNewBody 一个字都不像,正文够长。
const rescoreOtherSongBody = "[00:05.00]Completely unrelated opening words\n[00:15.00]Nothing in common with the other\n" +
	"[00:25.00]A different chorus entirely here\n[00:35.00]Some more unrelated verses\n[00:45.00]And yet another distinct line\n" +
	"[02:40.00]The unrelated closing words"

func contradictedPicked(terms ...scoreTerm) scoredLyricCandidateResult {
	return scoredLyricCandidateResult{Source: "qq", Score: 1100, Lyrics: rescoreTestNewBody, ScoreTerms: terms}
}

func TestRescoreCurrentContradicted(t *testing.T) {
	good := []scoreTerm{{Kind: scoreTermDuration, Points: 250}, {Kind: scoreTermTitleMatch, Points: 120}, {Kind: scoreTermConsensus, Points: 250}}
	batch := func(picked scoredLyricCandidateResult) []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{picked, {Source: "kugou", Score: 1090, Lyrics: rescoreTestNewBody}}
	}
	scored := batch(contradictedPicked(good...))
	if !rescoreCurrentContradicted(rescoreOtherSongBody, scored, &scored[0]) {
		t.Fatal("当前这份跟两家都不像,冠军歌名对得上、有印证,应判对不上")
	}
	cases := []struct {
		name    string
		current string
		scored  []scoredLyricCandidateResult
	}{
		{"有一家跟当前这份像", rescoreOtherSongBody, append(batch(contradictedPicked(good...)), scoredLyricCandidateResult{Source: "netease", Score: -1, Lyrics: rescoreOtherSongBody})},
		{"冠军歌名没对上", rescoreOtherSongBody, batch(contradictedPicked(good[0], good[2]))},
		{"冠军没有别家印证", rescoreOtherSongBody, batch(contradictedPicked(good[0], good[1]))},
		{"冠军末句跟曲长对不上", rescoreOtherSongBody, batch(contradictedPicked(good[1], good[2]))},
		{"冠军自报曲长对不上", rescoreOtherSongBody, batch(contradictedPicked(append(good, scoreTerm{Kind: scoreTermSourceDurationOff, Points: -400})...))},
		{"只有一份可比", rescoreOtherSongBody, batch(contradictedPicked(good...))[:1]},
		{"当前这份太短", "[00:05.00]Short\n[00:15.00]Line", batch(contradictedPicked(good...))},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if rescoreCurrentContradicted(c.current, c.scored, &c.scored[0]) {
				t.Fatal("不该判对不上")
			}
		})
	}
	if rescoreCurrentContradicted(rescoreOtherSongBody, scored, nil) {
		t.Fatal("没有冠军时不该判对不上")
	}
}

// 当前来源(网易云)这一轮没应答,当前这份是另一首歌的词(带逐字):Musixmatch 和 LRCLIB 两家给出同一份、歌名对得上的
// 词,照样换,逐字不算留的理由;当前这份跟这一轮的词一样时照旧判不了、什么都不动。
func TestRescoreReplacesAnotherSongWhenCurrentSourceSilent(t *testing.T) {
	cases := []struct {
		name     string
		current  string
		replaced bool
	}{
		{"另一首歌的词", rescoreOtherSongBody, true},
		{"同一首歌", "[00:06.00]Brand new first line\n[00:16.00]Brand new second line\n[00:26.00]Brand new third line\n" +
			"[00:36.00]Brand new fourth line\n[00:46.00]Brand new fifth line\n[02:51.00]Brand new last line", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			setupRescoreTest(t, []string{"musixmatch", "lrclib", "netease"}, nil)
			const artist, title, album = rescoreTestArtist, "Silent Song", "Some Album"
			hit, _ := json.Marshal(map[string]any{"trackName": title, "artistName": artist, "albumName": album, "duration": 180, "syncedLyrics": rescoreTestNewBody})
			withKugouFake(t, func(target string) (int, string) {
				switch target {
				case "https://lrclib.net/api/get":
					return http.StatusOK, string(hit)
				case "https://lrclib.net/api/search":
					return http.StatusOK, "[" + string(hit) + "]"
				}
				return http.StatusNotFound, ""
			})
			sharedHostGuard().rateFor = func(string) hostRate { return hostRate{perSec: 1000, burst: 1000} }
			key := enrichKey(artist, title, album)
			const oldYRC = "[5000,1000](5000,500,0)Completely(5500,500,0)unrelated"
			enrichMu.Lock()
			enrichCache = map[string]enrichEntry{key: {
				Lyrics: c.current, LyricsYRC: oldYRC, LyricsSource: "netease", LyricsScore: 1300,
				LyricsScoringVersion: lyricsScoringVersion - 1,
			}}
			enrichMu.Unlock()

			deferred := rescoreLyrics(context.Background(), key, artist, title, album, 180)

			enrichMu.Lock()
			e := enrichCache[key]
			enrichMu.Unlock()
			if !c.replaced {
				if !deferred || e.Lyrics != c.current || e.LyricsSource != "netease" {
					t.Fatalf("当前来源没应答、当前这份跟这一轮一样:应判不了、不动,deferred=%v source=%s", deferred, e.LyricsSource)
				}
				return
			}
			if e.Lyrics != rescoreTestNewBody || e.LyricsYRC == oldYRC || e.LyricsSource == "netease" {
				t.Fatalf("应换上这一轮的词: source=%s lyrics=%q yrc=%q", e.LyricsSource, e.Lyrics, e.LyricsYRC)
			}
			if e.LyricsDecision == nil || e.LyricsDecisionApplied == nil {
				t.Fatalf("换了词就要写决策记录、标成已采用,got %+v / %+v", e.LyricsDecision, e.LyricsDecisionApplied)
			}
		})
	}
}
