package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

// withFullDiskAccess 换掉授权判定,用完换回、清掉缓存的结论。
func withFullDiskAccess(t *testing.T, ok bool) {
	t.Helper()
	prev := fullDiskAccessCheck
	reset := func() {
		fullDiskAccessMemo.Lock()
		fullDiskAccessMemo.at = time.Time{}
		fullDiskAccessMemo.Unlock()
	}
	fullDiskAccessCheck = func() bool { return ok }
	reset()
	t.Cleanup(func() {
		fullDiskAccessCheck = prev
		reset()
	})
}

func TestOtherAppContainerFollowsFullDiskAccess(t *testing.T) {
	home := "/Users/u/Library/Containers/"
	inside := []string{
		home + "com.kugou.mac.Music/Data/Library/Preferences/currentPlayList.sqlite",
		home + "com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/qqmusic.sqlite",
		home + "com.tencent.QQMusic/Data/Library/Application Support/com.tencent.QQMusic/iDB/qq.sqlite",
	}
	outside := []string{
		"/Users/u/Library/Application Support/com.netease.163music/Documents/x",
		"/Users/u/Library/Caches/com.apple.Music/x",
	}
	withFullDiskAccess(t, false)
	for _, p := range inside {
		if got := otherAppContainer(p); got != "" {
			t.Errorf("没授权时不读容器: %s → %q", p, got)
		}
	}
	for _, p := range outside {
		if got := otherAppContainer(p); got != p {
			t.Errorf("容器外的路径原样: %s → %q", p, got)
		}
	}
	if qqDataRoots().path(qqLibraryRel) != "" || kugouContainerPath("Library/x") != "" {
		t.Error("QQ 数据根、酷狗容器路径没授权时都该落空")
	}
	withFullDiskAccess(t, true)
	for _, p := range inside {
		if got := otherAppContainer(p); got != p {
			t.Errorf("有授权时原样: %s → %q", p, got)
		}
	}
}

func TestFullDiskAccessVerdictIsCached(t *testing.T) {
	calls := 0
	prev := fullDiskAccessCheck
	fullDiskAccessCheck = func() bool { calls++; return false }
	fullDiskAccessMemo.Lock()
	fullDiskAccessMemo.at = time.Time{}
	fullDiskAccessMemo.Unlock()
	t.Cleanup(func() {
		fullDiskAccessCheck = prev
		fullDiskAccessMemo.Lock()
		fullDiskAccessMemo.at = time.Time{}
		fullDiskAccessMemo.Unlock()
	})
	for i := 0; i < 5; i++ {
		hasFullDiskAccess()
	}
	if calls != 1 {
		t.Fatalf("有效期内只判一次,判了 %d 次", calls)
	}
}

func TestProbeWithoutFullDiskAccessMarksInstalledDenied(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, "Library/Containers/com.tencent.QQMusicMac/Data"), 0o755); err != nil {
		t.Fatal(err)
	}
	read := resetLocalCacheAccessForTest(t)
	withFullDiskAccess(t, false)
	probeLocalCacheAccess()
	got := read()
	if len(got.Denied) != 1 || got.Denied[0] != "qq" || len(got.Readable) != 0 {
		t.Fatalf("装了 QQ(容器在)的记被拒,没装的不记: %+v", got)
	}
}

func TestLocalCacheContainerBundlesMatchClientPaths(t *testing.T) {
	withFullDiskAccess(t, true)
	want := map[string][]string{}
	for source, paths := range localCacheClientPaths() {
		seen := map[string]bool{}
		for _, p := range paths {
			if root := containerDataRoot(p); root != "" {
				seen[filepath.Base(filepath.Dir(root))] = true
			}
		}
		for b := range seen {
			want[source] = append(want[source], b)
		}
		sort.Strings(want[source])
	}
	got := map[string][]string{}
	for source, bundles := range localCacheContainerBundles {
		got[source] = append([]string(nil), bundles...)
		sort.Strings(got[source])
	}
	wantJSON, _ := json.Marshal(want)
	gotJSON, _ := json.Marshal(got)
	if string(wantJSON) != string(gotJSON) {
		t.Fatalf("localCacheContainerBundles 跟 localCacheClientPaths 对不上:\n got  %s\n want %s", gotJSON, wantJSON)
	}
}

func TestOtherAppContainerPathsGoThroughGate(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	literal := regexp.MustCompile(`"Library/Containers/`)
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(data), "\n") {
			code := strings.TrimSpace(line)
			if strings.HasPrefix(code, "//") || !literal.MatchString(code) {
				continue
			}
			if !strings.Contains(code, "otherAppContainer(") {
				t.Errorf("%s:%d 指向别的 App 容器的路径没经过 otherAppContainer: %s", f, i+1, code)
			}
		}
	}
}
