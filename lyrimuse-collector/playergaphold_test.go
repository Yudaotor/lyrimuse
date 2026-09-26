package main

import (
	"testing"
	"time"
)

func resetPlayerGapHold(t *testing.T) {
	t.Helper()
	gapHoldMu.Lock()
	gapHoldPrev, gapHoldSince = gapHoldLast{}, time.Time{}
	gapHoldMu.Unlock()
	saved := gapHoldPlayerRunning
	gapHoldPlayerRunning = func(string) bool { return true }
	t.Cleanup(func() {
		gapHoldMu.Lock()
		gapHoldPrev, gapHoldSince = gapHoldLast{}, time.Time{}
		gapHoldMu.Unlock()
		gapHoldPlayerRunning = saved
	})
}

func gapState(bundle, title string, playing bool) map[string]any {
	return map[string]any{"bundleIdentifier": bundle, "title": title, "artist": "y", "playing": playing}
}

// KKBOX 切歌时撤掉 Now Playing,焦点落到暂停着的 Apple Music:这几拍报读取失败(当前曲目原样留着),之后照常。
// 窗口从撤会话那一拍算起:collector 5 秒一拍,最后一次看到在放可能早了一拍;实测空档最长 19 秒。
func TestHoldAcrossPlayerGap(t *testing.T) {
	resetPlayerGapHold(t)
	t0 := time.Unix(1_000_000, 0)
	at := func(s float64) time.Time { return t0.Add(time.Duration(s * float64(time.Second))) }
	if _, ok := holdAcrossPlayerGap(gapState(kkboxBundleID, "Song A", true), t0); !ok {
		t.Fatal("在放的 KKBOX 原样交回")
	}
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Old", false), at(7)); ok {
		t.Error("KKBOX 撤会话、落到暂停的 Apple Music(离上一拍 7 秒):该保持")
	}
	if _, ok := holdAcrossPlayerGap(map[string]any{}, at(15)); ok {
		t.Error("谁都没在报:接着保持")
	}
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Old", false), at(26)); ok {
		t.Error("从撤会话那一拍起 19 秒:还在窗口里")
	}
	if got, ok := holdAcrossPlayerGap(gapState(kkboxBundleID, "Song B", true), at(27)); !ok || got["title"] != "Song B" {
		t.Errorf("KKBOX 接上下一首:照常交回,got %v ok=%v", got, ok)
	}

	// 再切一次,这次一直不回来:窗口到了就放行。
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Old", false), at(30)); ok {
		t.Error("第二次撤会话:保持")
	}
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Old", false), at(30+26)); !ok {
		t.Error("超过窗口就当它真的不放了,照常交回 Apple Music")
	}
}

// 暂停着点开一张新专辑:加载那几秒 KKBOX 同样撤会话,也保持(实测焦点先落到暂停的 Apple Music)。
func TestHoldAcrossPlayerGapFromPaused(t *testing.T) {
	resetPlayerGapHold(t)
	t0 := time.Unix(1_000_000, 0)
	if _, ok := holdAcrossPlayerGap(gapState(kkboxBundleID, "Song A", false), t0); !ok {
		t.Fatal("暂停的 KKBOX 原样交回")
	}
	if _, ok := holdAcrossPlayerGap(gapState(kkboxBundleID, "Song A", false), t0.Add(5*time.Second)); !ok {
		t.Fatal("一直暂停着:照常")
	}
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Old", false), t0.Add(9*time.Second)); ok {
		t.Error("暂停着的 KKBOX 撤会话:保持")
	}
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Old", true), t0.Add(12*time.Second)); !ok {
		t.Error("保持中别家开始放:照常切")
	}
}

func TestHoldAcrossPlayerGapSwitchesToAPlayingPlayer(t *testing.T) {
	resetPlayerGapHold(t)
	t0 := time.Unix(1_000_000, 0)
	holdAcrossPlayerGap(gapState(kkboxBundleID, "Song A", true), t0)
	if _, ok := holdAcrossPlayerGap(gapState(appleMusicBundleID, "Other", true), t0.Add(2*time.Second)); !ok {
		t.Error("接手的播放器在放:用户真的换了,照常切")
	}
}

func TestShouldHoldPlayerGap(t *testing.T) {
	t0 := time.Unix(1_000_000, 0)
	at := t0.Add(4 * time.Second)
	kk := gapHoldLast{bundle: kkboxBundleID, track: "y\x00Song A", seenAt: t0}
	running := func() bool { return true }
	cases := []struct {
		name      string
		last      gapHoldLast
		holdSince time.Time
		bundle    string
		track     string
		playing   bool
		running   func() bool
		now       time.Time
		wantHold  bool
	}{
		{"KKBOX 撤会话、落到暂停的别家", kk, time.Time{}, appleMusicBundleID, "z\x00Old", false, running, at, true},
		{"谁都没在报", kk, time.Time{}, "", "\x00", false, running, at, true},
		{"接手的在放", kk, time.Time{}, appleMusicBundleID, "z\x00Old", true, running, at, false},
		{"同一个播放器报同一首暂停是真暂停", kk, time.Time{}, kkboxBundleID, "y\x00Song A", false, running, at, false},
		{"同一个播放器报别的歌暂停:撤会话那一瞬的撕裂快照", kk, time.Time{}, kkboxBundleID, "z\x00Old", false, running, at, true},
		{"离最后一次看到它太久才撤:不算切歌空档", kk, time.Time{}, appleMusicBundleID, "z\x00Old", false, running, t0.Add(9 * time.Second), false},
		{"已经在保持:按保持起点算", kk, t0.Add(5 * time.Second), appleMusicBundleID, "z\x00Old", false, running, t0.Add(29 * time.Second), true},
		{"已经在保持:超过窗口", kk, t0.Add(5 * time.Second), appleMusicBundleID, "z\x00Old", false, running, t0.Add(31 * time.Second), false},
		{"播放器已经退出", kk, time.Time{}, appleMusicBundleID, "z\x00Old", false, func() bool { return false }, at, false},
		{"只对实测会撤会话的播放器生效", gapHoldLast{bundle: kugouMusicBundleID, seenAt: t0}, time.Time{}, appleMusicBundleID, "z\x00Old", false, running, at, false},
		{"之前没有在放的", gapHoldLast{}, time.Time{}, appleMusicBundleID, "z\x00Old", false, running, at, false},
	}
	for _, c := range cases {
		if got := shouldHoldPlayerGap(c.last, c.holdSince, c.bundle, c.track, c.playing, c.running, c.now); got != c.wantHold {
			t.Errorf("%s: got %v want %v", c.name, got, c.wantHold)
		}
	}
}
