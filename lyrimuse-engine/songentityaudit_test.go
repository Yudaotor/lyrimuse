package main

import (
	"context"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// 墙钟定时器:没到点时按剩下的时间再睡一段、不报到点;过了墙钟时刻就到点;Reset 从现在起重新算。
func TestWallTimerDue(t *testing.T) {
	w := newWallTimer(time.Hour)
	defer w.Stop()
	now := time.Now()
	if w.Due(now) {
		t.Error("还差一小时,不该到点")
	}
	if !w.Due(now.Add(time.Hour + time.Second)) {
		t.Error("墙钟过了一小时就该到点")
	}
	w.Reset(24 * time.Hour)
	if w.Due(now.Add(time.Hour+time.Second)) || !w.Due(now.Add(25*time.Hour)) {
		t.Error("Reset 之后按新的间隔判")
	}
}

// 写回实体 id 时,建表快照之后被改过 `song` 的条目(建表期间用户拆开了)不盖回去;没被改过的照写。
func TestWriteBackSkipsEntriesChangedSinceSnapshot(t *testing.T) {
	savedDirty := enrichDirty
	t.Cleanup(func() { enrichDirty = savedDirty })
	withEnrichCache(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001"},
		"A|Song|Two":   {Song: "s_000000000001"},
		"A|Song|Three": {},
	})
	snap := maps.Clone(enrichCache)
	e := enrichCache["A|Song|Two"]
	e.Song = "s_000000000002"
	enrichCache["A|Song|Two"] = e
	keys := writeBackSongEntityIDs(&songEntityTableFile{Songs: map[string]songEntityRecord{
		"s_000000000001": {Variants: []string{"A|Song|One", "A|Song|Three", "A|Song|Two"}},
	}}, snap)
	if !slices.Equal(keys, []string{"A|Song|Three"}) || enrichCache["A|Song|Two"].Song != "s_000000000002" ||
		enrichCache["A|Song|Three"].Song != "s_000000000001" {
		t.Errorf("keys=%v two=%q three=%q", keys, enrichCache["A|Song|Two"].Song, enrichCache["A|Song|Three"].Song)
	}
}

// 建表输入:这一场主缓存没读进来、拆开记录读不出来或解不开时不建;拆开记录不存在照常建。
func TestSongEntityLiveSourceRefusesBrokenInputs(t *testing.T) {
	dir := setUpSongShareTest(t, map[string]enrichEntry{"A|Song|One": {}}, true)
	if src, err := songEntityLiveSource(nil); err != nil || src == nil || len(src.cache) != 1 || src.splits != nil {
		t.Fatalf("拆开记录不存在照常建: src=%v err=%v", src, err)
	}
	path := songEntityUserPath()
	if !strings.HasPrefix(path, dir) {
		t.Fatalf("拆开记录不在测试目录: %s", path)
	}
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := songEntityLiveSource(nil); err == nil {
		t.Error("拆开记录解不开时不建")
	}
	os.Remove(path)
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := songEntityLiveSource(nil); err == nil {
		t.Error("拆开记录读不出来时不建")
	}
	os.Remove(path)
	enrichMu.Lock()
	saved := enrichLoadFailed
	enrichLoadFailed = true
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichLoadFailed = saved
		enrichMu.Unlock()
	})
	if _, err := songEntityLiveSource(nil); !errors.Is(err, errEnrichCacheNotLoaded) {
		t.Errorf("主缓存没读进来时不建: %v", err)
	}
}

// 同一组整组标了纯音乐之后,只靠时长 + 歌词连着的两条照样连着(撤标时才找得回组里别的写法);一边标了一边没标的不拿歌词作证。
func TestSongEntityLyricsEvidenceSurvivesInstrumentalMark(t *testing.T) {
	words := songTestWords("listen", 30)
	mk := func(ix, iy bool) []songVariant {
		return []songVariant{
			songTestVariant("Khalil Fong|Listen|Journey", enrichEntry{DurationSecs: 281, Lyrics: bt(songTestLRC(1000, words)), LyricsSource: "kuwo",
				ResolvedDurationSecs: 281, Instrumental: ix}, nil),
			songTestVariant("Khalil Fong|听|JTW", enrichEntry{DurationSecs: 281.093, Lyrics: bt(songTestLRC(1000, words)), LyricsSource: "kugou",
				ResolvedDurationSecs: 281.093, Instrumental: iy}, nil),
		}
	}
	vs := mk(true, true)
	if _, of := songTestBuild(t, vs, nil); !songTestSame(of, vs[0].key, vs[1].key) {
		t.Error("两边都标了纯音乐,歌词照样作证")
	}
	vs = mk(true, false)
	if songIndependentLyricsMatch(&vs[0], &vs[1], "") {
		t.Error("一边标了纯音乐的那一对不当检索 id 的歌词旁证")
	}
	vs = mk(true, true)
	if !songIndependentLyricsMatch(&vs[0], &vs[1], "") {
		t.Error("两边都标了纯音乐,歌词旁证照算")
	}
}

// 手改原件(同步之后用户只改了译文、原样采纳了同一份)正文指纹没变,也不按留底恢复;关开关时同样留着。自动副本照常恢复。
func TestSongShareRestoreSkipsManualOriginals(t *testing.T) {
	synced, before := songShareLRC("synced"), songShareLRC("before")
	share := &lyricsDecision{Path: lyricsDecisionPathSongEntityShare, ReusedFrom: "A|Song|Zero"}
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(synced), LyricsTr: bt("用户改的译文"), ManualLyrics: true, LyricsDecisionApplied: share},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(synced), LyricsDecisionApplied: share},
	}, true)
	now := time.Unix(3_000_000, 0)
	fp := songOffsetFingerprint(synced, "")
	for _, k := range []string{"A|Song|One", "A|Song|Two"} {
		if _, err := writeSongSharePre(k, enrichEntry{Song: "s_000000000001", Lyrics: bt(before)}, fp, now); err != nil {
			t.Fatal(err)
		}
	}
	enrichMu.Lock()
	_, one := songShareRestorable("A|Song|One", enrichCache["A|Song|One"])
	_, two := songShareRestorable("A|Song|Two", enrichCache["A|Song|Two"])
	enrichMu.Unlock()
	if one || !two {
		t.Fatalf("手改原件不可恢复、自动副本可恢复: one=%v two=%v", one, two)
	}
	revertSongEntityShare()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|Song|One"]; !e.Lyrics.EqualString(synced) || !e.LyricsTr.EqualString("用户改的译文") || !e.ManualLyrics {
		t.Errorf("关开关时手改原件留着现在的: %+v", e)
	}
	if e := enrichCache["A|Song|Two"]; !e.Lyrics.EqualString(before) {
		t.Errorf("自动副本按留底恢复: %q", e.Lyrics.String())
	}
}

// 关开关恢复时读不出来的留底留着(下一次再恢复),不删。
func TestRevertSongEntityShareKeepsUnreadableBackups(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{"A|Song|One": {Song: "s_000000000001"}}, false)
	path := songSharePrePath("A|Song|One")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{}"), 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(path, 0o600) })
	revertSongEntityShare()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("读不出来的留底不删: %v", err)
	}
}

// 按组重搜作废时,开搜之后别的路径接手了的留底(synced 对得上条目现在的歌词)留着;没人动过的删掉。
func TestRemoveStagedSongSharePresKeepsTakenOver(t *testing.T) {
	top, other, mine := songShareLRC("top"), songShareLRC("other"), songShareLRC("mine")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(mine)},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(mine)},
	}, true)
	now := time.Unix(3_000_000, 0)
	for _, k := range []string{"A|Song|One", "A|Song|Two"} {
		if made, err := stageSongSharePre(k, enrichCache[k], songOffsetFingerprint(top, ""), now); err != nil || !made {
			t.Fatal(made, err)
		}
	}
	enrichMu.Lock()
	e := enrichCache["A|Song|One"]
	if _, err := writeSongSharePre("A|Song|One", e, songOffsetFingerprint(other, ""), now); err != nil {
		t.Fatal(err)
	}
	e.Lyrics = bt(other)
	enrichCache["A|Song|One"] = e
	removeStagedSongSharePresLocked(map[string]bool{"A|Song|One": true, "A|Song|Two": true}, nil)
	enrichMu.Unlock()
	if _, err := os.Stat(songSharePrePath("A|Song|One")); err != nil {
		t.Errorf("别的路径接手了的留底留着: %v", err)
	}
	if _, err := os.Stat(songSharePrePath("A|Song|Two")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("没人动过的删掉: %v", err)
	}
}

// 翻转保险记的时刻只留墙钟。
func TestSongShareFlapTimesAreWallClock(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{}, true)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	songShareAutoWriteAllowedLocked("A|Song|One", time.Now())
	at := songShareFlaps["A|Song|One"]
	if len(at) != 1 || strings.Contains(at[0].String(), "m=") {
		t.Errorf("记的时刻带着单调读数: %v", at)
	}
}

// 原件改回自动之后的手改副本:有留底的按留底恢复、报成恢复了的;没有留底的去掉副本标记,出处是同步的那一槽也清掉。
// 标了纯音乐的手改原件不往组里别的写法同步。
func TestShareManualLockedReleaseAndInstrumental(t *testing.T) {
	m, before, auto := songShareLRC("m"), songShareLRC("before"), songShareLRC("auto")
	share := &lyricsDecision{Path: lyricsDecisionPathSongEntityShare, ReusedFrom: "A|Song|One"}
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(m), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One", LyricsDecisionApplied: share},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: bt(m), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One", LyricsDecisionApplied: share},
	}, true)
	now := time.Unix(3_000_000, 0)
	if _, err := writeSongSharePre("A|Song|Two", enrichEntry{Song: "s_000000000001", Lyrics: bt(before)}, songOffsetFingerprint(m, ""), now); err != nil {
		t.Fatal(err)
	}
	enrichMu.Lock()
	changed, restored, _ := shareManualLocked([]string{"A|Song|One", "A|Song|Three", "A|Song|Two"}, "", nil, now)
	three := enrichCache["A|Song|Three"]
	enrichMu.Unlock()
	if !slices.Equal(changed, []string{"A|Song|Three", "A|Song|Two"}) || !slices.Equal(restored, []string{"A|Song|Two"}) {
		t.Errorf("changed=%v restored=%v", changed, restored)
	}
	if three.LyricsEntityOrigin != "" || three.ManualLyrics || three.LyricsDecisionApplied != nil {
		t.Errorf("没有留底的副本去掉标记、同步出处也清掉: %+v", three)
	}

	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(m), ManualLyrics: true, Instrumental: true},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
	}, true)
	enrichMu.Lock()
	changed, _, _ = shareManualLocked([]string{"A|Song|One", "A|Song|Two"}, "", nil, now)
	two := enrichCache["A|Song|Two"]
	enrichMu.Unlock()
	if len(changed) != 0 || !two.Lyrics.EqualString(auto) {
		t.Errorf("标了纯音乐的原件不往外同步: changed=%v two=%q", changed, two.Lyrics.String())
	}
}

// 建表之后那一轮:手改副本按留底恢复了的也交给后台重评。
func TestShareManualPassRescoresRestoredCopies(t *testing.T) {
	m, before, auto := songShareLRC("m"), songShareLRC("before"), songShareLRC("auto")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(m), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One"},
	}, true)
	now := time.Unix(3_000_000, 0)
	if _, err := writeSongSharePre("A|Song|Two", enrichEntry{Song: "s_000000000001", Lyrics: bt(before)}, songOffsetFingerprint(m, ""), now); err != nil {
		t.Fatal(err)
	}
	saved := rescoreReleasedStrays
	t.Cleanup(func() { rescoreReleasedStrays = saved })
	var got []string
	rescoreReleasedStrays = func(keys []string) { got = append(got, keys...) }
	b := &songEntityBuild{variants: []songVariant{{key: "A|Song|One"}, {key: "A|Song|Two"}}, clusters: [][]int{{0, 1}}, shareOf: []int{0, 0}}
	var tally songShareTally
	b.shareManualPass(nil, now, &tally)
	if !slices.Equal(got, []string{"A|Song|Two"}) {
		t.Errorf("按留底恢复的手改副本要重评: %v", got)
	}
}

// 关着「随匹配算法更新重新选择」留下的组,这个开关打开之后到期。
func TestSongShareStateDueAfterUpgradeTurnsOn(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{}, true)
	fps := map[string]string{"A|Song|One": "x"}
	st := &songShareState{Groups: map[string]songShareGroupState{
		"sig": {Scoring: currentLyricsScoring.String(), Members: fps, HeldNoUpgrade: true},
	}}
	now := time.Unix(3_000_000, 0)
	setFeatures(featureFlags{SongEntityShadow: true, SongEntityShareLyrics: true})
	if st.due("sig", fps, now) {
		t.Error("开关还关着,不到期")
	}
	setFeatures(featureFlags{SongEntityShadow: true, SongEntityShareLyrics: true, LyricsAutoUpgrade: true})
	if !st.due("sig", fps, now) {
		t.Error("开关打开了,到期")
	}
}

// 标 / 撤纯音乐整组跟时,手改副本跟着,用户自己给了词的原件不跟。
func TestInstrumentalFollowsManualCopies(t *testing.T) {
	m := songShareLRC("m")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(m), ManualLyrics: true},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(m), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One"},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: bt(songShareLRC("auto"))},
	}, true)
	enrichMu.Lock()
	got := withShareGroupMatesLocked([]string{"A|Song|Three"})
	enrichMu.Unlock()
	if !slices.Equal(got, []string{"A|Song|Three", "A|Song|Two"}) {
		t.Errorf("got %v", got)
	}
}

// 歌词文件夹里同一组两条改成了不同的词:两条都留成手改原件,谁也不盖谁。
func TestShareImportedEditsKeepsBothEdits(t *testing.T) {
	a, b := songShareLRC("edita"), songShareLRC("editb")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001", Lyrics: bt(a)},
		"A|Song|Two": {Song: "s_000000000001", Lyrics: bt(b)},
	}, true)
	enrichMu.Lock()
	shareImportedEditsLocked([]string{"A|Song|One", "A|Song|Two"}, time.Unix(3_000_000, 0))
	one, two := enrichCache["A|Song|One"], enrichCache["A|Song|Two"]
	enrichMu.Unlock()
	if !one.Lyrics.EqualString(a) || !two.Lyrics.EqualString(b) || !songShareManualOriginal(one) || !songShareManualOriginal(two) {
		t.Errorf("one=%q two=%q", one.Lyrics.String(), two.Lyrics.String())
	}
}

// 有重建请求排着(建表期间用户拆开了)时,这次建表之后不同步。
func TestSongEntitySharePassWaitsForPendingRebuild(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{"A|Song|One": {Song: "s_000000000001"}}, true)
	requestSongEntityRebuild()
	t.Cleanup(func() { drainSongEntityRebuild() })
	runSongEntitySharePass(context.Background(), &songEntityBuild{variants: []songVariant{{key: "A|Song|One"}}, clusters: [][]int{{0}}, shareOf: []int{0}})
	if _, err := os.Stat(songShareStatePath()); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("有重建请求排着时不同步: %v", err)
	}
}
