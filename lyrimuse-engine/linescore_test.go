package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestContentWordCount(t *testing.T) {
	cases := []struct {
		lyrics string
		want   int
	}{
		{"[00:01.00]I don't wanna go", 4},
		{"[00:01.00]They loved 2 kiss on the steps", 7},
		{"[00:01.00]我的歌声里", 5},
		{"[00:01.00]跟着唱 Hallelujah", 4},
		{"[00:01.00]사랑해 baby", 4},
		{"[00:01.00]rock'n'roll, all night!", 3},
		{"[00:01.00]Café olé", 2},
		// 元信息标签行、空行、职员表行不算
		{"[ti:Song]\n[00:00.50]作词 : 某某\n[00:01.00]\n[00:02.00]hello world", 2},
	}
	for _, c := range cases {
		if got := contentWordCount(c.lyrics); got != c.want {
			t.Errorf("contentWordCount(%q) = %d, want %d", c.lyrics, got, c.want)
		}
	}
}

// 同一首歌的几句整句,和把每句从中间拆成两行的写法
var lineScoreSentences = []string{
	"Where have all the good men gone and where are all the gods",
	"Where is the street wise hero to fight the rising odds",
	"Is there a white knight upon a fiery steed tonight",
	"Late at night I toss and turn and dream of what I need",
	"I need a hero I am holding out for a hero now",
	"He has to be strong and he has to be fast and fresh",
	"He has to be sure and it has to be soon tonight",
	"Somewhere after midnight in my wildest fantasy again",
}

func lineScoreLRC(sentences []string, split bool) string {
	var b strings.Builder
	sec := 10
	for _, s := range sentences {
		if !split {
			fmt.Fprintf(&b, "[00:%02d.00]%s\n", sec, s)
			sec += 4
			continue
		}
		words := strings.Fields(s)
		half := len(words) / 2
		fmt.Fprintf(&b, "[00:%02d.00]%s\n", sec, strings.Join(words[:half], " "))
		fmt.Fprintf(&b, "[00:%02d.00]%s\n", sec+2, strings.Join(words[half:], " "))
		sec += 4
	}
	return b.String()
}

func linesTermOf(terms []scoreTerm) int {
	for _, t := range terms {
		if t.Kind == scoreTermLines {
			return t.Points
		}
	}
	return 0
}

func TestLinesTermIgnoresLineSplitting(t *testing.T) {
	whole := lyricCandidate{source: "soda", lyrics: lineScoreLRC(lineScoreSentences, false), title: "Hero", artist: "Singer", hasUsableTranslation: true}
	split := lyricCandidate{source: "petitlyrics", lyrics: lineScoreLRC(lineScoreSentences, true), title: "Hero", artist: "Singer"}
	missing := lyricCandidate{source: "lrclib", lyrics: lineScoreLRC(lineScoreSentences[:5], false), title: "Hero", artist: "Singer"}
	cands := []lyricCandidate{whole, split, missing}
	applyLineScoreReference(cands)

	score := func(c lyricCandidate) (int, int) {
		s, terms := scoreLyricCandidateDetailed("Singer", "Hero", "", 0, c, false, 0)
		return s, linesTermOf(terms)
	}
	wholeScore, wholeLines := score(cands[0])
	splitScore, splitLines := score(cands[1])
	_, missingLines := score(cands[2])
	if wholeLines != len(lineScoreSentences) || splitLines != wholeLines {
		t.Errorf("行数项:整句 %d、拆行 %d,都该是 %d(参照取整句的每行词数)", wholeLines, splitLines, len(lineScoreSentences))
	}
	if missingLines >= wholeLines {
		t.Errorf("少了一半段落的行数项 %d 不该追上完整的 %d", missingLines, wholeLines)
	}
	if wholeScore <= splitScore {
		t.Errorf("带译文的整句写法 %d 该胜过拆行写法 %d", wholeScore, splitScore)
	}
}

func TestApplyLineScoreReference(t *testing.T) {
	// 一条候选:折出来就是自己的行数
	one := []lyricCandidate{{lyrics: lineScoreLRC(lineScoreSentences, true)}}
	applyLineScoreReference(one)
	if got := contentLineEquivalent(one[0]); got != 2*len(lineScoreSentences) {
		t.Errorf("单条候选折算 %d,该是实际行数 %d", got, 2*len(lineScoreSentences))
	}
	// 纯文本、没时间戳、不够 5 行的不进中位,但照样拿到参照
	cands := []lyricCandidate{
		{lyrics: lineScoreLRC(lineScoreSentences, false)},
		{lyrics: lineScoreLRC(lineScoreSentences, true), plainTextOnly: true},
		{lyrics: lineScoreLRC(lineScoreSentences[:2], true)},
	}
	applyLineScoreReference(cands)
	want := float64(contentWordCount(cands[0].lyrics)) / float64(len(lineScoreSentences))
	for i, c := range cands {
		if c.lineWordsRef != want {
			t.Errorf("候选 %d 的参照 %v,该是 %v", i, c.lineWordsRef, want)
		}
	}
	// 偶数份取中间两份的平均
	two := []lyricCandidate{{lyrics: lineScoreLRC(lineScoreSentences, false)}, {lyrics: lineScoreLRC(lineScoreSentences, true)}}
	applyLineScoreReference(two)
	whole := float64(contentWordCount(two[0].lyrics)) / float64(len(lineScoreSentences))
	if want := (whole + whole/2) / 2; two[0].lineWordsRef != want {
		t.Errorf("两份候选的参照 %v,该是两者平均 %v", two[0].lineWordsRef, want)
	}
	// 没算过参照时按实际行数
	if got := contentLineEquivalent(lyricCandidate{lyrics: lineScoreLRC(lineScoreSentences, true)}); got != 2*len(lineScoreSentences) {
		t.Errorf("没有参照时折算 %d,该是实际行数", got)
	}
}

// 两条批量打分的流水线都要在打分前算好参照,漏一条那一路就退回按实际行数计分。
func TestLineScoreReferenceWiredInBothBatchPaths(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"inheritIdentityTerms(title, album, cands, consensusPeers)\n\tapplyLineScoreReference(cands)",
		"inheritIdentityTerms(title, album, candidates, consensusPeers)\n\tapplyLineScoreReference(candidates)",
	} {
		if !containsCode(string(src), want) {
			t.Errorf("enrich.go 缺少 %q", want)
		}
	}
}
