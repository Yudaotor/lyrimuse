package main

import "testing"

// 「优先用歌曲文件自带的歌词」:没写过时跟着匹配算法取缺省,写过就照写的。
func TestResolvePreferLocalFileLyrics(t *testing.T) {
	yes, no := true, false
	cases := []struct {
		p    *bool
		mode string
		want bool
	}{
		{nil, lyricsModePriority, true},
		{nil, lyricsModeSmart, false},
		{nil, "", false},
		{&no, lyricsModePriority, false},
		{&yes, lyricsModeSmart, true},
	}
	for _, c := range cases {
		if got := resolvePreferLocalFileLyrics(c.p, c.mode); got != c.want {
			t.Errorf("resolvePreferLocalFileLyrics(%v, %q) = %v, want %v", c.p, c.mode, got, c.want)
		}
	}
}

func withSmartPrefer(t *testing.T, prefer bool) {
	t.Helper()
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	setFeatures(featureFlags{LyricsSources: map[string]bool{"netease": true, "qq": true}, LyricsSourceMode: lyricsModeSmart,
		LyricsAutoUpgrade: true, PreferLocalFileLyrics: prefer})
}

// 智能算法下打开:文件自带的干净就直接用,不比分;带扣分项的、只有纯文本的不算;关着照分数挑。
func TestSmartPickPrefersCleanLocalFile(t *testing.T) {
	netease := scoredLyricCandidateResult{Source: "netease", Score: 1139}
	lrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: 672,
		ScoreTerms: []scoreTerm{{Kind: scoreTermNativeSource, Points: 250}}}
	offLrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: 1,
		ScoreTerms: []scoreTerm{{Kind: "durationOff", Points: -500}, {Kind: scoreTermNativeSource, Points: 250}}}
	plainLrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: -1}

	withSmartPrefer(t, true)
	if got := pickLyricCandidate([]scoredLyricCandidateResult{netease, lrc}); got == nil || got.Source != localFileLyricsSource {
		t.Fatalf("打开时文件自带的干净那份直接用, got %+v", got)
	}
	if !earlyLyricsPenaltyTerms["durationOff"] {
		t.Fatal("测试前提:durationOff 是扣分项")
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{netease, offLrc}); got == nil || got.Source != "netease" {
		t.Fatalf("文件自带的带扣分项(时长对不上)不优先, got %+v", got)
	}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{netease, plainLrc}); got == nil || got.Source != "netease" {
		t.Fatalf("只有纯文本的不顶掉带时间的, got %+v", got)
	}
	if earlyLyricsVerdict([]scoredLyricCandidateResult{lrc}, &lrc, func(string) bool { return false }, false, 0) != earlyLyricsTrust {
		t.Error("打开时文件自带的那份不用等别的源回话就先上屏")
	}
	if earlyLyricsVerdict([]scoredLyricCandidateResult{offLrc}, &offLrc, func(string) bool { return false }, false, 0) == earlyLyricsTrust {
		t.Error("文件自带的带扣分项(给别的版本的)不直接先上屏")
	}
	if got := earlyLyricsVerdict([]scoredLyricCandidateResult{netease}, &netease, func(string) bool { return false }, false, 0); got != earlyLyricsWait {
		t.Errorf("挑中的不是文件自带的(这一首没有文件那一份):不走「不用等别的源」那条,照常等,得到 %q", got)
	}

	withSmartPrefer(t, false)
	if got := pickLyricCandidate([]scoredLyricCandidateResult{netease, lrc}); got == nil || got.Source != "netease" {
		t.Fatalf("关着照分数挑, got %+v", got)
	}
}

// 顺序优先下关掉:文件自带的不再固定排第一,并进「播放器自带歌词」那一项、跟着它的位置走。
func TestPriorityTiersLocalFileFollowsPlayerLocalWhenNotPreferred(t *testing.T) {
	withPriorityOrder(t, "qq", "netease")
	featuresRef().PreferLocalFileLyrics = false
	qq := scoredLyricCandidateResult{Source: "qq", Score: 900}
	spotify := scoredLyricCandidateResult{Source: spotifyLocalLyricsSource, Score: 300}
	lrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: 600}
	if got := pickLyricCandidate([]scoredLyricCandidateResult{qq, lrc}); got == nil || got.Source != "qq" {
		t.Fatalf("关着时 .lrc 跟「播放器自带歌词」排在全部源之后, got %+v", got)
	}
	if priorityRank(localFileLyricsSource) != priorityRank(spotifyLocalLyricsSource) {
		t.Errorf("关着时 .lrc 跟播放器自带歌词同一个名次: lrc=%d spotify=%d",
			priorityRank(localFileLyricsSource), priorityRank(spotifyLocalLyricsSource))
	}
	featuresRef().LyricsSourceOrder = resolveLyricsSourceOrder([]string{lyricsPriorityPlayerLocal, "qq", "netease"})
	if got := pickLyricCandidate([]scoredLyricCandidateResult{qq, lrc, spotify}); got == nil || got.Source != localFileLyricsSource {
		t.Fatalf("「播放器自带歌词」拖到第一位,同一个名次里按分数挑 .lrc, got %+v", got)
	}
	featuresRef().PreferLocalFileLyrics = true
	if priorityRank(localFileLyricsSource) != 0 {
		t.Errorf("打开时 .lrc 排第一, rank=%d", priorityRank(localFileLyricsSource))
	}
}

// 智能算法下打开:升级重试和重评都换成文件自带的;现存的是文件自带的、这一轮没读到文件时不换走。
func TestPreferLocalFileUpgradeAndRescore(t *testing.T) {
	online := enrichEntry{Lyrics: bt("[00:01.00]网上那份\n[00:05.00]第二行"), LyricsSource: "netease"}
	local := enrichEntry{Lyrics: bt("[00:01.00]文件那份\n[00:05.00]第二行"), LyricsSource: localFileLyricsSource}
	lrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: 672, Lyrics: "[00:01.00]文件那份\n[00:05.00]第二行"}
	netease := scoredLyricCandidateResult{Source: "netease", Score: 1139, Lyrics: "[00:01.00]网上那份\n[00:05.00]第二行"}

	withSmartPrefer(t, true)
	if !lyricsUpgradeApplies(online, []scoredLyricCandidateResult{netease, lrc}, &lrc, 0) {
		t.Error("打开时升级重试换成文件自带的")
	}
	if lyricsUpgradeApplies(local, []scoredLyricCandidateResult{netease}, &netease, 0) {
		t.Error("现存的是文件自带的、这一轮没读到文件时不换走")
	}
	if rescoreKeepsLyrics(online, []scoredLyricCandidateResult{netease, lrc}, &lrc, false, false) {
		t.Error("打开时重评不留网上那份")
	}
	if !rescoreKeepsLyrics(local, []scoredLyricCandidateResult{netease}, &netease, false, false) {
		t.Error("打开时重评留住文件自带的")
	}
	if _, decided := preferLocalFileUpgradeVerdict(local, &netease, 0, true); decided {
		t.Error("手动重新匹配不替它拍板,照原来的规则")
	}
	if applies, decided := preferLocalFileUpgradeVerdict(local, &lrc, 0, false); applies || decided {
		t.Errorf("现存的和这一轮挑中的都是文件自带的:不在这里拍板,照原来的规则判(applies=%v decided=%v)", applies, decided)
	}
	shortCut := local
	shortCut.ResolvedDurationSecs, shortCut.DurationSecs = 240, 330
	if _, decided := preferLocalFileUpgradeVerdict(shortCut, &netease, 330, false); decided {
		t.Error("现存那份是给短一版选的、现在放的是加长版:不替它拍板")
	}
	if !localFileLyricsWorthRecheck(enrichEntry{LyricsSource: "netease", LyricsSourcesSeen: []string{localFileLyricsSource}},
		"com.foobar2000.mac", false, true, true) {
		t.Error("打开时见过文件自带的、现存却不是它:再来一次")
	}

	withSmartPrefer(t, false)
	if _, decided := preferLocalFileUpgradeVerdict(online, &lrc, 0, false); decided {
		t.Error("关着时不插手,照原来的分数规则")
	}
	if localFileLyricsWorthRecheck(enrichEntry{LyricsSource: "netease", LyricsSourcesSeen: []string{localFileLyricsSource}},
		"com.foobar2000.mac", false, true, true) {
		t.Error("关着时见过就不再来")
	}
}

// 顺序优先下(缺省开着):各源都还没回话、文件自带的那份带扣分项被当兜底挑中时,不先上屏,等排在后面的源。
func TestPriorityEarlyLyricsWaitsOnPenalizedLocalFile(t *testing.T) {
	withPriorityOrder(t, "qq", "netease")
	offLrc := scoredLyricCandidateResult{Source: localFileLyricsSource, Score: 1,
		ScoreTerms: []scoreTerm{{Kind: "durationOff", Points: -500}, {Kind: scoreTermNativeSource, Points: 250}}}
	scored := []scoredLyricCandidateResult{offLrc}
	picked := pickLyricCandidate(scored)
	if picked == nil || picked.Source != localFileLyricsSource {
		t.Fatalf("测试前提:找不到干净候选时退回文件自带的那份, got %+v", picked)
	}
	if got := earlyLyricsVerdict(scored, picked, func(string) bool { return false }, false, 0); got != earlyLyricsWait {
		t.Errorf("带扣分项的文件自带歌词要等别的源回话, got %q", got)
	}
}
