package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// 失败日志定级:warnf 落 Warn、infoFailf 落 Info;错误是主动取消(链上的或被 %v 包进字符串的)一律降到 Debug。
func TestFailureLogLevels(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(prev)

	boom := errors.New("connection refused")
	warnf("relay push failed: %v", boom)
	infoFailf("soda: search failed: %v", boom)
	warnf("submit playing_now failed: %v", fmt.Errorf("post playing_now: %w", context.Canceled))
	warnf("lastfmRecent: request failed: %v", errors.New(`Get "https://x": context canceled`))
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	want := []string{"level=WARN", "level=INFO", "level=DEBUG", "level=DEBUG"}
	if len(lines) != len(want) {
		t.Fatalf("got %d lines: %q", len(lines), buf.String())
	}
	for i, w := range want {
		if !strings.Contains(lines[i], w) {
			t.Errorf("line %d want %s, got %q", i, w, lines[i])
		}
	}
	if !strings.Contains(lines[0], `msg="relay push failed: connection refused"`) {
		t.Errorf("正文要跟 log.Printf 一样按格式串展开,got %q", lines[0])
	}
}

// 正文里的时刻按 UTC 写、带 Z:本地时区的时刻转成跟行首 time= 同一口径。
func TestLogClockIsUTC(t *testing.T) {
	at := time.Date(2026, 9, 28, 20, 1, 15, 250e6, time.FixedZone("CST", 8*3600))
	if got := logClock(at); got != "12:01:15Z" {
		t.Errorf("logClock = %q", got)
	}
}
