package main

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

// 正在播的那首:整份写盘之前单条快照已经在磁盘上,内容是这一条(候选明细拆掉);预解析别的歌不写。
func TestCommitPlayingKeyWritesEntryBeforeFullSave(t *testing.T) {
	withTempIndexCache(t)
	origNow, origPlaying := enrichSaveNow, enrichPlayingKey.Load()
	t.Cleanup(func() {
		enrichSaveNow = origNow
		enrichPlayingKey.Store(origPlaying)
	})
	var sawSnapshotAtSave bool
	enrichSaveNow = func() {
		_, err := os.Stat(playingEntryPath())
		sawSnapshotAtSave = err == nil
	}

	commitEnrichEntry("x|prefetch|y", enrichEntry{Lyrics: "[00:01.00]other"})
	if _, err := os.Stat(playingEntryPath()); err == nil {
		t.Fatal("预解析别的歌不该写单条快照")
	}

	const key = "a|now|b"
	noteEnrichPlayingKey(key)
	commitEnrichEntry(key, enrichEntry{Lyrics: "[00:01.00]hi", LyricsYRC: "[1000,500](1000,500,0)hi", TS: 7,
		LyricsDecision: fullDecision(lyricsDecisionPathFirstResolve, 7, "qq")})
	if !sawSnapshotAtSave {
		t.Fatal("整份写盘开始时单条快照就该已经在磁盘上")
	}
	b, err := os.ReadFile(playingEntryPath())
	if err != nil {
		t.Fatal(err)
	}
	var got playingEntryFile
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.Key != key || got.Entry.Lyrics != "[00:01.00]hi" || got.Entry.LyricsYRC == "" || got.Entry.TS != 7 {
		t.Fatalf("单条快照内容不对: %+v", got)
	}
	if hasDecisionDetails(got.Entry.LyricsDecision) {
		t.Fatal("单条快照里不该带候选明细")
	}
}

// 一次性子命令读完主缓存之后,单条快照比主缓存新就盖上去,不比它新就不动;快照不在、坏了都不动。
func TestOverlayPlayingEntryReadOnly(t *testing.T) {
	dir := t.TempDir()
	cachePath, path := dir+"/cache.json", dir+"/playing.json"
	const key = "leehom wang|gong zhuan zi zhuan|revolution"
	writeAt := func(p string, b []byte, at time.Time) {
		t.Helper()
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := json.Marshal(playingEntryFile{Key: key, Entry: enrichEntry{ISRCs: []string{"TWA479820001"}, TS: 9}})
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now().Add(-time.Hour)
	for _, c := range []struct {
		name      string
		snapshot  []byte
		snapAt    time.Time
		noCache   bool
		wantTS    int64
		wantFound bool
	}{
		{"快照更新", snapshot, base.Add(time.Minute), false, 9, true},
		{"快照更旧", snapshot, base.Add(-time.Minute), false, 1, true},
		{"同一时刻算不比它新", snapshot, base, false, 1, true},
		{"主缓存读不到", snapshot, base, true, 9, true},
		{"快照坏了", []byte("{"), base.Add(time.Minute), false, 1, true},
	} {
		os.Remove(cachePath)
		if !c.noCache {
			writeAt(cachePath, []byte("{}"), base)
		}
		writeAt(path, c.snapshot, c.snapAt)
		withEnrichCache(t, map[string]enrichEntry{key: {TS: 1}})
		overlayPlayingEntryReadOnly(path, cachePath)
		e, ok := enrichCache[key]
		if ok != c.wantFound || e.TS != c.wantTS {
			t.Errorf("%s: got ok=%v TS=%d, want TS=%d", c.name, ok, e.TS, c.wantTS)
		}
	}
	withEnrichCache(t, map[string]enrichEntry{})
	overlayPlayingEntryReadOnly(dir+"/missing.json", cachePath)
	if len(enrichCache) != 0 {
		t.Error("快照不在时不该动缓存")
	}
}
