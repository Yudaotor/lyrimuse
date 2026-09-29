package main

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
)

// 键缺失(老配置)= nil,沿用所有浏览器都探;App 写过但一个都没配 = 空 map,不能退成 nil。
func TestResolveBrowserPlatformPairs(t *testing.T) {
	if got := resolveBrowserPlatformPairs(nil); got != nil {
		t.Fatalf("键缺失应保持 nil, got %v", got)
	}
	if got := resolveBrowserPlatformPairs(map[string][]string{}); got == nil || len(got) != 0 {
		t.Fatalf("App 写过、一个都没配:应是空 map, got %#v", got)
	}
	got := resolveBrowserPlatformPairs(map[string][]string{
		" youtubeMusic ": {" com.google.Chrome ", ""},
		"spotifyWeb":     {},
		"":               {"com.apple.Safari"},
	})
	want := map[string]map[string]bool{"youtubeMusic": {"com.google.Chrome": true}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("清洗结果 = %v, want %v", got, want)
	}

	for _, tc := range []struct {
		raw     string
		wantNil bool
	}{
		{`{}`, true},
		{`{"browser_platform_pairs":{}}`, false},
	} {
		var f featureFlagsFile
		if err := json.Unmarshal([]byte(tc.raw), &f); err != nil {
			t.Fatal(err)
		}
		if got := buildFeatureFlags(f).BrowserPlatformPairs; (got == nil) != tc.wantNil {
			t.Errorf("%s: BrowserPlatformPairs nil = %v, want %v", tc.raw, got == nil, tc.wantNil)
		}
	}
}

// 四路网页平台探针只对配对过对应平台的浏览器起 osascript;Safari 报的媒体代理进程按宿主算。
func TestBrowserPageProbesSkipUnpairedBrowsers(t *testing.T) {
	resetYTMusicAdCacheForTest(t)
	calls := map[string]int{}
	oldAd, oldVideo, oldYT, oldSP := runYTMusicAdProbe, ytmusicVideoTypeScript, ytmusicQueueScript, spotifyWebQueueScript
	t.Cleanup(func() {
		runYTMusicAdProbe, ytmusicVideoTypeScript, ytmusicQueueScript, spotifyWebQueueScript = oldAd, oldVideo, oldYT, oldSP
	})
	runYTMusicAdProbe = func(_ context.Context, bundleID, _ string) (ytmusicAdVerdict, string, bool, string) {
		calls["ad "+bundleID]++
		return ytmusicAdUnknown, "", false, ""
	}
	ytmusicVideoTypeScript = func(_ context.Context, bundleID, _ string) (string, bool) {
		calls["video "+bundleID]++
		return "", false
	}
	ytmusicQueueScript = func(bundleID, _ string) (string, bool) {
		calls["ytqueue "+bundleID]++
		return "", false
	}
	spotifyWebQueueScript = func(bundleID, _ string) (string, bool) {
		calls["spqueue "+bundleID]++
		return "", false
	}
	probeAll := func(reported string) {
		ytmusicAdProbe(context.Background(), reported, "A\x00Song")
		ytmusicMusicVideo(context.Background(), reported, "A\x00Song")
		ytmusicUpcoming("A", "Song", reported, 200, 3)
		spotifyWebUpcoming("A", "Song", reported, 3)
	}

	setFeatureForTest(t, func(f *featureFlags) {
		f.BrowserPlatformPairs = map[string]map[string]bool{
			browserPlatformYouTubeMusic: {"com.google.Chrome": true},
			browserPlatformSpotifyWeb:   {"com.apple.Safari": true},
		}
	})
	probeAll("com.google.Chrome")
	probeAll("com.apple.WebKit.GPU")
	want := map[string]int{
		"ad com.google.Chrome": 1, "video com.google.Chrome": 1, "ytqueue com.google.Chrome": 1,
		"spqueue com.apple.Safari": 1,
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("只该探配对过的平台:\n got  %v\n want %v", calls, want)
	}
	if v, _ := ytmusicAdProbe(context.Background(), "com.apple.WebKit.GPU", "A\x00Song"); v != ytmusicAdUnknown {
		t.Fatalf("没配对时广告判定应缺失(按拒处理), got %v", v)
	}

	// 键缺失的老配置:照旧都探。
	calls = map[string]int{}
	setFeatureForTest(t, func(f *featureFlags) { f.BrowserPlatformPairs = nil })
	probeAll("com.apple.WebKit.GPU")
	for _, k := range []string{"ad com.apple.Safari", "video com.apple.Safari", "ytqueue com.apple.Safari", "spqueue com.apple.Safari"} {
		if calls[k] != 1 {
			t.Errorf("老配置下 %s 应照旧探一次, got %d (全部: %v)", k, calls[k], calls)
		}
	}
}
