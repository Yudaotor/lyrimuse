package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 「临时文件 + 改名」写进目录:收到信号。
func TestWatchDirWritesSeesAtomicReplace(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := make(chan struct{}, 1)
	if !watchDirWrites(ctx, dir, ch) {
		t.Fatal("盯不了一个存在的目录")
	}
	tmp := filepath.Join(dir, "state.json.tmp")
	if err := os.WriteFile(tmp, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, filepath.Join(dir, "state.json")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("原子写落盘之后没收到信号")
	}
}

// 目录不存在:返回 false,调用方退回定时器。
func TestWatchDirWritesMissingDir(t *testing.T) {
	if watchDirWrites(context.Background(), filepath.Join(t.TempDir(), "missing"), make(chan struct{}, 1)) {
		t.Fatal("目录不存在时该返回 false")
	}
}

// ctx 结束:监听 goroutine 退出、描述符关掉,不靠定时醒。
func TestStartDirWatchStopsOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	stopped, ok := startDirWatch(ctx, t.TempDir(), make(chan struct{}, 1))
	if !ok {
		t.Fatal("盯不了一个存在的目录")
	}
	cancel()
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("ctx 结束之后监听没有退出")
	}
}

// 请求循环:盯得了目录时目录一变就叫醒;盯不了时退回按 poll 轮询。
func TestRequestWakeups(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dir := t.TempDir()
	writes, ticker := requestWakeups(ctx, dir, time.Hour)
	defer ticker.Stop()
	if err := os.WriteFile(filepath.Join(dir, "req.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-writes:
	case <-time.After(2 * time.Second):
		t.Fatal("目录变了没有叫醒")
	}
	_, fallback := requestWakeups(ctx, filepath.Join(dir, "missing"), 10*time.Millisecond)
	defer fallback.Stop()
	select {
	case <-fallback.C:
	case <-time.After(2 * time.Second):
		t.Fatal("盯不了目录时没有按 poll 轮询")
	}
}
