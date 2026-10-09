package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const swapNewBody = "[00:05.00]Brand new first line\n[00:15.00]Brand new second line\n[00:25.00]Brand new third line\n" +
	"[00:35.00]Brand new fourth line\n[00:45.00]Brand new fifth line\n[02:50.00]Brand new last line"

// setupSwapE2E:歌词源只开 musixmatch 且换成假的(回 swapNewBody、不带译文),翻译走假 Google,不连外网。
// 假 Google 每次晚 googleDelay 才回,让「先换正文、再等机翻」那段空档宽到观察得到。
// 返回 Google 被调了几次的计数。条目由调用方写。
func setupSwapE2E(t *testing.T, googleDelay time.Duration) *int32 {
	t.Helper()
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
	googleCalls := new(int32)
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(googleCalls, 1)
		time.Sleep(googleDelay)
		_ = r.ParseForm()
		var out []string
		for _, l := range strings.Split(r.PostForm.Get("q"), "\n") {
			out = append(out, fakeTranslated("谷:", l))
		}
		fmt.Fprint(w, googleReply(t, out))
	})
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		return musixmatchResult{lrc: swapNewBody, title: title, artist: artist, durationSecs: 180}
	}
	return googleCalls
}

const swapArtist, swapTitle, swapAlbum = "Someone", "Swap Song", "Some Album"

// runWatchingForGap 跑 fn,期间每毫秒在锁内看一眼条目:出现过「新正文已经换上、译文还没跟上」就算断档。
// fn 返回后等可能起了的那轮机翻跑完再停表,换完再翻的那条路径也逃不掉。
func runWatchingForGap(t *testing.T, key string, fn func()) (gap bool) {
	t.Helper()
	stop := make(chan struct{})
	done := make(chan bool)
	go func() {
		seen := false
		for {
			enrichMu.Lock()
			e := enrichCache[key]
			enrichMu.Unlock()
			if e.Lyrics == swapNewBody && !strings.Contains(e.LyricsTr, fakeTranslated("谷:", "Brand new first line")) {
				seen = true
			}
			select {
			case <-stop:
				done <- seen
				return
			case <-time.After(time.Millisecond):
			}
		}
	}()
	fn()
	waitTranslationDone(t, key)
	close(stop)
	return <-done
}

// 现在这份带着能用的社区译文,新胜者没有:新正文跟它的机翻同一次换上,中间不出现「有正文没译文」。
func assertSwappedWithTranslation(t *testing.T, key string, gap bool, googleCalls *int32) {
	t.Helper()
	if gap {
		t.Fatal("换正文和译文落地之间出现了断档:新正文已经换上,译文还没跟上")
	}
	if got := atomic.LoadInt32(googleCalls); got != 1 {
		t.Fatalf("新正文只该翻一次,Google 被调了 %d 次", got)
	}
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.Lyrics != swapNewBody || e.LyricsSource != "musixmatch" {
		t.Fatalf("没换上新正文: source=%q lyrics=%q", e.LyricsSource, e.Lyrics)
	}
	if e.LyricsTrSource != lyricsTrSourceMachine || !strings.Contains(e.LyricsTr, fakeTranslated("谷:", "Brand new first line")) || strings.Contains(e.LyricsTr, "旧") {
		t.Fatalf("换上正文的同时没带上新正文的译文: tr_source=%q tr=%q", e.LyricsTrSource, e.LyricsTr)
	}
	if e.LyricsTrLang != "zh-CN" || e.TranslationLang != "zh-CN" || e.TranslationTS != 0 || e.TranslationRetryCount != 0 {
		t.Fatalf("译文的描述字段要跟 backfillTranslation 翻成时一致: lang=%q tlang=%q ts=%d retry=%d",
			e.LyricsTrLang, e.TranslationLang, e.TranslationTS, e.TranslationRetryCount)
	}
	b, err := os.ReadFile(playingEntryPath())
	if err != nil || !strings.Contains(string(b), fakeTranslated("谷:", "Brand new first line")) {
		t.Fatalf("换上的正文和译文没一起写进单条快照: err=%v", err)
	}
}

func TestRescoreSwapCarriesTranslationWithoutGap(t *testing.T) {
	googleCalls := setupSwapE2E(t, 300*time.Millisecond)
	key := enrichKey(swapArtist, swapTitle, swapAlbum)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "qq", LyricsScore: 10,
		LyricsScoringVersion: lyricsScoringVersion - 1,
		LyricsTr:             "[00:05.00]旧译一\n[00:15.00]旧译二", LyricsTrLang: "zh",
	}}
	enrichMu.Unlock()
	noteEnrichPlayingKey(key)

	gap := runWatchingForGap(t, key, func() {
		rescoreLyrics(context.Background(), key, swapArtist, swapTitle, swapAlbum, 180)
	})
	assertSwappedWithTranslation(t, key, gap, googleCalls)
}

func TestUpgradeSwapCarriesTranslationWithoutGap(t *testing.T) {
	googleCalls := setupSwapE2E(t, 300*time.Millisecond)
	key := enrichKey(swapArtist, swapTitle, swapAlbum)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "qq", LyricsScore: 10,
		LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision,
		LyricsTr: "[00:05.00]旧译一\n[00:15.00]旧译二", LyricsTrLang: "zh",
	}}
	enrichMu.Unlock()
	noteEnrichPlayingKey(key)

	gap := runWatchingForGap(t, key, func() {
		retryLyricsUpgrade(context.Background(), key, swapArtist, swapTitle, swapAlbum, 180, false)
	})
	assertSwappedWithTranslation(t, key, gap, googleCalls)
}

// 现在这份本来就没有译文:没有断档可言,照旧换完再由 translateAfterLyricsSwapLocked 补。
func TestSwapWithoutUsableTranslationStillTranslatesAfterwards(t *testing.T) {
	setupSwapE2E(t, 0)
	key := enrichKey(swapArtist, swapTitle, swapAlbum)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "qq", LyricsScore: 10,
		LyricsScoringVersion: lyricsScoringVersion - 1,
	}}
	enrichMu.Unlock()
	noteEnrichPlayingKey(key)

	rescoreLyrics(context.Background(), key, swapArtist, swapTitle, swapAlbum, 180)
	waitTranslationDone(t, key)
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.Lyrics != swapNewBody || !strings.Contains(e.LyricsTr, fakeTranslated("谷:", "Brand new first line")) {
		t.Fatalf("换完之后没补上译文: lyrics=%q tr=%q", e.Lyrics, e.LyricsTr)
	}
}

// 不该预先翻的几种情况:一个请求都不打,返回零值。
func TestPrepareSwapTranslationSkips(t *testing.T) {
	googleCalls := setupSwapE2E(t, 0)
	const key = "Someone|Swap Song|Some Album"
	usable := enrichEntry{Lyrics: "[00:05.00]Old line one", LyricsTr: "[00:05.00]旧译一", LyricsTrLang: "zh"}
	picked := &scoredLyricCandidateResult{}
	picked.Lyrics = swapNewBody
	always := func(enrichEntry) bool { return true }
	cases := []struct {
		name     string
		entry    enrichEntry
		playing  bool
		mt       bool
		picked   *scoredLyricCandidateResult
		willSwap func(enrichEntry) bool
	}{
		{"没在播", usable, false, true, picked, always},
		{"机翻关着", usable, true, false, picked, always},
		{"现在这份没有能用的译文", enrichEntry{Lyrics: "[00:05.00]Old line one"}, true, true, picked, always},
		{"这一轮不换正文", usable, true, true, picked, func(enrichEntry) bool { return false }},
		{"没有胜者", usable, true, true, nil, always},
		{"新胜者自带能用的译文", usable, true, true, func() *scoredLyricCandidateResult {
			p := &scoredLyricCandidateResult{}
			p.Lyrics, p.LyricsTr, p.LyricsTrLang = swapNewBody, "[00:05.00]新译一", "zh"
			return p
		}(), always},
	}
	for _, c := range cases {
		enrichMu.Lock()
		enrichCache = map[string]enrichEntry{key: c.entry}
		enrichMu.Unlock()
		if c.playing {
			noteEnrichPlayingKey(key)
		} else {
			noteEnrichPlayingKey("Someone Else|Other|Other")
		}
		featuresRef().LyricsMachineTranslation = c.mt
		before := atomic.LoadInt32(googleCalls)
		got := prepareSwapTranslation(context.Background(), key, swapArtist, swapTitle, c.picked, c.willSwap)
		if got != (swapTranslation{}) {
			t.Errorf("%s: 不该预先翻,却翻了: %+v", c.name, got)
		}
		if atomic.LoadInt32(googleCalls) != before {
			t.Errorf("%s: 不该打翻译请求", c.name)
		}
	}
}

// 锁外翻好、锁内发现正文又被换过(或已经有能用的译文)时不挂。
func TestSwapTranslationApplyChecksLyrics(t *testing.T) {
	s := swapTranslation{lyrics: swapNewBody, lrc: "[00:05.00]谷:Brand new first line", target: "zh-CN"}
	other := enrichEntry{Lyrics: "[00:05.00]Somebody else"}
	s.applyLocked(&other)
	if other.LyricsTr != "" {
		t.Fatalf("正文对不上还挂了译文: %q", other.LyricsTr)
	}
	has := enrichEntry{Lyrics: swapNewBody, LyricsTr: "[00:05.00]社区译文", LyricsTrLang: "zh"}
	s.applyLocked(&has)
	if has.LyricsTr != "[00:05.00]社区译文" {
		t.Fatalf("已经有能用的译文还被机翻顶掉了: %q", has.LyricsTr)
	}
	fresh := enrichEntry{Lyrics: swapNewBody}
	s.applyLocked(&fresh)
	if fresh.LyricsTr != s.lrc || fresh.LyricsTrSource != lyricsTrSourceMachine {
		t.Fatalf("该挂的没挂上: %+v", fresh)
	}
	(swapTranslation{}).applyLocked(&fresh)
}
