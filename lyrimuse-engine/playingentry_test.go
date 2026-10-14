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

// 一次性子命令只读加载:主缓存之上叠比它新的待落盘小文件,再叠比它新的在播单条快照;不比主缓存新的、坏了的、不在的都不叠;
// 主缓存不在时照叠。
func TestLoadEnrichCacheReadOnlyOverlaysUnsavedChanges(t *testing.T) {
	const a, b, c = "x|played earlier|y", "x|untouched|y", "x|playing|y"
	base := time.Now().Add(-time.Hour)
	write := func(t *testing.T, p string, v any, at time.Time) {
		t.Helper()
		data, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, data, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
	}
	main := map[string]enrichEntry{a: {TS: 1}, b: {TS: 1}, c: {TS: 1}}
	pending := enrichPendingFile{Entries: map[string]enrichEntry{a: {TS: 2, ISRCs: []string{"TWA479820001"}}, c: {TS: 2}}}
	playing := playingEntryFile{Key: c, Entry: enrichEntry{TS: 3}}
	for _, tc := range []struct {
		name                  string
		noMain                bool
		pendingAt, playingAt  time.Duration // 相对主缓存的修改时间
		brokenPending         bool
		wantA, wantB, wantC   int64
		wantBMissing, noFiles bool
	}{
		{name: "两份都比主缓存新", pendingAt: time.Minute, playingAt: 2 * time.Minute, wantA: 2, wantB: 1, wantC: 3},
		{name: "小文件比主缓存旧", pendingAt: -time.Minute, playingAt: time.Minute, wantA: 1, wantB: 1, wantC: 3},
		{name: "快照比主缓存旧", pendingAt: time.Minute, playingAt: -time.Minute, wantA: 2, wantB: 1, wantC: 2},
		{name: "同一时刻都不算新", wantA: 1, wantB: 1, wantC: 1},
		{name: "小文件坏了", pendingAt: time.Minute, brokenPending: true, wantA: 1, wantB: 1, wantC: 1},
		{name: "主缓存不在", noMain: true, wantA: 2, wantBMissing: true, wantC: 3},
		{name: "两份都不在", noFiles: true, wantA: 1, wantB: 1, wantC: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withEnrichCache(t, nil)
			dir := t.TempDir()
			cachePath := dir + "/" + clientName + "-enrich-cache.json"
			if !tc.noMain {
				write(t, cachePath, main, base)
			}
			if !tc.noFiles {
				if tc.brokenPending {
					if err := os.WriteFile(enrichPendingPathFor(cachePath), []byte("{"), 0o644); err != nil {
						t.Fatal(err)
					}
					at := base.Add(tc.pendingAt)
					if err := os.Chtimes(enrichPendingPathFor(cachePath), at, at); err != nil {
						t.Fatal(err)
					}
				} else {
					write(t, enrichPendingPathFor(cachePath), pending, base.Add(tc.pendingAt))
				}
				if !tc.brokenPending {
					write(t, playingEntryPathFor(cachePath), playing, base.Add(tc.playingAt))
				}
			}
			loadEnrichCacheReadOnly(cachePath)
			if got := enrichCache[a].TS; got != tc.wantA {
				t.Errorf("放过的那首 TS = %d, want %d", got, tc.wantA)
			}
			if eb, ok := enrichCache[b]; ok == tc.wantBMissing || (ok && eb.TS != tc.wantB) {
				t.Errorf("没改过的那首 = %+v ok=%v, want TS %d missing=%v", eb, ok, tc.wantB, tc.wantBMissing)
			}
			if got := enrichCache[c].TS; got != tc.wantC {
				t.Errorf("正在放的那首 TS = %d, want %d", got, tc.wantC)
			}
			if tc.name == "两份都比主缓存新" && len(enrichCache[a].ISRCs) != 1 {
				t.Errorf("小文件里的号要跟着条目进来: %+v", enrichCache[a])
			}
		})
	}
}
