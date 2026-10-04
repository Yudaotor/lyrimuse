package main

import (
	"encoding/json"
	"os"
	"testing"
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
