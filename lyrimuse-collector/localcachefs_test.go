package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// 五条客户端缓存快速路径的静默规则:只有"被系统拒绝"要留痕,别的一概不作声。
//
// 这条守卫盯的是一个**不会以任何其它方式暴露**的故障:TCC 拒绝之后整条路径 fail-soft,
// 线上表现与"没装那个播放器"逐字节相同,只有这行日志能把两者分开。
func TestNoteLocalCacheDenied(t *testing.T) {
	var buf bytes.Buffer
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
	}()
	localCacheDeniedMu.Lock()
	localCacheDeniedReported = map[string]string{}
	localCacheDeniedMu.Unlock()

	// nil、不存在、以及"客户端正在写"这类偶发失败,都不作声 —— 每首歌都会走一遍这里。
	noteLocalCacheDenied("kugou", "/nope", nil)
	noteLocalCacheDenied("kugou", "/nope", fs.ErrNotExist)
	noteLocalCacheDenied("kugou", "/nope", &fs.PathError{Op: "stat", Path: "/nope", Err: syscall.ENOENT})
	noteLocalCacheDenied("kugou", "/nope", &fs.PathError{Op: "read", Path: "/nope", Err: syscall.EIO})
	if buf.Len() != 0 {
		t.Fatalf("只有被拒才该记日志,got %q", buf.String())
	}

	// TCC 拒绝(EPERM)要报,而且要说清怎么修。
	denied := &fs.PathError{Op: "stat", Path: "/Users/x/Library/Containers/a/Data", Err: syscall.EPERM}
	if !errors.Is(denied, fs.ErrPermission) {
		t.Fatal("EPERM 应当满足 fs.ErrPermission —— 判据就建立在这上面")
	}
	noteLocalCacheDenied("kugou", "/Users/x/Library/Containers/a/Data", denied)
	first := buf.String()
	if !strings.Contains(first, "kugou local:") || !strings.Contains(first, "Full Disk Access") {
		t.Fatalf("被拒要报出来源和修法,got %q", first)
	}

	// EACCES 与 EPERM 同属"被拒",都要报。
	buf.Reset()
	noteLocalCacheDenied("qq", "/x", &fs.PathError{Op: "open", Path: "/x", Err: syscall.EACCES})
	if !strings.Contains(buf.String(), "qq local:") {
		t.Fatalf("EACCES 也是被拒,got %q", buf.String())
	}

	// 同一来源的同一种拒绝只报一次,否则每首歌刷一行。
	buf.Reset()
	noteLocalCacheDenied("kugou", "/Users/x/Library/Containers/a/Data", denied)
	if buf.Len() != 0 {
		t.Fatalf("重复的同一拒绝不该再报,got %q", buf.String())
	}

	// 去重按来源分开,一个播放器报过不该堵住另一个。
	buf.Reset()
	noteLocalCacheDenied("soda", "/Users/x/Library/Containers/b/Data", denied)
	if !strings.Contains(buf.String(), "soda local:") {
		t.Fatalf("另一个来源应当独立计数,got %q", buf.String())
	}
}

// 每条快速路径的**每个读取入口**都要接上判据。
//
// 数目是判据的一部分:`os.Stat` 过了不代表 `os.ReadDir` / `os.ReadFile` 也过 ——
// TCC 允许 stat 一个目录却拒绝列它的内容是实际发生过的形态。只在 stat 那一支接,
// 这类拒绝会继续无声无息。
func TestEveryLocalCacheReadPathReportsDenial(t *testing.T) {
	// 文件 到 (来源, 该文件里受 TCC 影响的读取入口数)
	want := []struct {
		file   string
		source string
		sites  int
	}{
		{"kugoulocal.go", "kugou", 2},           // Stat 目录 + ReadDir
		{"applemusiclocal.go", "applemusic", 2}, // Stat 目录 + ReadDir
		{"sodalocal.go", "soda", 2},             // Stat 文件 + ReadFile
		{"qqlocal.go", "qq", 1},                 // Stat 文件(查询走 sqlite,失败原因不止权限)
		{"neteaselocal.go", "netease", 1},       // 同上
	}
	for _, w := range want {
		raw, err := os.ReadFile(w.file)
		if err != nil {
			t.Fatalf("读不到 %s: %v", w.file, err)
		}
		needle := "noteLocalCacheDenied(\"" + w.source + "\""
		if got := strings.Count(string(raw), needle); got != w.sites {
			t.Errorf("%s 接上的读取入口数是 %d,应为 %d(漏一个就是那一个继续无声无息地哑着)",
				w.file, got, w.sites)
		}
	}
}

// 状态文件是设置页那三格提示的唯一数据源:被拒要写进去,授权之后要能自己撤掉。
//
// "撤掉"这一半跟"写进去"同样要紧 —— 少了它,用户授权之后界面上那个橙色提示会一直挂着,
// 而此刻它说的事情已经不成立了。
func TestLocalCacheAccessStatePublishing(t *testing.T) {
	prevOut := log.Writer()
	log.SetOutput(io.Discard)
	defer log.SetOutput(prevOut)

	path := filepath.Join(t.TempDir(), "access.json")
	setLocalCacheAccessPath(path)
	defer setLocalCacheAccessPath("")
	localCacheDeniedMu.Lock()
	localCacheDeniedReported = map[string]string{}
	localCacheDeniedNow = map[string]bool{}
	localCacheDeniedMu.Unlock()

	read := func() localCacheAccessState {
		t.Helper()
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读不到状态文件: %v", err)
		}
		var st localCacheAccessState
		if err := json.Unmarshal(raw, &st); err != nil {
			t.Fatalf("状态文件解不开: %v", err)
		}
		return st
	}

	denied := &fs.PathError{Op: "open", Path: "/x", Err: syscall.EPERM}
	noteLocalCacheDenied("kugou", "/x", denied)
	noteLocalCacheDenied("qq", "/y", denied)
	if got := read().Denied; len(got) != 2 || got[0] != "kugou" || got[1] != "qq" {
		t.Fatalf("两个来源被拒后都该在名单里(且有序),got %v", got)
	}

	// 非权限失败不该进名单 —— 那是常态,不是"需要授权"。
	noteLocalCacheDenied("netease", "/z", &fs.PathError{Op: "stat", Path: "/z", Err: syscall.EIO})
	if got := read().Denied; len(got) != 2 {
		t.Fatalf("偶发失败不该进名单,got %v", got)
	}

	// 授权之后:读到了就撤掉,只剩另一个。
	noteLocalCacheReadable("kugou")
	if got := read().Denied; len(got) != 1 || got[0] != "qq" {
		t.Fatalf("读得到的来源该被撤掉,got %v", got)
	}

	// 全部恢复 到 空名单,界面据此什么都不显示。
	noteLocalCacheReadable("qq")
	if got := read().Denied; len(got) != 0 {
		t.Fatalf("全部恢复后名单该空,got %v", got)
	}

	// 本来就不在名单里的来源反复报 readable,不该有任何副作用。
	noteLocalCacheReadable("soda")
	if got := read().Denied; len(got) != 0 {
		t.Fatalf("撤一个不在名单里的来源不该改动状态,got %v", got)
	}
}

// 五条路径都要在读成功后撤掉「被拒」,否则那一条的提示会永远挂着。
func TestEveryLocalCachePathClearsDenialOnSuccess(t *testing.T) {
	for _, w := range []struct{ file, source string }{
		{"kugoulocal.go", "kugou"},
		{"applemusiclocal.go", "applemusic"},
		{"sodalocal.go", "soda"},
		{"qqlocal.go", "qq"},
		{"neteaselocal.go", "netease"},
	} {
		raw, err := os.ReadFile(w.file)
		if err != nil {
			t.Fatalf("读不到 %s: %v", w.file, err)
		}
		needle := "noteLocalCacheReadable(\"" + w.source + "\")"
		if !strings.Contains(string(raw), needle) {
			t.Errorf("%s 没在读成功后撤掉「被拒」(缺 %s)", w.file, needle)
		}
	}
}
