package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// setUpMaintenanceTest 摆出「常驻进程运行期间用户手改了歌词文件」的现场:磁盘 JSON 里是旧歌词,
// lyrics/ 文件里是改过的。返回配置目录、条目 key、JSON 路径、一个歌词临时文件的路径。
func setUpMaintenanceTest(t *testing.T) (cfgDir, key, jsonPath, tempFile string) {
	t.Helper()
	resetFeaturesForTest(t)
	setFeatures(featureFlags{})
	savedDir, savedDefault := lyricsDir(), defaultLyricsDir
	savedCache, savedPath, savedDirty := enrichCache, enrichPath, enrichDirty
	t.Cleanup(func() {
		enrichMu.Lock()
		setLyricsDir(savedDir)
		defaultLyricsDir = savedDefault
		enrichCache, enrichPath, enrichDirty = savedCache, savedPath, savedDirty
		enrichMu.Unlock()
	})
	cfgDir = t.TempDir()
	key = enrichKey("Artist", "Song", "Album")
	jsonPath = filepath.Join(cfgDir, clientName+"-enrich-cache.json")
	data, err := json.Marshal(map[string]enrichEntry{key: {Lyrics: "[00:01.00]old"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	lyrics := filepath.Join(cfgDir, "lyrics")
	enrichMu.Lock()
	setLyricsDir(lyrics)
	enrichCache = map[string]enrichEntry{key: {Lyrics: "[00:01.00]edited"}}
	enrichPath = ""
	enrichMu.Unlock()
	exportLyricsFiles()
	tempFile = filepath.Join(lyrics, "Artist - Song - Album.lrc.tmp.123456")
	if err := os.WriteFile(tempFile, []byte("half"), 0o644); err != nil {
		t.Fatal(err)
	}
	enrichMu.Lock()
	enrichCache, enrichDirty = nil, false
	setLyricsDir("")
	enrichMu.Unlock()
	return cfgDir, key, jsonPath, tempFile
}

// -apply:先载 JSON 再让 lyrics/ 文件赢,之后的导出写回的是用户改过的内容,不会拿旧 JSON 盖掉它。
func TestMaintenanceApplyImportsLyricsFilesOverJSON(t *testing.T) {
	cfgDir, key, _, _ := setUpMaintenanceTest(t)
	loadEnrichForMaintenance(cfgDir, true)
	if e, _ := cacheEntry(t, key); e.Lyrics != "[00:01.00]edited" {
		t.Fatalf("lyrics/ 文件该赢过 JSON: %q", e.Lyrics)
	}
	if lyricsDir() != filepath.Join(cfgDir, "lyrics") {
		t.Fatalf("歌词文件夹该按设置 / 默认位置定下来(导出靠它): %q", lyricsDir())
	}
	if enrichPath == "" {
		t.Fatal("-apply 要能落盘")
	}
}

// 预演:常驻进程可能正在跑,内存照样按文件对齐(计划才准),但不落盘、不删临时文件。
func TestMaintenanceDryRunIsReadOnly(t *testing.T) {
	cfgDir, key, jsonPath, tempFile := setUpMaintenanceTest(t)
	before, _ := os.ReadFile(jsonPath)
	loadEnrichForMaintenance(cfgDir, false)
	if e, _ := cacheEntry(t, key); e.Lyrics != "[00:01.00]edited" {
		t.Fatalf("预演的内存也该按 lyrics/ 文件对齐: %q", e.Lyrics)
	}
	if enrichPath != "" {
		t.Fatalf("预演不该带着落盘路径: %q", enrichPath)
	}
	saveEnrichCache()
	if after, _ := os.ReadFile(jsonPath); string(after) != string(before) {
		t.Fatal("预演改写了磁盘上的缓存")
	}
	if _, err := os.Stat(tempFile); err != nil {
		t.Fatalf("预演删掉了歌词临时文件(可能是常驻进程写到一半的): %v", err)
	}
}
