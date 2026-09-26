package main

import (
	"reflect"
	"testing"
)

// KKBOX 开播先发一帧只有歌名的(歌手空、时长 0),约半秒后补齐:那一帧不采纳,补齐之后照常;专辑名不作要求。
func TestKKBOXArtistArrivesLate(t *testing.T) {
	if !trustedPlaybackNotASong(kkboxBundleID, "", "") {
		t.Error("开播那一帧还没有歌手,不该采纳")
	}
	if trustedPlaybackNotASong(kkboxBundleID, "Taylor Swift (泰勒絲)", "") {
		t.Error("歌手补齐之后照常采纳,没有专辑名也认")
	}
	if trustedPlaybackNotASong(kugouMusicBundleID, "", "") {
		t.Error("只管 artistArrivesLate 的播放器,别的内置播放器不受影响")
	}
	raw := map[string]any{"title": "Opalite", "artist": ""}
	if !builtinArtistNotReady(kkboxBundleID, raw) {
		t.Error("builtinArtistNotReady 跟 trustedPlaybackNotASong 同一个判据")
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
