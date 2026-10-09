package main

import (
	"fmt"
	"strings"
	"testing"
)

// tlOffLRC / tlOffYRC:同一份十行歌词的整行 LRC 与逐字轴,第一行从 startMs 起、每行隔 10 秒。
func tlOffLRC(startMs int) string {
	var b strings.Builder
	for i := range 10 {
		ms := startMs + i*10000
		fmt.Fprintf(&b, "[%02d:%02d.%02d]Line number %d goes here\n", ms/60000, ms/1000%60, ms%1000/10, i+1)
	}
	return b.String()
}

func tlOffYRC(startMs int) string {
	var b strings.Builder
	for i := range 10 {
		ms := startMs + i*10000
		fmt.Fprintf(&b, "[%d,2000](%d,2000,0)Line number %d goes here\n", ms, ms, i+1)
	}
	return b.String()
}

// 当前这份有逐字、整首晚 2.5 秒,冠军是对齐的那份、没有逐字:这一轮有一份跟当前这份同轴的候选扣了 timelineOffset,
// 就不再为逐字留着当前这份;同轴的那份没被扣、被扣的是另一份轴、扣的是别的项,都照旧留着。
func TestRescoreWouldLoseWordTimingOffTimeline(t *testing.T) {
	cur := enrichEntry{Lyrics: tlOffLRC(7500), LyricsYRC: tlOffYRC(7500), LyricsSource: "musixmatch", LyricsScore: 1030,
		LyricsScoringVersion: lyricsScoringVersion - 1}
	winner := scoredLyricCandidateResult{Source: "applemusic", Lyrics: tlOffLRC(5000), Score: 694}
	offset := []scoreTerm{{Kind: scoreTermTimelineOffset, Points: -600}}
	sameAxis := scoredLyricCandidateResult{Source: "musixmatch", Lyrics: tlOffLRC(7500), LyricsYRC: tlOffYRC(7500), Score: 430,
		ScoreTerms: offset}
	cases := []struct {
		name  string
		other scoredLyricCandidateResult
		want  bool
	}{
		{"同轴的那份被判整首错开", sameAxis, false},
		{"同轴的那份没被扣分", scoredLyricCandidateResult{Source: "musixmatch", Lyrics: tlOffLRC(7500), LyricsYRC: tlOffYRC(7500), Score: 1030}, true},
		{"被扣分的是另一份轴", scoredLyricCandidateResult{Source: "lrclib", Lyrics: tlOffLRC(11000), Score: 100, ScoreTerms: offset}, true},
		{"扣的不是整首错开那一项", scoredLyricCandidateResult{Source: "musixmatch", Lyrics: tlOffLRC(7500), LyricsYRC: tlOffYRC(7500), Score: 430,
			ScoreTerms: []scoreTerm{{Kind: scoreTermTimelineIntrusion, Points: -600}}}, true},
	}
	for _, c := range cases {
		scored := []scoredLyricCandidateResult{winner, c.other}
		if got := rescoreWouldLoseWordTiming(cur, scored, &scored[0]); got != c.want {
			t.Errorf("%s: rescoreWouldLoseWordTiming = %v, want %v", c.name, got, c.want)
		}
		if got := rescoreKeepsLyrics(cur, scored, &scored[0], false, false); got != c.want {
			t.Errorf("%s: rescoreKeepsLyrics = %v, want %v", c.name, got, c.want)
		}
	}
	// 当前这份已经是这一版的分(上一轮为逐字留着它时盖的版本号,分数还是旧的),这一轮回来的同一份只是正文写法变了:
	// 同轴的那份被判整首错开就不拿存的分数比,没被判照旧比。
	stamped := cur
	stamped.Lyrics = tlOffLRC(7500) + "\n"
	stamped.stampLyricsScoring()
	for _, c := range []struct {
		name  string
		other scoredLyricCandidateResult
		want  bool
	}{
		{"这一版的旧分数、同轴的那份被判整首错开", sameAxis, false},
		{"这一版的旧分数、同轴的那份没被扣分", scoredLyricCandidateResult{Source: "musixmatch", Lyrics: tlOffLRC(7500), LyricsYRC: tlOffYRC(7500), Score: 1030}, true},
	} {
		scored := []scoredLyricCandidateResult{winner, c.other}
		if got := rescoreKeepsCurrent(stamped, scored, &scored[0]); got != c.want {
			t.Errorf("%s: rescoreKeepsCurrent = %v, want %v", c.name, got, c.want)
		}
		if got := rescoreKeepsLyrics(stamped, scored, &scored[0], true, false); got != c.want {
			t.Errorf("%s: rescoreKeepsLyrics = %v, want %v", c.name, got, c.want)
		}
	}
	// 比的是显示出来的那条轴:整行 LRC 不同、逐字轴是同一份,照样认得出。
	wordsOnly := scoredLyricCandidateResult{Source: "musixmatch", Lyrics: tlOffLRC(9000), LyricsYRC: tlOffYRC(7500), Score: 430, ScoreTerms: offset}
	if !rescoreCurrentTimelineOff(cur, []scoredLyricCandidateResult{winner, wordsOnly}) {
		t.Error("整行 LRC 不同、逐字轴同一份的被判错开候选应当认得出")
	}
}
