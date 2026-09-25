package main

import (
	"os"
	"path/filepath"
	"testing"
)

// 水位闸的行为契约。它决定 migrateLyricTimelines 这类存量迁移跑不跑,判错的代价是
// **静默少跑一道迁移** —— 不报错、不红、只有存量数据一直停在旧形态,所以每一条都钉住。
func TestStartupMigrationState(t *testing.T) {
	saved, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() { migrationState, migrationStatePath = saved, savedPath })

	path := filepath.Join(t.TempDir(), "migrations.json")
	loadMigrationState(path)

	// 没跑过 → 该跑。
	if migrationDone("x", 1) {
		t.Error("水位文件不存在时该判为没跑过")
	}
	markMigrationDone("x", 1)
	if !migrationDone("x", 1) {
		t.Error("标记完该判为跑过")
	}

	// 版本号是"改了算法就重扫存量"的唯一开关:水位停在 1 时,要求 2 必须判为没跑过。
	if migrationDone("x", 2) {
		t.Error("水位低于要求的版本时该判为没跑过(改算法后存量要重扫)")
	}

	// 落了盘,新进程读得回来。
	migrationState = nil
	loadMigrationState(path)
	if !migrationDone("x", 1) {
		t.Error("水位该落盘并在重新载入后仍然成立")
	}

	// 外来数据进来 → 全部作废。
	invalidateMigrationState("test")
	if migrationDone("x", 1) {
		t.Error("作废之后该判为没跑过")
	}
	migrationState = nil
	loadMigrationState(path)
	if migrationDone("x", 1) {
		t.Error("作废要落盘,不能只改内存")
	}
}

// 路径没设 = 各 CLI 子命令的形态:水位必须整个失效,行为与加这层之前逐字节一致。
// 判反了的后果是 CLI 里那些迁移被静默跳过。
func TestStartupMigrationStateDisabledWithoutPath(t *testing.T) {
	saved, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() { migrationState, migrationStatePath = saved, savedPath })

	migrationStatePath = ""
	migrationState = map[string]int{"x": 9}
	if migrationDone("x", 1) {
		t.Error("没有水位文件路径时,水位必须整个失效(CLI 子命令要跟加这层之前一样全量跑)")
	}
	// 写也不能写出去 —— 没有路径可写,更不能 panic。
	markMigrationDone("x", 1)
	invalidateMigrationState("test")
}

// 水位文件坏了(手工编辑坏、写一半崩)必须退化成"全部重跑",不能退化成"全部跳过" ——
// 这一层最坏的失效方式只允许是多跑一遍。
func TestStartupMigrationStateCorruptFileRerunsEverything(t *testing.T) {
	saved, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() { migrationState, migrationStatePath = saved, savedPath })

	path := filepath.Join(t.TempDir(), "migrations.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	loadMigrationState(path)
	if migrationDone(migrationLyricTimelines, migrationLyricTimelinesVersion) {
		t.Error("水位文件解不出来时该判为一道都没跑过")
	}
}
