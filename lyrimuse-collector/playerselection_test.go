package main

import "testing"

// 播放器多选——设置页"播放器"卡可以同时勾好几个具体播放器,也可以额外勾"自动识别"。这一串盯的是
// 共享 JSON 里播放器列表的解析(老写法的迁移只在 App 做)。这一拍算不算数只在 App 判,
// 见 TestIsTrackedTrustsTheAppsPlayer。

func TestResolvePlayersFallsBackToAuto(t *testing.T) {
	// 一个能收的都没有(nil / 空 / 全认不出)→ 兜底 auto。空集不是合法状态。
	for _, list := range [][]string{nil, {}, {"some_removed_player"}} {
		if got := resolvePlayers(list); len(got) != 1 || !got[playerAuto] {
			t.Errorf("resolvePlayers(%v) = %v，期望兜底 {auto}", list, got)
		}
	}
	// 遗留的单选键 "player" 不认:迁移只在 App 做(加载设置时改写成 players 整份写回)。
	if got := loadFeatureFlagsFromJSON(t, `{"player":"qq_music"}`).Players; len(got) != 1 || !got[playerAuto] {
		t.Errorf("遗留 player 键不该被引擎迁移, got %v", got)
	}
}

func TestResolvePlayersAcceptsMultiSelect(t *testing.T) {
	got := resolvePlayers([]string{"qq_music", "kugou_music"})
	if len(got) != 2 || !got[playerQQMusic] || !got[playerKugou] {
		t.Errorf("resolvePlayers([qq,kugou]) = %v，期望恰好 {qq, kugou}", got)
	}
	// 列表里混了认不出的值:能认的留下，认不出的丢掉。
	got = resolvePlayers([]string{"qq_music", "some_removed_player"})
	if len(got) != 1 || !got[playerQQMusic] {
		t.Errorf("resolvePlayers([qq,认不出]) = %v，期望只留 {qq}", got)
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
