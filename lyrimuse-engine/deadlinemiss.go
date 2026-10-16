package main

import (
	"context"
	"sync"
)

// 被一轮总截止(lyricSearchDeadline)掐掉的源:那一轮 20 秒里一份结果都没交。截止取消的请求不计进熔断(它不是源的错,
// 有时只是那一轮开头被别的请求排在了后面),所以 lyricSourcesWorthRetry 照样把它当「缺着、值得换个名字再问」的源 ——
// 而它若本来就是要串好几步请求的慢源,之后每一个补缺席源的轮次(别名轮最多 lyricAliasMissingMaxTries 轮、ISRC 轮……)
// 都会再等满一整轮截止,一首歌的最终结果被拖到一两分钟。记下来,同一次解析里这些补缺席的轮次就不再为它跑;
// 全源重查的救急轮(一个能用的候选都没有)照常问它。
//
// 挂在 ctx 上、按一次解析(scoredLyricCandidatesStreaming 最外层那一次)计:换一首歌、下一次解析从空开始。

type lyricDeadlineMissKey struct{}

type lyricDeadlineMisses struct {
	mu      sync.Mutex
	sources map[string]bool
}

// withLyricDeadlineMisses:ctx 上还没有就挂一份空的;已经有了(重入、补查轮)原样返回,同一次解析共用一份。
func withLyricDeadlineMisses(ctx context.Context) context.Context {
	if _, ok := ctx.Value(lyricDeadlineMissKey{}).(*lyricDeadlineMisses); ok {
		return ctx
	}
	return context.WithValue(ctx, lyricDeadlineMissKey{}, &lyricDeadlineMisses{sources: map[string]bool{}})
}

// noteLyricDeadlineMiss:这一轮截止时 source 还没交结果。ctx 上没挂(单测直接调 fetch 的)就不记。
func noteLyricDeadlineMiss(ctx context.Context, source string) {
	m, ok := ctx.Value(lyricDeadlineMissKey{}).(*lyricDeadlineMisses)
	if !ok {
		return
	}
	m.mu.Lock()
	m.sources[source] = true
	m.mu.Unlock()
}

// lyricDeadlineMissed:同一次解析里 source 有没有被截止掐掉过。
func lyricDeadlineMissed(ctx context.Context, source string) bool {
	m, ok := ctx.Value(lyricDeadlineMissKey{}).(*lyricDeadlineMisses)
	if !ok {
		return false
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sources[source]
}
