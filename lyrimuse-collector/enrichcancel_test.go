package main

import (
	"context"
	"testing"
	"time"
)

// 2026-08-28 用户报「点击停止搜索之后，不是直接删除记录，而是保留记录，标记为无
// 歌词；并且灵动岛和桌面悬浮歌词都不再继续提示搜索歌词中」——之前 resolveEnrichAsync
// 的 ctx.Err() != nil 分支是纯粹的 return,什么都不写。这条测试直接验证取消场景确实会
// 落一条 ts>0、lyrics=="" 的记录进 enrichCache(EnrichCacheReader.lookup 靠 ts>0 判定
// "这一轮解析真的跑完了",见 Swift 侧 EnrichCacheReader.swift 顶部注释)——只要这条记录
// 落了盘,灵动岛/悬浮歌词/歌词管理三处就会自动统一从"搜索歌词中…"切到"暂无歌词",不需要
// 再改一行 Swift 代码,所以这里只测 collector 侧这一半。
//
// 用**已经取消**的 context 调用(不是"跑到一半再取消"),net/http 在 ctx 已 Done 时会在
// RoundTrip 阶段直接返回 ctx.Err(),不会真的建立任何连接(Go 标准库自 1.7 起的行为
// 保证)——这条测试因此不联网、不受网络环境影响,耗时应在毫秒级;10s 超时纯粹是防御性
// 兜底,不是预期耗时。
func TestResolveEnrichAsyncCancelWritesNoLyricsEntry(t *testing.T) {
	savedCache, savedPath, savedDirty := enrichCache, enrichPath, enrichDirty
	savedInflight, savedCancelFuncs := enrichInflight, enrichCancelFuncs
	t.Cleanup(func() {
		enrichCache, enrichPath, enrichDirty = savedCache, savedPath, savedDirty
		enrichInflight, enrichCancelFuncs = savedInflight, savedCancelFuncs
	})
	enrichCache = map[string]enrichEntry{}
	enrichPath = "" // 纯内存断言,不触碰磁盘——saveEnrichCache 在空路径时是安全的空操作
	enrichInflight = map[string]bool{}
	enrichCancelFuncs = map[string]context.CancelFunc{}

	const artist, title, album = "某测试歌手不存在", "某测试歌名不存在", ""
	key := enrichKey(artist, title, album)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // 调用前就取消——模拟"停止搜索"按钮点下去、enrichcancel.go 的 watcher 已经调过 cancel()

	done := make(chan struct{})
	go func() {
		resolveEnrichAsync(ctx, key, artist, title, album, "", 0, false)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("resolveEnrichAsync 在已取消的 ctx 下没能在 10s 内返回——可能哪个网络调用没有正确接住 ctx.Done()")
	}

	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok {
		t.Fatalf("取消之后应该保留一条记录(标记为暂无歌词),但 enrichCache 里完全没有 key=%q", key)
	}
	if e.Lyrics != "" {
		t.Errorf("取消场景下不该凑巧真的解析出歌词,got lyrics=%q", e.Lyrics)
	}
	if e.TS <= 0 {
		t.Errorf("TS 必须 > 0——EnrichCacheReader.lookup 靠它判定'这一轮解析真的跑完了',否则灵动岛/悬浮歌词会一直卡在'搜索歌词中…'")
	}
}
