package main

import (
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type testKugouPlistSong struct {
	musicName  string // "歌手 - 歌名"
	singerName string
	hash       string
	seconds    float64
}

// testKugouPlistEnv 造三份跟真机同构的文件:队列 plist、配置 plist、客户端曲库。
type testKugouPlistEnv struct {
	t   *testing.T
	dir string
}

func newTestKugouPlistEnv(t *testing.T) *testKugouPlistEnv {
	t.Helper()
	env := &testKugouPlistEnv{t: t, dir: t.TempDir()}
	for _, p := range []*string{&kugouQueuePlistOverride, &kugouConfigPlistOverride, &kugouLibraryDBOverride, &kugouUpcomingOverride} {
		old := *p
		t.Cleanup(func() { *p = old })
	}
	// 默认全部指到不存在的文件,每个测试按需写真的出来 —— 绝不能落到本机真实的酷狗数据上。
	kugouQueuePlistOverride = filepath.Join(env.dir, "no-queue.plist")
	kugouConfigPlistOverride = filepath.Join(env.dir, "no-config.plist")
	kugouLibraryDBOverride = filepath.Join(env.dir, "no-library.sqlite")
	kugouUpcomingOverride = filepath.Join(env.dir, "no-legacy.sqlite")
	resetKugouPlayOrder(t)
	return env
}

// resetKugouPlayOrder 清掉顺序 / 随机的证据,测试结束再清一次,免得带进下一个测试。
func resetKugouPlayOrder(t *testing.T) {
	t.Helper()
	kugouPlayOrderMu.Lock()
	kugouPlayOrderLast = queueOrder{}
	kugouPlayOrderMu.Unlock()
	t.Cleanup(func() {
		kugouPlayOrderMu.Lock()
		kugouPlayOrderLast = queueOrder{}
		kugouPlayOrderMu.Unlock()
	})
}

func plistSongDict(s testKugouPlistSong) string {
	return fmt.Sprintf(`<dict><key>musicName</key><string>%s</string><key>singerName</key><string>%s</string>`+
		`<key>strFileHash</key><string>%s</string><key>musicTime</key><real>%v</real>`+
		`<key>currentProgress</key><real>59.7</real></dict>`,
		html.EscapeString(s.musicName), html.EscapeString(s.singerName), s.hash, s.seconds)
}

// writeQueue 写 userCurrentPlayList.plist。index 是 userPlayList[2] 那个**字符串**下标(真机就是字符串)。
func (e *testKugouPlistEnv) writeQueue(songs []testKugouPlistSong, index int) {
	e.t.Helper()
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>`)
	b.WriteString(`<key>kPlayListSaveFromPage</key><string>排行榜</string><key>userPlayList</key><array><array>`)
	for _, s := range songs {
		b.WriteString(plistSongDict(s))
	}
	b.WriteString(`</array>`)
	if index >= 0 && index < len(songs) {
		b.WriteString(plistSongDict(songs[index]))
	} else {
		b.WriteString(`<dict/>`)
	}
	fmt.Fprintf(&b, `<string>%d</string></array></dict></plist>`, index)
	path := filepath.Join(e.dir, "userCurrentPlayList.plist")
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		e.t.Fatalf("写队列 plist: %v", err)
	}
	kugouQueuePlistOverride = path
}

func (e *testKugouPlistEnv) writePlayMode(mode int) {
	e.t.Helper()
	path := filepath.Join(e.dir, "KugouConfigPlist.plist")
	body := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>`+
		`<key>playMode</key><integer>%d</integer></dict></plist>`, mode)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		e.t.Fatalf("写配置 plist: %v", err)
	}
	kugouConfigPlistOverride = path
}

// writeLibrary 建 kugou3.sqlite 的 Allmusic 表。album 为 nil 表示 albumname 列是 NULL。
// hash 故意写成小写:真机曲库里是小写、队列 plist 里是大写。
func (e *testKugouPlistEnv) writeLibrary(albums map[string]*string) {
	e.t.Helper()
	var sql strings.Builder
	sql.WriteString("CREATE TABLE Allmusic(musicname TEXT, singer TEXT, albumname TEXT, musichash TEXT, musictime REAL);\n")
	for h, a := range albums {
		v := "NULL"
		if a != nil {
			v = "'" + strings.ReplaceAll(*a, "'", "''") + "'"
		}
		fmt.Fprintf(&sql, "INSERT INTO Allmusic VALUES('x','x',%s,'%s',1);\n", v, strings.ToLower(h))
	}
	path := filepath.Join(e.dir, "kugou3.sqlite")
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sql.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		e.t.Fatalf("建曲库失败: %v\n%s", err, out)
	}
	kugouLibraryDBOverride = path
}

func strp(s string) *string { return &s }

// 真实形态:当前这首在 [2] 指的位置,后面的歌从曲库补专辑。
func TestKugouPlistUsesStoredPositionAndLibraryAlbums(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"甲 - 第一首", "甲", "AAAA01", 100},
		{"乙 - 第二首", "乙", "AAAA02", 200},
		{"丙 - 第三首", "丙", "AAAA03", 300},
		{"丁 - 第四首", "丁", "AAAA04", 400},
	}, 1)
	env.writePlayMode(0)
	env.writeLibrary(map[string]*string{"AAAA03": strp("丙专辑"), "AAAA04": strp("丁专辑")})

	got, ok := kugouUpcoming("乙", "第二首", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到第三、四首,得到 ok=%v %+v", ok, got)
	}
	if got[0] != (upcomingTrack{artist: "丙", title: "第三首", album: "丙专辑", duration: 300}) {
		t.Errorf("字段取错: %+v", got[0])
	}
	if got[1].album != "丁专辑" {
		t.Errorf("第四首专辑 %q", got[1].album)
	}
}

// 指针落后(文件还没跟上这次切歌):在队列里再找一次,而不是放弃。
func TestKugouPlistRescansWhenStoredPositionIsStale(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"甲 - 第一首", "甲", "AAAA01", 100},
		{"乙 - 第二首", "乙", "AAAA02", 200},
		{"丙 - 第三首", "丙", "AAAA03", 300},
	}, 0) // 指针还停在第一首
	env.writeLibrary(map[string]*string{"AAAA03": strp("丙专辑")})

	got, ok := kugouUpcoming("乙", "第二首", 5)
	if !ok || len(got) != 1 || got[0].title != "第三首" {
		t.Fatalf("该从第二首往后取,得到 ok=%v %+v", ok, got)
	}
}

// plist 读到了、当前这首不在里面:不退回旧 sqlite。那份库是过期的,反查命中只会预取一批不会播的歌。
func TestKugouPlistMissDoesNotFallBackToLegacySQLite(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"甲 - 当前歌单里的", "甲", "AAAA01", 100},
		{"乙 - 当前歌单里的二", "乙", "AAAA02", 200},
	}, 0)
	// 旧库里**有**此刻在播的这首 —— 就是 09-22 那种「过期歌单恰好也含这首歌」的形态。
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "丙 - 过期歌单", album: "丙", singers: []string{"丙"}, seconds: 100},
		{musicName: "丁 - 不该取到", album: "丁", singers: []string{"丁"}, seconds: 200},
	})
	kugouQueuePlistOverride = filepath.Join(env.dir, "userCurrentPlayList.plist") // writeTestKugouQueue 把它指走了,指回来

	if got, ok := kugouUpcoming("丙", "过期歌单", 5); ok {
		t.Errorf("当前队列里没有这首,不该拿过期库去反查,却返回了 %+v", got)
	}
}

// plist 根本读不到(老客户端 / 文件不存在)时才退回旧 sqlite。
func TestKugouPlistMissingFallsBackToLegacySQLite(t *testing.T) {
	newTestKugouPlistEnv(t)
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 当前", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - 下一首", album: "乙专辑", singers: []string{"乙"}, seconds: 200},
	})
	got, ok := kugouUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 || got[0].album != "乙专辑" {
		t.Fatalf("plist 不存在时该走旧库,得到 ok=%v %+v", ok, got)
	}
}

// playMode 非 0(单曲循环 / 随机,具体哪个没对照过)不信列表顺序:大队列也按随机挑没解析过的那一批。
func TestKugouPlistNonListOrderPlayModeTreatedAsShuffle(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	songs := make([]testKugouPlistSong, queueShuffleWholeListMax+10)
	albums := map[string]*string{}
	for i := range songs {
		h := fmt.Sprintf("AAAA%02X", i)
		songs[i] = testKugouPlistSong{fmt.Sprintf("甲 - 第%d首", i), "甲", h, 100}
		albums[h] = strp("专辑")
	}
	env.writeQueue(songs, 0)
	env.writeLibrary(albums)
	isolateEnrichCache(t)
	env.writePlayMode(1)
	got, ok := kugouUpcoming("甲", "第0首", 3)
	if !ok || len(got) != queueShuffleBatch {
		t.Fatalf("playMode=1 该按随机交 %d 首,得到 ok=%v %d 首", queueShuffleBatch, ok, len(got))
	}
	env.writePlayMode(0)
	resetKugouPlayOrder(t)
	got, ok = kugouUpcoming("甲", "第0首", 3)
	if !ok || len(got) != 3 || got[0].title != "第1首" {
		t.Errorf("playMode=0、还没有随机证据:该按列表往后取 3 首,得到 ok=%v %+v", ok, got)
	}
}

// 推荐流(「首页 → 推荐」):plist 被清成两个空列表、队列写在旧库里。认不出 plist 的队列就退回旧库。
func TestKugouRecommendStreamUsesLegacySQLite(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	path := filepath.Join(env.dir, "userCurrentPlayList.plist")
	body := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>` +
		`<key>userLastNormalPlayList</key><array/><key>userPreNormalPlayList</key><array/></dict></plist>`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("写队列 plist: %v", err)
	}
	writeTestKugouQueue(t, []testKugouSong{
		{musicName: "甲 - 当前", album: "甲", singers: []string{"甲"}, seconds: 100},
		{musicName: "乙 - 推荐二", album: "乙专辑", singers: []string{"乙"}, seconds: 200},
	})
	kugouQueuePlistOverride = path // writeTestKugouQueue 把它指走了,指回来
	got, ok := kugouUpcoming("甲", "当前", 5)
	if !ok || len(got) != 1 || got[0].title != "推荐二" {
		t.Fatalf("该从旧库取到推荐队列,得到 ok=%v %+v", ok, got)
	}
}

// 配置读不到时按列表顺序算 —— 跟这条路原来的行为一致,不因为少一个文件就整条关掉。
func TestKugouPlistUnknownPlayModeKeepsListOrder(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"甲 - 当前", "甲", "AAAA01", 100},
		{"乙 - 下一首", "乙", "AAAA02", 200},
	}, 0)
	env.writeLibrary(map[string]*string{"AAAA02": strp("乙专辑")})
	if _, ok := kugouUpcoming("甲", "当前", 5); !ok {
		t.Errorf("没有配置文件时该照列表顺序取")
	}
}

// 曲库里没有的歌跳过(不拿空专辑去猜);曲库里有、专辑列是 NULL 的,照样取,专辑为空串。
func TestKugouPlistAlbumLookupSkipsUnknownKeepsNull(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"甲 - 当前", "甲", "AAAA01", 100},
		{"乙 - 曲库里没有", "乙", "AAAA02", 200},
		{"丙 - 专辑是 NULL", "丙", "AAAA03", 300},
		{"丁 - 正常", "丁", "AAAA04", 400},
	}, 0)
	env.writeLibrary(map[string]*string{"AAAA03": nil, "AAAA04": strp("丁专辑")})
	got, ok := kugouUpcoming("甲", "当前", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到丙、丁两首,得到 ok=%v %+v", ok, got)
	}
	if got[0].title != "专辑是 NULL" || got[0].album != "" || got[1].album != "丁专辑" {
		t.Errorf("取错: %+v", got)
	}
}

// 署名:接下来那几首用 singerName(播放器经署名修正后报的就是它);当前这首两种署名都认。
func TestKugouPlistArtistForms(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"少司命、新乐尘符 - 不归人", "少司命", "AAAA01", 200},
		{"善宇、怪兽 - 街角的晚风 (粤语版)", "善宇", "AAAA02", 210},
	}, 0)
	env.writeLibrary(map[string]*string{"AAAA02": strp("街角的晚风")})
	for _, cur := range []string{"少司命", "少司命、新乐尘符"} {
		got, ok := kugouUpcoming(cur, "不归人", 5)
		if !ok || len(got) != 1 {
			t.Fatalf("当前署名报成 %q 时该认出来,得到 ok=%v %+v", cur, ok, got)
		}
		if got[0].artist != "善宇" || got[0].title != "街角的晚风 (粤语版)" {
			t.Errorf("下一首署名该是 singerName「善宇」,得到 %+v", got[0])
		}
	}
}

func TestKugouQueueIndexForms(t *testing.T) {
	for _, c := range []struct {
		in   any
		want int
		ok   bool
	}{{"16", 16, true}, {" 3 ", 3, true}, {int64(2), 2, true}, {"-1", 0, false}, {"x", 0, false}, {nil, 0, false}} {
		got, ok := kugouQueueIndex(c.in)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("kugouQueueIndex(%#v) = %d,%v 期望 %d,%v", c.in, got, ok, c.want, c.ok)
		}
	}
}

// hash 要拼进 SQL,非十六进制的直接不查(也就不预解析那首)。
func TestKugouAlbumLookupRejectsNonHexHash(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeLibrary(map[string]*string{"AAAA01": strp("甲")})
	got := kugouAlbumsByHash([]kugouQueueSong{{hash: "AAAA01"}, {hash: "x') OR 1=1 --"}})
	if len(got) != 1 || got["AAAA01"] != "甲" {
		t.Errorf("得到 %+v", got)
	}
}

// 酷狗的同专辑兜底:按队列里当前这首的 hash 找专辑、取酷狗自己的曲目表,「歌手 - 歌名」照队列那套拆。
func TestAlbumTracksKugouUsesKugouAlbum(t *testing.T) {
	env := newTestKugouPlistEnv(t)
	env.writeQueue([]testKugouPlistSong{
		{"方大同 - 南音", "方大同", "17B35201DECC6DC9D7ED4A630A808082", 215},
	}, 0)
	kugouAlbumMu.Lock()
	oldIDs, oldAlbums := kugouAlbumIDCache, kugouAlbumCache
	kugouAlbumIDCache = map[string]string{"17B35201DECC6DC9D7ED4A630A808082": "966707"}
	kugouAlbumCache = map[string][]albumTrack{"966707": {
		{title: "Prologue", artist: "方大同", duration: 43},
		{title: "南音", artist: "方大同", duration: 215},
	}}
	kugouAlbumMu.Unlock()
	t.Cleanup(func() {
		kugouAlbumMu.Lock()
		kugouAlbumIDCache, kugouAlbumCache = oldIDs, oldAlbums
		kugouAlbumMu.Unlock()
	})

	tracks, ok := albumTracks("方大同", "南音", "Soul Boy", kugouMusicBundleID)
	if !ok || len(tracks) != 2 || tracks[0].title != "Prologue" || tracks[0].duration != 43 {
		t.Fatalf("该取到酷狗专辑的曲目表,得到 ok=%v %+v", ok, tracks)
	}
	// 队列里没有当前这首:本地这条放弃,交给网易云那条。
	if got, ok := kugouAlbumTracks("别人", "别的歌", "专辑"); ok {
		t.Errorf("队列里没有当前这首,不该取到: %+v", got)
	}
}
