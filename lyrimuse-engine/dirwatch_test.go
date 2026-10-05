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
