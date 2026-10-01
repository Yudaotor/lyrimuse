package main

import "testing"

func trackedWith(t *testing.T, players map[string]bool, trusted map[string]string, bundleID string) bool {
	t.Helper()
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().Players = players
	featuresRef().TrustedPlayers = trusted
	p := &poller{cur: snapshot{Title: "Song", Artist: "Singer", Bundle: bundleID}}
	return p.isTracked()
}

// 选了自动识别时,isTracked 的准入不能是一份**手抄**的 bundle id 列表:新播放器加进 players.json 后若这里没跟上,
// 它的播放会被当成"不相关 App"整条丢掉 —— collector 认为什么都没在放、永远不去解析,App 侧照常显示曲目并挂着
// 「搜索歌词中…」占位。所以逐个遍历生成的 playerBundleIDs,任何一个内置播放器不被认下都失败。
func TestAutoDetectAdmitsEveryBuiltinPlayer(t *testing.T) {
	if len(playerBundleIDs) == 0 {
		t.Fatal("playerBundleIDs 是空的,generate 那步没跑?")
	}
	for player, bundleID := range playerBundleIDs {
		if !trackedWith(t, map[string]bool{playerAuto: true}, map[string]string{}, bundleID) {
			t.Errorf("内置播放器 %q(%s)没被自动识别认下 —— 准入判断又跟 players.json 脱节了", player, bundleID)
		}
	}
}

// 信任列表里的播放器(配对过的浏览器)在自动识别和具体选中两种模式下都认;Safari 报的媒体代理进程按宿主算。
func TestTrackedAdmitsTrustedPlayers(t *testing.T) {
	trusted := map[string]string{"com.google.Chrome": "Chrome", "com.apple.Safari": "Safari"}
	for _, players := range []map[string]bool{{playerAuto: true}, {playerAppleMusic: true}} {
		if !trackedWith(t, players, trusted, "com.google.Chrome") || !trackedWith(t, players, trusted, "com.apple.WebKit.GPU") {
			t.Errorf("%v: 信任过的浏览器要认", players)
		}
	}
}

// 具体选中了几个播放器时只认这几个(加上信任列表);没选的内置播放器不认。
func TestTrackedSelectedPlayersOnly(t *testing.T) {
	selected := map[string]bool{playerAppleMusic: true, playerSpotify: true}
	if !trackedWith(t, selected, map[string]string{}, appleMusicBundleID) || !trackedWith(t, selected, map[string]string{}, spotifyBundleID) {
		t.Error("选中的播放器要认")
	}
	if trackedWith(t, selected, map[string]string{}, sodaMusicBundleID) {
		t.Error("没选中的内置播放器不认")
	}
}

// 反面:不在名单里、也没被信任过的 App 仍要被挡住 —— 准入没有宽到"谁报 Now Playing 就认谁"。
func TestAutoDetectStillRejectsUnrelatedApps(t *testing.T) {
	for _, bundleID := range []string{"com.apple.QuickTimePlayerX", "com.google.Chrome", ""} {
		if trackedWith(t, map[string]bool{playerAuto: true}, map[string]string{}, bundleID) {
			t.Errorf("%q 既不是内置播放器也没被信任过,该被拒", bundleID)
		}
	}
	if (&poller{}).isTracked() {
		t.Error("没在放就不算")
	}
}
