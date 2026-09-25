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
		`Tom "T" & Jerry|<b>|`: {Lyrics: "a b"},
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

	// 正在播的这首:间隔内也当场写;别的歌仍然节流。
	noteEnrichPlayingKey("a|now|b")
	before = saves.Load()
	commitEnrichSave("x|prefetch|y")
	commitEnrichSave("x|prefetch|y")
	commitEnrichSave("a|now|b")
	if n := saves.Load(); n != before+1 && n != before+2 {
		t.Fatalf("playing key must save immediately: %d → %d", before, n)
	}
	after := saves.Load()
	time.Sleep(150 * time.Millisecond)
	if n := saves.Load(); n != after {
		t.Fatalf("immediate save must cancel the pending trailing save: %d → %d", after, n)
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
