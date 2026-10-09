package main

import "testing"

func TestLyricsScoringStampOrder(t *testing.T) {
	cases := []struct {
		a, b lyricsScoringStamp
		want bool
	}{
		{lyricsScoringStamp{29, 9}, lyricsScoringStamp{29, 10}, true}, // 按整数比,不是小数
		{lyricsScoringStamp{29, 10}, lyricsScoringStamp{29, 9}, false},
		{lyricsScoringStamp{29, 0}, lyricsScoringStamp{29, 1}, true},
		{lyricsScoringStamp{29, 3}, lyricsScoringStamp{30, 0}, true},
		{lyricsScoringStamp{29, 1}, lyricsScoringStamp{29, 1}, false},
	}
	for _, c := range cases {
		if got := c.a.before(c.b); got != c.want {
			t.Errorf("%v before %v = %v, want %v", c.a, c.b, got, c.want)
		}
	}
	if s := (lyricsScoringStamp{29, 0}).String(); s != "29" {
		t.Errorf("修订号为 0 时显示 %q, want 29", s)
	}
	if s := (lyricsScoringStamp{29, 10}).String(); s != "29.10" {
		t.Errorf("显示 %q, want 29.10", s)
	}
}

// 主版本相同、修订号落后的条目照样按新规则重选;打上当前版本之后不再重选。
func TestNeedsLyricsRescoreFollowsRevision(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision - 1}
	if lyricsScoringRevision > 0 && !needsLyricsRescore(e, false, true) {
		t.Fatal("修订号落后的条目该重选")
	}
	e.stampLyricsScoring()
	if needsLyricsRescore(e, false, true) {
		t.Fatal("打上当前版本之后不该再重选")
	}
}
