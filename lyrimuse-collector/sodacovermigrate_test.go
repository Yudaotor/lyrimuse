package main

import "testing"

func TestMigrateSodaCoverURLs(t *testing.T) {
	saved, savedPath := enrichCache, enrichPath
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache, enrichPath = saved, savedPath
		enrichMu.Unlock()
	})
	broken := "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc"
	good := "https://p2.music.126.net/x.jpg?param=800y800"
	orig := &lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
		{Source: "soda", Score: 1045, CoverURL: broken},
		{Source: "netease", Score: 653, CoverURL: good},
	}}
	enrichMu.Lock()
	enrichPath = ""
	enrichCache = map[string]enrichEntry{
		"a|t|b": {Lyrics: "x", LyricsDecision: orig, LyricsDecisionApplied: orig},
		"c|t|d": {Lyrics: "y"},
	}
	enrichMu.Unlock()

	migrateSodaCoverURLs()
	migrateSodaCoverURLs()

	e := enrichCache["a|t|b"]
	want := broken + "~" + sodaImageTemplate + "-" + sodaCoverTransform
	for _, d := range []*lyricsDecision{e.LyricsDecision, e.LyricsDecisionApplied} {
		if d.Candidates[0].CoverURL != want || d.Candidates[1].CoverURL != good {
			t.Fatalf("cover urls = %q / %q", d.Candidates[0].CoverURL, d.Candidates[1].CoverURL)
		}
		if d.Candidates[0].Score != 1045 || d.Winner != "kugou" {
			t.Fatal("只该动 cover_url")
		}
	}
	if orig.Candidates[0].CoverURL != broken {
		t.Fatal("不能原地改原来的决策对象")
	}
}
