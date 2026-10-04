package main

import "context"

// 机翻补全的起跑点。
//
// 机翻只写译文那几个字段,落盘前核对正文没变(见 backfillTranslation),所以不占 enrichInflight
// 那个「一次只跑一路」的名额:设备封面、周边补全、重打分、升级重试落盘时都重新读条目、只改自己的字段,
// 跟它互不覆盖,可以同时跑。唯一要避开的是首次解析在途(enrichProvisional):它的最终提交整条覆盖条目,
// 在先上屏那一份上补的译文会被冲掉;这期间不起,等它提交完的下一次轮询再起。
//
// 待播队列里的歌预解析完就接着翻(withTranslateAfterResolve → translateUpcomingLocked),播到时
// 译文已经在缓存里。同专辑预取不翻:整张专辑多数歌不会被播到,白烧 MyMemory 的日配额和每首的
// 重试次数。见 10 章决策 26。

var (
	// translationInflight 正在机翻(或排队等 prefetchTranslateSlot)的 key,受 enrichMu 保护。
	translationInflight = map[string]bool{}
	// prefetchTranslateSlot 预取来的机翻一次只跑一首,几首一起跑会跟正在播的那首抢端上翻译 helper
	// 和网络翻译端点。正在播的那首不经过它。
	prefetchTranslateSlot = make(chan struct{}, 1)
)

type translateAfterResolveKey struct{}

// withTranslateAfterResolve 标记这一轮首次解析跑完后接着排机翻(resolveEnrichAsync 收尾时调
// translateUpcomingLocked)。只给待播队列预取用。
func withTranslateAfterResolve(ctx context.Context) context.Context {
	return context.WithValue(ctx, translateAfterResolveKey{}, true)
}

func translateAfterResolve(ctx context.Context) bool {
	v, _ := ctx.Value(translateAfterResolveKey{}).(bool)
	return v
}

// translationStartableLocked:这条要机翻、眼下也能起。调用方持有 enrichMu。
func translationStartableLocked(key string, e enrichEntry) bool {
	return !translationInflight[key] && !enrichProvisional[key] && needsTranslationBackfill(e, key)
}

// startTranslationBackfillLocked 给正在播的那首起机翻,起了返回 true。调用方持有 enrichMu。
func startTranslationBackfillLocked(key string, e enrichEntry) bool {
	if !translationStartableLocked(key, e) {
		return false
	}
	translationInflight[key] = true
	go backfillTranslation(key)
	return true
}

// translateAfterLyricsSwapLocked:自动换正文的路径(retryLyricsUpgrade / rescoreLyrics)换完之后调,
// 只管正在播的那首。同一首播放期间 trackEnrichment 只在中继 / ListenBrainz 推送时才会再被调到,
// 不在这里起,换下来的新正文要等下一次推送或下一次播放才有译文。补空扫描 / 全量扫库换的是没在播的歌,
// 不在这里翻。调用方持有 enrichMu。
func translateAfterLyricsSwapLocked(key string) {
	if cur := enrichPlayingKey.Load(); cur == nil || *cur != key {
		return
	}
	startTranslationBackfillLocked(key, enrichCache[key])
}

// translateUpcomingLocked 给待播队列里一首已经解析好的歌补机翻,排进 prefetchTranslateSlot。
// 调用方持有 enrichMu。
func translateUpcomingLocked(key string) bool {
	e, ok := enrichCache[key]
	if !ok || !translationStartableLocked(key, e) {
		return false
	}
	translationInflight[key] = true
	go func() {
		prefetchTranslateSlot <- struct{}{}
		defer func() { <-prefetchTranslateSlot }()
		backfillTranslation(key)
	}()
	return true
}
