package main

import "testing"

// 播放器多选(2026-09-01)——设置页"播放器"卡从单选改成多选,用户可以同时勾
// 好几个具体播放器(高亮显示),也可以额外勾"自动识别"。这一串盯的是共享 JSON 的
// 迁移路径 + isTracked() 的多选/自动识别组合判定,跟 Swift 侧 lyrimuse-selftest
// 的「播放器多选」块守的是同一份契约。

func TestResolvePlayersMigratesLegacySingleValue(t *testing.T) {
	// 老配置(升级前只写了 "player" 单值,从没写过 "players")：迁移成对应的单元素集合。
	if got := resolvePlayers(nil, "qq_music"); len(got) != 1 || !got[playerQQMusic] {
		t.Errorf("resolvePlayers(nil, qq_music) = %v，期望迁移成 {qq_music}", got)
	}
	// "players" 是空 slice(不是 nil,但也没有可用值)同样该走迁移路径,不能被
	// "非 nil 就信它"误判成"用户显式选了空集"——空集不是一个合法状态。
	if got := resolvePlayers([]string{}, "spotify"); len(got) != 1 || !got[playerSpotify] {
		t.Errorf("resolvePlayers([], spotify) = %v，期望迁移成 {spotify}", got)
	}
	// "players" 里全是认不出的值(比如以后下线了某个播放器,旧文件还留着字符串)
	// 同样退回 legacy 迁移，而不是把认不出的原样收进结果集。
	if got := resolvePlayers([]string{"some_removed_player"}, "netease_music"); len(got) != 1 || !got[playerNetease] {
		t.Errorf("resolvePlayers([认不出的值], netease_music) = %v，期望迁移成 {netease_music}", got)
	}
	// legacy 也认不出(全新安装/文件损坏)→ 最终兜底 auto。
	if got := resolvePlayers(nil, ""); len(got) != 1 || !got[playerAuto] {
		t.Errorf("resolvePlayers(nil, \"\") = %v，期望兜底 {auto}", got)
	}
}

func TestResolvePlayersAcceptsMultiSelect(t *testing.T) {
	// 新格式:"players" 里有值就直接用,忽略 legacy——不是"两边取并集"。
	got := resolvePlayers([]string{"qq_music", "kugou_music"}, "apple_music")
	if len(got) != 2 || !got[playerQQMusic] || !got[playerKugou] {
		t.Errorf("resolvePlayers([qq,kugou], apple) = %v，期望恰好 {qq, kugou}（legacy 不该混进来）", got)
	}
	// 列表里混了认不出的值:能认的留下，认不出的丢掉,不因为其中一个有效就整体接受
	// 也不因为其中一个无效就整体退回 legacy。
	got = resolvePlayers([]string{"qq_music", "some_removed_player"}, "spotify")
	if len(got) != 1 || !got[playerQQMusic] {
		t.Errorf("resolvePlayers([qq,认不出], spotify) = %v，期望只留 {qq}", got)
	}
}

// isTracked() 的多选/自动识别组合判定——跟 Swift 侧 MediaControlClient.fetchSnapshot
// 的多选解析是同一份设计:auto 是超集,选了 auto 就按"内置+信任列表"整套准入判断,
// 不管有没有额外勾了别的具体播放器；没有 auto 时按选中集合逐个比对 bundle id。
func TestIsTrackedMultiSelect(t *testing.T) {
	saved := features.Players
	t.Cleanup(func() { features.Players = saved })

	newPoller := func(bundle string) *poller {
		return &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Bundle: bundle}}
	}

	// 单选 qq_music：只认它自己的 bundle id，别的一律不认。
	features.Players = map[string]bool{playerQQMusic: true}
	if !newPoller(qqMusicBundleID).isTracked() {
		t.Error("单选 qq_music 时,qq 自己的 bundle 该被认")
	}
	if newPoller(neteaseMusicBundleID).isTracked() {
		t.Error("单选 qq_music 时,网易云的 bundle 不该被认")
	}

	// 多选 {qq_music, kugou_music}：两个都认,其它仍不认。
	features.Players = map[string]bool{playerQQMusic: true, playerKugou: true}
	if !newPoller(qqMusicBundleID).isTracked() {
		t.Error("多选 {qq,kugou} 时,qq 该被认")
	}
	if !newPoller(kugouMusicBundleID).isTracked() {
		t.Error("多选 {qq,kugou} 时,kugou 该被认")
	}
	if newPoller(spotifyBundleID).isTracked() {
		t.Error("多选 {qq,kugou} 时,没选中的 spotify 不该被认")
	}

	// 多选 {qq_music, auto}：auto 是超集,内置五个播放器全认（不局限于 qq 一个）,
	// 陌生 App 仍然不认(除非进了信任列表,这里没配)。
	features.Players = map[string]bool{playerQQMusic: true, playerAuto: true}
	if !newPoller(spotifyBundleID).isTracked() {
		t.Error("多选 {qq,auto} 时,auto 该把内置的 spotify 也认下来(超集语义)")
	}
	if newPoller("com.apple.Safari").isTracked() {
		t.Error("多选 {qq,auto} 时,没信任过的陌生 App 仍不该被认")
	}
}

// 2026-09-01 补:信任列表(最典型场景是「网页播放器」卡配对的浏览器)必须在**没有勾
// 自动识别**时也生效——配对浏览器这个动作跟"选没选自动识别"是两件独立的事,用户没有
// 理由因为只选了具体播放器就让配对形同虚设。
func TestIsTrackedMultiSelectHonorsTrustedPlayersWithoutAuto(t *testing.T) {
	savedPlayers, savedTrusted := features.Players, features.TrustedPlayers
	t.Cleanup(func() { features.Players, features.TrustedPlayers = savedPlayers, savedTrusted })

	const chrome = "com.google.Chrome"
	features.Players = map[string]bool{playerQQMusic: true} // 没有 auto
	features.TrustedPlayers = map[string]string{chrome: "Chrome"}

	trusted := &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Album: "专辑", Bundle: chrome}}
	if !trusted.isTracked() {
		t.Error("没勾自动识别时,信任列表里的浏览器(网页播放器卡配对)仍应被认")
	}

	untrusted := &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Album: "专辑", Bundle: "com.apple.Safari"}}
	if untrusted.isTracked() {
		t.Error("没被信任过的 App 不该因为这条新路径被放行")
	}

	// Safari 走媒体代理别名(报告方是 com.apple.WebKit.GPU,信任的是 com.apple.Safari)。
	features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}
	viaProxy := &poller{cfg: &config{}, cur: snapshot{
		Title: "曲目", Artist: "歌手", Album: "专辑", Bundle: "com.apple.WebKit.GPU"}}
	if !viaProxy.isTracked() {
		t.Error("信任了 Safari 之后,它的媒体代理进程 com.apple.WebKit.GPU 也该被认")
	}
}

func TestIsTrustedPlayerBundleID(t *testing.T) {
	saved := features.TrustedPlayers
	t.Cleanup(func() { features.TrustedPlayers = saved })

	features.TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}
	if !isTrustedPlayerBundleID("com.google.Chrome") {
		t.Error("信任列表里的 bundle id 该被认")
	}
	if isTrustedPlayerBundleID("com.apple.Safari") {
		t.Error("没信任过的 bundle id 不该被认")
	}
	if isTrustedPlayerBundleID(qqMusicBundleID) {
		t.Error("isTrustedPlayerBundleID 只回答信任这一半,内置播放器不该被它认下来" +
			"(那是 isAcceptedPlayerBundleID/isKnownPlayerBundleID 的职责)")
	}

	features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}
	if !isTrustedPlayerBundleID("com.apple.WebKit.GPU") {
		t.Error("信任 Safari 之后,它的媒体代理进程 com.apple.WebKit.GPU 该经别名表被认")
	}
}
