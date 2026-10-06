package main

import "testing"

func TestNeteaseTrialFull(t *testing.T) {
	cases := []struct {
		name         string
		bundle       string
		dur, full    float64
		want         float64
		ok, askedFor bool
	}{
		{"试听", neteaseMusicBundleID, 30.04, 212.8, 212.8, true, true},
		{"整首也很短", neteaseMusicBundleID, 30, 40, 0, false, true},
		{"查不到整首", neteaseMusicBundleID, 30, 0, 0, false, true},
		{"不是试听长度", neteaseMusicBundleID, 45, 212.8, 0, false, false},
		{"别的播放器", "com.apple.Music", 30, 212.8, 0, false, false},
	}
	for _, c := range cases {
		asked := false
		got, ok := neteaseTrialFull(c.bundle, c.dur, func() float64 { asked = true; return c.full })
		if got != c.want || ok != c.ok || asked != c.askedFor {
			t.Errorf("%s: neteaseTrialFull = %v %v (查整首=%v), want %v %v (查整首=%v)", c.name, got, ok, asked, c.want, c.ok, c.askedFor)
		}
	}
}

func TestNeteaseLocalPickFullDuration(t *testing.T) {
	track := func(album string, ms float64) neteaseLocalTrack {
		var tr neteaseLocalTrack
		tr.Album.Name = album
		tr.Duration = ms
		return tr
	}
	cases := []struct {
		name  string
		ents  []neteaseLocalTrack
		album string
		want  float64
	}{
		{"专辑对得上", []neteaseLocalTrack{track("精选", 180000), track("再见我的爱人2(1977)", 212811)}, "再见我的爱人2(1977)", 212.811},
		{"几条时长差不多", []neteaseLocalTrack{track("A", 209746), track("B", 210500)}, "C", 210.5},
		{"几条时长差得多、专辑也对不上", []neteaseLocalTrack{track("A", 180000), track("B", 240000)}, "C", 0},
		{"没有记录", nil, "A", 0},
	}
	for _, c := range cases {
		if got := neteaseLocalPickFullDuration(c.ents, c.album); got != c.want {
			t.Errorf("%s: = %v, want %v", c.name, got, c.want)
		}
	}
}
