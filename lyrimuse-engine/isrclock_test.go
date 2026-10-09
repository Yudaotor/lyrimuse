package main

import (
	"context"
	"testing"
	"time"
)

// 升级重试与重评持着 enrichMu 时不能再去取播放器给的 ISRC:Amazon 那一路(amazonCachedASIN)缓存过期时要拿同一把锁,
// 持锁调用会锁死整个引擎。一轮在上锁之前问歌词源时已经取过一次 ISRC、缓存刚建过,只有从问完源到上锁之间缓存
// 正好过期才撞得上;这里在假 musixmatch 应答时把缓存置成过期,让每一轮都落在这种情形,要求很快跑完。
func TestLyricsRoundsLookUpPlaybackISRCOutsideTheLock(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, func(context.Context) {
		amazonCachedASINsMu.Lock()
		amazonCachedASINs = nil
		amazonCachedASINsMu.Unlock()
	})
	const artist = rescoreTestArtist
	emptyKey, lyricKey := enrichKey(artist, "Lock Empty Song", ""), enrichKey(artist, "Lock Rescored Song", "Some Album")
	withEnrichCache(t, map[string]enrichEntry{
		emptyKey: {},
		lyricKey: {Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "musixmatch",
			LyricsScoringVersion: lyricsScoringVersion - 1},
	})
	run := func(name string, round func()) {
		done := make(chan struct{})
		go func() {
			defer close(done)
			round()
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatalf("%s持着 enrichMu 去取播放器的 ISRC,锁死了", name)
		}
	}
	run("升级重试", func() { retryLyricsUpgrade(context.Background(), emptyKey, artist, "Lock Empty Song", "", 180, true) })
	run("重评", func() { rescoreLyrics(context.Background(), lyricKey, artist, "Lock Rescored Song", "Some Album", 180) })
}
