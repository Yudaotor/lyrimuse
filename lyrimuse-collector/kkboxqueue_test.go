package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
	"unicode/utf16"
)

const testKKBOXOrigin = "_http://localhost:55680\x00\x01"

func testKKBOXPrefKey(account, name string) string {
	return testKKBOXOrigin + "wp:pref:" + account + ":" + name
}

// testUTF16Value 按 Chromium Local Storage 的格式编码:首字节 0,其后 UTF-16LE。
func testUTF16Value(s string) string {
	u := utf16.Encode([]rune(s))
	b := []byte{0}
	for _, c := range u {
		b = binary.LittleEndian.AppendUint16(b, c)
	}
	return string(b)
}

// testChromiumCacheEntry 造一个 simple cache 条目:24 字节头 + key + gzip 正文 + EOF 记录 + 一段响应头。
func testChromiumCacheEntry(t *testing.T, dir, name, rawURL, body string) {
	t.Helper()
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	zw.Close()
	key := "1/0/" + rawURL
	var b []byte
	b = binary.LittleEndian.AppendUint64(b, chromiumSimpleCacheMagic)
	b = binary.LittleEndian.AppendUint32(b, 5)
	b = binary.LittleEndian.AppendUint32(b, uint32(len(key)))
	b = binary.LittleEndian.AppendUint32(b, 0)
	b = binary.LittleEndian.AppendUint32(b, 0)
	b = append(b, key...)
	b = append(b, gz.Bytes()...)
	b = binary.LittleEndian.AppendUint64(b, chromiumSimpleCacheEOFMagic)
	b = append(b, make([]byte, 12)...)
	b = append(b, "HTTP/1.1 200\x00content-encoding: gzip\x00"...)
	if err := os.WriteFile(filepath.Join(dir, name), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

const testKKBOXSongList = `{"status":"OK","type":"TracksSet","data":{"id":"LIST==","tracks":[
 {"id":"T1","name":"Love Story","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"Fearless - International Version"},"duration_ms":233871},
 {"id":"T2","name":"End Game","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[{"name":"Ed Sheeran"},{"name":"Future"}]},"album":{"name":"reputation"},"duration_ms":244827},
 {"id":"T3","name":"willow","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"evermore"},"duration_ms":214706},
 {"id":"T4","name":"Speak Now","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"Speak Now - Deluxe Package"},"duration_ms":240773}
]}}`

const testKKBOXAlbum = `{"status":"OK","type":"Album","data":{"id":"ALB","name":"The Life of a Showgirl: The Encore","artist":{"name":"Taylor Swift (泰勒絲)"},"tracks":[
 {"id":"A1","name":"The Fate of Ophelia"},{"id":"A2","name":"Elizabeth Taylor"},{"id":"A3","name":"Opalite"}
]}}`

// withTestKKBOX 把两处路径指到临时目录,写一份 Local Storage(上下文 + 随机开关)和两份接口缓存。
func withTestKKBOX(t *testing.T, context string, shuffle bool) {
	t.Helper()
	savedDelays := kkboxUpcomingRetryDelays
	kkboxUpcomingRetryDelays = []time.Duration{0, 0, 0}
	t.Cleanup(func() { kkboxUpcomingRetryDelays = savedDelays })
	ls, cache := t.TempDir(), t.TempDir()
	savedLS, savedCache := kkboxLocalStorageOverride, kkboxCacheDirOverride
	kkboxLocalStorageOverride, kkboxCacheDirOverride = ls, cache
	t.Cleanup(func() { kkboxLocalStorageOverride, kkboxCacheDirOverride = savedLS, savedCache })
	shuffleText := "\x01false"
	if shuffle {
		shuffleText = "\x01true"
	}
	testWriteLog(t, filepath.Join(ls, "000003.log"), [][]testLDBEntry{
		{{key: testKKBOXPrefKey("@default", "now_playing"), seq: 2, value: testUTF16Value(`"kkbox:void"`)}},
		{{key: testKKBOXPrefKey("me@example.com", "now_playing"), seq: 10, value: testUTF16Value(`"` + context + `"`)}},
		{{key: testKKBOXPrefKey("me@example.com", "is_shuffle"), seq: 11, value: shuffleText}},
	})
	testChromiumCacheEntry(t, cache, "aaaa_0", "https://api-webapps.kkbox.com.tw/v2/tracks-set/LIST==?terr=tw&lang=tc", testKKBOXSongList)
	testChromiumCacheEntry(t, cache, "bbbb_0", "https://api-webapps.kkbox.com.tw/v2/albums/ALB?terr=tw&lang=tc", testKKBOXAlbum)
	testChromiumCacheEntry(t, cache, "cccc_0", "https://api-webapps.kkbox.com.tw/v2/tracks/T1?terr=tw", `{"data":{}}`)
}

func titlesOf(ts []upcomingTrack) []string {
	var out []string
	for _, t := range ts {
		out = append(out, t.title)
	}
	return out
}

func TestKKBOXUpcomingSequential(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	got, ok := kkboxUpcoming("Taylor Swift", "Love Story", 5)
	if !ok {
		t.Fatal("顺序播放应该读得到后面几首")
	}
	if want := []string{"End Game", "willow", "Speak Now"}; !reflect.DeepEqual(titlesOf(got), want) {
		t.Errorf("got %v want %v", titlesOf(got), want)
	}
	// 歌手名照 KKBOX 的规则拼:main + featured,", " 连起来;专辑、时长照接口。
	if got[0].artist != "Taylor Swift, Ed Sheeran, Future" || got[0].album != "reputation" || got[0].duration != 244.827 {
		t.Errorf("第一首: %+v", got[0])
	}
}

func TestKKBOXUpcomingShuffle(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:20:0?track=T2", true)
	got, ok := kkboxUpcoming("Taylor Swift, Ed Sheeran, Future", "End Game", 5)
	if !ok {
		t.Fatal("随机播放也要交一批")
	}
	// 列表不超过 30 首:除当前这首以外整份交出去,从当前往后、到末尾接回开头。
	if want := []string{"willow", "Speak Now", "Love Story"}; !reflect.DeepEqual(titlesOf(got), want) {
		t.Errorf("got %v want %v", titlesOf(got), want)
	}
}

// 专辑接口里的曲目没有 artist / artist_roles,批量详情也不在缓存里:歌手退回专辑歌手,专辑名用专辑的。
func TestKKBOXUpcomingAlbumContext(t *testing.T) {
	withTestKKBOX(t, "kkbox:album:ALB:0:0?track=A1", false)
	got, ok := kkboxUpcoming("Taylor Swift (泰勒絲)", "The Fate of Ophelia", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("got %v ok=%v", got, ok)
	}
	if got[0].artist != "Taylor Swift (泰勒絲)" || got[0].album != "The Life of a Showgirl: The Encore" || got[0].title != "Elizabeth Taylor" {
		t.Errorf("专辑曲目: %+v", got[0])
	}
}

// 专辑曲目的歌手在 KKBOX 开播专辑时另拉的批量详情里:roles 可以跟专辑歌手不是一个写法(实测周杰倫的单曲,专辑歌手
// 「周杰倫 (Jay Chou)」,播放器报「周杰倫」)。一张专辑分两批拉、有一首两批里都没有的,那一首退回专辑歌手。
func TestKKBOXUpcomingAlbumUsesBatchDetails(t *testing.T) {
	withTestKKBOX(t, "kkbox:album:ALB:0:0?track=A1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "dddd_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=A1,A2&plain=0&terr=tw",
		`{"data":[{"id":"A1","name":"The Fate of Ophelia","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"The Life of a Showgirl"},"duration_ms":226063},
		{"id":"A2","name":"Elizabeth Taylor","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[{"name":"Guest"}]},"album":{"name":"The Life of a Showgirl"},"duration_ms":208274}]}`)
	testChromiumCacheEntry(t, cache, "eeee_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=Z9&plain=0&terr=tw",
		`{"data":[{"id":"Z9","name":"Unrelated","artist_roles":{"main_artists":[{"name":"Nobody"}]}}]}`)
	got, ok := kkboxUpcoming("Taylor Swift", "The Fate of Ophelia", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("got %+v ok=%v", got, ok)
	}
	if got[0].artist != "Taylor Swift, Guest" || got[0].album != "The Life of a Showgirl" || got[0].duration != 208.274 {
		t.Errorf("有详情的那首照详情: %+v", got[0])
	}
	if got[1].artist != "Taylor Swift (泰勒絲)" || got[1].title != "Opalite" {
		t.Errorf("没有详情的那首退回专辑歌手: %+v", got[1])
	}
	// 播放器报的是详情里的写法:报专辑歌手的写法反而对不上。
	if _, ok := kkboxUpcoming("Taylor Swift (泰勒絲)", "The Fate of Ophelia", 5); ok {
		t.Error("当前这首的歌手按详情比")
	}
}

// 歌单:上下文串里叫 online-playlist,只有一段序号;曲目表在 /v2/playlists/<id>,每首自带歌手。
func TestKKBOXUpcomingOnlinePlaylist(t *testing.T) {
	withTestKKBOX(t, "kkbox:online-playlist:PL1:22?track=P1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "hhhh_0", "https://api-webapps.kkbox.com.tw/v2/playlists/PL1?terr=tw",
		`{"data":{"id":"PL1","title":"五月天 (Mayday) 歷年精選","tracks":[
		{"id":"P1","name":"志明與春嬌","artist":{"name":"五月天 (Mayday)"},"artist_roles":{"main_artists":[{"name":"五月天 (Mayday)"}],"featured_artists":[]},"album":{"name":"五月天第一張創作專輯"},"duration_ms":271000},
		{"id":"P2","name":"瘋狂世界","artist":{"name":"五月天 (Mayday)"},"artist_roles":{"main_artists":[{"name":"五月天 (Mayday)"}],"featured_artists":[]},"album":{"name":"五月天第一張創作專輯"},"duration_ms":330000}]}}`)
	got, ok := kkboxUpcoming("五月天 (Mayday)", "志明與春嬌", 5)
	if want := []string{"瘋狂世界"}; !ok || !reflect.DeepEqual(titlesOf(got), want) {
		t.Fatalf("got %v ok=%v", titlesOf(got), ok)
	}
}

// 专辑 / 歌单放完后自动续播:上下文是 song-list,但曲目表在 related-tracks 下面,按 data.id 认。
func TestKKBOXUpcomingAutoplayRelatedTracks(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:AUTO==:3:2?track=R2", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "ffff_0", "https://api-webapps.kkbox.com.tw/v2/related-tracks/SEED1?terr=tw",
		`{"data":{"id":"OTHER==","tracks":[{"id":"X1","name":"Elsewhere","artist_roles":{"main_artists":[{"name":"Someone"}]}}]}}`)
	testChromiumCacheEntry(t, cache, "gggg_0", "https://api-webapps.kkbox.com.tw/v2/related-tracks/SEED2?terr=tw",
		`{"data":{"id":"AUTO==","title":"最偉大的作品 合輯","tracks":[
		{"id":"R1","name":"最偉大的作品","artist":{"name":"周杰倫 (Jay Chou)"},"artist_roles":{"main_artists":[{"name":"周杰倫"}],"featured_artists":[]},"album":{"name":"最偉大的作品"}},
		{"id":"R2","name":"我想要你","artist":{"name":"蕭秉治Xiao Bing Chih"},"artist_roles":{"main_artists":[{"name":"蕭秉治Xiao Bing Chih"}],"featured_artists":[]},"album":{"name":"凡人"}},
		{"id":"R3","name":"自言自語","artist":{"name":"范曉萱 (Mavis Fan)"},"artist_roles":{"main_artists":[{"name":"范曉萱 (Mavis Fan)"}],"featured_artists":[]},"album":{"name":"范曉萱純摯年代黃金精選集"}}]}}`)
	got, ok := kkboxUpcoming("蕭秉治Xiao Bing Chih", "我想要你", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("got %+v ok=%v", got, ok)
	}
	if got[0].artist != "范曉萱 (Mavis Fan)" || got[0].title != "自言自語" || got[0].album != "范曉萱純摯年代黃金精選集" {
		t.Errorf("续播的下一首: %+v", got[0])
	}
}

func TestKKBOXUpcomingRefusesWhenUnsure(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	if _, ok := kkboxUpcoming("Taylor Swift", "Another Song", 5); ok {
		t.Error("当前这首对不上播放器报的(上下文停在上一次):退回")
	}
	if _, ok := kkboxUpcoming("Taylor Swift (泰勒絲)", "Love Story", 5); ok {
		t.Error("歌手名拼法对不上:照这个拼法预解析是白解析,退回")
	}
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T4", false)
	if _, ok := kkboxUpcoming("Taylor Swift", "Speak Now", 5); ok {
		t.Error("已经是最后一首:后面没有,退回同专辑预取")
	}
	withTestKKBOX(t, "kkbox:radio:R1:0:0?track=T1", false)
	if _, ok := kkboxUpcoming("Taylor Swift", "Love Story", 5); ok {
		t.Error("没有曲目表的上下文类型:退回")
	}
	withTestKKBOX(t, "kkbox:online-playlist:MISSING:0?track=T1", false)
	if _, ok := kkboxUpcoming("Taylor Swift", "Not Cached Anywhere", 5); ok {
		t.Error("上下文那份列表不在缓存里、最近的列表里也没有这首:退回")
	}
	if got, ok := kkboxUpcoming("Taylor Swift", "Love Story", 5); !ok || len(got) == 0 {
		t.Error("上下文那份列表不在缓存里,但最近缓存的列表里有这首:照那份")
	}
}

// 上下文里记的曲目还停在上一首(Chromium 的 Local Storage 落盘晚):同一份列表里按歌名找到这首,不用等。
func TestKKBOXUpcomingStaleTrackPointer(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	retries := 0
	kkboxUpcomingBeforeRetry = func() { retries++ }
	t.Cleanup(func() { kkboxUpcomingBeforeRetry = nil })
	got, ok := kkboxUpcoming("Taylor Swift", "willow", 5)
	if want := []string{"Speak Now"}; !ok || retries != 0 || !reflect.DeepEqual(titlesOf(got), want) {
		t.Errorf("got %v ok=%v retries=%d", titlesOf(got), ok, retries)
	}
}

// 换了列表、上下文还停在上一份(Chromium 的 Local Storage 攒一会儿才落盘):最近写进缓存的那份列表里有这首,直接用。
func TestKKBOXUpcomingSwitchedListBeforeContextLands(t *testing.T) {
	withTestKKBOX(t, "kkbox:album:ALB:0:0?track=A1", false)
	retries := 0
	kkboxUpcomingBeforeRetry = func() { retries++ }
	t.Cleanup(func() { kkboxUpcomingBeforeRetry = nil })
	got, ok := kkboxUpcoming("Taylor Swift", "willow", 5)
	if want := []string{"Speak Now"}; !ok || retries != 0 || !reflect.DeepEqual(titlesOf(got), want) {
		t.Errorf("got %v ok=%v retries=%d", titlesOf(got), ok, retries)
	}
}

func TestIsKKBOXTrackListPath(t *testing.T) {
	for path, want := range map[string]bool{
		"/v2/albums/ALB": true, "/v2/playlists/PL": true, "/v2/tracks-set/L==": true, "/v2/related-tracks/T1": true,
		"/v2/artists/A1/albums": false, "/v2/tracks/T1": false, "/v2/tracks/": false, "/v2/albums/": false,
	} {
		if got := isKKBOXTrackListPath(path); got != want {
			t.Errorf("%s: got %v want %v", path, got, want)
		}
	}
}

// 新列表的曲目表还没写进缓存、上下文也没落盘:隔一会儿重读,写进来了就认。
func TestKKBOXUpcomingRetriesUntilContextLands(t *testing.T) {
	withTestKKBOX(t, "kkbox:album:ALB:0:0?track=A1", false)
	if err := os.Remove(filepath.Join(kkboxCacheDirOverride, "aaaa_0")); err != nil {
		t.Fatal(err)
	}
	retries := 0
	kkboxUpcomingBeforeRetry = func() {
		retries++
		if retries == 2 {
			testChromiumCacheEntry(t, kkboxCacheDirOverride, "aaaa_0", "https://api-webapps.kkbox.com.tw/v2/tracks-set/LIST==?terr=tw&lang=tc", testKKBOXSongList)
			testWriteLog(t, filepath.Join(kkboxLocalStorageOverride, "000004.log"), [][]testLDBEntry{
				{{key: testKKBOXPrefKey("me@example.com", "now_playing"), seq: 20,
					value: testUTF16Value(`"kkbox:song-list:LIST==:0:0?track=T3"`)}},
			})
		}
	}
	t.Cleanup(func() { kkboxUpcomingBeforeRetry = nil })
	got, ok := kkboxUpcoming("Taylor Swift", "willow", 5)
	if !ok || retries != 2 {
		t.Fatalf("ok=%v retries=%d", ok, retries)
	}
	if want := []string{"Speak Now"}; !reflect.DeepEqual(titlesOf(got), want) {
		t.Errorf("got %v want %v", titlesOf(got), want)
	}

	// 一直对不上:重读到上限就退回,不无限等。歌手名拼法对不上不重读(重读也不会变)。
	retries = 0
	kkboxUpcomingBeforeRetry = func() { retries++ }
	if _, ok := kkboxUpcoming("Taylor Swift", "Another Song", 5); ok || retries != len(kkboxUpcomingRetryDelays) {
		t.Errorf("一直对不上: ok=%v retries=%d", ok, retries)
	}
	retries = 0
	if _, ok := kkboxUpcoming("Taylor Swift (泰勒絲)", "willow", 5); ok || retries != 0 {
		t.Errorf("歌手名对不上不该重读: ok=%v retries=%d", ok, retries)
	}
}

func TestKKBOXArtistName(t *testing.T) {
	a := func(n string) kkboxArtist { return kkboxArtist{Name: n} }
	withRoles := func(main, feat []kkboxArtist) kkboxTrack {
		tr := kkboxTrack{Artist: &kkboxArtist{Name: "Base (中文)"}}
		tr.ArtistRoles = &struct {
			Main     []kkboxArtist `json:"main_artists"`
			Featured []kkboxArtist `json:"featured_artists"`
		}{Main: main, Featured: feat}
		return tr
	}
	cases := []struct {
		name string
		t    kkboxTrack
		want string
	}{
		{"main + featured", withRoles([]kkboxArtist{a("Taylor Swift")}, []kkboxArtist{a("Ed Sheeran"), a("Future")}), "Taylor Swift, Ed Sheeran, Future"},
		{"没有 main_artists 字段退回 artist.name", withRoles(nil, []kkboxArtist{a("Guest")}), "Base (中文), Guest"},
		{"main_artists 是空数组就是空(同前端)", withRoles([]kkboxArtist{}, []kkboxArtist{a("Guest")}), "Guest"},
		{"没有 artist_roles 用 artist.name", kkboxTrack{Artist: &kkboxArtist{Name: "Taylor Swift (泰勒絲)"}}, "Taylor Swift (泰勒絲)"},
		{"曲目没有 artist 用专辑歌手", kkboxTrack{}, "Album Artist"},
	}
	for _, c := range cases {
		if got := kkboxArtistName(c.t, "Album Artist"); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestParseKKBOXContext(t *testing.T) {
	got, ok := parseKKBOXContext("kkbox:song-list:9aAuLbTii-uJpt3QZaHg==:15:0?track=KowPqsXBP2VFtgmG5K")
	if want := (kkboxContext{kind: "song-list", id: "9aAuLbTii-uJpt3QZaHg==", track: "KowPqsXBP2VFtgmG5K"}); !ok || got != want {
		t.Errorf("got %+v ok=%v", got, ok)
	}
	for _, bad := range []string{"kkbox:void", "", "spotify:album:x?track=y", "kkbox:album:ALB:0:0"} {
		if _, ok := parseKKBOXContext(bad); ok {
			t.Errorf("%q 不该解得出", bad)
		}
	}
}

func TestChromiumLocalStorageString(t *testing.T) {
	if got, ok := chromiumLocalStorageString([]byte(testUTF16Value(`"泰勒絲"`))); !ok || got != `"泰勒絲"` {
		t.Errorf("UTF-16: %q %v", got, ok)
	}
	if got, ok := chromiumLocalStorageString([]byte("\x01true")); !ok || got != "true" {
		t.Errorf("Latin-1: %q %v", got, ok)
	}
	if _, ok := chromiumLocalStorageString([]byte("\x00a")); ok {
		t.Error("奇数字节的 UTF-16 不该解得出")
	}
}

// ldbScan:.ldb 里的旧值被 .log 里的新值盖掉,删除标记让它消失,不满足条件的 key 不在结果里。
func TestLDBScan(t *testing.T) {
	dir := t.TempDir()
	testWriteTable(t, filepath.Join(dir, "000005.ldb"), []testLDBEntry{
		{key: "p:a", seq: 1, value: "old"},
		{key: "p:b", seq: 2, value: "keep"},
		{key: "p:c", seq: 3, value: "gone"},
		{key: "q:z", seq: 4, value: "other"},
	}, 2, true)
	testWriteLog(t, filepath.Join(dir, "000006.log"), [][]testLDBEntry{
		{{key: "p:a", seq: 10, value: "new"}},
		{{key: "p:c", seq: 11, deleted: true}},
	})
	got := ldbScan(dir, func(k []byte) bool { return bytes.HasPrefix(k, []byte("p:")) })
	vals := map[string]string{}
	for k, v := range got {
		vals[k] = string(v.value)
	}
	if want := map[string]string{"p:a": "new", "p:b": "keep"}; !reflect.DeepEqual(vals, want) {
		t.Errorf("got %v want %v", vals, want)
	}
}
