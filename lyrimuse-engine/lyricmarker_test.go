package main

import (
	"math"
	"strings"
	"testing"
)

func TestIsLyricMarkerLine(t *testing.T) {
	for _, s := range []string{
		"[Outro]", "(Instrumental)", "（\u00a0MUSIC\u00a0）", "[Chorus: 某人]", "[Verse 2]", "Pre-Chorus:", "【间奏】", "间奏",
		"♪", "…", "...", "~", "(End)", "[Instrumental Break]", "<间奏>", "《尾奏》", "【副歌】", "Instrumental",
	} {
		if !isLyricMarkerLine(s) {
			t.Errorf("%q 该算段落标记", s)
		}
	}
	for _, s := range []string{
		"", "Music is my life", "The end", "[Verse 1] I walk alone", "Verse 1: I walk alone", "Overtime", "(Yes sir)",
		"(x2)", "La la la", "♪ La la la ♪", "Outro of my heart",
		// 光秃秃一行的段落名、拉丁单词说不准是不是唱的:
		"副歌", "end", "Outro", "Music",
	} {
		if isLyricMarkerLine(s) {
			t.Errorf("%q 是唱的词,不该算标记", s)
		}
	}
}

func TestLastLRCTimestampSkipsMarkerLines(t *testing.T) {
	lrc := "[00:04.74]Overtime\n[03:19.47]Yes sir\n[03:52.70][Outro]\n[04:30.00]…\n"
	if got, ok := lastLRCTimestampSecs(lrc); !ok || math.Abs(got-199.47) > 0.001 {
		t.Errorf("lastLRCTimestampSecs = %v %v,want 199.47", got, ok)
	}
}

// 一份歌词末尾多挂一行「[Outro]」时,不能因此算「时长吻合」、让批内别的候选丢掉印证和共识分。
func TestMarkerLineDoesNotStripPeersOfCorroboration(t *testing.T) {
	var body strings.Builder
	for _, l := range []struct{ ts, text string }{
		{"00:08.44", "Are we hitting overtime"}, {"00:13.45", "Kiss me like I'm gonna die"},
		{"00:17.93", "Yeah I might tell you over wine"}, {"00:22.96", "That something's in the way this time"},
		{"00:27.80", "Maybe your worth is more than mine"}, {"00:32.61", "Maybe it's cause I missed my flight"},
		{"02:47.32", "Tell me if you wanna go"}, {"02:57.18", "Ooh ooh ooh"},
	} {
		body.WriteString("[" + l.ts + "]" + l.text + "\n")
	}
	end := "[03:19.30]Yes sir\n"
	batch := []lyricCandidate{
		{source: "netease", lyrics: body.String() + end + "[03:52.70][Outro]\n", title: "Overtime"},
		{source: "musixmatch", lyrics: body.String() + end, title: "Overtime", hasWordTiming: true},
		{source: "soda", lyrics: body.String() + end, title: "Overtime"},
	}
	const dur = 273
	corro := corroboratedEndings(batch, dur)
	peers := contentConsensusPeers("Mk.gee", "Overtime", batch, dur)
	for _, c := range batch {
		if !corro[c.source] || len(peers[c.source]) != 2 {
			t.Errorf("%s:印证 %v、共识 %v,want 都在", c.source, corro[c.source], peers[c.source])
		}
	}
	best, bestScore := "", -1
	for _, c := range batch {
		if sc, _ := scoreLyricCandidateDetailed("Mk.gee", "Overtime", "", dur, c, corro[c.source], len(peers[c.source])); sc > bestScore {
			best, bestScore = c.source, sc
		}
	}
	if best != "musixmatch" {
		t.Errorf("冠军 = %s,want 带逐字的 musixmatch", best)
	}
}
