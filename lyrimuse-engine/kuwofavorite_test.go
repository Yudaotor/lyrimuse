package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// 实测 cloud.db:userInfo 的 uid 是十进制 id 的 base64("NDYxMzQzMzc0" = 461343374),没登录那套列表挂在 uid 0 底下。
var kuwoFavMe = kuwoFavoriteUser{encodedUID: "NDYxMzQzMzc0", autoLogin: true, time: "2026-11-16 22:40:02"}

func TestKuwoCurrentUID(t *testing.T) {
	cases := []struct {
		name  string
		users []kuwoFavoriteUser
		want  string
	}{
		{"自动登录那一行解 base64", []kuwoFavoriteUser{kuwoFavMe}, "461343374"},
		{"没有自动登录的当没登录", []kuwoFavoriteUser{{encodedUID: "NDYxMzQzMzc0", time: "2026-11-16 22:40:02"}}, ""},
		{"几个自动登录的取最近登录的", []kuwoFavoriteUser{{encodedUID: "MTIz", autoLogin: true, time: "2026-11-10 10:00:00"}, kuwoFavMe}, "461343374"},
		{"uid 0 不认", []kuwoFavoriteUser{{encodedUID: "MA==", autoLogin: true, time: "t"}}, ""},
		{"不是数字不认", []kuwoFavoriteUser{{encodedUID: "bm90LWRpZ2l0cw==", autoLogin: true, time: "t"}}, ""},
		{"解不开不认", []kuwoFavoriteUser{{encodedUID: "%%%", autoLogin: true, time: "t"}}, ""},
	}
	for _, c := range cases {
		if got := kuwoCurrentUID(c.users); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestKuwoFavoriteRID(t *testing.T) {
	cases := []struct {
		name         string
		queue, lyric []int64
		want         int64
		ok           bool
	}{
		{"播放列表优先、重复行算一个", []int64{4049098, 4049098}, []int64{1}, 4049098, true},
		{"不在列表里按歌词文件名", nil, []int64{7}, 7, true},
		{"列表里对上两个不猜", []int64{1, 2}, []int64{1}, 0, false},
		{"歌词文件名对上两个不猜", nil, []int64{7, 8}, 0, false},
		{"都没有", nil, nil, 0, false},
	}
	for _, c := range cases {
		got, ok := kuwoFavoriteRID(c.queue, c.lyric)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("%s: got %d,%v want %d,%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestKuwoLyricRIDs(t *testing.T) {
	names := []string{"姚贝娜 - 至少还有你 - 4049098.lrcx", "姚贝娜 - 至少还有你 - 12.lrc", "姚贝娜 - 至少还有你 - x1.lrcx",
		"姚贝娜 - 至少还有你 - 3.txt", "姚贝娜 - 至少还有你吗 - 5.lrcx", "张三丰 - 至少还有你 - 9.lrcx",
		"雷安娜&关正杰 - 人在旅途洒泪时 - 3437422.lrcx"}
	if got := kuwoLyricRIDs(names, "姚贝娜", "至少还有你"); !reflect.DeepEqual(got, []int64{4049098, 12}) {
		t.Fatalf("歌手、歌名逐字对上、只认 .lrcx / .lrc 和纯数字 rid: got %v", got)
	}
}

const kuwoFavOutput = "U|NDYxMzQzMzc0|1|2026-11-16 22:40:02\nP|3|0\nP|7|461343374\nQ|4049098\nM|7|4049098\n"

func TestKuwoFavoritedIn(t *testing.T) {
	cases := []struct {
		name, out string
		lyric     []int64
		fav, ok   bool
	}{
		{"当前账号的「我喜欢听」里有这首", kuwoFavOutput, nil, true, true},
		{"没有这一行是没喜欢", strings.Replace(kuwoFavOutput, "M|7|4049098\n", "", 1), nil, false, true},
		{"没登录那套(uid 0)里有不算", strings.Replace(kuwoFavOutput, "M|7|", "M|3|", 1), nil, false, true},
		{"没登录读不到", strings.Replace(kuwoFavOutput, "U|NDYxMzQzMzc0|1|", "U|NDYxMzQzMzc0|0|", 1), nil, false, false},
		{"不在播放列表里按歌词文件名的 rid", strings.Replace(kuwoFavOutput, "Q|4049098\n", "", 1), []int64{4049098}, true, true},
		{"认不出这首读不到", strings.Replace(kuwoFavOutput, "Q|4049098\n", "", 1), nil, false, false},
		{"当前账号两个「我喜欢听」不猜", kuwoFavOutput + "P|8|461343374\n", nil, false, false},
	}
	for _, c := range cases {
		s, ok := parseKuwoFavoriteOutput(c.out)
		if !ok {
			t.Fatalf("%s: 输出没拆开", c.name)
		}
		fav, ok := kuwoFavoritedIn(s, c.lyric)
		if fav != c.fav || ok != c.ok {
			t.Errorf("%s: got %v,%v want %v,%v", c.name, fav, ok, c.fav, c.ok)
		}
	}
}

func TestParseKuwoFavoriteOutputRejectsUnknownRows(t *testing.T) {
	for _, out := range []string{"X|1\n", "Q|abc\n", "M|7\n", "P|3|0\nP|3|0\n"} {
		if _, ok := parseKuwoFavoriteOutput(out); ok {
			t.Errorf("认不出的行(表结构变了)该整份不认: %q", out)
		}
	}
	if _, ok := parseKuwoFavoriteOutput(""); !ok {
		t.Error("零行照常")
	}
}

func TestKuwoFavoriteQuery(t *testing.T) {
	q := kuwoFavoriteQuery("it's", "A", []int64{5, 6}, "/x/kwmusic.db")
	for _, want := range []string{"ATTACH 'file:///x/kwmusic.db?mode=ro' AS q;", "Title = 'it''s' AND Artist = 'A'",
		"UNION VALUES (5), (6)", "SELECT 'U', uid, is_autologin, time FROM userInfo;", "WHERE type = 3"} {
		if !strings.Contains(q, want) {
			t.Errorf("查询串缺 %q:\n%s", want, q)
		}
	}
	if strings.Contains(kuwoFavoriteQuery("t", "a", nil, "/q"), "UNION") {
		t.Error("没有歌词 rid 不拼 UNION")
	}
}

// 造两份跟酷我同结构的库,整条读一遍:只读打开、按账号挑列表、电台按歌词文件名。
func TestKuwoFavoritedReadsContainerDatabases(t *testing.T) {
	dir := t.TempDir()
	build := func(name, script string) string {
		path := filepath.Join(dir, name)
		cmd := exec.Command("/usr/bin/sqlite3", path)
		cmd.Stdin = strings.NewReader(sqliteBatch(script))
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("建测试库失败: %v\n%s", err, out)
		}
		return path
	}
	cloud := build("cloud.db", `CREATE TABLE playlistsInfo (id INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT NOT NULL, title TEXT NOT NULL, type INTEGER NOT NULL, pid INTEGER, version INTEGER, op INTEGER, desc TEXT, sort_type INTEGER, serial INTEGER, sicon TEXT);
CREATE TABLE playlistMusics (id INTEGER PRIMARY KEY AUTOINCREMENT, type INTEGER NOT NULL, rid INTEGER NOT NULL, title TEXT NOT NULL, artist TEXT, playlist_id INTEGER);
CREATE TABLE userInfo (uid TEXT PRIMARY KEY, name TEXT NOT NULL, is_autologin INTEGER, time TIMESTAMP);
INSERT INTO userInfo VALUES('NDYxMzQzMzc0','x',1,'2026-11-16 22:40:02');
INSERT INTO playlistsInfo(id,uid,title,type) VALUES(3,'0','我喜欢听',3),(6,'461343374','默认列表',1),(7,'461343374','我喜欢听',3);
INSERT INTO playlistMusics(type,rid,title,artist,playlist_id) VALUES(2,4049098,'至少还有你','姚贝娜',7),(2,2764717,'吸烟的女人','Raidas',3),(2,450567,'让我愉快爱一次','周影',7);
`)
	queue := build("kwmusic.db", `CREATE TABLE PlayList(ID INTEGER PRIMARY KEY AUTOINCREMENT,Type INTEGER,PersistentId INTEGER,Title TEXT,Artist TEXT,Album TEXT,Duration INTEGER);
INSERT INTO PlayList(ID,Type,PersistentId,Title,Artist) VALUES(12,2,4049098,'至少还有你','姚贝娜'),(13,2,65021876,'千年等一回','鞠婧祎'),(14,2,2764717,'吸烟的女人','Raidas');
`)
	lyrics := filepath.Join(dir, "Lyric")
	if err := os.MkdirAll(lyrics, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(lyrics, "周影 - 让我愉快爱一次 - 450567.lrc"), []byte("utf8\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	oldDB, oldQueue, oldLyric := kuwoFavoriteDBOverride, kuwoUpcomingOverride, kuwoLocalDirOverride
	kuwoFavoriteDBOverride, kuwoUpcomingOverride, kuwoLocalDirOverride = cloud, queue, lyrics
	t.Cleanup(func() { kuwoFavoriteDBOverride, kuwoUpcomingOverride, kuwoLocalDirOverride = oldDB, oldQueue, oldLyric })

	cases := []struct {
		title, artist string
		fav, ok       bool
	}{
		{"至少还有你", "姚贝娜", true, true},
		{"千年等一回", "鞠婧祎", false, true},
		{"吸烟的女人", "Raidas", false, true}, // 只在没登录那套里
		{"让我愉快爱一次", "周影", true, true},    // 电台:不在播放列表里,按歌词文件名
		{"不在哪儿的歌", "谁", false, false},
		{"", "姚贝娜", false, false},
	}
	for _, c := range cases {
		fav, ok := kuwoFavorited(c.title, c.artist)
		if fav != c.fav || ok != c.ok {
			t.Errorf("%s - %s: got %v,%v want %v,%v", c.artist, c.title, fav, ok, c.fav, c.ok)
		}
	}
	for _, p := range []string{cloud + "-journal", queue + "-journal", cloud + "-wal", queue + "-wal"} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("只读打开不该建 %s", filepath.Base(p))
		}
	}
}

func TestKuwoFavoriteIsWired(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(b), `if len(os.Args) > 1 && os.Args[1] == "kuwo-favorite" { runKuwoFavoriteCLI(os.Args[2:])`) {
		t.Error("main.go 没接 kuwo-favorite(App 的酷我喜欢键靠它读状态)")
	}
}
