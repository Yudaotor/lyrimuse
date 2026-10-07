package main

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"
)

// stubLyricSourceCooldownLeft 把各源的剩余冷却换成给定值,没列出的源当作不在冷却。
func stubLyricSourceCooldownLeft(t *testing.T, left map[string]time.Duration) {
	t.Helper()
	saved := lyricSourceCooldownLeft
	t.Cleanup(func() { lyricSourceCooldownLeft = saved })
	lyricSourceCooldownLeft = func(source string) (time.Duration, bool) {
		d, ok := left[source]
		return d, ok
	}
}

func TestLyricSourcesSkippedForRetry(t *testing.T) {
	stubLyricSourceCooldownLeft(t, map[string]time.Duration{
		"musixmatch": time.Hour,
		"qq":         15 * time.Second,
		"kugou":      lyricsFillSkippedRetryInterval,
		"lrclib":     lyricsFillSkippedRetryInterval + time.Second,
	})
	got := lyricSourcesSkippedForRetry([]string{"kugou", "lrclib", "musixmatch", "netease", "qq"})
	if want := []string{"kugou", "netease", "qq"}; !slices.Equal(got, want) {
		t.Errorf("剩余冷却超过补搜等待的不留,其余照留(含已经不冷却的):got %v want %v", got, want)
	}
	if got := lyricSourcesSkippedForRetry([]string{"musixmatch"}); got != nil {
		t.Errorf("只剩长冷却的源:名单为空(nil,落盘时省掉这个键),got %#v", got)
	}
	if got := lyricSourcesSkippedForRetry(nil); got != nil {
		t.Errorf("没有跳过的源:got %#v", got)
	}
}

// 补空、重新打分两处写入:条目只记很快会恢复的源,决策记录照记这一轮跳过的全部。首次解析那一处见
// TestFirstResolveRecordsSkippedForRetry。
func TestSkippedSourcesForRetryAtEveryWrite(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, func(ctx context.Context) {
		round := lyricSourceRoundFrom(ctx)
		round.markSkipped("lrclib")
		round.markSkipped("qq")
	})
	stubLyricSourceCooldownLeft(t, map[string]time.Duration{"lrclib": time.Hour, "qq": 20 * time.Second})
	all, forRetry := []string{"lrclib", "qq"}, []string{"qq"}
	check := func(name string, e enrichEntry) {
		t.Helper()
		if !slices.Equal(e.LyricsSourcesSkipped, forRetry) {
			t.Errorf("%s:条目的跳过名单 %v,want %v", name, e.LyricsSourcesSkipped, forRetry)
		}
		if e.LyricsDecision == nil || !slices.Equal(e.LyricsDecision.SourcesSkipped, all) {
			t.Errorf("%s:决策记录的跳过名单要记全部 %v,got %+v", name, all, e.LyricsDecision)
		}
	}

	const artist = rescoreTestArtist
	fillKey, rescoreKey := enrichKey(artist, "Fill Song", ""), enrichKey(artist, "Rescored Song", "")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{
		fillKey: {},
		rescoreKey: {Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "musixmatch",
			LyricsScoringVersion: lyricsScoringVersion - 1},
	}
	enrichMu.Unlock()
	retryLyricsUpgrade(context.Background(), fillKey, artist, "Fill Song", "", 180, true)
	deferred := rescoreLyrics(context.Background(), rescoreKey, artist, "Rescored Song", "", 180)

	enrichMu.Lock()
	filled, rescored := enrichCache[fillKey], enrichCache[rescoreKey]
	enrichMu.Unlock()
	check("补空", filled)
	check("重新打分", rescored)
	if !deferred || rescored.LyricsScoringVersion == lyricsScoringVersion {
		t.Error("重新打分:长冷却的源被跳过,这一轮照旧不算完整(deferred、不追平打分版本)")
	}
}

// 首次解析(lyricsEntryFromScored)写条目和决策记录的那两行。按源码核对,不直接调它:它的参数表常随先上屏那套改动变。
func TestFirstResolveRecordsSkippedForRetry(t *testing.T) {
	src := string(mustRead(t, "provisionallyrics.go"))
	for _, n := range []string{
		"e.LyricsSourcesSkipped = lyricSourcesSkippedForRetry(skipped)",
		"e.LyricsDecision.SourcesSkipped = skipped\n",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("provisionallyrics.go 少了 %q", n)
		}
	}
}
