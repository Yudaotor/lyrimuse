package main

import (
	"context"
	"strings"
	"testing"
)

// 跟 rescoreTestNewBody 是同一份词,只多两行元信息、时间少写一位小数:上屏看不出差别,原文不同。
var shownSameBody = "[ti:Shown]\n[offset:0]\n" + strings.ReplaceAll(rescoreTestNewBody, ".00]", ".0]")

// 换成候选之后屏上看不看得出多了或改了什么:正文与时间轴上屏后一样、候选带的逐字 / 译文 / 罗马音 / 背景人声都是现存这份
// 已经有的,才算没有;现存这份多出来的(机翻的译文、候选没给的逐字)不算差别。
func TestLyricsCandidateAddsNothingShown(t *testing.T) {
	cur := enrichEntry{Lyrics: shownSameBody, LyricsYRC: "[5000,1000](5000,500,0)Brand",
		LyricsTr: "[00:05.00]全新的第一句", LyricsTrSource: "machine"}
	same := scoredLyricCandidateResult{Lyrics: rescoreTestNewBody}
	cases := []struct {
		name string
		e    enrichEntry
		c    scoredLyricCandidateResult
		want bool
	}{
		{"只差元信息与时间写法", cur, same, true},
		{"候选带的逐字跟现存的一样", cur, scoredLyricCandidateResult{Lyrics: rescoreTestNewBody, LyricsYRC: "[5000,1000](5000,500,0)Brand\n"}, true},
		{"正文差一个词", cur, scoredLyricCandidateResult{Lyrics: strings.Replace(rescoreTestNewBody, "first", "1st", 1)}, false},
		{"时间差 10 毫秒", cur, scoredLyricCandidateResult{Lyrics: strings.Replace(rescoreTestNewBody, "[00:15.00]", "[00:15.01]", 1)}, false},
		{"候选带来现存没有的逐字", enrichEntry{Lyrics: shownSameBody},
			scoredLyricCandidateResult{Lyrics: rescoreTestNewBody, LyricsYRC: "[5000,1000](5000,500,0)Brand"}, false},
		{"候选带来自己的译文", cur, scoredLyricCandidateResult{Lyrics: rescoreTestNewBody, LyricsTr: "[00:05.00]崭新的第一行"}, false},
		{"候选带来背景人声", cur, scoredLyricCandidateResult{Lyrics: rescoreTestNewBody, LyricsBG: "[6000,500](6000,500,0)ooh"}, false},
		{"现存这份是空的", enrichEntry{}, same, false},
	}
	for _, c := range cases {
		if got := lyricsCandidateAddsNothingShown(c.e, c.c); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
	if keepsShownLyricsOver(enrichEntry{Lyrics: rescoreTestNewBody}, &same) {
		t.Error("原文相同的不归这里管(补逐字、换源记账照旧)")
	}
	if keepsShownLyricsOver(cur, nil) {
		t.Error("没有冠军时谈不上留")
	}
}

// 重评(打分版本落后):冠军跟当前这份原文不同、上屏看不出差别时留着当前这份,打分版本照常追平、决策记录标成没采用;
// 看得出差别的照换;手动重新匹配照换(用户要的就是这一轮的结论)。
func TestRescoreKeepsSameShownLyrics(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	const artist, album = rescoreTestArtist, "Some Album"
	run := func(title, current string, manual bool) enrichEntry {
		key := enrichKey(artist, title, album)
		enrichMu.Lock()
		enrichCache = map[string]enrichEntry{key: {
			Lyrics: current, LyricsSource: "musixmatch", LyricsScore: 900, LyricsScoringVersion: lyricsScoringVersion - 1,
		}}
		enrichMu.Unlock()
		if manual {
			rescoreLyricsWith(withManualLyricSearch(context.Background()), key, artist, title, album, 180, lyricsRescoreOpts{manual: true})
		} else {
			rescoreLyrics(context.Background(), key, artist, title, album, 180)
		}
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return enrichCache[key]
	}

	e := run("Shown Same", shownSameBody, false)
	if e.Lyrics != shownSameBody {
		t.Fatalf("上屏看不出差别,不该换成冠军那份原文: %q", e.Lyrics)
	}
	if e.LyricsScoringVersion != lyricsScoringVersion {
		t.Error("留着也算这一版规则评过,打分版本要追平")
	}
	if e.LyricsDecision == nil || e.LyricsDecision.Applied {
		t.Errorf("决策记录照写、标成没采用: %+v", e.LyricsDecision)
	}
	if e := run("Shown Changed", strings.Replace(shownSameBody, "first line", "first lane", 1), false); e.Lyrics != rescoreTestNewBody {
		t.Errorf("看得出差别照换: %q", e.Lyrics)
	}
	if e := run("Shown Manual", shownSameBody, true); e.Lyrics != rescoreTestNewBody {
		t.Errorf("手动重新匹配照换成这一轮的冠军: %q", e.Lyrics)
	}
}

// 升级重试:冠军分数更高、换上去屏上却看不出差别时不换;现存这份也就是给这个时长选的,时长照记,免得「时长对不上」接着重来。
// 看得出差别的照常升级。
func TestUpgradeRetryKeepsSameShownLyrics(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	const artist, album = rescoreTestArtist, "Some Album"
	run := func(title, current string) enrichEntry {
		key := enrichKey(artist, title, album)
		enrichMu.Lock()
		enrichCache = map[string]enrichEntry{key: {
			Lyrics: current, LyricsSource: "kugou", LyricsScore: 10, LyricsScoringVersion: lyricsScoringVersion,
			ResolvedDurationSecs: 150,
		}}
		enrichMu.Unlock()
		retryLyricsUpgrade(context.Background(), key, artist, title, album, 180, false)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return enrichCache[key]
	}

	e := run("Upgrade Same", shownSameBody)
	if e.Lyrics != shownSameBody || e.LyricsSource != "kugou" {
		t.Fatalf("上屏看不出差别不该升级: source=%q lyrics=%q", e.LyricsSource, e.Lyrics)
	}
	if e.ResolvedDurationSecs != 180 {
		t.Errorf("时长照记成这一轮的: %v", e.ResolvedDurationSecs)
	}
	e = run("Upgrade Changed", strings.Replace(shownSameBody, "first line", "first lane", 1))
	if e.Lyrics != rescoreTestNewBody || e.LyricsSource != "musixmatch" {
		t.Errorf("看得出差别照常升级: source=%q lyrics=%q", e.LyricsSource, e.Lyrics)
	}
}
