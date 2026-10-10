package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// 第二次建表用上一份实体表做种子:实体 id 不变;两首并成一首时留建立更早的 id,另一个记重定向。
func TestSongEntityTableKeepsIDs(t *testing.T) {
	mk := func(link bool) []songVariant {
		b := enrichEntry{DurationSecs: 200.2}
		if link {
			b.ISRCs = []string{"USAAA1100001"}
		}
		vs := []songVariant{
			songTestVariant("A|Song|One", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100001"}}, nil),
			songTestVariant("A|Song|Two", enrichEntry{DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}}, nil),
			songTestVariant("B|Other|Three", b, nil),
		}
		return vs
	}
	t0 := time.Unix(1_000_000, 0)
	b1, _ := songTestBuild(t, mk(false), nil)
	first := b1.table(nil, nil, t0)
	if len(first.Songs) != 2 {
		t.Fatalf("应当两首: %+v", first.Songs)
	}
	b2, _ := songTestBuild(t, mk(false), nil)
	second := b2.table(first, nil, t0.Add(time.Hour))
	ids := func(tb *songEntityTableFile) []string {
		var out []string
		for id := range tb.Songs {
			out = append(out, id)
		}
		slices.Sort(out)
		return out
	}
	if !slices.Equal(ids(first), ids(second)) {
		t.Fatalf("重建之后 id 要延续: %v → %v", ids(first), ids(second))
	}
	for id, s := range second.Songs {
		if s.Created != first.Songs[id].Created {
			t.Errorf("%s 的建立时刻要沿用旧表的", id)
		}
	}

	// 把第三条的建立时刻改得更早,再让它跟前两条并成一首:留它的 id,另一个重定向过去。
	var songID, otherID string
	for id, s := range second.Songs {
		if slices.Contains(s.Variants, "B|Other|Three") {
			otherID = id
			s.Created = 1
			second.Songs[id] = s
		} else {
			songID = id
		}
	}
	b3, _ := songTestBuild(t, mk(true), nil)
	third := b3.table(second, nil, t0.Add(2*time.Hour))
	if len(third.Songs) != 1 {
		t.Fatalf("三条共用一个 ISRC 应当并成一首: %+v", third.Songs)
	}
	if _, ok := third.Songs[songID]; !ok || third.Redirects[otherID] != songID {
		// 共有写法多的那个旧 id 留下(前两条的),另一个重定向过去。
		t.Errorf("合并后留共有写法最多的 %s、%s 重定向过去: songs=%v redirects=%v", songID, otherID, ids(third), third.Redirects)
	}
}

// 用户判断文件:拆开记录读进来,坏掉的文件当没有;拆开过的两条不并。
func TestSongEntityUserSplits(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "user.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"user_splits":[["A|Song|One","A|Song|Two"],["x"]],"future_field":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	splits := readSongEntityUserSplits(path)
	if len(splits) != 1 || !splits[songPairKey("A|Song|Two", "A|Song|One")] {
		t.Fatalf("拆开记录: %v", splits)
	}
	vs := []songVariant{
		songTestVariant("A|Song|One", enrichEntry{DurationSecs: 200, ISRCs: []string{"USAAA1100001"}}, nil),
		songTestVariant("A|Song|Two", enrichEntry{DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}}, nil),
	}
	if b, of := songTestBuild(t, vs, splits); songTestSame(of, "A|Song|One", "A|Song|Two") || len(b.vetoed) == 0 || b.vetoed[0].reason != "user_split" {
		t.Errorf("用户拆开过的两条不并: %+v", b.vetoed)
	}
	if err := os.WriteFile(path, []byte(`{not json`), 0o600); err != nil {
		t.Fatal(err)
	}
	if readSongEntityUserSplits(path) != nil {
		t.Error("坏掉的用户判断文件当没有")
	}
}

// 实体表版本对不上、坏掉都当没有上一份(下一次重建全部新开 id)。
func TestReadSongEntityTableRejectsOtherVersions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.json")
	for _, body := range []string{`{"version":99,"songs":{}}`, `{broken`} {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if readSongEntityTable(path) != nil {
			t.Errorf("%s 应当当成没有", body)
		}
	}
}

// App 的诊断包按文件名取实体报告:两边的文件名必须一致。
func TestSongEntityReportNameMatchesDiagnosticsExporter(t *testing.T) {
	raw, err := os.ReadFile("../lyrimuse/Sources/lyrimuse/Settings/DiagnosticsExporter.swift")
	if err != nil {
		t.Fatalf("读不到 App 的诊断导出(路径变了就跟着改,别删这个测试): %v", err)
	}
	if want := `"` + filepath.Base(songEntityReportPath()) + `"`; !strings.Contains(string(raw), want) {
		t.Fatalf("App 的诊断导出里找不到 %s", want)
	}
}

// 条目上的 `song` 是 id 种子:建完写回条目并落盘;实体表丢了照样接上;跟旧表不一致时以 `song` 为准。
func TestSongEntitySongFieldSeedsIDs(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	savedPath, savedDirty := enrichPath, enrichDirty
	t.Cleanup(func() { enrichPath, enrichDirty = savedPath, savedDirty })
	enrichPath = filepath.Join(dir, clientName+"-enrich-cache.json")
	withEnrichCache(t, map[string]enrichEntry{
		"A|Song|One":    {DurationSecs: 200, ISRCs: []string{"USAAA1100001"}},
		"A|Song|Two":    {DurationSecs: 200.1, ISRCs: []string{"USAAA1100001"}},
		"B|Other|Three": {DurationSecs: 180},
	})
	song := func(k string) string {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return enrichCache[k].Song
	}
	t0 := time.Unix(1_000_000, 0)

	rebuildSongEntityTable(t0)
	one, other := song("A|Song|One"), song("B|Other|Three")
	if one == "" || one != song("A|Song|Two") || other == "" || other == one {
		t.Fatalf("song 没按实体写回: %q %q %q", one, song("A|Song|Two"), other)
	}
	if data, err := os.ReadFile(enrichPath); err != nil || !strings.Contains(string(data), `"song":"`+one+`"`) {
		t.Fatalf("写回的 song 要落盘: %v", err)
	}
	table := readSongEntityTable(songEntityTablePath())
	if table == nil || !slices.Contains(table.Songs[one].Variants, "A|Song|One") {
		t.Fatalf("实体表跟条目上的 song 对不上: %+v", table)
	}

	if err := os.Remove(songEntityTablePath()); err != nil {
		t.Fatal(err)
	}
	rebuildSongEntityTable(t0.Add(time.Hour))
	if song("A|Song|One") != one || song("B|Other|Three") != other {
		t.Errorf("实体表丢了之后 id 要按 song 接上: %q %q", song("A|Song|One"), song("B|Other|Three"))
	}
	if table := readSongEntityTable(songEntityTablePath()); table == nil || len(table.Songs[one].Variants) != 2 {
		t.Errorf("重建的实体表要沿用 song 里的 id: %+v", table)
	}

	enrichMu.Lock()
	for _, k := range []string{"A|Song|One", "A|Song|Two"} {
		e := enrichCache[k]
		e.Song = "s_00000000abcd"
		enrichCache[k] = e
	}
	enrichMu.Unlock()
	rebuildSongEntityTable(t0.Add(2 * time.Hour))
	table = readSongEntityTable(songEntityTablePath())
	if table == nil || len(table.Songs["s_00000000abcd"].Variants) != 2 {
		t.Errorf("条目上的 song 跟旧表不一致时以 song 为准: %+v", table)
	}
	if _, ok := table.Songs[one]; ok || table.Redirects[one] != "s_00000000abcd" {
		t.Errorf("旧表里那个 id 没分到实体,要重定向到现在的 id: %+v", table.Redirects)
	}
}

// writeBackSongEntityIDs 只改 id 或共享组变了的、缓存里还在的写法。
func TestWriteBackSongEntityIDs(t *testing.T) {
	savedDirty := enrichDirty
	t.Cleanup(func() { enrichDirty = savedDirty })
	enrichDirty = false
	withEnrichCache(t, map[string]enrichEntry{
		"A|Song|One": {Song: "s_000000000001"},
		"A|Song|Two": {},
	})
	n := writeBackSongEntityIDs(&songEntityTableFile{Songs: map[string]songEntityRecord{
		"s_000000000001": {Variants: []string{"A|Song|One", "A|Song|Two", "A|Song|Gone"}},
	}})
	if n != 1 || enrichCache["A|Song|Two"].Song != "s_000000000001" || !enrichDirty {
		t.Errorf("n=%d song=%q dirty=%v", n, enrichCache["A|Song|Two"].Song, enrichDirty)
	}
	if _, ok := enrichCache["A|Song|Gone"]; ok {
		t.Error("缓存里没有的写法不该被建出来")
	}
	enrichDirty = false
	if n := writeBackSongEntityIDs(&songEntityTableFile{Songs: map[string]songEntityRecord{
		"s_000000000001": {Variants: []string{"A|Song|One", "A|Song|Two"}},
	}}); n != 0 || enrichDirty {
		t.Errorf("没变的不改、不标脏: n=%d dirty=%v", n, enrichDirty)
	}
	n = writeBackSongEntityIDs(&songEntityTableFile{Songs: map[string]songEntityRecord{
		"s_000000000001": {Variants: []string{"A|Song|One", "A|Song|Two"}, Share: []int{0, 1}},
	}})
	if n != 1 || enrichCache["A|Song|One"].SongShare != 0 || enrichCache["A|Song|Two"].SongShare != 1 {
		t.Errorf("共享组编号要跟实体表 share 一致: n=%d one=%d two=%d", n, enrichCache["A|Song|One"].SongShare, enrichCache["A|Song|Two"].SongShare)
	}
}
