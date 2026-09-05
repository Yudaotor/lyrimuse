package main

import (
	"fmt"
	"log"
	"os"
)

// 退出原因日志(2026-09-03)。常驻 collector 的每一条退出路径在退出前都打一行
//
//	exiting reason=<code> [detail]
//
// 形态固定、原因码英文 snake_case、可 grep(App 侧同款前缀记在 lifecycle 分类,见 AppExit.swift;
// 规则在 AGENTS.md「容易踩的具体坑 → 退出路径」)。排「collector 为什么自己退了」只需 grep 一个
// 前缀 —— 此前最常见的退出(每次 launchctl kickstart -k 重启)一行日志都没有。
//
// 走 log.Printf 而不是 fmt.Fprintln(os.Stderr):log 的输出经 logscrub.go 的脱敏出口并带 LUTC
// 时间戳。一次性子命令(search-lyrics / healthcheck / backfill-* 等)的 os.Exit / log.Fatalf 不在
// 此列 —— 那是命令行工具的正常退出码,不是"服务自己退了"。main.go 的常驻路径里不准再出现裸
// os.Exit / log.Fatalf,selftest contracts 组守着。
const (
	// 拿不到单实例锁:已有实例在跑,退出码 0 让 launchd KeepAlive 按自己的节流重试。
	exitReasonAlreadyRunning = "already_running"
	// ctx 被 SIGTERM / SIGINT 取消:launchctl kickstart -k 重启、bootout 卸载、终端 Ctrl-C。
	exitReasonSignal = "signal"
	// run() 在没被取消的情况下带错误返回。
	exitReasonRunError = "run_error"
	// 配置文件在但读不出来(权限 / IO);内容有问题不在此列,那已经降级成 loadIssues 了。
	exitReasonConfigUnreadable  = "config_unreadable"
	exitReasonHomeDirUnresolved = "home_dir_unresolved"
	// run() 没被取消也没报错就返回了 —— 理论上不该发生,记下来才看得见。
	exitReasonRunReturned = "run_returned"
)

// logExit 打退出原因;detail 为空时只有前缀。调用方随后自己 os.Exit / return。
func logExit(reason string, detail string) {
	if detail == "" {
		log.Printf("exiting reason=%s", reason)
	} else {
		log.Printf("exiting reason=%s %s", reason, detail)
	}
	// 退出前结算日志出口里攒着的折叠计数与审计汇总(logsink.go)—— 不结算的话最后
	// 一分钟的对外请求计数和"repeated N times"就随进程一起没了。
	flushLogSink()
}

// fatalExit 是 log.Fatalf 的替身:同一形态的日志 + 退出码 1。
func fatalExit(reason string, format string, args ...any) {
	logExit(reason, fmt.Sprintf(format, args...))
	os.Exit(1)
}
