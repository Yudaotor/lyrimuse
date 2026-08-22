package main

import "testing"

// 酷狗音乐作为**播放器**接入(2026-08-21)。这一串是 Go 侧的身份契约:features.json 里的
// "player" 值、bundle id、以及 ListenBrainz 的 media_player 标签。跟 Swift 侧
// lyrimuse-selftest 那个「播放器契约」块守的是同一件事 —— 任一侧改了名而另一侧没跟上,
// 表现都是**静默失效**:用户选了酷狗,collector 认不出这个值就默默兜底成「自动识别」,
// 界面一切正常、只是选择没生效。
func TestKugouPlayerWiring(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })

	// "player" 字段必须被接受,不能被 resolvePlayer 当成认不出的值兜底掉。
	if got := resolvePlayer("kugou_music"); got != playerKugou {
		t.Errorf("resolvePlayer(kugou_music) = %q，期望 %q（认不出会静默退回自动识别）", got, playerKugou)
	}

	features.Player = playerKugou
	if got := expectedPlayerBundleID(); got != kugouMusicBundleID {
		t.Errorf("expectedPlayerBundleID() = %q，期望 %q", got, kugouMusicBundleID)
	}
	if got := mediaPlayerLabel(kugouMusicBundleID); got != "KuGou Music (macOS)" {
		t.Errorf("mediaPlayerLabel(固定播放器分支) = %q", got)
	}

	// 「自动识别」下靠 bundle id 认成员,漏登记的话酷狗在 auto 模式下会被当成"不是我们
	// 认识的播放器"整条丢掉。
	if !isKnownPlayerBundleID(kugouMusicBundleID) {
		t.Error("自动识别模式认不出酷狗的 bundle id")
	}
	features.Player = playerAuto
	if got := mediaPlayerLabel(kugouMusicBundleID); got != "KuGou Music (macOS)" {
		t.Errorf("mediaPlayerLabel(自动识别分支) = %q", got)
	}

	// 白捡的一项:酷狗本来就是五个歌词源之一,接入播放器顺带把同源加权也接上。
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

// 「自动识别」放开到任意 App(2026-08-21):口径是"用户显式信任",不是"一律接受"。
// 白名单同时挡着显示和打卡(isTracked),一律接受等于让视频/播客写进永久收听历史。
func TestTrustedPlayersWiring(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })

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

	features.TrustedPlayers = got

	// 准入:内置永远认、信任过的认、陌生的一律不认。
	for _, id := range []string{"com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID} {
		if !isAcceptedPlayerBundleID(id) {
			t.Errorf("内置播放器 %q 该被接受", id)
		}
	}
	if !isAcceptedPlayerBundleID("com.foobar.mac") {
		t.Error("信任过的 App 该被接受")
	}
	if !isAcceptedPlayerBundleID("com.some.player") {
		t.Error("名字为空不影响准入")
	}
	if isAcceptedPlayerBundleID("com.apple.Safari") {
		t.Error("陌生 App 默认不该被接受(这条就是「一条垃圾都进不来」)")
	}
	// isKnownPlayerBundleID 回答的是另一个问题(是不是**内置**),不该被信任列表污染
	if isKnownPlayerBundleID("com.foobar.mac") {
		t.Error("isKnownPlayerBundleID 只该认内置播放器,不看信任列表")
	}

	// ListenBrainz 的 media_player 标签:用 App 自己的名字,反查不到退回 bundle id ——
	// 绝不能谎报成 Apple Music(那会让来源统计彻底失真)。
	features.Player = playerAuto
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

// 「这不是一首歌」守卫(2026-08-21):信任的未知播放器上报空歌手名**或空专辑名** → 整条丢掉。
// 判据跟 isAdBreak 完全一致,区别只在作用域。四份真实样本见 trustedPlaybackNotASong 的注释。
func TestTrustedPlaybackNotASong(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	const arc = "company.thebrowser.Browser"
	features.TrustedPlayers = map[string]string{arc: "Arc"}

	// —— 真实样本:Arc 放视频 ——
	// ① 第一份(2026-08-21 17:57):artist 和 album 都空
	if !trustedPlaybackNotASong(arc, "", "") {
		t.Error("artist/album 都空,该判成不是一首歌")
	}
	// ② 第二份(19:12):YouTube 把**频道名**塞进 artist,album 仍然空 —— 这一条正是
	//    "只卡 artist 不够"的证据:数据形状跟"歌手 - 歌名"无法区分,只有 album 分得开
	if !trustedPlaybackNotASong(arc, "Dream in reality", "") {
		t.Error("YouTube 频道名进了 artist 但 album 空,仍该判成不是一首歌")
	}
	// 反向:只有 album 没有 artist 同样不算
	if !trustedPlaybackNotASong(arc, "", "某专辑") {
		t.Error("artist 空同样该丢掉")
	}
	// 纯空白等于空
	if !trustedPlaybackNotASong(arc, "   ", "某专辑") || !trustedPlaybackNotASong(arc, "某歌手", "  ") {
		t.Error("纯空白该按空处理")
	}

	// —— 真实样本:三个真音乐 App 都两个字段齐全 ——
	for _, c := range []struct{ artist, album string }{
		{"周杰伦", "七里香"},     // 酷狗
		{"方大同", "Soulboy"}, // Spotify / Apple Music
		{"卢广仲", "100种生活"},  // Apple Music
	} {
		if trustedPlaybackNotASong(arc, c.artist, c.album) {
			t.Errorf("两个字段都齐的不该被丢掉: %s / %s", c.artist, c.album)
		}
	}

	// 内置播放器不受这条守卫约束 —— 它们各有既有守卫(Spotify 广告走 isAdBreak),
	// 卷进来等于偷偷改既有行为。
	for _, id := range []string{"com.apple.Music", qqMusicBundleID, neteaseMusicBundleID, spotifyBundleID, kugouMusicBundleID} {
		if trustedPlaybackNotASong(id, "", "") {
			t.Errorf("内置播放器 %q 不该被这条守卫影响", id)
		}
	}
	// 压根没信任过的:由准入层负责挡,这里返回 false —— 别让它看起来像"因为字段空被挡",
	// 那会掩盖真实原因。
	if trustedPlaybackNotASong("com.apple.Safari", "", "") {
		t.Error("没信任过的 App 由准入层负责挡,不该在这条守卫里返回 true")
	}
}
