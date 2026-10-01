package main

import (
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

// 两家网页版的待播队列探针只对配对过对应平台的浏览器起 osascript;Safari 报的媒体代理进程按宿主算。
func TestBrowserPageProbesSkipUnpairedBrowsers(t *testing.T) {
	calls := map[string]int{}
	oldYT, oldSP := ytmusicQueueScript, spotifyWebQueueScript
	t.Cleanup(func() { ytmusicQueueScript, spotifyWebQueueScript = oldYT, oldSP })
	ytmusicQueueScript = func(bundleID, _ string) (string, bool) {
		calls["ytqueue "+bundleID]++
		return "", false
	}
	spotifyWebQueueScript = func(bundleID, _ string) (string, bool) {
		calls["spqueue "+bundleID]++
		return "", false
	}
	probeAll := func(reported string) {
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
	want := map[string]int{"ytqueue com.google.Chrome": 1, "spqueue com.apple.Safari": 1}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("只该探配对过的平台:\n got  %v\n want %v", calls, want)
	}

	// 键缺失的老配置:照旧都探。
	calls = map[string]int{}
	setFeatureForTest(t, func(f *featureFlags) { f.BrowserPlatformPairs = nil })
	probeAll("com.apple.WebKit.GPU")
	for _, k := range []string{"ytqueue com.apple.Safari", "spqueue com.apple.Safari"} {
		if calls[k] != 1 {
			t.Errorf("老配置下 %s 应照旧探一次, got %d (全部: %v)", k, calls[k], calls)
		}
	}
}
