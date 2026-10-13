package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// testSodaBareRecord 拼一条 2.9 起的缓存记录:info 只有曲目 id 这几项,没有 mediaDetail(跟真实库同形)。
func testSodaBareRecord(id string, at uint32) []byte {
	info := mpDef('A', []string{"trackId", "urls", "spade", "quality", "bitrate", "isPreview"},
		mpStr(id), mpArr(), mpStr("k"), mpStr("medium"), mpU32(128000), []byte{0xc2})
	return mpDef('@', []string{"resourceId", "info", "headers", "chunkId", "previousAccessTime", "size"},
		mpStr("v10ad_P_highest"), info, []byte{0x80}, mpStr("00f51931-ee55-4cd3-b8d5-9afed45365d7"), mpU32(at), mpU32(257628))
}

// withSodaTrackMeta 换一份曲目信息表、清空后台状态,问的那一步换成 fetch;running 为 true 时排上的 id 只进待问、不开后台。
func withSodaTrackMeta(t *testing.T, m map[string]sodaTrackMeta, fetch func(context.Context, string) (sodaTrackMeta, error), running bool) {
	t.Helper()
	sodaTrackMetaMu.Lock()
	cache, path, dirty := sodaTrackMetaCache, sodaTrackMetaPath, sodaTrackMetaDirty
	pending, queued, failed := sodaTrackMetaPending, sodaTrackMetaQueued, sodaTrackMetaFailed
	run, paused := sodaTrackMetaRunning, sodaTrackMetaPaused
	if m == nil {
		m = map[string]sodaTrackMeta{}
	}
	sodaTrackMetaCache, sodaTrackMetaPath, sodaTrackMetaDirty = m, "", false
	sodaTrackMetaPending, sodaTrackMetaQueued, sodaTrackMetaFailed = nil, map[string]bool{}, map[string]time.Time{}
	sodaTrackMetaRunning, sodaTrackMetaPaused = running, time.Time{}
	sodaTrackMetaMu.Unlock()
	oldFetch := sodaTrackMetaFetch
	sodaTrackMetaFetch = fetch
	t.Cleanup(func() {
		sodaTrackMetaMu.Lock()
		sodaTrackMetaCache, sodaTrackMetaPath, sodaTrackMetaDirty = cache, path, dirty
		sodaTrackMetaPending, sodaTrackMetaQueued, sodaTrackMetaFailed = pending, queued, failed
		sodaTrackMetaRunning, sodaTrackMetaPaused = run, paused
		sodaTrackMetaMu.Unlock()
		sodaTrackMetaFetch = oldFetch
	})
}

// withSodaPreloadFile 把缓存库指到写着 raw 的临时文件,预载索引的缓存清掉。
func withSodaPreloadFile(t *testing.T, raw []byte) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "entries.db")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	old := sodaPreloadOverride
	sodaPreloadOverride = path
	resetIndex := func() {
		sodaPreloadIndexMu.Lock()
		sodaPreloadIndexMod, sodaPreloadIndexSize, sodaPreloadIndexTrack = time.Time{}, 0, nil
		sodaPreloadIndexMu.Unlock()
	}
	resetIndex()
	t.Cleanup(func() {
		sodaPreloadOverride = old
		resetIndex()
	})
}

func testSodaMeta(name string, artists []string, album string, durMs int64) sodaTrackMeta {
	m := sodaTrackMeta{Name: name, Album: sodaTrackMetaRef{ID: "66", Name: album}, DurationMs: durMs}
	for i, a := range artists {
		m.Artists = append(m.Artists, sodaTrackMetaRef{ID: string(rune('5'+i)) + "5", Name: a})
	}
	return m
}

func noSodaFetch(context.Context, string) (sodaTrackMeta, error) {
	return sodaTrackMeta{}, errors.New("not expected")
}

// 2.9 起的记录只有曲目 id:解出 id 与建立时刻,歌名等留空;老版本的记录照旧整条解出来。
func TestParseSodaPreloadsBareRecord(t *testing.T) {
	raw := append(testSodaBareRecord("7065822749403154433", 1790165600),
		testSodaPreloadRecord("7168858636298258444", "一分之二", []string{"HUSH", "孙盛希"}, "出没地带", 282801, 1790165601)...)
	got := parseSodaPreloads(raw)
	if len(got) != 2 {
		t.Fatalf("该解出两条记录,得到 %+v", got)
	}
	if got[0].id != "7065822749403154433" || got[0].at != 1790165600 || got[0].upcoming != (upcomingTrack{}) {
		t.Errorf("只有 id 的记录: %+v", got[0])
	}
	if got[1].upcoming.title != "一分之二" || got[1].upcoming.artist != "HUSH/孙盛希" {
		t.Errorf("老版本记录照旧: %+v", got[1])
	}
}

// 只有 id 的记录按问来的曲目信息补齐;还没问到的这一次不出现,按建立时刻新的先排进待问,不重复排。
func TestSodaPreloadsWithMeta(t *testing.T) {
	m := testSodaMeta("惯坏", []string{"", "泳儿", "某人"}, "私人珍藏", 246987)
	m.PreviewStartMs, m.PreviewDurMs = 87936, 30001
	withSodaTrackMeta(t, map[string]sodaTrackMeta{"1": m}, noSodaFetch, true)
	raw := append(append(testSodaBareRecord("1", 100), testSodaBareRecord("2", 105)...), testSodaBareRecord("3", 101)...)
	got := sodaPreloadsWithMeta(raw)
	want := sodaPreloadedTrack{id: "1", at: 100, albumID: "66", artistID: "65", previewStartMs: 87936, previewDurMs: 30001, fullMs: 246987,
		upcoming: upcomingTrack{artist: "泳儿/某人", title: "惯坏", album: "私人珍藏", duration: 246.987}}
	if len(got) != 1 || got[0] != want {
		t.Fatalf("got %+v", got)
	}
	sodaPreloadsWithMeta(raw)
	sodaTrackMetaMu.Lock()
	pending := slices.Clone(sodaTrackMetaPending)
	sodaTrackMetaMu.Unlock()
	if !slices.Equal(pending, []string{"2", "3"}) {
		t.Errorf("没问到的按建立时刻新的先排、不重复排: %v", pending)
	}
}

// 后台一个一个问:问到的进表、落盘、代号加一;正在问的 id 再来不重复排;连着失败三次停手,剩下的退回去,停手期间不再开问;
// 没问到的 id 一段时间内不再排;问到之后给存量条目补一次歌曲页。
func TestSodaTrackMetaWorker(t *testing.T) {
	calls := []string{}
	withSodaTrackMeta(t, nil, func(_ context.Context, id string) (sodaTrackMeta, error) {
		calls = append(calls, id)
		requestSodaTrackMeta([]string{id})
		if id == "7065822749403154433" {
			return testSodaMeta("惯坏", []string{"泳儿"}, "私人珍藏", 246987), nil
		}
		return sodaTrackMeta{}, errSodaTrackMetaMissing
	}, true)
	withSodaPreloadFile(t, testSodaBareRecord("7065822749403154433", uint32(time.Now().Unix()-60)))
	withEnrichCache(t, map[string]enrichEntry{"泳儿|惯坏|私人珍藏": {Players: []string{sodaMusicBundleID}, DurationSecs: 247}})
	path := filepath.Join(t.TempDir(), "soda-track-cache.json")
	sodaTrackMetaMu.Lock()
	sodaTrackMetaPath = path
	sodaTrackMetaPending = []string{"b", "7065822749403154433", "c", "d", "e", "f"}
	for _, id := range sodaTrackMetaPending {
		sodaTrackMetaQueued[id] = true
	}
	sodaTrackMetaMu.Unlock()
	gen := sodaTrackMetaGen.Load()

	sodaTrackMetaWorker()

	if !slices.Equal(calls, []string{"b", "7065822749403154433", "c", "d", "e"}) {
		t.Errorf("问到一个就重新数,连着失败三次才停: %v", calls)
	}
	sodaTrackMetaMu.Lock()
	_, have := sodaTrackMetaCache["7065822749403154433"]
	failed := len(sodaTrackMetaFailed)
	left, queued, running, paused := len(sodaTrackMetaPending), len(sodaTrackMetaQueued), sodaTrackMetaRunning, sodaTrackMetaPaused
	sodaTrackMetaMu.Unlock()
	if !have || failed != 4 || left != 0 || queued != 0 || running || !paused.After(time.Now()) {
		t.Errorf("have=%v failed=%d left=%d queued=%d running=%v paused=%v", have, failed, left, queued, running, paused)
	}
	if sodaTrackMetaGen.Load() != gen+1 {
		t.Error("问到一批代号加一")
	}
	if data, err := os.ReadFile(path); err != nil || !strings.Contains(string(data), "7065822749403154433") {
		t.Errorf("落盘: %v %s", err, data)
	}
	enrichMu.Lock()
	e := enrichCache["泳儿|惯坏|私人珍藏"]
	enrichMu.Unlock()
	if e.SodaURL != sodaTrackPageURL("7065822749403154433") || e.SodaAlbumID != "66" || e.SodaArtistID != "55" {
		t.Errorf("问到之后给存量条目补歌曲页: %+v", e)
	}

	requestSodaTrackMeta([]string{"b", "f"})
	sodaTrackMetaMu.Lock()
	pending, running := slices.Clone(sodaTrackMetaPending), sodaTrackMetaRunning
	sodaTrackMetaMu.Unlock()
	if !slices.Equal(pending, []string{"f"}) || running {
		t.Errorf("刚失败的不再排,停手期间不开问: pending=%v running=%v", pending, running)
	}
}

// 正在问的 id 又被排一次(换歌那一拍预载索引重解时常见):不重复问。
func TestSodaTrackMetaNoDuplicateFetch(t *testing.T) {
	calls := 0
	withSodaTrackMeta(t, nil, func(_ context.Context, id string) (sodaTrackMeta, error) {
		calls++
		requestSodaTrackMeta([]string{id})
		return testSodaMeta("惯坏", []string{"泳儿"}, "私人珍藏", 246987), nil
	}, true)
	sodaTrackMetaMu.Lock()
	sodaTrackMetaPending, sodaTrackMetaQueued["1"] = []string{"1"}, true
	sodaTrackMetaMu.Unlock()
	sodaTrackMetaWorker()
	if calls != 1 {
		t.Errorf("问了 %d 次", calls)
	}
}

// seo_track 应答里取曲目信息:试听段 start 为 0 时省略;不是这个 id、没有歌名、解不开的都按失败算。
func TestSodaTrackMetaFromSeo(t *testing.T) {
	raw := []byte(`{"seo_track":{"track":{"id":"7","name":"红豆","duration":236000,"artists":[{"id":"a1","name":"方大同","simple_display_name":"x"}],` +
		`"album":{"id":"b1","name":"Timeless 可啦思刻","release_date":1},"preview":{"duration":30001,"vid":"v"}},"lyric":{}}}`)
	got, err := sodaTrackMetaFromSeo(raw, "7")
	want := sodaTrackMeta{Name: "红豆", Artists: []sodaTrackMetaRef{{ID: "a1", Name: "方大同"}}, Album: sodaTrackMetaRef{ID: "b1", Name: "Timeless 可啦思刻"},
		DurationMs: 236000, PreviewDurMs: 30001}
	if err != nil || !slices.Equal(got.Artists, want.Artists) || got.Name != want.Name || got.Album != want.Album ||
		got.DurationMs != want.DurationMs || got.PreviewStartMs != 0 || got.PreviewDurMs != 30001 {
		t.Errorf("got %+v err %v", got, err)
	}
	for _, c := range []struct{ raw, id string }{
		{string(raw), "8"},
		{`{"seo_track":{"track":{"id":"7","name":" "}}}`, "7"},
		{`{"seo_track":{}}`, "7"},
	} {
		if _, err := sodaTrackMetaFromSeo([]byte(c.raw), c.id); !errors.Is(err, errSodaTrackMetaMissing) {
			t.Errorf("%s (%s): %v", c.raw, c.id, err)
		}
	}
	if _, err := sodaTrackMetaFromSeo([]byte(`{`), "7"); err == nil {
		t.Error("解不开的算失败")
	}
}

// 预载索引按曲目信息的代号失效:问到之后同一份库文件重解,补上的那条出现。
func TestSodaPreloadIndexRefreshesOnNewMeta(t *testing.T) {
	withSodaTrackMeta(t, nil, noSodaFetch, true)
	withSodaPreloadFile(t, testSodaBareRecord("1", 100))
	if got := sodaPreloadIndex(); len(got) != 0 {
		t.Fatalf("还没问到: %+v", got)
	}
	sodaTrackMetaMu.Lock()
	sodaTrackMetaCache["1"] = testSodaMeta("惯坏", []string{"泳儿"}, "私人珍藏", 246987)
	sodaTrackMetaMu.Unlock()
	if got := sodaPreloadIndex(); len(got) != 0 {
		t.Fatalf("代号没变不重解: %+v", got)
	}
	sodaTrackMetaGen.Add(1)
	if got := sodaPreloadIndex(); len(got) != 1 || got[0].upcoming.title != "惯坏" {
		t.Fatalf("代号变了重解: %+v", got)
	}
}

// 补存量歌曲页:只补在汽水上放过、还没有歌曲页的;报过原样写法的按它查;时长对不上、没在汽水上放过、已有歌曲页的不动。
func TestBackfillSodaPagesFromClientCache(t *testing.T) {
	odd := testSodaMeta("一分之二", []string{"HUSH", "孙盛希"}, "出没地带", 282801)
	odd.Album.ID, odd.Artists[0].ID = "专辑", "x-1"
	withSodaTrackMeta(t, map[string]sodaTrackMeta{
		"7065822749403154433": testSodaMeta("惯坏", []string{"泳儿"}, "私人珍藏", 246987),
		"7168858636298258444": odd,
	}, noSodaFetch, true)
	at := uint32(time.Now().Unix() - 60)
	withSodaPreloadFile(t, append(testSodaBareRecord("7065822749403154433", at), testSodaBareRecord("7168858636298258444", at)...))
	soda := []string{sodaMusicBundleID}
	withEnrichCache(t, map[string]enrichEntry{
		"泳儿|惯坏|私人珍藏":      {Players: soda, DurationSecs: 247},
		"孙盛希|一分之二|出没地带":   {Players: soda, DurationSecs: 282.8, Reported: map[string]reportedName{sodaMusicBundleID: {Title: "一分之二", Artist: "HUSH, 孙盛希", Album: "出没地带"}}},
		"泳儿|惯坏|私人珍藏 ~ 已有": {Players: soda, DurationSecs: 247, SodaURL: sodaTrackPageURL("1")},
		"泳儿|惯坏|私人珍藏 ~ 别家": {Players: []string{appleMusicBundleID}, DurationSecs: 247},
		"泳儿|惯坏|私人珍藏 ~ 长":  {Players: soda, DurationSecs: 300},
	})
	if n := backfillSodaPagesFromClientCache(); n != 2 {
		t.Errorf("补了 %d 条", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["泳儿|惯坏|私人珍藏"]; e.SodaURL != sodaTrackPageURL("7065822749403154433") || e.SodaAlbumID != "66" || e.SodaArtistID != "55" {
		t.Errorf("补上歌曲页、专辑、歌手: %+v", e)
	}
	if e := enrichCache["孙盛希|一分之二|出没地带"]; e.SodaURL != sodaTrackPageURL("7168858636298258444") || e.SodaAlbumID != "" || e.SodaArtistID != "" {
		t.Errorf("按报过的原样写法查;形状不对的专辑、歌手 id 不记: %+v", e)
	}
	if enrichCache["泳儿|惯坏|私人珍藏 ~ 已有"].SodaURL != sodaTrackPageURL("1") || enrichCache["泳儿|惯坏|私人珍藏 ~ 别家"].SodaURL != "" ||
		enrichCache["泳儿|惯坏|私人珍藏 ~ 长"].SodaURL != "" {
		t.Error("已有的、没在汽水上放过的、时长对不上的不动")
	}
}

// 超过上限时丢掉问得最早的。
func TestPruneSodaTrackMeta(t *testing.T) {
	m := map[string]sodaTrackMeta{}
	for i := 0; i <= sodaTrackMetaMax; i++ {
		m[strconv.Itoa(i)] = sodaTrackMeta{Name: "x", At: int64(i + 1)}
	}
	withSodaTrackMeta(t, m, noSodaFetch, true)
	sodaTrackMetaMu.Lock()
	pruneSodaTrackMetaLocked()
	_, oldest := sodaTrackMetaCache["0"]
	_, newest := sodaTrackMetaCache[strconv.Itoa(sodaTrackMetaMax)]
	n := len(sodaTrackMetaCache)
	sodaTrackMetaMu.Unlock()
	if n != sodaTrackMetaMax || oldest || !newest {
		t.Errorf("n=%d oldest=%v newest=%v", n, oldest, newest)
	}
}

// 2.9 起的记录补上曲目信息之后,点播的「即将播放」和同专辑兜底照样取得到。
func TestSodaBareRecordsFeedUpcomingAndAlbum(t *testing.T) {
	withSodaTrackMeta(t, map[string]sodaTrackMeta{
		"1": testSodaMeta("爱在", []string{"方大同"}, "未来", 243733),
		"2": testSodaMeta("惯坏", []string{"泳儿"}, "私人珍藏", 246987),
	}, noSodaFetch, true)
	at := uint32(time.Now().Unix() - 60)
	withSodaPreloadFile(t, append(testSodaBareRecord("1", at), testSodaBareRecord("2", at+1)...))
	got, ok := upcomingFromQueue("方大同", "爱在", "未来", sodaMusicBundleID, 0, 5)
	if !ok || len(got) != 1 || got[0].title != "惯坏" || got[0].artist != "泳儿" {
		t.Errorf("即将播放: ok=%v %+v", ok, got)
	}
	if id := sodaCurrentAlbumID("方大同", "爱在", "未来"); id != "66" {
		t.Errorf("同专辑兜底: %q", id)
	}
}

// 接线:问来的曲目信息有自己的缓存文件;引擎起来后的存量补记见 TestPlayerCatalogSweepWiring。
func TestSodaTrackMetaWiring(t *testing.T) {
	read := func(name string) string {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if !strings.Contains(read("main.go"), `loadSodaTrackMeta(filepath.Join(filepath.Dir(*cfgPath), clientName+"-soda-track-cache.json"))`) {
		t.Error("main 载入缓存文件")
	}
}
