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

// 信任列表里的 KKBOX(内置之前加进去的)剔出信任列表;挪进选中集合是 App 加载设置时的迁移,引擎不补。
func TestTrustedKKBOXIsDroppedNotPromoted(t *testing.T) {
	trusted := map[string]string{kkboxBundleID: "KKBOX", "com.apple.Safari": "Safari"}
	if tp := resolveTrustedPlayers(trusted); tp[kkboxBundleID] != "" || tp["com.apple.Safari"] != "Safari" {
		t.Errorf("KKBOX 内置之后剔出信任列表: %v", tp)
	}
	f := loadFeatureFlagsFromJSON(t, `{"players":["qq_music"],"trusted_players":{"`+kkboxBundleID+`":"KKBOX"}}`)
	if want := map[string]bool{playerQQMusic: true}; !reflect.DeepEqual(f.Players, want) {
		t.Errorf("引擎不替 App 迁移选中集合: got %v want %v", f.Players, want)
	}
}
