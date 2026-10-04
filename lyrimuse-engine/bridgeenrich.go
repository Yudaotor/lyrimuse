package main

// iPhone 经 Last.fm 桥接来的歌只查歌词缓存、不新建条目。
//
// 桥接的歌拿去上送(转发 ListenBrainz、同步正在播放、推给网页中继)时要附封面 / 平台链接 / 歌词,
// 这些都从歌词缓存取。Mac 上放过的歌照样带上;没放过的只送基本信息,不为它起一轮解析。理由:
//   - iPhone 的播放没有进度,网页上的歌词本来就没法跟着滚动,为它全源搜一轮收益很小;
//   - Last.fm 的写法跟本机播放器不同(`Crowd Lu` 对 `盧廣仲`),canonicalEnrichKey 折不平这种差异,
//     新建的条目在「歌词管理」里跟 Mac 那条成了两行;
//   - Last.fm 数据没有时长,打分里「时长对得上」那一档用不上,更容易选错版本;
//   - 积下的一批收听补转发时一首一轮全源搜索,集中打一阵请求;
//   - 播放器把歌词写进正在播放时(trustedlyricartist.go 那一类),Last.fm 上的正在播放每句一变,
//     桥接会把每一句都当成一首歌去解析、落库 —— 这条路径没有播放器标识,那边的纠正管不到。
//
// 没配上送目标(ListenBrainz / 网页中继)时这一步本来就不会发生:每个调用点都挂在对应的开关后面
// (bridgeForwardingEnabled、pushRelayState 里的 StateRelayURL)。

// enrichmentFor 是上送组装负载时取封面 / 链接 / 歌词的入口:桥接来的只查缓存,本机播放照常解析。
func enrichmentFor(s snapshot) map[string]string {
	if s.Remote {
		return cachedTrackEnrichment(s.Artist, s.Title, s.Album)
	}
	// isNewTrack 传 false:这里只是再查一次已经解析好的缓存(或触发首次解析),不是
	// poller.go handle() 那种"刚确认是新曲目"的现场时刻。
	return trackEnrichment(s.Artist, s.Title, s.Album, s.Bundle, s.lyricsDurationSecs(), false, s.Radio)
}

// cachedTrackEnrichment 只查缓存:key 解析跟 trackEnrichment 一致(精确 key,再退到宽松等价的
// canonicalEnrichKey),命中就返回字段,没命中返回 nil。不起解析、不挂任何后台补全、不去 Apple 反查
// 专辑名(coverAlbumForTrack 没命中时会联网)。
func cachedTrackEnrichment(artist, title, album string) map[string]string {
	if title == "" {
		return nil
	}
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	e, ok := enrichCache[key]
	if !ok {
		alt, found := canonicalEnrichKey(key)
		if !found {
			return nil
		}
		e = enrichCache[alt]
	}
	return e.fields()
}
