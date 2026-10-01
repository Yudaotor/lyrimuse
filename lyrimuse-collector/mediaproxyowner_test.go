package main

import "testing"

// Safari 的媒体进程按宿主算。别名表生成自 shared/players.json(Swift 侧 TrustedPlayers.mediaProxyOwners 同源);
// 先查本体、再查宿主的判法两侧各写一份,Swift 侧有对称的断言。
//
// 背景:Safari 播网页音视频时上报的是 com.apple.WebKit.GPU 而不是 com.apple.Safari
// (Chromium 系报的是自己的 bundle id,只有 Safari 这样)。
func TestMediaProxyOwnerTrust(t *testing.T) {
	const webkit = "com.apple.WebKit.GPU"
	const safari = "com.apple.Safari"

	saved := features().TrustedPlayers
	defer func() { featuresRef().TrustedPlayers = saved }()

	// 信任了 Safari → 它的媒体进程也算受信任
	featuresRef().TrustedPlayers = map[string]string{safari: "Safari"}
	if !isTrustedPlayerBundleID(webkit) {
		t.Error("信任了 Safari,WebKit 媒体进程该算受信任")
	}

	// 没信任 Safari → 别名不能凭空放行(别名不是白名单)
	featuresRef().TrustedPlayers = map[string]string{}
	if isTrustedPlayerBundleID(webkit) {
		t.Error("没信任 Safari 时不该放行 WebKit 媒体进程")
	}

	// 信任别的浏览器不能顺带放行
	featuresRef().TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}
	if isTrustedPlayerBundleID(webkit) {
		t.Error("信任 Chrome 不该顺带放行 WebKit 媒体进程")
	}

	// 别名是单向的:信任代理进程不等于信任 Safari 本身
	featuresRef().TrustedPlayers = map[string]string{webkit: ""}
	if isTrustedPlayerBundleID(safari) {
		t.Error("别名必须单向:信任代理进程不代表 Safari 本身被信任")
	}

	// 表本身:Chromium 系不该在里面
	if _, ok := mediaProxyOwners["com.google.Chrome"]; ok {
		t.Error("Chromium 系报自己的 bundle id,不该出现在代理表里")
	}
	if mediaProxyOwners[webkit] != safari {
		t.Errorf("WebKit 媒体进程的宿主该是 %q", safari)
	}
}
