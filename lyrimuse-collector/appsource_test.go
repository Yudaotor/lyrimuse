package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func plainAppJudge() appPlaybackJudge {
	return appPlaybackJudge{
		fixedTrack: func(string, string, string, string, float64) (string, string, bool) { return "", "", false },
		fixRev:     func() int64 { return 0 },
		sodaPreview: func(string, string, string, string, float64) (float64, float64, bool, bool) {
			return 0, 0, false, false
		},
		catalog: func(string, int64, int, string, string, string) (float64, bool) { return 0, false },
	}
}

func appSourceRec(pid int, playSeq, anchorSeq int64, title string, at time.Time) appStateRecord {
	d := 200.0
	return appStateRecord{
		Schema: 1, AppPID: pid, AppStartedAtMs: 1, Seq: 1, WrittenAtMs: at.UnixMilli(), State: "playing", Player: "com.apple.Music",
		Track: &appStateTrack{PlaySeq: playSeq, Title: title, Artist: "Singer", Album: "Album",
			Raw: appStateTags{Title: title, Artist: "Singer", Album: "Album"}, DurationSecs: &d},
		Position: &appStatePosition{Secs: 10, AtMs: at.UnixMilli(), Rate: 1, AnchorSeq: anchorSeq},
	}
}

// 契约样例换成的快照:身份、播放器、在播、曲长、外推到此刻的位置、Spotify 曲目 ID;第一份状态算重新对齐。
func TestAppPlaybackTickMapsAppState(t *testing.T) {
	rec := loadAppStateFixture(t, "playing-spotify.json")
	now := time.UnixMilli(rec.Position.AtMs).Add(5 * time.Second)
	tick, marks := appPlaybackTickFor(rec, appPlaybackMarks{}, now, plainAppJudge())
	s := tick.snap
	if !tick.tracked || s.Title != "honeybee" || s.Artist != "Olivia Rodrigo" || s.Bundle != "com.spotify.client" || !s.Playing {
		t.Fatalf("identity / playing wrong: %+v", tick)
	}
	if s.Duration != 223.5 || s.Rate != 1 || s.AnchorTS != now {
		t.Fatalf("duration / rate / anchor wrong: %+v", s)
	}
	if d := s.Position - 86.234; d > 0.001 || d < -0.001 {
		t.Fatalf("position should extrapolate 5s from 81.234, got %.3f", s.Position)
	}
	if tick.spotifyTrackID != "4iJyoBOLtHqaGxP12qzhQI" {
		t.Fatalf("spotify track id should come through, got %q", tick.spotifyTrackID)
	}
	if !tick.reanchor || tick.loopRestart {
		t.Fatalf("first state from a process: reanchor, not a loop restart: %+v", tick)
	}
	if marks.pid != rec.AppPID || marks.playSeq != 3 || marks.anchorSeq != 7 || marks.key != s.key() {
		t.Fatalf("marks wrong: %+v", marks)
	}
	idle := loadAppStateFixture(t, "idle.json")
	idleTick, idleMarks := appPlaybackTickFor(idle, marks, now, plainAppJudge())
	if idleTick.tracked || idleTick.snap.key() != "" {
		t.Fatalf("idle state is not a track: %+v", idleTick)
	}
	if idle.AppPID == rec.AppPID && idleMarks != marks {
		t.Fatalf("idle keeps the marks of the same process: %+v vs %+v", idleMarks, marks)
	}
}

// 署名纠正窗口:collector 刚发布的纠正比 App 套用的新 → 身份用 collector 的结论;App 跟上之后用 App 的。
func TestAppPlaybackTickFixWindow(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	rec := appSourceRec(7, 1, 1, "爱情慢慢来", now)
	rec.Player = kugouMusicBundleID
	rec.Track.Artist, rec.Track.Raw.Artist = "被窝里面心酸", "被窝里面心酸"
	rec.Track.AppliedFixRev = 100
	j := plainAppJudge()
	j.fixedTrack = func(bundle, title, artist, album string, duration float64) (string, string, bool) {
		if bundle == kugouMusicBundleID && title == "爱情慢慢来" {
			return "Stake", title, true
		}
		return "", "", false
	}
	j.fixRev = func() int64 { return 200 }
	tick, _ := appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	if tick.snap.Artist != "Stake" || tick.snap.Title != "爱情慢慢来" {
		t.Fatalf("App behind the published fix: use the collector's verdict, got %+v", tick.snap)
	}
	rec.Track.AppliedFixRev = 200
	rec.Track.Artist = "App 的署名"
	tick, _ = appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	if tick.snap.Artist != "App 的署名" {
		t.Fatalf("App caught up: its identity wins, got %+v", tick.snap)
	}
}

// 汽水试听段:collector 已经查到而 App 还报试听段长度 → 本地换回整首口径;App 已经换过就不动;还在查 → pending。
func TestAppPlaybackTickSodaPreviewWindow(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	rec := appSourceRec(7, 1, 1, "一分之二", now)
	rec.Player = sodaMusicBundleID
	d := 30.001
	rec.Track.DurationSecs = &d
	rec.Position.Secs = 6
	j := plainAppJudge()
	j.sodaPreview = func(bundle, title, artist, album string, duration float64) (float64, float64, bool, bool) {
		return 240, 282.801, true, false
	}
	tick, _ := appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	if tick.snap.Duration != 282.801 || tick.snap.Position != 246 {
		t.Fatalf("preview not yet applied by the App: shift to the full track, got dur=%.3f pos=%.3f", tick.snap.Duration, tick.snap.Position)
	}
	full := 282.801
	rec.Track.DurationSecs = &full
	rec.Position.Secs = 246
	tick, _ = appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	if tick.snap.Duration != 282.801 || tick.snap.Position != 246 {
		t.Fatalf("App already on the full track: leave it, got dur=%.3f pos=%.3f", tick.snap.Duration, tick.snap.Position)
	}
	j.sodaPreview = func(string, string, string, string, float64) (float64, float64, bool, bool) { return 0, 0, false, true }
	tick, _ = appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	if !tick.snap.SodaPreviewPending {
		t.Fatalf("lookup in flight should mark the snapshot pending")
	}
}

// 电台的曲长只认目录(没有就是 0);普通曲目有权威曲长就覆盖,没有照用 App 的。
func TestAppPlaybackTickRadioAndCatalog(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	rec := appSourceRec(7, 1, 1, "Dumb Blonde", now)
	program := 7074.538
	rec.Track.DurationSecs = &program
	rec.Track.Radio = &appStateRadio{StationHash: "abc"}
	tick, _ := appPlaybackTickFor(rec, appPlaybackMarks{}, now, plainAppJudge())
	if !tick.snap.Radio || tick.snap.Duration != 0 {
		t.Fatalf("radio without a catalog anchor: duration unknown, got %+v", tick.snap)
	}
	id, number := int64(1485220325), 18
	rec.Track.CatalogTrackID, rec.Track.TrackNumber = &id, &number
	var noted []int64
	j := plainAppJudge()
	j.catalog = func(bundle string, trackID int64, trackNumber int, artist, title, album string) (float64, bool) {
		if trackID != id || trackNumber != number || title != "Dumb Blonde" {
			return 0, false
		}
		noted = append(noted, trackID)
		return 150.447, true
	}
	tick, _ = appPlaybackTickFor(rec, appPlaybackMarks{}, now, j)
	if tick.snap.Duration != 150.447 || len(noted) != 1 {
		t.Fatalf("radio with a catalog anchor: catalog duration, got %+v (noted %v)", tick.snap, noted)
	}
	rec.Track.Radio = nil
	song := 201.0
	rec.Track.DurationSecs = &song
	j.catalog = func(string, int64, int, string, string, string) (float64, bool) { return 200.5, true }
	if tick, _ = appPlaybackTickFor(rec, appPlaybackMarks{}, now, j); tick.snap.Duration != 200.5 {
		t.Fatalf("song with an authoritative catalog duration: override, got %.3f", tick.snap.Duration)
	}
	j.catalog = func(string, int64, int, string, string, string) (float64, bool) { return 0, true }
	if tick, _ = appPlaybackTickFor(rec, appPlaybackMarks{}, now, j); tick.snap.Duration != 201 {
		t.Fatalf("catalog without a duration: keep the App's, got %.3f", tick.snap.Duration)
	}
}

// 起播与重新对齐只在同一个 App 进程里看序号:play_seq 增加且身份不变 = 重新起播;anchor_seq 变了 = 重新对齐;
// 换了进程 = 重新对齐但不算起播;停播之后回到同一首、play_seq 没加 = 都不是。
func TestAppPlaybackTickLoopRestartAndReanchor(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	j := plainAppJudge()
	tick, marks := appPlaybackTickFor(appSourceRec(7, 1, 1, "Song", now), appPlaybackMarks{}, now, j)
	if !tick.reanchor || tick.loopRestart {
		t.Fatalf("first: %+v", tick)
	}
	tick, marks = appPlaybackTickFor(appSourceRec(7, 1, 1, "Song", now), marks, now, j)
	if tick.reanchor || tick.loopRestart {
		t.Fatalf("nothing changed: %+v", tick)
	}
	tick, marks = appPlaybackTickFor(appSourceRec(7, 1, 2, "Song", now), marks, now, j)
	if !tick.reanchor || tick.loopRestart {
		t.Fatalf("anchor_seq moved: reanchor only: %+v", tick)
	}
	tick, marks = appPlaybackTickFor(appSourceRec(7, 2, 3, "Song", now), marks, now, j)
	if !tick.reanchor || !tick.loopRestart {
		t.Fatalf("play_seq moved on the same track: loop restart: %+v", tick)
	}
	idle := appStateRecord{Schema: 1, AppPID: 7, WrittenAtMs: now.UnixMilli(), State: "idle"}
	_, marks = appPlaybackTickFor(idle, marks, now, j)
	tick, marks = appPlaybackTickFor(appSourceRec(7, 2, 3, "Song", now), marks, now, j)
	if tick.loopRestart || tick.reanchor {
		t.Fatalf("back on the same track after idle, play_seq unchanged: neither: %+v", tick)
	}
	tick, marks = appPlaybackTickFor(appSourceRec(7, 3, 4, "Other", now), marks, now, j)
	if tick.loopRestart {
		t.Fatalf("a different track is a new track, not a loop restart: %+v", tick)
	}
	tick, _ = appPlaybackTickFor(appSourceRec(8, 5, 1, "Other", now), marks, now, j)
	if !tick.reanchor || tick.loopRestart {
		t.Fatalf("App restarted (new pid, its own counters): reanchor, not a loop restart even with a higher play_seq: %+v", tick)
	}
}

// App 判成广告的那一首,isAdBreak 也认;换了一首 / 清掉之后不再认。
func TestAppReportedAdJoinsIsAdBreak(t *testing.T) {
	t.Cleanup(func() { noteAppReportedAd(snapshot{}, false) })
	ad := snapshot{Title: "Advertisement", Artist: "Brand", Album: "Promo", Bundle: kkboxBundleID}
	noteAppReportedAd(ad, true)
	if !isAdBreak(ad.Bundle, ad.Artist, ad.Title, ad.Album) {
		t.Fatal("the App's ad verdict should count")
	}
	if isAdBreak(ad.Bundle, ad.Artist, "Another song", ad.Album) {
		t.Fatal("only the track the App flagged")
	}
	noteAppReportedAd(ad, false)
	if isAdBreak(ad.Bundle, ad.Artist, ad.Title, ad.Album) {
		t.Fatal("cleared once the App says it is not an ad")
	}
}

// App 没在放:沿用停播确认,三拍且满 nullClearMinWait 才清空 p.cur。
func TestApplyAppPlaybackTickNullStreak(t *testing.T) {
	p := &poller{ctx: context.Background(), cfg: &config{}}
	t0 := time.Unix(1_790_000_000, 0)
	tick, _ := appPlaybackTickFor(appSourceRec(7, 1, 1, "Song", t0), appPlaybackMarks{}, t0, plainAppJudge())
	if re, _ := p.applyAppPlaybackTick(t0, tick); !re || p.cur.Title != "Song" {
		t.Fatalf("tracked tick should land on p.cur: %+v", p.cur)
	}
	p.applyAppPlaybackTick(t0.Add(time.Second), appPlaybackTick{})
	p.applyAppPlaybackTick(t0.Add(2*time.Second), appPlaybackTick{})
	p.applyAppPlaybackTick(t0.Add(3*time.Second), appPlaybackTick{})
	if p.cur.Title != "Song" {
		t.Fatal("three empty ticks within nullClearMinWait keep the track")
	}
	p.applyAppPlaybackTick(t0.Add(time.Second+nullClearMinWait), appPlaybackTick{})
	if p.cur.key() != "" {
		t.Fatalf("enough empty ticks over nullClearMinWait clear it: %+v", p.cur)
	}
}

func writeAppStateFile(t *testing.T, path string, rec appStateRecord) {
	t.Helper()
	b, err := json.Marshal(rec)
	if err != nil {
		t.Fatal(err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

// 设备封面读 App 写的当前封面文件:属于这首、校验和对得上才给;不是这首 / 对不上 / 没登记读取器 → 没有。
func TestAppPlaybackArtwork(t *testing.T) {
	dir := t.TempDir()
	statePath, artPath := filepath.Join(dir, "state.json"), filepath.Join(dir, "artwork")
	art := []byte("fake jpeg bytes")
	sum := sha256.Sum256(art)
	if err := os.WriteFile(artPath, art, 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	rec := appSourceRec(os.Getpid(), 4, 1, "Song", now)
	rec.Artwork = &appStateArtwork{SHA256: hex.EncodeToString(sum[:]), Mime: "image/jpeg", Bytes: len(art), PlaySeq: 4}
	writeAppStateFile(t, statePath, rec)
	setAppPlaybackArtworkSource(nil, "")
	t.Cleanup(func() { setAppPlaybackArtworkSource(nil, "") })
	if _, _, ok := appPlaybackArtwork("com.apple.Music", "Singer", "Song"); ok {
		t.Fatal("no reader registered: no artwork")
	}
	setAppPlaybackArtworkSource(newAppStateReader(statePath), artPath)
	data, mime, ok := appPlaybackArtwork("com.apple.Music", "Singer", "Song")
	if !ok || mime != "image/jpeg" || string(data) != string(art) {
		t.Fatalf("matching track and checksum: got ok=%v mime=%q", ok, mime)
	}
	if _, _, ok := appPlaybackArtwork("com.apple.Music", "Singer", "Other"); ok {
		t.Fatal("another track: no artwork")
	}
	rec.Artwork.PlaySeq = 3
	rec.Seq = 2
	writeAppStateFile(t, statePath, rec)
	if _, _, ok := appPlaybackArtwork("com.apple.Music", "Singer", "Song"); ok {
		t.Fatal("artwork of an earlier play is not this one")
	}
	rec.Artwork.PlaySeq, rec.Artwork.SHA256, rec.Seq = 4, "00", 3
	writeAppStateFile(t, statePath, rec)
	if _, _, ok := appPlaybackArtwork("com.apple.Music", "Singer", "Song"); ok {
		t.Fatal("checksum mismatch: not used")
	}
}

// poller 只读 App 状态:可用就用;不可用就待机 —— 当读空,连着几拍、持续够久才按停播清掉,可用了接上。
// 快速通道只在有新东西时跑一轮。
func TestReadAppPlaybackAndStandby(t *testing.T) {
	t.Cleanup(func() { noteAppReportedAd(snapshot{}, false) })
	path := filepath.Join(t.TempDir(), "state.json")
	writeAppStateFile(t, path, appSourceRec(os.Getpid(), 1, 1, "Song", time.Now()))
	p := &poller{ctx: context.Background(), cfg: &config{}}
	p.app = &appPlayback{reader: newAppStateReader(path), judge: plainAppJudge()}
	if !p.app.changed(time.Now()) {
		t.Fatal("a state nobody has used yet is new")
	}
	if _, re, _ := p.readAppPlayback(); !re || p.cur.Title != "Song" || p.app.path != "app" {
		t.Fatalf("usable App state should be used: re=%v cur=%+v path=%q", re, p.cur, p.app.path)
	}
	if p.app.changed(time.Now()) {
		t.Fatal("nothing new since the last tick")
	}
	rec := appSourceRec(os.Getpid(), 1, 1, "Song", time.Now())
	rec.Seq = 2
	writeAppStateFile(t, path, rec)
	if !p.app.changed(time.Now()) {
		t.Fatal("a rewrite (heartbeat or change) is new")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if !p.app.changed(time.Now()) {
		t.Fatal("availability changed: the fast path runs a tick")
	}
	if _, re, loop := p.readAppPlayback(); re || loop || p.cur.Title != "Song" || p.app.path != "standby:missing" {
		t.Fatalf("first standby tick keeps the track: re=%v loop=%v cur=%+v path=%q", re, loop, p.cur, p.app.path)
	}
	p.readAppPlayback()
	p.readAppPlayback()
	if p.cur.Title != "Song" {
		t.Fatal("three empty ticks inside nullClearMinWait still keep the track")
	}
	p.nullSince = time.Now().Add(-nullClearMinWait)
	p.readAppPlayback()
	if p.cur.key() != "" {
		t.Fatalf("standby long enough: stopped, got %+v", p.cur)
	}
	writeAppStateFile(t, path, appSourceRec(os.Getpid(), 1, 1, "Song", time.Now()))
	if _, _, _ = p.readAppPlayback(); p.cur.Title != "Song" || p.app.path != "app" || p.nullStreak != 0 {
		t.Fatalf("App state usable again: picked up, cur=%+v path=%q streak=%d", p.cur, p.app.path, p.nullStreak)
	}
	var nilApp *appPlayback
	if nilApp.changed(time.Now()) {
		t.Fatal("no App source: nothing to watch")
	}
}
