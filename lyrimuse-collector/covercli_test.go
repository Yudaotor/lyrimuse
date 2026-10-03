//go:build devtools

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// 预演的子命令只读加载,不设落盘路径。
func TestLoadEnrichCacheForCLIDryRunIsReadOnly(t *testing.T) {
	dir := withTempDecisionCache(t)
	enrichMu.Lock()
	enrichPath = ""
	enrichMu.Unlock()
	p := filepath.Join(dir, "cache.json")
	if err := os.WriteFile(p, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	loadEnrichCacheForCLI(p, false)
	if enrichPath != "" {
		t.Fatal("预演不该设落盘路径")
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatal("预演不该把坏文件挪走")
	}
}
