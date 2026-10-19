package main

import (
	"context"
	"sync"
	"testing"
)

func TestLyricsChosenForShorterCut(t *testing.T) {
	body := "[00:21.39]I guess you know me well\n[03:50.00]What's this strange relationship?"
	for _, c := range []struct {
		name                    string
		lyrics                  string
		resolved, recorded, now float64
		want                    bool
	}{
		{"词按 241 秒选、条目已认 402 秒", body, 241.133, 401.707, 401.7, true},
		{"条目记的时长还是旧的", body, 241.133, 241, 401.7, false},
		{"时长差在 12% 以内", body, 241.133, 260, 260, false},
		{"放的比选词时短(试听段)", body, 241.133, 30, 30, false},
		{"选词时的时长未知", body, 0, 401.707, 401.7, false},
		{"条目没记时长", body, 241.133, 0, 401.7, false},
		{"现在的时长未知", body, 241.133, 401.707, 0, false},
		{"没歌词", "", 241.133, 401.707, 401.7, false},
	} {
		e := enrichEntry{Lyrics: bt(c.lyrics), ResolvedDurationSecs: c.resolved, DurationSecs: c.recorded}
		if got := lyricsChosenForShorterCut(e, c.now); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

// 现存那份按 241 秒选、1271 分,条目已认了现在放的 402 秒:这一轮同一个源只给出 402 秒那一版,旧那份按 0 算,1197 分的
// 胜者换上;同一份词这一轮也在,就按它这一轮的分比;源这一轮没答,不比。条目还记着 241 秒时照旧按存着的分比。
func TestLyricsUpgradeAppliesWhenStoredLyricsFitAShorterCut(t *testing.T) {
	old := "[00:21.39]I guess you know me well\n[03:50.00]What's this strange relationship?"
	cur := enrichEntry{
		Lyrics: bt(old), LyricsSource: "soda", LyricsScore: 1271,
		LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision,
		ResolvedDurationSecs: 241.133, DurationSecs: 401.707,
	}
	extended := scoredLyricCandidateResult{Source: "soda", Lyrics: "[01:00.10]I guess you know me well", Score: 1197}
	if !lyricsUpgradeApplies(cur, []scoredLyricCandidateResult{extended}, &extended, 401.7) {
		t.Error("现存那份是给 241 秒那一版的,402 秒那一版应该换上")
	}
	rescored := scoredLyricCandidateResult{Source: "soda", Lyrics: old, Score: 600}
	if !lyricsUpgradeApplies(cur, []scoredLyricCandidateResult{extended, rescored}, &extended, 401.7) {
		t.Error("同一份词这一轮 600 分,1197 分的胜者应该换上")
	}
	rescored.Score = 1190
	if lyricsUpgradeApplies(cur, []scoredLyricCandidateResult{extended, rescored}, &extended, 401.7) {
		t.Errorf("同一份词这一轮 1190 分,胜者没高出 %d 分不换", lyricsUpgradeMinGain)
	}
	lrclib := scoredLyricCandidateResult{Source: "lrclib", Lyrics: "[01:00.00]x", Score: 1197}
	if lyricsUpgradeApplies(cur, []scoredLyricCandidateResult{lrclib}, &lrclib, 401.7) {
		t.Error("现存那份的来源这一轮没答,没法比,不换")
	}
	stale := cur
	stale.DurationSecs = 241
	if lyricsUpgradeApplies(stale, []scoredLyricCandidateResult{extended}, &extended, 401.7) {
		t.Error("条目还记着 241 秒时照旧按存着的分比")
	}
}

// 重新自动匹配按哪个时长搜:条目记下的时长比选词时长出一截就按它,短了(试听段)或差在 12% 以内照旧按选词时的。
func TestManualRematchSearchesAtTheLongerRecordedDuration(t *testing.T) {
	for _, c := range []struct {
		name           string
		recorded, want float64
	}{
		{"条目已认了更长的时长", 401.7, 401.7},
		{"条目记的更短", 30, 241},
		{"差在 12% 以内", 250, 241},
	} {
		t.Run(c.name, func(t *testing.T) {
			setupRescoreTest(t, []string{"musixmatch"}, nil)
			var mu sync.Mutex
			var searched float64
			stub := musixmatchResolve
			musixmatchResolve = func(ctx context.Context, artist, title string, d float64, trLang, isrc string) musixmatchResult {
				mu.Lock()
				searched = d
				mu.Unlock()
				return stub(ctx, artist, title, d, trLang, isrc)
			}
			key := enrichKey(rescoreTestArtist, "Longer Cut", "Some Album")
			enrichMu.Lock()
			enrichCache = map[string]enrichEntry{key: {
				Lyrics: bt("[00:05.00]Old line"), LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1,
				ResolvedDurationSecs: 241, DurationSecs: c.recorded,
			}}
			enrichMu.Unlock()
			runLyricsRematchOne(context.Background(), key, nil)
			mu.Lock()
			defer mu.Unlock()
			if searched != c.want {
				t.Errorf("按 %v 秒搜了, want %v", searched, c.want)
			}
		})
	}
}

// 重评:现存那份是给短得多的另一版选的,存着的高分不拿来挡冠军;因为换了会丢逐字而留下时,不把选词时长改记成这一轮的。
// 时长对得上时照旧按存着的分留。
func TestRescoreDoesNotShieldLyricsChosenForAShorterCut(t *testing.T) {
	const old = "[00:05.00]Old line one\n[00:15.00]Old line two"
	for _, c := range []struct {
		name              string
		recorded, playing float64
		yrc               string
		wantNew           bool
		wantResolved      float64
	}{
		{"给 241 秒那一版选的、现在放 402 秒", 401.7, 401.7, "", true, 401.7},
		{"时长对得上", 241, 241, "", false, 241},
		{"留下逐字那份时不改记选词时长", 401.7, 401.7, "[5000,1000](5000,1000,0)Old", false, 241},
	} {
		t.Run(c.name, func(t *testing.T) {
			setupRescoreTest(t, []string{"musixmatch"}, nil)
			stub := musixmatchResolve
			musixmatchResolve = func(ctx context.Context, artist, title string, d float64, trLang, isrc string) musixmatchResult {
				r := stub(ctx, artist, title, d, trLang, isrc)
				r.durationSecs = c.playing
				return r
			}
			key := enrichKey(rescoreTestArtist, "Shorter Cut", "Some Album")
			enrichMu.Lock()
			enrichCache = map[string]enrichEntry{key: {
				Lyrics: bt(old), LyricsYRC: bt(c.yrc), LyricsSource: "musixmatch", LyricsScore: 5000,
				LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision,
				ResolvedDurationSecs: 241, DurationSecs: c.recorded,
			}}
			enrichMu.Unlock()
			rescoreLyrics(context.Background(), key, rescoreTestArtist, "Shorter Cut", "Some Album", c.playing)
			e, _ := cacheEntry(t, key)
			if got := !e.Lyrics.EqualString(old); got != c.wantNew {
				t.Errorf("换没换: %v, want %v (%q)", got, c.wantNew, e.Lyrics)
			}
			if e.ResolvedDurationSecs != c.wantResolved {
				t.Errorf("选词时长 %v, want %v", e.ResolvedDurationSecs, c.wantResolved)
			}
		})
	}
}

// 重评:现存那份末句超出现在放的版本(按 337.7 秒选、末句 330 秒,现在放 308 秒),因为换了会丢逐字而留下时,选词时长不改记成
// 这一轮的,lyricsOutrunPlayback 以后还认得出它。
func TestRescoreKeepsOutrunMarkWhenKeepingWordTiming(t *testing.T) {
	const old = "[00:05.00]Old line one\n[05:30.00]Old line two"
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	stub := musixmatchResolve
	musixmatchResolve = func(ctx context.Context, artist, title string, d float64, trLang, isrc string) musixmatchResult {
		r := stub(ctx, artist, title, d, trLang, isrc)
		r.durationSecs = 308
		return r
	}
	key := enrichKey(rescoreTestArtist, "Outrun Cut", "Some Album")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: bt(old), LyricsYRC: bt("[5000,1000](5000,1000,0)Old"), LyricsSource: "musixmatch", LyricsScore: 5000,
		LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision,
		ResolvedDurationSecs: 337.7, DurationSecs: 308,
	}}
	enrichMu.Unlock()
	rescoreLyrics(context.Background(), key, rescoreTestArtist, "Outrun Cut", "Some Album", 308)
	e, _ := cacheEntry(t, key)
	if !e.Lyrics.EqualString(old) {
		t.Fatalf("带逐字的那份应该留下, got %q", e.Lyrics)
	}
	if e.ResolvedDurationSecs != 337.7 {
		t.Errorf("选词时长 %v, want 337.7", e.ResolvedDurationSecs)
	}
	if !lyricsOutrunPlayback(e.Lyrics.String(), e.ResolvedDurationSecs, 308) {
		t.Error("留下之后应该还认得出末句超出现在放的版本")
	}
}
