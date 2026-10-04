package main

import (
	"context"
	"sync"
)

// 每个歌词源同时在途的请求上限。令牌桶(hostguard.go)管的是「每秒发多少」,管不住「同一瞬间有多少个在飞」:
// 救急别名并发(rescuefanout.go)几支同时开查时,同一个源一下子会有十来个请求一起出去,服务端按并发限流的
// (QQ 的 5xx、lrclib 的 503 都是这种时候成片出现)就会拒。超过上限的请求在这里排队(跟着请求自己的 ctx
// 走,取消了就不等),拿到响应就归还名额 —— 响应体一般几 KB,读取不占多久。按源计,不按主机:同一个源的
// 几个备用主机背后是同一套服务。不是歌词源的主机不管。见 09 章决策 102 第七批。
var lyricSourceInflightCaps = map[string]int{"qq": 4, "lrclib": 3, "musixmatch": 3}

// lyricSourceInflightDefault:没单独列上限的歌词源。正常一轮每个源同时在途不超过三四个(QQ 各标题变体并发、
// 取词两路并发),这个数只削并发救急的尖峰。
const lyricSourceInflightDefault = 6

var (
	lyricSourceSlotsMu sync.Mutex
	lyricSourceSlots   = map[string]chan struct{}{}
)

func lyricSourceSlotsFor(source string) chan struct{} {
	lyricSourceSlotsMu.Lock()
	defer lyricSourceSlotsMu.Unlock()
	ch := lyricSourceSlots[source]
	if ch == nil {
		n := lyricSourceInflightCaps[source]
		if n <= 0 {
			n = lyricSourceInflightDefault
		}
		ch = make(chan struct{}, n)
		lyricSourceSlots[source] = ch
	}
	return ch
}

// acquireLyricSourceSlot:给发往 host 的请求占一个名额;不是歌词源的主机直接放行。返回的 release 必须调用一次。
func acquireLyricSourceSlot(ctx context.Context, host string) (release func(), err error) {
	source := lyricSourceForHost(host)
	if source == "" {
		return func() {}, nil
	}
	ch := lyricSourceSlotsFor(source)
	select {
	case ch <- struct{}{}:
		var once sync.Once
		return func() { once.Do(func() { <-ch }) }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
