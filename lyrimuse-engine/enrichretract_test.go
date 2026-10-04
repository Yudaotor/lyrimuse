package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func withLyricsDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	saved := lyricsDir()
	t.Cleanup(func() { setLyricsDir(saved) })
	setLyricsDir(dir)
	return dir
}

func resetEnrichRetracted(t *testing.T) {
	t.Helper()
	reset := func() {
		enrichMu.Lock()
		enrichRetracted = map[string]time.Time{}
		enrichMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

// 只删 since 之后写下的条目;since 之前就在的不动。
func TestRetractEnrichKeysOnlyRemovesEntriesSince(t *testing.T) {
	resetEnrichRetracted(t)
	withLyricsDir(t)
	since := time.Now()
	fresh := enrichKey("作曲: 中岛美雪", "漫步人生路 - 邓丽君", "漫步人生路")
	old := enrichKey("第一句歌词", "别的歌 - 别人", "")
	withEnrichCache(t, map[string]enrichEntry{
		fresh: {TS: since.Unix()},
		old:   {TS: since.Add(-time.Hour).Unix()},
	})
	retractEnrichKeys([]string{fresh, old}, since)
	if _, ok := enrichCache[fresh]; ok {
		t.Error("这首歌开始之后写下的条目该删掉")
	}
	if _, ok := enrichCache[old]; !ok {
		t.Error("这首歌开始之前就在的条目不该动")
	}
}

// 撤回期内这个 key 不准再落盘(还在飞的那轮搜索搜完了也写不回来)。
func TestCommitEnrichEntrySkipsRetractedKey(t *testing.T) {
	resetEnrichRetracted(t)
	withLyricsDir(t)
	withEnrichCache(t, nil)
	key := enrichKey("作曲: 中岛美雪", "漫步人生路 - 邓丽君", "漫步人生路")
	retractEnrichKeys([]string{key}, time.Now())
	commitEnrichEntry(key, enrichEntry{TS: time.Now().Unix(), Lyrics: "[00:01.00]歌词"})
	if _, ok := enrichCache[key]; ok {
		t.Error("撤回期内不该再写进缓存")
	}
	enrichMu.Lock()
	enrichRetracted[key] = time.Now().Add(-enrichRetractTTL - time.Second)
	enrichMu.Unlock()
	commitEnrichEntry(key, enrichEntry{TS: time.Now().Unix(), Lyrics: "[00:01.00]歌词"})
	if _, ok := enrichCache[key]; !ok {
		t.Error("过了撤回期该照常写")
	}
}

// 导出过的歌词文件一起删(启动时会被读回成条目);文件头对不上的不碰。
func TestRemoveLyricsFilesForOnlyRemovesOwnFiles(t *testing.T) {
	dir := withLyricsDir(t)
	key := enrichKey("作曲: 中岛美雪", "漫步人生路 - 邓丽君", "漫步人生路")
	base := sanitizeLyricsFilename(key)
	own := filepath.Join(dir, base+".lrc")
	artist, title, album := splitEnrichKey(key)
	if err := os.WriteFile(own, []byte(lyricsFileHeader(artist, title, album, "qq", false)+"[00:01.00]词"), 0o644); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(dir, base+".tr.lrc")
	if err := os.WriteFile(foreign, []byte(lyricsFileHeader("别人", "别的歌", "", "", false)+"[00:01.00]词"), 0o644); err != nil {
		t.Fatal(err)
	}
	removeLyricsFilesFor(key)
	if _, err := os.Stat(own); !os.IsNotExist(err) {
		t.Error("这个 key 导出的文件该删掉")
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Error("文件头不是这个 key 的文件不该动")
	}
}
