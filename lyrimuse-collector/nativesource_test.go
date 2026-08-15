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
