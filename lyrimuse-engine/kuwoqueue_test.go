package main

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type kuwoTestSong struct{ title, artist, album string }

// writeTestKuwoDB 造一份跟酷我 kwmusic.db 同结构的 PlayList 表(列照真实库,ID 从 8 开始、不连续也照收)。
func writeTestKuwoDB(t *testing.T, songs []kuwoTestSong) string {
	t.Helper()
	var sql strings.Builder
	sql.WriteString("CREATE TABLE PlayList(ID INTEGER PRIMARY KEY AUTOINCREMENT,Type INTEGER,PersistentId TEXT,Title TEXT," +
		"Artist TEXT,Album TEXT,Duration INTEGER,Source TEXT,HasMV INTEGER,MVQuality TEXT,PlayListId INTEGER,IsLocalMusic INTEGER," +
		"IsDownload INTEGER,MusicQuality TEXT,PayFlag TEXT,MediaQualityInfo TEXT);\n")
	esc := func(s string) string { return strings.ReplaceAll(s, "'", "''") }
	for i, s := range songs {
		fmt.Fprintf(&sql, "INSERT INTO PlayList(ID,Type,PersistentId,Title,Artist,Album,Duration) VALUES(%d,0,'%d','%s','%s','%s',%d);\n",
			8+i*2, 1000+i, esc(s.title), esc(s.artist), esc(s.album), 200+i)
	}
	path := filepath.Join(t.TempDir(), "kwmusic.db")
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sqliteBatch(sql.String()))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("建测试库失败: %v\n%s", err, out)
	}
	return path
}

func useKuwoQueue(t *testing.T, path string) {
	t.Helper()
	old := kuwoUpcomingOverride
	kuwoUpcomingOverride = path
	kuwoPlayOrderMu.Lock()
	kuwoPlayOrderLast = queueOrder{}
	kuwoPlayOrderMu.Unlock()
	t.Cleanup(func() {
		kuwoUpcomingOverride = old
		kuwoPlayOrderMu.Lock()
		kuwoPlayOrderLast = queueOrder{}
		kuwoPlayOrderMu.Unlock()
	})
}

func TestKuwoUpcomingSmallListWholeFromCurrent(t *testing.T) {
	useKuwoQueue(t, writeTestKuwoDB(t, []kuwoTestSong{
		{"千千阙歌", "吉他的天空", ""},
		{"有多少爱可以重来", "刘宇宁", "专辑甲"},
		{"雨碟", "蓝澜", "专辑乙"},
		{"一千年以后", "黑鸭子演唱组", "专辑丙"},
	}))
	got, ok := kuwoUpcoming("刘宇宁", "有多少爱可以重来", 5)
	if !ok || len(got) != 3 {
		t.Fatalf("小列表该整份交出(当前这首除外): ok=%v %+v", ok, got)
	}
	if got[0].title != "雨碟" || got[0].album != "专辑乙" || got[0].duration != 202 || got[2].title != "千千阙歌" {
		t.Fatalf("该从当前往后、到末尾接回开头: %+v", got)
	}
}

func TestKuwoUpcomingCurrentNotInList(t *testing.T) {
	useKuwoQueue(t, writeTestKuwoDB(t, []kuwoTestSong{{"雨碟", "蓝澜", ""}, {"一千年以后", "黑鸭子演唱组", ""}}))
	if got, ok := kuwoUpcoming("Raidas", "吸烟的女人", 5); ok {
		t.Fatalf("在放的这首不在列表里(电台)该退回: %+v", got)
	}
	useKuwoQueue(t, writeTestKuwoDB(t, []kuwoTestSong{{"雨碟", "蓝澜", ""}}))
	if _, ok := kuwoUpcoming("蓝澜", "雨碟", 5); ok {
		t.Fatal("列表里只有当前这首时该退回")
	}
}

func TestKuwoUpcomingMissingDBIsQuiet(t *testing.T) {
	useKuwoQueue(t, filepath.Join(t.TempDir(), "nope.db"))
	if _, ok := kuwoUpcoming("蓝澜", "雨碟", 5); ok {
		t.Fatal("库不在该返回 false")
	}
}

func TestKuwoPickUpcomingLargeListOrderedThenShuffled(t *testing.T) {
	rows := make([]kuwoQueueRow, queueShuffleWholeListMax+10)
	for i := range rows {
		rows[i] = kuwoQueueRow{ID: int64(i + 1), PersistentID: float64(5000 + i), Title: fmt.Sprintf("歌%02d", i), Artist: "某人", Duration: float64(180)}
	}
	useKuwoQueue(t, "")
	got, ok := kuwoPickUpcoming(rows, "某人", "歌03", 2)
	if !ok || len(got) != 2 || got[0].title != "歌04" || got[1].title != "歌05" {
		t.Fatalf("顺序时该往后取 n 首: %+v", got)
	}
	// 从 3 跳到 20:按随机处理,不再只取紧接着的两首。
	got, ok = kuwoPickUpcoming(rows, "某人", "歌20", 2)
	if !ok || len(got) != queueShuffleBatch || got[0].title != "歌21" {
		t.Fatalf("跳着放该按随机交一批: %+v", got)
	}
}

func TestKuwoQueueNumber(t *testing.T) {
	for in, want := range map[any]string{float64(228908): "228908", "228908": "228908", " 12 ": "12", "MUSIC_1": "", float64(-1): "", 1.5: "", nil: ""} {
		if got := kuwoQueueNumber(in); got != want {
			t.Errorf("%v: got %q want %q", in, got, want)
		}
	}
}
