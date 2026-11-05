package main

import (
	"context"
	"log"
	"time"
)

// Apple Music 在放、目录说这条没有人声(applemusicCatalogNoVocals)时按纯音乐处理。播放侧的目录 id 要等锚点核对完
// (applecatalog.go:第一次见到这首时后台查一次目录、下一拍才写进提示),所以两处都不能只在开搜那一刻读一次:
//   - 解析在放的这首时,Apple 那一路没拿到词就等锚点就绪再问(waitPlayingAppleCatalogID),跟别的源并行等;
//   - 同专辑预取、后台补空存下的「没词」条目(那几条路不是在放这首,问不了),开播后锚点一就绪就问一次,
//     是就不等退避起一轮补空:那一轮在放这首,信号照常生效(appleNoVocalsFill)。
// 见 09 章决策 360。

// appleNoVocalsAnchorWait:等目录锚点的上限。锚点要一次目录查询加一拍(5 秒)。单测置 0。
var appleNoVocalsAnchorWait = 8 * time.Second

// appleNoVocalsPoll:等锚点时隔多久看一次提示。
var appleNoVocalsPoll = 250 * time.Millisecond

// waitPlayingAppleCatalogID:这首在播放侧记下的 Apple 目录 id。还没有时等锚点就绪;确定立不起锚点(本地导入的文件、
// 没报专辑名、目录元数据核对不上)或 ctx 结束时不等。
func waitPlayingAppleCatalogID(ctx context.Context, artist, title, album string) string {
	id, _ := playbackTrackIDsForRound(ctx, artist, title, album)
	deadline := time.Now().Add(appleNoVocalsAnchorWait)
	for id == "" && !appleCatalogCannotAnchor(title, album) && time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ""
		case <-time.After(appleNoVocalsPoll):
		}
		id, _ = playbackTrackIDsForRound(ctx, artist, title, album)
	}
	return id
}

// appleNoVocalsTried:开播后问过目录的条目(按 key),每次启动每首只问一次。读写都持 enrichMu。
var appleNoVocalsTried = map[string]bool{}

// appleNoVocalsFillDue:这条没词、没标纯音乐的条目正用 Apple Music 放着,目录 id 已经有了,值得问一次有没有人声。
// 用户存过歌词、撤过纯音乐标记的不问;applemusic 源被关掉时不问(同解析那一路)。调用方持 enrichMu。
func appleNoVocalsFillDue(e enrichEntry, key, bundleID, artist, title, album string) bool {
	if bundleID != appleMusicBundleID || !e.Lyrics.IsZero() || e.ManualLyrics || !e.autoMarksInstrumental() ||
		appleNoVocalsTried[key] || !lyricSourceEnabled("applemusic") {
		return false
	}
	id, _ := playbackTrackIDsFor(artist, title, album)
	if id == "" {
		return false
	}
	appleNoVocalsTried[key] = true
	return true
}

// appleNoVocalsFill:问目录这条有没有人声,没有就起一轮补空(retryLyricsUpgrade 收尾时清 enrichInflight),有就自己清。
func appleNoVocalsFill(ctx context.Context, key, artist, title, album string, durationSecs float64) {
	id, _ := playbackTrackIDsFor(artist, title, album)
	askCtx, cancel := withCancelAfter(ctx, 15*time.Second)
	noVocals := id != "" && applemusicCatalogNoVocals(askCtx, id)
	cancel()
	if !noVocals {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
		return
	}
	log.Printf("lyrics: %s  Apple Music catalog says no vocals, filling now", key)
	retryLyricsUpgrade(ctx, key, artist, title, album, durationSecs, true)
}
