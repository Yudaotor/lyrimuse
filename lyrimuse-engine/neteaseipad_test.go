package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// miniBarLastPlay 那一行的 json 列,照真实形状造:外层是字符串数组,第一个元素的 rawJsonString 是整条曲目 JSON。
func neteaseIPadTestRow(t *testing.T, song map[string]any, mediaType int) string {
	t.Helper()
	raw, err := json.Marshal(song)
	if err != nil {
		t.Fatal(err)
	}
	inner, _ := json.Marshal(map[string]any{"playSource": 0, "rawJsonString": string(raw), "mediaType": mediaType})
	outer, _ := json.Marshal([]string{string(inner)})
	return string(outer)
}

func neteaseIPadTestSong() map[string]any {
	return map[string]any{"id": "28387594", "name": "同桌的你", "ar": []map[string]string{{"id": "3273", "name": "胡夏"}},
		"al":       map[string]string{"id": "2785184", "name": "同桌的你", "picUrl": "http://p3.music.126.net/x.jpg"},
		"duration": 270000, "mark": 8192, "alias": []string{"电影《同桌的你》片尾主题曲"}}
}

func neteaseIPadTestProgram() map[string]any {
	return map[string]any{"id": "3403310000", "name": "卖酱香饼和当老师，哪个更有前途？",
		"ar": []map[string]string{{"name": "网易每日轻松一刻"}}, "al": map[string]string{"name": "网易每日轻松一刻"},
		"duration": 1219000, "clientDjProgram": map[string]any{"id": 3724125210, "name": "卖酱香饼和当老师，哪个更有前途？",
			"radio": map[string]any{"name": "网易每日轻松一刻"}}}
}

func TestNeteaseIPadItemFromRow(t *testing.T) {
	got, ok := neteaseIPadItemFromRow(neteaseIPadTestRow(t, neteaseIPadTestSong(), 4))
	want := neteaseIPadItem{ID: "28387594", Name: "同桌的你", Aliases: []string{"电影《同桌的你》片尾主题曲"}, Artists: []string{"胡夏"},
		AlbumID: "2785184", AlbumName: "同桌的你",
		AlbumPic: "http://p3.music.126.net/x.jpg", DurationMs: 270000, Mark: 8192}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("song = %+v, %v; want %+v", got, ok, want)
	}
	prog, ok := neteaseIPadItemFromRow(neteaseIPadTestRow(t, neteaseIPadTestProgram(), 1))
	if !ok || !prog.Program || prog.Name != "卖酱香饼和当老师，哪个更有前途？" || !reflect.DeepEqual(prog.Artists, []string{"网易每日轻松一刻"}) {
		t.Fatalf("program = %+v, %v", prog, ok)
	}
	empty := neteaseIPadTestSong()
	empty["clientDjProgram"] = map[string]any{}
	if it, ok := neteaseIPadItemFromRow(neteaseIPadTestRow(t, empty, 4)); !ok || it.Program {
		t.Fatalf("empty clientDjProgram = %+v, %v; want a song", it, ok)
	}
	for _, raw := range []string{``, `[]`, `["not json"]`, `[{"rawJsonString":""}]`, `["{\"rawJsonString\":\"{}\"}"]`} {
		if _, ok := neteaseIPadItemFromRow(raw); ok {
			t.Fatalf("%q parsed as an item", raw)
		}
	}
}

// neteaseIPadTestDB 在 path 建一份只有 miniBarLastPlay 表的库;row 为空串时不插行。
func neteaseIPadTestDB(t *testing.T, path, row string) {
	t.Helper()
	_ = os.Remove(path)
	script := "CREATE TABLE miniBarLastPlay ( id TEXT NOT NULL, json TEXT NOT NULL, createdTime TEXT NOT NULL, PRIMARY KEY(id));\n"
	if row != "" {
		script += "INSERT INTO miniBarLastPlay VALUES ('miniBarLastPlay', '" + strings.ReplaceAll(row, "'", "''") + "', '1');\n"
	}
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sqliteBatch(script))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("sqlite3: %v %s", err, out)
	}
}

func TestNeteaseIPadEpisodesPublisherRefresh(t *testing.T) {
	dir := t.TempDir()
	p := &neteaseIPadEpisodesPublisher{statePath: filepath.Join(dir, "episodes.json"), dbPath: filepath.Join(dir, "kv.sqlite3")}
	touch := func(mod time.Time) {
		t.Helper()
		if err := os.Chtimes(p.dbPath, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	base := time.Now().Add(-time.Hour)

	if p.refresh() {
		t.Fatal("no database yet, want unknown")
	}
	neteaseIPadTestDB(t, p.dbPath, neteaseIPadTestRow(t, neteaseIPadTestProgram(), 1))
	touch(base)
	if !p.refresh() {
		t.Fatal("a program row, want readable")
	}
	s, ok := readTestNeteaseEpisodes(t, p.statePath)
	if !ok || !reflect.DeepEqual(s.Episodes, []neteaseEpisode{{Title: "卖酱香饼和当老师，哪个更有前途？", Host: "网易每日轻松一刻"}}) {
		t.Fatalf("published = %+v, %v", s, ok)
	}

	// 库没变:不重读、不重写(拿一个哨兵内容验)。
	if err := os.WriteFile(p.statePath, []byte("sentinel"), 0o644); err != nil {
		t.Fatal(err)
	}
	p.refresh()
	if raw, _ := os.ReadFile(p.statePath); string(raw) != "sentinel" {
		t.Fatalf("unchanged database rewrote the list: %q", raw)
	}

	neteaseIPadTestDB(t, p.dbPath, neteaseIPadTestRow(t, neteaseIPadTestSong(), 4))
	touch(base.Add(time.Minute))
	if !p.refresh() {
		t.Fatal("a song row, want readable")
	}
	if s, ok := readTestNeteaseEpisodes(t, p.statePath); !ok || s.Episodes == nil || len(s.Episodes) != 0 {
		t.Fatalf("song = %+v, %v; want an empty list (readable, no episode)", s, ok)
	}

	neteaseIPadTestDB(t, p.dbPath, "")
	touch(base.Add(2 * time.Minute))
	if p.refresh() {
		t.Fatal("no row, want unknown")
	}
	if _, ok := readTestNeteaseEpisodes(t, p.statePath); ok {
		t.Fatal("no row left the list in place")
	}

	neteaseIPadTestDB(t, p.dbPath, neteaseIPadTestRow(t, neteaseIPadTestProgram(), 1))
	touch(base.Add(3 * time.Minute))
	p.refresh()
	if err := os.Remove(p.dbPath); err != nil {
		t.Fatal(err)
	}
	if p.refresh() {
		t.Fatal("database gone, want unknown")
	}
	if _, ok := readTestNeteaseEpisodes(t, p.statePath); ok {
		t.Fatal("database gone but the list is still there")
	}
}

// 客户端开着时库是 WAL 模式、连接一直不关,改写只落在 -wal 里;监听要跟着 -wal 的写入刷新名单。
func TestNeteaseIPadEpisodesWatcherFollowsWALWrites(t *testing.T) {
	dir := t.TempDir()
	p := &neteaseIPadEpisodesPublisher{statePath: filepath.Join(dir, "episodes.json"), dbPath: filepath.Join(dir, "kv.sqlite3")}
	neteaseIPadTestDB(t, p.dbPath, neteaseIPadTestRow(t, neteaseIPadTestSong(), 4))

	client := exec.Command("/usr/bin/sqlite3", p.dbPath)
	stdin, err := client.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	client.Stdout, client.Stderr = io.Discard, io.Discard
	if err := client.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		stdin.Close()
		_ = client.Wait()
	}()
	send := func(sql string) {
		t.Helper()
		if _, err := io.WriteString(stdin, sql+"\n"); err != nil {
			t.Fatal(err)
		}
	}
	send("PRAGMA journal_mode=WAL;")
	waitWAL := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(p.dbPath + "-wal"); err == nil {
			break
		}
		if time.Now().After(waitWAL) {
			t.Fatal("sqlite3 did not switch the test database to WAL")
		}
		send("SELECT count(*) FROM miniBarLastPlay;")
		time.Sleep(5 * time.Millisecond)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		runNeteaseIPadEpisodesWatcher(ctx, p, time.Hour)
	}()
	defer func() {
		cancel()
		<-done
	}()
	waitFor := func(what string, n int) {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for {
			if s, ok := readTestNeteaseEpisodes(t, p.statePath); ok && len(s.Episodes) == n {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("watcher did not publish %s", what)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	waitFor("the empty list on start", 0)

	row := neteaseIPadTestRow(t, neteaseIPadTestProgram(), 1)
	send("UPDATE miniBarLastPlay SET json = '" + strings.ReplaceAll(row, "'", "''") + "';")
	waitFor("the episode written into the WAL", 1)

	cancel()
	<-done
	if _, ok := readTestNeteaseEpisodes(t, p.statePath); ok {
		t.Fatal("stopped watcher left the list behind")
	}
}

func TestNeteasePlayingSongFallsBackToIPad(t *testing.T) {
	dir := t.TempDir()
	prevKV, prevQueue := neteaseIPadKVOverride, neteaseUpcomingOverride
	neteaseIPadKVOverride, neteaseUpcomingOverride = filepath.Join(dir, "kv.sqlite3"), filepath.Join(dir, "playingList")
	defer func() { neteaseIPadKVOverride, neteaseUpcomingOverride = prevKV, prevQueue }()

	neteaseIPadTestDB(t, neteaseIPadKVOverride, neteaseIPadTestRow(t, neteaseIPadTestSong(), 4))
	if id, album := neteasePlayingSong("胡夏", "同桌的你", 270); id != "28387594" || album != "2785184" {
		t.Fatalf("playing song = %q, %q; want the iPad app's ids", id, album)
	}
	if id, _ := neteasePlayingSong("胡夏", "同桌的你 (电影《同桌的你》片尾主题曲)", 270); id != "28387594" {
		t.Fatalf("title with the alias = %q; want the iPad app's id", id)
	}
	if id, _ := neteasePlayingSong("胡夏", "同桌的你 (Live)", 270); id != "" {
		t.Fatalf("title with another suffix = %q; want no match", id)
	}
	tr, ok := neteasePlayingTrack("胡夏", "同桌的你", "同桌的你", 270)
	if !ok || tr.ID != 28387594 || tr.Album.ID != 2785184 || tr.Album.Name != "同桌的你" || tr.Duration != 270000 ||
		len(tr.Artists) != 1 || tr.Artists[0].Name != "胡夏" {
		t.Fatalf("playing track = %+v, %v", tr, ok)
	}
	for _, c := range []struct {
		name, artist, title, album string
		secs                       float64
	}{
		{"other title", "胡夏", "别的歌", "", 270},
		{"other artist", "老狼", "同桌的你", "", 270},
		{"duration off", "胡夏", "同桌的你", "", 200},
		{"album off", "胡夏", "同桌的你", "龙凤金歌榜", 270},
	} {
		if _, ok := neteasePlayingTrack(c.artist, c.title, c.album, c.secs); ok {
			t.Errorf("%s: matched the iPad app's song", c.name)
		}
	}

	// 改写库要让缓存失效:换成节目后不再当成这首歌。
	neteaseIPadTestDB(t, neteaseIPadKVOverride, neteaseIPadTestRow(t, neteaseIPadTestProgram(), 1))
	later := time.Now().Add(time.Minute)
	if err := os.Chtimes(neteaseIPadKVOverride, later, later); err != nil {
		t.Fatal(err)
	}
	if id, _ := neteasePlayingSong("胡夏", "同桌的你", 270); id != "" {
		t.Fatalf("after the row changed to a program the old song still gave id %q", id)
	}
	if id, _ := neteasePlayingSong("网易每日轻松一刻", "卖酱香饼和当老师，哪个更有前途？", 1219); id != "" {
		t.Fatalf("a program gave song id %q", id)
	}
}
