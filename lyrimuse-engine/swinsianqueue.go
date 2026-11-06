package main

// Swinsian 的待播队列:App 代问它的 AppleScript `playback queue`(从当前这首起、只剩没放的,开着随机时就是打乱后的顺序),
// 每首按它放到时快照里那一套认身份(文件标签、没写标签按文件名拆),整理成跟 Kaset 同一种回包(App 侧
// SwinsianPlayerInfo.queueReply)。单曲循环没有要预取的;列表循环绕回开头之后放什么队列里没有,App 报成不循环。
// 问不到(没授自动化、没在跑)退回同专辑预取。见 02 章决策 241。

// swinsianQueueAsk 让 App 读一次队列。单测替换它。
var swinsianQueueAsk = func() (string, bool) {
	return askApp(appQueryRequest{Kind: appQuerySwinsianQueue}, appQueryScriptTimeout)
}

func swinsianUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	out, ok := swinsianQueueAsk()
	if !ok {
		return nil, false
	}
	return parseKasetQueue(out, artist, title, n)
}
