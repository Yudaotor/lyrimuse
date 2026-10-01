package main

import "testing"

// 播放器多选——设置页"播放器"卡从单选改成多选,用户可以同时勾
// 好几个具体播放器(高亮显示),也可以额外勾"自动识别"。这一串盯的是共享 JSON 的
// 迁移路径,跟 Swift 侧 lyrimuse-selftest 的「播放器多选」块守的是同一份契约。这一拍算不算数只在 App 判,
// 见 TestIsTrackedTrustsTheAppsPlayer。

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

// 这一拍算不算数只在 App 判:App 只把它认下的播放器写进播放状态,引擎不再按选中集合复核。选中集合、信任列表
// 之外的播放器只要出现在 App 状态里就算数;没有曲目才不算。
func TestIsTrackedTrustsTheAppsPlayer(t *testing.T) {
	savedPlayers, savedTrusted := features().Players, features().TrustedPlayers
	t.Cleanup(func() { featuresRef().Players, featuresRef().TrustedPlayers = savedPlayers, savedTrusted })
	featuresRef().Players = map[string]bool{playerQQMusic: true}
	featuresRef().TrustedPlayers = nil

	for _, bundle := range []string{qqMusicBundleID, spotifyBundleID, "com.apple.WebKit.GPU", "com.example.player"} {
		p := &poller{cfg: &config{}, cur: snapshot{Title: "曲目", Artist: "歌手", Bundle: bundle}}
		if !p.isTracked() {
			t.Errorf("%s 出现在 App 状态里就该算数", bundle)
		}
	}
	if (&poller{cfg: &config{}}).isTracked() {
		t.Error("没有曲目不算")
	}
}

func TestIsTrustedPlayerBundleID(t *testing.T) {
	saved := features().TrustedPlayers
	t.Cleanup(func() { featuresRef().TrustedPlayers = saved })

	featuresRef().TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}
	if !isTrustedPlayerBundleID("com.google.Chrome") {
		t.Error("信任列表里的 bundle id 该被认")
	}
	if isTrustedPlayerBundleID("com.apple.Safari") {
		t.Error("没信任过的 bundle id 不该被认")
	}
	if isTrustedPlayerBundleID(qqMusicBundleID) {
		t.Error("isTrustedPlayerBundleID 只回答信任这一半,内置播放器不该被它认下来" +
			"(那是 isKnownPlayerBundleID 的职责)")
	}

	featuresRef().TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}
	if !isTrustedPlayerBundleID("com.apple.WebKit.GPU") {
		t.Error("信任 Safari 之后,它的媒体代理进程 com.apple.WebKit.GPU 该经别名表被认")
	}
}
