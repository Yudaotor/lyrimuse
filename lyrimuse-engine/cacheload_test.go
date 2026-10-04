package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

// 批里的辅助缓存合成一行;批外(命令行子命令、运行中重读)的当场写一行、带文件路径。
func TestCacheLoadBatchCollapsesIntoOneLine(t *testing.T) {
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	beginCacheLoadBatch("/cfg")
	noteCacheLoaded("/cfg/a.json", "3 artist aliases")
	noteCacheLoaded("/cfg/b.json", "5 QQ artist names")
	noteCacheLoaded("/elsewhere/c.json", "1 thing")
	endCacheLoadBatch()
	noteCacheLoaded("/cfg/d.json", "2 motion-cover entries")

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 lines, got %q", buf.String())
	}
	if !strings.HasSuffix(lines[0], "cache: loaded 1 thing from /elsewhere/c.json") ||
		!strings.HasSuffix(lines[1], "cache: loaded 3 artist aliases, 5 QQ artist names from /cfg") ||
		!strings.HasSuffix(lines[2], "cache: loaded 2 motion-cover entries from /cfg/d.json") {
		t.Fatalf("got %q", lines)
	}
}
