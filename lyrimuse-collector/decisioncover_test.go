package main

import "testing"

// buildLyricsDecision 必须把候选的展示字段**逐个**抄进存档 —— 漏一个的表现是「解析决策」
// 面板上那一栏永远空着,而缓存里看上去一切正常(字段带 omitempty,压根不会出现在 JSON 里),
// 极难发现。2026-09-01 加 CoverURL 时立的这道闸:以后再往
// scoredLyricCandidateResult 加展示字段,同时在这里补一条断言。
//
// 只盯"展示用"的那几个,不盯 Lyrics —— 存档刻意不存歌词正文(见 lyricsDecisionCandidate
// 的头注)。
func TestBuildLyricsDecisionCopiesDisplayFields(t *testing.T) {
	scored := []scoredLyricCandidateResult{{
		Source:                     "netease",
		Score:                      974,
		Lyrics:                     "[00:01.00]不该进存档\n",
		Title:                      "Shall We Dance(Live)",
		Artist:                     "陈奕迅",
		Album:                      "The Easy Ride Live 陈奕迅演唱会",
		CoverURL:                   "https://p2.music.126.net/abc==/109951170175574203.jpg",
		SourceReportedDurationSecs: 222.066,
		HasWordTiming:              true,
		ScoreTerms:                 []scoreTerm{{Kind: "duration", Points: 252}},
	}}
	d := buildLyricsDecision(
		lyricsDecisionPathFirstResolve, "陈奕迅", "Shall We Dance (Live)", "专辑",
		222, scored, &scored[0], true)

	if len(d.Candidates) != 1 {
		t.Fatalf("候选数 = %d, want 1", len(d.Candidates))
	}
	c := d.Candidates[0]
	checks := []struct {
		name      string
		got, want any
	}{
		{"Source", c.Source, scored[0].Source},
		{"Score", c.Score, scored[0].Score},
		{"Title", c.Title, scored[0].Title},
		{"Artist", c.Artist, scored[0].Artist},
		{"Album", c.Album, scored[0].Album},
		{"CoverURL", c.CoverURL, scored[0].CoverURL},
		{"SourceReportedDurationSecs", c.SourceReportedDurationSecs, scored[0].SourceReportedDurationSecs},
		{"HasWordTiming", c.HasWordTiming, scored[0].HasWordTiming},
	}
	for _, ck := range checks {
		if ck.got != ck.want {
			t.Errorf("%s 没抄进存档: got %v, want %v", ck.name, ck.got, ck.want)
		}
	}
	if len(c.ScoreTerms) != 1 || c.ScoreTerms[0].Kind != "duration" {
		t.Errorf("ScoreTerms 没抄进存档: %+v", c.ScoreTerms)
	}
	if d.Winner != "netease" {
		t.Errorf("Winner = %q, want netease", d.Winner)
	}
}
