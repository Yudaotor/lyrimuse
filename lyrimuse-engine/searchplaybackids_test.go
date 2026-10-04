package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// 手动搜索读一次 App 的播放状态:正在放的那首的 Apple 目录 ID(核对通过才记)与 Spotify 曲目 ID 记成播放提示;
// 状态过期、App 没在放时什么都不记;搜索专用的判定不查汽水试听段。
func TestNotePlaybackIDsFromAppState(t *testing.T) {
	playbackTrackIDMu.Lock()
	saved := playbackTrackIDHints
	playbackTrackIDHints = map[string]playbackTrackIDs{}
	playbackTrackIDMu.Unlock()
	t.Cleanup(func() {
		playbackTrackIDMu.Lock()
		playbackTrackIDHints = saved
		playbackTrackIDMu.Unlock()
	})
	reset := func() {
		playbackTrackIDMu.Lock()
		playbackTrackIDHints = map[string]playbackTrackIDs{}
		playbackTrackIDMu.Unlock()
	}
	now := time.Now()
	path := filepath.Join(t.TempDir(), "playback-state.json")
	write := func(rec appStateRecord) {
		b, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	id := int64(535824738)
	j := plainAppJudge()
	j.catalog = func(_ string, trackID int64, _ int, artist, title, album string) (float64, bool) {
		notePlayingAppleCatalogID(artist, title, album, trackID)
		return 0, true
	}

	rec := appSourceRec(os.Getpid(), 1, 1, "Song", now)
	rec.Track.CatalogTrackID, rec.Track.SpotifyTrackID = &id, "0F02KChKwbcQ3tk4q1YxLH"
	write(rec)
	notePlaybackIDsFromAppState(path, now, j)
	if apple, spotify := playbackTrackIDsFor("Singer", "Song", "Album"); apple != "535824738" || spotify != "0F02KChKwbcQ3tk4q1YxLH" {
		t.Errorf("正在放的这首该记下两个 ID: %q %q", apple, spotify)
	}

	reset()
	old := rec
	old.WrittenAtMs = now.Add(-time.Hour).UnixMilli()
	write(old)
	notePlaybackIDsFromAppState(path, now, j)
	if apple, spotify := playbackTrackIDsFor("Singer", "Song", "Album"); apple != "" || spotify != "" {
		t.Errorf("过期的状态不该记: %q %q", apple, spotify)
	}

	reset()
	write(appStateRecord{Schema: 1, AppPID: os.Getpid(), AppStartedAtMs: 1, WrittenAtMs: now.UnixMilli(), State: "idle"})
	notePlaybackIDsFromAppState(path, now, j)
	if apple, spotify := playbackTrackIDsFor("Singer", "Song", "Album"); apple != "" || spotify != "" {
		t.Errorf("没在放时不该记: %q %q", apple, spotify)
	}

	if reflect.ValueOf(searchAppPlaybackJudge().sodaPreview).Pointer() == reflect.ValueOf(liveAppSodaPreview).Pointer() {
		t.Error("搜索用的判定不查汽水试听段")
	}
	if _, _, known, pending := searchAppPlaybackJudge().sodaPreview(sodaMusicBundleID, "Song", "Singer", "Album", 200); known || pending {
		t.Error("搜索用的判定不查汽水试听段")
	}
}

// search-lyrics 开搜之前读一次播放状态,用的是搜索专用的判定。
func TestSearchLyricsNotesPlaybackIDs(t *testing.T) {
	src, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	call := strings.Index(s, "notePlaybackIDsFromAppState(")
	search := strings.Index(s, "scoredLyricCandidatesStreaming(searchCtx")
	if call < 0 || search < 0 || call > search || !strings.Contains(s, "searchAppPlaybackJudge()") {
		t.Error("search-lyrics 要在开搜之前用 searchAppPlaybackJudge 读一次播放状态")
	}
}

// search-lyrics 开搜之前按缓存里存的 YouTube Music 歌曲页给 ctx 挂上 videoId,lyricfind 跟自动解析一样按它取。
func TestSearchLyricsAttachesCachedVideoID(t *testing.T) {
	src, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	attach := strings.Index(s, "searchCtx = withCachedYouTubeMusicVideoIDLocked(searchCtx, enrichKey(*artist, *title, *album))")
	search := strings.Index(s, "scoredLyricCandidatesStreaming(searchCtx")
	if attach < 0 || search < 0 || attach > search {
		t.Error("search-lyrics 要在开搜之前按缓存给 ctx 挂上 videoId")
	}
}
