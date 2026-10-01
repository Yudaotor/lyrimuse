package main

import "testing"

// 酷狗音乐作为**播放器**接入。这一串是 Go 侧的身份契约:features.json 里的
// "player" 值、bundle id、以及 ListenBrainz 的 media_player 标签。跟 Swift 侧
// lyrimuse-selftest 那个「播放器契约」块守的是同一件事 —— 任一侧改了名而另一侧没跟上,
// 表现都是**静默失效**:用户选了酷狗,collector 认不出这个值就默默兜底成「自动识别」,
// 界面一切正常、只是选择没生效。
func TestKugouPlayerWiring(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })

	// "players" 字段里的值必须被接受,不能被 resolvePlayers 当成认不出的值兜底掉。
	if got := resolvePlayers([]string{"kugou_music"}, ""); !got[playerKugou] {
		t.Errorf("resolvePlayers([kugou_music]) = %v，期望包含 %q（认不出会静默退回自动识别）", got, playerKugou)
	}

	featuresRef().Players = map[string]bool{playerKugou: true}
	if got := playerBundleIDs[playerKugou]; got != kugouMusicBundleID {
		t.Errorf("playerBundleIDs[kugou] = %q，期望 %q", got, kugouMusicBundleID)
	}
	if got := mediaPlayerLabel(kugouMusicBundleID); got != "Kugou Music (macOS)" {
		t.Errorf("mediaPlayerLabel(固定播放器分支) = %q", got)
	}

	// 内置播放器要认得出:信任播放器那套署名纠正按它把内置的排除掉,酷狗走自己那一套。
	if !isKnownPlayerBundleID(kugouMusicBundleID) {
		t.Error("认不出酷狗是内置播放器")
	}
	featuresRef().Players = map[string]bool{playerAuto: true}
	if got := mediaPlayerLabel(kugouMusicBundleID); got != "Kugou Music (macOS)" {
		t.Errorf("mediaPlayerLabel(自动识别分支) = %q", got)
	}

	// 白捡的一项:酷狗本来就是歌词源之一,接入播放器顺带把同源加权也接上。
	if got := playerNativeLyricSource(playerKugou); got != "kugou" {
		t.Errorf("playerNativeLyricSource(酷狗) = %q，期望 kugou", got)
	}

	// bundle id 不能跟别的播放器撞车(复制粘贴加播放器时最容易犯)。
	ids := map[string]string{
		"apple":   "com.apple.Music",
		"qq":      qqMusicBundleID,
		"netease": neteaseMusicBundleID,
		"spotify": spotifyBundleID,
		"kugou":   kugouMusicBundleID,
	}
	seen := map[string]string{}
	for name, id := range ids {
		if prev, dup := seen[id]; dup {
			t.Errorf("bundle id 撞车: %s 和 %s 都是 %q", prev, name, id)
		}
		seen[id] = name
	}
}

// 「自动识别」放开到任意 App:口径是"用户显式信任",不是"一律接受"。白名单在 App 那边同时挡着显示和打卡
// (引擎只记 App 认下的播放),一律接受等于让视频/播客写进永久收听历史。这里钉引擎这一侧:信任列表的清洗、
// 内置 / 信任两种身份的判定、上报标签。
func TestTrustedPlayersWiring(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })

	// 清洗:空 bundle id 丢掉、首尾空白去掉、内置播放器剔掉(它们本来就认,
	// 留在名单里只会让"已信任"列表看起来莫名多几条)。
	got := resolveTrustedPlayers(map[string]string{
		"  com.foobar.mac  ": "  Foobar2000  ",
		"":                   "空 id 该被丢掉",
		"com.apple.Music":    "内置,该被剔掉",
		qqMusicBundleID:      "内置,该被剔掉",
		kugouMusicBundleID:   "内置,该被剔掉",
		"com.some.player":    "",
	})
	if len(got) != 2 {
		t.Fatalf("清洗后应剩 2 条,实得 %d: %v", len(got), got)
	}
	if got["com.foobar.mac"] != "Foobar2000" {
		t.Errorf("首尾空白没去掉: %q", got["com.foobar.mac"])
	}
	if name, ok := got["com.some.player"]; !ok || name != "" {
		t.Errorf("名字为空的条目该保留(名字只影响标签、不影响准入): %v", got)
	}
	if resolveTrustedPlayers(nil) != nil || resolveTrustedPlayers(map[string]string{}) != nil {
		t.Error("空输入该返回 nil(调用方一律用 m[k] 取值,nil map 是合法零值读取)")
	}

	featuresRef().TrustedPlayers = got

	// 身份:内置的认作内置、信任过的认作信任、陌生的两样都不是。
	for _, id := range []string{"com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID} {
		if !isKnownPlayerBundleID(id) {
			t.Errorf("内置播放器 %q 该被认作内置", id)
		}
	}
	if !isTrustedPlayerBundleID("com.foobar.mac") {
		t.Error("信任过的 App 该被认作信任")
	}
	if !isTrustedPlayerBundleID("com.some.player") {
		t.Error("名字为空不影响信任")
	}
	if isKnownPlayerBundleID("com.apple.Safari") || isTrustedPlayerBundleID("com.apple.Safari") {
		t.Error("陌生 App 既不是内置的也不是信任的")
	}
	// isKnownPlayerBundleID 回答的是另一个问题(是不是**内置**),不该被信任列表污染
	if isKnownPlayerBundleID("com.foobar.mac") {
		t.Error("isKnownPlayerBundleID 只该认内置播放器,不看信任列表")
	}

	// ListenBrainz 的 media_player 标签:用 App 自己的名字,反查不到退回 bundle id ——
	// 绝不能谎报成 Apple Music(那会让来源统计彻底失真)。mediaPlayerLabel
	// 只看传入的 bundleID + TrustedPlayers,不再看 features().Players,这里不需要设置
	// 它,保留旧断言只是确认这条不变量继续成立。
	if got := mediaPlayerLabel("com.foobar.mac"); got != "Foobar2000 (macOS)" {
		t.Errorf("信任 App 的标签 = %q,期望 Foobar2000 (macOS)", got)
	}
	if got := mediaPlayerLabel("com.some.player"); got != "com.some.player (macOS)" {
		t.Errorf("名字为空时该退回 bundle id,实得 %q", got)
	}
	if got := mediaPlayerLabel("com.apple.Safari"); got != "Apple Music (macOS)" {
		t.Errorf("没信任的 App 走原有兜底,实得 %q", got)
	}
}
