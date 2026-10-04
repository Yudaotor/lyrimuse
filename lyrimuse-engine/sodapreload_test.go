package main

import (
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 按 msgpackr 的写法手拼字节:结构第一次出现带字段名(d4 72 <编号> + 字段名数组),之后单字节引用。
func mpStr(s string) []byte {
	if len(s) < 32 {
		return append([]byte{0xa0 | byte(len(s))}, s...)
	}
	return append([]byte{0xd9, byte(len(s))}, s...)
}

func mpU32(v uint32) []byte {
	b := []byte{0xce, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(b[1:], v)
	return b
}

func mpArr(items ...[]byte) []byte {
	out := []byte{0x90 | byte(len(items))}
	for _, it := range items {
		out = append(out, it...)
	}
	return out
}

func mpDef(id byte, keys []string, vals ...[]byte) []byte {
	ks := make([][]byte, 0, len(keys))
	for _, k := range keys {
		ks = append(ks, mpStr(k))
	}
	out := append([]byte{0xd4, 0x72, id}, mpArr(ks...)...)
	for _, v := range vals {
		out = append(out, v...)
	}
	return out
}

func mpRef(id byte, vals ...[]byte) []byte {
	out := []byte{id}
	for _, v := range vals {
		out = append(out, v...)
	}
	return out
}

// testSodaPreloadRecord 拼一条跟真实库同形的音频缓存记录;歌手第二位用结构引用,跟真实数据一样。
func testSodaPreloadRecord(id, name string, artists []string, album string, durMs, at uint32) []byte {
	artistVals := make([][]byte, 0, len(artists))
	for i, a := range artists {
		if i == 0 {
			artistVals = append(artistVals, mpDef('D', []string{"id", "name"}, mpStr("a"), mpStr(a)))
		} else {
			artistVals = append(artistVals, mpRef('D', mpStr("a"), mpStr(a)))
		}
	}
	playable := mpDef('C', []string{"id", "name", "artists", "album", "duration"},
		mpStr(id), mpStr(name), mpArr(artistVals...), mpDef('E', []string{"id", "name"}, mpStr("b"), mpStr(album)), mpU32(durMs))
	detail := mpDef('B', []string{"video_model", "playable"}, []byte{0xc0}, playable)
	info := mpDef('A', []string{"trackId", "urls", "mediaDetail"}, mpStr(id), mpArr(), detail)
	return mpDef('@', []string{"resourceId", "info", "headers", "chunkId", "previousAccessTime", "size"},
		mpStr("v10ad_P_highest"), info, []byte{0x80}, mpStr("00f51931-ee55-4cd3-b8d5-9afed45365d7"), mpU32(at), mpU32(257628))
}

func TestParseSodaPreloadsReadsRecordsAmongJunk(t *testing.T) {
	var raw []byte
	raw = append(raw, 0, 0, 0xd4, 0x72, 0x40, 0xff) // 解不动的起点:跳过
	raw = append(raw, testSodaPreloadRecord("7065822749403154433", "惯坏", []string{"泳儿"}, "私人珍藏", 246987, 1790165600)...)
	raw = append(raw, 0, 0, 0, 0)
	raw = append(raw, testSodaPreloadRecord("7168858636298258444", "一分之二", []string{"HUSH", "孙盛希"}, "出没地带", 282801, 1790165600)...)
	got := parseSodaPreloads(raw)
	if len(got) != 2 {
		t.Fatalf("该解出两条记录,得到 %+v", got)
	}
	if got[0].id != "7065822749403154433" || got[0].at != 1790165600 || got[0].upcoming.title != "惯坏" || got[0].upcoming.album != "私人珍藏" || got[0].upcoming.duration != 246.987 {
		t.Errorf("第一条字段不对: %+v", got[0])
	}
	if got[1].upcoming.artist != "HUSH/孙盛希" {
		t.Errorf("多位歌手要用 / 连起来(第二位走结构引用),得到 %q", got[1].upcoming.artist)
	}
}

func TestParseSodaPreloadsRejectsMismatchedPlayable(t *testing.T) {
	// playable 的 id 跟 trackId 对不上(结构变了、拿到别的对象):不认。
	info := mpDef('A', []string{"trackId", "urls", "mediaDetail"}, mpStr("1"), mpArr(),
		mpDef('B', []string{"video_model", "playable"}, []byte{0xc0},
			mpDef('C', []string{"id", "name", "artists", "album", "duration"}, mpStr("2"), mpStr("别的"), mpArr(), []byte{0xc0}, mpU32(1))))
	mismatched := mpDef('@', []string{"resourceId", "info", "headers", "chunkId", "previousAccessTime", "size"},
		mpStr("v"), info, []byte{0x80}, mpStr("x"), mpU32(1790165600), mpU32(1))
	if got := parseSodaPreloads(mismatched); len(got) != 0 {
		t.Errorf("playable 的 id 跟 trackId 对不上时不该认: %+v", got)
	}
}

func TestPickSodaPreloadedTakesLatestAndOrdersByPreload(t *testing.T) {
	now := time.Unix(1790166000, 0)
	tr := func(id string, at int64, title string) sodaPreloadedTrack {
		return sodaPreloadedTrack{id: id, at: at, upcoming: upcomingTrack{artist: "歌手", title: title}}
	}
	all := []sodaPreloadedTrack{
		tr("old", now.Add(-2*time.Hour).Unix(), "两小时前的"),
		tr("a", now.Unix()-600, "早就播过的"),
		tr("b", now.Unix()-300, "第一首"),
		tr("b", now.Unix()-100, "第一首"), // 同一首的另一段音质:以最早那段为准
		tr("c", now.Unix()-240, "第二首"),
		tr("cur", now.Unix()-200, "正在播"),
		tr("d", now.Unix()-120, "第三首"),
	}
	got, ok := pickSodaPreloaded(all, "歌手", "正在播", 3, now)
	if !ok || len(got) != 3 || got[0].title != "第一首" || got[1].title != "第二首" || got[2].title != "第三首" {
		t.Fatalf("该取最近预载的 3 首(不含正在播的),按预载先后排,得到 %+v", got)
	}
	if _, ok := pickSodaPreloaded(all[:1], "歌手", "正在播", 5, now); ok {
		t.Error("窗口外的缓存不该算")
	}
}

func TestSodaUpcomingFallsBackToPreload(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "entries.db")
	at := uint32(time.Now().Unix() - 60)
	raw := append(testSodaPreloadRecord("1", "爱在", []string{"方大同"}, "未来", 243733, at),
		testSodaPreloadRecord("2", "惯坏", []string{"泳儿"}, "私人珍藏", 246987, at+1)...)
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	old := sodaPreloadOverride
	sodaPreloadOverride = path
	t.Cleanup(func() { sodaPreloadOverride = old })

	// QueueCache 读不到(TestMain 指向不存在的文件),退到预载那层;正在播的这首自己不算。
	got, ok := upcomingFromQueue("方大同", "爱在", "未来", sodaMusicBundleID, 0, 5)
	if !ok || len(got) != 1 || got[0].title != "惯坏" || got[0].artist != "泳儿" {
		t.Fatalf("该从预载缓存取到惯坏,得到 ok=%v %+v", ok, got)
	}
}

// testSodaPreviewRecord 拼一条带试听段(preview{start,duration},毫秒)的缓存记录。
func testSodaPreviewRecord(id, name, artist string, durMs, pvStart, pvDur uint32) []byte {
	playable := mpDef('C', []string{"id", "name", "artists", "album", "duration", "preview"},
		mpStr(id), mpStr(name), mpArr(mpDef('D', []string{"id", "name"}, mpStr("a"), mpStr(artist))),
		mpDef('E', []string{"id", "name"}, mpStr("b"), mpStr("专辑")), mpU32(durMs),
		mpDef('F', []string{"start", "duration"}, mpU32(pvStart), mpU32(pvDur)))
	detail := mpDef('B', []string{"video_model", "playable"}, []byte{0xc0}, playable)
	info := mpDef('A', []string{"trackId", "urls", "mediaDetail"}, mpStr(id), mpArr(), detail)
	return mpDef('@', []string{"resourceId", "info", "headers", "chunkId", "previousAccessTime", "size"},
		mpStr("v_P_medium"), info, []byte{0x80}, mpStr("x"), mpU32(uint32(time.Now().Unix())), mpU32(1))
}

func TestSodaPreviewForReadsPreloadCacheWithoutSearch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "entries.db")
	if err := os.WriteFile(path, testSodaPreviewRecord("1", "Say a lil something", "萧敬腾", 209000, 43584, 29977), 0o644); err != nil {
		t.Fatal(err)
	}
	old := sodaPreloadOverride
	sodaPreloadOverride = path
	oldSearch := sodaPreviewSearchFn
	searched := false
	sodaPreviewSearchFn = func(ctx context.Context, artist, title, album string, mr float64) (sodaPreview, bool) {
		searched = true
		return sodaPreview{}, false
	}
	t.Cleanup(func() {
		sodaPreloadOverride = old
		sodaPreviewSearchFn = oldSearch
		sodaPreloadIndexMu.Lock()
		sodaPreloadIndexMod, sodaPreloadIndexSize, sodaPreloadIndexTrack = time.Time{}, 0, nil
		sodaPreloadIndexMu.Unlock()
		sodaPreviewMu.Lock()
		sodaPreviewCache = map[string]sodaPreviewCacheEntry{}
		sodaPreviewInflight = map[string]bool{}
		sodaPreviewMu.Unlock()
	})

	// 点播的歌不在队列缓存里(TestMain 指向不存在的文件),换歌那一拍就从音频缓存库同步拿到,不去搜。
	p, ok := sodaPreviewFor("萧敬腾", "Say a lil something", "王妃", 30, nil)
	if !ok || p.StartSecs != 43.584 || p.DurSecs != 29.977 || p.FullSecs != 209 {
		t.Fatalf("该从缓存库同步拿到试听段,得到 ok=%v %+v", ok, p)
	}
	if searched {
		t.Error("缓存库命中了就不该再发搜索")
	}
	// 播放器报的是整首(会员 / 限免):对不上试听段,不换算。
	if _, ok := sodaPreloadPreview("萧敬腾", "Say a lil something", 209); ok {
		t.Error("报的是整首时不该当成试听")
	}
}
