package main

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func TestWinnerCandidateCover(t *testing.T) {
	cand := func(source string, score int, album, cover string) lyricsDecisionCandidate {
		return lyricsDecisionCandidate{Source: source, Score: score, Album: album, CoverURL: cover}
	}
	d := &lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
		cand("qq", 1200, "半生雪", "https://q/1.jpg"),
		cand("kugou", 1100, "半生雪", "https://k/1.jpg"),
	}}
	if c, s, a := winnerCandidateCover(d, "半生雪"); c != "https://k/1.jpg" || s != "kugou" || a != "半生雪" {
		t.Errorf("胜者带封面、专辑逐字对上:要用它,得到 %q %q %q", c, s, a)
	}
	for name, c := range map[string]struct {
		d     *lyricsDecision
		album string
	}{
		"专辑多了版本限定词": {d, "半生雪 (DJ版)"},
		"专辑完全不沾边":   {d, "冬眠"},
		"没有判决":      {nil, "半生雪"},
		"胜者没封面、别的源专辑对不上": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 900, "半生雪", ""), cand("qq", 800, "冬眠", "https://q/1.jpg")}}, "半生雪"},
		"胜者没封面、别的源负分": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 900, "半生雪", ""), cand("qq", -1, "半生雪", "https://q/1.jpg")}}, "半生雪"},
		"胜者封面不是 https": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 900, "半生雪", "http://k/1.jpg")}}, "半生雪"},
		"胜者那条被拒": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", -1, "半生雪", "https://k/1.jpg")}}, "半生雪"},
		"胜者那条专辑对不上、同源后面一条对得上": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 1100, "半生雪 (Live)", "https://k/1.jpg"), cand("kugou", 900, "半生雪", "https://k/2.jpg")}}, "半生雪"},
	} {
		if got, _, _ := winnerCandidateCover(c.d, c.album); got != "" {
			t.Errorf("%s:不该给,得到 %q", name, got)
		}
	}
}

// 放宽的几种:本地没报专辑、一个专辑名包含另一个且版本限定词一样、胜者没封面时别的源对得上的那条。
func TestWinnerCandidateCoverLoosened(t *testing.T) {
	cand := func(source string, score int, album, cover string) lyricsDecisionCandidate {
		return lyricsDecisionCandidate{Source: source, Score: score, Album: album, CoverURL: cover}
	}
	for name, c := range map[string]struct {
		d                  *lyricsDecision
		album, cover, from string
	}{
		"本地没有专辑": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 1100, "半生雪", "https://k/1.jpg")}}, "", "https://k/1.jpg", "kugou"},
		"专辑名包含、没有版本词": {&lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 1092, "龙虎门 RAP N' ROLL - Vol.06", "https://k/2.jpg")}}, "RAP N' ROLL", "https://k/2.jpg", "kugou"},
		"胜者没封面、看后面的源": {&lyricsDecision{Winner: "qq", Candidates: []lyricsDecisionCandidate{
			cand("qq", 837, "", ""), cand("kugou", 811, "齐天大圣(单曲)", "https://k/3.jpg")}}, "", "https://k/3.jpg", "kugou"},
		"胜者有封面时不看别的源": {&lyricsDecision{Winner: "qq", Candidates: []lyricsDecisionCandidate{
			cand("kugou", 1200, "", "https://k/4.jpg"), cand("qq", 1100, "", "https://q/4.jpg")}}, "", "https://q/4.jpg", "qq"},
	} {
		if got, src, _ := winnerCandidateCover(c.d, c.album); got != c.cover || src != c.from {
			t.Errorf("%s:要 %q(%s),得到 %q(%s)", name, c.cover, c.from, got, src)
		}
	}
}

func TestDecisionCandidateCovers(t *testing.T) {
	var cands []lyricsDecisionCandidate
	for i, u := range []string{"https://a/1.jpg", "https://a/1.jpg", "http://b/1.jpg", "", "https://c/1.jpg",
		"https://d/1.jpg", "https://e/1.jpg", "https://f/1.jpg", "https://g/1.jpg", "https://h/1.jpg"} {
		cands = append(cands, lyricsDecisionCandidate{Source: string(rune('a' + i)), CoverURL: u})
	}
	got := decisionCandidateCovers("A|B|C", &lyricsDecision{Candidates: cands})
	var urls []string
	for _, c := range got {
		urls = append(urls, c.url)
	}
	want := []string{"https://a/1.jpg", "https://c/1.jpg", "https://d/1.jpg", "https://e/1.jpg", "https://f/1.jpg", "https://g/1.jpg"}
	if !reflect.DeepEqual(urls, want) || got[0].source != "a" {
		t.Errorf("去重、只认 https、最多 %d 张:得到 %+v", decisionCoverCandidatesMax, got)
	}
	if decisionCandidateCovers("A|B|C", nil) != nil {
		t.Error("没有判决:没有候选")
	}
}

// 歌词判决里各源候选自带的封面跟小设备封面是同一张图、更清晰就换上,来源记那个源;不是同一张不换。
func TestUpgradeSmallDeviceCoverFromDecisionCandidates(t *testing.T) {
	isolateEnrichCache(t)
	resetCoverEdgeMemo(t)
	saved := candidateCoverURLOK
	candidateCoverURLOK = func(u string) bool { return strings.HasPrefix(u, deviceArtworkURLPrefix) }
	t.Cleanup(func() { candidateCoverURLOK = saved })
	dir := t.TempDir()
	device := writeCoverFile(t, dir, "device.jpg", synthCover(150, 1))
	same := writeCoverFile(t, dir, "k/800x800.jpg", synthCover(800, 1))
	other := writeCoverFile(t, dir, "o/800x800.jpg", synthCover(800, 2))
	if coverURLIntendedEdge(same) != 800 {
		t.Skipf("临时目录路径里带着别的 NxN 片段: %q", dir)
	}
	const key = "甲|乙|丙"
	run := func(cands ...lyricsDecisionCandidate) enrichEntry {
		enrichMu.Lock()
		enrichCache[key] = enrichEntry{CoverURL: device, CoverSource: "device", Lyrics: "[00:01.00]x",
			LyricsDecision: &lyricsDecision{Winner: "qq", Candidates: cands}}
		enrichInflight[key] = true
		enrichMu.Unlock()
		upgradeSmallDeviceCover(context.Background(), key, device, "甲", "乙", "丙", 0)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return enrichCache[key]
	}
	e := run(lyricsDecisionCandidate{Source: "qq", CoverURL: other}, lyricsDecisionCandidate{Source: "soda", CoverURL: same})
	if e.CoverURL != same || e.CoverSource != "soda" || e.CoverAlbum != "丙" {
		t.Errorf("候选里那张同一张图更清晰:换上、来源记 soda,得到 %+v", e)
	}
	if e := run(lyricsDecisionCandidate{Source: "qq", CoverURL: other}); e.CoverSource != "device" {
		t.Errorf("候选都不是同一张:留设备封面,得到 %+v", e)
	}
}

// 补边的小设备封面(汽水那种上下白边):歌词判决里的候选不担保是这首歌,不是同一张图就不换;播放器自己给的照旧让它让位。
func TestUpgradeSmallLetterboxedDeviceCover(t *testing.T) {
	isolateEnrichCache(t)
	resetCoverEdgeMemo(t)
	saved := candidateCoverURLOK
	candidateCoverURLOK = func(u string) bool { return strings.HasPrefix(u, deviceArtworkURLPrefix) }
	t.Cleanup(func() { candidateCoverURLOK = saved })
	dir := t.TempDir()
	device := writeCoverFile(t, dir, "device.jpg", letterboxedCover(150, 114, 1))
	other := writeCoverFile(t, dir, "o/800x800.jpg", synthCover(800, 2))
	if coverURLIntendedEdge(other) != 800 {
		t.Skipf("临时目录路径里带着别的 NxN 片段: %q", dir)
	}
	const key = "甲|乙|丙"
	run := func(ctx context.Context, cands ...lyricsDecisionCandidate) enrichEntry {
		enrichMu.Lock()
		enrichCache[key] = enrichEntry{CoverURL: device, CoverSource: "device", Lyrics: "[00:01.00]x",
			LyricsDecision: &lyricsDecision{Winner: "lrclib", Candidates: cands}}
		enrichInflight[key] = true
		enrichMu.Unlock()
		upgradeSmallDeviceCover(ctx, key, device, "甲", "乙", "丙", 0)
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return enrichCache[key]
	}
	stranger := lyricsDecisionCandidate{Source: "kugou", Score: -1, Artist: "别人", Title: "另一首", CoverURL: other}
	if e := run(context.Background(), lyricsDecisionCandidate{Source: "lrclib", Score: 300}, stranger); e.CoverURL != device {
		t.Errorf("判决里另一首歌的封面不是同一张图:留着补边的设备封面,得到 %+v", e)
	}
	if e := run(withPlayerCover(context.Background(), other)); e.CoverURL != other || e.CoverSource != "player" {
		t.Errorf("播放器自己给的照旧让补边的设备封面让位,得到 %+v", e)
	}
}

// 后台补封面开头不联网补一轮:没封面、存着的判决里胜出的那个源自带封面且专辑逐字对上的补上,别的不动。
func TestCoverSweepFillsFromLyricsWinner(t *testing.T) {
	dec := func(album, cover string) *lyricsDecision {
		return &lyricsDecision{Winner: "kugou", Candidates: []lyricsDecisionCandidate{
			{Source: "kugou", Score: 1000, Album: album, CoverURL: cover}}}
	}
	withEnrichCache(t, map[string]enrichEntry{
		"A|fill|半生雪":  {Lyrics: coverSweepLyrics, PeripheralRetryCount: 3, LyricsDecision: dec("半生雪", "https://k/1.jpg")},
		"A|other|半生雪": {Lyrics: coverSweepLyrics, PeripheralRetryCount: 3, LyricsDecision: dec("另一张", "https://k/2.jpg")},
		"A|has|半生雪":   {Lyrics: coverSweepLyrics, CoverURL: "https://n/1.jpg", CoverSource: "netease", LyricsDecision: dec("半生雪", "https://k/3.jpg")},
		"A|nodec|半生雪": {Lyrics: coverSweepLyrics, PeripheralRetryCount: 3},
	})
	withCoverSweepFakes(t, [][2]int32{{1, 0}}, nil)
	fakeCoverSweepUpgrade(t, nil)
	runCoverSweep(context.Background())
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|fill|半生雪"]; e.CoverURL != "https://k/1.jpg" || e.CoverSource != "kugou" || e.CoverAlbum != "半生雪" {
		t.Errorf("该补上胜者那张: %+v", e)
	}
	for _, k := range []string{"A|other|半生雪", "A|nodec|半生雪"} {
		if e := enrichCache[k]; e.CoverURL != "" {
			t.Errorf("%s 不该补: %+v", k, e)
		}
	}
	if e := enrichCache["A|has|半生雪"]; e.CoverURL != "https://n/1.jpg" {
		t.Errorf("已有封面的不动: %+v", e)
	}
}
