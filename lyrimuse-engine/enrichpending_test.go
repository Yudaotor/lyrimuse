package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func restoreEnrichPendingOnCleanup(t *testing.T) {
	t.Helper()
	savedDelay, savedNow := enrichPendingWriteDelay, enrichPendingNow
	enrichMu.Lock()
	savedKeys, savedSeq, savedNew := enrichPendingKeys, enrichPendingSeq, enrichPendingHasNew
	enrichPendingKeys, enrichPendingHasNew = map[string]uint64{}, false
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichPendingTimerMu.Lock()
		if enrichPendingTimer != nil {
			enrichPendingTimer.Stop()
			enrichPendingTimer = nil
		}
		enrichPendingTimerMu.Unlock()
		enrichPendingWriteDelay, enrichPendingNow = savedDelay, savedNow
		enrichMu.Lock()
		enrichPendingKeys, enrichPendingSeq, enrichPendingHasNew = savedKeys, savedSeq, savedNew
		enrichMu.Unlock()
	})
}

// readEnrichPendingFile 等小文件出现并读出来。
func readEnrichPendingFile(t *testing.T, within time.Duration) enrichPendingFile {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		b, err := os.ReadFile(enrichPendingPath())
		if err == nil {
			var f enrichPendingFile
			if err := json.Unmarshal(b, &f); err != nil {
				t.Fatalf("小文件解不开: %v", err)
			}
			return f
		}
		if time.Now().After(deadline) {
			t.Fatalf("等不到小文件: %v", err)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func withEnrichPendingCache(t *testing.T, cache map[string]enrichEntry) {
	t.Helper()
	savedPath, savedCache, savedDirty := enrichPath, enrichCache, enrichDirty
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPath, enrichCache, enrichDirty = savedPath, savedCache, savedDirty
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	enrichPath = filepath.Join(t.TempDir(), "lyrimuse-enrich-cache.json")
	enrichCache = cache
	enrichMu.Unlock()
	restoreEnrichPendingOnCleanup(t)
	enrichPendingWriteDelay = time.Millisecond
}

// 带 key 的改动攒一下写进小文件;整份落盘之后清掉已经写进去的,取快照之后又改的留着重写;一条不剩就删文件。
func TestEnrichPendingWriteAndClearAfterFullSave(t *testing.T) {
	withEnrichPendingCache(t, map[string]enrichEntry{"a|1|x": {Lyrics: "A"}, "b|2|y": {Lyrics: "B"}})
	noteEnrichPending("a|1|x", false)
	noteEnrichPending("b|2|y", false)
	f := readEnrichPendingFile(t, time.Second)
	if len(f.Entries) != 2 || f.Entries["a|1|x"].Lyrics != "A" {
		t.Fatalf("两条都该在小文件里: %+v", f.Entries)
	}
	enrichMu.Lock()
	seq := enrichPendingSeqLocked()
	enrichMu.Unlock()
	noteEnrichPending("b|2|y", false) // 取快照之后又改了一次
	enrichPendingSavedThrough(seq)
	f = readEnrichPendingFile(t, time.Second)
	if _, ok := f.Entries["a|1|x"]; ok || len(f.Entries) != 1 {
		t.Fatalf("整份落盘之后只该剩取快照之后改的那条: %+v", f.Entries)
	}
	enrichMu.Lock()
	seq = enrichPendingSeqLocked()
	enrichMu.Unlock()
	enrichPendingSavedThrough(seq)
	if _, err := os.Stat(enrichPendingPath()); !os.IsNotExist(err) {
		t.Fatalf("一条不剩时该删掉小文件: %v", err)
	}
}

// 新歌进缓存:写完小文件就提醒歌曲实体增量重算,不等整份落盘;只是改了旧条目不提醒。
func TestEnrichPendingNewKeyNudgesSongEntities(t *testing.T) {
	withEnrichPendingCache(t, map[string]enrichEntry{"a|1|x": {Lyrics: "A"}})
	select {
	case <-songEntityCacheSaved:
	default:
	}
	noteEnrichPending("a|1|x", false)
	readEnrichPendingFile(t, time.Second)
	select {
	case <-songEntityCacheSaved:
		t.Fatal("只是改了旧条目,不该提醒增量重算")
	case <-time.After(20 * time.Millisecond):
	}
	noteEnrichPending("a|1|x", true)
	select {
	case <-songEntityCacheSaved:
	case <-time.After(time.Second):
		t.Fatal("新歌进缓存该提醒增量重算")
	}
}

// 启动时小文件比主缓存新:叠回内存、记成待落盘;比主缓存旧就不动。
func TestApplyEnrichPendingAtLoad(t *testing.T) {
	withEnrichPendingCache(t, map[string]enrichEntry{"a|1|x": {Lyrics: "old"}})
	cachePath := enrichPath
	if err := os.WriteFile(cachePath, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(enrichPendingFile{Entries: map[string]enrichEntry{"a|1|x": {Lyrics: "new"}, "c|3|z": {Lyrics: "C"}}})
	if err := os.WriteFile(enrichPendingPath(), b, 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(enrichPendingPath(), old, old); err != nil {
		t.Fatal(err)
	}
	applyEnrichPendingAtLoad(cachePath)
	enrichMu.Lock()
	got := enrichCache["a|1|x"].Lyrics
	enrichMu.Unlock()
	if got != "old" {
		t.Fatalf("小文件比主缓存旧,不该叠回: %q", got)
	}
	newer := time.Now().Add(time.Minute)
	if err := os.Chtimes(enrichPendingPath(), newer, newer); err != nil {
		t.Fatal(err)
	}
	applyEnrichPendingAtLoad(cachePath)
	enrichMu.Lock()
	got, c, dirty, pending := enrichCache["a|1|x"].Lyrics, enrichCache["c|3|z"].Lyrics, enrichDirty, len(enrichPendingKeys)
	enrichMu.Unlock()
	if got != "new" || c != "C" || !dirty || pending != 2 {
		t.Fatalf("小文件比主缓存新,该叠回并记成待落盘: a=%q c=%q dirty=%v pending=%d", got, c, dirty, pending)
	}
}
