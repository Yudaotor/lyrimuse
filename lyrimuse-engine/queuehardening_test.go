package main

import (
	"encoding/binary"
	"errors"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// 播放队列那一层的加固:不可信二进制解析里的长度回绕、预取随换歌收手、Spotify 提示表与漂移计数、
// YouTube Music 重名曲目的定位、plist 的超大整数、KKBOX 的扫描记忆与「叫不出名字」的回退。

// hugeUvarint 是一个接近 2^64 的 varint:跟任何偏移相加都会回绕成小数。
func hugeUvarint() []byte {
	return binary.AppendUvarint(nil, math.MaxUint64-3)
}

// 块里某条的 nonShared 长度接近 2^64:以前 uint64(i)+nonShared+vlen 回绕、绕过边界检查,切片越界 panic。
func TestLdbBlockEntriesRejectsWrappingLengths(t *testing.T) {
	var b []byte
	b = append(b, 0) // shared
	b = append(b, hugeUvarint()...)
	b = append(b, 8) // vlen
	b = append(b, []byte("abcdefgh")...)
	b = binary.LittleEndian.AppendUint32(b, 0) // restart 数
	err := ldbBlockEntries(b, func(k, v []byte) bool { return true })
	if err == nil {
		t.Fatal("回绕的长度应当报错")
	}
	// vlen 那一项回绕同样要挡住。
	b = b[:0]
	b = append(b, 0, 1) // shared, nonShared
	b = append(b, hugeUvarint()...)
	b = append(b, 'k')
	b = binary.LittleEndian.AppendUint32(b, 0)
	if err := ldbBlockEntries(b, func(k, v []byte) bool { return true }); err == nil {
		t.Fatal("回绕的 vlen 应当报错")
	}
}

// .log 里一条批写记录的 key 长度接近 2^64:readSlice 要当成读不了,而不是越界。
func TestLdbApplyBatchRejectsWrappingLength(t *testing.T) {
	var b []byte
	b = binary.LittleEndian.AppendUint64(b, 7) // seq
	b = binary.LittleEndian.AppendUint32(b, 1) // count
	b = append(b, 1)                           // typ = value
	b = append(b, hugeUvarint()...)
	b = append(b, "key"...)
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("不该 panic: %v", r)
		}
	}()
	ldbApplyBatch(b, func([]byte) bool { return true }, func([]byte, ldbValue) {
		t.Error("解不出来的记录不该交出去")
	})
}

// 解析里万一还有没挡住的越界,单个文件当读失败,不带走进程。
func TestLdbSafelyRecoversPanic(t *testing.T) {
	err := ldbSafely("/x/000001.ldb", func() error {
		var s []byte
		_ = s[3]
		return nil
	})
	if err == nil {
		t.Fatal("越界应当变成这个文件的读错误")
	}
	if err := ldbSafely("/x/000002.ldb", func() error { return nil }); err != nil {
		t.Fatalf("正常读取不受影响: %v", err)
	}
}

// Snappy 解码途中就按头部声明的长度截住:坏块不能先撑出远超声明长度的缓冲才报错。
func TestSnappyDecodeStopsAtDeclaredLength(t *testing.T) {
	// 声明 2 字节,literal 却给 10 字节。
	src := binary.AppendUvarint(nil, 2)
	src = append(src, byte(9<<2)) // literal,长度 10
	src = append(src, "0123456789"...)
	if _, err := snappyDecode(src); err == nil {
		t.Fatal("literal 超过声明长度应当报错")
	}
	// 声明 5 字节:一个字节的 literal 之后,copy 元素要复制 64 字节。
	src = binary.AppendUvarint(nil, 5)
	src = append(src, 0, 'a')        // literal,长度 1
	src = append(src, byte(63<<2|2)) // copy2,长度 64
	src = binary.LittleEndian.AppendUint16(src, 1)
	if _, err := snappyDecode(src); err == nil {
		t.Fatal("copy 超过声明长度应当报错")
	}
	// 正常的一段照样解得开。
	src = binary.AppendUvarint(nil, 4)
	src = append(src, byte(3<<2))
	src = append(src, "abcd"...)
	got, err := snappyDecode(src)
	if err != nil || string(got) != "abcd" {
		t.Fatalf("正常数据: %q %v", got, err)
	}
}

// Spotify 状态文件的 protobuf:length-delimited 的长度接近 2^64 时报错,不越界。
func TestPbParseRejectsWrappingLength(t *testing.T) {
	b := binary.AppendUvarint(nil, 1<<3|2) // 字段 1,wire type 2
	b = append(b, hugeUvarint()...)
	b = append(b, "xyz"...)
	if _, err := pbParse(b); err == nil {
		t.Fatal("回绕的长度应当报错")
	}
	if _, err := spotifyParseState(append([]byte("1700000000#"), b...)); err == nil {
		t.Fatal("从入口进来同样应当报错而不是 panic")
	}
}

// 状态文件认得出来、只是这一刻没有当前曲目 / 曲目表:不算「上游格式变了」。
func TestSpotifyStateWithoutQueueIsNotDrift(t *testing.T) {
	_, err := spotifyParseState([]byte("1700000000#"))
	if err == nil {
		t.Fatal("没有当前曲目应当报错")
	}
	if !errors.Is(err, errSpotifyStateNoQueue) {
		t.Fatalf("应当归为「这一刻没有队列」,不计解析漂移: %v", err)
	}
	if _, err := spotifyParseState([]byte("no timestamp")); errors.Is(err, errSpotifyStateNoQueue) {
		t.Fatal("文件本身认不出来的仍要算漂移")
	}
}

// 提示表用完不删,同一首歌从单曲和专辑各放过一次就有两条同前缀的:先认最近一次换曲记下的,
// 认不出又不止一个 id 时不猜。
func TestSpotifyTrackIDHintPrefersLatest(t *testing.T) {
	enrichMu.Lock()
	savedHints, savedLast := spotifyTrackIDHints, spotifyTrackIDLastKey
	single, album := enrichKey("甲", "歌1", "单曲"), enrichKey("甲", "歌1", "专辑")
	spotifyTrackIDHints = map[string]string{single: "idSingle", album: "idAlbum"}
	spotifyTrackIDLastKey = ""
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		spotifyTrackIDHints, spotifyTrackIDLastKey = savedHints, savedLast
		enrichMu.Unlock()
	})
	if got := spotifyTrackIDHintFor("甲", "歌1"); got != "" {
		t.Errorf("两个 id、没有最近一次可认:不该猜,得到 %q", got)
	}
	enrichMu.Lock()
	spotifyTrackIDLastKey = album
	enrichMu.Unlock()
	if got := spotifyTrackIDHintFor("甲", "歌1"); got != "idAlbum" {
		t.Errorf("应当认最近一次换曲记下的那条,得到 %q", got)
	}
	enrichMu.Lock()
	spotifyTrackIDHints = map[string]string{single: "same", album: "same"}
	spotifyTrackIDLastKey = enrichKey("乙", "别的歌", "")
	enrichMu.Unlock()
	if got := spotifyTrackIDHintFor("甲", "歌1"); got != "same" {
		t.Errorf("几条都是同一个 id 时照给,得到 %q", got)
	}
	noteSpotifyTrackID("丙", "歌2", "专辑", "idNew")
	enrichMu.Lock()
	last := spotifyTrackIDLastKey
	enrichMu.Unlock()
	if last != enrichKey("丙", "歌2", "专辑") {
		t.Errorf("换曲时要记下最近一次的 key,得到 %q", last)
	}
}

// 连跳几首时,上一首那批还没排完的不再往下起:代号变了,第一首都不占位。
func TestQueueUpcomingEnrichStopsAfterTrackChange(t *testing.T) {
	tracks := []upcomingTrack{{artist: "代号测试歌手", title: "代号测试一"}, {artist: "代号测试歌手", title: "代号测试二"}}
	gen := upcomingGen.Add(1)
	upcomingGen.Add(1) // 又换了一首
	queueUpcomingEnrich(tracks, gen)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, tr := range tracks {
		if enrichInflight[enrichKey(tr.artist, tr.title, tr.album)] {
			t.Errorf("换歌之后不该再起这一批: %s", tr.title)
		}
	}
}

// 高亮还停在上一首时,重名的歌(「Home」)不能取第一个命中把播过的那首当成当前。
func TestYTMusicQueueCurrentWithDuplicateTitles(t *testing.T) {
	items := []ytmusicQueueItem{
		{title: "Home", artist: "A"},
		{title: "Song1", artist: "B"},
		{title: "Song2", artist: "C", selected: true},
		{title: "Home", artist: "D"},
		{title: "Next1", artist: "E"},
	}
	if got := ytmusicQueueCurrent(items, "D", "Home", 0); got != 3 {
		t.Errorf("歌手+歌名对得上的那条优先,得到 %d", got)
	}
	if got := ytmusicQueueCurrent(items, "某个写法不同的歌手", "Home", 0); got != 3 {
		t.Errorf("只剩歌名对得上时认高亮之后的第一条,得到 %d", got)
	}
	noSel := append([]ytmusicQueueItem(nil), items...)
	noSel[2].selected = false
	if got := ytmusicQueueCurrent(noSel, "某个写法不同的歌手", "Home", 0); got != -1 {
		t.Errorf("没有高亮可参照、歌名重名时不猜,得到 %d", got)
	}
	if got := ytmusicQueueCurrent(items, "B", "Song1", 0); got != 1 {
		t.Errorf("唯一命中照常认,得到 %d", got)
	}
	got, ok := pickYTMusicUpcoming(items, "D", "Home", 0, 5)
	if !ok || len(got) != 1 || got[0].title != "Next1" {
		t.Fatalf("接下来应当是 Next1: ok=%v %+v", ok, got)
	}
}

// plist 的整数可以是 64 位无符号:一个字段读不成不该让整份归档作废。
func TestPlistXMLLargeIntegerKeepsParsing(t *testing.T) {
	doc := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>` +
		`<key>hash</key><integer>18446744073709551615</integer>` +
		`<key>bad</key><integer>not-a-number</integer>` +
		`<key>name</key><string>ok</string></dict></plist>`
	root, err := parsePlistXML([]byte(doc))
	if err != nil {
		t.Fatalf("不该整份失败: %v", err)
	}
	m, _ := root.(map[string]any)
	if m["name"] != "ok" {
		t.Errorf("其余字段照读: %+v", m)
	}
	if u, ok := m["hash"].(uint64); !ok || u != math.MaxUint64 {
		t.Errorf("超过 int64 的整数应当按 uint64 读出: %#v", m["hash"])
	}
	if v, present := m["bad"]; !present || v != nil {
		t.Errorf("认不出的整数当缺席(nil): %#v", v)
	}
}

// 扫描缓存目录时认过的文件记住:没变的不再打开读头,变了的重读,淘汰掉的清出记忆。
func TestScanKKBOXCacheRemembersEntryURLs(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	dir := kkboxCacheDirOverride
	path := filepath.Join(dir, "aaaa_0")
	if !kkboxScanHas(scanKKBOXCache(dir), path) {
		t.Fatal("首次扫描应当认出曲目表")
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	// 头部改成认不出来的内容,大小、修改时间都不变:记忆应当照用,不重读。
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 8; i++ {
		raw[i] = 0
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, st.ModTime(), st.ModTime()); err != nil {
		t.Fatal(err)
	}
	if !kkboxScanHas(scanKKBOXCache(dir), path) {
		t.Fatal("文件没变(大小、修改时间都一样)时应当沿用记忆")
	}
	later := st.ModTime().Add(time.Minute)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	if kkboxScanHas(scanKKBOXCache(dir), path) {
		t.Fatal("文件变了应当重读头部,认不出就不要")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	scanKKBOXCache(dir)
	kkboxScanMemoMu.Lock()
	_, stale := kkboxScanMemo[path]
	kkboxScanMemoMu.Unlock()
	if stale {
		t.Error("不在目录里的文件要从记忆里清掉")
	}
}

func kkboxScanHas(c kkboxCache, path string) bool {
	for _, e := range c {
		if e.file == path {
			return true
		}
	}
	return false
}

// 收藏库里接下来几首的详情没进缓存:先截 n 首再滤会把后面叫得出名字的一起挤掉;一首也叫不出时退回同专辑预取。
func TestKKBOXUpcomingSkipsUnnamedTracks(t *testing.T) {
	withTestKKBOX(t, "kkbox:my-library:@all:0?track_id=L1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "lib_0", "https://api-webapps.kkbox.com.tw/v2/library/all-tracks?lang=tc",
		`{"status":"OK","data":{"version":1,"tracks":[{"id":"L1"},{"id":"L2"},{"id":"L3"},{"id":"L4"}]}}`)
	testChromiumCacheEntry(t, cache, "lib1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/L1?terr=tw",
		`{"data":{"id":"L1","name":"最偉大的作品","artist_roles":{"main_artists":[{"name":"周杰倫"}]},"album":{"name":"最偉大的作品"}}}`)
	testChromiumCacheEntry(t, cache, "lib4_0", "https://api-webapps.kkbox.com.tw/v2/tracks/?ids=L4&plain=0",
		`{"data":[{"id":"L4","name":"親密愛人","artist_roles":{"main_artists":[{"name":"法蘭"}]},"album":{"name":"另一個法蘭"}}]}`)
	got, ok := kkboxUpcoming("周杰倫", "最偉大的作品", 1)
	if !ok || !reflect.DeepEqual(titlesOf(got), []string{"親密愛人"}) {
		t.Fatalf("n=1 时应当跳过叫不出名字的两首、交出 L4: ok=%v %v", ok, titlesOf(got))
	}

	withTestKKBOX(t, "kkbox:my-library:@all:0?track_id=L1", false)
	cache = kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "lib_0", "https://api-webapps.kkbox.com.tw/v2/library/all-tracks?lang=tc",
		`{"status":"OK","data":{"version":1,"tracks":[{"id":"L1"},{"id":"L2"},{"id":"L3"}]}}`)
	testChromiumCacheEntry(t, cache, "lib1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/L1?terr=tw",
		`{"data":{"id":"L1","name":"最偉大的作品","artist_roles":{"main_artists":[{"name":"周杰倫"}]},"album":{"name":"最偉大的作品"}}}`)
	if got, ok := kkboxUpcoming("周杰倫", "最偉大的作品", 5); ok {
		t.Fatalf("接下来一首都叫不出名字:应当退回同专辑预取,得到 %v", titlesOf(got))
	}
}
