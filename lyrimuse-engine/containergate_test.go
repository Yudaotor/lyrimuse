package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func resetContainerGate(t *testing.T) {
	t.Helper()
	t.Cleanup(func() {
		containerGate.Lock()
		containerGate.on, containerGate.allowed = false, nil
		containerGate.Unlock()
	})
}

func TestOtherAppContainerUngatedByDefault(t *testing.T) {
	resetContainerGate(t)
	p := "/Users/u/Library/Containers/com.tencent.QQMusicMac/Data/Library/x.sqlite"
	if got := otherAppContainer(p); got != p {
		t.Fatalf("常驻引擎不设闸: got %q", got)
	}
}

func TestOtherAppContainerGateFollowsReadableSources(t *testing.T) {
	resetContainerGate(t)
	state := filepath.Join(t.TempDir(), "access.json")
	if err := os.WriteFile(state, []byte(`{"updatedAt":1,"denied":["qq"],"readable":["kugou"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	gateOtherAppContainers(state)
	home := "/Users/u/Library/Containers/"
	cases := map[string]bool{
		home + "com.kugou.mac.Music/Data/Library/Preferences/currentPlayList.sqlite":                    true,
		home + "com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/qqmusic.sqlite":      false,
		home + "com.netease.163music/Data/Documents/storage/sqlite_storage.sqlite3":                     false,
		home + "com.tencent.QQMusic/Data/Library/Application Support/com.tencent.QQMusic/iDB/qq.sqlite": false,
		"/Users/u/Library/Application Support/com.netease.163music/Documents/x":                         true,
		"/Users/u/Library/Caches/com.apple.Music/x":                                                     true,
	}
	for p, keep := range cases {
		got := otherAppContainer(p)
		if keep && got != p || !keep && got != "" {
			t.Errorf("%s: got %q, keep=%v", p, got, keep)
		}
	}
	if qqDataRoots().path(qqLibraryRel) != "" {
		t.Error("QQ 没确认读得到时,子命令不该读它的容器")
	}
}

func TestOtherAppContainerGateClosedWithoutState(t *testing.T) {
	resetContainerGate(t)
	gateOtherAppContainers(filepath.Join(t.TempDir(), "missing.json"))
	if otherAppContainer("/Users/u/Library/Containers/com.kugou.mac.Music/Data/x") != "" {
		t.Error("没有状态文件时所有容器都不读")
	}
	if kugouContainerPath("Library/x") != "" {
		t.Error("酷狗的容器路径也要经过闸")
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
