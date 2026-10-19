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

// 主缓存这次解析不动、被挪成 .corrupt-*(或者读出错、这一场不落盘):超龄的迁移备份一份都不删 —— 这时它们可能是
// 唯一还完整的那份。读进来的那一场照常清。
func TestRemoveOldMigrationBackupsSkipsWhenCacheNotLoaded(t *testing.T) {
	old := time.Now().Add(-migrationBackupAge - time.Hour)
	writeOld := func(t *testing.T, p string) {
		t.Helper()
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, old, old); err != nil {
			t.Fatal(err)
		}
	}
	backups := func(path string) []string {
		return []string{path + ".full-format.bak", path + ".pre-keynorm.bak", path + ".keynorm-20260101-120000.bak"}
	}

	t.Run("解析不动、挪走了", func(t *testing.T) {
		withTempIndexCache(t)
		saveEnrichLoadFlags(t)
		savedFull := enrichDiskFullFormat
		t.Cleanup(func() { enrichDiskFullFormat = savedFull })
		path := enrichPath
		if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
			t.Fatal(err)
		}
		for _, p := range backups(path) {
			writeOld(t, p)
		}
		loadEnrichCache(path)
		if matches, _ := filepath.Glob(path + ".corrupt-*"); len(matches) != 1 {
			t.Fatalf("前提:主缓存挪成了 .corrupt-*: %v", matches)
		}
		removeOldMigrationBackups()
		for _, p := range backups(path) {
			if _, err := os.Stat(p); err != nil {
				t.Errorf("主缓存刚被挪走,%s 要留着: %v", filepath.Base(p), err)
			}
		}
	})

	t.Run("读出错", func(t *testing.T) {
		dir := withTempIndexCache(t)
		saveEnrichLoadFlags(t)
		path := filepath.Join(dir, "cache-is-a-dir.json")
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, p := range backups(path) {
			writeOld(t, p)
		}
		loadEnrichCache(path)
		removeOldMigrationBackups()
		for _, p := range backups(path) {
			if _, err := os.Stat(p); err != nil {
				t.Errorf("主缓存没读进来,%s 要留着: %v", filepath.Base(p), err)
			}
		}
	})

	t.Run("读进来了", func(t *testing.T) {
		withTempIndexCache(t)
		saveEnrichLoadFlags(t)
		savedFull := enrichDiskFullFormat
		t.Cleanup(func() { enrichDiskFullFormat = savedFull })
		path := enrichPath
		if err := os.WriteFile(path, []byte(`{"a|t|b":{"lyrics":"[00:01.00]hi"}}`), 0o600); err != nil {
			t.Fatal(err)
		}
		for _, p := range backups(path) {
			writeOld(t, p)
		}
		loadEnrichCache(path)
		enrichDiskFullFormat = false
		removeOldMigrationBackups()
		for _, p := range backups(path) {
			if _, err := os.Stat(p); !os.IsNotExist(err) {
				t.Errorf("读进来的那一场照常清 %s: %v", filepath.Base(p), err)
			}
		}
	})
}
