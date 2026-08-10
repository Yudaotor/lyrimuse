package main

import (
	"testing"
	"time"
)

// needsLyricsRescore 的回归测试。
//
// 背景:打分规则(scoreLyricCandidate)改了之后,已经缓存下来的条目仍挂着按旧规则选出来的
// 那份歌词——缓存是"解析一次永久保留"。2026-08-07 把时长档从 +1000 压到 +300、并把"歌词
// 结尾超出曲目时长"判成无效之后,用户那首《我们的时光》缓存里还是按旧规则胜出的
// Musixmatch。lyricsScoringVersion + 这个判定就是让存量条目跟上新规则的那条路径。
func TestNeedsLyricsRescore(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	stale := enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion - 1}

	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"版本落后:重选", stale, true},
		{
			name: "没有版本号的老条目(读成 0):也算落后,重选",
			e:    enrichEntry{Lyrics: "x"},
			want: true,
		},
		{
			name: "版本已是最新:不碰",
			e:    enrichEntry{Lyrics: "x", LyricsScoringVersion: lyricsScoringVersion},
			want: false,
		},
		{
			name: "人工修正过:绝不自动重搜(唯一不可恢复的东西)",
			e:    func() enrichEntry { e := stale; e.ManualLyrics = true; return e }(),
			want: false,
		},
		{
			name: "压根没歌词:交给首次解析那条路,不走这里",
			e:    enrichEntry{LyricsScoringVersion: lyricsScoringVersion - 1},
			want: false,
		},
		{
			name: "次数用尽:不为一次规则升级无限重搜",
			e:    func() enrichEntry { e := stale; e.LyricsRescoreCount = lyricsRescoreMaxAttempts; return e }(),
			want: false,
		},
		{
			name: "差一次到上限:还重选",
			e:    func() enrichEntry { e := stale; e.LyricsRescoreCount = lyricsRescoreMaxAttempts - 1; return e }(),
			want: true,
		},
		{
			name: "已有逐字歌词也照样重选 —— 规则变了,当初的选择本身就要重新审视",
			e:    func() enrichEntry { e := stale; e.LyricsYRC = "y"; return e }(),
			want: true,
		},
		{
			name: "刚尝试过:等间隔到了再来(不然一秒内就把次数烧光,全烧在同一个网络时机上)",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount, e.LyricsRescoreTS = 1, time.Now().Unix()
				return e
			}(),
			want: false,
		},
		{
			name: "间隔已过:再试一次",
			e: func() enrichEntry {
				e := stale
				e.LyricsRescoreCount = 1
				e.LyricsRescoreTS = time.Now().Unix() - int64(lyricsRescoreDeferInterval/time.Second) - 1
				return e
			}(),
			want: true,
		},
	}
	for _, c := range cases {
		if got := needsLyricsRescore(c.e); got != c.want {
			t.Errorf("%s: needsLyricsRescore = %v, want %v", c.name, got, c.want)
		}
	}

}

// 一个源明确给出了一份"烂"候选(被判无效),跟它超时压根没露面,是两回事——重选要求的是
// "这一轮信息完整",不是"这一轮每个源都给出了能用的东西"。
//
// 这个区分直接决定用户那首歌能不能修好:新规则下 Musixmatch 那份因为末尾超出曲长被判 -1,
// 如果按 lyricSourcesWithCandidates 的口径,它就成了"缺席的源",重选会被永远推迟。
func TestAllEnabledLyricSourcesResponded(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsSources = map[string]bool{"netease": true, "qq": true, "musixmatch": true, "kugou": false}

	full := []scoredLyricCandidateResult{
		{Source: "netease", Score: 173},
		{Source: "qq", Score: 582},
		{Source: "musixmatch", Score: -1},
	}
	if !allEnabledLyricSourcesResponded(full) {
		t.Error("三个启用的源都给出了候选(哪怕其中一份被判无效),应该算信息完整")
	}
	if got := lyricSourcesWithCandidates(full); len(got) != 2 {
		t.Errorf("lyricSourcesWithCandidates 仍应只收有效候选,got %v", got)
	}

	missing := []scoredLyricCandidateResult{
		{Source: "netease", Score: 173},
		{Source: "qq", Score: 582},
	}
	if allEnabledLyricSourcesResponded(missing) {
		t.Error("musixmatch 这轮压根没回来,不该算信息完整")
	}

	// 被禁用的源缺席不算数。
	if !allEnabledLyricSourcesResponded([]scoredLyricCandidateResult{
		{Source: "netease", Score: 1}, {Source: "qq", Score: 1}, {Source: "musixmatch", Score: 1},
	}) {
		t.Error("被禁用的 kugou 缺席不该影响判断")
	}
}

// rescoreDecidable 是这个功能能不能真正生效的关键闸。
//
// 2026-08-07 上线当天真机日志坐实:五源搜索 20 秒上限下**有源超时是常态**,原来那条
// "所有启用的源都回来了才算数"让同一首歌连着两次都 deferred,次数烧光、永远轮不到重选。
// 换成"当前这份歌词的来源这一轮回来了"就够 —— 它自己参与了新规则下的比较。
func TestRescoreDecidable(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.LyricsSources = map[string]bool{"netease": true, "qq": true, "musixmatch": true, "kugou": false}

	partial := []scoredLyricCandidateResult{
		{Source: "netease", Score: 173},
		{Source: "qq", Score: 582},
	}
	if !rescoreDecidable(partial, "netease") {
		t.Error("手上这份来自 netease、它这轮回来了:够格重选,不该因为 musixmatch 缺席就推迟")
	}
	if rescoreDecidable(partial, "musixmatch") {
		t.Error("手上这份来自 musixmatch、它这轮没回来:什么都不该动")
	}
	// 来源已被用户关掉 / 老条目压根没记来源:无从判断"手上这份"参没参与,退回严格口径。
	// 这一轮缺了 musixmatch,所以两种都不够格。
	if rescoreDecidable(partial, "kugou") {
		t.Error("来源已被关掉时退回严格口径,而这一轮缺了 musixmatch,不该够格")
	}
	if rescoreDecidable(partial, "") {
		t.Error("老条目没记来源时退回严格口径,而这一轮缺了 musixmatch,不该够格")
	}

	full := append(append([]scoredLyricCandidateResult{}, partial...),
		scoredLyricCandidateResult{Source: "musixmatch", Score: -1})
	if !rescoreDecidable(full, "") {
		t.Error("没记来源、但这一轮所有启用的源都回来了:够格")
	}
}
