package main

import (
	"context"
	"time"
)

// withCancelAfter:跟 context.WithTimeout 一样到点就停,只是停的方式是取消。打歌词源的请求设时间预算一律用它:
// 到点被停的请求报 context.Canceled,熔断和网络失败计数都不算(时间预算是我们自己定的,对方没出错);WithTimeout
// 报的 DeadlineExceeded 会被记成这个源的网络失败,连着两次就把源熔断。见 15 章「健康检查的联网探测有时限」、09 章决策 272。
//
// 派生出来的 ctx 没有 Deadline:出站闸排队时按 maxWait 封顶,到点由取消叫停。
func withCancelAfter(parent context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	t := time.AfterFunc(d, cancel)
	return ctx, func() {
		t.Stop()
		cancel()
	}
}
