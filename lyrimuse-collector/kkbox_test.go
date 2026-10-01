package main

import (
	"reflect"
	"testing"
)

// KKBOX 歌手空的(播客单集)不拿去搜歌词。
func TestKKBOXArtistlessNotEnriched(t *testing.T) {
	if got := trackEnrichment("", "1989 - Deluxe - KKBOX", "", kkboxBundleID, 2143, true, false); got != nil {
		t.Errorf("KKBOX 歌手空的内容不该解析: %v", got)
	}
}

// 信任列表里的 KKBOX 升级后补进选中集合;勾着自动识别的不用补。
func TestPromoteTrustedBuiltins(t *testing.T) {
	trusted := map[string]string{kkboxBundleID: "KKBOX", "com.apple.Safari": "Safari"}
	got := promoteTrustedBuiltins(map[string]bool{playerQQMusic: true}, trusted)
	if want := map[string]bool{playerQQMusic: true, playerKKBOX: true}; !reflect.DeepEqual(got, want) {
		t.Errorf("没勾自动识别: got %v want %v", got, want)
	}
	got = promoteTrustedBuiltins(map[string]bool{playerAuto: true}, trusted)
	if want := map[string]bool{playerAuto: true}; !reflect.DeepEqual(got, want) {
		t.Errorf("勾着自动识别: got %v want %v", got, want)
	}
	got = promoteTrustedBuiltins(map[string]bool{playerSpotify: true}, map[string]string{"com.apple.Safari": "Safari"})
	if want := map[string]bool{playerSpotify: true}; !reflect.DeepEqual(got, want) {
		t.Errorf("没有内置播放器: got %v want %v", got, want)
	}
	if tp := resolveTrustedPlayers(trusted); tp[kkboxBundleID] != "" || tp["com.apple.Safari"] != "Safari" {
		t.Errorf("KKBOX 内置之后剔出信任列表: %v", tp)
	}
}
