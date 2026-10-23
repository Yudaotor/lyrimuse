package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type voxFixtureTrack struct {
	pk, fok              int
	url, name, artist    string
	album                string
	dur                  float64
	inDefault, inAnother bool
}

// withVoxPlaylistDB 造一份跟 VOX 同结构的库(只建用到的列),路径指给 voxUpcomingOverride。
func withVoxPlaylistDB(t *testing.T, tracks []voxFixtureTrack) {
	t.Helper()
	q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	var sql strings.Builder
	sql.WriteString("CREATE TABLE ZVXLOCALOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZISDEFAULT INTEGER, ZNAME VARCHAR, ZARTISTNAME VARCHAR, ZALBUMNAME VARCHAR, ZURL VARCHAR, ZVX_DURATION FLOAT);\n")
	sql.WriteString("CREATE TABLE Z_7TRACKS (Z_7PLAYLISTS INTEGER, Z_10TRACKS INTEGER, Z_FOK_7PLAYLISTS INTEGER, Z_FOK_10TRACKS INTEGER, PRIMARY KEY (Z_7PLAYLISTS, Z_10TRACKS));\n")
	sql.WriteString("INSERT INTO ZVXLOCALOBJECT (Z_PK, Z_ENT, ZISDEFAULT, ZNAME) VALUES (1, 8, 1, 'Playlist'), (2, 8, 0, 'Other');\n")
	for _, tr := range tracks {
		fmt.Fprintf(&sql, "INSERT INTO ZVXLOCALOBJECT (Z_PK, Z_ENT, ZNAME, ZARTISTNAME, ZALBUMNAME, ZURL, ZVX_DURATION) VALUES (%d, 11, %s, %s, %s, %s, %g);\n",
			tr.pk, q(tr.name), q(tr.artist), q(tr.album), q(tr.url), tr.dur)
		if tr.inDefault {
			fmt.Fprintf(&sql, "INSERT INTO Z_7TRACKS VALUES (1, %d, 0, %d);\n", tr.pk, tr.fok)
		}
		if tr.inAnother {
			fmt.Fprintf(&sql, "INSERT INTO Z_7TRACKS VALUES (2, %d, 0, %d);\n", tr.pk, tr.fok)
		}
	}
	path := filepath.Join(t.TempDir(), "voxdb.storedata")
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sqliteBatch(sql.String()))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("建库失败: %v\n%s", err, out)
	}
	saved := voxUpcomingOverride
	voxUpcomingOverride = path
	t.Cleanup(func() { voxUpcomingOverride = saved })
}

// withVoxRepeating 把问循环档换成固定答案;calls 记问了几次。
func withVoxRepeating(t *testing.T, mode string, ok bool) *int {
	t.Helper()
	calls := 0
	saved := voxRepeating
	voxRepeating = func() (string, bool) { calls++; return mode, ok }
	t.Cleanup(func() { voxRepeating = saved })
	return &calls
}

func voxFileURL(name string) string { return "file:///Users/x/Music/%E6%AD%8C/" + name }

func voxTitles(res []upcomingTrack) []string {
	out := make([]string, len(res))
	for i, r := range res {
		out[i] = r.artist + "/" + r.title
	}
	return out
}

// 按列表顺序(Z_FOK_10TRACKS,不是主键顺序)取当前这首后面的;当前这首按文件认,不在默认列表里的曲目不算。
func TestVoxUpcomingFollowsPlaylistOrder(t *testing.T) {
	withVoxPlaylistDB(t, []voxFixtureTrack{
		{pk: 10, fok: 4096, url: voxFileURL("c.mp3"), name: "C", artist: "甲", album: "专辑", dur: 200, inDefault: true},
		{pk: 11, fok: 2048, url: voxFileURL("a.mp3"), name: "A", artist: "甲", dur: 180, inDefault: true},
		{pk: 12, fok: 3072, url: voxFileURL("b.mp3"), name: "B", artist: "乙", dur: 190, inDefault: true},
		{pk: 13, fok: 5120, url: voxFileURL("d.mp3"), name: "D", artist: "丙", dur: 210, inDefault: true},
		{pk: 14, fok: 3500, url: voxFileURL("x.mp3"), name: "X", artist: "外", dur: 100, inAnother: true},
	})
	rows, ok := voxPlaylistRows()
	if !ok || len(rows) != 4 {
		t.Fatalf("该读到默认列表的 4 首: ok=%v %+v", ok, rows)
	}
	res, ok := voxPickUpcoming(rows, "/Users/x/Music/歌/a.mp3", "甲", "A", 2, false)
	if got := voxTitles(res); !ok || strings.Join(got, ",") != "乙/B,甲/C" {
		t.Fatalf("按列表顺序取后两首: %v", got)
	}
	if res[1].album != "专辑" || res[1].duration != 200 {
		t.Errorf("专辑、时长带上: %+v", res[1])
	}
	// 没有当前文件(或对不上)时按歌名歌手找。
	if res, ok := voxPickUpcoming(rows, "", "乙", "B", 5, false); !ok || strings.Join(voxTitles(res), ",") != "甲/C,丙/D" {
		t.Errorf("按歌名歌手定位: %v", voxTitles(res))
	}
	// 同一首在列表里有两份(两个目录):按文件认出放的是后一份,取它后面的。
	dup := []voxUpcomingRow{
		{URL: voxFileURL("1/a.mp3"), Name: "A", Artist: "甲"}, {URL: voxFileURL("b.mp3"), Name: "B", Artist: "乙"},
		{URL: voxFileURL("2/a.mp3"), Name: "A", Artist: "甲"}, {URL: voxFileURL("c.mp3"), Name: "C", Artist: "丙"},
	}
	if res, ok := voxPickUpcoming(dup, "/Users/x/Music/歌/2/a.mp3", "甲", "A", 1, false); !ok || strings.Join(voxTitles(res), ",") != "丙/C" {
		t.Errorf("同一首两份时按文件定位: %v", voxTitles(res))
	}
	// 放到最后一首、列表里没有这首:退回同专辑预取。
	if _, ok := voxPickUpcoming(rows, "/Users/x/Music/歌/d.mp3", "丙", "D", 5, false); ok {
		t.Error("最后一首后面没有,不绕回开头")
	}
	if _, ok := voxPickUpcoming(rows, "/Users/x/Music/歌/none.mp3", "谁", "没有", 5, false); ok {
		t.Error("列表里没有当前这首要退回")
	}
}

// 列表循环时放到最后接回开头,不把当前这首算进去;单曲循环不预取、也不读库;不循环或问不到循环档时到最后为止。
func TestVoxUpcomingFollowsRepeatMode(t *testing.T) {
	withVoxPlaylistDB(t, []voxFixtureTrack{
		{pk: 10, fok: 2048, url: voxFileURL("a.mp3"), name: "A", artist: "甲", inDefault: true},
		{pk: 11, fok: 3072, url: voxFileURL("b.mp3"), name: "B", artist: "乙", inDefault: true},
		{pk: 12, fok: 4096, url: voxFileURL("c.mp3"), name: "C", artist: "丙", inDefault: true},
		{pk: 13, fok: 5120, url: voxFileURL("d.mp3"), name: "D", artist: "丁", inDefault: true},
	})
	calls := withVoxRepeating(t, "all", true)
	if res, ok := voxUpcoming("丁", "D", 2); !ok || strings.Join(voxTitles(res), ",") != "甲/A,乙/B" {
		t.Errorf("列表循环在最后一首时接回开头: ok=%v %v", ok, voxTitles(res))
	}
	if *calls != 1 {
		t.Errorf("每次换歌问一次循环档: %d", *calls)
	}
	if res, ok := voxUpcoming("乙", "B", 5); !ok || strings.Join(voxTitles(res), ",") != "丙/C,丁/D,甲/A" {
		t.Errorf("绕一圈到当前这首为止: ok=%v %v", ok, voxTitles(res))
	}

	withVoxRepeating(t, "one", true)
	saved := voxUpcomingOverride
	voxUpcomingOverride = filepath.Join(t.TempDir(), "missing.storedata")
	if res, ok := voxUpcoming("乙", "B", 5); !ok || len(res) != 0 {
		t.Errorf("单曲循环:下一首还是这首,不预取、也不退回同专辑: ok=%v %v", ok, voxTitles(res))
	}
	voxUpcomingOverride = saved

	for _, c := range []struct {
		mode string
		ok   bool
	}{{"off", true}, {"", false}} {
		withVoxRepeating(t, c.mode, c.ok)
		if _, ok := voxUpcoming("丁", "D", 5); ok {
			t.Errorf("循环档 %q(问到=%v)时最后一首后面没有,退回同专辑预取", c.mode, c.ok)
		}
		if res, ok := voxUpcoming("乙", "B", 5); !ok || strings.Join(voxTitles(res), ",") != "丙/C,丁/D" {
			t.Errorf("循环档 %q(问到=%v)时到最后为止: %v", c.mode, c.ok, voxTitles(res))
		}
	}
}

// 循环档由 App 代问:请求种类是 vox_repeat,只认 off / one / all。
func TestVoxRepeatingAsksTheApp(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	answer := `{"repeating":"all"}`
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: answer}
	})
	if mode, ok := voxRepeating(); !ok || mode != "all" {
		t.Fatalf("应拿到 App 交回的循环档: %q %v", mode, ok)
	}
	select {
	case req := <-seen:
		if req.Kind != appQueryVoxRepeat {
			t.Errorf("请求种类: %q", req.Kind)
		}
	case <-time.After(time.Second):
		t.Fatal("没看到请求")
	}
	for _, out := range []string{`{"repeating":"shuffle"}`, `{}`, `oops`} {
		answer = out
		if mode, ok := voxRepeating(); ok {
			t.Errorf("认不出的应答 %s 当问不到: %q", out, mode)
		}
	}
}

// 网络地址、没写标签(歌手空)、像 GBK 乱码的跳过;带重音的西文名照取。
func TestVoxUpcomingSkipsUnguessableRows(t *testing.T) {
	rows := []voxUpcomingRow{
		{URL: voxFileURL("now.mp3"), Name: "Now", Artist: "A"},
		{URL: "http://radio.example/stream", Name: "Radio", Artist: "A"},
		{URL: voxFileURL("untagged.mp3"), Name: "untagged", Artist: ""},
		{URL: voxFileURL("gbk.mp3"), Name: "ÁcÅé", Artist: "´ú¸Õ"},
		{URL: voxFileURL("cubicos.mp3"), Name: "Cúbicos", Artist: "Beyoncé"},
	}
	res, ok := voxPickUpcoming(rows, "/Users/x/Music/歌/now.mp3", "A", "Now", 5, false)
	if got := voxTitles(res); !ok || strings.Join(got, ",") != "Beyoncé/Cúbicos" {
		t.Errorf("只留猜得准的那首: %v", got)
	}
}

// 库的结构对不上(VOX 换了数据模型)、库不在:退回,不报错。
func TestVoxUpcomingFallsBackOnSchemaDrift(t *testing.T) {
	path := filepath.Join(t.TempDir(), "voxdb.storedata")
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sqliteBatch("CREATE TABLE ZOTHER (Z_PK INTEGER);\n"))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("建库失败: %v\n%s", err, out)
	}
	withVoxRepeating(t, "", false)
	saved := voxUpcomingOverride
	t.Cleanup(func() { voxUpcomingOverride = saved })
	voxUpcomingOverride = path
	if _, ok := voxUpcoming("A", "B", 5); ok {
		t.Error("结构对不上要退回")
	}
	voxUpcomingOverride = filepath.Join(t.TempDir(), "missing.storedata")
	if _, ok := voxUpcoming("A", "B", 5); ok {
		t.Error("库不在要退回")
	}
}

// 预解析分发里 VOX 走这条路。
func TestVoxUpcomingIsWired(t *testing.T) {
	b, err := os.ReadFile("upcoming.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(b), "case voxBundleID:\n") || !containsCode(string(b), "return voxUpcoming(artist, title, n)\n") {
		t.Error("upcomingFromQueue 里 VOX 没接上读列表")
	}
}
