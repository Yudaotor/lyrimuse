package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"weak"
)

// withBodyEviction 打开退回,测试结束关掉、清空登记。
func withBodyEviction(t *testing.T) {
	t.Helper()
	enableBodyEviction()
	t.Cleanup(func() {
		bodyEvictionOn.Store(false)
		bodyRegMu.Lock()
		bodyLocated = map[string][]weak.Pointer[bodyBlob]{}
		bodyRegMu.Unlock()
	})
}

// clearBodyFileCacheForTest 清掉最近读过的小文件,下一次读一定落到磁盘。
func clearBodyFileCacheForTest() {
	bodyFileMu.Lock()
	bodyFiles, bodyFileOrder = map[string]*enrichBody{}, nil
	bodyFileMu.Unlock()
}

// writeBodyFileForTest 写一份自洽的正文小文件。
func writeBodyFileForTest(t *testing.T, path string, b enrichBody) {
	t.Helper()
	b.CRC = bodyCRCOf(b.fields())
	data, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestBodyTextSharesBlobForSameContent(t *testing.T) {
	a, b := bt("[00:01.00]同一句"), bt("[00:01.00]同一句")
	if a.b != b.b {
		t.Fatal("内容相同的正文要共用一个 bodyBlob,reflect.DeepEqual 才判得等")
	}
	if !reflect.DeepEqual(enrichEntry{Lyrics: a}, enrichEntry{Lyrics: b}) {
		t.Fatal("内容相同的两个条目 DeepEqual 要相等")
	}
	c := bt("[00:01.00]另一句")
	if a.Equal(c) || reflect.DeepEqual(enrichEntry{Lyrics: a}, enrichEntry{Lyrics: c}) {
		t.Fatal("内容不同不能判等")
	}
	if !a.EqualString("[00:01.00]同一句") || a.EqualString("") || !(bodyText{}).EqualString("") {
		t.Fatal("EqualString 跟明文比")
	}
	if !bt("").IsZero() || bt("").Len() != 0 {
		t.Fatal("空串是零值")
	}
}

func TestBodyTextJSONRoundTrip(t *testing.T) {
	in := enrichEntry{Lyrics: bt("[00:01.00]一"), LyricsSource: "qq"}
	data, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"lyrics":"[00:01.00]一","lyrics_source":"qq","ts":0}` {
		t.Fatalf("盘上还是明文、空正文不落键: %s", data)
	}
	var out enrichEntry
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	if !out.Lyrics.Equal(in.Lyrics) || !out.LyricsYRC.IsZero() {
		t.Fatalf("读回来不一致: %#v", out)
	}
}

// 退回之后不常驻,用到时从小文件读回同样的内容。
func TestEvictedBodyReadsBackFromSideFile(t *testing.T) {
	withBodyEviction(t)
	path := filepath.Join(t.TempDir(), "a.json")
	writeBodyFileForTest(t, path, enrichBody{Lyrics: "[00:01.00]退回一", LyricsYRC: "[1000,500](1000,500,0)退"})
	lyr, yrc := bt("[00:01.00]退回一"), bt("[1000,500](1000,500,0)退")
	locateBody(lyr, path, bodyFieldLyrics)
	locateBody(yrc, path, bodyFieldYRC)
	if lyr.resident() || yrc.resident() {
		t.Fatal("定位之后应该退回")
	}
	dropBodyFileCache(path)
	if lyr.String() != "[00:01.00]退回一" || yrc.String() != "[1000,500](1000,500,0)退" {
		t.Fatalf("读回来不对: %q %q", lyr.String(), yrc.String())
	}
	if lyr.resident() {
		t.Fatal("读回来不该重新常驻")
	}
}

// 改写小文件之前钉住:拿着旧内容的快照照样读得回旧内容;新文件里同一块没变的照旧退回。
func TestPinBeforeRewriteKeepsOldSnapshot(t *testing.T) {
	withBodyEviction(t)
	path := filepath.Join(t.TempDir(), "b.json")
	writeBodyFileForTest(t, path, enrichBody{Lyrics: "[00:01.00]旧主歌词", LyricsTr: "[00:01.00]译文不变"})
	oldLyr, tr := bt("[00:01.00]旧主歌词"), bt("[00:01.00]译文不变")
	locateBody(oldLyr, path, bodyFieldLyrics)
	locateBody(tr, path, bodyFieldTr)
	snap := enrichEntry{Lyrics: oldLyr, LyricsTr: tr}

	next := enrichBody{Lyrics: "[00:01.00]新主歌词", LyricsTr: "[00:01.00]译文不变"}
	pinBodiesAt(path, &next)
	writeBodyFileForTest(t, path, next)

	if !snap.Lyrics.resident() || snap.Lyrics.String() != "[00:01.00]旧主歌词" {
		t.Fatalf("旧快照要读得回旧内容: %q", snap.Lyrics.String())
	}
	if snap.LyricsTr.resident() || snap.LyricsTr.String() != "[00:01.00]译文不变" {
		t.Fatal("没变的那一块照旧退回在新文件里")
	}
	// 钉住过的不再登记在这份文件:再改写一次,也不会被当成还在这里
	pinBodiesAt(path, nil)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if snap.Lyrics.String() != "[00:01.00]旧主歌词" {
		t.Fatal("钉住的内容跟文件无关了")
	}
	if snap.LyricsTr.String() != "[00:01.00]译文不变" {
		t.Fatal("文件删掉之前钉住,退回的那块也要读得回")
	}
}

// 整条保存链路:存盘把正文写进小文件后退回;改了主歌词再存,改之前拷的快照照样读得回旧内容,
// 没改的正文不常驻。
func TestSaveEvictsBodiesAndSnapshotsSurviveRewrite(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "周杰伦|晴天|叶惠美"
	putEntriesForTest(map[string]enrichEntry{key: {
		Lyrics: bt("[00:01.00]故事的小黄花"), LyricsYRC: bt("[1000,800](1000,800,0)故事"), LyricsSource: "netease"}})
	saveEnrichCache()

	enrichMu.Lock()
	snap := enrichCache[key]
	enrichMu.Unlock()
	if snap.Lyrics.resident() || snap.LyricsYRC.resident() {
		t.Fatal("写进小文件之后应该退回")
	}

	changed := snap
	changed.Lyrics = bt("[00:01.00]刮风这天")
	putEntriesForTest(map[string]enrichEntry{key: changed})
	saveEnrichCache()
	clearBodyFileCacheForTest()

	if snap.Lyrics.String() != "[00:01.00]故事的小黄花" {
		t.Fatalf("改之前拷的快照要读得回旧主歌词: %q", snap.Lyrics.String())
	}
	enrichMu.Lock()
	cur := enrichCache[key]
	enrichMu.Unlock()
	if cur.Lyrics.String() != "[00:01.00]刮风这天" || cur.Lyrics.resident() {
		t.Fatal("新主歌词写进去之后也退回")
	}
	if cur.LyricsYRC.resident() || cur.LyricsYRC.String() != "[1000,800](1000,800,0)故事" {
		t.Fatal("没改的逐字照旧退回、读得回")
	}
}

// 退回之后再存盘,没改的条目不读小文件:校验值走备忘。把文件删掉也照样存得下去、不报错。
func TestSaveAfterEvictionUsesMemoizedCRC(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "Coldplay|Yellow|Parachutes"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]Look at the stars"), LyricsSource: "qq"}})
	saveEnrichCache()
	path := bodySidePath(enrichBodiesDir(), key)
	dropBodyFileCache(path)
	if err := os.Rename(path, path+".away"); err != nil {
		t.Fatal(err)
	}
	enrichMu.Lock()
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if err := os.Rename(path+".away", path); err != nil {
		t.Fatal(err)
	}
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.Lyrics.String() != "[00:01.00]Look at the stars" {
		t.Fatal("文件放回来之后读得回")
	}
}

// 条目删掉之后,启动清孤儿文件之前钉住:删之前拷的快照照样读得回。
func TestSweepPinsBodiesOfRemovedEntries(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "王菲|红豆|唱游"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]还没好好地感受"), LyricsSource: "qq"}})
	saveEnrichCache()
	enrichMu.Lock()
	snap := enrichCache[key]
	delete(enrichCache, key)
	enrichMu.Unlock()
	if snap.Lyrics.resident() {
		t.Fatal("存盘之后应该退回")
	}
	sweepKeyedDir(enrichBodiesDir(), "lyrics bodies")
	if _, err := os.Stat(bodySidePath(enrichBodiesDir(), key)); !os.IsNotExist(err) {
		t.Fatal("孤儿文件应该被清掉")
	}
	if snap.Lyrics.String() != "[00:01.00]还没好好地感受" {
		t.Fatal("清掉之前要钉住,快照读得回")
	}
}

// 运行中会扫全库的两处先用元数据筛:正文退回之后,不相干的条目一份小文件都不读。
func TestFullScansDoNotReadEvictedBodies(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	entries := map[string]enrichEntry{}
	for i, title := range []string{"甲", "乙", "丙", "丁"} {
		entries["某人|"+title+"|专辑"] = enrichEntry{Lyrics: bt("[00:01.00]第" + title + "首"), DurationSecs: float64(200 + i),
			LyricsScore: 900, LyricsSource: "qq"}
	}
	putEntriesForTest(entries)
	saveEnrichCache()
	enrichMu.Lock()
	cache := enrichCache
	enrichMu.Unlock()
	clearBodyFileCacheForTest()
	before := bodyFileReads.Load()
	self := enrichEntry{DurationSecs: 300, LyricsScore: 100}
	if got := crossAlbumSiblingLyrics(cache, "别人|另一首|专辑", self); got != "" {
		t.Fatalf("没有兄弟: %q", got)
	}
	enrichMu.Lock()
	flips := manualLockFlipsLocked(true)
	enrichMu.Unlock()
	if len(flips) != 0 {
		t.Fatalf("没有选过源的条目: %v", flips)
	}
	if n := bodyFileReads.Load() - before; n != 0 {
		t.Fatalf("不相干的条目不该读小文件,读了 %d 次", n)
	}
}

// 内容跟小文件一样、却是另起的一份(没定位)的常驻正文,存盘时对着文件定位、退回。
func TestSaveLocatesResidentDuplicateOfSideFile(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "孙燕姿|遇见|The Moment"
	const lyr = "[00:01.00]听见冬天的离开"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt(lyr), LyricsSource: "qq"}})
	saveEnrichCache()
	fresh := &bodyBlob{sum: bodySum(lyr), n: len(lyr)}
	s := lyr
	fresh.text.Store(&s)
	enrichMu.Lock()
	e := enrichCache[key]
	e.Lyrics = bodyText{b: fresh}
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()
	if (bodyText{b: fresh}).resident() {
		t.Fatal("跟小文件里一样的那份应该定位到文件、退回")
	}
	if (bodyText{b: fresh}).String() != lyr {
		t.Fatal("退回之后读得回")
	}
}

// 加载时从小文件补回的正文先常驻(启动迁移要用),打开退回之后全部退回、读得回。
func TestLoadedBodiesEvictWhenEnabled(t *testing.T) {
	withTempLeanCache(t)
	const key = "莫文蔚|阴天|你可以"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]阴天 在不开灯的房间"),
		LyricsYRC: bt("[1000,500](1000,500,0)阴"), LyricsSource: "qq"}})
	saveEnrichCache()
	// 存盘时那几个 bodyBlob 回收掉,加载时才是新建的(不然去重拿回的是已经定位过的那个)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	enrichBodyCRCMemo = nil
	runtime.GC()
	runtime.GC()
	loadEnrichCache(enrichPath)
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if !e.Lyrics.resident() {
		t.Fatal("退回打开之前补回的正文常驻")
	}
	withBodyEviction(t)
	if e.Lyrics.resident() || e.LyricsYRC.resident() {
		t.Fatal("打开退回之后补回的正文都退回")
	}
	if e.Lyrics.String() != "[00:01.00]阴天 在不开灯的房间" || e.LyricsYRC.String() != "[1000,500](1000,500,0)阴" {
		t.Fatal("退回之后读得回")
	}
}

// 钉住要读的旧文件读不了:返回 false、登记放回;存盘这一次不改写那份文件,文件恢复之后旧快照照样读得回。
func TestPinFailureKeepsFileAndSnapshot(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "张学友|吻别|吻别"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]前尘往事成云烟"),
		LyricsTr: bt("[00:01.00]the past turns into smoke"), LyricsSource: "qq"}})
	saveEnrichCache()
	enrichMu.Lock()
	snap := enrichCache[key]
	enrichMu.Unlock()
	path := bodySidePath(enrichBodiesDir(), key)
	before := mustRead(t, path)
	clearBodyFileCacheForTest()
	if err := os.Chmod(path, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })

	next := enrichBody{Lyrics: "[00:01.00]别的歌词"}
	if pinBodiesAt(path, &next) {
		t.Fatal("旧文件读不了时钉住要报失败")
	}
	bodyRegMu.Lock()
	n := len(bodyLocated[path])
	bodyRegMu.Unlock()
	if n == 0 {
		t.Fatal("钉不成时登记要放回去")
	}

	changed := snap
	changed.Lyrics = bt("[00:01.00]别的歌词")
	putEntriesForTest(map[string]enrichEntry{key: changed})
	saveEnrichCache()
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(mustRead(t, path), before) {
		t.Fatal("钉不成的那份小文件这一次不该被改写")
	}
	clearBodyFileCacheForTest()
	if snap.Lyrics.String() != "[00:01.00]前尘往事成云烟" || snap.LyricsTr.String() != "[00:01.00]the past turns into smoke" {
		t.Fatal("文件恢复之后旧快照读得回")
	}
}

// 退回的正文读不回来:load 报错,条目整份编码失败,不把空串写下去。
func TestUnreadableBodyFailsMarshal(t *testing.T) {
	withBodyEviction(t)
	path := filepath.Join(t.TempDir(), "gone.json")
	writeBodyFileForTest(t, path, enrichBody{Lyrics: "[00:01.00]读不回来的那份"})
	lyr := bt("[00:01.00]读不回来的那份")
	locateBody(lyr, path, bodyFieldLyrics)
	clearBodyFileCacheForTest()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := lyr.load(); err == nil {
		t.Fatal("读不回来要报错")
	}
	if _, err := json.Marshal(enrichEntry{Lyrics: lyr}); err == nil {
		t.Fatal("读不回来时整份编码要失败")
	}
	if lyr.String() != "" {
		t.Fatal("String 读不回来是空串")
	}
}

// 导出时有一份正文读不回来:整轮不导出,已有的文件一个都不动。
func TestExportSkipsRoundOnUnreadableBody(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	lyricsDir := t.TempDir()
	saved := lyricsDirValue.Load()
	setLyricsDir(lyricsDir)
	t.Cleanup(func() { lyricsDirValue.Store(saved) })
	const key = "林忆莲|至少还有你|林忆莲's"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]我怕来不及"), LyricsTr: bt("[00:01.00]afraid"),
		LyricsSource: "qq"}})
	saveEnrichCache()
	exportLyricsFilesMatching(nil)
	names := func() []string {
		es, _ := os.ReadDir(lyricsDir)
		var out []string
		for _, e := range es {
			out = append(out, e.Name())
		}
		return out
	}
	exported := names()
	if len(exported) == 0 {
		t.Fatal("先导出一份")
	}
	path := bodySidePath(enrichBodiesDir(), key)
	clearBodyFileCacheForTest()
	if err := os.Chmod(path, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
	exportLyricsFilesMatching(nil)
	if got := names(); !reflect.DeepEqual(got, exported) {
		t.Fatalf("读不回来时整轮不导出,文件不该少: %v → %v", exported, got)
	}
}

// 小文件缓存按最近用过挤:命中过的那份不会被后来读的挤掉。
func TestBodyFileCacheKeepsRecentlyUsed(t *testing.T) {
	clearBodyFileCacheForTest()
	t.Cleanup(clearBodyFileCacheForTest)
	hot := &enrichBody{CRC: 1, Lyrics: "hot"}
	rememberBodyFile("/hot", hot)
	for i := 0; i < bodyFileCacheSize*2; i++ {
		if cachedBodyFile("/hot") != hot {
			t.Fatalf("第 %d 次读之前在放那份被挤掉了", i)
		}
		rememberBodyFile(fmt.Sprintf("/cold-%d", i), &enrichBody{CRC: 2})
	}
}

// 新内容自己拼得出来、但旧快照退回在这份文件里而文件读不了:钉住失败,这一次不改写。
func TestSaveSkipsWriteWhenPinFails(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "李宗盛|山丘|山丘"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]想说却还没说的"), LyricsSource: "qq"}})
	saveEnrichCache()
	enrichMu.Lock()
	snap := enrichCache[key]
	enrichMu.Unlock()
	path := bodySidePath(enrichBodiesDir(), key)
	before := mustRead(t, path)
	changed := snap
	changed.Lyrics = bt("[00:01.00]越过山丘")
	clearBodyFileCacheForTest()
	if err := os.Chmod(path, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
	putEntriesForTest(map[string]enrichEntry{key: changed})
	saveEnrichCache()
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(mustRead(t, path), before) {
		t.Fatal("钉不成时这一次不改写小文件")
	}
	clearBodyFileCacheForTest()
	if snap.Lyrics.String() != "[00:01.00]想说却还没说的" {
		t.Fatal("旧快照读得回")
	}
}

// 清孤儿文件时钉不成(文件读不了):这份先不删。
func TestSweepKeepsFileWhenPinFails(t *testing.T) {
	withTempLeanCache(t)
	withBodyEviction(t)
	const key = "陈奕迅|十年|黑白灰"
	putEntriesForTest(map[string]enrichEntry{key: {Lyrics: bt("[00:01.00]如果那两个字没有颤抖"), LyricsSource: "qq"}})
	saveEnrichCache()
	enrichMu.Lock()
	snap := enrichCache[key]
	delete(enrichCache, key)
	enrichMu.Unlock()
	path := bodySidePath(enrichBodiesDir(), key)
	clearBodyFileCacheForTest()
	if err := os.Chmod(path, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
	sweepKeyedDir(enrichBodiesDir(), "lyrics bodies")
	if _, err := os.Lstat(path); err != nil {
		t.Fatal("钉不成时孤儿文件先留着")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	clearBodyFileCacheForTest()
	if snap.Lyrics.String() != "[00:01.00]如果那两个字没有颤抖" {
		t.Fatal("留着的文件里读得回")
	}
}
