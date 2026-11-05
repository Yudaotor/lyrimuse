package main

import (
	"context"
	"log"
	"time"
)

// 开播补问「这条没有人声」:同专辑预取、后台补空、全量扫库存下的没词条目不是边放边解析的,问不到播放器自己的纯音乐信号
// (playerInstrumentalSource 只认在放的这首),补空又按退避(首次 24 小时起)不重来,放到时一直显示「暂无歌词」。
// 开播时只问在放的播放器自家那一路一轮(Spotify 读它本机的元数据缓存),它说没有人声就不等退避补一轮:那一轮在放这首,
// 信号照常生效、照常落标。见 09 章决策 361。

// playerNoVocalsTried:开播后问过的条目(按 key),每次启动每首只问一次。读写都持 enrichMu。
var playerNoVocalsTried = map[string]bool{}

// playerNoVocalsProbeTimeout:问自家那一路的上限,含 Apple 等目录锚点的那一段。
const playerNoVocalsProbeTimeout = 20 * time.Second

// playerNoVocalsSource:在放的播放器能给纯音乐信号的那一路(同 playerInstrumentalSource 认的几家),Spotify 是它的本地
// 歌词缓存。没有、或者那个源被关掉了返回空串。
func playerNoVocalsSource(bundleID string) string {
	player := playerForBundleID(bundleID)
	if player == playerSpotify {
		return spotifyLocalLyricsSource
	}
	switch src := playerNativeLyricSource(player); src {
	case lyricSourceNetease, lyricSourceQQ, lyricSourceSoda, lyricSourceAppleMusic:
		if lyricSourceEnabled(src) {
			return src
		}
	}
	return ""
}

// playerNoVocalsFillDue:这条没词、没标纯音乐的条目正被一个能给纯音乐信号的播放器放着,值得问一次。用户存过歌词、撤过
// 纯音乐标记的不问;Apple Music 要等播放侧记下目录 id 再问(没有 id 这一路问不出来)。调用方持 enrichMu。
func playerNoVocalsFillDue(e enrichEntry, key, bundleID, artist, title, album string) bool {
	if !e.Lyrics.IsZero() || e.ManualLyrics || !e.autoMarksInstrumental() || playerNoVocalsTried[key] {
		return false
	}
	src := playerNoVocalsSource(bundleID)
	if src == "" {
		return false
	}
	if src == lyricSourceAppleMusic {
		if id, _ := playbackTrackIDsFor(artist, title, album); id == "" {
			return false
		}
	}
	playerNoVocalsTried[key] = true
	return true
}

// playerSaysNoVocalsNow:只问在放的播放器自家那一路一轮(不换身份重搜),看它说不说这条没有人声。
func playerSaysNoVocalsNow(ctx context.Context, bundleID, artist, title, album string, durationSecs float64) bool {
	src := playerNoVocalsSource(bundleID)
	if src == spotifyLocalLyricsSource {
		return spotifyLocalNoVocals(spotifyTrackIDHintFor(artist, title))
	}
	if src == "" {
		return false
	}
	ctx, cancel := withCancelAfter(withLyricSourceOnly(ctx, []string{src}), playerNoVocalsProbeTimeout)
	defer cancel()
	_, scored := fetchScoredLyricCandidatesStreaming(ctx, artist, title, album, durationSecs, nil)
	return playerSaysInstrumental(scored)
}

// playerNoVocalsFill:播放器说没有人声就起一轮补空(retryLyricsUpgrade 收尾时清 enrichInflight),否则自己清。
func playerNoVocalsFill(ctx context.Context, key, bundleID, artist, title, album string, durationSecs float64) {
	if !playerSaysNoVocalsNow(ctx, bundleID, artist, title, album, durationSecs) {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
		return
	}
	log.Printf("lyrics: %s  %s says no vocals, filling now", key, playerForBundleID(bundleID))
	retryLyricsUpgrade(ctx, key, artist, title, album, durationSecs, true)
}
