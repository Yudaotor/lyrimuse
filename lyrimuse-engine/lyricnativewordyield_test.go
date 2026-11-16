package main

import (
	"fmt"
	"strings"
	"testing"
)

const yieldLines = 20

// yieldLRC:第 i 句在 12 秒 + 8 秒 × i 处(再平移 shiftMs),只写前 lines 句。
func yieldLRC(shiftMs, lines int) string {
	var b strings.Builder
	for i := range lines {
		ms := 12000 + 8000*i + shiftMs
		fmt.Fprintf(&b, "[%02d:%02d.%02d]这是第%d句不一样的歌词\n", ms/60000, ms/1000%60, ms%1000/10, i+1)
	}
	return b.String()
}

// yieldYRC:同 yieldLRC 的逐字轴,每句一个词、唱 3 秒。
func yieldYRC(shiftMs, lines int) string {
	var b strings.Builder
	for i := range lines {
		ms := 12000 + 8000*i + shiftMs
		fmt.Fprintf(&b, "[%d,3000](%d,3000,0)这是第%d句不一样的歌词\n", ms, ms, i+1)
	}
	return b.String()
}

func yieldTerms(kv ...any) []scoreTerm {
	var terms []scoreTerm
	for i := 0; i < len(kv); i += 2 {
		terms = append(terms, scoreTerm{Kind: kv[i].(string), Points: kv[i+1].(int)})
	}
	return terms
}

func yieldResult(source string, lrc, yrc string, terms []scoreTerm) scoredLyricCandidateResult {
	score := 0
	for _, t := range terms {
		score += t.Points
	}
	return scoredLyricCandidateResult{Source: source, Lyrics: lrc, LyricsYRC: yrc, HasWordTiming: yrc != "", Score: score,
		ScoreTerms: terms, SourceReportedDurationSecs: 180}
}

// yieldNative:跟播放器同源、只有逐行的那份,专辑、歌名都对得上,1090 分。
func yieldNative() scoredLyricCandidateResult {
	return yieldResult("netease", yieldLRC(0, yieldLines), "", yieldTerms(scoreTermDuration, 280, scoreTermNativeSource, 250,
		scoreTermLines, 40, scoreTermAlbum, 150, scoreTermTitleMatch, 120, scoreTermConsensus, 250))
}

// yieldWord:别家的逐字版,专辑报的是另一张、不加分,比同源那份少 1 分。
func yieldWord(source string, shiftMs, lines int, extra ...scoreTerm) scoredLyricCandidateResult {
	terms := yieldTerms(scoreTermDuration, 279, scoreTermWordTiming, 400, scoreTermLines, 40, scoreTermTitleMatch, 120,
		scoreTermConsensus, 250)
	return yieldResult(source, yieldLRC(shiftMs, lines), yieldYRC(shiftMs, lines), append(terms, extra...))
}

func isolateNativeYieldFeatures(t *testing.T, mode string) {
	t.Helper()
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsSourceMode: mode})
}

func TestNativeSourceWordYieldHandsCrownToAlignedWordVersion(t *testing.T) {
	isolateNativeYieldFeatures(t, lyricsModeSmart)
	lastLine := fmt.Sprintf("这是第%d句不一样的歌词", yieldLines)
	for _, tc := range []struct {
		name    string
		shiftMs int
		tie     bool
		edit    func(lrc, yrc string) (string, string)
	}{
		{"逐字版整首早 0.45 秒", -450, false, nil},
		{"逐字版整首早 0.03 秒", -30, false, nil},
		{"逐字版整首晚 0.06 秒、跟同源那份同分", 60, true, nil},
		{"逐字版最后一句写法不同、时刻对得上", 0, false, func(lrc, yrc string) (string, string) {
			return strings.ReplaceAll(lrc, lastLine, "末尾这句换了写法"), strings.ReplaceAll(yrc, lastLine, "末尾这句换了写法")
		}},
		{"逐字版最后一句正文配得上、时刻早 6 秒", 0, false, func(lrc, yrc string) (string, string) {
			end := 12000 + 8000*(yieldLines-1)
			return lrc, strings.Replace(yrc, fmt.Sprintf("[%d,3000](%d,", end, end), fmt.Sprintf("[%d,3000](%d,", end-6000, end-6000), 1)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			word := yieldWord("qq", tc.shiftMs, yieldLines)
			if tc.edit != nil {
				word.Lyrics, word.LyricsYRC = tc.edit(word.Lyrics, word.LyricsYRC)
			}
			if tc.tie {
				word.Score++
				word.ScoreTerms[0].Points++
			}
			results := []scoredLyricCandidateResult{yieldNative(), word}
			applyNativeSourceWordYield(results)
			if got := scoreTermPoints(results[0].ScoreTerms, scoreTermNativeSourceYield); got != -250 {
				t.Fatalf("同源那份该撤销 250 分,得到 %d: %+v", got, results[0].ScoreTerms)
			}
			if results[0].Score != yieldNative().Score-250 {
				t.Fatalf("同源那份的分该少 250,得到 %d", results[0].Score)
			}
			if top := topScoredIndex(results, []int{results[0].Score, results[1].Score}); top != 1 {
				t.Fatalf("撤销后第一名该是逐字版,得到 %s", results[top].Source)
			}
			if results[1].Score != word.Score || len(results[1].ScoreTerms) != len(word.ScoreTerms) {
				t.Fatalf("逐字版的分不该动: %+v", results[1])
			}
		})
	}
}

func TestNativeSourceWordYieldKeepsNative(t *testing.T) {
	isolateNativeYieldFeatures(t, lyricsModeSmart)
	localFile := yieldNative()
	localFile.Source = localFileLyricsSource
	nativeWithWords := yieldNative()
	nativeWithWords.LyricsYRC, nativeWithWords.HasWordTiming = yieldYRC(0, yieldLines), true
	nativeWithWords.ScoreTerms = append(nativeWithWords.ScoreTerms, scoreTerm{Kind: scoreTermWordTiming, Points: 400})
	nativeWithWords.Score += 400
	behind := yieldNative()
	behind.Score -= 10
	behind.ScoreTerms[0].Points -= 10
	for _, tc := range []struct {
		name    string
		results []scoredLyricCandidateResult
	}{
		{"逐字版整首晚 7.76 秒(另一个版本)", []scoredLyricCandidateResult{yieldNative(), yieldWord("qq", 7760, yieldLines)}},
		{"逐字版整首早 7.76 秒(另一个版本)", []scoredLyricCandidateResult{yieldNative(), yieldWord("qq", -7760, yieldLines)}},
		{"逐字版缺最后两句", []scoredLyricCandidateResult{yieldNative(), yieldWord("qq", 0, yieldLines-2)}},
		{"逐字版带扣分项", []scoredLyricCandidateResult{yieldNative(),
			yieldWord("qq", 0, yieldLines, scoreTerm{Kind: scoreTermSourceDurationNearMiss, Points: -400},
				scoreTerm{Kind: scoreTermConsensus, Points: 400})}},
		{"撤销后的第一名是错开的那份", []scoredLyricCandidateResult{yieldNative(), yieldWord("kugou", 7760, yieldLines),
			yieldWord("qq", 0, yieldLines, scoreTerm{Kind: scoreTermLines, Points: -30})}},
		{"同源那份带逐字", []scoredLyricCandidateResult{nativeWithWords, yieldWord("qq", 0, yieldLines)}},
		{"同源那份是播放器本地歌词", []scoredLyricCandidateResult{localFile, yieldWord("qq", 0, yieldLines)}},
		{"同源那份本来就不是第一名", []scoredLyricCandidateResult{behind, yieldWord("qq", 0, yieldLines)}},
		{"没有同源加分", []scoredLyricCandidateResult{
			yieldResult("netease", yieldLRC(0, yieldLines), "", yieldTerms(scoreTermDuration, 280, scoreTermLines, 40,
				scoreTermAlbum, 800)),
			yieldWord("qq", 0, yieldLines)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := make([]int, len(tc.results))
			terms := make([]int, len(tc.results))
			for i, r := range tc.results {
				before[i], terms[i] = r.Score, len(r.ScoreTerms)
			}
			applyNativeSourceWordYield(tc.results)
			for i, r := range tc.results {
				if r.Score != before[i] || len(r.ScoreTerms) != terms[i] {
					t.Fatalf("整批不该动,%s 变成 %d 分: %+v", r.Source, r.Score, r.ScoreTerms)
				}
			}
		})
	}
}

func TestNativeSourceWordYieldSkipsPriorityMode(t *testing.T) {
	isolateNativeYieldFeatures(t, lyricsModePriority)
	results := []scoredLyricCandidateResult{yieldNative(), yieldWord("qq", -450, yieldLines)}
	applyNativeSourceWordYield(results)
	if results[0].Score != yieldNative().Score || scoreTermPoints(results[0].ScoreTerms, scoreTermNativeSourceYield) != 0 {
		t.Fatalf("顺序优先下不该撤销同源加分: %+v", results[0])
	}
}

// 两条流水线(首轮打分、合并各轮重打分)都走这一步。
func TestNativeSourceWordYieldRunsInBothPipelines(t *testing.T) {
	isolateNativeYieldFeatures(t, lyricsModeSmart)
	nativeLyricSourcesMu.Lock()
	savedNative := nativeLyricSources
	nativeLyricSources = map[string]bool{"netease": true}
	nativeLyricSourcesMu.Unlock()
	t.Cleanup(func() {
		nativeLyricSourcesMu.Lock()
		nativeLyricSources = savedNative
		nativeLyricSourcesMu.Unlock()
	})
	const artist, title, album = "某歌手", "某首歌", "某专辑"
	raw := map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{Lyrics: yieldLRC(0, yieldLines), DurationSecs: 180, Title: title,
			Artist: artist, Album: album, FromLocalClient: true}},
		"qq": {source: "qq", lyr: yieldLRC(-450, yieldLines), yrc: yieldYRC(-450, yieldLines), srcDur: 180,
			matchTitle: title, matchArtist: artist, matchAlbum: "另一张合辑"},
	}
	check := func(stage string, got []scoredLyricCandidateResult) {
		t.Helper()
		if len(got) == 0 || got[0].Source != "qq" {
			t.Fatalf("%s:第一名该是对得上的逐字版,得到 %+v", stage, got)
		}
		for _, r := range got {
			if r.Source == "netease" && scoreTermPoints(r.ScoreTerms, scoreTermNativeSourceYield) != -250 {
				t.Fatalf("%s:同源那份该撤销同源加分: %+v", stage, r.ScoreTerms)
			}
		}
	}
	first := rankLyricSourceResults(artist, title, album, 180, raw)
	check("首轮", first)
	check("合并重打分", mergeLyricCandidateRounds(artist, title, album, 180, first, nil))
}

// 歌曲实体共享算「去掉同源加分的分」时,撤销过的同源加分不再扣第二次。
func TestSongPlanLyricsNetsOutYieldedNativeBonus(t *testing.T) {
	d := &lyricsDecision{Winner: "netease", ScoringVersion: lyricsScoringVersion, Candidates: []lyricsDecisionCandidate{{
		Source: "netease", Score: 900,
		ScoreTerms: []scoreTerm{{Kind: scoreTermNativeSource, Points: 250}, {Kind: scoreTermNativeSourceYield, Points: -250}},
	}}}
	l := songPlanLyricsFor("A|Song|X", songTestLRC(0, songTestWords("y", 4)), "", "netease", false, false, d, t.TempDir())
	if l == nil || l.score != 900 || l.native {
		t.Fatalf("撤销过同源加分的那份该按 900 分、不算自家源加分,得到 %+v", l)
	}
}
