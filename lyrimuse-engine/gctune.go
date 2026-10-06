package main

import (
	"os"
	"runtime/debug"
)

// daemonGCPercent 常驻进程的回收目标:堆长到上一轮回收后存活量的 1.5 倍就回收(Go 默认 2 倍)。存活量的大头是
// 整份歌词缓存,默认那一档要多占百来 MB(见 15 章决策 20)。
//
// 别换成固定的内存上限(debug.SetMemoryLimit):存活量跟着曲库长,超过上限之后回收会一刻不停地跑。
const daemonGCPercent = 50

// tuneDaemonGC 只给常驻进程调,放在加载缓存之前。环境变量 GOGC 设了就照它。
func tuneDaemonGC() {
	if os.Getenv("GOGC") != "" {
		return
	}
	debug.SetGCPercent(daemonGCPercent)
}
