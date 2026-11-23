package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// 造一份跟 iPad 版酷狗 currentPlayList.sqlite 同构的队列库:每首的 JSON 在 FullSongInfo,次序在 CurrentSongListNew
// (它自己那一列 songInfo 是空的)。songIndex 故意跟 FullSongInfo.id 的次序不同,钉住「按 songIndex 排」。
func writeTestKugouIPadQueue(t *testing.T, songs []testKugouSong) {
	t.Helper()
	var sql strings.Builder
	sql.WriteString("CREATE TABLE FullSongInfo (id INTEGER PRIMARY KEY, songInfo BLOB);\n")
	sql.WriteString("CREATE TABLE CurrentSongListNew(id INTEGER PRIMARY KEY, songInfo BLOB, basicInfo BLOB, songid integer default 0, songIndex INTEGER DEFAULT 0);\n")
	n := len(songs)
	for i, s := range songs {
		fields := map[string]any{"musicName": s.musicName, "albumName": s.album, "musicTime": s.seconds}
		if s.showName != "" {
			fields["showName"] = s.showName
		}
		if len(s.singers) > 0 {
			arr := make([]map[string]any, 0, len(s.singers))
			for _, name := range s.singers {
				arr = append(arr, map[string]any{"id": 1, "name": name})
			}
			b, _ := json.Marshal(arr)
			fields["singerInfo"] = string(b)
		}
		for k, v := range s.extra {
			fields[k] = v
		}
		info, err := json.Marshal(fields)
		if err != nil {
			t.Fatalf("造 songInfo: %v", err)
		}
		id := n - i // id 倒着编,次序只看 songIndex
		fmt.Fprintf(&sql, "INSERT INTO FullSongInfo VALUES(%d, '%s');\n", id, strings.ReplaceAll(string(info), "'", "''"))
		fmt.Fprintf(&sql, "INSERT INTO CurrentSongListNew VALUES(%d, NULL, NULL, %d, %d);\n", i+1, id, i)
	}
	dir := t.TempDir()
	seed := filepath.Join(dir, "seed.sql")
	if err := os.WriteFile(seed, []byte(sqliteBatch(sql.String())), 0o644); err != nil {
		t.Fatal(err)
	}
	db := filepath.Join(dir, "currentPlayList.sqlite")
	cmd := exec.Command("/usr/bin/sqlite3", db)
	f, err := os.Open(seed)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	cmd.Stdin = f
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("建测试库失败: %v\n%s", err, out)
	}
	old := kugouIPadQueueOverride
	kugouIPadQueueOverride = db
	t.Cleanup(func() { kugouIPadQueueOverride = old })
}

func TestKugouIPadQueueSQL(t *testing.T) {
	for _, mac := range []string{kugouUpcomingSQL, kugouQueueSongSQL} {
		q := kugouIPadQueueSQL(mac)
		if !strings.Contains(q, kugouIPadQueueFrom) || strings.Contains(q, "FROM CurrentSongList ORDER") ||
			strings.Contains(q, "cast(songInfo") {
			t.Errorf("没换成 iPad 版的表:\n%s", q)
		}
	}
}

// iPad 版那份库里认得出正在放的这一集是听书(KGSoundReadInfo)、拿得到歌曲 id 和专辑 id;Mac 版那几份都不在时也一样,
// 读它不改 "kugou" 的访问状态(那一份管 Mac 版的完全磁盘访问)。
func TestKugouIPadQueueMarksSoundRead(t *testing.T) {
	localCacheDeniedMu.Lock()
	delete(localCacheReadableNow, "kugou")
	delete(localCacheDeniedNow, "kugou")
	localCacheDeniedMu.Unlock()
	writeTestKugouIPadQueue(t, []testKugouSong{
		{musicName: "小酷说书 - 第1集 重生了，但是幼儿园", album: "重生幼儿园", singers: []string{"小酷说书"}, seconds: 1180,
			extra: map[string]any{"mixId": "657045916", "payAlbumID": "88", "classname": "KGSoundReadInfo"}},
		{musicName: "杨丞琳 - 雨爱", album: "雨爱", singers: []string{"杨丞琳"}, seconds: 260,
			extra: map[string]any{"mixId": "32042828", "payAlbumID": "977", "classname": "CollectSongEntity"}},
	})
	if mix, album, spoken := kugouPlayingSongInfo("小酷说书", "第1集 重生了，但是幼儿园", 1180.35); !spoken || mix != "657045916" || album != "88" {
		t.Errorf("听书这一集: mix=%q album=%q spoken=%v", mix, album, spoken)
	}
	if mix, _, spoken := kugouPlayingSongInfo("杨丞琳", "雨爱", 260.5); spoken || mix != "32042828" {
		t.Errorf("歌: mix=%q spoken=%v", mix, spoken)
	}
	if _, _, spoken := kugouPlayingSongInfo("小酷说书", "第2集", 500); spoken {
		t.Error("队列里没有的不下结论")
	}
	localCacheDeniedMu.Lock()
	marked := localCacheReadableNow["kugou"] || localCacheDeniedNow["kugou"]
	localCacheDeniedMu.Unlock()
	if marked {
		t.Fatal("读 iPad 版那份不该改 \"kugou\" 的访问状态")
	}
}

// 待播:Mac 版那两份都没有时读 iPad 版那份,按 songIndex 排。
func TestKugouUpcomingFromIPadQueue(t *testing.T) {
	writeTestKugouIPadQueue(t, []testKugouSong{
		{musicName: "赵本山 - 慌啥子嘛", album: "慌啥子嘛", singers: []string{"赵本山"}, seconds: 189},
		{musicName: "马里奥 - 主角", album: "斗破苍穹", singers: []string{"马里奥"}, seconds: 257},
		{musicName: "z阿康 - 北京没有你", album: "北京没有你", singers: []string{"z阿康"}, seconds: 247},
	})
	oldPlist, oldMac := kugouQueuePlistOverride, kugouUpcomingOverride
	kugouQueuePlistOverride = filepath.Join(t.TempDir(), "no-userCurrentPlayList.plist")
	kugouUpcomingOverride = filepath.Join(t.TempDir(), "no-currentPlayList.sqlite")
	t.Cleanup(func() { kugouQueuePlistOverride, kugouUpcomingOverride = oldPlist, oldMac })
	resetKugouPlayOrder(t)
	localCacheDeniedMu.Lock()
	delete(localCacheReadableNow, "kugou")
	delete(localCacheDeniedNow, "kugou")
	localCacheDeniedMu.Unlock()
	got, ok := kugouUpcoming("马里奥", "主角", 5)
	if !ok || len(got) == 0 || got[0].title != "北京没有你" || got[0].artist != "z阿康" {
		t.Fatalf("iPad 版队列的下一首: ok=%v %+v", ok, got)
	}
	if _, ok := kugouUpcoming("周杰伦", "稻香", 5); ok {
		t.Error("两份队列里都没有当前这首,不预取")
	}
	localCacheDeniedMu.Lock()
	marked := localCacheReadableNow["kugou"]
	localCacheDeniedMu.Unlock()
	if marked {
		t.Error("读 iPad 版那份队列不该记成 Mac 版读得到")
	}
}

// 歌词缓存:Mac 版目录不在、只有 iPad 版的也命中;两个目录都有时合进同一份索引。
func TestKugouLocalLyricReadsIPadDir(t *testing.T) {
	resetKugouLocalIndex(t, filepath.Join(t.TempDir(), "没有 Mac 版"))
	ipad := t.TempDir()
	writeTestKRC(t, ipad, "849412727.krc", testKRCGeLian)
	old := kugouIPadLocalDirOverride
	kugouIPadLocalDirOverride = ipad
	t.Cleanup(func() { kugouIPadLocalDirOverride = old })
	if r, ok := kugouLocalLyric("周杰伦", "搁浅", "七里香", 0); !ok || r.artist != "周杰伦" {
		t.Fatalf("只有 iPad 版的缓存也该命中: ok=%v", ok)
	}

	mac := t.TempDir()
	writeTestKRC(t, mac, "周杰伦 - 搁浅_abc.krc", testKRCGeLian)
	resetKugouLocalIndex(t, mac)
	kugouLocalMu.Lock()
	refreshKugouLocalIndexLocked()
	n := len(kugouLocalIndex[kugouLocalKey("周杰伦", "搁浅")])
	kugouLocalMu.Unlock()
	if n != 2 {
		t.Errorf("两个目录合进一份索引:Mac 版、iPad 版各一条,得到 %d", n)
	}
}
