package main

import "strings"

// Chromium 系浏览器(Chrome / Edge / Brave 等)「安装为 App」的网页应用。系统「正在播放」报的是网页应用壳的 bundle id:
// `<浏览器 bundle id>.app.<应用 id>`,应用 id 是 32 位 a–p,非默认个人资料在应用 id 前多一段「个人资料目录名-」。
// 只认 browserWebAppPlatforms 里登记过的应用(生成自 shared/players.json):按宿主浏览器里配对了这个平台的网页版对待,
// 不用手动信任。规则跟 Swift 侧 BrowserWebApp.parse 一致。见 02 章决策 284。

const browserWebAppIDLength = 32

// parseBrowserWebApp 按规则拆 bundle id;不是网页应用壳的形状 ok 为 false。host 是 bundle id 的前半段:引擎不读壳的
// Info.plist,App 侧发脚本前另按壳的 CrBundleIdentifier 核对。
func parseBrowserWebApp(bundleID string) (host, appID string, ok bool) {
	i := strings.LastIndex(bundleID, ".app.")
	if i < 0 {
		return "", "", false
	}
	host, tail := bundleID[:i], bundleID[i+len(".app."):]
	if !bundleIDLike(host) || len(tail) < browserWebAppIDLength {
		return "", "", false
	}
	appID = tail[len(tail)-browserWebAppIDLength:]
	for _, c := range appID {
		if c < 'a' || c > 'p' {
			return "", "", false
		}
	}
	if profile := tail[:len(tail)-browserWebAppIDLength]; profile != "" {
		if !strings.HasSuffix(profile, "-") {
			return "", "", false
		}
		for _, c := range profile {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return "", "", false
			}
		}
	}
	return host, appID, true
}

func bundleIDLike(s string) bool {
	if s == "" || s[0] == '.' || s[len(s)-1] == '.' {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}

// knownBrowserWebApp:登记过平台的浏览器网页应用 → 宿主浏览器、网页平台 id、ListenBrainz 标签。
func knownBrowserWebApp(bundleID string) (host, platform, label string, ok bool) {
	host, appID, ok := parseBrowserWebApp(bundleID)
	if !ok {
		return "", "", "", false
	}
	platform, ok = browserWebAppPlatforms[appID]
	if !ok {
		return "", "", "", false
	}
	return host, platform, browserWebAppScrobbleLabels[appID], true
}

// playerHostBundleID 把报上来的 bundle id 换成查信任列表、Last.fm 排除名单、网页播放器配对时用的宿主:Safari 的媒体进程
// 换成 Safari(mediaProxyOwners),登记过的浏览器网页应用换成宿主浏览器,别的原样。跟 Swift 侧 TrustedPlayers.mediaProxyOwner 同一套。
func playerHostBundleID(bundleID string) string {
	if owner, ok := mediaProxyOwners[bundleID]; ok {
		return owner
	}
	if host, _, _, ok := knownBrowserWebApp(bundleID); ok {
		return host
	}
	return bundleID
}

// browserQueueTarget:这一拍的播放能不能读 platformID 的网页队列,以及请 App 对哪个 bundle id 跑脚本。网页应用只读它自己那个
// 平台、不看宿主浏览器的配对,脚本请求带壳的 bundle id(App 侧换成宿主);别的按宿主查配对。
func browserQueueTarget(platformID, bundleID string) (string, bool) {
	if _, platform, _, ok := knownBrowserWebApp(bundleID); ok {
		return bundleID, platform == platformID
	}
	target := playerHostBundleID(bundleID)
	return target, browserPlatformPaired(platformID, target)
}
