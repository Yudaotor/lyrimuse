package main

import "testing"

// 网易云、QQ、汽水三家的本机曲库挑法用同一道判据(localLibraryEntryFits):只有另一张专辑的同名曲目时,
// 时长未知或差 3 秒都不认,差不到 1 秒、或者播放器没报专辑时才认。
func TestLocalLibraryPickersNeedSameLengthForOtherAlbum(t *testing.T) {
	var ne neteaseLocalTrack
	ne.Name, ne.Album.Name, ne.Duration = "董小姐", "摩登天空7", 313320
	var so sodaLocalTrack
	so.Name, so.Album.Name, so.Duration = "董小姐", "摩登天空7", 313320
	qq := qqLocalEntry{mid: "001", title: "董小姐", album: "摩登天空7", duration: 313.32}
	pickers := map[string]func(album string, dur float64) bool{
		"netease": func(album string, dur float64) bool {
			_, ok := pickNeteaseLocalEntry([]neteaseLocalTrack{ne}, album, dur)
			return ok
		},
		"soda": func(album string, dur float64) bool {
			_, ok := pickSodaLocalEntry([]sodaLocalTrack{so}, album, dur)
			return ok
		},
		"qq": func(album string, dur float64) bool {
			_, ok := pickQQLocalEntry([]qqLocalEntry{qq}, album, dur)
			return ok
		},
	}
	for name, pick := range pickers {
		for _, c := range []struct {
			album string
			dur   float64
			hit   bool
		}{
			{"安和桥北", 0, false},
			{"安和桥北", 310.2, false},
			{"安和桥北", 313.0, true},
			{"", 310.2, true},
			{"摩登天空7", 0, true},
		} {
			if got := pick(c.album, c.dur); got != c.hit {
				t.Errorf("%s:专辑 %q 时长 %v,命中=%v,要 %v", name, c.album, c.dur, got, c.hit)
			}
		}
	}
}
