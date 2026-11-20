package main

import (
	"reflect"
	"testing"
)

const (
	testYTMusicAppID = "cinhimbnkkaeohfgghhklpknlkffjgod"
	testSpotifyAppID = "pjibgclleladliembfgfagdaldikeohf"
	// 形状合法、但没登记平台的应用 id。
	testUnknownAppID = "abcdefghijklmnopabcdefghijklmnop"
)

// 拆 bundle id 的规则(跟 Swift 侧 BrowserWebApp.parse 同一套,那边有对称的断言)。
func TestParseBrowserWebApp(t *testing.T) {
	cases := []struct {
		id, host, appID string
		ok              bool
	}{
		{"com.google.Chrome.app." + testYTMusicAppID, "com.google.Chrome", testYTMusicAppID, true},
		{"com.microsoft.edgemac.app." + testYTMusicAppID, "com.microsoft.edgemac", testYTMusicAppID, true},
		{"com.brave.Browser.app." + testSpotifyAppID, "com.brave.Browser", testSpotifyAppID, true},
		{"com.google.Chrome.canary.app." + testYTMusicAppID, "com.google.Chrome.canary", testYTMusicAppID, true},
		// 非默认个人资料:应用 id 前多一段「个人资料目录名-」,目录名里的空格换成了连字符。
		{"com.google.Chrome.app.Profile-1-" + testYTMusicAppID, "com.google.Chrome", testYTMusicAppID, true},
		{"com.google.Chrome.app.Default-" + testYTMusicAppID, "com.google.Chrome", testYTMusicAppID, true},
		{"com.google.Chrome.app." + testUnknownAppID, "com.google.Chrome", testUnknownAppID, true},
		{"com.google.Chrome", "", "", false},
		{"com.google.Chrome.app.", "", "", false},
		{"com.google.Chrome.app." + testYTMusicAppID[1:], "", "", false},                // 31 位
		{"com.google.Chrome.app.x" + testYTMusicAppID, "", "", false},                   // 前缀没以连字符结尾
		{"com.google.Chrome.app.a.b-" + testYTMusicAppID, "", "", false},                // 前缀带点
		{"com.google.Chrome.app." + "q" + testYTMusicAppID[1:], "", "", false},          // q 不在 a–p
		{"com.google.Chrome.app." + "C" + testYTMusicAppID[1:], "", "", false},          // 大写
		{".app." + testYTMusicAppID, "", "", false},                                     // 没有宿主
		{"com.google.Chrome..app." + testYTMusicAppID, "", "", false},                   // 宿主以点结尾
		{"com.google.Chrome.app." + testYTMusicAppID + ".helper", "", "", false},        // 后面还有东西
		{"com.google.Chrome.app " + testYTMusicAppID, "", "", false},                    // 不是 .app.
		{"com.google.Chrome.app.Profile 1-" + testYTMusicAppID, "", "", false},          // 前缀带空格
		{"com.google.Chrome.application." + testYTMusicAppID, "", "", false},            // 不是 .app.
		{"com.google.Chrome.app." + testYTMusicAppID + testYTMusicAppID, "", "", false}, // 前缀没有连字符
	}
	for _, c := range cases {
		host, appID, ok := parseBrowserWebApp(c.id)
		if ok != c.ok || host != c.host || appID != c.appID {
			t.Errorf("parseBrowserWebApp(%q) = (%q, %q, %v), want (%q, %q, %v)", c.id, host, appID, ok, c.host, c.appID, c.ok)
		}
	}
}

// 登记表:只有这两个应用,平台 id 是「网页播放器」卡的那两个,每条都有标签。
func TestBrowserWebAppTable(t *testing.T) {
	want := map[string]string{testYTMusicAppID: browserPlatformYouTubeMusic, testSpotifyAppID: browserPlatformSpotifyWeb}
	if !reflect.DeepEqual(browserWebAppPlatforms, want) {
		t.Fatalf("browserWebAppPlatforms = %v, want %v", browserWebAppPlatforms, want)
	}
	for appID := range browserWebAppPlatforms {
		if browserWebAppScrobbleLabels[appID] == "" {
			t.Errorf("%s 没有 ListenBrainz 标签", appID)
		}
	}

	host, platform, label, ok := knownBrowserWebApp("com.microsoft.edgemac.app.Profile-2-" + testSpotifyAppID)
	if !ok || host != "com.microsoft.edgemac" || platform != browserPlatformSpotifyWeb || label != "Spotify Web (macOS)" {
		t.Errorf("Edge 的 Spotify 网页应用:得到 (%q, %q, %q, %v)", host, platform, label, ok)
	}
	if _, _, _, ok := knownBrowserWebApp("com.google.Chrome.app." + testUnknownAppID); ok {
		t.Error("没登记的应用 id 不该认")
	}
}

// 默认就信任、标签报平台、Last.fm 排除按宿主浏览器查。
func TestBrowserWebAppTrustLabelAndLastfmExclude(t *testing.T) {
	ytm := "com.google.Chrome.app." + testYTMusicAppID
	unknown := "com.google.Chrome.app." + testUnknownAppID

	setFeatureForTest(t, func(f *featureFlags) { f.TrustedPlayers = map[string]string{} })
	if !isTrustedPlayerBundleID(ytm) {
		t.Error("登记过的网页应用不用手动信任")
	}
	if isTrustedPlayerBundleID(unknown) {
		t.Error("没登记的网页应用不能凭空信任")
	}
	if got := mediaPlayerLabel(ytm); got != "YouTube Music (macOS)" {
		t.Errorf("mediaPlayerLabel(网页应用) = %q", got)
	}
	setFeatureForTest(t, func(f *featureFlags) { f.TrustedPlayers = map[string]string{"com.google.Chrome": "Google Chrome"} })
	if got := mediaPlayerLabel(ytm); got != "YouTube Music (macOS)" {
		t.Errorf("宿主浏览器信任过也报平台,得到 %q", got)
	}
	if isTrustedPlayerBundleID(unknown) {
		t.Error("信任了宿主浏览器不能顺带放行没登记的网页应用")
	}

	if got := playerHostBundleID(ytm); got != "com.google.Chrome" {
		t.Errorf("playerHostBundleID(网页应用) = %q", got)
	}
	if got := playerHostBundleID(unknown); got != unknown {
		t.Errorf("没登记的网页应用原样返回,得到 %q", got)
	}
	if got := playerHostBundleID("com.apple.WebKit.GPU"); got != "com.apple.Safari" {
		t.Errorf("Safari 的媒体进程换成 Safari,得到 %q", got)
	}

	saved, savedPath := features(), lastfmExcludePath
	defer func() {
		setFeatures(saved)
		setLastfmExcludePath(savedPath)
	}()
	setLastfmExcludePath("")
	featuresRef().LastfmExcludedBundles = resolveLastfmExcludedBundles([]string{"com.google.Chrome"})
	if !lastfmExcluded(ytm) {
		t.Error("排除了 Chrome,Chrome 里的网页应用也该排除")
	}
	if lastfmExcluded("com.brave.Browser.app." + testYTMusicAppID) {
		t.Error("排除了 Chrome 不该排除 Brave 里的网页应用")
	}
	if lastfmExcluded(unknown) {
		t.Error("没登记的网页应用不按宿主排除")
	}
}

// 队列预取:网页应用只读它自己那个平台、不看宿主浏览器的配对,脚本请求带壳的 bundle id(App 侧换成宿主)。
func TestBrowserWebAppQueueTarget(t *testing.T) {
	ytm := "com.google.Chrome.app." + testYTMusicAppID
	sp := "com.brave.Browser.app.Profile-1-" + testSpotifyAppID

	oldYT, oldSP := ytmusicQueueScript, spotifyWebQueueScript
	t.Cleanup(func() { ytmusicQueueScript, spotifyWebQueueScript = oldYT, oldSP })
	calls := map[string]int{}
	ytmusicQueueScript = func(bundleID string) (appQueryTracks, bool) {
		calls["ytqueue "+bundleID]++
		return appQueryTracks{}, false
	}
	spotifyWebQueueScript = func(bundleID string) (appQueryTracks, bool) {
		calls["spqueue "+bundleID]++
		return appQueryTracks{}, false
	}
	probeAll := func(reported string) {
		ytmusicUpcoming("A", "Song", reported, 200, 3)
		spotifyWebUpcoming("A", "Song", reported, 3)
	}

	// 宿主浏览器一个平台都没配对、Chrome 配的是别的平台,网页应用照样只读自己那个平台。
	setFeatureForTest(t, func(f *featureFlags) {
		f.BrowserPlatformPairs = map[string]map[string]bool{browserPlatformSpotifyWeb: {"com.google.Chrome": true}}
	})
	probeAll(ytm)
	probeAll(sp)
	probeAll("com.google.Chrome.app." + testUnknownAppID)
	want := map[string]int{"ytqueue " + ytm: 1, "spqueue " + sp: 1}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("网页应用只该读自己那个平台:\n got  %v\n want %v", calls, want)
	}

	if target, ok := browserQueueTarget(browserPlatformYouTubeMusic, "com.google.Chrome"); ok || target != "com.google.Chrome" {
		t.Errorf("没配对 YouTube Music 的 Chrome 标签页照旧不读,得到 (%q, %v)", target, ok)
	}
	if target, ok := browserQueueTarget(browserPlatformSpotifyWeb, "com.google.Chrome"); !ok || target != "com.google.Chrome" {
		t.Errorf("配对过的 Chrome 标签页照旧读,得到 (%q, %v)", target, ok)
	}
}
