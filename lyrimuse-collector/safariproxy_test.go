package main

import (
	"os"
	"strings"
	"testing"
)

// Safari 播网页音频时 MediaRemote 报的是媒体代理进程 com.apple.WebKit.GPU,信任表里存的是宿主
// com.apple.Safari。按 bundle id **裸查** features().TrustedPlayers 对 Safari 恒落空:信任播放器的署名纠正
// 不生效、media_player 谎报成 Apple Music。Chrome/Arc 报浏览器自己的 bundle id、直接在表里,不受影响。
// 这组测试钉住代理进程的信任判定与标签。
func TestSafariMediaProxyTrustResolution(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"}

	const proxy = "com.apple.WebKit.GPU"

	t.Run("信任判定经代理别名解析", func(t *testing.T) {
		if !isTrustedPlayerBundleID(proxy) {
			t.Error("WebKit.GPU 该按宿主 Safari 算成受信任")
		}
	})

	t.Run("media_player 标签按宿主名报,不谎报 Apple Music", func(t *testing.T) {
		if got := mediaPlayerLabel(proxy); got != "Safari (macOS)" {
			t.Errorf("Safari 代理进程的标签 = %q,期望 Safari (macOS)", got)
		}
	})

	t.Run("Safari 没被信任时代理进程照旧不认", func(t *testing.T) {
		featuresRef().TrustedPlayers = map[string]string{}
		defer func() { featuresRef().TrustedPlayers = map[string]string{"com.apple.Safari": "Safari"} }()
		if isTrustedPlayerBundleID(proxy) {
			t.Error("宿主不在信任表里时代理进程也不该被信任")
		}
	})
}

// 源码级守卫:system.go 里对 features().TrustedPlayers 用 bundleID 直接下标的裸查,只允许
// 存在于 isTrustedPlayerBundleID 内部那一处(它是唯一被授权直查的地方,别名解析就在它
// 身上)。新代码要判信任,一律调 isTrustedPlayerBundleID,别自己查表。
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
		n += strings.Count(line, "features().TrustedPlayers[bundleID]")
	}
	if n > 1 {
		t.Errorf("system.go 里出现 %d 处 features().TrustedPlayers[bundleID] 裸查,只允许 "+
			"isTrustedPlayerBundleID 内部那 1 处——新代码请改调 isTrustedPlayerBundleID,"+
			"否则 Safari(媒体代理进程 com.apple.WebKit.GPU)会在你的判定里恒不受信任", n)
	}
}
