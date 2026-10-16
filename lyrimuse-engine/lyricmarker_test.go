package main

import (
	"fmt"
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
	// 三家各自打的轴:时间戳各错开几百毫秒。逐行同一时刻的会被当成同一份副本、不算独立印证(contentConsensusPeers)。
	body := func(shiftMs int) string {
		var b strings.Builder
		for _, l := range []struct {
			ms   int
			text string
		}{
			{8440, "Are we hitting overtime"}, {13450, "Kiss me like I'm gonna die"},
			{17930, "Yeah I might tell you over wine"}, {22960, "That something's in the way this time"},
			{27800, "Maybe your worth is more than mine"}, {32610, "Maybe it's cause I missed my flight"},
			{167320, "Tell me if you wanna go"}, {177180, "Ooh ooh ooh"},
		} {
			ms := l.ms + shiftMs
			fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", ms/60000, ms/1000%60, ms%1000/10, l.text)
		}
		return b.String()
	}
	end := "[03:19.30]Yes sir\n"
	batch := []lyricCandidate{
		{source: "netease", lyrics: body(0) + end + "[03:52.70][Outro]\n", title: "Overtime"},
		{source: "musixmatch", lyrics: body(250) + end, title: "Overtime", hasWordTiming: true},
		{source: "soda", lyrics: body(-300) + end, title: "Overtime"},
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
