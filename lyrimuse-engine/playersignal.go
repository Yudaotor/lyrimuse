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

type otherTrackRoundKey struct{}

// withOtherTrackRound 标记这一轮评的是别的歌:不是播放器在放的这首,也不是它的待播队列、同专辑预取 —— 按组重搜、全量扫库、
// 补空扫描、给别的歌手动重新匹配。同源加权(+250)的立论是「时间轴对着正在放的这个播放器的母带」,这首歌以后在哪个播放器上放
// 不知道;不标的话谁赢取决于跑这一轮时用户碰巧开着哪个播放器(见 withoutPlayerIdentity)。见 09 章决策 299。
func withOtherTrackRound(ctx context.Context) context.Context {
	return context.WithValue(ctx, otherTrackRoundKey{}, true)
}

// withOtherTrackRoundUnlessPlaying:key 不是在放的那首时标上 withOtherTrackRound。全量扫库、补空扫描、手动重新匹配都可能轮到
// 正在放的这首,那时照常算同源加权,跟播放那一侧选出来的一致。
func withOtherTrackRoundUnlessPlaying(ctx context.Context, key string) context.Context {
	if isEnrichPlayingKey(key) {
		return ctx
	}
	return withOtherTrackRound(ctx)
}

func isOtherTrackRound(ctx context.Context) bool {
	v, _ := ctx.Value(otherTrackRoundKey{}).(bool)
	return v
}

// withoutPlayerIdentity:别的歌那一轮里,候选的身份即便读自正在放的播放器的本机数据,也不算「身份由那个播放器给定」—— 清掉
// identityFromLocalClient(网易云那一路在 ne.FromLocalClient 上),同源加权就不给。这两个字段另一个读的人是
// playerInstrumentalSource,它只认 forPlayingTrack 的结果,这几种轮次本来就不是。
func withoutPlayerIdentity(ctx context.Context, r lyricSourceResult) lyricSourceResult {
	if isOtherTrackRound(ctx) {
		r.identityFromLocalClient, r.ne.FromLocalClient = false, false
	}
	return r
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
