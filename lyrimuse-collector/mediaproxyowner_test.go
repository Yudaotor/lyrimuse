package main

import "testing"

// Safari 的媒体进程按宿主算 —— 跟 Swift 侧 TrustedPlayers 的同名断言一一对应。
//
// 背景:Safari 播网页音视频时上报的是 com.apple.WebKit.GPU 而不是 com.apple.Safari
// (Chromium 系报的是自己的 bundle id,只有 Safari 这样)。2026-09-01 用户实测撞上:
// 配对了 Safari 却整条播放不被采纳,同时还被要求再信任一个看不懂的 bundle id。
//
// ⚠️ 这份判据跟 Swift 侧 LyrimuseCore/Local/TrustedPlayers.swift 的 mediaProxyOwners
// 必须一致。两边各有一组对称的断言,单独改一边就会有一边红 —— 这正是要的效果。
func TestMediaProxyOwnerAcceptance(t *testing.T) {
	const webkit = "com.apple.WebKit.GPU"
	const safari = "com.apple.Safari"

	saved := features.TrustedPlayers
	defer func() { features.TrustedPlayers = saved }()

	// 信任了 Safari → 它的媒体进程也该被采纳
	features.TrustedPlayers = map[string]string{safari: "Safari"}
	if !isAcceptedPlayerBundleID(webkit) {
		t.Error("信任了 Safari,WebKit 媒体进程该被采纳")
	}

	// 没信任 Safari → 别名不能凭空放行(别名不是白名单)
	features.TrustedPlayers = map[string]string{}
	if isAcceptedPlayerBundleID(webkit) {
		t.Error("没信任 Safari 时不该放行 WebKit 媒体进程")
	}

	// 信任别的浏览器不能顺带放行
	features.TrustedPlayers = map[string]string{"com.google.Chrome": "Chrome"}
	if isAcceptedPlayerBundleID(webkit) {
		t.Error("信任 Chrome 不该顺带放行 WebKit 媒体进程")
	}

	// 别名是单向的:信任代理进程不等于信任 Safari 本身
	features.TrustedPlayers = map[string]string{webkit: ""}
	if isAcceptedPlayerBundleID(safari) {
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
