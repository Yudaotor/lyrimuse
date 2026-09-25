package main

import (
	"context"
	"math"
	"strings"
	"testing"
	"time"
)

// 放 Apple Music 时,这一拍的快照本身就是 Music.app 的 AppleScript 读数:直接用它校准,不再另起一个
// osascript 问同一个值。快照陈旧、或退回了 media-control 那份时照旧单独问一次。
func TestCalibrateAppleMusicPositionUsesThisTickReading(t *testing.T) {
	saved := appleMusicPositionQuery
	t.Cleanup(func() { appleMusicPositionQuery = saved })
	calls := 0
	appleMusicPositionQuery = func(context.Context) (float64, bool) {
		calls++
		return 99, true
	}
	now := time.Now()
	p := &poller{ctx: context.Background()}
	p.cur = snapshot{Elapsed: 120, McTS: now.Add(-200 * time.Millisecond), PositionFromPlayerClock: true}
	p.calibrateAppleMusicPosition(now)
	if calls != 0 {
		t.Fatalf("这一拍已经是 AppleScript 读数,不该再问, got %d", calls)
	}
	if math.Abs(p.trackPos-120.2) > 0.001 || p.cur.Position != p.trackPos || !p.prevWall.Equal(now) || !p.cur.AnchorTS.Equal(now) {
		t.Fatalf("该按读数外推到此刻并回写累加器: trackPos=%.3f pos=%.3f", p.trackPos, p.cur.Position)
	}

	p.snapshotStale = true
	p.calibrateAppleMusicPosition(now)
	if calls != 1 || p.trackPos != 99 {
		t.Fatalf("快照陈旧时该单独问一次: calls=%d trackPos=%.3f", calls, p.trackPos)
	}
	p.snapshotStale = false
	p.cur.PositionFromPlayerClock = false
	p.calibrateAppleMusicPosition(now)
	if calls != 2 {
		t.Fatalf("退回 media-control 那份时该单独问一次: calls=%d", calls)
	}
}

func TestAppleMusicStateMarksPlayerClock(t *testing.T) {
	if !strings.Contains(getStateScript, "positionFromPlayerClock: true") {
		t.Fatal("Apple Music 的 AppleScript 快照要带 positionFromPlayerClock")
	}
	if !extract(map[string]any{"title": "T", "positionFromPlayerClock": true}).PositionFromPlayerClock {
		t.Fatal("extract 要读出 positionFromPlayerClock")
	}
}
