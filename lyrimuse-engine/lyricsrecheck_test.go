package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"strings"
	"testing"
)

// 每张「只来一次」的记录表换成这个用例自己的空表,结束还原。
func withEmptyRecheckRecords(t *testing.T) {
	t.Helper()
	savedListed, savedKKBOX, savedAmazon := listedAlbumLyricsRechecked, kkboxLyricsRechecked, amazonLyricsRechecked
	savedSpotify, savedKaset := spotifyLyricsRechecked, kasetLyricsRechecked
	listedAlbumLyricsRechecked, kkboxLyricsRechecked, amazonLyricsRechecked = map[string]bool{}, map[string]bool{}, map[string]bool{}
	spotifyLyricsRechecked, kasetLyricsRechecked = map[string]bool{}, map[string]bool{}
	t.Cleanup(func() {
		listedAlbumLyricsRechecked, kkboxLyricsRechecked, amazonLyricsRechecked = savedListed, savedKKBOX, savedAmazon
		spotifyLyricsRechecked, kasetLyricsRechecked = savedSpotify, savedKaset
	})
}

// Kaset 放的这首:登记专辑刚判出来、自家源也还没按 videoId 问过,两个理由同一拍成立 —— 起一轮就都算用过,
// 下一拍不再为另一个理由起第二轮。
func TestLyricsRecheckOneRoundCoversEveryReason(t *testing.T) {
	withEmptyRecheckRecords(t)
	withKasetAudioVideoIDs(t)
	saved, savedNative := features(), nativeLyricSources
	t.Cleanup(func() { setFeatures(saved); nativeLyricSources = savedNative })
	featuresRef().LyricsSources = map[string]bool{"qq": true, "lyricfind": true}
	featuresRef().LyricsAutoUpgrade = true
	setNativeLyricSourcesForPlayer(kasetBundleID)
	const key = "a|t|"
	e := enrichEntry{Lyrics: "[00:01.00]hi", LyricsSource: "qq", YouTubeMusicAlbum: "Listed",
		LyricsSourcesSeen: []string{"qq"}, LyricsSourcesResponded: []string{"qq", "lyricfind"}}
	scene := lyricsRecheckScene{bundleID: kasetBundleID, kasetVideoID: "Song0000001"}

	r := lyricsRecheckForLocked(key, e, scene)
	if !r.due() || r.String() != "listed-album,kaset" {
		t.Fatalf("两个理由都成立: %+v (%q)", r, r.String())
	}
	r.consumeLocked(key)
	if again := lyricsRecheckForLocked(key, e, scene); again.due() {
		t.Errorf("这一轮已经把两个理由都带上了,下一拍不该再起一轮: %+v", again)
	}
	if r := lyricsRecheckForLocked("b|t|", e, scene); r.String() != "listed-album,kaset" {
		t.Errorf("别的条目不受影响: %q", r.String())
	}
}

// 只记这一拍成立的理由:MV 还没配上音轨版本时自家源那个理由不成立,不跟着登记专辑那一轮记成用过;配上之后照常来。
func TestLyricsRecheckKeepsReasonsThatDidNotHoldYet(t *testing.T) {
	withEmptyRecheckRecords(t)
	withKasetAudioVideoIDs(t)
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"qq": true, "lyricfind": true}
	featuresRef().LyricsAutoUpgrade = true
	const key = "a|mv|"
	e := enrichEntry{Lyrics: "[00:01.00]hi", LyricsSource: "qq", YouTubeMusicAlbum: "Listed", YouTubeMusicMV: true,
		LyricsSourcesSeen: []string{"qq"}, LyricsSourcesResponded: []string{"qq", "lyricfind"}}
	scene := lyricsRecheckScene{bundleID: kasetBundleID, kasetVideoID: "Mv000000001"}

	r := lyricsRecheckForLocked(key, e, scene)
	if r.String() != "listed-album" {
		t.Fatalf("MV 还没配上音轨版本,只有登记专辑那个理由: %q", r.String())
	}
	r.consumeLocked(key)
	// 那一轮按 MV 自己问了自家源,带着登记专辑搜过。
	e.LyricsListedAlbum, e.LyricsNativeVideoID = "Listed", "Mv000000001"
	noteKasetAudioVideoIDs(map[string]string{"Mv000000001": "Audio000001"})
	if r := lyricsRecheckForLocked(key, e, scene); r.String() != "kaset" {
		t.Errorf("配上音轨版本之后自家源那个理由照常来: %q", r.String())
	}
}

// 走真实的 retryLyricsUpgrade:一轮评过之后条件原样成立(这里是时长对不上,换不掉),接下来几拍也不再连着重搜。
// 起的那一轮把理由记进决策日志那一行。
func TestLyricsRecheckDoesNotRepeatAnIdenticalRound(t *testing.T) {
	withEmptyRecheckRecords(t)
	var fetches int
	setupRescoreTest(t, []string{"musixmatch"}, func(ctx context.Context) {
		fetches++
		lyricSourceRoundFrom(ctx).markReached("musixmatch")
	})
	const artist, title = rescoreTestArtist, "Recheck Song"
	key := enrichKey(artist, title, "")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: rescoreTestNewBody, LyricsSource: "musixmatch", LyricsScore: 5000, ResolvedDurationSecs: 180,
		LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision,
	}}
	enrichMu.Unlock()
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	scene := lyricsRecheckScene{wrongDuration: true}
	rounds := 0
	for tick := 0; tick < 4; tick++ {
		enrichMu.Lock()
		r := lyricsRecheckForLocked(key, enrichCache[key], scene)
		if r.due() {
			r.consumeLocked(key)
		}
		enrichMu.Unlock()
		if !r.due() {
			continue
		}
		rounds++
		retryLyricsUpgradeWith(context.Background(), key, artist, title, "", 180, false, lyricsRescoreOpts{reasons: r.String()})
	}
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if rounds != 1 || fetches != 1 {
		t.Errorf("一轮评过、输入没变,不该连着再起: rounds=%d fetches=%d", rounds, fetches)
	}
	if e.LyricsRetryCount != 1 || e.LyricsRetryTS == 0 {
		t.Errorf("那一轮照常记账: count=%d ts=%d", e.LyricsRetryCount, e.LyricsRetryTS)
	}
	if !strings.Contains(buf.String(), "path=upgrade") || !strings.Contains(buf.String(), "reasons=retry") {
		t.Errorf("决策日志那一行要带上理由: %q", buf.String())
	}
}

func TestLyricsRescoreOptsLogAttrs(t *testing.T) {
	if got := (lyricsRescoreOpts{}).logAttrs(); got != nil {
		t.Errorf("没有理由就不加字段: %v", got)
	}
	got := lyricsRescoreOpts{reasons: "listed-album,kaset"}.logAttrs()
	if len(got) != 2 || got[0] != "reasons" || got[1] != "listed-album,kaset" {
		t.Errorf("got %v", got)
	}
}

// 接线:trackEnrichment 在 MV 那段把 wrongDuration 定下来之后,把这一拍的现场整份交给 lyricsRecheckForLocked;
// 分支链里只有一个分支为这些理由起一轮,理由跟着进决策日志。各理由不再各占一个分支。
func TestLyricsRecheckWiring(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	for _, want := range []string{
		"\t\t\twrongDuration = true\n\t\t}\n\t\t// 已经有词、值得再全源搜一轮的几个理由",
		"\t\trecheck := lyricsRecheckForLocked(key, e, lyricsRecheckScene{\n" +
			"\t\t\talbum: album, bundleID: bundleID, kasetVideoID: kasetVideoID, pinned: pinned, wrongDuration: wrongDuration,\n" +
			"\t\t\tkkboxLyrics: kkboxInfo.lyrics, amazonLyrics: amazonLyricsAvail, spotifyLyrics: spotifyLyricsAvail,\n",
		"} else if recheck.due() && !enrichInflight[key] {",
		"\t\t\trecheck.consumeLocked(key)\n",
		"lyricsRescoreOpts{reasons: recheck.String()})",
		"path, artist, title, searchAlbum, durationSecs, scored, picked, upgraded, opts.logAttrs()...)",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("enrich.go 里要有: %q", want)
		}
	}
	for _, gone := range []string{
		"listedAlbumLyricsRecheckOnce(key)", "kkboxLyricsRecheckOnce(key)", "amazonLyricsRecheckOnce(key)",
		"spotifyLyricsRecheckOnce(key)", "kasetLyricsRecheckOnce(key)", "needsLyricsRetry(e, wrongDuration",
	} {
		if strings.Contains(s, gone) {
			t.Errorf("enrich.go 里不该再单独判: %s", gone)
		}
	}
}
