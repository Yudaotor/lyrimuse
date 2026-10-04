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

type testKugouSong struct {
	musicName string // "歌手 - 歌名",跟客户端里的形状一致
	showName  string // 空 = 不写这个字段
	album     string
	singers   []string // 空 = singerInfo 写成坏串,覆盖"解不开就退回 musicName 前缀"那一支
	seconds   float64
}

// writeTestKugouQueue 造一份跟真实 currentPlayList.sqlite 同构的队列库。
//
// currentProgress **每一行都给非零值**:真实库就是这样(实测 59.7/180.6/59.6/120.7),
// 它不是"当前播放进度"。这么造是为了钉住一件事 —— 定位只能靠反查歌名,谁要是改成
// "找 currentProgress 最大/非零的那行",这些测试会立刻红。
func writeTestKugouQueue(t *testing.T, songs []testKugouSong) string {
	t.Helper()
	var sql strings.Builder
	sql.WriteString("CREATE TABLE CurrentSongList(songInfo BLOB, currentProgress REAL, songIndex INTEGER DEFAULT 0);\n")
	for i, s := range songs {
		singerJSON := "坏掉的不是 JSON"
		if len(s.singers) > 0 {
			arr := make([]map[string]any, 0, len(s.singers))
			for _, n := range s.singers {
				arr = append(arr, map[string]any{"id": 1, "name": n})
			}
			b, err := json.Marshal(arr)
			if err != nil {
				t.Fatalf("造 singerInfo: %v", err)
			}
			singerJSON = string(b)
		}
		fields := map[string]any{
			"musicName": s.musicName, "musictitle": s.musicName,
			"albumName": s.album, "musicTime": s.seconds,
			"singerInfo": singerJSON,
		}
		if s.showName != "" {
			fields["showName"] = s.showName
		}
		info, err := json.Marshal(fields)
		if err != nil {
			t.Fatalf("造 songInfo: %v", err)
		}
		// SQL 字符串字面量里单引号双写转义。
		esc := strings.ReplaceAll(string(info), "'", "''")
		fmt.Fprintf(&sql, "INSERT INTO CurrentSongList VALUES('%s', %v, %d);\n", esc, float64(i)*7+1, i)
	}
	dir := t.TempDir()
	sqlPath := filepath.Join(dir, "seed.sql")
	if err := os.WriteFile(sqlPath, []byte(sql.String()), 0o644); err != nil {
		t.Fatalf("写 seed.sql: %v", err)
	}
	dbPath := filepath.Join(dir, "currentPlayList.sqlite")
	// 从文件喂 SQL,不走命令行参数 —— 歌名里有引号和中文,拼进 argv 迟早踩转义。
	cmd := exec.Command("/usr/bin/sqlite3", dbPath)
	f, err := os.Open(sqlPath)
	if err != nil {
		t.Fatalf("打开 seed.sql: %v", err)
	}
	defer f.Close()
	cmd.Stdin = f
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("建测试库失败: %v\n%s", err, out)
	}
	old := kugouUpcomingOverride
	kugouUpcomingOverride = dbPath
	t.Cleanup(func() { kugouUpcomingOverride = old })
	// 这批测的是 sqlite 兜底那条路:把 plist 主路径指到不存在的文件,不然 kugouUpcoming 会先去读
	// **本机真实的**酷狗队列(见 kugouUpcoming 的分流)。
	oldPlist := kugouQueuePlistOverride
	kugouQueuePlistOverride = filepath.Join(dir, "no-such-userCurrentPlayList.plist")
	t.Cleanup(func() { kugouQueuePlistOverride = oldPlist })
	resetKugouPlayOrder(t)
	return dbPath
}

// isolateEnrichCache 给这个测试一份空的解析缓存,结束时换回去。
func isolateEnrichCache(t *testing.T) {
	t.Helper()
	enrichMu.Lock()
	oldCache, oldInflight := enrichCache, enrichInflight
	enrichCache, enrichInflight = map[string]enrichEntry{}, map[string]bool{}
	enrichMu.Unlock()
	t.Cleanup(func() { enrichMu.Lock(); enrichCache, enrichInflight = oldCache, oldInflight; enrichMu.Unlock() })
}

// testKugouSongs 造 n 首「甲 - 第i首」。
func testKugouSongs(n int) []testKugouSong {
	songs := make([]testKugouSong, n)
	for i := range songs {
		songs[i] = testKugouSong{musicName: fmt.Sprintf("甲 - 第%d首", i), album: "专辑", singers: []string{"甲"}, seconds: 100}
	}
	return songs
}

func TestKugouUpcomingLocatesByCurrentTrack(t *testing.T) {
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 第一首", album: "甲专辑", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - 第二首", album: "乙专辑", singers: []string{"乙"}, seconds: 200},
		{musicName: "丙 - 第三首", album: "丙专辑", singers: []string{"丙"}, seconds: 300},
		{musicName: "丁 - 第四首", album: "丁专辑", singers: []string{"丁"}, seconds: 400},
	})
	got, ok := kugouUpcoming("乙", "第二首", 5)
	if !ok {
		t.Fatalf("当前这首在队列里,该定位得到")
	}
	// 小队列整份交出:从当前往后,到末尾接回开头。
	if len(got) != 3 || got[0].title != "第三首" || got[1].title != "第四首" || got[2].title != "第一首" {
		t.Fatalf("取到 %+v,期望第三首、第四首、第一首", got)
	}
	if got[0].artist != "丙" || got[0].album != "丙专辑" || got[0].duration != 300 {
		t.Errorf("字段取错: %+v", got[0])
	}
}

func TestKugouUpcomingRejectsStaleQueue(t *testing.T) {
	// 队列库停在上一次播放 —— 常态。反查不到就退回同专辑预取。
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 旧的", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - 不该取到", album: "乙", singers: []string{"乙"}, seconds: 200},
	})
	if got, ok := kugouUpcoming("丙", "此刻在播的别的歌", 5); ok {
		t.Errorf("反查不到时该退回兜底,却返回了 %+v", got)
	}
}

func TestKugouUpcomingKeepsDashInsideTitle(t *testing.T) {
	// 只切**第一个** " - "。歌名本身带破折号是真实存在的(实测
	// "冬妍DYan - No photo of you left to survey (one day when I was twenty)"),
	// 多切一刀就把歌名截断,拼出来的 enrich key 再也对不上。
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 当前", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - 前奏 - 副歌", album: "乙", singers: []string{"乙"}, seconds: 200},
	})
	got, ok := kugouUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该取到 1 首,得到 ok=%v got=%+v", ok, got)
	}
	if got[0].title != "前奏 - 副歌" {
		t.Errorf("歌名被截成 %q,期望 %q", got[0].title, "前奏 - 副歌")
	}
}

func TestKugouUpcomingJoinsEverySinger(t *testing.T) {
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 当前", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - 合唱", album: "乙", singers: []string{"乙", "丙", "丁"}, seconds: 200},
	})
	got, ok := kugouUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该取到 1 首,得到 ok=%v got=%+v", ok, got)
	}
	if loosenEnrichKey(got[0].artist+"|合唱") != loosenEnrichKey("乙 & 丙 & 丁|合唱") {
		t.Errorf("歌手串 %q 跟播放器报的完整串归一后对不上", got[0].artist)
	}
}

func TestKugouUpcomingFallsBackToMusicNamePrefix(t *testing.T) {
	// singerInfo 解不开(格式变了/被截断)时,歌手退回 musicName 的前缀那一半,
	// 而不是交出空歌手 —— 空歌手拼出来的 key 必然搜不到。
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 当前", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙歌手 - 老条目", album: "乙", seconds: 200},
	})
	got, ok := kugouUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该取到 1 首,得到 ok=%v got=%+v", ok, got)
	}
	if got[0].artist != "乙歌手" || got[0].title != "老条目" {
		t.Errorf("退回前缀失败: %+v", got[0])
	}
}

// 实测形态:15 首的推荐队列,随机从第 0 首跳到第 14 首。小队列整份交出,不管有没有随机证据。
func TestKugouSmallQueueOffersWholeQueue(t *testing.T) {
	writeTestKugouQueue(t, testKugouSongs(15))
	got, ok := kugouUpcoming("甲", "第0首", 5)
	if !ok || len(got) != 14 || got[0].title != "第1首" || got[13].title != "第14首" {
		t.Fatalf("该交出其余 14 首,得到 ok=%v %d 首", ok, len(got))
	}
	got, ok = kugouUpcoming("甲", "第14首", 5)
	if !ok || len(got) != 14 || got[0].title != "第0首" {
		t.Fatalf("在最后一首时该接回开头,不该退回同专辑预取,得到 ok=%v %+v", ok, got)
	}
}

// 大队列:顺序时照旧往后取 n 首;换歌跳着走就按随机,每换一首补 queueShuffleBatch 首没解析过的。
func TestKugouLargeQueueDetectsShuffleFromJumps(t *testing.T) {
	writeTestKugouQueue(t, testKugouSongs(queueShuffleWholeListMax+10))
	isolateEnrichCache(t)
	got, ok := kugouUpcoming("甲", "第0首", 5)
	if !ok || len(got) != 5 || got[0].title != "第1首" {
		t.Fatalf("开播还没有证据,该按列表往后取 5 首,得到 ok=%v %+v", ok, got)
	}
	got, ok = kugouUpcoming("甲", "第1首", 5)
	if !ok || len(got) != 5 || got[0].title != "第2首" {
		t.Fatalf("连续走了一步,仍按列表取,得到 ok=%v %+v", ok, got)
	}
	enrichMu.Lock()
	enrichCache[enrichKey("甲", "第21首", "专辑")] = enrichEntry{} // 跳到的位置之后第一首已经解析过
	enrichMu.Unlock()
	got, ok = kugouUpcoming("甲", "第20首", 5)
	if !ok || len(got) != queueShuffleBatch || got[0].title != "第22首" {
		t.Fatalf("1 → 20 该按随机、跳过已解析的第21首,得到 ok=%v %+v", ok, got)
	}
}

// 队列里只有当前这首:没有能预解析的,退回同专辑预取。
func TestKugouSingleSongQueueFallsBack(t *testing.T) {
	writeTestKugouQueue(t, testKugouSongs(1))
	if got, ok := kugouUpcoming("甲", "第0首", 5); ok {
		t.Fatalf("只有当前这首,该退回同专辑预取,得到 %+v", got)
	}
}

// showName 带版本说明时用它当歌名(播放器报的是它),当前这首按两种写法都认得出来。
func TestKugouUpcomingUsesShowName(t *testing.T) {
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 当前", showName: "当前 (现场版)", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - UP", showName: "UP (KARINA Solo)", album: "乙专辑", singers: []string{"乙"}, seconds: 200},
		{musicName: "丙 - 第三首", album: "丙专辑", singers: []string{"丙"}, seconds: 300},
	})
	got, ok := kugouUpcoming("甲", "当前 (现场版)", 5)
	if !ok || len(got) != 2 || got[0].title != "UP (KARINA Solo)" || got[1].title != "第三首" {
		t.Fatalf("该用 showName 当歌名、没有 showName 的退回 musicName,得到 ok=%v %+v", ok, got)
	}
	if _, ok := kugouUpcoming("乙", "UP (KARINA Solo)", 5); !ok {
		t.Error("播放器报的是 showName 时,当前这首也该在队列里定位得到")
	}
}
