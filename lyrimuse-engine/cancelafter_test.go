package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 到点停,停的方式是取消:请求报 context.Canceled,熔断不算。
func TestWithCancelAfter(t *testing.T) {
	ctx, cancel := withCancelAfter(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, has := ctx.Deadline(); has {
		t.Fatal("不该带截止时间:带了的话到点报的是超时")
	}
	<-ctx.Done()
	if !errors.Is(ctx.Err(), context.Canceled) {
		t.Fatalf("到点应是取消: %v", ctx.Err())
	}
	ctx2, cancel2 := withCancelAfter(context.Background(), time.Hour)
	cancel2()
	if ctx2.Err() == nil {
		t.Fatal("调用方 cancel 应当立刻停")
	}
}

// 打歌词源的请求设时间预算不用 context.WithTimeout(见 withCancelAfter)。本地查询(sqlite3 / plutil 子进程)不算。
func TestLyricSourceBudgetsUseCancelAfter(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	prefixes := []string{"qq", "netease", "kugou", "kuwo", "migu", "soda", "deezer", "musixmatch", "ytmusic", "lrclib", "applemusic", "amll"}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		ok := false
		for _, p := range prefixes {
			if strings.HasPrefix(f, p) {
				ok = true
			}
		}
		if !ok {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(string(b), "\n")
		for i, line := range lines {
			if !strings.Contains(line, "context.WithTimeout(") || strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			window := strings.Join(lines[i:min(i+6, len(lines))], "\n")
			if strings.Contains(window, "exec.CommandContext(") {
				continue
			}
			t.Errorf("%s:%d 打歌词源的时间预算改用 withCancelAfter: %s", f, i+1, strings.TrimSpace(line))
		}
	}
}
