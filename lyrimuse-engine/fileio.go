package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// noteFileErr 是引擎读写文件失败时的统一记账,日志前缀 `file-io:`,跟 Swift 侧 LyrimuseCore 的 FileIO
// 同一套口径,排查时一条 grep 找全:
//   - 读、解码只记配置目录、日志目录下的路径:别的 App 的缓存、设备封面这类不归引擎管的路径不记(那些各有自己的
//     计数,见 localcachefs.go),否则一个没授权的目录能刷出成百上千行。写、建目录、改名、删都是引擎自己的产出,
//     不管落在哪(用户选的歌词导出目录)都记。
//   - 读、删时文件不存在是常态,不记。
//   - 同一操作、同一路径、同一种错误只记一次;writeFileAtomic 成功一次会清掉这一路径的写记录,再失败重新记。
//
// 读文件的 `if err != nil { … }` 分支第一句调它,别只 return。写文件走 writeFileAtomic(它自己记)。见 15 章决策 32。
func noteFileErr(op, path string, err error) {
	if err == nil {
		fileIOReported.Delete(op + " " + path)
		return
	}
	if (op == "read" || op == "remove") && errors.Is(err, fs.ErrNotExist) {
		return
	}
	if (op == "read" || op == "decode") && !engineOwnsPath(path) {
		return
	}
	if !fileErrFirstSeen(op+" "+path, fileErrSignature(err)) {
		return
	}
	warnf("file-io: %s failed path=%s error=%s", op, tildeHome(path), fileErrSignature(err))
}

var fileIOReported sync.Map // "操作 路径" → 上一次记过的错误

// fileErrFirstSeen:这一「操作 路径」上一次记的不是这个错误,就记下并返回 true。
func fileErrFirstSeen(key, signature string) bool {
	prev, loaded := fileIOReported.Swap(key, signature)
	return !loaded || prev != signature
}

// fileErrSignature 去掉错误里的路径(日志里已经单独有 path=),只留操作和系统给的原因。
func fileErrSignature(err error) string {
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) {
		return pathErr.Op + ": " + pathErr.Err.Error()
	}
	var linkErr *os.LinkError
	if errors.As(err, &linkErr) {
		return linkErr.Op + ": " + linkErr.Err.Error()
	}
	return err.Error()
}

// engineOwnsPath:路径落在配置目录或日志目录下。
func engineOwnsPath(path string) bool {
	for _, root := range []string{configDir(), filepath.Dir(logFilePath())} {
		if root == "" || root == "." {
			continue
		}
		if path == root || strings.HasPrefix(path, root+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func tildeHome(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if path == home || strings.HasPrefix(path, home+string(filepath.Separator)) {
		return "~" + strings.TrimPrefix(path, home)
	}
	return path
}
