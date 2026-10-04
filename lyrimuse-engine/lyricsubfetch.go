package main

import (
	"context"
	"sync/atomic"
)

// 歌词源一次解析里「附带的子请求」(逐字、译文、罗马音、老接口的整行歌词)有没有没问成。挂在 ctx 上,各源的
// 进程内缓存据此决定这份结果能不能缓存:主歌词拿到了、逐字那一趟却超时 / 被限流 / 连不上时,缓存下来就再也
// 补不回来了 —— 常驻进程里之后的解析、重评全命中这份残缺的,要等进程重启。「问成了、这首没有」不算没问成。
type lyricSubFetch struct{ failed atomic.Bool }

// lyricSourceResponseMaxBytes 各歌词源 JSON 应答一次最多读多少。正常应答几十 KB;不封顶的话一个出错的(或者
// 被中途篡改的明文 http)应答能让解码一直读下去。
const lyricSourceResponseMaxBytes = 8 << 20

type lyricSubFetchKey struct{}

// withLyricSubFetch 给这一次解析挂一个记录器。嵌套调用时各记各的(内层的失败不冒泡到外层)。
func withLyricSubFetch(ctx context.Context) (context.Context, *lyricSubFetch) {
	f := &lyricSubFetch{}
	return context.WithValue(ctx, lyricSubFetchKey{}, f), f
}

// noteLyricSubFetchFailure 记一次子请求没问成。ctx 上没挂记录器时什么都不做。
func noteLyricSubFetchFailure(ctx context.Context) {
	if f, ok := ctx.Value(lyricSubFetchKey{}).(*lyricSubFetch); ok {
		f.failed.Store(true)
	}
}

// complete:这一次解析的结果是完整的 —— ctx 没被取消、子请求都问成了。
func (f *lyricSubFetch) complete(ctx context.Context) bool {
	return ctx.Err() == nil && !f.failed.Load()
}
