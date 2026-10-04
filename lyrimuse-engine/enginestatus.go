package main

import (
	"encoding/json"
	"log"
	"log/slog"
	"os"
	"sync"
	"time"
)

// 引擎 → App 的状态通道,眼下只有一件事要说:"这一轮什么都没查到,是因为网络不通"。
//
// 为什么需要它:歌词解析全空时引擎 **故意不写缓存**(见 enrich.go 里那句"全空
// (可能网络抽风)不写入,下次再试,别把偶发失败钉死")—— 这个取舍是对的,但它让界面
// 永远等不到结论:hasLyricsContent 一直是 false,悬浮窗于是一直显示"搜索歌词中…"。
// 用户看到的是"正在搜",实际是"没网,而且永远不会有结果"。
//
// 已经有过一次同类修复:"这首歌确实没有歌词"曾经也是无限期转圈,后来加了
// currentTrackHasNoLyrics 才变成"暂无歌词"(见 EnrichCacheReader 的注释)。那次解决的是
// "查过了,没有";这次解决的是"根本查不了"。
//
// 形制照抄 lyrimuse-lastfm-status.json 那条通道(引擎落盘 / Swift 按 mtime 读,
// 见 lastfm.go 的 writeLastfmMirrorStatus 和 LastfmMirrorStatus.swift):写失败只记日志,
// 它是通知通道,不是正确性依赖。
var (
	engineStatusPath string
	engineStatusMu   sync.Mutex
	// 记住上次写进去的状态,避免每一轮都重写同一份内容 —— Swift 那边按 mtime 判断要不要
	// 重新解码,无意义的重写会让它每轮都白解码一次。
	engineStatusNetworkDown bool
)

type engineStatusFile struct {
	// NetworkDown:最近一轮歌词解析期间,所有网络请求都发不出去。
	NetworkDown bool  `json:"networkDown"`
	At          int64 `json:"at"`
}

func setEngineStatusPath(path string) {
	engineStatusMu.Lock()
	engineStatusPath = path
	engineStatusMu.Unlock()
	// 启动时先清一次:上一次运行留下的"没网"跟这次进程毫无关系,留着会让界面一启动
	// 就顶着一个陈旧的错误提示。
	clearEngineNetworkDown()
}

// markEngineNetworkDown 记下"这一轮是因为网络不通而一无所获"。
func markEngineNetworkDown() {
	engineStatusMu.Lock()
	defer engineStatusMu.Unlock()
	if engineStatusPath == "" || engineStatusNetworkDown {
		return
	}
	data, err := json.Marshal(engineStatusFile{NetworkDown: true, At: time.Now().Unix()})
	if err != nil {
		return
	}
	if err := writeFileAtomic(engineStatusPath, data); err != nil {
		slog.Error("engine status: write failed", "err", err)
		return
	}
	engineStatusNetworkDown = true
	warnf("engine status: network down, every lyric source failed this round")
}

// clearEngineNetworkDown 在任何一次成功的解析之后调用 —— 有结果就说明网络是通的。
func clearEngineNetworkDown() {
	engineStatusMu.Lock()
	defer engineStatusMu.Unlock()
	if engineStatusPath == "" {
		return
	}
	// 不看 engineStatusNetworkDown 这个内存标志就直接删:进程刚起来时标志是 false,
	// 而盘上可能还留着上一次运行写下的文件。
	if err := os.Remove(engineStatusPath); err != nil && !os.IsNotExist(err) {
		warnf("engine status: clear failed: %v", err)
	}
	if engineStatusNetworkDown {
		log.Printf("engine status: network restored")
	}
	engineStatusNetworkDown = false
}
