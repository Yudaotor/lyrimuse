package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// 流式写必须跟原来的 json.Marshal(map) 逐字节一致:key 排序、HTML 转义、Unknown 原样写回都要对上。
func TestWriteEnrichSnapshotMatchesMarshal(t *testing.T) {
	snap := map[string]enrichEntry{
		"周杰伦|晴天|叶惠美":           {Lyrics: "[00:01.00]故事的小黄花\n", CoverURL: "https://example.com/a.jpg?x=1&y=2"},
		"AC/DC|Back In Black|": {LyricsYRC: `[0,1000](0,500,0)Back (500,500,0)<in>`},
		`Tom "T" & Jerry|<b>|`: {Lyrics: "a\u2028b"},
		"":                     {},
		"ゆず|夏色|":               {Unknown: map[string]json.RawMessage{"future_field": json.RawMessage(`{"n":1}`)}},
	}
	want, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	var got bytes.Buffer
	if err := writeEnrichSnapshot(&got, snap); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Bytes(), want) {
		t.Fatalf("stream output differs from json.Marshal\n got: %s\nwant: %s", got.Bytes(), want)
	}

	var empty bytes.Buffer
	if err := writeEnrichSnapshot(&empty, map[string]enrichEntry{}); err != nil {
		t.Fatal(err)
	}
	if empty.String() != "{}" {
		t.Fatalf("empty snapshot = %q, want {}", empty.String())
	}
}

// 节流:先写;间隔内再来的请求合成一次补写;flush 取消排着的补写并当场写;正在播的这首当场写。
func TestRequestEnrichSaveThrottle(t *testing.T) {
	var saves atomic.Int32
	origNow, origInterval := enrichSaveNow, enrichSaveMinInterval
	enrichSaveThrottleMu.Lock()
	origThrottled, origLast := enrichSaveThrottled, enrichLastSaveAt
	enrichSaveThrottleMu.Unlock()
	origPlaying := enrichPlayingKey.Load()
	t.Cleanup(func() {
		enrichSaveThrottleMu.Lock()
		if enrichSaveTimer != nil {
			enrichSaveTimer.Stop()
			enrichSaveTimer = nil
		}
		cancelEnrichDeferredSaveLocked()
		enrichSaveThrottled, enrichLastSaveAt = origThrottled, origLast
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow, enrichSaveMinInterval = origNow, origInterval
		enrichPlayingKey.Store(origPlaying)
	})
	enrichSaveNow = func() { saves.Add(1) }
	enrichSaveMinInterval = 80 * time.Millisecond

	// 节流关着(CLI / 测试的默认):每次都当场写。
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled = false
	enrichSaveThrottleMu.Unlock()
	requestEnrichSave()
	requestEnrichSave()
	if n := saves.Load(); n != 2 {
		t.Fatalf("throttle off: saves = %d, want 2", n)
	}

	saves.Store(0)
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled = true
	enrichLastSaveAt = time.Time{}
	enrichSaveThrottleMu.Unlock()

	requestEnrichSave() // 距上次很久:当场写
	if n := saves.Load(); n != 1 {
		t.Fatalf("leading save: saves = %d, want 1", n)
	}
	for i := 0; i < 5; i++ { // 间隔内连来五次:只排一次补写
		requestEnrichSave()
	}
	if n := saves.Load(); n != 1 {
		t.Fatalf("within interval: saves = %d, want still 1", n)
	}
	deadline := time.Now().Add(2 * time.Second)
	for saves.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if n := saves.Load(); n != 2 {
		t.Fatalf("trailing save: saves = %d, want 2", n)
	}
	time.Sleep(150 * time.Millisecond)
	if n := saves.Load(); n != 2 {
		t.Fatalf("no extra saves after trailing: saves = %d, want 2", n)
	}

	// flush:间隔内先排上补写,flush 当场写并取消它。
	requestEnrichSave()
	requestEnrichSave()
	flushEnrichSave()
	if n := saves.Load(); n != 3 && n != 4 {
		t.Fatalf("flush: saves = %d, want 3 or 4", n)
	}
	before := saves.Load()
	time.Sleep(150 * time.Millisecond)
	if n := saves.Load(); n != before {
		t.Fatalf("flush must cancel the pending trailing save: %d → %d", before, n)
	}

	// 正在播的这首:单条快照当场写(App 读它出词),整份落盘节流;预取别的歌攒着,不算进这次补写。
	savedPath, savedCache := enrichPath, enrichCache
	t.Cleanup(func() { enrichPath, enrichCache = savedPath, savedCache })
	enrichPath = filepath.Join(t.TempDir(), "lyrimuse-enrich-cache.json")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{"a|now|b": {Lyrics: "[00:01.00]hi"}}
	enrichMu.Unlock()
	noteEnrichPlayingKey("a|now|b")
	requestEnrichSave() // 刚写过:接下来都在间隔内
	before = saves.Load()
	commitEnrichSave("x|prefetch|y")
	commitEnrichSave("a|now|b")
	commitEnrichSave("a|now|b")
	if n := saves.Load(); n != before {
		t.Fatalf("playing key must go through the throttle too: %d → %d", before, n)
	}
	if _, err := os.Stat(playingEntryPath()); err != nil {
		t.Fatalf("playing entry must be written at once: %v", err)
	}
	deadline = time.Now().Add(2 * time.Second)
	for saves.Load() == before && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(150 * time.Millisecond)
	if n := saves.Load(); n != before+1 {
		t.Fatalf("three commits within the interval must coalesce into one trailing save: %d → %d", before, n)
	}
}

// 保存残骸:超过一天的删、刚写的留(可能是别的进程正在写)、旁边的备份文件一概不碰。
func TestRemoveStaleEnrichTemps(t *testing.T) {
	dir := t.TempDir()
	savedPath := enrichPath
	t.Cleanup(func() { enrichPath = savedPath })
	enrichPath = filepath.Join(dir, "lyrimuse-enrich-cache.json")
	old := enrichPath + ".tmp.111"
	fresh := enrichPath + ".tmp.222"
	backup := filepath.Join(dir, "backup-before-x.json")
	bak := enrichPath + ".bak-before-y"
	for _, p := range []string{old, fresh, backup, bak, enrichPath} {
		if err := os.WriteFile(p, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-25 * time.Hour)
	for _, p := range []string{old, backup, bak} {
		if err := os.Chtimes(p, past, past); err != nil {
			t.Fatal(err)
		}
	}
	removeStaleEnrichTemps()
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("stale temp must be removed")
	}
	for _, p := range []string{fresh, backup, bak, enrichPath} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("%s must be kept: %v", filepath.Base(p), err)
		}
	}
}

// restoreEnrichSaveStateOnCleanup 存下节流相关的全局状态,测试结束时停掉排着的定时器、原样还原。
func restoreEnrichSaveStateOnCleanup(t *testing.T) {
	origNow, origInterval := enrichSaveNow, enrichSaveMinInterval
	origBackground, origBookkeeping := enrichBackgroundSaveDelay, enrichBookkeepingSaveDelay
	enrichSaveThrottleMu.Lock()
	origThrottled, origLast := enrichSaveThrottled, enrichLastSaveAt
	enrichSaveThrottleMu.Unlock()
	origPlaying := enrichPlayingKey.Load()
	t.Cleanup(func() {
		enrichSaveThrottleMu.Lock()
		if enrichSaveTimer != nil {
			enrichSaveTimer.Stop()
			enrichSaveTimer = nil
		}
		cancelEnrichDeferredSaveLocked()
		enrichSaveThrottled, enrichLastSaveAt = origThrottled, origLast
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow, enrichSaveMinInterval = origNow, origInterval
		enrichBackgroundSaveDelay, enrichBookkeepingSaveDelay = origBackground, origBookkeeping
		enrichPlayingKey.Store(origPlaying)
	})
}

func waitEnrichSaves(t *testing.T, saves *atomic.Int32, want int32, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for saves.Load() < want && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if n := saves.Load(); n != want {
		t.Fatalf("saves = %d, want %d", n, want)
	}
}

// 别的歌的改动攒着、到点只写一次;正在播的这首照常当场写;两种延后先到期的为准,后来的不往后推;flush 取消排着的。
func TestRequestEnrichSaveForDefersOtherSongs(t *testing.T) {
	var saves atomic.Int32
	restoreEnrichSaveStateOnCleanup(t)
	enrichSaveNow = func() { saves.Add(1) }
	enrichSaveMinInterval = 5 * time.Millisecond
	enrichBackgroundSaveDelay = 40 * time.Millisecond
	enrichBookkeepingSaveDelay = 160 * time.Millisecond
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled, enrichLastSaveAt = true, time.Time{}
	enrichSaveThrottleMu.Unlock()
	noteEnrichPlayingKey("p|now|x")

	for range 5 {
		requestEnrichSaveFor("o|other|y")
	}
	commitEnrichSave("o|other|z")
	if n := saves.Load(); n != 0 {
		t.Fatalf("别的歌的改动不该当场写: saves = %d", n)
	}
	waitEnrichSaves(t, &saves, 1, 2*time.Second)
	time.Sleep(100 * time.Millisecond)
	if n := saves.Load(); n != 1 {
		t.Fatalf("攒着的那几次到点只该写一次: saves = %d", n)
	}

	saves.Store(0)
	time.Sleep(10 * time.Millisecond)
	requestEnrichSaveFor("p|now|x")
	if n := saves.Load(); n != 1 {
		t.Fatalf("正在播的这首应当当场写: saves = %d", n)
	}

	// 记账那次(160ms)排着,再来一条别的歌(40ms):提前到 40ms,原来那次不再写。
	saves.Store(0)
	time.Sleep(10 * time.Millisecond)
	requestEnrichBookkeepingSave("o|other|y")
	requestEnrichSaveFor("o|other|y")
	waitEnrichSaves(t, &saves, 1, 2*time.Second)
	time.Sleep(200 * time.Millisecond)
	if n := saves.Load(); n != 1 {
		t.Fatalf("提前之后原来那次不该再写: saves = %d", n)
	}

	// 别的歌那次(40ms)排着,再来记账(160ms):不往后推,40ms 写一次,160ms 不再写。
	saves.Store(0)
	time.Sleep(10 * time.Millisecond)
	requestEnrichSaveFor("o|other|y")
	requestEnrichBookkeepingSave("o|other|y")
	waitEnrichSaves(t, &saves, 1, 2*time.Second)
	time.Sleep(200 * time.Millisecond)
	if n := saves.Load(); n != 1 {
		t.Fatalf("更晚的请求不该往后推、也不该另写一次: saves = %d", n)
	}

	saves.Store(0)
	requestEnrichSaveFor("o|other|y")
	flushEnrichSave()
	time.Sleep(100 * time.Millisecond)
	if n := saves.Load(); n != 1 {
		t.Fatalf("flush 应当当场写一次并取消排着的: saves = %d", n)
	}
}

// 换歌那一拍:新这首已经有条目就当场写单条快照,排着的延后存盘提前到现在;没有条目的歌不写快照。
func TestNotePlayingKeyWritesSnapshotAndPromotesDeferredSave(t *testing.T) {
	var saves atomic.Int32
	restoreEnrichSaveStateOnCleanup(t)
	savedPath, savedCache := enrichPath, enrichCache
	t.Cleanup(func() { enrichPath, enrichCache = savedPath, savedCache })
	enrichPath = filepath.Join(t.TempDir(), "lyrimuse-enrich-cache.json")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{"n|next|y": {Lyrics: "[00:01.00]next"}}
	enrichMu.Unlock()
	enrichSaveNow = func() { saves.Add(1) }
	enrichSaveMinInterval = 5 * time.Millisecond
	enrichBackgroundSaveDelay = time.Hour
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled, enrichLastSaveAt = true, time.Time{}
	enrichSaveThrottleMu.Unlock()

	noteEnrichPlayingKey("p|now|x")
	if _, err := os.Stat(playingEntryPath()); err == nil {
		t.Fatal("内存里没有条目的歌不该写单条快照")
	}
	requestEnrichSaveFor("n|next|y")
	if n := saves.Load(); n != 0 {
		t.Fatalf("预取的那首还不是正在播的,不该当场写: saves = %d", n)
	}
	noteEnrichPlayingKey("n|next|y")
	b, err := os.ReadFile(playingEntryPath())
	if err != nil {
		t.Fatalf("换到已有条目的歌,应当当场写单条快照: %v", err)
	}
	var got playingEntryFile
	if err := json.Unmarshal(b, &got); err != nil || got.Key != "n|next|y" || got.Entry.Lyrics != "[00:01.00]next" {
		t.Fatalf("单条快照内容不对: %+v err=%v", got, err)
	}
	waitEnrichSaves(t, &saves, 1, 2*time.Second)
	enrichSaveThrottleMu.Lock()
	pending := enrichDeferredSaveTimer != nil
	enrichSaveThrottleMu.Unlock()
	if pending {
		t.Fatal("提前写过之后不该还排着延后存盘")
	}
}
