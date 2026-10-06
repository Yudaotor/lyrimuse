package main

import "testing"

// 有纯音乐标记时,被判版本不符的歌词不当冠军;歌词头 [ti:] 多出的版本限定词也算版本不符(09 章决策 194)。

func TestLyricHeaderClaimsOtherVersion(t *testing.T) {
	remixLRC := "[ar:Some Artist]\n[ti:Song (Someone Remix)]\n[00:01.00]a\n[00:05.00]b\n[00:09.00]c\n"
	cases := []struct {
		label             string
		localTitle, album string
		lyrics            string
		want              bool
	}{
		{"歌词头多出 remix", "Song", "Album", remixLRC, true},
		{"歌词头只写歌名", "Song", "Album", "[ti:Song]\n[00:01.00]a\n", false},
		{"没有歌词头", "Song", "Album", "[00:01.00]a\n[00:05.00]b\n", false},
		{"本地是现场版、歌词头没写 Live(沉默不算)", "Song (Live)", "Album", "[ti:Song]\n[00:01.00]a\n", false},
		{"两边都是现场版", "Song (Live)", "Album", "[ti:Song (Live)]\n[00:01.00]a\n", false},
		{"本地专辑带现场标记、歌词头写 Live", "Song", "某某演唱会", "[ti:Song (Live)]\n[00:01.00]a\n", false},
		{"歌词头多出语种标签不算", "Song", "Album", "[ti:Song (粤语)]\n[00:01.00]a\n", false},
		{"长副标题不是版本限定词", "Song", "Album", "[ti:Song(电视剧《某某》片尾曲 / 某某广告曲)]\n[00:01.00]a\n", false},
		{"歌词头多出 edit", "Song", "Album", "[ti:Song (Anime Size Edit)]\n[00:01.00]a\n", true},
	}
	for _, c := range cases {
		if got := lyricHeaderClaimsOtherVersion(c.localTitle, c.album, 200, c.lyrics, "", 200); got != c.want {
			t.Errorf("%s: got %v, want %v", c.label, got, c.want)
		}
	}
}

// 端到端:同一份歌词、同样的逐字与时长,只差歌词头写的是不是另一个版本,分数要拉开、且带上版本不符那一项。
func TestScoreLyricCandidatePenalizesHeaderVersion(t *testing.T) {
	body := "[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n"
	base := lyricCandidate{source: "kugou", title: "Song", hasWordTiming: true, wordTimingYRC: "x"}
	good := base
	good.lyrics = "[ti:Song]\n" + body
	bad := base
	bad.lyrics = "[ti:Song (Someone Remix)]\n" + body
	gs, _ := scoreLyricCandidateDetailed("Artist", "Song", "", 9, good, false, 0)
	bs, terms := scoreLyricCandidateDetailed("Artist", "Song", "", 9, bad, false, 0)
	if gs-bs < 400 {
		t.Errorf("歌词头写着另一个版本的候选(%d)要比同版本的(%d)低出决定性的差距", bs, gs)
	}
	found := false
	for _, term := range terms {
		if term.Kind == scoreTermVersionTags && term.Points == -versionMismatchPenalty {
			found = true
		}
	}
	if !found {
		t.Errorf("版本不符那一项没出现在明细里: %+v", terms)
	}
}

func TestPickLyricCandidateInstrumentalMarkerSkipsOtherVersion(t *testing.T) {
	saved := features()
	defer func() { setFeatures(saved) }()
	enabled := map[string]bool{"kugou": true, "qq": true, "lrclib": true}
	mismatched := scoredLyricCandidateResult{Source: "kugou", Score: 321,
		ScoreTerms: []scoreTerm{{Kind: scoreTermVersionTags, Points: -versionMismatchPenalty}}}
	marker := scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
	sameVersion := scoredLyricCandidateResult{Source: "qq", Score: 200}

	setFeatures(featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart})
	if got := pickLyricCandidate([]scoredLyricCandidateResult{mismatched, marker}); got != nil {
		t.Fatalf("有纯音乐标记、唯一的候选又是别的版本:不该选出冠军,得到 %v", got.Source)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{mismatched, marker, sameVersion}); got == nil || got.Source != "qq" {
		t.Fatalf("有纯音乐标记时跳过别的版本、选同版本的 qq,得到 %v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{mismatched}); got == nil || got.Source != "kugou" {
		t.Fatalf("没有纯音乐标记时照旧(扣过分也能当冠军),得到 %v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{sameVersion, marker}); got == nil || got.Source != "qq" {
		t.Fatalf("有纯音乐标记、但候选是同一版本:以正文为准,得到 %v", got)
	}

	setFeatures(featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModePriority,
		LyricsSourceOrder: []string{"kugou", "qq", "lrclib"}})
	if got := pickLyricCandidate([]scoredLyricCandidateResult{mismatched, marker, sameVersion}); got == nil || got.Source != "qq" {
		t.Fatalf("顺序优先:排最前的 kugou 是别的版本,有标记时跳到下一个源,得到 %v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{mismatched, marker}); got != nil {
		t.Fatalf("顺序优先:都不能用时不选,得到 %v", got.Source)
	}
}

func TestRescoreTurnsInstrumental(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]a\n", LyricsSource: "kugou"}
	mismatched := scoredLyricCandidateResult{Source: "kugou", Score: 321,
		ScoreTerms: []scoreTerm{{Kind: scoreTermVersionTags, Points: -versionMismatchPenalty}}}
	marker := scoredLyricCandidateResult{Source: "lrclib", Score: -1, Instrumental: true}
	if !rescoreTurnsInstrumental(e, []scoredLyricCandidateResult{mismatched, marker}) {
		t.Errorf("现有歌词的来源这一轮被判别的版本、又有纯音乐标记:该按纯音乐处理")
	}
	if rescoreTurnsInstrumental(e, []scoredLyricCandidateResult{mismatched}) {
		t.Errorf("没有纯音乐标记:不动")
	}
	plain := mismatched
	plain.ScoreTerms = nil
	if rescoreTurnsInstrumental(e, []scoredLyricCandidateResult{plain, marker}) {
		t.Errorf("现有歌词的来源这一轮没被判版本不符:不动")
	}
	other := e
	other.LyricsSource = "qq"
	if rescoreTurnsInstrumental(other, []scoredLyricCandidateResult{mismatched, marker}) {
		t.Errorf("被判版本不符的不是现有歌词的来源:不动")
	}
	already := e
	already.Instrumental = true
	if rescoreTurnsInstrumental(already, []scoredLyricCandidateResult{mismatched, marker}) {
		t.Errorf("已经标了纯音乐:不重复处理")
	}
}
