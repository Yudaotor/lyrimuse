package main

import "testing"

func TestFoldHanNumerals(t *testing.T) {
	for in, want := range map[string]string{
		"爱情三十六计":  "爱情36计",
		"一百零八":    "108",
		"十二":      "12",
		"十":       "10",
		"二十":      "20",
		"两千零二十六":  "2026",
		"二〇二六":    "2026",
		"三百六十五里路": "365里路",
		"一生一世":    "1生1世",
		"十十":      "十十",
		"三百六":     "三百六",
		"一十二":     "12",
		"爱情36计":   "爱情36计",
		"千千阙歌":    "千千阙歌",
		"Love":    "Love",
	} {
		if got := foldHanNumerals(in); got != want {
			t.Errorf("foldHanNumerals(%q) = %q,期望 %q", in, got, want)
		}
	}
}

// 歌名闸:两边换成阿拉伯数字之后相等的认;版本差异照旧归版本闸,不相等的照旧不认。
func TestLyricTitleAcceptedHanNumerals(t *testing.T) {
	for _, c := range []struct {
		cand, local string
		want        bool
	}{
		{"爱情36计", "爱情三十六计", true},
		{"M87", "M八七", true},
		{"一百種生活", "100種生活", true},
		{"爱情37计", "爱情三十六计", false},
		{"爱情36计2", "爱情三十六计", false},
	} {
		if got := lyricTitleAccepted(c.cand, c.local); got != c.want {
			t.Errorf("lyricTitleAccepted(%q, %q) = %v,期望 %v", c.cand, c.local, got, c.want)
		}
	}
}
