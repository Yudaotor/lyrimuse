package main

import (
	"context"
	"testing"
	"time"
)

// focusFallbackStubs 把焦点回退的三个外部依赖换成假的:media-control 报 rawBundle(ok=false 表示子进程失败),
// AppleScript / 直查按 bundle 返回给定 state。返回两个计数器。
func focusFallbackStubs(t *testing.T, rawBundle string, rawOK bool,
	appleScript, probe map[string]map[string]any) (asCalls, probeCalls *int) {
	t.Helper()
	savedRaw, savedAS, savedProbe, savedFeatures := fetchRawNowPlaying, focusFallbackAppleScript, focusFallbackProbe, features()
	focusFallbackMu.Lock()
	savedBundle, savedActive := focusFallbackBundle, focusFallbackActive
	focusFallbackBundle, focusFallbackActive = "", false
	focusFallbackMu.Unlock()
	t.Cleanup(func() {
		fetchRawNowPlaying, focusFallbackAppleScript, focusFallbackProbe = savedRaw, savedAS, savedProbe
		setFeatures(savedFeatures)
		focusFallbackMu.Lock()
		focusFallbackBundle, focusFallbackActive = savedBundle, savedActive
		focusFallbackMu.Unlock()
	})
	var as, pr int
	fetchRawNowPlaying = func(context.Context) (map[string]any, string, bool) {
		if !rawOK {
			return nil, "", false
		}
		return map[string]any{"title": "Some Video", "artist": "Some Channel", "bundleIdentifier": rawBundle}, rawBundle, true
	}
	focusFallbackAppleScript = func(_ context.Context, bundle string) map[string]any {
		as++
		return appleScript[bundle]
	}
	focusFallbackProbe = func(_ context.Context, bundle string) map[string]any {
		pr++
		return probe[bundle]
	}
	return &as, &pr
}

func fallbackTrack(title, bundle string) map[string]any {
	return map[string]any{"title": title, "artist": "A", "album": "B", "playing": true, "bundleIdentifier": bundle}
}

// 网页视频占走「正在播放」时,上一份被接受的是 Apple Music → 直接问它自己,读取路径照常给出这首歌。
func TestFocusFallbackKeepsAcceptedPlayer(t *testing.T) {
	as, _ := focusFallbackStubs(t, "com.google.Chrome", true,
		map[string]map[string]any{appleMusicBundleID: fallbackTrack("Song", appleMusicBundleID)}, nil)
	setFeatures(featureFlags{Players: map[string]bool{playerAuto: true}})
	ctx := context.Background()

	if st, ok := getAutoDetectedState(ctx); !ok || len(st) != 0 || *as != 0 {
		t.Fatalf("从没接受过内置播放器时不该回退: state=%v calls=%d", st, *as)
	}
	noteFocusAccepted(appleMusicBundleID)
	st, ok := getAutoDetectedState(ctx)
	if !ok || st["title"] != "Song" {
		t.Fatalf("焦点被占该回退到 Apple Music: state=%v ok=%v", st, ok)
	}
	// media-control 子进程失败那一拍同样回退。
	fetchRawNowPlaying = func(context.Context) (map[string]any, string, bool) { return nil, "", false }
	if st, ok := getAutoDetectedState(ctx); !ok || st["title"] != "Song" {
		t.Fatalf("media-control 失败时也该回退: state=%v ok=%v", st, ok)
	}
}

// 回退问不到(播放器退出 / 停了)就关掉开关,之后不再为它起子进程。
func TestFocusFallbackTurnsOffWhenPlayerGone(t *testing.T) {
	as, probe := focusFallbackStubs(t, "com.google.Chrome", true, nil, nil)
	setFeatures(featureFlags{Players: map[string]bool{playerAuto: true}})
	noteFocusAccepted(appleMusicBundleID)
	ctx := context.Background()
	if st, ok := getAutoDetectedState(ctx); !ok || len(st) != 0 {
		t.Fatalf("回退问不到该按没人在放处理: state=%v", st)
	}
	if *as != 1 || *probe != 1 {
		t.Fatalf("两级都该问一次: applescript=%d probe=%d", *as, *probe)
	}
	getAutoDetectedState(ctx)
	if *as != 1 || *probe != 1 {
		t.Fatalf("开关关掉之后不该再问: applescript=%d probe=%d", *as, *probe)
	}
}

// 没有 AppleScript 字典的内置播放器走按 bundle id 直查。
func TestFocusFallbackProbeForPlayersWithoutAppleScript(t *testing.T) {
	_, probe := focusFallbackStubs(t, "com.google.Chrome", true, nil,
		map[string]map[string]any{qqMusicBundleID: fallbackTrack("QQ Song", qqMusicBundleID)})
	setFeatures(featureFlags{Players: map[string]bool{playerAuto: true}})
	noteFocusAccepted(qqMusicBundleID)
	if st, ok := getAutoDetectedState(context.Background()); !ok || st["title"] != "QQ Song" || *probe != 1 {
		t.Fatalf("QQ 音乐该走直查: state=%v probe=%d", st, *probe)
	}
}

// 正常路径接受了别的(非内置)播放器就当场关掉开关;多选路径还要核对它仍在勾选之列。
func TestFocusFallbackGates(t *testing.T) {
	as, _ := focusFallbackStubs(t, "com.google.Chrome", true,
		map[string]map[string]any{appleMusicBundleID: fallbackTrack("Song", appleMusicBundleID)}, nil)
	ctx := context.Background()

	setFeatures(featureFlags{Players: map[string]bool{playerAuto: true}})
	noteFocusAccepted(appleMusicBundleID)
	noteFocusAccepted("company.thebrowser.Browser")
	if st, _ := getAutoDetectedState(ctx); len(st) != 0 || *as != 0 {
		t.Fatalf("最后接受的是浏览器,不该回退到 Apple Music: state=%v calls=%d", st, *as)
	}

	setFeatures(featureFlags{Players: map[string]bool{playerQQMusic: true}})
	noteFocusAccepted(appleMusicBundleID)
	if st, _ := getMultiSelectedState(ctx); len(st) != 0 || *as != 0 {
		t.Fatalf("多选里没勾 Apple Music,不该回退到它: state=%v calls=%d", st, *as)
	}
	setFeatures(featureFlags{Players: map[string]bool{playerQQMusic: true, playerAppleMusic: true}})
	if st, _ := getMultiSelectedState(ctx); st["title"] != "Song" {
		t.Fatalf("多选里勾了 Apple Music,该回退: state=%v", st)
	}
}

func TestParseNowPlayingClientState(t *testing.T) {
	if st := parseNowPlayingClientState([]byte("null"), qqMusicBundleID); st != nil {
		t.Fatalf("null 该是 nil: %v", st)
	}
	if st := parseNowPlayingClientState([]byte(`{"title":"","artist":"A"}`), qqMusicBundleID); st != nil {
		t.Fatalf("标题空不算: %v", st)
	}
	st := parseNowPlayingClientState([]byte(
		`{"bundleIdentifier":"com.tencent.QQMusicMac","title":"歌 名","artist":"歌手","album":"专辑","duration":200.5,`+
			`"playbackRate":1,"playing":true,"isMusicApp":true,"anchorElapsedTime":10,"elapsedTime":42.25,"timestamp":1790000000.5}`),
		qqMusicBundleID)
	if st == nil || st["title"] != "歌 名" || st["artist"] != "歌手" || st["album"] != "专辑" ||
		st["duration"] != 200.5 || st["elapsedTime"] != 42.25 || st["anchorElapsedTime"] != 10.0 ||
		st["playing"] != true || st["bundleIdentifier"] != qqMusicBundleID {
		t.Fatalf("字段没对上: %v", st)
	}
	paused := parseNowPlayingClientState([]byte(`{"title":"T","artist":"A","anchorElapsedTime":33,"playing":false}`), qqMusicBundleID)
	if paused == nil || paused["elapsedTime"] != 33.0 {
		t.Fatalf("没有 elapsedTime 时按锚点值: %v", paused)
	}
}

// 这个浏览器里没有 YouTube Music 标签页(NOTFOUND)时,同一个 key 在免探期内不再跑脚本;换曲目、读失败照常探。
func TestYTMusicAdNotFoundSuppressesRetry(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	saved := runYTMusicAdProbe
	clearNotFound := func() {
		ytmusicAdMu.Lock()
		ytmusicAdNotFoundKey, ytmusicAdNotFoundAt = "", time.Time{}
		ytmusicAdMu.Unlock()
	}
	clearNotFound()
	t.Cleanup(func() { runYTMusicAdProbe = saved; clearNotFound() })
	calls := 0
	notFound := true
	runYTMusicAdProbe = func(context.Context, string, string) (ytmusicAdVerdict, string, bool, string) {
		calls++
		return ytmusicAdUnknown, "", notFound, ""
	}
	ctx := context.Background()
	key := "Some Channel\x00Some Video"
	for i := 0; i < 3; i++ {
		if v, _ := ytmusicAdProbe(ctx, "com.google.Chrome", key); v != ytmusicAdUnknown {
			t.Fatalf("NOTFOUND 仍按 unknown 拒: %v", v)
		}
	}
	if calls != 1 {
		t.Fatalf("免探期内同 key 只该探一次, got %d", calls)
	}
	ytmusicAdProbe(ctx, "com.google.Chrome", "Other\x00Video")
	if calls != 2 {
		t.Fatalf("换了曲目该立刻探, got %d", calls)
	}
	ytmusicAdMu.Lock()
	ytmusicAdNotFoundAt = time.Now().Add(-ytmusicAdNotFoundRetry - time.Second)
	ytmusicAdMu.Unlock()
	notFound = false
	ytmusicAdProbe(ctx, "com.google.Chrome", "Other\x00Video")
	ytmusicAdProbe(ctx, "com.google.Chrome", "Other\x00Video")
	if calls != 4 {
		t.Fatalf("到期重探;读失败(不是 NOTFOUND)不记,下一拍照常探, got %d", calls)
	}
	if !ytmusicAdProbeNotFound("\"NOTFOUND\"\n") || ytmusicAdProbeNotFound("0|0|0||") {
		t.Fatal("NOTFOUND 判定不对")
	}
}
