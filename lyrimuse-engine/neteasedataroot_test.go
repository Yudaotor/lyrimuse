package main

import (
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func writeNeteaseFile(t *testing.T, p string, at time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, at, at); err != nil {
		t.Fatal(err)
	}
}

func TestPickNeteaseDataRoot(t *testing.T) {
	dir := t.TempDir()
	container := filepath.Join(dir, "Containers", "Documents")
	standalone := filepath.Join(dir, "Application Support", "Documents")
	now := time.Now()

	if got := pickNeteaseDataRoot(container, standalone); got != container {
		t.Errorf("两处都没有:应返回容器,got %s", got)
	}
	writeNeteaseFile(t, filepath.Join(standalone, neteaseLibraryRel), now.Add(-time.Hour))
	if got := pickNeteaseDataRoot(container, standalone); got != standalone {
		t.Errorf("只有非沙盒那一处:应读它,got %s", got)
	}
	writeNeteaseFile(t, filepath.Join(container, neteaseFMRel), now)
	if got := pickNeteaseDataRoot(container, standalone); got != container {
		t.Errorf("两处都有、容器里有一份更新:应读容器,got %s", got)
	}
	writeNeteaseFile(t, filepath.Join(standalone, neteaseQueueRel), now.Add(time.Hour))
	if got := pickNeteaseDataRoot(container, standalone); got != standalone {
		t.Errorf("两处都有、非沙盒那一处的队列更新:应读非沙盒,got %s", got)
	}
	if got := pickNeteaseDataRoot("", standalone); got != standalone {
		t.Errorf("容器根是空串时只看另一处,got %s", got)
	}

	if os.Geteuid() != 0 {
		locked := filepath.Join(dir, "Locked")
		if err := os.MkdirAll(locked, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(locked, 0o000); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(locked, 0o755)
		if got := pickNeteaseDataRoot(locked, standalone); got != locked {
			t.Errorf("容器读不了:应返回容器让读的那一步报拒绝,got %s", got)
		}
	}
}

// 只装了非沙盒版:三条读取路径都落在 Application Support 那一处,启动探测把 netease 记成不用授权、不探容器。
func TestNeteaseStandaloneOnlyPathsAndProbe(t *testing.T) {
	prevOut := log.Writer()
	log.SetOutput(io.Discard)
	defer log.SetOutput(prevOut)

	home := t.TempDir()
	t.Setenv("HOME", home)
	overrides := []*string{&neteaseLocalDBOverride, &neteaseUpcomingOverride, &neteaseFMOverride}
	saved := make([]string, len(overrides))
	for i, o := range overrides {
		saved[i], *o = *o, ""
	}
	defer func() {
		for i, o := range overrides {
			*o = saved[i]
		}
	}()

	standalone := filepath.Join(home, "Library/Application Support/com.netease.163music/Documents")
	writeNeteaseFile(t, filepath.Join(standalone, neteaseLibraryRel), time.Now())
	for got, rel := range map[string]string{
		neteaseLocalDBPath():  neteaseLibraryRel,
		neteaseUpcomingPath(): neteaseQueueRel,
		neteaseFMPath():       neteaseFMRel,
	} {
		if want := filepath.Join(standalone, rel); got != want {
			t.Errorf("读取路径应落在非沙盒那一处:got %s,want %s", got, want)
		}
	}

	statePath := filepath.Join(t.TempDir(), "access.json")
	setLocalCacheAccessPath(statePath)
	defer setLocalCacheAccessPath("")
	localCacheDeniedMu.Lock()
	localCacheDeniedReported = map[string]string{}
	localCacheDeniedNow = map[string]bool{}
	localCacheReadableNow = map[string]bool{}
	localCacheUnprotectedNow = map[string]bool{}
	localCacheDeniedMu.Unlock()
	defer func() {
		localCacheDeniedMu.Lock()
		localCacheUnprotectedNow = map[string]bool{}
		localCacheDeniedMu.Unlock()
	}()

	// 容器目录也在(装过沙盒版又删了数据),但此刻读的是非沙盒那一处:不该探它。
	if err := os.MkdirAll(filepath.Join(home, "Library/Containers/com.netease.163music/Data"), 0o755); err != nil {
		t.Fatal(err)
	}
	probeLocalCacheAccess()
	raw, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("读不到状态文件: %v", err)
	}
	var st localCacheAccessState
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(st.Unprotected, []string{"netease"}) {
		t.Errorf("非沙盒版网易云应记进 unprotected,got %v", st.Unprotected)
	}
	if slices.Contains(st.Readable, "netease") || slices.Contains(st.Denied, "netease") {
		t.Errorf("此刻读的不是容器,不该探容器给出授权结论,got readable=%v denied=%v", st.Readable, st.Denied)
	}
}
