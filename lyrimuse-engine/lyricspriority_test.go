package main

import (
	"testing"
	"time"
)

func withPriorityOrder(t *testing.T, order ...string) {
	t.Helper()
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	enabled := map[string]bool{}
	for _, s := range order {
		enabled[s] = true
	}
	setFeatures(featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModePriority, LyricsSourceOrder: order,
		LyricsAutoUpgrade: true})
}

// 顺序优先跳过带扣分项的候选(版本不符、末句超过曲长……夹到 1 分也照样跳),各源都带扣分时退回顺序里第一个能用的;
// 逐字加分撤销那一项不算扣分。
func TestPriorityPickSkipsPenalizedCandidates(t *testing.T) {
	withPriorityOrder(t, "qq", "netease", "kugou")
	versionOff := scoredLyricCandidateResult{Source: "qq", Score: 1, ScoreTerms: []scoreTerm{{Kind: scoreTermVersionTags, Points: -600}}}
	overshoot := scoredLyricCandidateResult{Source: "netease", Score: 1, ScoreTerms: []scoreTerm{{Kind: scoreTermDurationOvershoot, Points: -600}}}
	clean := scoredLyricCandidateResult{Source: "kugou", Score: 900}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{clean, versionOff, overshoot}); got == nil || got.Source != "kugou" {
		t.Fatalf("排在前面的两份都带扣分项,该取干净的酷狗, got %+v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{versionOff, overshoot}); got == nil || got.Source != "qq" {
		t.Fatalf("都带扣分项时退回顺序里第一个能用的, got %+v", got)
	}
	wordTiming := scoredLyricCandidateResult{Source: "qq", Score: 700, ScoreTerms: []scoreTerm{{Kind: scoreTermWordTimingOverride, Points: -200}}}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{clean, wordTiming}); got == nil || got.Source != "qq" {
		t.Fatalf("逐字加分撤销不算扣分, got %+v", got)
	}
}

// 首轮先上屏:挑出来的是退回来的(带扣分项)那份时,要顺序里开着的源都回话。
func TestPriorityPickSettledWaitsForCleanFallback(t *testing.T) {
	withPriorityOrder(t, "qq", "netease")
	versionOff := scoredLyricCandidateResult{Source: "qq", Score: 1, ScoreTerms: []scoreTerm{{Kind: scoreTermVersionTags, Points: -600}}}
	answered := func(names ...string) func(string) bool {
		return func(s string) bool {
			for _, n := range names {
				if n == s {
					return true
				}
			}
			return false
		}
	}
	scored := []scoredLyricCandidateResult{versionOff}
	if priorityPickSettled(scored, &scored[0], answered("qq")) {
		t.Error("网易云还没回话,它可能给出干净的那份")
	}
	if !priorityPickSettled(scored, &scored[0], answered("qq", "netease")) {
		t.Error("都回话了")
	}
}

// 升级重试在顺序优先下按名次换:排前面的源回来了就换(分低也换);排后面的只在现存那份的来源这一轮回了话、却没给出能挑的
// 时才换;同一个来源照分数门槛。
func TestPriorityUpgradeFollowsOrder(t *testing.T) {
	withPriorityOrder(t, "qq", "netease")
	const cur = "[00:01.00]现存\n[00:05.00]第二句\n[00:09.00]第三句"
	fromNetease := enrichEntry{Lyrics: bt(cur), LyricsSource: "netease", LyricsScore: 1000,
		LyricsScoringVersion: lyricsScoringVersion, LyricsScoringRevision: lyricsScoringRevision}
	qq := scoredLyricCandidateResult{Source: "qq", Score: 800, Lyrics: "[00:01.00]QQ\n[00:05.00]二\n[00:09.00]三"}
	if !lyricsUpgradeApplies(fromNetease, []scoredLyricCandidateResult{qq}, &qq, 0) {
		t.Error("排第一的 QQ 回来了,分低也该换")
	}

	fromQQ := fromNetease
	fromQQ.LyricsSource, fromQQ.LyricsScore = "qq", 800
	ne := scoredLyricCandidateResult{Source: "netease", Score: 1100, Lyrics: "[00:01.00]网易\n[00:05.00]二\n[00:09.00]三"}
	if lyricsUpgradeApplies(fromQQ, []scoredLyricCandidateResult{ne}, &ne, 0) {
		t.Error("QQ 这一轮没回话,不该被排后面的网易云换走")
	}
	qqPenalized := scoredLyricCandidateResult{Source: "qq", Score: 1, Lyrics: cur, ScoreTerms: []scoreTerm{{Kind: scoreTermVersionTags, Points: -600}}}
	if !lyricsUpgradeApplies(fromQQ, []scoredLyricCandidateResult{ne, qqPenalized}, &ne, 0) {
		t.Error("QQ 回了话、给的只有带扣分项的,该换成网易云")
	}

	sameSource := scoredLyricCandidateResult{Source: "netease", Score: 1010, Lyrics: "[00:01.00]另一份\n[00:05.00]二\n[00:09.00]三"}
	if lyricsUpgradeApplies(fromNetease, []scoredLyricCandidateResult{sameSource}, &sameSource, 0) {
		t.Errorf("同一个来源照分数门槛:没高出 %d 分不换", lyricsUpgradeMinGain)
	}
}

// 顺序优先下排在当前来源前面的源上一轮缺席:现存那份带逐字也要重试;智能算法下照旧不重试。
func TestPriorityRetryWhenAheadSourceAbsent(t *testing.T) {
	withPriorityOrder(t, "qq", "netease")
	e := enrichEntry{Lyrics: bt("[00:01.00]x"), LyricsYRC: bt("[1000,500](1000,500,0)x"), LyricsSource: "netease",
		LyricsSourcesResponded: []string{"netease"}, TS: time.Now().Add(-7 * time.Hour).Unix()}
	if !needsLyricsRetry(e, false, false, true) {
		t.Error("排第一的 QQ 上次缺席,该再问一次")
	}
	e.LyricsSourcesResponded = []string{"netease", "qq"}
	if needsLyricsRetry(e, false, false, true) {
		t.Error("QQ 回过话了,有逐字就不重试")
	}
	fromQQ := e
	fromQQ.LyricsSource, fromQQ.LyricsSourcesResponded = "qq", []string{"qq"}
	if needsLyricsRetry(fromQQ, false, false, true) {
		t.Error("缺席的网易云排在当前来源 QQ 后面,有逐字就不重试")
	}
	e.LyricsSourcesResponded = []string{"netease"}
	featuresRef().LyricsSourceMode = lyricsModeSmart
	if needsLyricsRetry(e, false, false, true) {
		t.Error("智能算法下有逐字就不重试")
	}
}

// 「顺序优先」的先后:reAMP 同名 .lrc 排最前;「播放器自带歌词」排在顺序表里它所在的位置,几份播放器本地歌词同一个名次按分数挑;
// 默认(没排过)在全部源之后。
func TestPriorityTiersPlaceLocalLyrics(t *testing.T) {
	withPriorityOrder(t, "qq", "netease")
	qq := scoredLyricCandidateResult{Source: "qq", Score: 900}
	kkbox := scoredLyricCandidateResult{Source: kkboxLocalLyricsSource, Score: 600}
	spotify := scoredLyricCandidateResult{Source: spotifyLocalLyricsSource, Score: 700}
	lrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: 300}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{qq, spotify, kkbox, lrc}); got == nil || got.Source != localFileLyricsSource {
		t.Fatalf("同名 .lrc 排最前, got %+v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{qq, spotify, kkbox}); got == nil || got.Source != "qq" {
		t.Fatalf("没排过「播放器自带歌词」时它在全部源之后, got %+v", got)
	}
	featuresRef().LyricsSourceOrder = resolveLyricsSourceOrder([]string{lyricsPriorityPlayerLocal, "qq", "netease"})
	if got := pickLyricCandidate([]scoredLyricCandidateResult{qq, spotify, kkbox}); got == nil || got.Source != spotifyLocalLyricsSource {
		t.Fatalf("「播放器自带歌词」拖到第一位,同一个名次里按分数挑 Spotify, got %+v", got)
	}
	if priorityRank(kkboxLocalLyricsSource) != priorityRank(spotifyLocalLyricsSource) || priorityRank(localFileLyricsSource) != 0 ||
		priorityRank("qq") <= priorityRank(kkboxLocalLyricsSource) {
		t.Errorf("名次: lrc=%d kkbox=%d spotify=%d qq=%d", priorityRank(localFileLyricsSource), priorityRank(kkboxLocalLyricsSource),
			priorityRank(spotifyLocalLyricsSource), priorityRank("qq"))
	}
	// 现存的是 QQ 的词、「播放器自带歌词」排在它前面:播放器本地歌词不算缺席,不为它重试。
	e := enrichEntry{Lyrics: bt("[00:01.00]x"), LyricsYRC: bt("[1000,500](1000,500,0)x"), LyricsSource: "qq",
		LyricsSourcesResponded: []string{"qq", "netease"}, TS: time.Now().Add(-7 * time.Hour).Unix()}
	if needsLyricsRetry(e, false, false, true) {
		t.Error("播放器本地歌词不算缺席")
	}
}
