package main

import (
	"testing"
	"time"
)

// 关掉的源这一轮不发请求(2026-09-06,用户定的「没启用肯定就不查」),而且不算冷却跳过——
// 冷却跳过会被记进 lyrics_sources_skipped 招来 needsLyricsRetry 的补搜,关掉的源不该被补搜。
func TestLyricSourceSkipForDisabledBeatsCooling(t *testing.T) {
	enabled := func(s string) bool { return s != "netease" }
	plan := lyricSourceRoundPlan{"netease": 30 * time.Second, "qq": 15 * time.Second}
	cases := []struct {
		source string
		want   lyricSourceSkip
	}{
		{"netease", lyricSourceSkipDisabled}, // 关掉 + 冷却:按关掉算
		{"qq", lyricSourceSkipCooling},       // 开着 + 冷却
		{"kugou", lyricSourceQuery},          // 开着 + 没冷却
	}
	for _, c := range cases {
		if got := lyricSourceSkipFor(c.source, enabled, plan); got != c.want {
			t.Errorf("%s: got %v want %v", c.source, got, c.want)
		}
	}
	// plan 为 nil(没有源在冷却)时只剩"开没开"一个判据。
	if got := lyricSourceSkipFor("netease", enabled, nil); got != lyricSourceSkipDisabled {
		t.Errorf("nil plan, disabled: got %v", got)
	}
	if got := lyricSourceSkipFor("qq", enabled, nil); got != lyricSourceQuery {
		t.Errorf("nil plan, enabled: got %v", got)
	}
}

// 网易云关掉时那一路不查,e.NeteaseURL 必然是空的——外围补全不能把它算缺项,否则每条记录都要
// 白补 peripheralBackfillMaxAttempts 轮、每轮把开着的源全部重查一遍。
func TestNeedsPeripheralBackfillIgnoresNeteaseURLWhenDisabled(t *testing.T) {
	saved := features.LyricsSources
	defer func() { features.LyricsSources = saved }()

	long := time.Now().Unix() - int64(enrichPeripheralRetryInterval/time.Second) - 1
	e := enrichEntry{
		AccentColor: "#fff", AppleURL: "a", QQURL: "https://y.qq.com/n/ryqq/songDetail/000abc", QQAlbumMid: "al", QQSingerMid: "si",
		CanonicalArtist: "蔡徐坤", TS: long,
		CoverURL: "https://is1-ssl.mzstatic.com/x.jpg", CoverSource: "apple", CoverAlbum: "KUN",
		// NeteaseURL 留空
	}
	features.LyricsSources = map[string]bool{"netease": true, "qq": true}
	if !needsPeripheralBackfill(e, "蔡徐坤", "KUN") {
		t.Error("网易云开着、链接为空:该补")
	}
	features.LyricsSources = map[string]bool{"netease": false, "qq": true}
	if needsPeripheralBackfill(e, "蔡徐坤", "KUN") {
		t.Error("网易云关掉、链接为空:不该为此补——那一路根本不查")
	}
	// 其它缺项照旧触发,不因网易云关掉而被一并放过。
	e.AppleURL = ""
	if !needsPeripheralBackfill(e, "蔡徐坤", "KUN") {
		t.Error("Apple 链接缺:仍该补")
	}
}
