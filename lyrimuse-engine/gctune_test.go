package main

import (
	"os"
	"runtime/debug"
	"strings"
	"testing"
)

func TestTuneDaemonGC(t *testing.T) {
	defer debug.SetGCPercent(debug.SetGCPercent(100))
	t.Setenv("GOGC", "")
	tuneDaemonGC()
	if got := debug.SetGCPercent(100); got != daemonGCPercent {
		t.Fatalf("没设 GOGC 时回收目标应是 %d,实际 %d", daemonGCPercent, got)
	}
	t.Setenv("GOGC", "80")
	debug.SetGCPercent(80)
	tuneDaemonGC()
	if got := debug.SetGCPercent(100); got != 80 {
		t.Fatalf("设了 GOGC 时照环境变量,实际被改成 %d", got)
	}
}

// 常驻进程在加载歌词缓存之前调 tuneDaemonGC:加载那一下的临时分配最多,放在后面就白白先涨到默认那一档。
func TestMainTunesGCBeforeLoadingEnrichCache(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("读 main.go: %v", err)
	}
	s := string(src)
	tune, load := strings.Index(s, "\ttuneDaemonGC()\n"), strings.Index(s, "\tloadEnrichCache(")
	if tune < 0 || load < 0 || tune > load {
		t.Fatalf("main.go 里 tuneDaemonGC() 要在 loadEnrichCache( 之前(位置 %d / %d)", tune, load)
	}
	if lock := strings.Index(s, "acquireSingleInstanceLock("); lock < 0 || lock > tune {
		t.Fatalf("tuneDaemonGC() 要在常驻路径里(拿单实例锁之后),一次性子命令不改回收目标")
	}
}
