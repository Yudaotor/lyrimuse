package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"
)

// 手动停止"正在搜索"占位行(2026-08-28,用户反馈这段等待没有任何上限——歌词那一步有
// lyricSearchDeadline 兜底,但 resolveTrackEnrichment 整体(还跟着 MusicBrainz/Apple
// Music/QQ 兜底封面这几步顺序网络请求)没有总超时,某一步卡住时占位行会一直挂着,此前
// 用户没有任何退出方式)。
//
// App 侧(LyricsManagerView.swift 的 cancelPlaceholderSearch)往 enrichCancelRequestPath
// 写一个纯文本文件,内容就是要取消的缓存 key(EnrichCacheKeys.normalizedKey 拼出来的
// "artist|title|album",跟 resolveEnrichAsync 用的是同一个 key 空间,逐字节一致)。这里
// 用一个独立的 1s ticker 检查这个文件,读到 key 就去 enrichCancelFuncs 登记表(见
// enrich.go 的 var 块、resolveEnrichAsync)里找对应的 context.CancelFunc,找到就调用——
// 真正让 resolveTrackEnrichment 内部还在飞的网络请求中断,不是"隔着进程装个样子"。
//
// 检查间隔意味着不是瞬时生效(最多等 1s),但比完全没有退出方式好得多;跟
// startCompanionLaunchWatcher 是同一个"独立节奏的后台 watcher,由 run() 单开 goroutine,
// ctx 取消时退出"模式。

var enrichCancelRequestPath string

// setEnrichCancelRequestPath 在 main() 启动时调一次,顺带清掉上一次运行遗留的请求文件——
// 那份文件跟这次进程/这一轮解析无关,留着会在这次进程刚起来、还没有任何 key 在飞的时候被
// 误当成"要取消某个 key"处理。查不到对应的 CancelFunc 本身是安全的空操作(见
// checkEnrichCancelRequest),这里清掉纯粹是不想让下一次检查白跑这一轮、多打一行无意义
// 的日志。
func setEnrichCancelRequestPath(path string) {
	enrichCancelRequestPath = path
	_ = os.Remove(path)
}

// 1s——跟 companionLaunchInterval 同一个量级,给"用户点了停止按钮"这类交互式操作留够
// 响应感,又不会因为检查本身(一次 os.ReadFile,大多数轮次文件都不存在)有任何可感知的
// 资源代价。
const enrichCancelCheckInterval = 1 * time.Second

// startEnrichCancelWatcher 独立于 poller.go 的主轮询跑,由 run() 用单独的 goroutine
// 启动,ctx 取消时退出。
func startEnrichCancelWatcher(ctx context.Context) {
	if enrichCancelRequestPath == "" {
		return
	}
	ticker := time.NewTicker(enrichCancelCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			checkEnrichCancelRequest()
		}
	}
}

// checkEnrichCancelRequest 读一次请求文件、无条件消费掉(不管有没有真的找到对应的
// in-flight 搜索都删除)——这份文件只是个一次性信号,不是需要持续存在的状态。
func checkEnrichCancelRequest() {
	data, err := os.ReadFile(enrichCancelRequestPath)
	if err != nil {
		return // 大多数轮次文件不存在,是正常状态,不用打日志刷屏
	}
	_ = os.Remove(enrichCancelRequestPath)
	key := strings.TrimSpace(string(data))
	if key == "" {
		return
	}
	enrichMu.Lock()
	cancel, ok := enrichCancelFuncs[key]
	enrichMu.Unlock()
	if !ok {
		// 大概率是这一轮已经自然跑完了(结果已经写进缓存,或者刚巧在这一刻还没来得及
		// 登记)——用户点"停止"和 resolveEnrichAsync 真正收尾之间本来就有一段竞态窗口,
		// 查不到不代表哪里坏了,不用报错级别。
		log.Printf("enrich cancel: no in-flight search found for key=%q (already finished, or never started)", key)
		return
	}
	log.Printf("enrich cancel: cancelling in-flight search for key=%q", key)
	cancel()
}
