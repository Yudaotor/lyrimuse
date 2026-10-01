package main

import (
	"path/filepath"
	"testing"
	"time"
)

func shadowRec(key string, playSeq int64, pid int, state string, duration float64, now time.Time) appStateRecord {
	d := duration
	return appStateRecord{
		Schema: 1, AppPID: pid, WrittenAtMs: now.UnixMilli(), State: state, Player: "com.apple.Music",
		Track:    &appStateTrack{PlaySeq: playSeq, Title: key, Artist: "Singer", Album: "Album", DurationSecs: &d},
		Position: &appStatePosition{Secs: 0, AtMs: now.UnixMilli(), Rate: 1, AnchorSeq: 1},
	}
}

func newTestShadow(t *testing.T) *shadowCompare {
	t.Helper()
	return newShadowCompare(filepath.Join(t.TempDir(), "shadow.json"), nil, time.Unix(1_790_000_000, 0))
}

// 按 App 状态模拟的会话:累计到门槛(200 秒曲目的一半)记一条,只记一次。
func TestShadowSimulateCountsOneListenAtThreshold(t *testing.T) {
	sc := newTestShadow(t)
	t0 := time.Unix(1_790_000_000, 0)
	var got []*shadowListen
	for i := 0; i <= 25; i++ {
		now := t0.Add(time.Duration(i*5) * time.Second)
		if w := sc.simulate(shadowRec("Song", 1, 7, "playing", 200, now), true, now); w != nil {
			got = append(got, w)
		}
	}
	if len(got) != 1 || got[0].Key != "Song|Singer|Album" || got[0].StartedAt != t0.Unix() {
		t.Fatalf("expected exactly one listen for Song started at t0, got %+v", got)
	}
}

// 同一 App 进程里 play_seq 加一 = 单曲循环,开新会话;换了进程(App 重启)同一首接着算。
func TestShadowSimulateLoopRestartAndAppRestart(t *testing.T) {
	sc := newTestShadow(t)
	t0 := time.Unix(1_790_000_000, 0)
	sc.simulate(shadowRec("Song", 1, 7, "playing", 200, t0), true, t0)
	first := sc.sess
	sc.simulate(shadowRec("Song", 1, 8, "playing", 200, t0.Add(5*time.Second)), true, t0.Add(5*time.Second))
	if sc.sess != first {
		t.Fatal("an App restart (new pid, same song) must continue the session")
	}
	sc.simulate(shadowRec("Song", 2, 8, "playing", 200, t0.Add(10*time.Second)), true, t0.Add(10*time.Second))
	if sc.sess == first {
		t.Fatal("play_seq bump in the same App process must open a new session")
	}
}

// 停播 60 秒内回到同一首续接;超过就是新的一次。
func TestShadowSimulateResumeWithinGrace(t *testing.T) {
	sc := newTestShadow(t)
	t0 := time.Unix(1_790_000_000, 0)
	sc.simulate(shadowRec("Song", 1, 7, "playing", 200, t0), true, t0)
	s := sc.sess
	sc.simulate(appStateRecord{Schema: 1, AppPID: 7, State: "idle"}, true, t0.Add(10*time.Second))
	sc.simulate(shadowRec("Song", 1, 7, "playing", 200, t0.Add(40*time.Second)), true, t0.Add(40*time.Second))
	if sc.sess != s {
		t.Fatal("coming back to the same song within 60s must resume the session")
	}
	sc.simulate(appStateRecord{Schema: 1, AppPID: 7, State: "idle"}, true, t0.Add(50*time.Second))
	sc.simulate(shadowRec("Song", 1, 7, "playing", 200, t0.Add(200*time.Second)), true, t0.Add(200*time.Second))
	if sc.sess == s {
		t.Fatal("after the grace window the same song is a new session")
	}
}

// 广告、holding 期间不计时;广告到门槛也不算一条收听。
func TestShadowSimulateSkipsAdsAndHolding(t *testing.T) {
	sc := newTestShadow(t)
	t0 := time.Unix(1_790_000_000, 0)
	for i := 0; i <= 12; i++ {
		now := t0.Add(time.Duration(i*5) * time.Second)
		rec := shadowRec("Ad", 1, 7, "playing", 30, now)
		rec.Track.Ad = true
		if w := sc.simulate(rec, true, now); w != nil {
			t.Fatalf("an ad must not be counted as a listen: %+v", w)
		}
	}
	sc2 := newTestShadow(t)
	for i := 0; i <= 30; i++ {
		now := t0.Add(time.Duration(i*5) * time.Second)
		rec := shadowRec("Song", 1, 7, "playing", 200, now)
		rec.Holding = true
		sc2.simulate(rec, true, now)
	}
	if sc2.sess.playedSecs != 0 {
		t.Fatalf("holding must not accrue play time, got %.1f", sc2.sess.playedSecs)
	}
}

// 两边读播放器的时刻差一两秒:换歌后 10 秒内的身份不一致算过渡期,之后才算真不一致;署名纠正刚发布、App 还没
// 跟上的也单独记。
func TestShadowObserveSettlingAndFixWindow(t *testing.T) {
	// 版本号是进程级的全局量,别的测试会写署名纠正;这里从 0 起、结束还原。
	playerArtistFixMu.Lock()
	savedRev := playerArtistFixWrittenAt
	playerArtistFixWrittenAt = 0
	playerArtistFixMu.Unlock()
	defer func() {
		playerArtistFixMu.Lock()
		playerArtistFixWrittenAt = savedRev
		playerArtistFixMu.Unlock()
	}()
	dir := t.TempDir()
	sc := newShadowCompare(filepath.Join(dir, "shadow.json"), nil, time.Unix(1_790_000_000, 0))
	t0 := time.Unix(1_790_000_000, 0)
	cur := snapshot{Title: "Song", Artist: "Singer", Album: "Album", Bundle: "com.apple.Music", Playing: true}
	appRec := shadowRec("Other", 1, 7, "playing", 200, t0)

	sc.noteChanges(t0, cur, true, appRec)
	ps := sc.player("com.apple.Music")
	sc.classify(t0.Add(2*time.Second), cur, true, false, appRec, ps)
	if ps.Settling != 1 || ps.IdentityMismatch != 0 {
		t.Fatalf("a mismatch right after a change is settling: %+v", ps)
	}
	sc.classify(t0.Add(20*time.Second), cur, true, false, appRec, ps)
	if ps.IdentityMismatch != 1 {
		t.Fatalf("a persisting mismatch counts: %+v", ps)
	}
	playerArtistFixMu.Lock()
	playerArtistFixWrittenAt = 1_790_000_100
	playerArtistFixMu.Unlock()
	appRec.Track.AppliedFixRev = 1_790_000_050
	sc.classify(t0.Add(40*time.Second), cur, true, false, appRec, ps)
	if ps.FixWindow != 1 || ps.IdentityMismatch != 1 {
		t.Fatalf("App not yet on the latest artist fix counts as the fix window: %+v", ps)
	}
}

// collector 先看到拖动:那一拍 App 还是旧位置,算过渡期;过了窗口还对不上照常计。
func TestShadowCollectorSeekSettles(t *testing.T) {
	sc := newTestShadow(t)
	t0 := time.Unix(1_790_000_000, 0)
	cur := snapshot{Title: "Song", Artist: "Singer", Album: "Album", Bundle: "com.apple.Music", Playing: true,
		Position: 100, AnchorTS: t0, Rate: 1}
	appRec := shadowRec("Song", 1, 7, "playing", 300, t0)
	appRec.Position.Secs = 100
	ps := sc.player("com.apple.Music")

	sc.classify(t0, cur, true, false, appRec, ps)
	sc.classify(t0.Add(20*time.Second), cur, true, false, appRec, ps)
	if ps.Settling != 1 || ps.PositionDelta.Buckets[0] != 1 {
		t.Fatalf("steady ticks compare positions: %+v", ps)
	}
	seekAt := t0.Add(21 * time.Second)
	cur.Position, cur.AnchorTS = 200, seekAt
	sc.classify(seekAt, cur, true, false, appRec, ps)
	if ps.Settling != 2 || ps.PositionDelta.Buckets[6] != 0 {
		t.Fatalf("the tick the collector sees a seek first is settling: %+v", ps)
	}
	sc.classify(seekAt.Add(11*time.Second), cur, true, false, appRec, ps)
	if ps.PositionDelta.Buckets[6] != 1 {
		t.Fatalf("an App that never follows the seek still counts: %+v", ps)
	}
}

func TestShadowMatchListens(t *testing.T) {
	sc := newTestShadow(t)
	t0 := time.Unix(1_790_000_000, 0)
	sc.simulated = []shadowListen{
		{Key: "A|x|y", StartedAt: t0.Unix(), At: t0.Unix()},
		{Key: "B|x|y", StartedAt: t0.Unix(), At: t0.Unix()},
	}
	sc.actual = []shadowListen{
		{Key: "A|x|y", StartedAt: t0.Unix() + 20, At: t0.Unix()},
		{Key: "C|x|y", StartedAt: t0.Unix(), At: t0.Unix()},
	}
	sc.matchListens(t0.Add(time.Minute))
	if sc.report.Listens.Matched != 1 || sc.report.Listens.OnlyActual != 0 || sc.report.Listens.OnlySimulated != 0 {
		t.Fatalf("before settling only the match is counted: %+v", sc.report.Listens)
	}
	sc.matchListens(t0.Add(5 * time.Minute))
	if sc.report.Listens.OnlyActual != 1 || sc.report.Listens.OnlySimulated != 1 {
		t.Fatalf("after settling the leftovers are counted on each side: %+v", sc.report.Listens)
	}
}
