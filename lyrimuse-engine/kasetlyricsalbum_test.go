package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"strings"
	"testing"
)

func TestLyricsSearchAlbum(t *testing.T) {
	withKasetAudioVideoIDs(t)
	withYTMusicCredits(t, map[string]ytmusicCredit{
		ytmusicCreditKey(ytmusicDisplayLanguage(), "AbCdEfGhIjK"): {artist: "Someone", title: "Song", album: "Listed", durationSecs: 200},
	})
	withVideo := withYouTubeMusicVideoID(context.Background(), "AbCdEfGhIjK")
	for _, c := range []struct {
		name                 string
		ctx                  context.Context
		album, listed        string
		wantSearch, wantUsed string
	}{
		{"播放器报了专辑就用它", withVideo, "Reported", "Stored", "Reported", ""},
		{"没报:用条目里记着的登记专辑", context.Background(), "", "Stored", "Stored", "Stored"},
		{"条目里没记着:按 videoId 现判", withVideo, "", "", "Listed", "Listed"},
		{"没有 videoId 也没记着", context.Background(), "", "", "", ""},
	} {
		search, used := lyricsSearchAlbum(c.ctx, c.album, c.listed, 200, "Someone", "Song")
		if search != c.wantSearch || used != c.wantUsed {
			t.Errorf("%s: got (%q, %q), want (%q, %q)", c.name, search, used, c.wantSearch, c.wantUsed)
		}
	}
}

func TestListedAlbumLyricsWorthRecheck(t *testing.T) {
	entry := func(edit func(*enrichEntry)) enrichEntry {
		e := enrichEntry{Lyrics: "[00:01.00]hi", LyricsSource: "qq", YouTubeMusicAlbum: "Listed"}
		if edit != nil {
			edit(&e)
		}
		return e
	}
	if !listedAlbumLyricsWorthRecheck(entry(nil), "", false, true) {
		t.Error("登记专辑判出来了、这份词没带着它搜过:该重来一次")
	}
	if !listedAlbumLyricsWorthRecheck(entry(func(e *enrichEntry) { e.LyricsListedAlbum = "Old" }), "", false, true) {
		t.Error("上次带的是另一个登记专辑(界面语言换过):该重来一次")
	}
	for _, c := range []struct {
		name                string
		e                   enrichEntry
		album               string
		pinned, autoUpgrade bool
	}{
		{"播放器报了专辑", entry(nil), "Reported", false, true},
		{"登记专辑还没判出来", entry(func(e *enrichEntry) { e.YouTubeMusicAlbum = "" }), "", false, true},
		{"已经带着它搜过", entry(func(e *enrichEntry) { e.LyricsListedAlbum = "Listed" }), "", false, true},
		{"没词(补空那条管)", entry(func(e *enrichEntry) { e.Lyrics, e.LyricsSource = "", "" }), "", false, true},
		{"手改过", entry(func(e *enrichEntry) { e.ManualLyrics = true }), "", false, true},
		{"校准过", entry(nil), "", true, true},
		{"关了自动升级", entry(nil), "", false, false},
	} {
		if listedAlbumLyricsWorthRecheck(c.e, c.album, c.pinned, c.autoUpgrade) {
			t.Errorf("%s:不该重来", c.name)
		}
	}
}

func TestListedAlbumLyricsRecheckOnce(t *testing.T) {
	saved := listedAlbumLyricsRechecked
	listedAlbumLyricsRechecked = map[string]bool{}
	t.Cleanup(func() { listedAlbumLyricsRechecked = saved })
	if !listedAlbumLyricsRecheckOnce("a|t|") || listedAlbumLyricsRecheckOnce("a|t|") {
		t.Error("同一条这次进程里只重来一次")
	}
	if !listedAlbumLyricsRecheckOnce("b|t|") {
		t.Error("别的条目不受影响")
	}
}

// 升级重试 / 补空 / 重打分:播放器没报专辑时拿条目里的登记专辑去搜、去打分,决策记录和 LyricsListedAlbum 记下,缓存 key 不变。
func TestLyricsRetriesSearchWithListedAlbum(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		lyricSourceRoundFrom(ctx).markReached("musixmatch")
		return musixmatchResult{lrc: rescoreTestNewBody, title: title, artist: artist, album: "Listed Album", durationSecs: 180}
	}
	const artist = rescoreTestArtist
	listedKey, plainKey := enrichKey(artist, "Listed Song", ""), enrichKey(artist, "Plain Song", "")
	rescoreKey := enrichKey(artist, "Rescored Song", "")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{
		listedKey: {YouTubeMusicAlbum: "Listed Album"},
		plainKey:  {},
		rescoreKey: {Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "musixmatch",
			LyricsScoringVersion: lyricsScoringVersion - 1, YouTubeMusicAlbum: "Listed Album"},
	}
	enrichMu.Unlock()
	retryLyricsUpgrade(context.Background(), listedKey, artist, "Listed Song", "", 180, true)
	retryLyricsUpgrade(context.Background(), plainKey, artist, "Plain Song", "", 180, true)
	rescoreLyrics(context.Background(), rescoreKey, artist, "Rescored Song", "", 180)

	enrichMu.Lock()
	listed, plain, rescored := enrichCache[listedKey], enrichCache[plainKey], enrichCache[rescoreKey]
	_, albumKeyed := enrichCache[enrichKey(artist, "Listed Song", "Listed Album")]
	enrichMu.Unlock()
	if listed.LyricsDecision == nil || listed.LyricsDecision.QueryAlbum != "Listed Album" || listed.LyricsListedAlbum != "Listed Album" {
		t.Fatalf("没报专辑:拿登记专辑去搜,决策记录和条目都要记下: decision=%+v listed=%q", listed.LyricsDecision, listed.LyricsListedAlbum)
	}
	if plain.LyricsDecision == nil || plain.LyricsDecision.QueryAlbum != "" || plain.LyricsListedAlbum != "" {
		t.Fatalf("没有登记专辑就照旧不带专辑: decision=%+v listed=%q", plain.LyricsDecision, plain.LyricsListedAlbum)
	}
	if listed.Lyrics == "" || listed.LyricsScore <= plain.LyricsScore {
		t.Errorf("登记专辑要进打分(专辑对得上的候选加分): with=%d without=%d", listed.LyricsScore, plain.LyricsScore)
	}
	if rescored.LyricsDecision == nil || rescored.LyricsDecision.QueryAlbum != "Listed Album" || rescored.LyricsListedAlbum != "Listed Album" {
		t.Errorf("重打分同样带登记专辑: decision=%+v listed=%q", rescored.LyricsDecision, rescored.LyricsListedAlbum)
	}
	if albumKeyed {
		t.Error("登记专辑不进缓存 key")
	}
}

func TestAdoptBackfilledLyricsKeepsListedAlbum(t *testing.T) {
	var e enrichEntry
	fresh := enrichEntry{Lyrics: "[00:01.00]hi", LyricsSource: "qq", LyricsListedAlbum: "Listed"}
	if !adoptBackfilledLyrics(&e, fresh) || e.LyricsListedAlbum != "Listed" {
		t.Errorf("收下的词是带着哪个登记专辑搜的要一起收: %q", e.LyricsListedAlbum)
	}
}

// 决策日志的 playing:拿登记专辑搜的那首,查询专辑跟在播那首 key 里的(空)专辑对不上,照样算在播。
func TestLyricsDecisionLogPlayingWithListedAlbum(t *testing.T) {
	saved := enrichPlayingKey.Load()
	t.Cleanup(func() { enrichPlayingKey.Store(saved) })
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	scored := []scoredLyricCandidateResult{{Source: "qq", Score: 900}}
	noteEnrichPlayingKey(enrichKey("a", "t", ""))
	buildLyricsDecision(lyricsDecisionPathRescore, "a", "t", "Listed", 0, scored, &scored[0], false)
	if !strings.Contains(buf.String(), "path=rescore playing=true") {
		t.Errorf("在播那首的重新打分要落 Info 并标 playing=true: %q", buf.String())
	}
}

// 接线守卫:首次解析带登记专辑搜(它没有缓存 key,按 ctx 上的 videoId 现判),播放时登记专辑判出来后重来一次。
func TestListedAlbumLyricsSearchIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, want := range []string{
		"\tsearchAlbum, listedAlbum := lyricsSearchAlbum(ctx, album, \"\", durationSecs, artist, title)\n",
		"\tne, scored = scoredLyricCandidates(roundCtx, artist, title, searchAlbum, durationSecs)\n",
		"\te.LyricsListedAlbum = listedAlbum\n",
		"} else if listedAlbumLyricsWorthRecheck(e, album, pinned, features().LyricsAutoUpgrade) &&\n" +
			"\t\t\t!enrichInflight[key] && listedAlbumLyricsRecheckOnce(key) {",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("enrich.go 缺 %q", want)
		}
	}
}
