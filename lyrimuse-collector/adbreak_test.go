package main

import "testing"

// 广告判定归 App:引擎只认 App 写进播放状态的结论,字段像广告、App 没判就不算。字段启发式(Spotify 原生
// album 空 / artist 空 / 标题「—」)在 App 的 LocalPlaybackSource.adBreakByFields,selftest 覆盖。
func TestIsAdBreakFollowsTheApp(t *testing.T) {
	t.Cleanup(func() { noteAppReportedAd(snapshot{}, false) })
	ad := snapshot{Title: "Take your sweet time.", Artist: "Häagen-Dazs", Album: "", Bundle: spotifyBundleID}
	if isAdBreak(ad.Bundle, ad.Artist, ad.Title, ad.Album) {
		t.Fatal("fields alone must not make an ad; only the App's verdict does")
	}
	noteAppReportedAd(ad, true)
	if !isAdBreak(ad.Bundle, ad.Artist, ad.Title, ad.Album) {
		t.Fatal("the App's verdict should count")
	}
}
