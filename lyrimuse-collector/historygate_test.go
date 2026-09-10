package main

import "testing"

func TestResolveHistoryExcludedBundles(t *testing.T) {
	got := resolveHistoryExcludedBundles([]string{" com.tencent.QQMusicMac ", "", "com.apple.Safari", "com.apple.Safari"})
	if len(got) != 2 || !got["com.tencent.QQMusicMac"] || !got["com.apple.Safari"] {
		t.Fatalf("resolve: got %v", got)
	}
	if m := resolveHistoryExcludedBundles(nil); m == nil || len(m) != 0 {
		t.Fatalf("nil input should resolve to an empty (non-nil) map, got %v", m)
	}
}

func TestHistoryExcluded(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	features.HistoryExcludedBundles = map[string]bool{}
	if historyExcluded(qqMusicBundleID) {
		t.Fatal("empty exclusion set must exclude nothing")
	}

	features.HistoryExcludedBundles = resolveHistoryExcludedBundles([]string{qqMusicBundleID, "com.apple.Safari"})
	cases := []struct {
		bundle string
		want   bool
	}{
		{qqMusicBundleID, true},
		{spotifyBundleID, false},
		{appleMusicBundleID, false},
		// Safari 报的是媒体代理进程,设置里存的是宿主 —— 必须经 mediaProxyOwners 归一后命中。
		{"com.apple.WebKit.GPU", true},
		{"com.apple.Safari", true},
		{"company.thebrowser.Browser", false},
		{"", false},
	}
	for _, c := range cases {
		if got := historyExcluded(c.bundle); got != c.want {
			t.Errorf("historyExcluded(%q) = %v, want %v", c.bundle, got, c.want)
		}
	}
}
