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

// 解析那一路在没拿到词时等锚点。源码契约(要全套源和播放状态才搭得起来)。
func TestAppleNoVocalsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, needle := range []string{
		"if appleID == \"\" && !isPlayerQueueTrack(ctx) {\n\t\t\t\tappleID = waitPlayingAppleCatalogID(ctx, idArtist, idTitle, idAlbum)",
		"appleNoVocals = appleID != \"\" && applemusicCatalogNoVocals(ctx, appleID)",
	} {
		if !containsCode(string(data), needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
}
