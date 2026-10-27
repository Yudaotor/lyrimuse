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

func writeClientFile(t *testing.T, p string, at time.Time) {
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

func TestPickClientDataRoot(t *testing.T) {
	dir := t.TempDir()
	container := filepath.Join(dir, "Containers", "Documents")
	standalone := filepath.Join(dir, "Application Support", "Documents")
	files := []string{neteaseLibraryRel, neteaseQueueRel, neteaseFMRel}
	now := time.Now()

	if got := pickClientDataRoot(container, standalone, files); got != container {
		t.Errorf("两处都没有:应返回容器,got %s", got)
	}
	writeClientFile(t, filepath.Join(standalone, neteaseLibraryRel), now.Add(-time.Hour))
	if got := pickClientDataRoot(container, standalone, files); got != standalone {
		t.Errorf("只有非沙盒那一处:应读它,got %s", got)
	}
	writeClientFile(t, filepath.Join(container, neteaseFMRel), now)
	if got := pickClientDataRoot(container, standalone, files); got != container {
		t.Errorf("两处都有、容器里有一份更新:应读容器,got %s", got)
	}
	writeClientFile(t, filepath.Join(standalone, neteaseQueueRel), now.Add(time.Hour))
	if got := pickClientDataRoot(container, standalone, files); got != standalone {
		t.Errorf("两处都有、非沙盒那一处的队列更新:应读非沙盒,got %s", got)
	}
	if got := pickClientDataRoot("", standalone, files); got != standalone {
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
		if got := pickClientDataRoot(locked, standalone, files); got != locked {
			t.Errorf("容器读不了:应返回容器让读的那一步报拒绝,got %s", got)
		}
	}
}

// 只装了官网的非沙盒版:每条读取路径都落在 Application Support 那一处,启动探测把它记成不用授权、不探容器。
func TestStandaloneOnlyClientsPathsAndProbe(t *testing.T) {
	prevOut := log.Writer()
	log.SetOutput(io.Discard)
	defer log.SetOutput(prevOut)

	overrides := []*string{&neteaseLocalDBOverride, &neteaseUpcomingOverride, &neteaseFMOverride,
		&qqLocalDBOverride, &qqUpcomingOverride, &qqRRCacheOverride, &sodaLocalQueueOverride, &sodaPreloadOverride}
	saved := make([]string, len(overrides))
	for i, o := range overrides {
		saved[i], *o = *o, ""
	}
	defer func() {
		for i, o := range overrides {
			*o = saved[i]
		}
	}()

	cases := []struct {
		source     string
		standalone string
		container  string
		paths      map[string]func() string
	}{
		{"netease", "Library/Application Support/com.netease.163music/Documents", "Library/Containers/com.netease.163music/Data",
			map[string]func() string{neteaseLibraryRel: neteaseLocalDBPath, neteaseQueueRel: neteaseUpcomingPath, neteaseFMRel: neteaseFMPath}},
		{"qq", "Library/Application Support/QQMusicMac", "Library/Containers/com.tencent.QQMusicMac/Data",
			map[string]func() string{qqLibraryRel: qqLocalDBPath, qqQueueRel: qqUpcomingPath, qqRRCacheRel: qqRRCachePath}},
		{"soda", "Library/Application Support/SodaMusic", "Library/Containers/com.soda.music/Data",
			map[string]func() string{sodaQueueRel: sodaLocalQueuePath, sodaPreloadRel: sodaPreloadPath}},
	}
	for _, tc := range cases {
		t.Run(tc.source, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			standalone := filepath.Join(home, tc.standalone)
			for rel := range tc.paths {
				writeClientFile(t, filepath.Join(standalone, rel), time.Now())
				break
			}
			for rel, path := range tc.paths {
				if got, want := path(), filepath.Join(standalone, rel); got != want {
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
			if err := os.MkdirAll(filepath.Join(home, tc.container), 0o755); err != nil {
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
			if !slices.Equal(st.Unprotected, []string{tc.source}) {
				t.Errorf("非沙盒版应记进 unprotected,got %v", st.Unprotected)
			}
			if slices.Contains(st.Readable, tc.source) || slices.Contains(st.Denied, tc.source) {
				t.Errorf("此刻读的不是容器,不该探容器给出授权结论,got readable=%v denied=%v", st.Readable, st.Denied)
			}
		})
	}
}

// 有两种安装包的来源都要登记进 clientDataRootsBySource,且容器那一处跟 localCacheClientPaths 登记的是同一个容器。
func TestClientDataRootsMatchProbePaths(t *testing.T) {
	paths := localCacheClientPaths()
	for source, roots := range clientDataRootsBySource() {
		if len(roots.files) == 0 {
			t.Errorf("%s 没登记要读的文件", source)
		}
		want := containerDataRoot(roots.container)
		var registered []string
		for _, rel := range roots.files {
			registered = append(registered, roots.containerPath(rel))
		}
		for _, p := range paths[source] {
			if got := containerDataRoot(p); got != want {
				t.Errorf("%s: 探测路径 %s 所在的容器 %s 跟挑根用的 %s 对不上", source, p, got, want)
			}
			if !slices.Contains(registered, p) {
				t.Errorf("%s: 探测路径 %s 挑根时没算进去,在 clientDataRoots.files 里补上", source, p)
			}
		}
		for _, rel := range roots.files {
			if !slices.Contains(paths[source], roots.containerPath(rel)) {
				t.Errorf("%s: %s 没登记进 localCacheClientPaths", source, rel)
			}
		}
	}
}
