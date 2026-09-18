package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 同 qqlocal_test.go:全部用合成的 dbTrack,不读本机真实的网易云库。

// neteaseTestTrack 按 dbTrack 里真实的写法造一条曲目 JSON —— id / album.id 是**字符串**
// 形态的数字,这正是 flexID 要吃下的形状。
func neteaseTestTrack(id, name, artist, album string, durationMS int) string {
	artists := []map[string]string{}
	for _, a := range strings.Split(artist, "|") {
		if a != "" {
			artists = append(artists, map[string]string{"id": "1", "name": a})
		}
	}
	m := map[string]any{
		"id": id, "name": name, "duration": durationMS,
		"artists": artists,
		"album":   map[string]any{"id": "900" + id, "name": album},
	}
	b, err := json.Marshal(m)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func writeTestNeteaseDB(t *testing.T, tracks []string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "Application Support")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	path := filepath.Join(dir, "sqlite_storage.sqlite3")
	var sb strings.Builder
	sb.WriteString("CREATE TABLE `dbTrack` (`id` VARCHAR(40) NOT NULL, `jsonStr` TEXT NULL, PRIMARY KEY (`id`));\n")
	for i, j := range tracks {
		sb.WriteString(fmt.Sprintf("INSERT INTO dbTrack VALUES ('k%d',%s);\n", i, sqlQuote(j)))
	}
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sb.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("建测试库失败(没有 /usr/bin/sqlite3?): %v %s", err, out)
	}
	return path
}

func resetNeteaseLocalIndex(t *testing.T, dbPath string) {
	t.Helper()
	clear := func() {
		neteaseLocalMu.Lock()
		neteaseLocalIndex, neteaseLocalReady, neteaseLocalScanned = nil, false, time.Time{}
		neteaseLocalDBMod, neteaseLocalDBSize = time.Time{}, 0
		neteaseLocalMu.Unlock()
	}
	clear()
	old := neteaseLocalDBOverride
	neteaseLocalDBOverride = dbPath
	t.Cleanup(func() {
		neteaseLocalDBOverride = old
		clear()
	})
}

var neteaseLocalTestTracks = []string{
	neteaseTestTrack("569213220", "像我这样的人", "毛不易", "平凡的一天", 207466),
	neteaseTestTrack("229779", "小城故事", "邓丽君", "岛国之情歌第六集", 155946),
	neteaseTestTrack("400000", "合唱曲", "歌手甲|歌手乙", "合辑", 200000),
}

func TestNeteaseLocalSongHit(t *testing.T) {
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, neteaseLocalTestTracks))
	s, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "平凡的一天", 207)
	if !ok {
		t.Fatal("应当命中本地曲库")
	}
	// ⚠️ dbTrack 里 id 是字符串 "569213220";解不成 int64 的话这里会是 0,
	// 上游会拿 id=0 去请求歌词、静默拿不到东西。
	if s.ID != 569213220 {
		t.Fatalf("songID 没解对: %d", s.ID)
	}
	if s.Name != "像我这样的人" || s.Album.Name != "平凡的一天" {
		t.Fatalf("元数据没透传: %+v", s)
	}
	// Duration 必须保持**毫秒**:上游 resolveNeteaseInfo 会再除以 1000。
	if s.Duration != 207466 {
		t.Fatalf("时长应为毫秒(207466),得到 %v", s.Duration)
	}
	if s.Album.ID != 900569213220 {
		t.Fatalf("albumID 没解对: %d", s.Album.ID)
	}
	if len(s.Artists) != 1 || s.Artists[0].Name != "毛不易" {
		t.Fatalf("歌手没透传: %+v", s.Artists)
	}
}

func TestNeteaseLocalSongMatchesAnyCreditedArtist(t *testing.T) {
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, neteaseLocalTestTracks))
	// 合唱曲:本地标签常只写其中一位,所以每个署名都要能查到 —— 这是实测 106 条多歌手
	// 曲目的处理方式,只按第一个歌手建键会让这些歌全查不到。
	for _, who := range []string{"歌手甲", "歌手乙"} {
		if _, ok := neteaseLocalSong(context.Background(), who, "合唱曲", "", 200); !ok {
			t.Fatalf("按 %q 应当命中合唱曲", who)
		}
	}
}

func TestNeteaseLocalSongRejectsDurationMismatch(t *testing.T) {
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, neteaseLocalTestTracks))
	// 库里 207s,播放器在放 300s 的另一版(差 31%)。宁可走搜索也不给错版本的 songID。
	if s, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "", 300); ok {
		t.Fatalf("时长差 >12%% 不该命中,却给了 %+v", s)
	}
	if _, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "", 0); !ok {
		t.Fatal("时长未知时应当命中")
	}
}

func TestNeteaseLocalSongPicksAmongSameNameVersions(t *testing.T) {
	tracks := []string{
		neteaseTestTrack("111", "晴天", "周杰伦", "演唱会", 281000),
		neteaseTestTrack("222", "晴天", "周杰伦", "叶惠美", 269000),
	}
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, tracks))
	s, ok := neteaseLocalSong(context.Background(), "周杰伦", "晴天", "", 269)
	if !ok || s.ID != 222 {
		t.Fatalf("应按时长挑中 222,得到 ok=%v id=%d", ok, s.ID)
	}
	s, ok = neteaseLocalSong(context.Background(), "周杰伦", "晴天", "演唱会", 269)
	if !ok || s.ID != 111 {
		t.Fatalf("应按专辑挑中 111,得到 ok=%v id=%d", ok, s.ID)
	}
}

func TestNeteaseLocalSongTraditionalAndCase(t *testing.T) {
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, neteaseLocalTestTracks))
	if _, ok := neteaseLocalSong(context.Background(), "鄧麗君", "小城故事", "", 156); !ok {
		t.Fatal("繁体歌手名应当命中")
	}
}

func TestNeteaseLocalSongMissingDB(t *testing.T) {
	resetNeteaseLocalIndex(t, filepath.Join(t.TempDir(), "没有这个库.sqlite3"))
	if _, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "", 207); ok {
		t.Fatal("库不存在时不该命中")
	}
}

func TestNeteaseLocalSongNeedsArtist(t *testing.T) {
	resetNeteaseLocalIndex(t, writeTestNeteaseDB(t, neteaseLocalTestTracks))
	if _, ok := neteaseLocalSong(context.Background(), "", "像我这样的人", "", 207); ok {
		t.Fatal("歌手名为空时不该命中")
	}
}

func TestNeteaseLocalFlexIDAcceptsBothForms(t *testing.T) {
	// 字符串形态(dbTrack 当前的写法)与数字形态都要吃得下 —— 别人的库换版改了形态,
	// 不该让整条路径静默失效。
	for _, raw := range []string{
		`{"id":"12345","name":"甲","duration":200000,"artists":[{"name":"某人"}],"album":{"id":"77","name":"专辑"}}`,
		`{"id":12345,"name":"甲","duration":200000,"artists":[{"name":"某人"}],"album":{"id":77,"name":"专辑"}}`,
	} {
		var tr neteaseLocalTrack
		if err := json.Unmarshal([]byte(raw), &tr); err != nil {
			t.Fatalf("解析失败 %s: %v", raw[:30], err)
		}
		if tr.ID != 12345 || tr.Album.ID != 77 {
			t.Fatalf("id 没解对: id=%d albumID=%d (%s)", tr.ID, tr.Album.ID, raw[:30])
		}
	}
}

func TestQueryNeteaseLocalTracksSkipsBadRowsAndEmptyResult(t *testing.T) {
	// 零行:sqlite3 -json 输出空串,不该报错。
	rows, err := queryNeteaseLocalTracks(context.Background(), writeTestNeteaseDB(t, nil))
	if err != nil || len(rows) != 0 {
		t.Fatalf("零行结果应当无错且为空: err=%v n=%d", err, len(rows))
	}
	// 混一条坏 JSON:跳过它,其余照读 —— 不能让一条脏记录带走整批。
	mixed := append([]string{"{这不是合法 JSON"}, neteaseLocalTestTracks...)
	rows, err = queryNeteaseLocalTracks(context.Background(), writeTestNeteaseDB(t, mixed))
	if err != nil {
		t.Fatalf("含坏行时不该整批失败: %v", err)
	}
	if len(rows) != len(neteaseLocalTestTracks) {
		t.Fatalf("应当读回 %d 条好记录,得到 %d", len(neteaseLocalTestTracks), len(rows))
	}
}
