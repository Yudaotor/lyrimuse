package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// 端到端:正在播的那首重打分换了一份不带译文的歌词,当场按新正文机翻,翻完写进单条快照。
// 走真实的 rescoreLyrics;歌词源只开 musixmatch 且换成假的,翻译走假 Google,不连外网。
func TestRescoreSwapRetranslatesPlayingTrackEndToEnd(t *testing.T) {
	setupTranslateStart(t)
	savedPlaying := enrichPlayingKey.Load()
	savedResolve := musixmatchResolve
	savedOnDevice := onDeviceTranslator
	t.Cleanup(func() {
		enrichPlayingKey.Store(savedPlaying)
		musixmatchResolve = savedResolve
		onDeviceTranslator = savedOnDevice
	})
	resetMusixmatchCacheForTest(t)
	featuresRef().LyricsSources = map[string]bool{"musixmatch": true}
	featuresRef().LyricsAutoUpgrade = true
	onDeviceTranslator = func(context.Context, string, []string) ([]string, error) { return nil, errOnDeviceUnavailable }
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		var out []string
		for _, l := range strings.Split(r.PostForm.Get("q"), "\n") {
			out = append(out, fakeTranslated("谷:", l))
		}
		fmt.Fprint(w, googleReply(t, out))
	})
	newBody := "[00:05.00]Brand new first line\n[00:15.00]Brand new second line\n[00:25.00]Brand new third line\n" +
		"[00:35.00]Brand new fourth line\n[00:45.00]Brand new fifth line\n[02:50.00]Brand new last line"
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		return musixmatchResult{lrc: newBody, title: title, artist: artist, durationSecs: 180}
	}

	const artist, title, album = "Someone", "Swap Song", "Some Album"
	key := enrichKey(artist, title, album)
	oldBody := "[00:05.00]Old line one\n[00:15.00]Old line two"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: oldBody, LyricsSource: "qq", LyricsScore: 10, LyricsScoringVersion: lyricsScoringVersion - 1,
		LyricsTr: "[00:05.00]旧译一\n[00:15.00]旧译二", LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN",
	}}
	enrichMu.Unlock()
	noteEnrichPlayingKey(key)

	before := atomic.LoadInt32(&networkAttemptCount)
	rescoreLyrics(context.Background(), key, artist, title, album, 180)
	waitTranslationDone(t, key)

	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.Lyrics != newBody || e.LyricsSource != "musixmatch" {
		t.Fatalf("重打分没换上新正文: source=%q lyrics=%q", e.LyricsSource, e.Lyrics)
	}
	if e.LyricsTrSource != lyricsTrSourceMachine || !strings.Contains(e.LyricsTr, fakeTranslated("谷:", "Brand new first line")) || strings.Contains(e.LyricsTr, "旧译") {
		t.Fatalf("换了正文之后没有当场按新正文重翻: tr_source=%q tr=%q", e.LyricsTrSource, e.LyricsTr)
	}
	b, err := os.ReadFile(playingEntryPath())
	if err != nil || !strings.Contains(string(b), fakeTranslated("谷:", "Brand new first line")) {
		t.Fatalf("新译文没写进单条快照: err=%v", err)
	}
	// 只打了假 Google 那一个本地服务器,没连外网。
	if got := atomic.LoadInt32(&networkAttemptCount) - before; got > 2 {
		t.Errorf("整轮打了 %d 次请求,检索连到了外网", got)
	}
}
