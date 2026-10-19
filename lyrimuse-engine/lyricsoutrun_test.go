package main

import "testing"

// 开头多一段对白的专辑版(339 秒)那份词,末句在 334.98 秒。
const outrunAlbumBody = "[00:00.00]Got-t-t-t me, that girl\n[00:28.76]All right!\n[05:32.46]You rock my world\n[05:34.98]You rock my world"

func TestLyricsOutrunPlayback(t *testing.T) {
	for _, c := range []struct {
		name             string
		lyrics           string
		resolved, actual float64
		want             bool
	}{
		{"末句比曲长晚 26 秒", outrunAlbumBody, 337.733, 308.44, true},
		{"时长对得上", outrunAlbumBody, 337.733, 338.9, false},
		{"末句只晚 5 秒以内", outrunAlbumBody, 337.733, 330.5, false},
		{"选词时的时长不比现在长", outrunAlbumBody, 308, 308.44, false},
		{"选词时的时长未知", outrunAlbumBody, 0, 308.44, false},
		{"现在的时长未知", outrunAlbumBody, 337.733, 0, false},
		{"没歌词", "", 337.733, 308.44, false},
		{"没时间戳", "You rock my world", 337.733, 308.44, false},
		{"末尾的署名行不算", "[00:28.76]All right!\n[05:00.00]You rock my world\n[05:34.98]监制：Michael Jackson", 337.733, 308.44, false},
	} {
		if got := lyricsOutrunPlayback(c.lyrics, c.resolved, c.actual); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

// 现存那份按 337 秒选、1412 分,现在放的是 308 秒的版本:末句比曲长晚,不拿 1412 分当基准,1200 分的胜者照换。
// 按原来的时长再放,照旧要高出门槛才换。见 09 章决策 277。
func TestLyricsUpgradeAppliesWhenStoredLyricsOutrunPlayback(t *testing.T) {
	cur := enrichEntry{
		Lyrics: bt(outrunAlbumBody), LyricsSource: "soda", LyricsScore: 1412,
		LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision,
		ResolvedDurationSecs: 337.733,
	}
	kugou := scoredLyricCandidateResult{Source: "kugou", Lyrics: "[00:00.50]All right!\n[05:01.00]You rock my world", Score: 1200}
	scored := []scoredLyricCandidateResult{kugou}
	if !lyricsUpgradeApplies(cur, scored, &kugou, 308.44) {
		t.Error("现存那份配不上这段音频,胜者应该换上")
	}
	if lyricsUpgradeApplies(cur, scored, &kugou, 338.9) {
		t.Error("时长对得上时照旧按存着的分比")
	}
	low := kugou
	low.Score = lyricsUpgradeMinGain - 1
	if lyricsUpgradeApplies(cur, scored, &low, 308.44) {
		t.Errorf("基准按 0 算,照样要高出 %d 分", lyricsUpgradeMinGain)
	}
}
