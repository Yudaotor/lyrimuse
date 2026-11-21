package main

import (
	"encoding/json"
	"os"
	"testing"
)

// testdata/megalobiz 里那一首(正文已置乱):Megalobiz 那份正文跟 Apple Music 的一致,时间轴整体晚约 8 秒。
func megalobizDorofeevaRaw(t *testing.T) (mgz, am string) {
	t.Helper()
	raw, err := os.ReadFile("testdata/megalobiz/dorofeeva-lrc.json")
	if err != nil {
		t.Fatal(err)
	}
	var body megalobizLRCBody
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	amRaw, err := os.ReadFile("testdata/megalobiz/dorofeeva-applemusic.lrc")
	if err != nil {
		t.Fatal(err)
	}
	return megalobizBuildLRC(body), string(amRaw)
}

func megalobizRanked(t *testing.T, raw map[string]lyricSourceResult) map[string]scoredLyricCandidateResult {
	t.Helper()
	out := map[string]scoredLyricCandidateResult{}
	for _, c := range rankLyricSourceResults("DOROFEEVA", "Кохаю, але не зовсім", "Кохаю, але не зовсім - Single", 199.567, raw) {
		out[c.Source] = c
	}
	return out
}

func TestMegalobizTimelinePenaltyDorofeeva(t *testing.T) {
	mgz, am := megalobizDorofeevaRaw(t)
	mgzRes := lyricSourceResult{source: "megalobiz", lyr: mgz, srcDur: 201.8, matchTitle: "Кохаю, але не зовсім", matchArtist: "Dorofeeva"}
	amRes := lyricSourceResult{source: "applemusic", lyr: am, srcDur: 199.567, matchTitle: "Кохаю, але не зовсім", matchArtist: "DOROFEEVA"}

	both := megalobizRanked(t, map[string]lyricSourceResult{"megalobiz": mgzRes, "applemusic": amRes})
	m, a := both["megalobiz"], both["applemusic"]
	t.Logf("megalobiz + applemusic: megalobiz=%d %v applemusic=%d %v", m.Score, m.ScoreTerms, a.Score, a.ScoreTerms)
	if scoreTermPoints(m.ScoreTerms, scoreTermConsensus) == 0 {
		t.Fatalf("前提:两份正文有共识 %v", m.ScoreTerms)
	}
	if scoreTermPoints(m.ScoreTerms, scoreTermTimelineOffset) != -timelineOffsetPenalty {
		t.Errorf("整体晚 8 秒的 Megalobiz 应扣时间轴分: %v", m.ScoreTerms)
	}
	if scoreTermPoints(a.ScoreTerms, scoreTermTimelineOffset) != 0 {
		t.Errorf("别的源不动: %v", a.ScoreTerms)
	}
	if a.Score-m.Score < timelineOffsetPenalty/2 {
		t.Errorf("Apple 应明显领先: %d vs %d", a.Score, m.Score)
	}

	solo := megalobizRanked(t, map[string]lyricSourceResult{"megalobiz": mgzRes})["megalobiz"]
	t.Logf("megalobiz only: %d %v", solo.Score, solo.ScoreTerms)
	if scoreTermPoints(solo.ScoreTerms, scoreTermTimelineOffset) != 0 {
		t.Errorf("没有别家可比时不扣: %v", solo.ScoreTerms)
	}

	// 同一份正文、时间轴挪到跟 Apple 对齐:不扣。
	aligned := mgzRes
	aligned.lyr = am
	ok := megalobizRanked(t, map[string]lyricSourceResult{"megalobiz": aligned, "applemusic": amRes})["megalobiz"]
	if scoreTermPoints(ok.ScoreTerms, scoreTermTimelineOffset) != 0 {
		t.Errorf("对得上的不扣: %v", ok.ScoreTerms)
	}
}

func megalobizShiftedLRC(n, startMs, stepMs, shiftMs int) string {
	var s string
	for i := 0; i < n; i++ {
		s += formatLRCStamp(startMs+i*stepMs+shiftMs) + "Line number " + string(rune('A'+i)) + " goes here\n"
	}
	return s
}

// 判据:有一家对得上就不扣;对不上的都同向平移才扣;两个方向都有不扣;不在共识名单里的不算;别的源不扣。
func TestApplyHandTypedTimelinePenalty(t *testing.T) {
	base := megalobizShiftedLRC(20, 10000, 8000, 0)
	cand := func(src, lrc string, peers ...string) scoredLyricCandidateResult {
		return scoredLyricCandidateResult{Source: src, Lyrics: lrc, Score: 500, ConsensusPeers: peers}
	}
	cases := []struct {
		name string
		in   []scoredLyricCandidateResult
		want bool
	}{
		{"晚 2 秒", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 2000), "qq"), cand("qq", base)}, true},
		{"早 2 秒", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, -2000), "qq"), cand("qq", base)}, true},
		{"晚 1.2 秒不到阈值", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 1200), "qq"), cand("qq", base)}, false},
		{"有一家对得上", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000), "qq", "netease"), cand("qq", base),
			cand("netease", megalobizShiftedLRC(20, 10000, 8000, 3000))}, false},
		{"两个方向都有", []scoredLyricCandidateResult{cand("megalobiz", base, "qq", "netease"), cand("qq", megalobizShiftedLRC(20, 10000, 8000, 3000)),
			cand("netease", megalobizShiftedLRC(20, 10000, 8000, -3000))}, false},
		{"不在共识名单里", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000), "netease"), cand("qq", base)}, false},
		{"共识名单按家族认", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000), "deezer"), cand("lyricfind", base)}, true},
		{"共识名单按家族认(名单里是家族名、在场的是并进来的那一家)", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000), "lyricfind"), cand("deezer", base)}, true},
		{"没有共识", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000)), cand("qq", base)}, false},
		{"淘汰的不算", []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000), "qq"),
			{Source: "qq", Lyrics: base, Score: -1}}, false},
	}
	for _, c := range cases {
		applyHandTypedTimelinePenalty(lyricProviders(), c.in)
		got := scoreTermPoints(c.in[0].ScoreTerms, scoreTermTimelineOffset) == -timelineOffsetPenalty
		if got != c.want {
			t.Errorf("%s: 扣了 = %v,期望 %v", c.name, got, c.want)
		}
		if got && c.in[0].Score != 1 {
			t.Errorf("%s: 扣完夹到 1: %d", c.name, c.in[0].Score)
		}
		for _, r := range c.in[1:] {
			if len(r.ScoreTerms) != 0 {
				t.Errorf("%s: 别的源不动: %s %v", c.name, r.Source, r.ScoreTerms)
			}
		}
	}
	// 别的源整体错开也不归它管。
	other := []scoredLyricCandidateResult{cand("lrclib", megalobizShiftedLRC(20, 10000, 8000, 3000), "qq"), cand("qq", base)}
	applyHandTypedTimelinePenalty(lyricProviders(), other)
	if len(other[0].ScoreTerms) != 0 {
		t.Errorf("只看手打时间轴的源: %v", other[0].ScoreTerms)
	}
	// 认哪个源由描述符定:把 lrclib 登记成手打时间轴,同一份输入就扣它。
	lrclib := lyricProviders().descriptor(lyricSourceLRCLIB)
	lrclib.HandTypedTimeline = true
	defer func() { lrclib.HandTypedTimeline = false }()
	marked := []scoredLyricCandidateResult{cand("lrclib", megalobizShiftedLRC(20, 10000, 8000, 3000), "qq"), cand("qq", base)}
	applyHandTypedTimelinePenalty(lyricProviders(), marked)
	if scoreTermPoints(marked[0].ScoreTerms, scoreTermTimelineOffset) != -timelineOffsetPenalty {
		t.Errorf("登记成手打时间轴的源该扣: %v", marked[0].ScoreTerms)
	}
	// 已经被批级判定扣过的不重复扣。
	twice := []scoredLyricCandidateResult{cand("megalobiz", megalobizShiftedLRC(20, 10000, 8000, 3000), "qq"), cand("qq", base)}
	twice[0].ScoreTerms = []scoreTerm{{Kind: scoreTermTimelineOffset, Points: -timelineOffsetPenalty}}
	applyHandTypedTimelinePenalty(lyricProviders(), twice)
	if len(twice[0].ScoreTerms) != 1 || twice[0].Score != 500 {
		t.Errorf("不重复扣: %d %v", twice[0].Score, twice[0].ScoreTerms)
	}
}
