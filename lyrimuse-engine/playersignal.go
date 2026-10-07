package main

import "context"

// 正在放的播放器自己的纯音乐信号(playerInstrumentalSource)只对它在放的这首和它的待播队列成立。专辑预取、补空扫描、全量扫库
// 解析的是别的歌,手动搜索 / 手动重新匹配是用户要看候选,这几种只用搜出来的信号。见 09 章决策 210。

type playerQueueTrackKey struct{}

// withPlayerQueueTrack 标记这次解析的是正在放的播放器待播队列里的一首(upcoming.go)。
func withPlayerQueueTrack(ctx context.Context) context.Context {
	return context.WithValue(ctx, playerQueueTrackKey{}, true)
}

func isPlayerQueueTrack(ctx context.Context) bool {
	v, _ := ctx.Value(playerQueueTrackKey{}).(bool)
	return v
}

// playerSignalApplies:这次解析能不能用正在放的播放器自己的信号。
func playerSignalApplies(ctx context.Context) bool {
	if manualLyricSearch(ctx) {
		return false
	}
	return !isBackgroundOutbound(ctx) || isPlayerQueueTrack(ctx)
}

// playerLocalNoVocalsHint:开搜之前,正在放的播放器的本机数据就说这一条没有人声(网易云客户端曲库的无人声位、汽水播放队列缓存的
// vocal==2)。只给先上屏用:有它时宽限期那条也等播放器自家的源回话,免得先闪一下别家的词(见 earlyLyricsWatch.holdForNative)。
// QQ 音乐、Apple Music 要联网才知道,不在此列。
func playerLocalNoVocalsHint(artist, title, album string, durationSecs float64) bool {
	switch playingPlayer() {
	case playerNetease:
		t, ok := neteaseLocalEntry(context.Background(), artist, title, album, durationSecs)
		return ok && t.Mark&neteaseMarkNoVocals != 0
	case playerSoda:
		return sodaLocalInstrumental(artist, title, album, durationSecs)
	}
	return false
}
