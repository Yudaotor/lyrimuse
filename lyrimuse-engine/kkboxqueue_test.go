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
	// 每首只按一种写法预解析(另一种真播到时整份搬过去,见 kkboxalias.go)。
	if len(got) != 3 {
		t.Errorf("每首一种写法: %+v", got)
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
// 单曲:上下文是 kkbox:track:<id>,接下来会播的是这首的相关歌曲(自动续播),表里第一首是它自己。
func TestKKBOXUpcomingSingleTrack(t *testing.T) {
	withTestKKBOX(t, "kkbox:track:SEED", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "rt1_0", "https://api-webapps.kkbox.com.tw/v2/related-tracks/SEED?terr=tw",
		`{"data":{"id":"REL==","tracks":[
		{"id":"SEED","name":"最偉大的作品","artist_roles":{"main_artists":[{"name":"周杰倫"}],"featured_artists":[]},"album":{"name":"最偉大的作品"}},
		{"id":"R1","name":"Skywalker","artist_roles":{"main_artists":[{"name":"怕胖團"}],"featured_artists":[]},"album":{"name":"2049"}}]}}`)
	got, ok := kkboxUpcoming("周杰倫", "最偉大的作品", 5)
	if !ok || len(got) == 0 || got[0].title != "Skywalker" || got[0].artist != "怕胖團" {
		t.Fatalf("got %+v ok=%v", got, ok)
	}
}

// 「一起聽」:下一首由主持人决定,本机没有队列 —— 不重读、不交曲目,ok=true 让调用方也不退回同专辑预取。
func TestKKBOXUpcomingListenWithSkips(t *testing.T) {
	withTestKKBOX(t, "kkbox:listen-with:channel:CH1", false)
	retries := 0
	kkboxUpcomingBeforeRetry = func() { retries++ }
	t.Cleanup(func() { kkboxUpcomingBeforeRetry = nil })
	got, ok := kkboxUpcoming("周杰倫", "最偉大的作品", 5)
	if !ok || len(got) != 0 || retries != 0 {
		t.Fatalf("got %+v ok=%v retries=%d", got, ok, retries)
	}
}

// 收藏库「全部歌曲」:上下文用 track_id;曲目表每首只有 id,歌名歌手从单曲 / 批量详情补,补不上的那首不交出去。
func TestKKBOXUpcomingLibraryAllTracks(t *testing.T) {
	withTestKKBOX(t, "kkbox:my-library:@all:0?track_id=L1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "lib_0", "https://api-webapps.kkbox.com.tw/v2/library/all-tracks?lang=tc",
		`{"status":"OK","data":{"version":1,"tracks":[{"id":"L1"},{"id":"L2"},{"id":"L3"}]}}`)
	testChromiumCacheEntry(t, cache, "lib1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/L1?terr=tw",
		`{"data":{"id":"L1","name":"最偉大的作品","artist_roles":{"main_artists":[{"name":"周杰倫"}]},"album":{"name":"最偉大的作品"}}}`)
	testChromiumCacheEntry(t, cache, "lib2_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=L2&plain=0",
		`{"data":[{"id":"L2","name":"親密愛人","artist_roles":{"main_artists":[{"name":"法蘭"}]},"album":{"name":"另一個法蘭"}}]}`)
	got, ok := kkboxUpcoming("周杰倫", "最偉大的作品", 5)
	if !ok || len(got) == 0 || got[0].title != "親密愛人" || got[0].artist != "法蘭" {
		t.Fatalf("got %+v ok=%v", got, ok)
	}
	for _, tr := range got {
		if tr.title == "" {
			t.Errorf("没有详情的那首不该交出去: %+v", got)
		}
	}
	if !isKKBOXTrackListPath("/v2/library/all-tracks") || isKKBOXTrackListPath("/v2/library/favorite-tracks") {
		t.Error("最近列表兜底只认全部歌曲那份")
	}

	withTestKKBOX(t, "kkbox:my-library:@favorites:0?track_id=L1", false)
	if _, ok := kkboxUpcoming("周杰倫", "最偉大的作品", 5); ok {
		t.Error("收藏库里没接的那几份:退回同专辑预取")
	}
}

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
	if _, ok := kkboxUpcoming("Someone Else", "Love Story", 5); ok {
		t.Error("歌手名哪种写法都对不上(同名的另一首):照这个拼法预解析是白解析,退回")
	}
	if _, ok := kkboxUpcoming("Taylor Swift (泰勒絲)", "Love Story", 5); !ok {
		t.Error("播放器报的是 artist.name 那种写法(详情里的):认")
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
	if _, ok := kkboxUpcoming("Someone Else", "willow", 5); ok || retries != 0 {
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
	if got, ok := parseKKBOXContext("kkbox:my-library:@all:1?track_id=D-GkWXIWldMimVKEC3"); !ok || got.id != "@all" || got.track != "D-GkWXIWldMimVKEC3" {
		t.Errorf("收藏库:曲目 id 在 track_id 里, got %+v ok=%v", got, ok)
	}
	if got, ok := parseKKBOXContext("kkbox:track:4s7gyziTOGRFhEcFQf"); !ok || got.kind != "track" || got.track != "4s7gyziTOGRFhEcFQf" {
		t.Errorf("单曲:上下文本身就是这首, got %+v ok=%v", got, ok)
	}
	if got, ok := parseKKBOXContext("kkbox:listen-with:channel:CH1"); !ok || got.kind != "listen-with" || got.id != "CH1" {
		t.Errorf("一起聽:没有曲目 id 也认得出, got %+v ok=%v", got, ok)
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

// 同一个曲目 id,歌单列表里的 roles 是「田馥甄」,详情里是「田馥甄 (Hebe)」(= artist.name),播放器报的是详情那份。
// 当前这首报的是 artist.name 那种写法也认;下一首 artist.name 是「Various Artists」、roles 是真歌手,只有一种写法。
func TestKKBOXUpcomingPlaylistArtistSpellings(t *testing.T) {
	withTestKKBOX(t, "kkbox:online-playlist:PL2:3?track=H1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "iiii_0", "https://api-webapps.kkbox.com.tw/v2/playlists/PL2?terr=tw",
		`{"data":{"id":"PL2","tracks":[
		{"id":"H1","name":"要去什麼地方","artist":{"name":"田馥甄 (Hebe)"},"artist_roles":{"main_artists":[{"name":"田馥甄"}],"featured_artists":[]},"album":{"name":"要去什麼地方"}},
		{"id":"H2","name":"無你的所在","artist":{"name":"Various Artists"},"artist_roles":{"main_artists":[{"name":"李承隆 Tzo"}],"featured_artists":[]},"album":{"name":"原聲帶"}},
		{"id":"H3","name":"大船","artist":{"name":"田馥甄 (Hebe)"},"artist_roles":{"main_artists":[{"name":"田馥甄"}],"featured_artists":[]},"album":{"name":"要去什麼地方"}},
		{"id":"H4","name":"小幸運","artist":{"name":"田馥甄 (Hebe)"},"artist_roles":{"main_artists":[{"name":"田馥甄"}],"featured_artists":[]},"album":{"name":"我的少女時代"}}]}}`)
	// 大船播过,单首详情在缓存里:照详情,不猜第二种写法。
	testChromiumCacheEntry(t, cache, "jjjj_0", "https://api-webapps.kkbox.com.tw/v2/tracks/H3?terr=tw",
		`{"data":{"id":"H3","name":"大船","artist":{"name":"田馥甄 (Hebe)"},"artist_roles":{"main_artists":[{"name":"田馥甄 (Hebe)"}],"featured_artists":[]},"album":{"name":"要去什麼地方"}}}`)
	got, ok := kkboxUpcoming("田馥甄 (Hebe)", "要去什麼地方", 5)
	if !ok {
		t.Fatal("播放器报的是 artist.name 那种写法:不该整份退回")
	}
	var spelled []string
	for _, x := range got {
		spelled = append(spelled, x.artist+"|"+x.title)
	}
	// 小幸運不在当前这张专辑、也没有详情:按列表里的写法。
	want := []string{"李承隆 Tzo|無你的所在", "田馥甄 (Hebe)|大船", "田馥甄|小幸運"}
	if !reflect.DeepEqual(spelled, want) {
		t.Errorf("got %v want %v", spelled, want)
	}
}

func TestKKBOXArtistSpellings(t *testing.T) {
	a := func(n string) kkboxArtist { return kkboxArtist{Name: n} }
	track := func(name string, main, feat []kkboxArtist) kkboxTrack {
		tr := kkboxTrack{Artist: &kkboxArtist{Name: name}}
		tr.ArtistRoles = &struct {
			Main     []kkboxArtist `json:"main_artists"`
			Featured []kkboxArtist `json:"featured_artists"`
		}{Main: main, Featured: feat}
		return tr
	}
	cases := []struct {
		name        string
		t           kkboxTrack
		fromDetails bool
		want        []string
	}{
		{"括号别名", track("Taylor Swift (泰勒絲)", []kkboxArtist{a("Taylor Swift")}, []kkboxArtist{a("Ed Sheeran")}), false,
			[]string{"Taylor Swift, Ed Sheeran", "Taylor Swift (泰勒絲), Ed Sheeran"}},
		{"只换第一位主唱", track("五月天 (Mayday)", []kkboxArtist{a("五月天"), a("孫燕姿")}, nil), false,
			[]string{"五月天, 孫燕姿", "五月天 (Mayday), 孫燕姿"}},
		{"两边一样", track("周杰倫", []kkboxArtist{a("周杰倫")}, nil), false, []string{"周杰倫"}},
		{"artist.name 是合辑", track("Various Artists", []kkboxArtist{a("李承隆 Tzo")}, nil), false, []string{"李承隆 Tzo"}},
		{"不是括号别名", track("田馥甄Hebe", []kkboxArtist{a("田馥甄")}, nil), false, []string{"田馥甄"}},
		{"详情不猜", track("田馥甄 (Hebe)", []kkboxArtist{a("田馥甄")}, nil), true, []string{"田馥甄"}},
	}
	for _, c := range cases {
		if got, _ := kkboxArtistSpellings(c.t, "Album Artist", "Album", c.fromDetails); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
	if got, key := kkboxArtistSpellings(kkboxTrack{}, "Album Artist", "Album", false); !reflect.DeepEqual(got, []string{"Album Artist"}) || key != "" {
		t.Errorf("没有歌手的曲目退回专辑歌手: %v", got)
	}
}

// 同一张专辑里写法一致:缓存里这张专辑别的曲目有详情,两种写法的那首就照详情那一种;别的专辑照列表里的写法。
func TestKKBOXUpcomingAlbumFormFromCachedDetails(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "kkkk_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=Z1,Z2&terr=tw",
		`{"data":[{"id":"Z1","name":"Delicate","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift (泰勒絲)"}],"featured_artists":[]},"album":{"name":"reputation"}},
		{"id":"Z2","name":"the 1","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"folklore"}}]}`)
	got, ok := kkboxUpcoming("Taylor Swift", "Love Story", 5)
	if !ok {
		t.Fatal("读得到后面几首")
	}
	var spelled []string
	for _, x := range got {
		spelled = append(spelled, x.artist+"|"+x.title)
	}
	want := []string{"Taylor Swift (泰勒絲), Ed Sheeran, Future|End Game", "Taylor Swift|willow", "Taylor Swift|Speak Now"}
	if !reflect.DeepEqual(spelled, want) {
		t.Errorf("reputation 照详情带别名,其余两张没有证据照列表:got %v want %v", spelled, want)
	}
}

// 此刻在放的这首报的写法就是这张专辑的写法:同专辑后面的曲目只留那一种。
func TestKKBOXUpcomingAlbumFormFromPlayer(t *testing.T) {
	withTestKKBOX(t, "kkbox:online-playlist:PL3:0?track=S1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "llll_0", "https://api-webapps.kkbox.com.tw/v2/playlists/PL3?terr=tw",
		`{"data":{"id":"PL3","tracks":[
		{"id":"S1","name":"The Fate of Ophelia","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"album":{"name":"The Life of a Showgirl"}},
		{"id":"S2","name":"Opalite","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"album":{"name":"The Life of a Showgirl"}},
		{"id":"S3","name":"Lover","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"album":{"name":"Lover"}}]}}`)
	got, ok := kkboxUpcoming("Taylor Swift (泰勒絲)", "The Fate of Ophelia", 5)
	if !ok {
		t.Fatal("读得到后面几首")
	}
	var spelled []string
	for _, x := range got {
		spelled = append(spelled, x.artist+"|"+x.title)
	}
	want := []string{"Taylor Swift (泰勒絲)|Opalite", "Taylor Swift|Lover"}
	if !reflect.DeepEqual(spelled, want) {
		t.Errorf("got %v want %v", spelled, want)
	}
}

// 详情文件解析一次就记住(按路径 + 修改时间),同一个文件不重复解析;文件变了重新解析。
func TestKKBOXDetailMemo(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "mmmm_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=Z1&terr=tw",
		`{"data":[{"id":"Z1","name":"Delicate","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift (泰勒絲)"}]},"album":{"name":"reputation"}}]}`)
	c := scanKKBOXCache(kkboxCacheDirOverride)
	if forms := c.albumForms(); !forms[kkboxAlbumFormKey("Taylor Swift", "reputation")] {
		t.Fatalf("详情里带别名: %v", forms)
	}
	var entry kkboxCacheEntry
	for _, e := range c {
		if filepath.Base(e.file) == "mmmm_0" {
			entry = e
		}
	}
	kkboxDetailMemoMu.Lock()
	memo, ok := kkboxDetailMemo[entry.file]
	kkboxDetailMemoMu.Unlock()
	if !ok || len(memo.tracks) != 1 {
		t.Fatalf("解析过的要记住: %+v", memo)
	}
	// 换了内容(新的修改时间):重新解析。
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "mmmm_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=Z1&terr=tw",
		`{"data":[{"id":"Z1","name":"Delicate","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"album":{"name":"reputation"}}]}`)
	later := time.Now().Add(time.Minute)
	if err := os.Chtimes(entry.file, later, later); err != nil {
		t.Fatal(err)
	}
	if forms := scanKKBOXCache(kkboxCacheDirOverride).albumForms(); forms[kkboxAlbumFormKey("Taylor Swift", "reputation")] {
		t.Errorf("文件变了要重新解析: %v", forms)
	}
	// 文件被淘汰:记录跟着清掉。
	if err := os.Remove(entry.file); err != nil {
		t.Fatal(err)
	}
	scanKKBOXCache(kkboxCacheDirOverride).albumForms()
	kkboxDetailMemoMu.Lock()
	_, stale := kkboxDetailMemo[entry.file]
	kkboxDetailMemoMu.Unlock()
	if stale {
		t.Error("不在缓存目录里的文件要从记录里清掉")
	}
}

// 同一张专辑的详情里两种写法都见过(没实测到过):不下结论,照列表里的写法。
func TestKKBOXAlbumFormsMixedAlbum(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "nnnn_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=Z1,Z2&terr=tw",
		`{"data":[{"id":"Z1","name":"Delicate","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift (泰勒絲)"}]},"album":{"name":"reputation"}},
		{"id":"Z2","name":"Gorgeous","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"album":{"name":"reputation"}}]}`)
	if forms := scanKKBOXCache(kkboxCacheDirOverride).albumForms(); hasKey(forms, kkboxAlbumFormKey("Taylor Swift", "reputation")) {
		t.Errorf("混用的专辑不下结论: %v", forms)
	}
}
