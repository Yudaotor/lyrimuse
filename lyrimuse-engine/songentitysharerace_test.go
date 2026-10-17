package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 按组重搜的冠军候选和一轮检索,搜的是 keys[0]。
func songShareRaceRound(key string, champ string) songShareRound {
	return songShareRound{
		shareEvalRound: shareEvalRound{Key: key, Artist: "A", Title: "Song", Album: "One", Duration: 200, Scored: []scoredLyricCandidateResult{
			{Source: "netease", Lyrics: champ, Score: 1200},
			{Source: "qq", Lyrics: songShareLRC("a1"), Score: 900},
			{Source: "kugou", Lyrics: songShareLRC("a2"), Score: 800},
		}},
		reached: true,
	}
}

func songShareSnapOf(keys []string) ([]enrichEntry, uint64) {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	out := make([]enrichEntry, len(keys))
	for i, k := range keys {
		out[i] = enrichCache[k]
	}
	return out, enrichEditStampLocked()
}

// 建表之后、这一组开搜之前存的手改或采纳:整轮开头算的 own 不知道,这一组不搜、不改,手改原样留着。
func TestShareGroupSkipsManualSavedAfterBuild(t *testing.T) {
	a1, a2, mine := songShareLRC("a1"), songShareLRC("a2"), songShareLRC("mine")
	for _, c := range []struct {
		name string
		edit func(e *enrichEntry)
	}{
		{"手改", func(e *enrichEntry) { e.Lyrics, e.LyricsSource, e.ManualLyrics = mine, "manual", true }},
		{"采纳", func(e *enrichEntry) { e.ManualPickSHA = manualPickFingerprint(e.Lyrics) }},
	} {
		t.Run(c.name, func(t *testing.T) {
			entries := map[string]enrichEntry{
				"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}, Lyrics: a1, LyricsSource: "qq"},
				"A|Song|Two": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}, Lyrics: a2, LyricsSource: "kugou"},
			}
			setUpSongShareTest(t, entries, true)
			saved := searchShareRound
			t.Cleanup(func() { searchShareRound = saved })
			calls := 0
			searchShareRound = func(_ context.Context, key, _, _, _ string, _ float64) songShareRound {
				calls++
				return songShareRaceRound(key, songShareLRC("champ"))
			}
			vs := []songVariant{songTestVariant("A|Song|One", entries["A|Song|One"], nil), songTestVariant("A|Song|Two", entries["A|Song|Two"], nil)}
			b, _ := songTestBuild(t, vs, nil)
			own := []*songPlanLyrics{b.songPlanLyricsOf(0, nil), b.songPlanLyricsOf(1, nil)}
			enrichMu.Lock()
			e := enrichCache["A|Song|Two"]
			c.edit(&e)
			enrichCache["A|Song|Two"] = e
			want := e
			enrichMu.Unlock()
			if out := b.shareGroup(context.Background(), []int{0, 1}, own); out.state != nil || calls != 0 {
				t.Fatalf("组里有了手改或采纳不搜: %+v calls=%d", out, calls)
			}
			if got, _ := cacheEntry(t, "A|Song|Two"); got.Lyrics != want.Lyrics || got.ManualLyrics != want.ManualLyrics || hasPre("A|Song|Two") {
				t.Errorf("手改或采纳的那份留着: %+v", got)
			}
			if got, _ := cacheEntry(t, "A|Song|One"); got.Lyrics != a1 || hasPre("A|Song|One") {
				t.Errorf("同组别的写法也不动: %+v", got)
			}
		})
	}
}

// 锁内核对:快照和现在都带着手改(开搜之前就改了),own 却不知道,比快照跟现在比不出来;组里有手改或采纳就整轮作废。
func TestApplyShareRoundAbandonsGroupWithManual(t *testing.T) {
	now := time.Unix(3_000_000, 0)
	mine := songShareLRC("mine")
	keys := []string{"A|Song|One", "A|Song|Two"}
	setUpSongShareTest(t, map[string]enrichEntry{
		keys[0]: {Song: "s", Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
		keys[1]: {Song: "s", Lyrics: mine, LyricsSource: "manual", ManualLyrics: true},
	}, true)
	snap, stamp := songShareSnapOf(keys)
	own := []*songPlanLyrics{{}, {}}
	if out := applyShareRound(keys, own, snap, stamp, songShareRaceRound(keys[0], songShareLRC("champ")), now); out.state != nil {
		t.Fatalf("组里有手改要作废: %+v", out)
	}
	if got, _ := cacheEntry(t, keys[1]); got.Lyrics != mine || !got.ManualLyrics || hasPre(keys[1]) {
		t.Errorf("手改不被冠军覆盖: %+v", got)
	}
	if got, _ := cacheEntry(t, keys[0]); got.Lyrics != songShareLRC("a1") || hasPre(keys[0]) {
		t.Errorf("作废的一轮不改、不留底: %+v", got)
	}
}

// 已经有留底的写法:这一轮作废时留底的 synced 不动(还对得上现在的歌词,关开关、拆开照样恢复);真换了词才改成冠军那份。
// 翻转保险挡下、没换成的,这一轮新建的留底删掉。
func TestApplyShareRoundKeepsExistingPreOnAbandon(t *testing.T) {
	now := time.Unix(3_000_000, 0)
	champ, x := songShareLRC("champ"), songShareLRC("x")
	keys := []string{"A|Song|One", "A|Song|Two", "A|Song|Three"}
	entries := func() map[string]enrichEntry {
		return map[string]enrichEntry{
			keys[0]: {Song: "s", Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
			keys[1]: {Song: "s", Lyrics: x, LyricsSource: "kugou",
				LyricsDecisionApplied: &lyricsDecision{Path: lyricsDecisionPathSongEntityShare, ReusedFrom: "B|Gone|One"}},
			keys[2]: {Song: "s", Lyrics: songShareLRC("a3"), LyricsSource: "kuwo"},
		}
	}
	setPre := func(t *testing.T) {
		t.Helper()
		if _, err := writeSongSharePre(keys[1], enrichEntry{Lyrics: songShareLRC("before"), LyricsSource: "qq"}, songOffsetFingerprint(x, ""), now); err != nil {
			t.Fatal(err)
		}
	}
	own := []*songPlanLyrics{{}, {}, {}}
	round := songShareRaceRound(keys[0], champ)
	round.Scored = append(round.Scored, scoredLyricCandidateResult{Source: "kuwo", Lyrics: songShareLRC("a3"), Score: 700})

	setUpSongShareTest(t, entries(), true)
	setPre(t)
	snap, stamp := songShareSnapOf(keys)
	enrichMu.Lock()
	markEnrichEditedLocked(false, keys[2])
	enrichMu.Unlock()
	if out := applyShareRound(keys, own, snap, stamp, round, now); out.state != nil {
		t.Fatalf("开搜之后被改过要作废: %+v", out)
	}
	e, _ := cacheEntry(t, keys[1])
	if p, _ := readPreEntry(t, keys[1]); p.Synced != songOffsetFingerprint(x, "") {
		t.Errorf("作废的一轮不改已有留底的 synced: %+v", p)
	}
	if _, ok := songShareRestorable(keys[1], e); !ok {
		t.Error("作废之后已有的留底还要恢复得了")
	}
	if hasPre(keys[0]) {
		t.Error("作废的一轮新建的留底删掉")
	}

	setUpSongShareTest(t, entries(), true)
	setPre(t)
	enrichMu.Lock()
	songShareFlapStopped[keys[2]] = true
	enrichMu.Unlock()
	snap, stamp = songShareSnapOf(keys)
	if out := applyShareRound(keys, own, snap, stamp, round, now); out.state == nil {
		t.Fatalf("没人动过要做成: %+v", out)
	}
	for _, k := range keys[:2] {
		if got, _ := cacheEntry(t, k); got.Lyrics != champ {
			t.Errorf("%s 换成冠军: %+v", k, got)
		}
	}
	if p, pre := readPreEntry(t, keys[1]); p.Synced != songOffsetFingerprint(champ, "") || pre.Lyrics != songShareLRC("before") {
		t.Errorf("已有的留底只改 synced: %+v %+v", p, pre)
	}
	if got, _ := cacheEntry(t, keys[2]); got.Lyrics != songShareLRC("a3") || hasPre(keys[2]) {
		t.Errorf("翻转保险挡下的不改、新建的留底删掉: %+v pre=%v", got, hasPre(keys[2]))
	}
}

// 统一两份手改时有一条留底写不成:已经写了的撤回(新建的删掉、已有的 synced 改回原来的),条目都不动。
func TestResolveManualConflictUndoesBackupsOnFailure(t *testing.T) {
	now := time.Now()
	keep, b, c, d := songShareLRC("keep"), songShareLRC("b"), songShareLRC("c"), songShareLRC("d")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|Nine":  {Song: "s_000000000001", Lyrics: keep, ManualLyrics: true, LyricsSource: "manual"},
		"A|Song|One":   {Song: "s_000000000001", Lyrics: b, ManualLyrics: true, LyricsSource: "manual"},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: d, ManualLyrics: true, LyricsSource: "manual"},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: c, ManualLyrics: true, LyricsSource: "manual"},
	}, true)
	// One 没有留底(会新建);Three 已有一份(synced 对着 d);Two 那个文件是别的写法的,写不成。
	prev := songOffsetFingerprint(d, "")
	if _, err := writeSongSharePre("A|Song|Three", enrichEntry{Lyrics: songShareLRC("old")}, prev, now); err != nil {
		t.Fatal(err)
	}
	if _, err := writeSongSharePre("B|Other|One", enrichEntry{Lyrics: songShareLRC("other")}, "", now); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(songSharePrePath("B|Other|One"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(songSharePrePath("A|Song|Two"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "resolve_manual_conflict", Key: "A|Song|Nine"}); res.OK {
		t.Fatalf("有一条留底写不成要报错: %+v", res)
	}
	if hasPre("A|Song|One") {
		t.Error("这一次新建的留底要删掉")
	}
	if p, _ := readPreEntry(t, "A|Song|Three"); p.Synced != prev {
		t.Errorf("已有留底的 synced 改回原来的: %+v", p)
	}
	for k, want := range map[string]string{"A|Song|One": b, "A|Song|Two": c, "A|Song|Three": d} {
		if got, _ := cacheEntry(t, k); got.Lyrics != want || got.LyricsEntityOrigin != "" {
			t.Errorf("%s 不动: %+v", k, got)
		}
	}
}

// 拆开、恢复合并请了马上重建:同步一轮停在两组之间、请求留给常驻循环;重建之后那一轮接着搜没轮到的组,搜过的不重搜。
func TestSongSharePassYieldsToRebuildRequest(t *testing.T) {
	champ := songShareLRC("champ")
	entries := map[string]enrichEntry{
		"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a1"), LyricsSource: "qq"},
		"A|Song|Two": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}, Lyrics: songShareLRC("a2"), LyricsSource: "kugou"},
		"B|Tune|One": {DurationSecs: 180, ISRCs: []string{"USAAA1100002"}, Lyrics: songShareLRC("b1"), LyricsSource: "qq"},
		"B|Tune|Two": {DurationSecs: 180.1, ISRCs: []string{"USAAA1100002"}, Lyrics: songShareLRC("b2"), LyricsSource: "kugou"},
	}
	setUpSongShareTest(t, entries, true)
	drainSongEntityRebuild()
	t.Cleanup(func() { drainSongEntityRebuild() })
	savedSearch, savedWait := searchShareRound, songShareWait
	t.Cleanup(func() { searchShareRound, songShareWait = savedSearch, savedWait })
	songShareWait = func(context.Context, time.Duration) {}
	var searched []string
	searchShareRound = func(_ context.Context, key, artist, title, album string, dur float64) songShareRound {
		searched = append(searched, key)
		if len(searched) == 1 {
			requestSongEntityRebuild()
		}
		return songShareRound{
			shareEvalRound: shareEvalRound{Key: key, Artist: artist, Title: title, Album: album, Duration: dur, Scored: []scoredLyricCandidateResult{
				{Source: "netease", Lyrics: champ, Score: 1200},
				{Source: "qq", Lyrics: songShareLRC("a1"), Score: 900},
				{Source: "kugou", Lyrics: songShareLRC("a2"), Score: 800},
				{Source: "qq", Lyrics: songShareLRC("b1"), Score: 900},
				{Source: "kugou", Lyrics: songShareLRC("b2"), Score: 800},
			}},
			reached: true,
		}
	}
	runSongEntitySharePass(context.Background(), rebuildSongEntityTable(time.Now()))
	if len(searched) != 1 || !strings.HasPrefix(searched[0], "A|Song|") {
		t.Fatalf("请了重建要停在两组之间: %v", searched)
	}
	if !drainSongEntityRebuild() {
		t.Fatal("重建请求要留给常驻循环")
	}
	searched = nil
	runSongEntitySharePass(context.Background(), rebuildSongEntityTable(time.Now()))
	if len(searched) != 1 || !strings.HasPrefix(searched[0], "B|Tune|") {
		t.Errorf("重建之后接着搜没轮到的组: %v", searched)
	}
}

// 两组之间、连不上歌词源时的等待,来了马上重建的请求就醒,请求放回去。
func TestSongShareSleepWakesOnRebuildRequest(t *testing.T) {
	drainSongEntityRebuild()
	t.Cleanup(func() { drainSongEntityRebuild() })
	requestSongEntityRebuild()
	done := make(chan struct{})
	go func() { songShareSleep(context.Background(), time.Hour); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("有重建请求时要醒")
	}
	if !songShareRebuildPending() {
		t.Error("请求要放回去")
	}
}

// 实体表写不成时这次建出来的状态照样留给增量重算,实体表攒着、下一次 flush 写掉。
func TestSongEntityRebuildKeepsStateWhenTableWriteFails(t *testing.T) {
	dir := setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Two": {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
	}, false)
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	t.Cleanup(func() { songEntityTableUnsaved = nil })
	if err := os.MkdirAll(songEntityTablePath(), 0o700); err != nil {
		t.Fatal(err)
	}
	if b := rebuildSongEntityTable(time.Now()); b != nil {
		t.Fatal("实体表写不成时这次不同步")
	}
	songEntityRebuildMu.Lock()
	live, unsaved := songEntityLive != nil && songEntityLivePath == songEntityTablePath(), songEntityTableUnsaved != nil
	songEntityRebuildMu.Unlock()
	if !live || !unsaved {
		t.Fatalf("状态要留给增量重算(%v)、实体表攒着(%v)", live, unsaved)
	}
	if err := os.Remove(songEntityTablePath()); err != nil {
		t.Fatal(err)
	}
	commitEnrichEntrySince("A|Song|Three", enrichEntry{DurationSecs: 199.9, ISRCs: []string{"USAAA1100001"}}, enrichEditNoStamp)
	if b, full := updateSongEntityTable(time.Now()); b == nil || full {
		t.Fatalf("增量重算接着做: b=%v full=%v", b != nil, full)
	}
	flushSongEntityTable()
	one, _ := cacheEntry(t, "A|Song|One")
	if tbl := readSongEntityTable(songEntityTablePath()); tbl == nil || len(tbl.Songs[one.Song].Variants) != 3 {
		t.Fatal("攒着的实体表 flush 时写进盘")
	}
}
