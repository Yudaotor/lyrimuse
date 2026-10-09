package main

import (
	"bytes"
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func captureFileIOLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(prev) })
	fileIOReported.Range(func(k, _ any) bool { fileIOReported.Delete(k); return true })
	return &buf
}

func TestNoteFileErr(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	buf := captureFileIOLog(t)
	owned := filepath.Join(dir, "state.json")
	denied := &fs.PathError{Op: "open", Path: owned, Err: errors.New("permission denied")}

	noteFileErr("read", owned, &fs.PathError{Op: "open", Path: owned, Err: fs.ErrNotExist})
	noteFileErr("read", "/elsewhere/other-app/cache.db", denied)
	if buf.Len() != 0 {
		t.Fatalf("文件不存在、别人的文件读不到都不该记: %q", buf.String())
	}

	noteFileErr("read", owned, denied)
	noteFileErr("read", owned, denied)
	if n := strings.Count(buf.String(), "file-io: read failed"); n != 1 {
		t.Fatalf("同一路径同一种错误只记一次, got %d: %q", n, buf.String())
	}
	if !strings.Contains(buf.String(), "error=open: permission denied\"") || strings.Count(buf.String(), owned) != 1 {
		t.Errorf("错误里不重复路径,只留操作和原因: %q", buf.String())
	}

	noteFileErr("write", "/Users/someone/Music/lyrics/a.lrc", denied)
	if !strings.Contains(buf.String(), "file-io: write failed") {
		t.Errorf("写不管落在哪都记: %q", buf.String())
	}

	buf.Reset()
	noteFileErr("write", owned, denied)
	noteFileErr("write", owned, nil)
	noteFileErr("write", owned, denied)
	if n := strings.Count(buf.String(), "file-io: write failed"); n != 2 {
		t.Errorf("成功一次之后再失败要重新记, got %d: %q", n, buf.String())
	}
}

func TestWriteFileAtomicLogsFailure(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root can write anywhere")
	}
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	buf := captureFileIOLog(t)
	readOnly := filepath.Join(dir, "ro")
	if err := os.Mkdir(readOnly, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(readOnly, 0o755) })
	if err := writeFileAtomic(filepath.Join(readOnly, "x.json"), []byte("{}")); err == nil {
		t.Fatal("写进只读目录应当失败")
	}
	if !strings.Contains(buf.String(), "file-io: write failed") {
		t.Errorf("writeFileAtomic 失败要记一行: %q", buf.String())
	}
}

// 守卫:引擎里读写文件的错误不许悄悄吞掉,否则出了问题日志里什么都没有(15 章决策 32)。
//   - 写盘、建目录、改名的返回值不许丢;
//   - 读文件拿到 err 之后的分支里要么记(noteFileErr / 日志)、要么把错误交出去,别只 return。
//
// 日志出口自己(logsink.go / logrotate.go)写不进日志文件时没处可记,不在此列;那种情况由 App 启动时的
// 文件夹检查兜底(HomeFolderAccess,15 章决策 31)。
func TestEngineFileErrorsAreNotSwallowed(t *testing.T) {
	exempt := map[string]bool{"logsink.go": true, "logrotate.go": true}
	dropped := regexp.MustCompile(`^\s*(_ = )?os\.(WriteFile|MkdirAll|Rename|Chmod)\(`)
	ignoredRead := regexp.MustCompile(`, _ :?= os\.ReadFile\(`)
	readSite := regexp.MustCompile(`\b\w+, err :?= os\.(ReadFile|Open)\(`)
	silentBranch := regexp.MustCompile(`^\s*if err != nil \{`)
	handled := regexp.MustCompile(`noteFileErr|noteLocalCacheDenied|log\.|warnf|infoFailf|Printf|Fprint|fatal|return .*err\b|fmt\.Errorf|errors\.Is|IsNotExist|emit\(|add\(`)

	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	var offenders []string
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") || exempt[name] {
			continue
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			if dropped.MatchString(line) || ignoredRead.MatchString(line) {
				offenders = append(offenders, name+":"+strconv.Itoa(i+1))
				continue
			}
			if !readSite.MatchString(line) || i+1 >= len(lines) || !silentBranch.MatchString(lines[i+1]) {
				continue
			}
			var body []string
			for j := i + 2; j < len(lines) && strings.TrimSpace(lines[j]) != "}"; j++ {
				body = append(body, lines[j])
			}
			if !handled.MatchString(strings.Join(body, "\n")) {
				offenders = append(offenders, name+":"+strconv.Itoa(i+1))
			}
		}
	}
	if len(offenders) > 0 {
		t.Errorf("这些地方把文件读写的错误悄悄吞了,出事时日志里不会有任何痕迹;读文件在 err 分支里调 noteFileErr,写文件走 writeFileAtomic 或把错误交给 noteFileErr:\n%s",
			strings.Join(offenders, "\n"))
	}
}
