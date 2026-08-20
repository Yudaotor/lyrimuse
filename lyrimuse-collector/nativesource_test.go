package main

import "testing"

// 同源加权：用户放 QQ 音乐时，偏向 QQ 自家的歌词。
//
// 理由是时间轴对齐同一个音频母版，不是内容质量 —— 所以权重刻意压在逐字时间轴之下，
// 见 match.go 里那一项的注释。
func TestNativeSourceBonus(t *testing.T) {
	const lrc = "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句\n"
	score := func(source string, wordTiming bool) int {
		return scoreLyricCandidate("周杰伦", "太阳之子", "", 0,
			lyricCandidate{source: source, lyrics: lrc, hasWordTiming: wordTiming}, false, 0)
	}

	saved := nativeLyricSource
	t.Cleanup(func() { nativeLyricSource = saved })

	// 识别不出播放器时一分不加，行为跟改动前完全一致。
	nativeLyricSource = ""
	base := score("qq", false)
	if got := score("kugou", false); got != base {
		t.Errorf("没有 native 源时不该有来源差异: qq=%d kugou=%d", base, got)
	}

	// 放 QQ 音乐 → QQ 那份加分，别家不加。
	nativeLyricSource = "qq"
	if got := score("qq", false); got != base+250 {
		t.Errorf("同源该加 250, got %d (base %d)", got, base)
	}
	if got := score("kugou", false); got != base {
		t.Errorf("非同源不该加分, got %d (base %d)", got, base)
	}

	// ⚠️ 最要紧的一条：同源加权**压不过**逐字时间轴。
	// 250 < 400 是故意的 —— 同源只说明轴大概率更准，不说明这份歌词完整正确。给到能压过
	// 质量项的量级，就会重演 2026-08-09 那次"按来源加分"的翻车（0 次变对、6 次变错）。
	if score("qq", false) >= score("kugou", true) {
		t.Errorf("同源无逐字不该赢过跨源有逐字: qq=%d kugou+yrc=%d",
			score("qq", false), score("kugou", true))
	}
	// 但同源 + 逐字必须赢过跨源 + 逐字（这正是用户那首歌该走到的结果）。
	if score("qq", true) <= score("kugou", true) {
		t.Errorf("同源+逐字该赢: qq=%d kugou=%d", score("qq", true), score("kugou", true))
	}
}

func TestPlayerNativeLyricSource(t *testing.T) {
	cases := map[string]string{
		playerQQMusic: "qq", playerNetease: "netease",
		// Apple Music / Spotify 不是这套里的歌词源，没有"同源"可言；auto 识别不出播放器，
		// 不该瞎猜。三者都必须返回空。
		playerAppleMusic: "", playerSpotify: "", playerAuto: "", "": "",
	}
	for player, want := range cases {
		if got := playerNativeLyricSource(player); got != want {
			t.Errorf("player %q → %q, want %q", player, got, want)
		}
	}
}

// 换播放器后，"当初见过同源候选却没选它"的歌该获得一次重来的机会 —— 哪怕它已经有逐字。
func TestNeedsLyricsRetry_NativeSourceMissedOut(t *testing.T) {
	saved := nativeLyricSource
	t.Cleanup(func() { nativeLyricSource = saved })
	nativeLyricSource = "qq"

	// 用户那首歌的形态：选了酷狗（带逐字），而 QQ 当初也答过。
	missed := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq", "lrclib"},
	}
	if !needsLyricsRetry(missed, 0, false) {
		t.Error("见过同源候选却没选它，该重试（这正是被『有逐字就不重试』挡死的那种）")
	}

	// 已经就是同源 → 没什么可换的。
	already := missed
	already.LyricsSource = "qq"
	if needsLyricsRetry(already, 0, false) {
		t.Error("已经是同源，不该重试")
	}

	// 同源当初压根没答过 → 重搜也变不出来。
	unseen := missed
	unseen.LyricsSourcesSeen = []string{"kugou", "lrclib"}
	if needsLyricsRetry(unseen, 0, false) {
		t.Error("同源没出现过，不该为它重试")
	}

	// ⚠️ 最要紧：用户手改过的绝不能被这条新路径重搜覆盖掉 —— 那是缓存里唯一不可恢复的东西。
	manual := missed
	manual.ManualLyrics = true
	if needsLyricsRetry(manual, 0, false) {
		t.Error("手改过的歌词绝不能重搜")
	}

	// 识别不出播放器时，行为跟改动前一致（有逐字就不重试）。
	nativeLyricSource = ""
	if needsLyricsRetry(missed, 0, false) {
		t.Error("没有 native 源时该维持原行为")
	}
}

// 预取用了另一个版本的时长做校验 → 真播放时长对不上就重选一次。
// 实锤案例：网易云《梦想家》Tango 2:44，Spotify 版 ~4:06，预取按 164s 选了短版歌词。
func TestNeedsLyricsRetry_DurationMismatch(t *testing.T) {
	saved := nativeLyricSource
	t.Cleanup(func() { nativeLyricSource = saved })
	nativeLyricSource = ""

	entry := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq"},
		ResolvedDurationSecs: 164,
	}
	if !needsLyricsRetry(entry, 246, false) {
		t.Error("164s 校验的歌词碰上 246s 的真实版本，该重选（哪怕有逐字）")
	}
	if needsLyricsRetry(entry, 166, false) {
		t.Error("差 2 秒是标注抖动，不该白跑网络")
	}
	// 旧条目没记校验时长 → 一律不回溯，别让一次升级把全库重新解析一遍。
	legacy := entry
	legacy.ResolvedDurationSecs = 0
	if needsLyricsRetry(legacy, 246, false) {
		t.Error("没记录校验时长的旧条目不触发")
	}
	// 真实时长未知（预取路径自己查缓存时）同样不触发。
	if needsLyricsRetry(entry, 0, false) {
		t.Error("真实时长未知不触发")
	}
	// 手改保护永远最高优先。
	manual := entry
	manual.ManualLyrics = true
	if needsLyricsRetry(manual, 246, false) {
		t.Error("手改过的歌词绝不能被时长错配重搜")
	}
}
