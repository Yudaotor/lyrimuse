package main

import (
	"context"
	"testing"
	"time"
)

// 升级重试与重评不能持着 enrichMu 去取播放器给的 ISRC:取号要读别的 App 的本机缓存,Amazon 按歌手 + 歌名认曲目的那份
// 索引(amazonCachedASIN)过期时重建还要拿同一把锁,取号的路一旦经过它,持锁调用就会锁死整个引擎。这里在假 musixmatch
// 应答时把那份索引置成过期,要求每一轮都很快跑完。
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
