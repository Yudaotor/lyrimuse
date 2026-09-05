package main

import (
	"os"
	"path/filepath"
)

// configDir 是 collector 一切落盘的根:config.json、features、enrich 缓存、歌词、封面、收听日志、状态文件、
// 单实例锁全在它下面。常驻路径以 `-config` 的目录为准(默认值就是这里),全部一次性子命令直接取这里。
//
// 环境变量 LYRIMUSE_CONFIG_DIR(绝对路径)优先(2026-09-05,借鉴清单 #33):App 侧 CollectorServiceManager 写
// launchd plist、以及 spawn 每个一次性子命令时都会传 —— 正式版传的就是这里的默认值(2026-09-05 曾给并排安装的开发
// 构建传另一个目录,2026-09-06 已整体回退;机制保留,别再靠 os.UserHomeDir 自己拼路径)。Swift 侧的对应口径是 LyrimuseCore 的 LyrimusePaths。
//
// 没有环境变量、又拿不到家目录时返回空串,调用方按原来的方式报错(main.go 常驻路径直接 fatalExit)。
func configDir() string {
	if v := os.Getenv("LYRIMUSE_CONFIG_DIR"); v != "" && filepath.IsAbs(v) {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", clientName)
}

// configFilePath 是配置目录下的一个文件(或子目录)。
func configFilePath(name string) string {
	return filepath.Join(configDir(), name)
}

// appBundleID 是「本 collector 所属的那个 App」的 bundle id —— companion launch 拿它 `open -b`。环境变量
// LYRIMUSE_APP_BUNDLE_ID 优先(App 侧跟另外两个变量一起写进 plist / 子进程环境),缺省是正式版
// (这一层是给别的 bundle id 的构建用的,2026-09-06 回退 Dev 变体后没有这种构建,机制保留)。
func appBundleID() string {
	if v := os.Getenv("LYRIMUSE_APP_BUNDLE_ID"); v != "" {
		return v
	}
	return "me.yudaotor.lyrimuse"
}

// logFilePath 是常驻进程日志文件:launchd 的 StandardOutPath/StandardErrorPath 指向它,collector 自己也打开它写
// 并按大小轮转(logsink.go / logrotate.go)。环境变量 LYRIMUSE_LOG_FILE(绝对路径)优先,理由同上;Swift 侧对应
// LyrimuseCore 的 LogFiles.collector。拿不到家目录时返回空串,调用方据此放弃轮转、退回 stderr,不阻塞启动。
func logFilePath() string {
	if v := os.Getenv("LYRIMUSE_LOG_FILE"); v != "" && filepath.IsAbs(v) {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Logs", clientName+".log")
}
