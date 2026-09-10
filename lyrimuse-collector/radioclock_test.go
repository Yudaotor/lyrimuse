package main

import (
	"testing"
	"time"
)

// 电台曲内时钟:换歌归零、播放中按墙钟走、暂停冻结、单拍有上限。
// 实测背景见 radioclock.go 头注(位置换歌不复位,实测偏了 304 秒)。
func TestAdvanceRadioClock(t *testing.T) {
	base := time.Date(2026, 9, 10, 7, 15, 35, 0, time.UTC)
	// 第一次见:归零起表。
	s := advanceRadioClock(radioClockState{}, "Daniel Caesar|Who Knows", true, base)
	if s.position != 0 || s.trackKey != "Daniel Caesar|Who Knows" {
		t.Fatalf("first sight should start at 0, got %+v", s)
	}
	// 播放中按墙钟累加。
	s = advanceRadioClock(s, "Daniel Caesar|Who Knows", true, base.Add(5*time.Second))
	s = advanceRadioClock(s, "Daniel Caesar|Who Knows", true, base.Add(10*time.Second))
	if s.position != 10 {
		t.Fatalf("playing should accumulate wall clock, got %.3f want 10", s.position)
	}
	// 换歌:归零 —— 这正是系统那块表不做的事(实测 07:20:39 换歌位置照旧往上走)。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(11*time.Second))
	if s.position != 0 || s.trackKey != "Clairo|Juna" {
		t.Fatalf("track change must reset to 0, got %+v", s)
	}
	// 暂停:冻结,tick 推进但位置不动;恢复后不会把暂停那段补回来。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(21*time.Second))
	if s.position != 10 {
		t.Fatalf("want 10 before pause, got %.3f", s.position)
	}
	s = advanceRadioClock(s, "Clairo|Juna", false, base.Add(120*time.Second))
	if s.position != 10 {
		t.Fatalf("pause must freeze the position, got %.3f", s.position)
	}
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(125*time.Second))
	if s.position != 15 {
		t.Fatalf("resume must not backfill the paused span, got %.3f want 15", s.position)
	}
	// 单拍上限:休眠 / 长卡顿之后墙钟差不再等于"播了多久"。
	s = advanceRadioClock(s, "Clairo|Juna", true, base.Add(125*time.Second+2*time.Hour))
	if s.position != 15+radioMaxAdvancePerTick.Seconds() {
		t.Fatalf("a huge gap must be clamped, got %.3f", s.position)
	}
	// 时钟倒退(NTP 校时)不减位置。
	before := s.position
	s = advanceRadioClock(s, "Clairo|Juna", true, base)
	if s.position != before {
		t.Fatalf("a backwards clock must not move the position, got %.3f want %.3f", s.position, before)
	}
}

// applyRadioClock 只动电台快照,普通播放原样不碰。
func TestApplyRadioClockOnlyTouchesRadio(t *testing.T) {
	radioClockMu.Lock()
	saved := radioClockValue
	radioClockValue = radioClockState{}
	radioClockMu.Unlock()
	defer func() {
		radioClockMu.Lock()
		radioClockValue = saved
		radioClockMu.Unlock()
	}()

	now := time.Date(2026, 9, 10, 7, 20, 39, 0, time.UTC)
	normal := snapshot{Title: "Fushigi", Artist: "星野源", Elapsed: 42, AnchorElapsed: 7, Duration: 292.21, Playing: true}
	before := normal
	applyRadioClock(&normal, now)
	if normal != before {
		t.Fatalf("a non-radio snapshot must be left alone: %+v vs %+v", normal, before)
	}

	radio := snapshot{Title: "Juna", Artist: "Clairo", Elapsed: 467, AnchorElapsed: 0, Playing: true, Radio: true}
	applyRadioClock(&radio, now)
	if radio.Elapsed != 0 || radio.AnchorElapsed != 0 {
		t.Fatalf("first radio tick should anchor at 0, got elapsed=%.3f anchor=%.3f", radio.Elapsed, radio.AnchorElapsed)
	}
	if !radio.McTS.Equal(now) {
		t.Fatalf("McTS should be the tick instant, got %v", radio.McTS)
	}
	radio.Elapsed = 999 // 系统下一拍照旧报整档节目的位置
	applyRadioClock(&radio, now.Add(20*time.Second))
	if radio.Elapsed != 20 {
		t.Fatalf("radio position must come from our own clock, got %.3f want 20", radio.Elapsed)
	}
}

// extract():电台的 duration 当未知,普通播放原样保留。
func TestExtractRadioDuration(t *testing.T) {
	radioState := map[string]any{
		"title": "Juna", "artist": "Clairo", "bundleIdentifier": "com.apple.Music",
		"duration": 3390.122, "elapsedTime": 467.0, "playing": true,
		"radioStationHash": "CgkIBRoFwOSKqxkQBA",
	}
	s := extract(radioState)
	if !s.Radio {
		t.Fatal("radioStationHash present → Radio must be true")
	}
	if s.Duration != 0 {
		t.Fatalf("radio duration is the whole show, must be treated as unknown, got %.3f", s.Duration)
	}
	normalState := map[string]any{
		"title": "Fushigi", "artist": "星野源", "bundleIdentifier": "com.apple.Music",
		"duration": 292.21, "elapsedTime": 12.0, "playing": true,
	}
	n := extract(normalState)
	if n.Radio || n.Duration != 292.21 {
		t.Fatalf("normal playback must keep its duration, got radio=%v duration=%.3f", n.Radio, n.Duration)
	}
}
