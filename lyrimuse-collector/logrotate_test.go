package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotateLogIfNeeded_BelowThreshold_NoRotation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse.log")
	if err := os.WriteFile(path, []byte("small"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, rotated := rotateLogIfNeeded(path, 100)
	if rotated {
		t.Fatalf("expected no rotation for a file under the threshold")
	}
	if _, err := os.Stat(path + ".old"); !os.IsNotExist(err) {
		t.Fatalf("expected no .old file to be created, got err=%v", err)
	}
}

func TestRotateLogIfNeeded_MissingFile_NoRotation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "does-not-exist.log")
	_, rotated := rotateLogIfNeeded(path, 100)
	if rotated {
		t.Fatalf("expected no rotation for a missing file")
	}
}

func TestRotateLogIfNeeded_EmptyPath_FallsBackToStderr(t *testing.T) {
	w, rotated := rotateLogIfNeeded("", 100)
	if rotated {
		t.Fatalf("expected no rotation for an empty path")
	}
	if w != os.Stderr {
		t.Fatalf("expected the fallback writer to be os.Stderr when path is empty")
	}
}

func TestRotateLogIfNeeded_AboveThreshold_ArchivesAndOpensFresh(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse.log")
	oldContent := strings.Repeat("x", 200)
	if err := os.WriteFile(path, []byte(oldContent), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	w, rotated := rotateLogIfNeeded(path, 100)
	if !rotated {
		t.Fatalf("expected rotation for a file over the threshold")
	}
	f, ok := w.(*os.File)
	if !ok {
		t.Fatalf("expected the returned writer to be a fresh *os.File, got %T", w)
	}
	defer f.Close()

	// 归档:旧内容原样搬到 .old,一个字节都不能丢——用户排查问题时这是唯一还能看到
	// "轮转之前发生了什么"的地方。
	archived, err := os.ReadFile(path + ".old")
	if err != nil {
		t.Fatalf("read archived file: %v", err)
	}
	if string(archived) != oldContent {
		t.Fatalf("archived content mismatch: got %d bytes, want %d bytes", len(archived), len(oldContent))
	}

	// 新文件:原路径必须存在且是全新的(空的),不能残留旧内容的任何一部分。
	if _, err := f.WriteString("fresh"); err != nil {
		t.Fatalf("write to fresh file: %v", err)
	}
	fresh, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fresh file: %v", err)
	}
	if string(fresh) != "fresh" {
		t.Fatalf("expected the fresh file to start empty and only contain what we just wrote, got %q", fresh)
	}
}

func TestRotateLogIfNeeded_OverwritesPreviousOldFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse.log")
	oldOldPath := path + ".old"
	if err := os.WriteFile(oldOldPath, []byte("stale archive from a previous rotation"), 0o644); err != nil {
		t.Fatalf("write stale .old: %v", err)
	}
	newContent := strings.Repeat("y", 200)
	if err := os.WriteFile(path, []byte(newContent), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	w, rotated := rotateLogIfNeeded(path, 100)
	if !rotated {
		t.Fatalf("expected rotation")
	}
	if f, ok := w.(*os.File); ok {
		defer f.Close()
	}

	// 覆盖式:.old 只留最近这一份,不该是旧的旧存档跟新存档拼在一起。
	archived, err := os.ReadFile(oldOldPath)
	if err != nil {
		t.Fatalf("read .old after rotation: %v", err)
	}
	if string(archived) != newContent {
		t.Fatalf(".old should be overwritten with the just-rotated content, got %q", string(archived)[:min(40, len(archived))])
	}
}
