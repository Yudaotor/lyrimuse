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

// 2026-09-02:同源加权的判据从「用户勾了哪些播放器」换成「**这一刻在放的是哪个**」。
//
// (这里原来是 TestResolveNativeLyricSources,钉的是 2026-09-01 多选那次的行为:
//  「选中集合里每个成员各自的原生源都收进来」。那个函数连同它的判据一起删了 —— 它对
//  别的按播放器分叉的功能成立,对**这一项**不成立,理由见 match.go 里 nativeLyricSources
//  的注释:这一项的立论是"时间轴对着同一份音频母版",那是正在播的那个播放器的属性。)
func TestPlayerForBundleID(t *testing.T) {
	cases := map[string]string{
		appleMusicBundleID:   playerAppleMusic,
		qqMusicBundleID:      playerQQMusic,
		neteaseMusicBundleID: playerNetease,
		spotifyBundleID:      playerSpotify,
		kugouMusicBundleID:   playerKugou,
		// ⚠️ 认不出必须是"不知道"(空串),不能是"就当是 Apple Music"—— playerBundleID
		// 那个反方向的函数 default 分支返回 appleMusicBundleID,照抄过来就会把任何浏览器/
		// 第三方 App 都认成 Apple Music。
		"com.google.Chrome": "",
		"":                  "",
	}
	for bundleID, want := range cases {
		if got := playerForBundleID(bundleID); got != want {
			t.Errorf("playerForBundleID(%q) = %q, want %q", bundleID, got, want)
		}
	}
}

func TestSetNativeLyricSourcesForPlayer(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })

	// ⚠️ 用户报的那个 bug 的形状:设置里六个播放器全勾,但实际在放 Apple Music。
	// 旧判据(按 features.Players)会得出 {kugou, netease, qq} —— 三个源同时 +250,
	// 而「解析决策」面板上那句"这个源就是你正在用的播放器"对三个都是假话。
	// 新判据只看在放的那个:Apple Music 没有原生歌词源 → 空集,谁都不加。
	setNativeLyricSourcesForPlayer(appleMusicBundleID)
	if hasNativeLyricSource() {
		t.Errorf("放 Apple Music 时不该有任何同源加权,got %v", nativeLyricSources)
	}
	for _, src := range []string{"qq", "netease", "kugou"} {
		if isNativeLyricSource(src) {
			t.Errorf("放 Apple Music 时 %q 不该被判成同源", src)
		}
	}

	// 放 QQ 音乐:只有 qq 一个,不能顺带把别的中文源也算进去。
	setNativeLyricSourcesForPlayer(qqMusicBundleID)
	if !isNativeLyricSource("qq") {
		t.Error("放 QQ 音乐时 qq 应当判为同源")
	}
	if isNativeLyricSource("netease") || isNativeLyricSource("kugou") {
		t.Errorf("放 QQ 音乐时只该有 qq 一个,got %v", nativeLyricSources)
	}

	// 换播放器要**换掉**而不是累积 —— 累积就退化成旧那个"多个源同时加"的形状了。
	setNativeLyricSourcesForPlayer(kugouMusicBundleID)
	if !isNativeLyricSource("kugou") || isNativeLyricSource("qq") {
		t.Errorf("换到酷狗之后应当恰好只剩 kugou,got %v", nativeLyricSources)
	}

	// Spotify 跟 Apple Music 同类:接进来了,但不是这套里的歌词源,没有"同源"可言。
	setNativeLyricSourcesForPlayer(spotifyBundleID)
	if hasNativeLyricSource() {
		t.Errorf("放 Spotify 时不该有任何同源加权,got %v", nativeLyricSources)
	}

	// 认不出的 bundle id(浏览器网页版等)同样是空集,不能兜底成某个源。
	setNativeLyricSourcesForPlayer("com.google.Chrome")
	if hasNativeLyricSource() {
		t.Errorf("认不出的播放器不该有同源加权,got %v", nativeLyricSources)
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
	if !needsLyricsRetry(missed, false, false, true) {
		t.Error("见过同源候选却没选它，该重试（这正是被『有逐字就不重试』挡死的那种）")
	}

	// 已经就是同源 → 没什么可换的。
	already := missed
	already.LyricsSource = "qq"
	if needsLyricsRetry(already, false, false, true) {
		t.Error("已经是同源，不该重试")
	}

	// 同源当初压根没答过 → 重搜也变不出来。
	unseen := missed
	unseen.LyricsSourcesSeen = []string{"kugou", "lrclib"}
	if needsLyricsRetry(unseen, false, false, true) {
		t.Error("同源没出现过，不该为它重试")
	}

	// ⚠️ 最要紧：用户手改过的绝不能被这条新路径重搜覆盖掉 —— 那是缓存里唯一不可恢复的东西。
	manual := missed
	manual.ManualLyrics = true
	if needsLyricsRetry(manual, false, false, true) {
		t.Error("手改过的歌词绝不能重搜")
	}

	// 识别不出播放器时，行为跟改动前一致（有逐字就不重试）。
	nativeLyricSources = nil
	if needsLyricsRetry(missed, false, false, true) {
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
		return needsLyricsRetry(e, durationMismatch(e.ResolvedDurationSecs, actual), false, true)
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
