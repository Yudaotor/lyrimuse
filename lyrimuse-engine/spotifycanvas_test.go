package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 合成的 Canvas 缓存,形状照搬实测:key 是 `!xmeta#cache#` + 01 30 + 曲目 uri,值是 Any 包着的
// spotify.canvaz.cache.EntityCanvazResponse.Canvaz(1 id、2 地址、4 类型、5 曲目 uri)。

const (
	testCanvasA = "https://canvaz.scdn.co/upload/licensor/7JGwF0zhX9oItt9901OvB5/video/3c536bc079704182813b8f636922489c.cnvs.mp4"
	testCanvasB = "https://canvaz.scdn.co/upload/artist/00FQb4jTyendYWaN8pK0wa/video/23fa20bde1e84c6f9c3668c1d9c3c837.cnvs.mp4"
)

func testCanvasValue(url string, kind uint64, trackURI string) []byte {
	v := pbMsg(pbStr(1, "3c536bc079704182813b8f636922489c"), pbStr(2, url))
	if kind != 0 {
		v = append(v, pbVarint(4, kind)...)
	}
	v = append(v, pbStr(5, trackURI)...)
	return pbMsg(pbVarint(1, 16), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.canvaz.cache.EntityCanvazResponse.Canvaz"), pbBytes(2, v))))
}

type testCanvasRec struct{ url, isrc string }

// writeTestSpotifyCanvasCache:每个账号一份 曲目 id → (Canvas 地址,ISRC);地址空的只写曲目元数据。
func writeTestSpotifyCanvasCache(t *testing.T, accounts ...map[string]testCanvasRec) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Users")
	for i, recs := range accounts {
		dir := filepath.Join(root, "acct"+string(rune('a'+i))+"-user", "primary.ldb")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		var entries []testLDBEntry
		seq := uint64(1)
		for id, r := range recs {
			if r.url != "" {
				entries = append(entries, testLDBEntry{key: string(spotifyXmetaKey(spotifyCanvasKind, id)), seq: seq,
					value: string(testCanvasValue(r.url, 3, "spotify:track:"+id))})
				seq++
			}
			entries = append(entries, testLDBEntry{key: string(spotifyXmetaKey(spotifyTrackKind, id)), seq: seq, value: string(testSpotifyTrackWithISRC(r.isrc))})
			seq++
		}
		testWriteTable(t, filepath.Join(dir, "000123.ldb"), entries, 2, true)
	}
	return root
}

func resetSpotifyCanvasIndex(t *testing.T) {
	t.Helper()
	reset := func() {
		spotifyCanvasMu.Lock()
		spotifyCanvasCached, spotifyCanvasStamp, spotifyCanvasCheckAt = nil, "", time.Time{}
		spotifyCanvasMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

func TestSpotifyCanvasURL(t *testing.T) {
	uri := "spotify:track:" + testSpotifyID1
	if got := spotifyCanvasURL(testCanvasValue(testCanvasA, 3, uri), uri); got != testCanvasA {
		t.Errorf("循环视频: %q", got)
	}
	for _, kind := range []uint64{1, 2} {
		if spotifyCanvasURL(testCanvasValue(testCanvasA, kind, uri), uri) != testCanvasA {
			t.Errorf("类型 %d 是视频,该收", kind)
		}
	}
	for name, v := range map[string][]byte{
		"图片(类型 0 不写)": testCanvasValue(testCanvasA, 0, uri),
		"GIF":         testCanvasValue(testCanvasA, 4, uri),
		"记的是别的曲目":     testCanvasValue(testCanvasA, 3, "spotify:track:"+testSpotifyID2),
		"不是 mp4":      testCanvasValue("https://canvaz.scdn.co/upload/artist/x/video/a.jpg", 3, uri),
		"别的主机":        testCanvasValue("https://example.com/upload/a.cnvs.mp4", 3, uri),
		"不是 Canvas":   testSpotifyTrackWithISRC("USRC17607839"),
	} {
		if got := spotifyCanvasURL(v, uri); got != "" {
			t.Errorf("%s: %q", name, got)
		}
	}
}

func TestSpotifyXmetaKeyTrackURI(t *testing.T) {
	uri := "spotify:track:" + testSpotifyID1
	if got := spotifyXmetaKeyTrackURI(spotifyXmetaKey(spotifyCanvasKind, testSpotifyID1)); got != uri {
		t.Errorf("got %q", got)
	}
	k := spotifyXmetaKey(spotifyCanvasKind, testSpotifyID1)
	for name, bad := range map[string][]byte{"截短": k[:len(k)-3], "没有结尾 #": k[:len(k)-1], "太短": []byte("!xmeta#cache#")} {
		if got := spotifyXmetaKeyTrackURI(bad); got != "" {
			t.Errorf("%s: %q", name, got)
		}
	}
}

func TestSpotifyCanvasLookup(t *testing.T) {
	root := writeTestSpotifyCanvasCache(t,
		map[string]testCanvasRec{testSpotifyID1: {testCanvasA, "USRC17607839"}, testSpotifyID3: {"", "GBARL9300135"}},
		map[string]testCanvasRec{testSpotifyID1: {testCanvasB, "USRC17607839"}, testSpotifyID2: {testCanvasB, "QZES71982312"}})
	resetSpotifyISRCCache(t, root)
	idx := buildSpotifyCanvasIndex(spotifyISRCLedgerDirs(root))
	levels := func(code, level string) enrichEntry {
		return enrichEntry{ISRCs: []string{code}, ISRCLevels: map[string]string{code: level}}
	}
	for _, c := range []struct {
		name string
		e    enrichEntry
		want string
	}{
		{"自己的曲目 id(多账号先扫到的算)", enrichEntry{SpotifyTrackID: testSpotifyID1}, testCanvasA},
		{"只在第二个账号里有", enrichEntry{SpotifyTrackID: testSpotifyID2}, testCanvasB},
		{"播放器报的 ISRC", levels("USRC17607839", isrcLevelPlayer), testCanvasA},
		{"核实过的 ISRC", levels("QZES71982312", isrcLevelVerified), testCanvasB},
		{"搜出来的 ISRC 不用", levels("USRC17607839", isrcLevelSearched), ""},
		{"没记级别的 ISRC 不用", enrichEntry{ISRCs: []string{"USRC17607839"}}, ""},
		{"这段录音在缓存里没有 Canvas", levels("GBARL9300135", isrcLevelPlayer), ""},
		{"自己的 id 没有就按 ISRC", func() enrichEntry {
			e := levels("QZES71982312", isrcLevelPlayer)
			e.SpotifyTrackID = testSpotifyID3
			return e
		}(), testCanvasB},
	} {
		if got := idx.canvasFor(c.e); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	e := enrichEntry{ISRCs: []string{"QZES71982312", "USRC17607839"},
		ISRCLevels: map[string]string{"QZES71982312": isrcLevelVerified, "USRC17607839": isrcLevelPlayer}}
	if got := idx.canvasFor(e); got != testCanvasA {
		t.Errorf("播放器报的 ISRC 排在核实过的前面: %q", got)
	}
}

func TestSpotifyCanvasIndexRefresh(t *testing.T) {
	resetSpotifyCanvasIndex(t)
	root := writeTestSpotifyCanvasCache(t, map[string]testCanvasRec{testSpotifyID1: {testCanvasA, ""}})
	resetSpotifyISRCCache(t, root)
	now := time.Unix(1_800_000_000, 0)
	first := spotifyCanvasIndexNow(now)
	if first == nil || first.byTrack[testSpotifyID1] != testCanvasA {
		t.Fatalf("first = %+v", first)
	}
	// 库变了:隔不到 spotifyCanvasRefresh 照用旧的,过了才重建。
	dir := filepath.Join(root, "accta-user", "primary.ldb")
	testWriteTable(t, filepath.Join(dir, "000124.ldb"), []testLDBEntry{{key: string(spotifyXmetaKey(spotifyCanvasKind, testSpotifyID2)), seq: 9,
		value: string(testCanvasValue(testCanvasB, 3, "spotify:track:"+testSpotifyID2))}}, 2, true)
	if got := spotifyCanvasIndexNow(now.Add(spotifyCanvasRefresh / 2)); got != first {
		t.Error("间隔内不重看库")
	}
	again := spotifyCanvasIndexNow(now.Add(spotifyCanvasRefresh))
	if again == first || again.byTrack[testSpotifyID2] != testCanvasB {
		t.Errorf("库变了要重建: %+v", again)
	}
	if got := spotifyCanvasIndexNow(now.Add(3 * spotifyCanvasRefresh)); got != again {
		t.Error("库没变不重建")
	}
	resetSpotifyISRCCache(t, filepath.Join(t.TempDir(), "nothing"))
	spotifyCanvasMu.Lock()
	spotifyCanvasCached, spotifyCanvasCheckAt = nil, time.Time{}
	spotifyCanvasMu.Unlock()
	if got := spotifyCanvasIndexNow(now); got == nil || len(got.byTrack) != 0 {
		t.Errorf("没有缓存目录时是空索引: %+v", got)
	}
}

func TestSpotifyCanvasJobLocked(t *testing.T) {
	saved := spotifyCanvasChecked
	t.Cleanup(func() { spotifyCanvasChecked = saved })
	spotifyCanvasChecked = map[string]time.Time{}
	now := time.Unix(1_800_000_000, 0)
	withID := enrichEntry{SpotifyTrackID: testSpotifyID1}
	if spotifyCanvasJobLocked("k", enrichEntry{}, now) {
		t.Error("没有曲目 id 也没有可信 ISRC 不查")
	}
	if spotifyCanvasJobLocked("k", enrichEntry{SpotifyTrackID: testSpotifyID1, SpotifyCanvasURL: testCanvasA}, now) {
		t.Error("已经有了不查")
	}
	if !spotifyCanvasJobLocked("k", withID, now) {
		t.Error("有曲目 id 该查")
	}
	if spotifyCanvasJobLocked("k", withID, now.Add(spotifyCanvasRefresh-time.Second)) {
		t.Error("隔不到 spotifyCanvasRefresh 不再查")
	}
	if !spotifyCanvasJobLocked("k", withID, now.Add(spotifyCanvasRefresh)) {
		t.Error("隔够了再查一次(Spotify 开播后才拉 Canvas)")
	}
	trusted := enrichEntry{ISRCs: []string{"USRC17607839"}, ISRCLevels: map[string]string{"USRC17607839": isrcLevelVerified}}
	if !spotifyCanvasJobLocked("k2", trusted, now) {
		t.Error("只有可信 ISRC 也查")
	}
}

func TestRunSpotifyCanvasJob(t *testing.T) {
	withTempDecisionCache(t)
	resetSpotifyCanvasIndex(t)
	root := writeTestSpotifyCanvasCache(t, map[string]testCanvasRec{testSpotifyID1: {testCanvasA, "USRC17607839"}})
	resetSpotifyISRCCache(t, root)
	savedKeys := enrichPendingKeys
	savedNow, savedSave := enrichPendingNow, enrichSaveNow
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPendingKeys = savedKeys
		enrichMu.Unlock()
		enrichPendingNow, enrichSaveNow = savedNow, savedSave
	})
	enrichPendingNow, enrichSaveNow = func() {}, func() {}
	for _, c := range []struct {
		name string
		e    enrichEntry
		want string
	}{
		{"按 ISRC 查到写回", enrichEntry{ISRCs: []string{"USRC17607839"}, ISRCLevels: map[string]string{"USRC17607839": isrcLevelPlayer}}, testCanvasA},
		{"查不到不写", enrichEntry{SpotifyTrackID: testSpotifyID2}, ""},
		{"已有的不换", enrichEntry{SpotifyTrackID: testSpotifyID1, SpotifyCanvasURL: testCanvasB}, testCanvasB},
	} {
		const key = "歌手|歌名|专辑"
		enrichMu.Lock()
		enrichPendingKeys = map[string]uint64{}
		enrichCache[key] = c.e
		enrichMu.Unlock()
		runSpotifyCanvasJob(key)
		enrichMu.Lock()
		got := enrichCache[key].SpotifyCanvasURL
		_, pending := enrichPendingKeys[key]
		enrichMu.Unlock()
		if got != c.want || pending != (c.want != "" && c.e.SpotifyCanvasURL == "") {
			t.Errorf("%s: %q 进待落盘 %v", c.name, got, pending)
		}
	}
	loser := enrichEntry{SpotifyCanvasURL: testCanvasA}
	if got := mergePeripheralInto(enrichEntry{}, loser); got.SpotifyCanvasURL != testCanvasA {
		t.Errorf("合并时胜者没有就带过来: %q", got.SpotifyCanvasURL)
	}
	if got := mergePeripheralInto(enrichEntry{SpotifyCanvasURL: testCanvasB}, loser); got.SpotifyCanvasURL != testCanvasB {
		t.Errorf("胜者有的不换: %q", got.SpotifyCanvasURL)
	}
}
