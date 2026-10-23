package main

import "encoding/json"

// 某个播放器此刻的播放模式,由 App 代读(PlayerQueryServer 的 playback_mode,App 侧 MusicPlaybackController.playbackMode(for:),
// 跟歌词窗口那两颗键同一个读法;交回 {"mode":…},App 侧 PlayerQueryMode)。值是 App 那边 MusicPlaybackMode 的原值,两边一起改。
// 随机优先:开着随机时读不出循环档。只问 App 读得了模式的播放器(supportsExtendedControls),别的 App 当场回失败。
const (
	playerModeList      = "list"
	playerModeShuffle   = "shuffle"
	playerModeRepeatOne = "repeatOne"
	playerModeRepeatAll = "repeatAll"
)

// playerPlaybackMode 问 App 这个播放器此刻的播放模式;读不出、不认识的值 ok=false。读 AppleScript 的那几家 App 侧超时 5 秒,
// 所以等脚本那一档。单测替换它。
var playerPlaybackMode = func(bundleID string) (mode string, ok bool) {
	out, ok := askApp(appQueryRequest{Kind: appQueryPlaybackMode, BundleID: bundleID}, appQueryScriptTimeout)
	if !ok {
		return "", false
	}
	var r struct {
		Mode string `json:"mode"`
	}
	if json.Unmarshal([]byte(out), &r) != nil {
		return "", false
	}
	switch r.Mode {
	case playerModeList, playerModeShuffle, playerModeRepeatOne, playerModeRepeatAll:
		return r.Mode, true
	}
	return "", false
}
