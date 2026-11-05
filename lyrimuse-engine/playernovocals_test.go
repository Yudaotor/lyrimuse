package main

import (
	"context"
	"os"
	"testing"
)

// 能给纯音乐信号的五家各认自家那一路;别的播放器、自家源被关掉时不问。
func TestPlayerNoVocalsSource(t *testing.T) {
	withFeatures(t, featureFlags{LyricsSources: map[string]bool{"netease": true, "qq": true, "soda": true, "applemusic": true}})
	for bundle, want := range map[string]string{
		playerBundleIDs[playerNetease]:   lyricSourceNetease,
		playerBundleIDs[playerQQMusic]:   lyricSourceQQ,
		playerBundleIDs[playerSoda]:      lyricSourceSoda,
		appleMusicBundleID:               lyricSourceAppleMusic,
		spotifyBundleID:                  spotifyLocalLyricsSource,
		"com.github.th-ch.youtube-music": "",
		"":                               "",
	} {
		if got := playerNoVocalsSource(bundle); got != want {
			t.Errorf("playerNoVocalsSource(%q) = %q,want %q", bundle, got, want)
		}
	}
	withFeatures(t, featureFlags{LyricsSources: map[string]bool{"netease": true}})
	if got := playerNoVocalsSource(playerBundleIDs[playerQQMusic]); got != "" {
		t.Errorf("qq 源关掉时不问,got %q", got)
	}
}

// 开播命中缓存:没词、没标纯音乐、能给信号的播放器在放时问一次;Apple Music 要目录 id 到了才问;每首每次启动只问一次。
func TestPlayerNoVocalsFillDue(t *testing.T) {
	withCleanPlaybackHints(t)
	withFeatures(t, featureFlags{LyricsSources: map[string]bool{"applemusic": true, "qq": true}})
	enrichMu.Lock()
	saved := playerNoVocalsTried
	playerNoVocalsTried = map[string]bool{}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		playerNoVocalsTried = saved
		enrichMu.Unlock()
	})
	const artist, album = "某乐团", "某专辑"
	notePlayingAppleCatalogID(artist, "I. Allegretto", album, 1464784738)
	qq := playerBundleIDs[playerQQMusic]
	due := func(e enrichEntry, key, bundle, title string) bool {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return playerNoVocalsFillDue(e, key, bundle, artist, title, album)
	}
	if due(enrichEntry{}, "k1", "com.github.th-ch.youtube-music", "I. Allegretto") {
		t.Error("给不了纯音乐信号的播放器不问")
	}
	if due(enrichEntry{}, "k2", appleMusicBundleID, "没核对的曲目") {
		t.Error("Apple Music 没有目录 id 不问")
	}
	if due(enrichEntry{Lyrics: bt("[00:01.00]词")}, "k3", qq, "某曲") {
		t.Error("有词的不问")
	}
	if due(enrichEntry{InstrumentalCleared: true}, "k4", qq, "某曲") {
		t.Error("用户撤过纯音乐标记的不问")
	}
	if due(enrichEntry{ManualLyrics: true}, "k5", qq, "某曲") {
		t.Error("用户存过歌词的不问")
	}
	if !due(enrichEntry{}, "k6", appleMusicBundleID, "I. Allegretto") {
		t.Error("Apple Music 目录 id 到了应问")
	}
	if !due(enrichEntry{}, "k7", qq, "某曲") {
		t.Fatal("QQ 在放的没词条目应问")
	}
	if due(enrichEntry{}, "k7", qq, "某曲") {
		t.Error("同一首这次启动只问一次")
	}
	if !due(enrichEntry{}, "k8", spotifyBundleID, "某曲") {
		t.Error("Spotify 在放的没词条目应问(读它本机元数据缓存)")
	}
}

// QQ 在放、曲库里还没有这首:按播放列表里这一首认,算本机身份;不在放 QQ 时不认。
func TestQQLocalMatchFallsBackToPlayingList(t *testing.T) {
	resetQQLocalIndex(t, writeTestQQDB(t, qqLocalTestRows))
	resetQQIPadLocalIndex(t, "")
	writeTestQQArchive(t, 0, []testQQSong{
		{title: "上一首", album: "专辑甲", singers: []string{"某歌手"}, duration: 200, mid: "000AAA"},
		{title: "刚点播的纯音乐", album: "专辑乙", singers: []string{"某歌手"}, duration: 180, mid: "001NEWMID"},
	})
	if _, ok := qqLocalMatch(context.Background(), "某歌手", "刚点播的纯音乐", "专辑乙", 180); ok {
		t.Fatal("QQ 没在放时不按播放列表认")
	}
	playingFor(t, playerQQMusic)
	m, ok := qqLocalMatch(context.Background(), "某歌手", "刚点播的纯音乐", "专辑乙", 180)
	if !ok || qqMidFromURL(m.url) != "001NEWMID" || !m.fromLocalLibrary {
		t.Fatalf("QQ 在放时应按播放列表认出这一首:ok=%v %+v", ok, m)
	}
	if _, ok := qqLocalMatch(context.Background(), "某歌手", "刚点播的纯音乐", "专辑乙", 240); ok {
		t.Error("时长对不上不认")
	}
	if _, ok := qqLocalMatch(withOtherTrackRound(context.Background()), "某歌手", "刚点播的纯音乐", "专辑乙", 180); ok {
		t.Error("别的歌那一轮不认")
	}
}

// 开播补问那条分支接在补空后面,只问自家那一路一轮。源码契约(要全套源和播放状态才搭得起来)。
func TestPlayerNoVocalsWired(t *testing.T) {
	for file, needles := range map[string][]string{
		"enrich.go": {
			"} else if !enrichInflight[key] && playerNoVocalsFillDue(e, key, bundleID, artist, title, album) {",
			"go playerNoVocalsFill(withLyricSearchTitle(context.Background(), searchTitle), key, bundleID, artist, title, album, durationSecs)",
		},
		"playernovocals.go": {
			"ctx, cancel := withCancelAfter(withLyricSourceOnly(ctx, []string{src}), playerNoVocalsProbeTimeout)",
			"_, scored := fetchScoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, nil)",
			"return spotifyLocalNoVocals(spotifyTrackIDHintFor(artist, title))",
		},
	} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, needle := range needles {
			if !containsCode(string(data), needle) {
				t.Errorf("%s 缺 %q", file, needle)
			}
		}
	}
}
