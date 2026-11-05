package main

import (
	"context"
	"os"
	"testing"
	"time"
)

func withCleanPlaybackHints(t *testing.T) {
	t.Helper()
	playbackTrackIDMu.Lock()
	saved := playbackTrackIDHints
	playbackTrackIDHints = map[string]playbackTrackIDs{}
	playbackTrackIDMu.Unlock()
	t.Cleanup(func() {
		playbackTrackIDMu.Lock()
		playbackTrackIDHints = saved
		playbackTrackIDMu.Unlock()
	})
}

func withAppleNoVocalsWait(t *testing.T, wait time.Duration) {
	t.Helper()
	savedWait, savedPoll := appleNoVocalsAnchorWait, appleNoVocalsPoll
	appleNoVocalsAnchorWait, appleNoVocalsPoll = wait, 5*time.Millisecond
	t.Cleanup(func() { appleNoVocalsAnchorWait, appleNoVocalsPoll = savedWait, savedPoll })
}

// 目录 id 开搜时还没有、等一会儿才核对完:等到它;立不起锚点(没报专辑名)的不等;等满上限还没有就放弃。
func TestWaitPlayingAppleCatalogID(t *testing.T) {
	withCleanPlaybackHints(t)
	withAppleNoVocalsWait(t, 2*time.Second)
	const artist, title, album = "Royal Scottish National Orchestra & Georg Tintner", "Symphony No. 3 in D Minor, WAB 103: II. Adagio. Feirelich", "Bruckner: Symphony No. 3, WAB 103"
	go func() {
		time.Sleep(30 * time.Millisecond)
		notePlayingAppleCatalogID(artist, title, album, 19613387)
	}()
	if got := waitPlayingAppleCatalogID(context.Background(), artist, title, album); got != "19613387" {
		t.Fatalf("等到的目录 id = %q", got)
	}
	start := time.Now()
	if got := waitPlayingAppleCatalogID(context.Background(), artist, "别的曲目", ""); got != "" || time.Since(start) > time.Second {
		t.Errorf("没报专辑名立不起锚点,应立刻返回空:%q,用时 %v", got, time.Since(start))
	}
	withAppleNoVocalsWait(t, 30*time.Millisecond)
	if got := waitPlayingAppleCatalogID(context.Background(), artist, "还没核对的曲目", album); got != "" {
		t.Errorf("等满上限还没有应返回空:%q", got)
	}
}

// 开播命中缓存:没词、没标纯音乐、用 Apple Music 放、目录 id 已有,问一次;每首每次启动只问一次。
func TestAppleNoVocalsFillDue(t *testing.T) {
	withCleanPlaybackHints(t)
	withFeatures(t, featureFlags{LyricsSources: map[string]bool{"applemusic": true, "qq": true}})
	enrichMu.Lock()
	savedTried := appleNoVocalsTried
	appleNoVocalsTried = map[string]bool{}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		appleNoVocalsTried = savedTried
		enrichMu.Unlock()
	})
	const artist, album = "某乐团", "某专辑"
	notePlayingAppleCatalogID(artist, "I. Allegretto", album, 1464784738)
	due := func(e enrichEntry, key, bundle, title string) bool {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return appleNoVocalsFillDue(e, key, bundle, artist, title, album)
	}
	if due(enrichEntry{}, "k1", spotifyBundleID, "I. Allegretto") {
		t.Error("别的播放器在放不问")
	}
	if due(enrichEntry{}, "k2", appleMusicBundleID, "没核对的曲目") {
		t.Error("没有目录 id 不问")
	}
	if due(enrichEntry{Lyrics: bt("[00:01.00]词")}, "k3", appleMusicBundleID, "I. Allegretto") {
		t.Error("有词的不问")
	}
	if due(enrichEntry{InstrumentalCleared: true}, "k4", appleMusicBundleID, "I. Allegretto") {
		t.Error("用户撤过纯音乐标记的不问")
	}
	if due(enrichEntry{ManualLyrics: true}, "k5", appleMusicBundleID, "I. Allegretto") {
		t.Error("用户存过歌词的不问")
	}
	if !due(enrichEntry{}, "k6", appleMusicBundleID, "I. Allegretto") {
		t.Fatal("预取存下的没词条目应问一次")
	}
	if due(enrichEntry{}, "k6", appleMusicBundleID, "I. Allegretto") {
		t.Error("同一首这次启动只问一次")
	}
	withFeatures(t, featureFlags{LyricsSources: map[string]bool{"qq": true}})
	if due(enrichEntry{}, "k7", appleMusicBundleID, "I. Allegretto") {
		t.Error("applemusic 源关掉时不问")
	}
}

// 解析那一路在没拿到词时等锚点、开播命中缓存那条分支接在补空后面。源码契约(这两处要全套源和播放状态才搭得起来)。
func TestAppleNoVocalsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, needle := range []string{
		"if appleID == \"\" && !isPlayerQueueTrack(ctx) {\n\t\t\t\tappleID = waitPlayingAppleCatalogID(ctx, idArtist, idTitle, idAlbum)",
		"appleNoVocals = appleID != \"\" && applemusicCatalogNoVocals(ctx, appleID)",
		"} else if !enrichInflight[key] && appleNoVocalsFillDue(e, key, bundleID, artist, title, album) {",
		"go appleNoVocalsFill(withLyricSearchTitle(context.Background(), searchTitle), key, artist, title, album, durationSecs)",
	} {
		if !containsCode(string(data), needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
}
