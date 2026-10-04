package main

import (
	"errors"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestParserDriftThresholdPersistAndReset(t *testing.T) {
	path := filepath.Join(t.TempDir(), "drift.json")
	parserDriftMu.Lock()
	oldPath, oldMap := parserDriftPath, parserDrift
	parserDriftPath, parserDrift = path, map[string]*parserDriftEntry{}
	parserDriftMu.Unlock()
	t.Cleanup(func() {
		parserDriftMu.Lock()
		parserDriftPath, parserDrift = oldPath, oldMap
		parserDriftMu.Unlock()
	})

	for i := 0; i < parserDriftThreshold-1; i++ {
		noteParserUnrecognized("x", "shape")
	}
	if got := loadParserDriftFile(path); len(got) != 0 {
		t.Fatalf("阈值之前不该落盘: %v", got)
	}
	if n := parserDriftingNames(); len(n) != 0 {
		t.Fatalf("阈值之前不算: %v", n)
	}
	noteParserUnrecognized("x", "shape")
	got := loadParserDriftFile(path)
	if e, ok := got["x"]; !ok || e.Streak != parserDriftThreshold || e.Detail != "shape" {
		t.Fatalf("到阈值应落盘: %v", got)
	}

	// 重启之后读回来,计数接着往上加。
	parserDriftMu.Lock()
	parserDrift = map[string]*parserDriftEntry{}
	parserDriftMu.Unlock()
	setParserDriftPath(path)
	noteParserUnrecognized("x", "shape")
	if e := loadParserDriftFile(path)["x"]; e.Streak != parserDriftThreshold+1 {
		t.Fatalf("重启后计数应接着加: %+v", e)
	}

	noteParserRecognized("x")
	if got := loadParserDriftFile(path); len(got) != 0 {
		t.Fatalf("认出一次应清掉: %v", got)
	}
	if n := parserDriftingNames(); len(n) != 0 {
		t.Fatalf("认出一次应清掉: %v", n)
	}
}

func TestSqliteSchemaMismatch(t *testing.T) {
	schema := &exec.ExitError{Stderr: []byte("Parse error near line 1: no such table: SONGS\n")}
	locked := &exec.ExitError{Stderr: []byte("Error: database is locked\n")}
	if !sqliteSchemaMismatch(schema) {
		t.Error("no such table 应算改了库结构")
	}
	if sqliteSchemaMismatch(locked) || sqliteSchemaMismatch(errors.New("no such column: x")) {
		t.Error("库被锁 / 不是 sqlite3 退出错误都不算")
	}
	if got := sqliteErrorDetail(schema); got != "Parse error near line 1: no such table: SONGS" {
		t.Errorf("detail = %q", got)
	}
}
