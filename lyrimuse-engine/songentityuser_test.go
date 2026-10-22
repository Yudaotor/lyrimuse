package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

func drainSongEntityRebuild() bool {
	select {
	case <-songEntityRebuildNow:
		return true
	default:
		return false
	}
}

func readUserSplitPairs(t *testing.T) [][]string {
	t.Helper()
	data, err := os.ReadFile(songEntityUserPath())
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		UserSplits [][]string `json:"user_splits"`
	}
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return f.UserSplits
}

// 用户判断文件:只改 user_splits,别的键原样留着;没有文件时新建、带版本;解不开时报错、不覆盖。
func TestEditSongEntityUserSplits(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "user.json")
	add := func(a, b string) func(map[string][2]string) bool {
		return func(p map[string][2]string) bool { p[songPairKey(a, b)] = songSplitPair(a, b); return true }
	}
	if err := editSongEntityUserSplits(path, add("B", "A")); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); !strings.Contains(string(data), `"version": 1`) || !strings.Contains(string(data), `"A"`) {
		t.Fatalf("新建的文件: %s", data)
	}
	if err := os.WriteFile(path, []byte(`{"version":1,"user_splits":[["Y","X"],["x"]],"future_field":{"a":1}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := editSongEntityUserSplits(path, add("C", "A")); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	if string(doc["future_field"]) != `{"a":1}` && !strings.Contains(string(doc["future_field"]), `"a": 1`) {
		t.Errorf("不认识的键要原样留着: %s", data)
	}
	var pairs [][]string
	_ = json.Unmarshal(doc["user_splits"], &pairs)
	if !reflect.DeepEqual(pairs, [][]string{{"A", "C"}, {"X", "Y"}}) {
		t.Errorf("写法对小的在前、排好序,坏的那项丢掉: %v", pairs)
	}
	if err := editSongEntityUserSplits(path, func(p map[string][2]string) bool { clear(p); return true }); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); strings.Contains(string(data), "user_splits") || !strings.Contains(string(data), "future_field") {
		t.Errorf("删光了不留空键,别的键还在: %s", data)
	}
	if err := os.WriteFile(path, []byte(`{broken`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := editSongEntityUserSplits(path, add("A", "B")); err == nil {
		t.Error("解不开的文件要报错")
	}
	if data, _ := os.ReadFile(path); string(data) != `{broken` {
		t.Errorf("解不开的文件不覆盖: %s", data)
	}
	written := false
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := editSongEntityUserSplits(path, func(map[string][2]string) bool { return written }); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("没改就不写")
	}
}

// 拆开:记下拆出去的 × 留下的写法对,写法少的那一半换新 id,同步写进去的歌词按留底恢复,请马上重建。
func TestSplitSongEdit(t *testing.T) {
	own, synced := songShareLRC("own"), songShareLRC("shared")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(synced), LyricsSource: "netease"},
		"A|Song|Two":   {Song: "s_000000000001", SongShare: 1, Lyrics: bt(synced), LyricsSource: "netease"},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: bt(synced), LyricsSource: "netease"},
		"B|Other|One":  {Song: "s_000000000002", Lyrics: bt(own)},
	}, true)
	t0 := time.Unix(1_000_000, 0)
	if _, err := writeSongSharePre("A|Song|Two", enrichEntry{Song: "s_000000000001", Lyrics: bt(own), LyricsSource: "qq"},
		songOffsetFingerprint(synced, ""), t0); err != nil {
		t.Fatal(err)
	}
	drainSongEntityRebuild()
	enrichMu.Lock()
	stamp := enrichEditStampLocked()
	enrichMu.Unlock()

	res := applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"A|Song|Two"}})
	if !res.OK || res.Changed != 3 {
		t.Fatalf("拆开: %+v", res)
	}
	if got := readUserSplitPairs(t); !reflect.DeepEqual(got, [][]string{{"A|Song|One", "A|Song|Two"}, {"A|Song|Three", "A|Song|Two"}}) {
		t.Errorf("写法对: %v", got)
	}
	enrichMu.Lock()
	two, one, three := enrichCache["A|Song|Two"], enrichCache["A|Song|One"], enrichCache["A|Song|Three"]
	edited := enrichEditedSinceLocked("A|Song|Two", stamp) && enrichEditedSinceLocked("A|Song|One", stamp)
	enrichMu.Unlock()
	if two.Song == "" || two.Song == "s_000000000001" || two.SongShare != 0 {
		t.Errorf("拆出去的换新 id: %q %d", two.Song, two.SongShare)
	}
	if one.Song != "s_000000000001" || three.Song != "s_000000000001" {
		t.Errorf("留下的不动: %q %q", one.Song, three.Song)
	}
	if !two.Lyrics.EqualString(own) || two.LyricsSource != "qq" {
		t.Errorf("同步写进去的歌词按留底恢复: %q", two.LyricsSource)
	}
	if !one.Lyrics.EqualString(synced) {
		t.Error("留下的写法歌词不动")
	}
	if hasPre("A|Song|Two") {
		t.Error("恢复了就删掉留底")
	}
	if !edited {
		t.Error("拆开要让在飞的后台任务作废")
	}
	if !drainSongEntityRebuild() {
		t.Error("拆开之后要请马上重建")
	}
	if data, err := os.ReadFile(enrichPath); err != nil || !strings.Contains(string(data), two.Song) {
		t.Errorf("拆开要落盘: %v", err)
	}

	// 拆出去的比留下的多:留下的那一半换新 id。
	res = applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"A|Song|One", "A|Song|Three"}})
	if res.OK {
		t.Fatalf("实体里一条不剩不能拆: %+v", res)
	}
	enrichMu.Lock()
	e := enrichCache["B|Other|One"]
	e.Song = "s_000000000001"
	enrichCache["B|Other|One"] = e
	enrichMu.Unlock()
	if res = applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"A|Song|One", "A|Song|Three"}}); !res.OK {
		t.Fatalf("拆开: %+v", res)
	}
	enrichMu.Lock()
	one, three, other := enrichCache["A|Song|One"], enrichCache["A|Song|Three"], enrichCache["B|Other|One"]
	enrichMu.Unlock()
	if one.Song != "s_000000000001" || three.Song != "s_000000000001" || other.Song == "s_000000000001" || other.Song == "" {
		t.Errorf("写法多的一半留原 id: %q %q %q", one.Song, three.Song, other.Song)
	}

	for _, keys := range [][]string{nil, {"A|Song|Missing"}, {"A|Song|One", "A|Song|Two"}} {
		if res := applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: keys}); res.OK {
			t.Errorf("%v 不能拆: %+v", keys, res)
		}
	}
	// 两个实体各自都还留得下写法:跨实体照样不能一起拆。没有实体 id 的写法不能拆,哪怕别的写法也没有 id。
	enrichMu.Lock()
	for k, song := range map[string]string{"A|Song|Two": "s_000000000003", "C|Third|One": "s_000000000003",
		"C|None|One": "", "C|None|Two": ""} {
		e := enrichCache[k]
		e.Song = song
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	if res := applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"A|Song|One", "A|Song|Two"}}); res.OK {
		t.Error("跨实体不能一起拆")
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"C|None|One"}}); res.OK {
		t.Error("没有实体 id 的写法不能拆")
	}
}

// 拆出去的手改副本:按留底恢复;没有能用的留底时只去掉副本标记。自己的手改原件不动。
func TestSplitSongEditReleasesCopies(t *testing.T) {
	orig, mine, edited := songShareLRC("orig"), songShareLRC("mine"), songShareLRC("edited")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(orig), ManualLyrics: true},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(orig), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One"},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: bt(edited), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One"},
		"A|Song|Four":  {Song: "s_000000000001", Lyrics: bt(mine), ManualLyrics: true},
	}, true)
	if _, err := writeSongSharePre("A|Song|Two", enrichEntry{Lyrics: bt(mine), LyricsSource: "qq"},
		songOffsetFingerprint(orig, ""), time.Unix(1_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"A|Song|Two", "A|Song|Three", "A|Song|Four"}})
	if !res.OK {
		t.Fatalf("拆开: %+v", res)
	}
	enrichMu.Lock()
	two, three, four := enrichCache["A|Song|Two"], enrichCache["A|Song|Three"], enrichCache["A|Song|Four"]
	enrichMu.Unlock()
	if !two.Lyrics.EqualString(mine) || two.ManualLyrics || two.LyricsEntityOrigin != "" {
		t.Errorf("同步来的手改副本按留底恢复: %+v", two)
	}
	if !three.Lyrics.EqualString(edited) || three.LyricsEntityOrigin != "" || three.ManualLyrics {
		t.Errorf("没有能用的留底:词留着、去掉副本与手改标记: %+v", three)
	}
	if !four.Lyrics.EqualString(mine) || !four.ManualLyrics {
		t.Errorf("自己的手改原件不动: %+v", four)
	}
	drainSongEntityRebuild()
}

// 恢复合并:删掉两端都在 keys 里的拆开记录;删了才请重建。
func TestUnsplitSongEdit(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{}, true)
	if err := os.WriteFile(songEntityUserPath(), []byte(`{"version":1,"user_splits":[["A","B"],["A","C"],["B","C"]],"keep":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	drainSongEntityRebuild()
	if res := applyEnrichEdit(enrichEditRequest{Op: "unsplit_song", Keys: []string{"A", "B", "D"}}); !res.OK || res.Changed != 1 {
		t.Fatalf("恢复合并一对: %+v", res)
	}
	if got := readUserSplitPairs(t); !reflect.DeepEqual(got, [][]string{{"A", "C"}, {"B", "C"}}) {
		t.Errorf("只删 A–B: %v", got)
	}
	if !drainSongEntityRebuild() {
		t.Error("删了要请重建")
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "unsplit_song", Keys: []string{"C", "A", "B"}}); !res.OK || res.Changed != 2 {
		t.Fatalf("恢复合并全部: %+v", res)
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "unsplit_song", Keys: []string{"C", "A"}}); !res.OK || res.Changed != 0 {
		t.Fatalf("没有可删的: %+v", res)
	}
	if drainSongEntityRebuild() != true {
		t.Error("上一次删了两对,要请重建")
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "unsplit_song", Keys: []string{"C", "A"}}); res.Changed != 0 || drainSongEntityRebuild() {
		t.Error("什么都没删不请重建")
	}
	if data, _ := os.ReadFile(songEntityUserPath()); !strings.Contains(string(data), `"keep"`) {
		t.Errorf("别的键留着: %s", data)
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "unsplit_song", Keys: []string{"A"}}); res.OK {
		t.Error("不到两条不行")
	}
}

// 拆开之后重建:拆出去的跟留下的不再并,id 各归各;恢复合并之后重建又并回来。
func TestSplitSongSurvivesRebuild(t *testing.T) {
	dir := setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Two":   {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Three": {DurationSecs: 200.2, ISRCs: []string{"USAAA1100001"}},
	}, false)
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	song := func(k string) string {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return enrichCache[k].Song
	}
	t0 := time.Unix(1_000_000, 0)
	rebuildSongEntityTable(t0)
	id := song("A|Song|One")
	if id == "" || song("A|Song|Two") != id || song("A|Song|Three") != id {
		t.Fatal("同一个 ISRC 先并成一首")
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "split_song", Keys: []string{"A|Song|Two"}}); !res.OK {
		t.Fatalf("拆开: %+v", res)
	}
	split := song("A|Song|Two")
	rebuildSongEntityTable(t0.Add(time.Hour))
	if song("A|Song|One") != id || song("A|Song|Three") != id || song("A|Song|Two") != split || split == id {
		t.Errorf("重建之后照样拆开、id 接上: %q %q %q", song("A|Song|One"), song("A|Song|Two"), song("A|Song|Three"))
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "unsplit_song", Keys: []string{"A|Song|Two", "A|Song|One", "A|Song|Three"}}); !res.OK || res.Changed != 2 {
		t.Fatalf("恢复合并: %+v", res)
	}
	rebuildSongEntityTable(t0.Add(2 * time.Hour))
	if song("A|Song|Two") != id {
		t.Errorf("恢复合并之后按证据并回原来那首: %q", song("A|Song|Two"))
	}
	drainSongEntityRebuild()
}

// 常驻循环收到「马上重建」就建一次表,不等每天那一次。
func TestSongEntityRebuildNowWakesShadowLoop(t *testing.T) {
	dir := setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One": {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Two": {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
	}, false)
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	drainSongEntityRebuild()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { startSongEntityShadow(ctx); close(done) }()
	defer func() { cancel(); <-done }()
	requestSongEntityRebuild()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(songEntityTablePath()); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("请马上重建之后没有建表")
}

// 锁定开关:同一首歌的手改副本跟着原件一起翻(不然下一轮同步又要重抄),回报的「几首」只数原件。
func TestManualLockCountsOriginalsOnly(t *testing.T) {
	lrc := songShareLRC("picked")
	sha := manualPickFingerprint(lrc)
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(lrc), ManualLyrics: true, ManualPickSHA: sha},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(lrc), ManualLyrics: true, ManualPickSHA: sha, LyricsEntityOrigin: "A|Song|One"},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: bt(lrc), ManualLyrics: true, ManualPickSHA: sha, LyricsEntityOrigin: "A|Song|One"},
		"B|Other|One":  {Lyrics: bt(songShareLRC("other")), ManualLyrics: true, ManualPickSHA: manualPickFingerprint(songShareLRC("other"))},
	}, true)
	if res := applyEnrichEdit(enrichEditRequest{Op: "count_manual_lock", Value: false}); !res.OK || res.Changed != 2 {
		t.Fatalf("只数原件: %+v", res)
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "set_manual_lock", Value: false})
	if !res.OK || res.Changed != 2 {
		t.Fatalf("回报只数原件: %+v", res)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, k := range []string{"A|Song|One", "A|Song|Two", "A|Song|Three", "B|Other|One"} {
		if enrichCache[k].ManualLyrics {
			t.Errorf("%s 要跟着翻", k)
		}
	}
}

// 两份手改选一份统一:别的原件留底、另存一份此刻的整条,换成选定那份的副本;其余写法跟上;开关关着、选的不是原件时拒绝。
// 统一两份手改只动同一个共享组:别的组自己的手改原件留着。
func TestResolveManualConflictStaysInShareGroup(t *testing.T) {
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(songShareLRC("x")), LyricsSource: "manual", ManualLyrics: true},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(songShareLRC("y")), LyricsSource: "manual", ManualLyrics: true},
		"A|Song|Three": {Song: "s_000000000001", SongShare: 1, Lyrics: bt(songShareLRC("z")), LyricsSource: "manual", ManualLyrics: true},
	}, true)
	if res := applyEnrichEdit(enrichEditRequest{Op: "resolve_manual_conflict", Key: "A|Song|One"}); !res.OK {
		t.Fatalf("统一: %+v", res)
	}
	if got, _ := cacheEntry(t, "A|Song|Two"); !got.Lyrics.EqualString(songShareLRC("x")) || got.LyricsEntityOrigin != "A|Song|One" {
		t.Errorf("同组那份换成选的: %+v", got)
	}
	if got, _ := cacheEntry(t, "A|Song|Three"); !got.Lyrics.EqualString(songShareLRC("z")) || got.LyricsEntityOrigin != "" {
		t.Errorf("别的组的手改原件留着: %+v", got)
	}
}

func TestResolveManualConflictEdit(t *testing.T) {
	a, b, auto := songShareLRC("mine-a"), songShareLRC("mine-b"), songShareLRC("auto")
	dir := setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(a), ManualLyrics: true, LyricsSource: "manual"},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(b), ManualLyrics: true, LyricsSource: "manual"},
		"A|Song|Three": {Song: "s_000000000001", Lyrics: bt(a), ManualLyrics: true, LyricsEntityOrigin: "A|Song|One"},
		"A|Song|Four":  {Song: "s_000000000001", Lyrics: bt(auto), LyricsSource: "qq"},
		"A|Song|Five":  {Song: "s_000000000001", Lyrics: bt(b), ManualLyrics: true, LyricsSource: "manual"},
		"B|Other|One":  {Song: "s_000000000002", Lyrics: bt(a), ManualLyrics: true},
	}, true)
	if res := applyEnrichEdit(enrichEditRequest{Op: "resolve_manual_conflict", Key: "A|Song|Three"}); res.OK {
		t.Error("副本不能当选定的那份")
	}
	res := applyEnrichEdit(enrichEditRequest{Op: "resolve_manual_conflict", Key: "A|Song|Two"})
	if !res.OK || res.Changed != 3 {
		t.Fatalf("统一: %+v", res)
	}
	for _, k := range []string{"A|Song|One", "A|Song|Three", "A|Song|Four"} {
		got, _ := cacheEntry(t, k)
		if !got.Lyrics.EqualString(b) || got.LyricsEntityOrigin != "A|Song|Two" || !got.ManualLyrics {
			t.Errorf("%s 换成选定那份的副本: %+v", k, got)
		}
	}
	if got, _ := cacheEntry(t, "A|Song|Five"); !got.Lyrics.EqualString(b) || got.LyricsEntityOrigin != "" {
		t.Errorf("内容跟选定那份一样的原件不动: %+v", got)
	}
	if got, _ := cacheEntry(t, "B|Other|One"); !got.Lyrics.EqualString(a) || got.LyricsEntityOrigin != "" {
		t.Errorf("别的歌不动: %+v", got)
	}
	if _, pre := readPreEntry(t, "A|Song|One"); !pre.Lyrics.EqualString(a) {
		t.Errorf("被换掉的原件要留底: %+v", pre)
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "backups", "*-song-entity-manual", "entries.json"))
	if len(matches) != 1 {
		t.Fatalf("被换掉的原件另存一份: %v", matches)
	}
	data, _ := os.ReadFile(matches[0])
	var saved map[string]enrichEntry
	if err := json.Unmarshal(data, &saved); err != nil || len(saved) != 1 || !saved["A|Song|One"].Lyrics.EqualString(a) {
		t.Errorf("另存的是被换掉的原件此刻的样子: %v %+v", err, saved)
	}
	setFeatures(featureFlags{SongEntityShadow: true})
	if res := applyEnrichEdit(enrichEditRequest{Op: "resolve_manual_conflict", Key: "A|Song|Two"}); res.OK {
		t.Error("开关关着时拒绝")
	}
}

// 歌词同步开着时标 / 撤纯音乐作用到共享组;别的共享组、手改过词的、采纳的那份还在的不动;开关关着只动这一条。
func TestSetInstrumentalFollowsShareGroup(t *testing.T) {
	picked := songShareLRC("picked")
	setUpSongShareTest(t, map[string]enrichEntry{
		"A|Song|One":   {Song: "s_000000000001", Lyrics: bt(songShareLRC("a"))},
		"A|Song|Two":   {Song: "s_000000000001", Lyrics: bt(songShareLRC("a"))},
		"A|Song|Three": {Song: "s_000000000001", SongShare: 1, Lyrics: bt(songShareLRC("c"))},
		"A|Song|Four":  {Song: "s_000000000001", Lyrics: bt(songShareLRC("mine")), ManualLyrics: true},
		"A|Song|Five":  {Song: "s_000000000001", Lyrics: bt(picked), ManualPickSHA: manualPickFingerprint(picked)},
		"B|Other|One":  {Song: "s_000000000002", Lyrics: bt(songShareLRC("b"))},
	}, true)
	instrumental := func() []string {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		var out []string
		for k, e := range enrichCache {
			if e.Instrumental {
				out = append(out, k)
			}
		}
		sort.Strings(out)
		return out
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: "A|Song|One", Value: true}); !res.OK {
		t.Fatalf("标纯音乐: %+v", res)
	}
	if got := instrumental(); !slices.Equal(got, []string{"A|Song|One", "A|Song|Two"}) {
		t.Errorf("同一共享组一起标,别的组、手改、采纳、别的歌不动: %v", got)
	}
	if res := applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: "A|Song|Two", Value: false}); !res.OK {
		t.Fatalf("撤纯音乐: %+v", res)
	}
	if got := instrumental(); len(got) != 0 {
		t.Errorf("撤也一起撤: %v", got)
	}
	if got, _ := cacheEntry(t, "A|Song|One"); !got.InstrumentalCleared {
		t.Error("一起撤的那条也记下「用户说不是纯音乐」")
	}
	setFeatures(featureFlags{SongEntityShadow: true})
	applyEnrichEdit(enrichEditRequest{Op: "set_instrumental", Key: "A|Song|One", Value: true})
	if got := instrumental(); !slices.Equal(got, []string{"A|Song|One"}) {
		t.Errorf("开关关着只动这一条: %v", got)
	}
}
