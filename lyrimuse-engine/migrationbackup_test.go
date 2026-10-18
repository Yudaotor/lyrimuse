package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 一次性迁移的备份过了期限就删;没过期的、还在用完整格式时的 full-format 备份、手工留的备份都不碰。
func TestRemoveOldMigrationBackups(t *testing.T) {
	dir := t.TempDir()
	savedPath, savedFull := enrichPath, enrichDiskFullFormat
	t.Cleanup(func() { enrichPath, enrichDiskFullFormat = savedPath, savedFull })
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	old := time.Now().Add(-migrationBackupAge - time.Hour)
	write := func(name string, mtime time.Time) string {
		t.Helper()
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mtime, mtime); err != nil {
			t.Fatal(err)
		}
		return p
	}
	base := filepath.Base(enrichPath)
	gone := []string{
		write(base+".pre-keynorm.bak", old),
		write(base+".keynorm-20260101-120000.bak", old),
		write(base+".full-format.bak", old),
	}
	kept := []string{
		write(base, old),
		write(base+".keynorm-20261001-120000.bak", time.Now()),
		write(base+".bak-before-spotifyid-cleanup-20260923", old),
		write(base+".tmp.123", old),
		write("backup-20260903", old),
		write("other.json.pre-keynorm.bak", old),
	}

	enrichDiskFullFormat = true
	removeOldMigrationBackups()
	if _, err := os.Stat(gone[2]); err != nil {
		t.Error("盘上还是完整格式时 full-format 备份要留着")
	}
	enrichDiskFullFormat = false
	removeOldMigrationBackups()
	for _, p := range gone {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s 过期了应删掉", filepath.Base(p))
		}
	}
	for _, p := range kept {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s 不该删: %v", filepath.Base(p), err)
		}
	}
}
