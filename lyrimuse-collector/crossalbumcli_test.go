package main

import "testing"

// 构造一组同 artist|title、不同专辑的条目。
func crossAlbumFixture() map[string]enrichEntry {
	return map[string]enrichEntry{
		"A|Song|Original": {
			DurationSecs: 200.0, Lyrics: "[00:01.00]low", LyricsSource: "kugou", LyricsScore: 1100,
		},
		"A|Song|Deluxe": {
			DurationSecs: 200.3, Lyrics: "[00:01.00]high", LyricsSource: "netease", LyricsScore: 1300,
			LyricsDecisionApplied: &lyricsDecision{Path: "first-resolve", Winner: "netease"},
		},
	}
}

func TestCrossAlbumReuseTakesHighestScore(t *testing.T) {
	cache := crossAlbumFixture()
	// 让胜者带上完整的歌词族字段,确认它们会被一起搬过去。
	e := cache["A|Song|Deluxe"]
	e.LyricsYRC, e.LyricsTr, e.LyricsRoma = "yrc", "tr", "roma"
	cache["A|Song|Deluxe"] = e
	enrichCache = cache

	groups := groupCrossAlbumCandidates(cache, crossAlbumReuseToleranceSecs)
	if len(groups) != 1 {
		t.Fatalf("groups = %d, want 1", len(groups))
	}
	applied, skipped := applyCrossAlbumReuse(groups)
	if applied != 1 || skipped != 0 {
		t.Fatalf("applied/skipped = %d/%d, want 1/0", applied, skipped)
	}
	got := enrichCache["A|Song|Original"]
	if got.Lyrics != "[00:01.00]high" || got.LyricsSource != "netease" || got.LyricsScore != 1300 {
		t.Errorf("低分那条没拿到高分那条的歌词: %+v", got)
	}
	if got.LyricsYRC != "yrc" || got.LyricsTr != "tr" || got.LyricsRoma != "roma" {
		t.Errorf("歌词族字段没搬全: yrc=%q tr=%q roma=%q", got.LyricsYRC, got.LyricsTr, got.LyricsRoma)
	}
	if got.LyricsDecisionApplied == nil ||
		got.LyricsDecisionApplied.Path != "cross-album-reuse" ||
		got.LyricsDecisionApplied.ReusedFrom != "A|Song|Deluxe" {
		t.Errorf("复用留痕没写上: %+v", got.LyricsDecisionApplied)
	}
	// 胜者自己不该被动过。
	if enrichCache["A|Song|Deluxe"].Lyrics != "[00:01.00]high" {
		t.Errorf("胜者被改了")
	}
}

// 用户手改过正文、或手动选过源的条目一律不动 —— 这两位代表用户已经表过态,
// "评分高的赢"在这里会把他的选择静默抹掉。
func TestCrossAlbumReuseSkipsUserDecisions(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(e *enrichEntry)
	}{
		{"手改过正文", func(e *enrichEntry) { e.ManualLyrics = true }},
		{"手动选过源", func(e *enrichEntry) { e.ManualPickSHA = "deadbeef" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cache := crossAlbumFixture()
			e := cache["A|Song|Original"]
			tc.mutate(&e)
			cache["A|Song|Original"] = e
			enrichCache = cache

			applied, skipped := applyCrossAlbumReuse(groupCrossAlbumCandidates(cache, crossAlbumReuseToleranceSecs))
			if applied != 0 || skipped != 1 {
				t.Fatalf("applied/skipped = %d/%d, want 0/1", applied, skipped)
			}
			if enrichCache["A|Song|Original"].Lyrics != "[00:01.00]low" {
				t.Errorf("用户表过态的条目被覆盖了")
			}
		})
	}
}

// 时长差超过容差的不该被归进同一组 —— 那是另一个版本,不是同一段录音。
func TestCrossAlbumReuseRespectsTolerance(t *testing.T) {
	cache := crossAlbumFixture()
	e := cache["A|Song|Deluxe"]
	e.DurationSecs = 200.0 + crossAlbumReuseToleranceSecs + 0.5
	cache["A|Song|Deluxe"] = e
	if got := len(groupCrossAlbumCandidates(cache, crossAlbumReuseToleranceSecs)); got != 0 {
		t.Errorf("超容差仍被归组: groups = %d, want 0", got)
	}
}

// 歌词完全相同的组不算分歧 —— 复用与否对用户没区别,列出来只会淹没真正要看的。
func TestCrossAlbumReuseNoDivergenceIsNoop(t *testing.T) {
	cache := map[string]enrichEntry{
		"A|Song|Original": {DurationSecs: 200.0, Lyrics: "same", LyricsScore: 1100},
		"A|Song|Deluxe":   {DurationSecs: 200.1, Lyrics: "same", LyricsScore: 1300},
	}
	enrichCache = cache
	groups := groupCrossAlbumCandidates(cache, crossAlbumReuseToleranceSecs)
	if len(groups) != 1 || groups[0].diverged() {
		t.Fatalf("歌词相同却被判成有分歧")
	}
	if applied, skipped := applyCrossAlbumReuse(groups); applied != 0 || skipped != 0 {
		t.Errorf("无分歧的组被动了: applied/skipped = %d/%d", applied, skipped)
	}
}

// 生产路径(commitEnrichEntry 前)的单向对齐:评分更高的兄弟在,就采用它的歌词。
func TestAdoptCrossAlbumSiblingTakesHigherScore(t *testing.T) {
	enrichCache = crossAlbumFixture()
	e := enrichCache["A|Song|Original"]
	if !adoptCrossAlbumSiblingLyrics("A|Song|Original", &e) {
		t.Fatal("有更高分的兄弟却没采用")
	}
	if e.Lyrics != "[00:01.00]high" || e.LyricsSource != "netease" || e.LyricsScore != 1300 {
		t.Errorf("没对齐到兄弟: %+v", e)
	}
	if e.LyricsDecisionApplied == nil ||
		e.LyricsDecisionApplied.Path != "cross-album-reuse" ||
		e.LyricsDecisionApplied.ReusedFrom != "A|Song|Deluxe" {
		t.Errorf("留痕没写上: %+v", e.LyricsDecisionApplied)
	}
}

// 自己分更高时不动 —— 单向规则,不反过来改兄弟。
func TestAdoptCrossAlbumSiblingKeepsHigherSelf(t *testing.T) {
	enrichCache = crossAlbumFixture()
	e := enrichCache["A|Song|Deluxe"] // 1300 分,兄弟只有 1100
	before := e.Lyrics
	if adoptCrossAlbumSiblingLyrics("A|Song|Deluxe", &e) {
		t.Fatal("自己分更高却被改了")
	}
	if e.Lyrics != before {
		t.Errorf("歌词被动了")
	}
	// 兄弟也不该被反向写。
	if enrichCache["A|Song|Original"].Lyrics != "[00:01.00]low" {
		t.Errorf("反向改了兄弟 —— 这条规则是单向的")
	}
}

// 同分不动:两份都站得住,换一份只会让用户觉得歌词莫名其妙变了。
func TestAdoptCrossAlbumSiblingIgnoresTie(t *testing.T) {
	enrichCache = crossAlbumFixture()
	tie := enrichCache["A|Song|Deluxe"]
	tie.LyricsScore = 1100
	enrichCache["A|Song|Deluxe"] = tie
	e := enrichCache["A|Song|Original"]
	if adoptCrossAlbumSiblingLyrics("A|Song|Original", &e) {
		t.Error("同分却换了歌词")
	}
}

// 用户表过态的条目,生产路径同样不碰。
func TestAdoptCrossAlbumSiblingSkipsUserDecisions(t *testing.T) {
	for name, mutate := range map[string]func(*enrichEntry){
		"手改过正文": func(e *enrichEntry) { e.ManualLyrics = true },
		"手动选过源": func(e *enrichEntry) { e.ManualPickSHA = "deadbeef" },
	} {
		t.Run(name, func(t *testing.T) {
			enrichCache = crossAlbumFixture()
			e := enrichCache["A|Song|Original"]
			mutate(&e)
			if adoptCrossAlbumSiblingLyrics("A|Song|Original", &e) {
				t.Error("用户表过态的条目被改了")
			}
		})
	}
}

// 超出时长容差的不算兄弟 —— 那是另一个版本。
func TestAdoptCrossAlbumSiblingRespectsTolerance(t *testing.T) {
	enrichCache = crossAlbumFixture()
	far := enrichCache["A|Song|Deluxe"]
	far.DurationSecs = 200.0 + crossAlbumReuseToleranceSecs + 0.5
	enrichCache["A|Song|Deluxe"] = far
	e := enrichCache["A|Song|Original"]
	if adoptCrossAlbumSiblingLyrics("A|Song|Original", &e) {
		t.Error("超容差的条目被当成兄弟")
	}
}

// 同一张专辑下的另一条(时长变体 key)不算兄弟 —— 那归 resolveEnrichKeyForDuration 管。
func TestAdoptCrossAlbumSiblingIgnoresSameAlbum(t *testing.T) {
	enrichCache = map[string]enrichEntry{
		"A|Song|Same":  {DurationSecs: 200.0, Lyrics: "low", LyricsScore: 1100},
		"A|Song2|Same": {DurationSecs: 200.1, Lyrics: "high", LyricsScore: 1300},
	}
	e := enrichCache["A|Song|Same"]
	if adoptCrossAlbumSiblingLyrics("A|Song|Same", &e) {
		t.Error("标题不同的条目被当成兄弟")
	}
}
