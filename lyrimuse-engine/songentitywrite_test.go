package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// 实体表跟盘上那份只差 built_at 时不重写:增量重算后到点写、每次启动全量建表,结果常常逐字相同。
func TestSongEntityTableSkipsUnchangedWrite(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	savedFeatures := features()
	t.Cleanup(func() { setFeatures(savedFeatures) })
	setFeatures(featureFlags{SongEntityShadow: true})
	savedPath, savedDirty := enrichPath, enrichDirty
	t.Cleanup(func() { enrichPath, enrichDirty = savedPath, savedDirty })
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	withEnrichCache(t, map[string]enrichEntry{
		"A|Song|One":    {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Two":    {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
		"B|Other|Three": {DurationSecs: 180},
	})
	inode := func(path string) uint64 {
		t.Helper()
		fi, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		return fi.Sys().(*syscall.Stat_t).Ino
	}
	t0 := time.Unix(1_000_000, 0)
	rebuildSongEntityTable(t0)
	table, report := inode(songEntityTablePath()), inode(songEntityReportPath())

	rebuildSongEntityTable(t0.Add(time.Hour))
	if inode(songEntityTablePath()) != table {
		t.Error("全量建表结果没变时不该重写实体表")
	}
	if inode(songEntityReportPath()) != report {
		t.Error("报告没变时不该重写")
	}

	// 换一次进程:没有记下的摘要,从盘上读种子时记。
	songEntityRebuildMu.Lock()
	songEntityWritten.path = ""
	songEntityRebuildMu.Unlock()
	rebuildSongEntityTable(t0.Add(2 * time.Hour))
	if inode(songEntityTablePath()) != table {
		t.Error("从盘上读的种子跟结果一样时也不该重写")
	}

	withEnrichCache(t, map[string]enrichEntry{
		"A|Song|One":    {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Two":    {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
		"B|Other|Three": {DurationSecs: 180},
		"C|New|Four":    {DurationSecs: 240},
	})
	rebuildSongEntityTable(t0.Add(3 * time.Hour))
	if inode(songEntityTablePath()) == table {
		t.Error("多了一首歌,实体表要重写")
	}
	if got := readSongEntityTable(songEntityTablePath()); got == nil || len(got.Songs) != 3 {
		t.Errorf("重写后的实体表: %+v", got)
	}

	songEntityRebuildMu.Lock()
	songEntityTableUnsaved = readSongEntityTable(songEntityTablePath())
	songEntityTableUnsaved.BuiltAt++
	songEntityRebuildMu.Unlock()
	before := inode(songEntityTablePath())
	flushSongEntityTable()
	if inode(songEntityTablePath()) != before {
		t.Error("增量那份只差 built_at 时 flush 不该重写")
	}

	// 摘要对得上但文件被删了(用户清理、App 重置):照样写回来。
	kept := readSongEntityTable(songEntityTablePath())
	if err := os.Remove(songEntityTablePath()); err != nil {
		t.Fatal(err)
	}
	songEntityRebuildMu.Lock()
	songEntityTableUnsaved = kept
	songEntityRebuildMu.Unlock()
	flushSongEntityTable()
	if _, err := os.Stat(songEntityTablePath()); err != nil {
		t.Errorf("文件没了要写回来: %v", err)
	}
}
