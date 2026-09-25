package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setUpLyricsDirSwitchTest 准备一个旧目录、一个新目录和一份内存缓存,测试结束全部还原。
func setUpLyricsDirSwitchTest(t *testing.T) (oldDir, newDir string) {
	t.Helper()
	resetFeaturesForTest(t)
	oldDir, newDir = t.TempDir(), t.TempDir()
	savedDir, savedCache, savedPath, savedDefault := lyricsDir(), enrichCache, enrichPath, defaultLyricsDir
	savedReady := lyricsDirSwitchReady.Load()
	t.Cleanup(func() {
		enrichMu.Lock()
		setLyricsDir(savedDir)
		enrichCache = savedCache
		enrichPath = savedPath
		enrichMu.Unlock()
		defaultLyricsDir = savedDefault
		lyricsDirSwitchReady.Store(savedReady)
	})
	enrichMu.Lock()
	setLyricsDir(oldDir)
	enrichCache = map[string]enrichEntry{
		enrichKey("Alpha", "Song One", "Album"): {Lyrics: "[00:01.00]cache one"},
		enrichKey("Alpha", "Song Two", "Album"): {Lyrics: "[00:01.00]cache two"},
	}
	enrichPath = filepath.Join(t.TempDir(), "enrich-cache.json")
	enrichMu.Unlock()
	defaultLyricsDir = oldDir
	return oldDir, newDir
}

// 切换 = 新目录里已有的文件赢、缓存里其余的整份导出到新目录、lyricsDir() 指过去、旧目录不动。
func TestSwitchLyricsDirAdoptsThenExports(t *testing.T) {
	oldDir, newDir := setUpLyricsDirSwitchTest(t)
	userFile := lyricsFileHeader("Alpha", "Song One", "Album", "", false) + "[00:01.00]user edited"
	if err := os.WriteFile(filepath.Join(newDir, "Alpha - Song One - Album.lrc"), []byte(userFile), 0o644); err != nil {
		t.Fatal(err)
	}
	lyricsDirSwitchReady.Store(true)
	setFeatures(featureFlags{LyricsDir: newDir})

	switchLyricsDir(newDir)

	if got := lyricsDir(); got != newDir {
		t.Fatalf("lyricsDir() 没指到新目录 got %q", got)
	}
	enrichMu.Lock()
	one := enrichCache[enrichKey("Alpha", "Song One", "Album")].Lyrics
	enrichMu.Unlock()
	if !strings.Contains(one, "user edited") {
		t.Errorf("新目录里已有的文件应赢过缓存,got %q", one)
	}
	two, err := os.ReadFile(filepath.Join(newDir, "Alpha - Song Two - Album.lrc"))
	if err != nil || !strings.Contains(string(two), "cache two") {
		t.Errorf("缓存里其余条目应导出到新目录 err=%v body=%q", err, two)
	}
	if entries, _ := os.ReadDir(oldDir); len(entries) != 0 {
		t.Errorf("旧目录不该被写入或删改,现有 %d 项", len(entries))
	}
}

// 留空 = 默认位置。
func TestSwitchLyricsDirEmptyMeansDefault(t *testing.T) {
	_, newDir := setUpLyricsDirSwitchTest(t)
	defaultLyricsDir = newDir
	lyricsDirSwitchReady.Store(true)
	setFeatures(featureFlags{LyricsDir: ""})
	switchLyricsDir("")
	if got := lyricsDir(); got != newDir {
		t.Errorf("lyrics_dir 留空应切到默认位置 got %q", got)
	}
}

// 启动迁移跑完之前不切:那时启动路径自己正在导入导出、改缓存。
func TestSwitchLyricsDirWaitsForStartup(t *testing.T) {
	oldDir, newDir := setUpLyricsDirSwitchTest(t)
	lyricsDirSwitchReady.Store(false)
	setFeatures(featureFlags{LyricsDir: newDir})
	switchLyricsDir(newDir)
	if got := lyricsDir(); got != oldDir {
		t.Fatalf("启动完成前不该切换 got %q", got)
	}
	enableLyricsDirSwitch()
	if got := lyricsDir(); got != newDir {
		t.Errorf("放开之后应补上启动期间那次改动 got %q", got)
	}
}

// 排队的那一趟发现设置已经又改过,就不做,交给最新那一趟。
func TestSwitchLyricsDirSkipsStaleRequest(t *testing.T) {
	oldDir, newDir := setUpLyricsDirSwitchTest(t)
	lyricsDirSwitchReady.Store(true)
	setFeatures(featureFlags{LyricsDir: oldDir})
	switchLyricsDir(newDir)
	if got := lyricsDir(); got != oldDir {
		t.Errorf("过时的切换请求不该生效 got %q", got)
	}
}

// features.json 里改了 lyrics_dir,热重读那一步要自己把搬家拉起来(不需要任何人另外调用)。
func TestFeaturesReloadTriggersLyricsDirSwitch(t *testing.T) {
	_, newDir := setUpLyricsDirSwitchTest(t)
	lyricsDirSwitchReady.Store(true)
	path := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(path, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setFeatures(loadFeatureFlags(path))
	setFeaturesPath(path)
	body, _ := json.Marshal(map[string]string{"lyrics_dir": newDir})
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	featuresCheckedAt.Store(time.Now().Add(-2 * featuresReloadInterval).UnixNano())
	_ = features()
	deadline := time.Now().Add(5 * time.Second)
	for lyricsDir() != newDir && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := lyricsDir(); got != newDir {
		t.Errorf("改了 lyrics_dir 之后没切过去 got %q", got)
	}
}
