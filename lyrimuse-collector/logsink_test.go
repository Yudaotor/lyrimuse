package main

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 等级解析:大小写不敏感、空串 = info、warning 是 warn 的别名、认不出报 false。
func TestParseLogLevel(t *testing.T) {
	cases := map[string]slog.Level{
		"debug": slog.LevelDebug, "INFO": slog.LevelInfo, "": slog.LevelInfo,
		" warn ": slog.LevelWarn, "warning": slog.LevelWarn, "error": slog.LevelError,
	}
	for in, want := range cases {
		got, ok := parseLogLevel(in)
		if !ok || got != want {
			t.Fatalf("parseLogLevel(%q) = %v,%v; want %v,true", in, got, ok, want)
		}
	}
	if _, ok := parseLogLevel("verbose"); ok {
		t.Fatalf("unknown level must not parse")
	}
}

// handler 输出:时间是 UTC RFC3339 毫秒带 Z,等级与 key=value 都在;低于等级的记录不写。
func TestLogHandler_TimeFormatAndLevel(t *testing.T) {
	var buf bytes.Buffer
	prevLevel := logLevel.Level()
	defer logLevel.Set(prevLevel)
	logLevel.Set(slog.LevelInfo)
	lg := slog.New(newLogHandler(&buf))
	lg.Debug("hidden")
	lg.Info("enrich: hello", "count", 3)
	out := buf.String()
	if strings.Contains(out, "hidden") {
		t.Fatalf("debug record must be filtered at info level: %q", out)
	}
	if !strings.HasPrefix(out, "time=20") || !strings.Contains(out, "Z level=INFO msg=\"enrich: hello\" count=3") {
		t.Fatalf("unexpected line shape: %q", out)
	}
	ts := strings.TrimPrefix(strings.Fields(out)[0], "time=")
	if _, err := time.Parse(logTimeLayout, ts); err != nil {
		t.Fatalf("time attr %q does not parse as %s: %v", ts, logTimeLayout, err)
	}
}

// 模板口径:去掉 time= 属性、数字抹成 #。
func TestLineTemplate(t *testing.T) {
	a := lineTemplate("time=2026-09-05T00:00:01.000Z level=WARN msg=\"api call: POST x FAILED\" elapsed_ms=10001\n")
	b := lineTemplate("time=2026-09-05T00:00:07.500Z level=WARN msg=\"api call: POST x FAILED\" elapsed_ms=9800\n")
	if a != b {
		t.Fatalf("lines differing only in time/digits must share a template:\n%q\n%q", a, b)
	}
	c := lineTemplate("time=2026-09-05T00:00:07.500Z level=INFO msg=\"api call: POST x FAILED\" elapsed_ms=9800\n")
	if a == c {
		t.Fatalf("different level must be a different template")
	}
}

// 折叠:连续同模板只写第一条,换一条时补 "repeated N times";超过窗口后同一条重新完整打印。
func TestRepeatSquelcher_FoldsConsecutiveRepeats(t *testing.T) {
	var buf bytes.Buffer
	sq := newRepeatSquelcher(&buf)
	now := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	sq.now = func() time.Time { return now }
	write := func(s string) {
		if _, err := sq.Write([]byte(s)); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	write("time=2026-09-05T00:00:00.000Z level=INFO msg=\"submit failed after 10001ms\"\n")
	now = now.Add(5 * time.Second)
	write("time=2026-09-05T00:00:05.000Z level=INFO msg=\"submit failed after 9900ms\"\n")
	now = now.Add(5 * time.Second)
	write("time=2026-09-05T00:00:10.000Z level=INFO msg=\"submit failed after 10200ms\"\n")
	if got := strings.Count(buf.String(), "submit failed"); got != 1 {
		t.Fatalf("only the first of a run must be written, got %d lines: %q", got, buf.String())
	}
	now = now.Add(time.Second)
	write("time=2026-09-05T00:00:11.000Z level=INFO msg=\"now playing: track 1\"\n")
	out := buf.String()
	if !strings.Contains(out, "msg=\"last message repeated 2 times\"") {
		t.Fatalf("switching template must emit the repeat count, got: %q", out)
	}
	if idx := strings.Index(out, "repeated 2 times"); idx > strings.Index(out, "now playing") {
		t.Fatalf("repeat count must precede the new line, got: %q", out)
	}
	// 只差数字的同模板行在窗口内被折;窗口外再出现:完整打印,并结算之前攒的计数。
	// (字母不同就是不同模板 —— "track 1" 和 "song 1" 不折,这是有意的:抹的只有数字。)
	buf.Reset()
	now = now.Add(2 * time.Second)
	write("time=2026-09-05T00:00:13.000Z level=INFO msg=\"now playing: track 2\"\n")
	if buf.Len() != 0 {
		t.Fatalf("same template within the window must be folded, got: %q", buf.String())
	}
	now = now.Add(repeatSquelchWindow + time.Second)
	write("time=2026-09-05T00:01:14.000Z level=INFO msg=\"now playing: track 3\"\n")
	out = buf.String()
	if !strings.Contains(out, "repeated 1 times") || !strings.Contains(out, "now playing: track 3") {
		t.Fatalf("after the window the line prints in full and the pending count is settled, got: %q", out)
	}
	// Flush:窗口内不结算(可能马上又来),窗口外结算并清模板。
	buf.Reset()
	now = now.Add(time.Second)
	write("time=2026-09-05T00:01:15.000Z level=INFO msg=\"now playing: track 4\"\n")
	sq.Flush()
	if strings.Contains(buf.String(), "repeated") {
		t.Fatalf("Flush inside the window must not settle, got: %q", buf.String())
	}
	now = now.Add(repeatSquelchWindow + time.Second)
	sq.Flush()
	if !strings.Contains(buf.String(), "repeated 1 times") {
		t.Fatalf("Flush after the window must settle, got: %q", buf.String())
	}
}

// 运行期轮转:累计写入要越过上限时先归档成 .old、新开一份;轮转事件那一行写在新文件开头。
func TestRotatingLogFile_RotatesAtRuntime(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse.log")
	if err := os.WriteFile(path, []byte("old line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := openRotatingLogFile(path, 40)
	if r == nil {
		t.Fatalf("openRotatingLogFile returned nil")
	}
	if r.rotatedAtOpen {
		t.Fatalf("9 bytes is below the 40-byte cap, must not rotate at open")
	}
	if _, err := r.Write([]byte("second line, 20 bytes\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Write([]byte("third line pushes past the cap\n")); err != nil {
		t.Fatal(err)
	}
	old, err := os.ReadFile(path + ".old")
	if err != nil {
		t.Fatalf("expected an archived .old file: %v", err)
	}
	if !strings.Contains(string(old), "old line") || !strings.Contains(string(old), "second line") {
		t.Fatalf("archive must hold everything written before the rotation, got: %q", old)
	}
	cur, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(cur)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], "msg=\"log: rotated") || lines[1] != "third line pushes past the cap" {
		t.Fatalf("new file must start with the rotation marker then the triggering line, got: %q", cur)
	}
}

// 子命令判定:无参数 / 只有 flag = 常驻;有子命令名 = 子命令。
func TestIsDaemonInvocation(t *testing.T) {
	if !isDaemonInvocation([]string{"collector"}) || !isDaemonInvocation([]string{"collector", "-dry-run"}) {
		t.Fatalf("no subcommand must count as daemon")
	}
	if isDaemonInvocation([]string{"collector", "healthcheck"}) {
		t.Fatalf("a subcommand must not count as daemon")
	}
}
