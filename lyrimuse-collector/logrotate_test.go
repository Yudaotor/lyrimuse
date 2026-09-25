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

	// .old 始终是**最近**那一份(上一份挪去了 .old.1,不是被拼接也不是被留在原地)。
	archived, err := os.ReadFile(oldOldPath)
	if err != nil {
		t.Fatalf("read .old after rotation: %v", err)
	}
	if string(archived) != newContent {
		t.Fatalf(".old should hold the just-rotated content, got %q", string(archived)[:min(40, len(archived))])
	}
}

// 轮转保留多代:最近一份仍叫 .old,上一份挪到 .old.1、再上一份 .old.2,超出保留份数的
// 最老那份删掉。
//
// 不能只留一份(覆盖式):按实测产量(5~8.5 万行/天、约 11MB/天,30MB 阈值)算,
// 两三天就轮转一次,只留一份的话能回溯的窗口只有两到五天,"上周那次是怎么回事"
// 根本查不了。
func TestRotateLogIfNeeded_KeepsMultipleGenerations(t *testing.T) {
	// 下面的断言都是拿 logRotateKeepArchives 参数化的,所以它们抓不到"把这个常量悄悄
	// 改小"——变异测试实测:改成 1 时整条用例照样全绿。具体留几份是可调的策略,但
	// "不止一份"是这次修复本身,单独钉死。
	if logRotateKeepArchives < 2 {
		t.Fatalf("保留份数不该退回 %d 份:只留一份时能回溯的窗口只有两到五天", logRotateKeepArchives)
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "lyrimuse.log")

	// 连着轮转比保留份数多一次,好验证最老的那份确实被丢掉了。
	var written []string
	for i := 0; i < logRotateKeepArchives+1; i++ {
		content := strings.Repeat(string(rune('a'+i)), 200)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("第 %d 轮写入: %v", i, err)
		}
		w, rotated := rotateLogIfNeeded(path, 100)
		if !rotated {
			t.Fatalf("第 %d 轮该轮转", i)
		}
		if f, ok := w.(*os.File); ok {
			f.Close()
		}
		written = append(written, content)
	}

	// 最近的几份按新→旧排在 .old / .old.1 / .old.2 上,一份都不能串位。
	for i := 0; i < logRotateKeepArchives; i++ {
		want := written[len(written)-1-i]
		got, err := os.ReadFile(logArchiveName(path, i))
		if err != nil {
			t.Fatalf("第 %d 代归档读不到: %v", i, err)
		}
		if string(got) != want {
			t.Errorf("第 %d 代归档串位了:内容是 %q 开头,期望 %q 开头", i, string(got)[:1], want[:1])
		}
	}
	// 再老的要丢掉 —— 不然归档会无限堆下去,轮转就白做了。
	if _, err := os.Stat(logArchiveName(path, logRotateKeepArchives)); !os.IsNotExist(err) {
		t.Errorf("超出保留份数的归档该删掉,err=%v", err)
	}
	// 中转文件属于轮转内部实现,收尾后不该留在磁盘上。
	if _, err := os.Stat(path + ".rotating"); !os.IsNotExist(err) {
		t.Errorf("轮转中转文件该在收尾时消失,err=%v", err)
	}
}
