//go:build devtools

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

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

// 分组跟子组第一条比时长,不链式合并:200 / 201.9 / 203.8 秒不会连成一组。
func TestGroupCrossAlbumNoChaining(t *testing.T) {
	cache := map[string]enrichEntry{
		enrichKey("A", "歌", "一"): {Lyrics: "x", DurationSecs: 200},
		enrichKey("A", "歌", "二"): {Lyrics: "y", DurationSecs: 201.9},
		enrichKey("A", "歌", "三"): {Lyrics: "z", DurationSecs: 203.8},
	}
	groups := groupCrossAlbumCandidates(cache, 2)
	if len(groups) != 1 || len(groups[0].members) != 2 {
		t.Fatalf("应当只有 200 / 201.9 一组: %+v", groups)
	}
	for _, m := range groups[0].members {
		if m.duration == 203.8 {
			t.Error("203.8 秒那条跟 200 秒差了 3.8 秒,不该在组里")
		}
	}
}

// -apply:校准过时间轴的条目不动;组内最高分打平的整组不动;源没有决策记录时写一份最小记录。
func TestApplyCrossAlbumReuseGuards(t *testing.T) {
	kBest, kPinned, kPlain := enrichKey("A", "歌", "一"), enrichKey("A", "歌", "二"), enrichKey("A", "歌", "三")
	tie1, tie2 := enrichKey("B", "曲", "一"), enrichKey("B", "曲", "二")
	withEnrichCache(t, map[string]enrichEntry{
		kBest:   {Lyrics: "最好", DurationSecs: 200, LyricsScore: 900, LyricsScoringVersion: 3},
		kPinned: {Lyrics: "校准过", DurationSecs: 200, LyricsScore: 100, LyricsScoringVersion: 3},
		kPlain: {Lyrics: "普通", DurationSecs: 200, LyricsScore: 100, LyricsScoringVersion: 3,
			LyricsDecisionApplied: &lyricsDecision{Path: "old-path"}},
		tie1: {Lyrics: "甲", DurationSecs: 180, LyricsScore: 500, LyricsScoringVersion: 3},
		tie2: {Lyrics: "乙", DurationSecs: 180, LyricsScore: 500, LyricsScoringVersion: 3},
	})
	pins := filepath.Join(t.TempDir(), "pins.json")
	data, _ := json.Marshal(lyricsPinsFile{Version: 1, Pins: map[string]int64{kPinned: 1}})
	if err := os.WriteFile(pins, data, 0o600); err != nil {
		t.Fatal(err)
	}
	savedPins := lyricsPinsPath
	lyricsPinsPath = pins
	t.Cleanup(func() { lyricsPinsPath = savedPins })

	enrichMu.Lock()
	groups := groupCrossAlbumCandidates(enrichCache, crossAlbumReuseToleranceSecs)
	enrichMu.Unlock()
	applied, skipped := applyCrossAlbumReuse(groups)
	if applied != 1 || skipped != 2 {
		t.Fatalf("applied=%d skipped=%d, want 1 / 2", applied, skipped)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if enrichCache[kPinned].Lyrics != "校准过" {
		t.Error("校准过的不该被改")
	}
	plain := enrichCache[kPlain]
	if plain.Lyrics != "最好" || plain.LyricsDecisionApplied == nil ||
		plain.LyricsDecisionApplied.Path != lyricsDecisionPathCrossAlbumReuse || plain.LyricsDecisionApplied.ReusedFrom != kBest {
		t.Errorf("普通那条应复用并换成最小决策记录: %+v", plain.LyricsDecisionApplied)
	}
	if enrichCache[tie1].Lyrics != "甲" || enrichCache[tie2].Lyrics != "乙" {
		t.Error("打平的组不该动")
	}
}

// 跨专辑复用只跟同一打分版本的兄弟比分数;存量命令优先用打分版本最新的那条。
func TestCrossAlbumReuseComparesSameScoringVersionOnly(t *testing.T) {
	self := enrichEntry{Lyrics: "mine", LyricsScore: 700, LyricsScoringVersion: lyricsScoringVersion, DurationSecs: 200}
	cache := map[string]enrichEntry{
		"a|t|原版": self,
		"a|t|典藏": {Lyrics: "inflated", LyricsScore: 900, LyricsScoringVersion: lyricsScoringVersion - 5, DurationSecs: 200.5},
	}
	if got := crossAlbumSiblingLyrics(cache, "a|t|原版", self); got != "" {
		t.Fatalf("旧版本的高分不该赢: %q", got)
	}
	cache["a|t|典藏"] = enrichEntry{Lyrics: "better", LyricsScore: 900, LyricsScoringVersion: lyricsScoringVersion, DurationSecs: 200.5}
	if got := crossAlbumSiblingLyrics(cache, "a|t|原版", self); got != "a|t|典藏" {
		t.Fatalf("同版本更高分的兄弟应当赢: %q", got)
	}
	g := crossAlbumGroup{members: []crossAlbumMember{{key: "old", score: 900, version: 3}, {key: "new", score: 500, version: 24}, {key: "new2", score: 600, version: 24}}}
	if best := g.members[g.bestMember()].key; best != "new2" {
		t.Fatalf("bestMember = %q, want new2", best)
	}
}
