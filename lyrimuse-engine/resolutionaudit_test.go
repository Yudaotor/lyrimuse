package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// 熔断器记的时刻只留墙钟:睡眠时单调时钟不走,暂停两小时的源醒来还要再停近两小时。
func TestLyricSourceBreakerUsesWallClock(t *testing.T) {
	b := newLyricSourceBreaker(time.Now)
	if now := b.now(); strings.Contains(now.String(), "m=") {
		t.Errorf("熔断器的时刻带着单调读数: %v", now)
	}
}

// 后台重搜不在播的那首时,不拿这次播放记下的播放器 ID(同名的另一段录音会撞上同一条提示)。
func TestPlaybackTrackIDsSkippedForOtherTrackRounds(t *testing.T) {
	saved := playbackTrackIDHints
	t.Cleanup(func() {
		playbackTrackIDMu.Lock()
		playbackTrackIDHints = saved
		playbackTrackIDMu.Unlock()
	})
	playbackTrackIDMu.Lock()
	playbackTrackIDHints = map[string]playbackTrackIDs{}
	playbackTrackIDMu.Unlock()
	notePlayingSpotifyTrackID("Singer", "Song", "Album", "4uLU6hMCjMI75M1A2tKUQC")
	if _, id := playbackTrackIDsForRound(context.Background(), "Singer", "Song", "Album"); id != "4uLU6hMCjMI75M1A2tKUQC" {
		t.Fatalf("正在播那一轮照拿: %q", id)
	}
	if a, id := playbackTrackIDsForRound(withOtherTrackRound(context.Background()), "Singer", "Song", "Album"); a != "" || id != "" {
		t.Errorf("别的歌那一轮不拿: %q %q", a, id)
	}
	if code := playbackISRCForRound(withOtherTrackRound(context.Background()), "Singer", "Song", "Album"); code != "" {
		t.Errorf("别的歌那一轮不拿播放器给的 ISRC: %q", code)
	}
}

// 「covered by」按词认:Rediscovered By You 不是翻唱。
func TestTitleMarkedCoverWholeWords(t *testing.T) {
	for title, want := range map[string]bool{
		"Song (Covered by Someone)": true,
		"Rediscovered By You":       false,
		"Recovered by Morning":      false,
	} {
		if got := titleMarkedCover(title); got != want {
			t.Errorf("titleMarkedCover(%q) = %v, want %v", title, got, want)
		}
	}
}

// 跨专辑复用不搬标了纯音乐的兄弟的词。
func TestCrossAlbumSiblingSkipsInstrumental(t *testing.T) {
	lyrics := bt("[00:01.00]第一句\n[00:05.00]第二句\n")
	self := enrichEntry{DurationSecs: 240, LyricsScore: 100}
	sib := enrichEntry{Lyrics: lyrics, DurationSecs: 240.5, LyricsScore: 900, LyricsSource: "qq"}
	sib.stampLyricsScoring()
	self.stampLyricsScoring()
	cache := map[string]enrichEntry{"Singer|Song|Single": sib}
	if got := crossAlbumSiblingLyrics(cache, "Singer|Song|Album", self); got != "Singer|Song|Single" {
		t.Fatalf("对照:没标纯音乐的兄弟照搬: %q", got)
	}
	sib.Instrumental = true
	cache["Singer|Song|Single"] = sib
	if got := crossAlbumSiblingLyrics(cache, "Singer|Song|Album", self); got != "" {
		t.Errorf("标了纯音乐的兄弟不搬: %q", got)
	}
}

// 墙钟定时器的 Restart:没收过 C 时也能改到点时刻。
func TestWallTimerRestart(t *testing.T) {
	w := newWallTimer(time.Hour)
	defer w.Stop()
	w.Restart(10 * time.Millisecond)
	select {
	case <-w.C:
	case <-time.After(2 * time.Second):
		t.Fatal("Restart 之后到点没响")
	}
	if !w.Due(time.Now().Add(time.Second)) {
		t.Error("Restart 之后按新的时刻判")
	}
}

// 源码契约:首次解析带上本轮跳过名单、取消的那一轮不进统计;导入一首不跟着进程退出取消;后台要不到 token 不让前台冷却;
// 补封面的重核走后台档;两处写回前核对校准;补空、补封面的定时器按墙钟;正在播的从时长变体挪回基条目。
func TestResolutionAuditContracts(t *testing.T) {
	read := func(name string) string {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	enrich := read("enrich.go")
	for _, c := range []struct{ src, snippet, why string }{
		{enrich, "e.LyricsDecision.statsSkips = round.statsSkips()\n\t\te.LyricsDecision.skipStats = roundCtx.Err() != nil || lyricSourceStatsOff(roundCtx)", "首次解析带本轮跳过名单"},
		{read("lyricsourcestats.go"), "if s == nil || d == nil || d.skipStats || !lyricSourceStatsCountsPath(d.Path) {", "取消的那一轮不进统计"},
		{read("prefetchimport.go"), "roundCtx, round := withLyricSourceRound(withoutLyricSourceStats(context.WithoutCancel(ctx)))", "导入一首不跟着进程退出取消、不进各源近况统计"},
		{read("musixmatch.go"), "} else if ctx.Err() == nil && !isBackgroundOutbound(ctx) {", "后台要不到 token 不让前台冷却"},
		{read("coversweep.go"), "rctx, round := coverSweepNetworkRound(withBackgroundOutbound(ctx))", "补封面重核动态封面走后台档"},
		{read("coversweep.go"), "timer := newWallTimer(coverSweepInitialDelay)", "补封面定时器按墙钟"},
		{read("lyricsfillsweep.go"), "next := newWallTimer(lyricsFillSweepFirstDelay(lyricsFullScanActive()))", "补空定时器按墙钟"},
		{enrich, "if base, variant := durationVariantBaseKey(*cur); variant && base == key {", "正在播的从时长变体挪回基条目"},
		{read("lyricsexport.go"), "func exportLyricsFilesMatching(onlyFolds map[string]bool) {\n\tlyricsExportMu.Lock()\n\tdefer lyricsExportMu.Unlock()", "导出整段串行"},
	} {
		if !containsCode(c.src, c.snippet) {
			t.Error(c.why)
		}
	}
	if n := strings.Count(enrich, "if !opts.manual && lyricsCalibratedLocked(key, pins, pinContent) {"); n != 2 {
		t.Errorf("升级重试、重评两处写回前都核对校准: %d", n)
	}
}
