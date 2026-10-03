package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const appStateFixtureDir = "../shared/testdata/playback-state"

func loadAppStateFixture(t *testing.T, name string) appStateRecord {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(appStateFixtureDir, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	var rec appStateRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}
	return rec
}

func alwaysAlive(int) bool { return true }

// 与 App 的 selftest「playback-state」组跑同一批样例:每份都解得开、字段落到对的位置。
func TestAppStateFixturesDecode(t *testing.T) {
	entries, err := os.ReadDir(appStateFixtureDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) < 10 {
		t.Fatalf("expected at least 10 fixtures, got %d", len(entries))
	}

	playing := loadAppStateFixture(t, "playing-spotify.json")
	at := time.UnixMilli(playing.Position.AtMs)
	s := appStateSnapshot(playing, at.Add(10*time.Second))
	if s.Title != "honeybee" || s.Artist != "Olivia Rodrigo" || s.Bundle != "com.spotify.client" || !s.Playing {
		t.Fatalf("playing snapshot identity wrong: %+v", s)
	}
	if s.Duration != 223.5 || s.Rate != 1 {
		t.Fatalf("playing snapshot duration/rate wrong: %+v", s)
	}
	if d := s.Position - 91.234; d > 0.001 || d < -0.001 {
		t.Fatalf("position should extrapolate 10s from 81.234, got %.3f", s.Position)
	}
	if playing.Artwork == nil || playing.Artwork.PlaySeq != playing.Track.PlaySeq {
		t.Fatalf("artwork should belong to the current play: %+v", playing.Artwork)
	}
	if playing.Track.SpotifyTrackID != "4iJyoBOLtHqaGxP12qzhQI" {
		t.Fatalf("spotify track id should decode, got %q", playing.Track.SpotifyTrackID)
	}
	if playing.Track.AmazonTrackID != "" {
		t.Fatalf("amazon track id is only set for Amazon Music, got %q", playing.Track.AmazonTrackID)
	}

	kaset := loadAppStateFixture(t, "playing-kaset.json")
	if kaset.Track.YouTubeMusicVideoID != "OMOGaugKpzs" || kaset.Player != kasetBundleID {
		t.Fatalf("kaset video id should decode, got %q (%s)", kaset.Track.YouTubeMusicVideoID, kaset.Player)
	}

	amazon := loadAppStateFixture(t, "playing-amazon.json")
	if amazon.Track.AmazonTrackID != "asin://B09GYHYMRR" || amazon.Player != amazonMusicBundleID {
		t.Fatalf("amazon track id should decode, got %q (%s)", amazon.Track.AmazonTrackID, amazon.Player)
	}
	if as := appStateSnapshot(amazon, time.UnixMilli(amazon.Position.AtMs)); as.Title != "Ring Finger" || as.Position != 24.5 {
		t.Fatalf("amazon snapshot wrong: %+v", as)
	}

	paused := loadAppStateFixture(t, "paused-apple-music.json")
	ps := appStateSnapshot(paused, time.UnixMilli(paused.Position.AtMs).Add(time.Minute))
	if ps.Playing || ps.Position != 132.5 {
		t.Fatalf("paused snapshot should stay at 132.5, got playing=%v pos=%.3f", ps.Playing, ps.Position)
	}
	if paused.Track.CatalogTrackID == nil || *paused.Track.CatalogTrackID != 1485220325 ||
		paused.Track.TrackNumber == nil || *paused.Track.TrackNumber != 18 ||
		paused.Track.MediaType != "MRMediaRemoteMediaTypeMusic" {
		t.Fatalf("catalog identifiers not decoded: %+v", paused.Track)
	}

	radio := loadAppStateFixture(t, "radio-talk-break.json")
	if rs := appStateSnapshot(radio, time.UnixMilli(radio.WrittenAtMs)); !rs.Radio {
		t.Fatal("radio fixture should map to Radio=true")
	}
	if radio.Track.Radio == nil || !radio.Track.Radio.TalkBreak || radio.Track.Radio.StationName != "Country Radio" {
		t.Fatalf("radio block not decoded: %+v", radio.Track.Radio)
	}

	mv := loadAppStateFixture(t, "music-video.json")
	if ms := appStateSnapshot(mv, time.UnixMilli(mv.WrittenAtMs)); !ms.NotAudio {
		t.Fatal("music video fixture should map to NotAudio=true")
	} else if ms.Duration <= 0 || ms.lyricsDurationSecs() != 0 {
		// 视频时长照旧是打卡门槛与进度条的分母,只是不交给歌词解析(02 章决策 33、49)。
		t.Fatalf("music video keeps its duration but hides it from lyrics: duration=%v lyrics=%v", ms.Duration, ms.lyricsDurationSecs())
	}

	if ad := loadAppStateFixture(t, "ad.json"); !ad.Track.Ad {
		t.Fatal("ad fixture should carry ad=true")
	}

	kugou := loadAppStateFixture(t, "kugou-artist-fixed.json")
	if kugou.Track.Artist == kugou.Track.Raw.Artist || kugou.Track.AppliedFixRev != 1790000015 {
		t.Fatalf("kugou fixture should carry the corrected artist and the raw one: %+v", kugou.Track)
	}

	idle := loadAppStateFixture(t, "idle.json")
	if idle.hasTrack() || appStateSnapshot(idle, time.Now()).key() != "" {
		t.Fatal("idle fixture should map to nothing playing")
	}

	holding := loadAppStateFixture(t, "holding.json")
	if !holding.Holding || !holding.hasTrack() {
		t.Fatal("holding fixture should keep the track and set holding")
	}

	exiting := loadAppStateFixture(t, "exiting.json")
	if got := appStateUsable(exiting, time.UnixMilli(exiting.WrittenAtMs), alwaysAlive); got != appStateExiting {
		t.Fatalf("exiting fixture: got %s", got)
	}
	future := loadAppStateFixture(t, "future-schema.json")
	if got := appStateUsable(future, time.UnixMilli(future.WrittenAtMs), alwaysAlive); got != appStateUnsupported {
		t.Fatalf("future schema: got %s", got)
	}
}

func TestAppStateUsable(t *testing.T) {
	rec := appStateRecord{Schema: 1, AppPID: 42, WrittenAtMs: 1_790_000_000_000, State: "playing"}
	written := time.UnixMilli(rec.WrittenAtMs)
	if got := appStateUsable(rec, written.Add(14*time.Second), alwaysAlive); got != appStateAvailable {
		t.Fatalf("fresh record: got %s", got)
	}
	if got := appStateUsable(rec, written.Add(16*time.Second), alwaysAlive); got != appStateStale {
		t.Fatalf("16s old record: got %s", got)
	}
	if got := appStateUsable(rec, written.Add(-2*time.Second), alwaysAlive); got != appStateAvailable {
		t.Fatalf("written 2s ahead of the reader's clock: got %s", got)
	}
	if got := appStateUsable(rec, written.Add(-16*time.Second), alwaysAlive); got != appStateStale {
		t.Fatalf("written 16s in the future (clock set back): got %s", got)
	}
	if got := appStateUsable(rec, written, func(int) bool { return false }); got != appStateProcessGone {
		t.Fatalf("dead writer: got %s", got)
	}
	noPID := rec
	noPID.AppPID = 0
	if got := appStateUsable(noPID, written, alwaysAlive); got != appStateProcessGone {
		t.Fatalf("missing pid: got %s", got)
	}
}

func TestAppStateReaderPrefersNewerInstance(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	write := func(rec appStateRecord) {
		t.Helper()
		data, _ := json.Marshal(rec)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	r := newAppStateReader(path)
	alive := map[int]bool{100: true, 200: true}
	r.alive = func(pid int) bool { return alive[pid] }
	now := time.UnixMilli(1_790_000_010_000)

	if _, got := r.read(now); got != appStateMissing {
		t.Fatalf("no file yet: got %s", got)
	}
	newer := appStateRecord{Schema: 1, AppPID: 200, AppStartedAtMs: 1_790_000_005_000, Seq: 1, WrittenAtMs: 1_790_000_009_000, State: "idle"}
	write(newer)
	if rec, got := r.read(now); got != appStateAvailable || rec.AppPID != 200 {
		t.Fatalf("newer instance: got %s pid=%d", got, rec.AppPID)
	}
	older := appStateRecord{Schema: 1, AppPID: 100, AppStartedAtMs: 1_790_000_000_000, Seq: 9, WrittenAtMs: 1_790_000_009_500, State: "exiting"}
	time.Sleep(10 * time.Millisecond)
	write(older)
	if rec, got := r.read(now); got != appStateAvailable || rec.AppPID != 200 {
		t.Fatalf("an older instance's write must not replace the newer one: got %s pid=%d", got, rec.AppPID)
	}
	if !appStateSuperseded(newer, older, r.alive) {
		t.Fatal("older instance should be superseded while the newer one is alive")
	}
	alive[200] = false
	if appStateSuperseded(newer, older, r.alive) {
		t.Fatal("once the newer instance is gone the older one is no longer superseded")
	}

	if err := os.WriteFile(path, []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, got := r.read(now); got != appStateUnreadable {
		t.Fatalf("broken json: got %s", got)
	}
}

func TestAppStateSnapshotClampsToDuration(t *testing.T) {
	d := 100.0
	rec := appStateRecord{
		Schema: 1, AppPID: 1, State: "playing", Player: "com.apple.Music",
		Track:    &appStateTrack{Title: "A", Artist: "B", DurationSecs: &d},
		Position: &appStatePosition{Secs: 95, AtMs: 1_790_000_000_000, Rate: 1},
	}
	s := appStateSnapshot(rec, time.UnixMilli(1_790_000_000_000).Add(30*time.Second))
	if s.Position != 100 {
		t.Fatalf("position should clamp to duration, got %.3f", s.Position)
	}
}
