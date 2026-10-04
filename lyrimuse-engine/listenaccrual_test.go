package main

import (
	"context"
	"testing"
	"time"
)

// 两次读数之间计多少收听:有位置就不超过位置前进的量;长空档只有 App 按住造成的才补;没有位置照旧按墙钟。
func TestListenAccrualSecs(t *testing.T) {
	cases := []struct {
		name            string
		wall, from, to  float64
		positions, held bool
		playingNow      bool
		want            float64
	}{
		{"连续播放一拍", 5, 10, 15, true, false, true, 5},
		{"往后拖进度不灌水", 5, 10, 100, true, false, true, 5},
		{"往回拖的那一拍不算", 5, 100, 10, true, false, true, 0},
		{"短睡眠:位置几乎没走", 40, 10, 11, true, false, true, 1},
		{"长空档不是按住造成的:不算", 120, 10, 130, true, false, true, 0},
		{"按住 2 分钟、其间一直在放:全补", 120, 10, 130, true, true, true, 120},
		{"按住 200 秒、其间只放了 30 秒:补 30 秒", 200, 10, 40, true, true, true, 30},
		{"暂停那一拍:补上暂停前放的那段", 4, 10, 13, true, false, false, 3},
		{"没有位置:按墙钟", 5, 0, 0, false, false, true, 5},
		{"没有位置、空档太长:不算", 90, 0, 0, false, true, true, 0},
		{"没有位置、这一拍已暂停:不补", 4, 0, 0, false, false, false, 0},
		{"时钟倒退", -3, 10, 15, true, false, true, 0},
	}
	for _, c := range cases {
		if got := listenAccrualSecs(c.wall, c.from, c.to, c.positions, c.held, c.playingNow); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 按住、读空去抖期间的拍不计时、不挪起点;恢复后按 App 报的位置补;暂停那一拍补上暂停前的部分再停表。
func TestNoteListeningTickSkipsStaleTicks(t *testing.T) {
	t0 := time.Unix(1_790_000_000, 0)
	at := func(sec float64) time.Time { return t0.Add(time.Duration(sec * float64(time.Second))) }
	p := &poller{sess: &playSession{key: "Song|Singer|Album"}}
	tick := func(sec, pos float64, playing, stale, held bool) {
		now := at(sec)
		p.cur = snapshot{Title: "Song", Artist: "Singer", Album: "Album", Playing: playing, Position: pos, AnchorTS: now}
		p.curStale, p.curHeld = stale, held
		p.noteListeningTick(now)
	}
	want := func(step string, secs float64) {
		t.Helper()
		if p.sess.playedSecs != secs {
			t.Fatalf("%s: playedSecs = %v, want %v", step, p.sess.playedSecs, secs)
		}
	}

	tick(0, 10, true, false, false)
	tick(5, 15, true, false, false)
	want("连续播放", 5)

	// App 按住 200 秒,其间播放器其实只放了 30 秒:按住的拍不计,解除那一拍按位置补 30 秒。
	for s := 10.0; s < 205; s += 5 {
		tick(s, 15+(s-5), true, true, true)
	}
	want("按住期间不计", 5)
	tick(205, 45, true, false, false)
	want("按住解除按位置补", 35)

	// 读空去抖(不是按住):留着的拍不计;同一首 15 秒后回来、位置走了 15 秒,补 15 秒。
	tick(210, 50, true, false, false)
	tick(215, 55, true, true, false)
	tick(220, 60, true, true, false)
	tick(225, 65, true, false, false)
	want("去抖之后按位置补", 55)

	// 暂停那一拍补上暂停前放的 2 秒,之后停表;恢复那一拍只起表。
	tick(228, 67, false, false, false)
	want("暂停那一拍", 57)
	tick(300, 67, false, false, false)
	tick(310, 67, true, false, false)
	want("恢复那一拍只起表", 57)
	tick(315, 72, true, false, false)
	want("恢复后接着计", 62)
}

// 没有位置可核的快照(没有锚点时刻)照旧按墙钟计,读空去抖期间同样不计。
func TestNoteListeningTickWithoutPositions(t *testing.T) {
	t0 := time.Unix(1_790_000_000, 0)
	p := &poller{sess: &playSession{key: "Song|Singer|Album"}}
	p.cur = snapshot{Title: "Song", Artist: "Singer", Album: "Album", Playing: true}
	p.noteListeningTick(t0)
	p.noteListeningTick(t0.Add(5 * time.Second))
	p.curStale = true
	p.noteListeningTick(t0.Add(10 * time.Second))
	if p.sess.playedSecs != 5 {
		t.Fatalf("playedSecs = %v, want 5", p.sess.playedSecs)
	}
	p.curStale = false
	p.noteListeningTick(t0.Add(15 * time.Second))
	if p.sess.playedSecs != 15 {
		t.Fatalf("没有位置时恢复按墙钟补(60 秒以内): playedSecs = %v, want 15", p.sess.playedSecs)
	}
}

// App 按住时这一拍记成 curStale + curHeld;App 状态不可用 / 没在放、留着上一首的拍记成 curStale;正常拍都不记。
func TestApplyAppPlaybackTickMarksStale(t *testing.T) {
	t.Cleanup(func() { noteAppReportedAd(snapshot{}, false) })
	p := &poller{ctx: context.Background(), cfg: &config{}}
	t0 := time.Unix(1_790_000_000, 0)
	rec := appSourceRec(7, 1, 1, "Song", t0)
	tick, marks := appPlaybackTickFor(rec, appPlaybackMarks{}, t0, plainAppJudge())
	p.applyAppPlaybackTick(t0, tick)
	if p.curStale || p.curHeld {
		t.Fatalf("a fresh App reading is live: stale=%v held=%v", p.curStale, p.curHeld)
	}
	rec.Holding = true
	tick, marks = appPlaybackTickFor(rec, marks, t0.Add(time.Second), plainAppJudge())
	p.applyAppPlaybackTick(t0.Add(time.Second), tick)
	if !p.curStale || !p.curHeld || p.cur.Title != "Song" {
		t.Fatalf("holding: stale=%v held=%v cur=%+v", p.curStale, p.curHeld, p.cur)
	}
	p.applyAppPlaybackTick(t0.Add(2*time.Second), appPlaybackTick{})
	if !p.curStale || p.curHeld || p.cur.Title != "Song" {
		t.Fatalf("standby keeps the track as stale: stale=%v held=%v cur=%+v", p.curStale, p.curHeld, p.cur)
	}
	rec.Holding = false
	tick, _ = appPlaybackTickFor(rec, marks, t0.Add(3*time.Second), plainAppJudge())
	p.applyAppPlaybackTick(t0.Add(3*time.Second), tick)
	if p.curStale || p.curHeld {
		t.Fatalf("live again: stale=%v held=%v", p.curStale, p.curHeld)
	}
}
