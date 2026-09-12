package main

// 电台曲目的**真实曲长**补进歌词缓存(2026-09-10)。
//
// 为什么要单开这条路:电台快照里的 duration 是整档节目(实测 3390.122s),真曲长只有 Apple 目录知道
// (appleCatalogAnchor,实测把 3390.122 纠成 226.283 / 131.173 / 237.800)。而目录锚点是**异步**的:
// 一首歌刚换过来那一拍通常是缓存未命中、后台才去取,偏偏歌词条目就是在那一拍写下的 —— 所以条目里
// 的时长是空的,几秒后目录到位了也没人回头补。实测:Tame Impala《Borderline》条目 09:18:46 落盘,
// 目录 09:19:07 才给出 237.8s,条目一直是空。
//
// App 侧要拿这个值当电台进度条的分母(EnrichCacheReader.trackDurationSecs),空着就只能退回整档节目,
// 显示成「2:29 / 56:30」。所以照搬 spotifytrack.go 那套「提示 + 下次进 trackEnrichment 时补上」的模式:
// poller 每拍把当前已知的真曲长记成提示,条目下一次被读到时写进去、落盘。
//
// 只写 DurationSecs(观察到的真实曲长),**不碰** ResolvedDurationSecs —— 后者的语义是"这份歌词是按多少秒
// 校验选出来的",歌词并不是按这个时长选的,写进去就是伪造依据,而且会让 durationMismatch 拿它当基准。

const radioDurationHintCap = 512

var radioDurationHints = map[string]float64{}

// noteRadioDuration 记下这首歌的真实曲长(秒)。key 与 enrichKey 同一套归一化。
// 非正值不记 —— 目录还没给出来时就是 0,记进去等于把"未知"当成事实。
func noteRadioDuration(artist, title, album string, secs float64) {
	if secs <= 0 {
		return
	}
	key := enrichKey(artist, title, album)
	if key == "" {
		return
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if len(radioDurationHints) >= radioDurationHintCap {
		radioDurationHints = map[string]float64{}
	}
	radioDurationHints[key] = secs
}

// applyRadioDurationHintLocked 把提示写进条目,返回是否真的改了(调用方据此决定要不要落盘)。
// **调用方必须持有 enrichMu**(名字里的 Locked 就是这个意思,同 applySpotifyTrackIDHintLocked 的约定)。
// 已经有值且一致(容差 0.5s,浮点与不同来源的标注差)就不动,免得同一首歌每几秒落一次盘。
func applyRadioDurationHintLocked(key string, e *enrichEntry) bool {
	secs := radioDurationHints[key]
	if secs <= 0 {
		return false
	}
	if diff := e.DurationSecs - secs; diff > -0.5 && diff < 0.5 {
		return false
	}
	e.DurationSecs = secs
	return true
}
