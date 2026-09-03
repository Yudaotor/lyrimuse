package main

import (
	"os"
	"strings"
	"testing"
)

// 2026-09-02 真实bug(王力宏《你不知道的事》Safari 网页播放,「歌词管理」占位行永远停在
// "搜索歌词中…"):Safari 播网页音频时 MediaRemote 报的是媒体代理进程 com.apple.WebKit.GPU,
// 信任表里存的是宿主 com.apple.Safari——system.go 里三处**裸查** features.TrustedPlayers[
// bundleID] 的地方对 Safari 全部落空(getAutoDetectedState 把播放整条丢掉、
// trustedPlaybackNotASong 守卫恒不生效、mediaPlayerLabel 谎报成 Apple Music),而 Swift 侧
// TrustedPlayers.isTrusted 做了代理解析、App 认了这首歌,于是 App 一直等一个 collector
// 永远不会去做的解析。Chrome/Arc 报浏览器自己的 bundle id、直接在表里,所以从来没暴露。
// 这组测试钉住三处修复对代理进程的行为。
func TestSafariMediaProxyTrustResolution(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}

	const proxy = "com.apple.WebKit.GPU"

	t.Run("信任判定经代理别名解析", func(t *testing.T) {
		if !isTrustedPlayerBundleID(proxy) {
			t.Error("WebKit.GPU 该按宿主 Safari 算成受信任")
		}
	})

	t.Run("notASong 守卫对代理进程同样生效", func(t *testing.T) {
		// Safari 播非歌曲视频(album 恒为空,同 Arc 的实测形态)→ 该被守卫丢掉。
		if !trustedPlaybackNotASong(proxy, "某个频道名", "") {
			t.Error("Safari(代理进程)播 album 为空的内容,该判成不是一首歌")
		}
		// 真歌两个字段齐全 → 放行。
		if trustedPlaybackNotASong(proxy, "王力宏", "十八般武藝") {
			t.Error("字段齐全的真歌不该被丢掉")
		}
	})

	t.Run("media_player 标签按宿主名报,不谎报 Apple Music", func(t *testing.T) {
		if got := mediaPlayerLabel(proxy); got != "Safari (macOS)" {
			t.Errorf("Safari 代理进程的标签 = %q,期望 Safari (macOS)", got)
		}
	})

	t.Run("Safari 没被信任时代理进程照旧不认", func(t *testing.T) {
		features.TrustedPlayers = map[string]string{}
		defer func() { features.TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"} }()
		if isTrustedPlayerBundleID(proxy) {
			t.Error("宿主不在信任表里时代理进程也不该被信任")
		}
		if trustedPlaybackNotASong(proxy, "", "") {
			t.Error("没信任过的由准入层负责挡,这条守卫该返回 false")
		}
	})
}

// 源码级守卫:system.go 里对 features.TrustedPlayers 用 bundleID 直接下标的裸查,只允许
// 存在于 isTrustedPlayerBundleID 内部那一处(它是唯一被授权直查的地方,别名解析就在它
// 身上)。这次三处同型 bug 说明这个坑非常容易再挖——新代码要判信任,一律调
// isTrustedPlayerBundleID / isAcceptedPlayerBundleID,别自己查表。
func TestNoNakedTrustedPlayersLookupInSystemGo(t *testing.T) {
	src, err := os.ReadFile("system.go")
	if err != nil {
		t.Fatalf("读 system.go: %v", err)
	}
	// 逐行数、跳过注释行——修复注释里如实引用了这个模式的字面量,不该被算进去。
	n := 0
	for _, line := range strings.Split(string(src), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "//") {
			continue
		}
		n += strings.Count(line, "features.TrustedPlayers[bundleID]")
	}
	if n > 1 {
		t.Errorf("system.go 里出现 %d 处 features.TrustedPlayers[bundleID] 裸查,只允许 "+
			"isTrustedPlayerBundleID 内部那 1 处——新代码请改调 isTrustedPlayerBundleID,"+
			"否则 Safari(媒体代理进程 com.apple.WebKit.GPU)会在你的判定里恒不受信任", n)
	}
}
