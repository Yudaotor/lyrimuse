package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
)

// 单实例锁。两个 collector 同时活着的时候,各自的内存缓存大小不同,谁后保存谁赢 ——
// 2026-08-16 实锤:build.sh 反复重启期间新旧实例短暂共存,204 条的歌词缓存被磨到 10 条。
// flock 是随进程消亡自动释放的,崩溃/被 kill 都不会留下死锁文件。
var singleInstanceLockFile *os.File

// acquireSingleInstanceLock 拿不到锁 = 已有别的实例在跑,返回 false,调用方直接退出。
// 锁**文件**本身打不开(权限/磁盘之类)不拦启动 —— 保护机制自己坏了不该把正主拖死。
func acquireSingleInstanceLock(dir string) bool {
	path := filepath.Join(dir, "collector.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		log.Printf("single-instance lock unavailable (%v), continuing without it", err)
		return true
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return false
	}
	// 句柄挂在包级变量上防 GC 关闭(关了锁就没了);进程退出时由内核自动释放。
	singleInstanceLockFile = f
	_ = f.Truncate(0)
	_, _ = fmt.Fprintf(f, "%d\n", os.Getpid())
	return true
}
