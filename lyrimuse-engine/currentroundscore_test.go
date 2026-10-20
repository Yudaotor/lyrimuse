package main

import (
	"fmt"
	"strings"
	"testing"
)

// timedLyricsFixture:n 行带时间戳的歌词、同轴的逐字和中文译文,每行文字不同(时间轴对齐按文字配对)。
func timedLyricsFixture(n int) (lrc, yrc, tr string) {
	var l, y, z strings.Builder
	for i := 0; i < n; i++ {
		ms := 1000 + i*4000
		ts := formatLRCTime(ms)
		fmt.Fprintf(&l, "[%s]line number %d\n", ts, i)
		fmt.Fprintf(&y, "[%d,3000](%d,3000,0)line number %d\n", ms, ms, i)
		fmt.Fprintf(&z, "[%s]第 %d 行\n", ts, i)
	}
	return l.String(), y.String(), z.String()
}

// 同一段词挂在同一首歌的几个条目下,有的带逐字、有的没有:当前这份带着逐字,这一轮同文的那份没带,按它这一轮的分
// 补上逐字那一项再比,不输给分数更低的另一份。
func TestRescoreKeepsCurrentCreditsWordTimingOfSameTextCandidate(t *testing.T) {
	cur := enrichEntry{Lyrics: bt("shhh"), LyricsSource: "netease", LyricsYRC: bt("[1000,500](1000,500,0)shhh"), LyricsScore: 1305}
	cur.stampLyricsScoring()
	kugou := scoredLyricCandidateResult{Source: "kugou", Lyrics: "shhh live", LyricsYRC: "[1000,500](1000,500,0)shhh live", Score: 1147,
		ScoreTerms: []scoreTerm{{Kind: scoreTermWordTiming, Points: wordTimingPoints}}}
	netease := scoredLyricCandidateResult{Source: "netease", Lyrics: "shhh", Score: 905}
	scored := []scoredLyricCandidateResult{kugou, netease}
	if !rescoreKeepsCurrent(cur, scored, &scored[0]) {
		t.Fatal("当前这份 905+400 分高过冠军 1147,应留着")
	}
	if !rescoreKeepsLyrics(cur, scored, &scored[0], false, false) {
		t.Fatal("重评的总判据也要留")
	}
	// 冠军确实更高:照换。
	higher := kugou
	higher.Score = 1400
	if rescoreKeepsCurrent(cur, []scoredLyricCandidateResult{higher, netease}, &higher) {
		t.Fatal("冠军 1400 分高过当前这份 1305,该换")
	}
	// 同文那份自己带了逐字:没东西可补,输了就换(原来的规则)。
	withWT := netease
	withWT.ScoreTerms = []scoreTerm{{Kind: scoreTermWordTiming, Points: wordTimingPoints}}
	if rescoreKeepsCurrent(cur, []scoredLyricCandidateResult{kugou, withWT}, &kugou) {
		t.Fatal("同文候选已经算了逐字,不该再补一次")
	}
	// 当前这份没有逐字:输了就换。
	plain := cur
	plain.LyricsYRC = bt("")
	if rescoreKeepsCurrent(plain, scored, &scored[0]) {
		t.Fatal("当前这份没有逐字,不补")
	}
	// 打分版本落后也按这一轮的分比:这个分跟版本无关。
	old := cur
	old.LyricsScoringVersion = lyricsScoringVersion - 1
	if !rescoreKeepsCurrent(old, scored, &scored[0]) {
		t.Fatal("打分版本落后时这一轮的分照样能比")
	}
	// 同文那份被判不可用:不补。
	rejected := netease
	rejected.Score = -1
	if rescoreKeepsCurrent(cur, []scoredLyricCandidateResult{kugou, rejected}, &kugou) {
		t.Fatal("同文那份被判不可用,不能靠补分留下")
	}
}

// 当前这份的逐字被这一轮判整首错开(同轴的那份扣了 timelineOffset):逐字不补,同 rescoreWouldLoseWordTiming。
func TestCurrentLyricsRoundScoreSkipsWordTimingWhenTimelineOff(t *testing.T) {
	lrc, yrc, _ := timedLyricsFixture(12)
	cur := enrichEntry{Lyrics: bt(lrc), LyricsSource: "netease", LyricsYRC: bt(yrc)}
	same := scoredLyricCandidateResult{Source: "netease", Lyrics: lrc, Score: 500,
		ScoreTerms: []scoreTerm{{Kind: scoreTermTimelineOffset, Points: -600}}}
	if _, gained, _ := currentLyricsRoundScore(cur, []scoredLyricCandidateResult{{Source: "netease", Lyrics: lrc, Score: 500}}, true); !gained {
		t.Fatal("前提:没被判错开时补逐字")
	}
	score, gained, ok := currentLyricsRoundScore(cur, []scoredLyricCandidateResult{same}, true)
	if !ok || gained || score != 500 {
		t.Fatalf("整首错开时不补逐字,得到 %d %v %v", score, gained, ok)
	}
}

// 歌词源自带的可用译文同样补(+50);机翻的不算。
func TestCurrentLyricsRoundScoreCreditsSourceTranslation(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsTranslationLanguage: "zh"})
	lyrics, _, tr := timedLyricsFixture(6)
	cur := enrichEntry{Lyrics: bt(lyrics), LyricsSource: "musixmatch", LyricsTr: bt(tr), LyricsTrLang: "zh"}
	scored := []scoredLyricCandidateResult{{Source: "musixmatch", Lyrics: lyrics, Score: 700}}
	if score, gained, _ := currentLyricsRoundScore(cur, scored, true); !gained || score != 700+translationPoints {
		t.Fatalf("歌词源自带译文应补 %d 分,得到 %d", translationPoints, score)
	}
	machine := cur
	machine.LyricsTrSource = "machine"
	if score, gained, _ := currentLyricsRoundScore(machine, scored, true); gained || score != 700 {
		t.Fatalf("机翻不补分,得到 %d", score)
	}
	withTr := scored[0]
	withTr.ScoreTerms = []scoreTerm{{Kind: scoreTermTranslation, Points: translationPoints}}
	if _, gained, _ := currentLyricsRoundScore(cur, []scoredLyricCandidateResult{withTr}, true); gained {
		t.Fatal("同文候选已经算了译文,不该再补")
	}
}

// 升级重试按这一轮的分当基准的两处(打分版本落后、时长未知)同样补:不然一份同文没逐字的候选高出 30 分就会把逐字换掉。
func TestUpgradeBaselinesCreditWordTiming(t *testing.T) {
	cur := enrichEntry{Lyrics: bt("shhh"), LyricsSource: "netease", LyricsYRC: bt("[1000,500](1000,500,0)shhh"), LyricsScore: 1305,
		LyricsScoringVersion: lyricsScoringVersion - 1}
	scored := []scoredLyricCandidateResult{{Source: "netease", Lyrics: "shhh", Score: 905}}
	if b, ok := lyricsUpgradeBaseline(cur, scored); !ok || b != 905+wordTimingPoints {
		t.Fatalf("打分版本落后时基准应是 905+%d,得到 %d %v", wordTimingPoints, b, ok)
	}
	if b, ok := lyricsBaselineForUnknownDuration(cur, scored); !ok || b != 905+wordTimingPoints {
		t.Fatalf("时长未知时基准应是 905+%d,得到 %d %v", wordTimingPoints, b, ok)
	}
	// 别的源正文相同不算(升级基准要源和正文都对上)。
	other := []scoredLyricCandidateResult{{Source: "lrclib", Lyrics: "shhh", Score: 905}}
	if _, ok := lyricsUpgradeBaseline(cur, other); ok {
		t.Fatal("别的源的同文候选不当基准")
	}
}
