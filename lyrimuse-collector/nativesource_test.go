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

	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })

	// 识别不出播放器时一分不加，行为跟改动前完全一致。
	nativeLyricSources = nil
	base := score("qq", false)
	if got := score("kugou", false); got != base {
		t.Errorf("没有 native 源时不该有来源差异: qq=%d kugou=%d", base, got)
	}

	// 放 QQ 音乐 → QQ 那份加分，别家不加。
	nativeLyricSources = map[string]bool{"qq": true}
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

// 2026-09-01 多选后新增:resolveNativeLyricSources 要把选中集合里每个成员各自的原生源
// 都收进来,不是只挑一个——同时用 QQ 音乐和酷狗听歌的人,两边的同源加权都该生效。
func TestResolveNativeLyricSources(t *testing.T) {
	got := resolveNativeLyricSources(map[string]bool{playerQQMusic: true, playerKugou: true})
	if len(got) != 2 || !got["qq"] || !got["kugou"] {
		t.Errorf("resolveNativeLyricSources({qq,kugou}) = %v，期望恰好 {qq, kugou}", got)
	}
	// Apple Music/Spotify/auto 不贡献任何源,混进去不该多出条目、也不该 panic。
	got = resolveNativeLyricSources(map[string]bool{playerQQMusic: true, playerAppleMusic: true, playerAuto: true})
	if len(got) != 1 || !got["qq"] {
		t.Errorf("resolveNativeLyricSources({qq,apple,auto}) = %v，期望恰好 {qq}", got)
	}
	// 全是不贡献源的成员 → 空集,不是 nil 判断失败/panic。
	if got := resolveNativeLyricSources(map[string]bool{playerAuto: true}); len(got) != 0 {
		t.Errorf("resolveNativeLyricSources({auto}) = %v，期望空集", got)
	}
}

// 换播放器后，"当初见过同源候选却没选它"的歌该获得一次重来的机会 —— 哪怕它已经有逐字。
func TestNeedsLyricsRetry_NativeSourceMissedOut(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })
	nativeLyricSources = map[string]bool{"qq": true}

	// 用户那首歌的形态：选了酷狗（带逐字），而 QQ 当初也答过。
	missed := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq", "lrclib"},
	}
	if !needsLyricsRetry(missed, false, false) {
		t.Error("见过同源候选却没选它，该重试（这正是被『有逐字就不重试』挡死的那种）")
	}

	// 已经就是同源 → 没什么可换的。
	already := missed
	already.LyricsSource = "qq"
	if needsLyricsRetry(already, false, false) {
		t.Error("已经是同源，不该重试")
	}

	// 同源当初压根没答过 → 重搜也变不出来。
	unseen := missed
	unseen.LyricsSourcesSeen = []string{"kugou", "lrclib"}
	if needsLyricsRetry(unseen, false, false) {
		t.Error("同源没出现过，不该为它重试")
	}

	// ⚠️ 最要紧：用户手改过的绝不能被这条新路径重搜覆盖掉 —— 那是缓存里唯一不可恢复的东西。
	manual := missed
	manual.ManualLyrics = true
	if needsLyricsRetry(manual, false, false) {
		t.Error("手改过的歌词绝不能重搜")
	}

	// 识别不出播放器时，行为跟改动前一致（有逐字就不重试）。
	nativeLyricSources = nil
	if needsLyricsRetry(missed, false, false) {
		t.Error("没有 native 源时该维持原行为")
	}
}

// 预取用了另一个版本的时长做校验 → 真播放时长对不上就重选一次。
// 实锤案例：网易云《梦想家》Tango 2:44，Spotify 版 ~4:06，预取按 164s 选了短版歌词。
//
// 签名 2026-08-22 改:mismatch 由调用方(trackEnrichment)用 durationMismatch 算好、
// 再过 observeWrongDuration 去抖后以 bool 传入。这里按同样方式组合两个函数,保住
// "从时长差到重试判定"这条链路的覆盖(去抖本身另有 TestObserveWrongDuration)。
func TestNeedsLyricsRetry_DurationMismatch(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })
	nativeLyricSources = nil

	entry := enrichEntry{
		Lyrics: "[00:01.00]x", LyricsYRC: "[1,2](1,1,0)x",
		LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "qq"},
		ResolvedDurationSecs: 164,
	}
	retryAt := func(e enrichEntry, actual float64) bool {
		return needsLyricsRetry(e, durationMismatch(e.ResolvedDurationSecs, actual), false)
	}
	if !retryAt(entry, 246) {
		t.Error("164s 校验的歌词碰上 246s 的真实版本，该重选（哪怕有逐字）")
	}
	if retryAt(entry, 166) {
		t.Error("差 2 秒是标注抖动，不该白跑网络")
	}
	// 旧条目没记校验时长 → 一律不回溯，别让一次升级把全库重新解析一遍。
	legacy := entry
	legacy.ResolvedDurationSecs = 0
	if retryAt(legacy, 246) {
		t.Error("没记录校验时长的旧条目不触发")
	}
	// 真实时长未知（预取路径自己查缓存时）同样不触发。
	if retryAt(entry, 0) {
		t.Error("真实时长未知不触发")
	}
	// 手改保护永远最高优先。
	manual := entry
	manual.ManualLyrics = true
	if retryAt(manual, 246) {
		t.Error("手改过的歌词绝不能被时长错配重搜")
	}
}
