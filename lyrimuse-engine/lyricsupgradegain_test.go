package main

import "testing"

// 在用 1364 分;这一轮另一个源 1366、在用那份 1363,两份都带逐字和译文,只差时长项、行数项的零头。见 09 章决策 212。
func TestLyricsUpgradeAppliesNeedsMinGain(t *testing.T) {
	const qqBody = "[00:29.56]She was more like a beauty queen\n[00:33.31]I said don't mind\n[00:38.69]Who will dance"
	const kuwoBody = "[00:29.50]She was more like a beauty queen\n[00:33.30]I said don't mind\n[00:38.70]Who will dance"
	cur := enrichEntry{
		Lyrics:               qqBody,
		LyricsSource:         "qq",
		LyricsScore:          1364,
		LyricsScoringVersion: lyricsScoringVersion,
		ResolvedDurationSecs: 294,
	}
	kuwo := scoredLyricCandidateResult{Source: "kuwo", Lyrics: kuwoBody, Score: 1366}
	scored := []scoredLyricCandidateResult{kuwo, {Source: "qq", Lyrics: qqBody, Score: 1363}}
	if lyricsUpgradeApplies(cur, scored, &kuwo, 294) {
		t.Error("只高出 2 分不该换掉在用的歌词")
	}
	edge := kuwo
	edge.Score = cur.LyricsScore + lyricsUpgradeMinGain - 1
	if lyricsUpgradeApplies(cur, scored, &edge, 294) {
		t.Errorf("差 %d 分还在门槛内,不该换", lyricsUpgradeMinGain-1)
	}
	edge.Score = cur.LyricsScore + lyricsUpgradeMinGain
	if !lyricsUpgradeApplies(cur, scored, &edge, 294) {
		t.Errorf("高出 %d 分应该换", lyricsUpgradeMinGain)
	}
	// 带译文那一项(+50)这类实质提升照换。
	better := kuwo
	better.Score = cur.LyricsScore + 50
	if !lyricsUpgradeApplies(cur, scored, &better, 294) {
		t.Error("高出 50 分应该换")
	}
	// 没歌词的条目不设门槛,能用的候选直接填上。
	fill := scoredLyricCandidateResult{Source: "lrclib", Lyrics: kuwoBody, Score: 5}
	if !lyricsUpgradeApplies(enrichEntry{}, []scoredLyricCandidateResult{fill}, &fill, 294) {
		t.Error("空条目拿到正分候选应该填上")
	}
}
