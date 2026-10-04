package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// 客户端本地缓存那几条快速路径的加固:「读得到」只在真读成功之后发布、读失败不把库版本记死、
// 酷狗宽松匹配不吞版本限定词、Apple Music 时长未知时不乱挑、预算从最新的文件花起。

// resetLocalCacheAccessForTest 把可读性状态清零、状态文件指到临时目录,返回读状态文件的函数
// (文件还没写过时返回零值)。
func resetLocalCacheAccessForTest(t *testing.T) func() localCacheAccessState {
	t.Helper()
	prevOut := log.Writer()
	log.SetOutput(io.Discard)
	t.Cleanup(func() { log.SetOutput(prevOut) })
	path := filepath.Join(t.TempDir(), "access.json")
	setLocalCacheAccessPath(path)
	t.Cleanup(func() { setLocalCacheAccessPath("") })
	localCacheDeniedMu.Lock()
	localCacheDeniedReported = map[string]string{}
	localCacheDeniedNow = map[string]bool{}
	localCacheReadableNow = map[string]bool{}
	localCacheDeniedMu.Unlock()
	return func() localCacheAccessState {
		t.Helper()
		var st localCacheAccessState
		raw, err := os.ReadFile(path)
		if err != nil {
			return st
		}
		if err := json.Unmarshal(raw, &st); err != nil {
			t.Fatalf("状态文件解不开: %v", err)
		}
		return st
	}
}

// chmodUnreadable 把文件改成读不了(stat 照样过,跟没授权时 TCC 的形态一样),测试结束改回来。
func chmodUnreadable(t *testing.T, path string) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root 读得了 000 的文件,模拟不出「stat 过、读被拒」")
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
}

// 没授权的机器上 stat 能过、读被拒:以前 stat 一过就发布「读得到」,把启动探测记下的「被拒」盖掉,
// 设置页据此显示「已授权」。现在要真读成功才算;授权之后(文件读得了)下一次重建能自己恢复,
// 不因为上一次失败时记下的库版本而一直不重试。
func TestQQLocalDeniedReadStaysDenied(t *testing.T) {
	read := resetLocalCacheAccessForTest(t)
	path := writeTestQQDB(t, qqLocalTestRows)
	resetQQLocalIndex(t, path)
	noteLocalCacheDenied("qq", path, &fs.PathError{Op: "open", Path: path, Err: syscall.EPERM})
	chmodUnreadable(t, path)

	if _, ok := qqLocalMatch(context.Background(), "周杰伦", "晴天", "", 269); ok {
		t.Fatal("读不了库时不该命中")
	}
	st := read()
	if !slices.Contains(st.Denied, "qq") || slices.Contains(st.Readable, "qq") {
		t.Fatalf("stat 过了但读被拒,应当仍是被拒: denied=%v readable=%v", st.Denied, st.Readable)
	}
	qqLocalMu.Lock()
	recorded := !qqLocalDBMod.IsZero()
	qqLocalMu.Unlock()
	if recorded {
		t.Fatal("读失败时不该记下库版本,不然直到库再变都不会重试")
	}
	// 中途也不能闪一下「读得到」:那会撤掉日志去重,每次重建都再打一行「macOS is refusing」、状态文件来回写。
	var buf bytes.Buffer
	log.SetOutput(&buf)
	for i := 0; i < 3; i++ {
		qqLocalMu.Lock()
		qqLocalScanned = time.Time{}
		qqLocalMu.Unlock()
		qqLocalMatch(context.Background(), "周杰伦", "晴天", "", 269)
	}
	log.SetOutput(io.Discard)
	if n := strings.Count(buf.String(), "macOS is refusing"); n != 0 {
		t.Fatalf("同一种拒绝已经报过,重试时不该再报(每次再报说明中途被撤成过读得到): %d 行", n)
	}

	// 授权之后:库没变(mtime 不动),过了节流窗口就该重建成功,并撤掉「被拒」。
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	qqLocalMu.Lock()
	qqLocalScanned = time.Time{}
	qqLocalMu.Unlock()
	if _, ok := qqLocalMatch(context.Background(), "周杰伦", "晴天", "", 269); !ok {
		t.Fatal("读得了之后应当命中")
	}
	st = read()
	if slices.Contains(st.Denied, "qq") || !slices.Contains(st.Readable, "qq") {
		t.Fatalf("真读成功后应当是读得到: denied=%v readable=%v", st.Denied, st.Readable)
	}
}

// 网易云同一形态:以前每首歌在「被拒」(队列 ReadFile)和「读得到」(曲库 stat)之间翻一次。
func TestNeteaseLocalDeniedReadStaysDenied(t *testing.T) {
	read := resetLocalCacheAccessForTest(t)
	path := writeTestNeteaseDB(t, neteaseLocalTestTracks)
	resetNeteaseLocalIndex(t, path)
	noteLocalCacheDenied("netease", path, &fs.PathError{Op: "open", Path: path, Err: syscall.EPERM})
	chmodUnreadable(t, path)

	if _, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "", 207); ok {
		t.Fatal("读不了库时不该命中")
	}
	if st := read(); !slices.Contains(st.Denied, "netease") || slices.Contains(st.Readable, "netease") {
		t.Fatalf("应当仍是被拒: denied=%v readable=%v", st.Denied, st.Readable)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	neteaseLocalMu.Lock()
	neteaseLocalScanned = time.Time{}
	neteaseLocalMu.Unlock()
	if _, ok := neteaseLocalSong(context.Background(), "毛不易", "像我这样的人", "", 207); !ok {
		t.Fatal("读得了之后应当命中")
	}
	if st := read(); slices.Contains(st.Denied, "netease") || !slices.Contains(st.Readable, "netease") {
		t.Fatalf("真读成功后应当是读得到: denied=%v readable=%v", st.Denied, st.Readable)
	}
}

// noteLocalCacheReadFailure 只认「被系统拒了」:文件读得了(是锁 / 表结构这类原因)、文件不在,都不动状态。
func TestNoteLocalCacheReadFailureClassifies(t *testing.T) {
	read := resetLocalCacheAccessForTest(t)
	dir := t.TempDir()
	ok := filepath.Join(dir, "ok.sqlite")
	if err := os.WriteFile(ok, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	noteLocalCacheReadFailure("qq", ok)
	noteLocalCacheReadFailure("qq", filepath.Join(dir, "missing.sqlite"))
	if st := read(); len(st.Denied) != 0 {
		t.Fatalf("读得了 / 不存在都不该记成被拒: %v", st.Denied)
	}
	chmodUnreadable(t, ok)
	noteLocalCacheReadFailure("qq", ok)
	if st := read(); !slices.Contains(st.Denied, "qq") {
		t.Fatalf("读被拒要记成被拒: %v", st.Denied)
	}
}

// 经子进程读的那几个入口都要在失败时补一次分类,且「读得到」只在子进程成功之后才发布。
func TestSubprocessLocalCacheReadsClassifyFailures(t *testing.T) {
	for _, w := range []struct {
		file, source string
		sites        int
	}{
		{"qqlocal.go", "qq", 2},             // 曲库 sqlite3 + 队列 plutil
		{"neteaselocal.go", "netease", 1},   // 曲库 sqlite3
		{"kugoulocal.go", "kugou", 1},       // 旧队列库 sqlite3
		{"kugouqueue.go", "kugou", 2},       // 队列 plutil + 曲库 sqlite3
		{"kugoulyricartist.go", "kugou", 1}, // 当前曲目 plutil
	} {
		raw, err := os.ReadFile(w.file)
		if err != nil {
			t.Fatal(err)
		}
		needle := `noteLocalCacheReadFailure("` + w.source + `"`
		if got := strings.Count(string(raw), needle); got != w.sites {
			t.Errorf("%s 里子进程读失败的分类入口是 %d 个,应为 %d", w.file, got, w.sites)
		}
	}
	for _, w := range []struct{ file, read, readable string }{
		{"qqlocal.go", "queryQQLocalSongs(ctx, path)", `noteLocalCacheReadable("qq")`},
		{"neteaselocal.go", "queryNeteaseLocalTracks(ctx, path)", `noteLocalCacheReadable("netease")`},
	} {
		raw, err := os.ReadFile(w.file)
		if err != nil {
			t.Fatal(err)
		}
		s := string(raw)
		if q, r := strings.Index(s, w.read), strings.Index(s, w.readable); q < 0 || r < q {
			t.Errorf("%s:「读得到」必须在 %s 之后才发布", w.file, w.read)
		}
	}
}

// testKRCBody 造一份跟客户端落盘同形的 KRC 正文(标签 + 两行逐字),最后一行从 lastMs 开始。
func testKRCBody(artist, title, album string, lastMs int) string {
	return "[ar:" + artist + "]\n[ti:" + title + "]\n[al:" + album + "]\n[total:0]\n[offset:0]\n" +
		"[1000,1000]<0,500,0>第<500,500,0>一\n" +
		"[" + strconv.Itoa(lastMs) + ",1000]<0,500,0>最<500,500,0>后"
}

// 宽松匹配把「(Live)」「(伴奏)」当副标题会拿另一次录音的逐字轴顶上,而本地命中之后网络那条整个不问。
// 版本限定词两边对不上就不命中;真副标题照样命中,但宽松命中不拿「本地客户端」的同源加权。
func TestKugouLocalLooseMatchVersionAndWeight(t *testing.T) {
	dir := t.TempDir()
	writeTestKRC(t, dir, "live.krc", testKRCBody("周深", "大梦 (Live)", "某演唱会", 30000))
	writeTestKRC(t, dir, "sub.krc", testKRCBody("BY2", "我知道(电视剧《比赛开始》片尾曲)", "专辑", 30000))
	writeTestKRC(t, dir, "exact.krc", testKRCBody("周杰伦", "搁浅", "七里香", 30000))
	resetKugouLocalIndex(t, dir)

	if r, ok := kugouLocalLyric("周深", "大梦", "", 0); ok {
		t.Fatalf("Live 版不该顶替录音室版: %q", r.title)
	}
	r, ok := kugouLocalLyric("BY2", "我知道", "", 0)
	if !ok {
		t.Fatal("真副标题应当宽松命中")
	}
	if r.fromLocalClient {
		t.Error("宽松命中不该拿本地客户端的同源加权")
	}
	r, ok = kugouLocalLyric("周杰伦", "搁浅", "七里香", 0)
	if !ok || !r.fromLocalClient {
		t.Fatalf("精确命中应当带同源加权: ok=%v fromLocalClient=%v", ok, r.fromLocalClient)
	}
}

// 本地 KRC 没有可信时长,只能拿最后一句挡「歌词比歌还长」的另一个版本。
func TestKugouLocalLyricFitsDuration(t *testing.T) {
	for _, c := range []struct {
		lrc  string
		dur  float64
		want bool
	}{
		{"[00:01.00]a\n[04:10.00]b", 240, true},  // 250 ≤ 240+28.8
		{"[00:01.00]a\n[04:10.00]b", 200, false}, // 250 > 200+24
		{"[00:01.00]a\n[04:10.00]b", 0, true},    // 时长未知不判
		{"没有时间戳", 100, true},
		{"[00:01.00]a\n[00:40.00]b", 30, false}, // 短曲:余量取 5 秒
		{"[00:01.00]a\n[00:34.00]b", 30, true},
	} {
		if got := kugouLocalLyricFitsDuration(c.lrc, c.dur); got != c.want {
			t.Errorf("kugouLocalLyricFitsDuration(%q, %v) = %v, want %v", c.lrc, c.dur, got, c.want)
		}
	}
	dir := t.TempDir()
	writeTestKRC(t, dir, "a.krc", testKRCBody("周杰伦", "搁浅", "七里香", 200000))
	resetKugouLocalIndex(t, dir)
	if _, ok := kugouLocalLyric("周杰伦", "搁浅", "", 120); ok {
		t.Error("歌词最后一句在 200 秒,播放器报 120 秒:不该命中")
	}
	if _, ok := kugouLocalLyric("周杰伦", "搁浅", "", 230); !ok {
		t.Error("时长对得上应当命中")
	}
}

// 重扫只解密新增 / 变过的文件:没变的沿用上一轮的解析结果,变了的重解,删掉的从记忆里清掉。
func TestKugouLocalRescanReusesUnchangedFiles(t *testing.T) {
	dir := t.TempDir()
	path := writeTestKRC(t, dir, "a.krc", testKRCBody("周杰伦", "搁浅", "七里香", 30000))
	resetKugouLocalIndex(t, dir)
	if _, ok := kugouLocalLyric("周杰伦", "搁浅", "", 0); !ok {
		t.Fatal("首次扫描应当命中")
	}
	bumps := 0
	rescan := func() {
		t.Helper()
		bumps++
		later := time.Now().Add(time.Duration(bumps) * time.Hour)
		if err := os.Chtimes(dir, later, later); err != nil {
			t.Fatal(err)
		}
		kugouLocalMu.Lock()
		kugouLocalScanned = time.Time{}
		refreshKugouLocalIndexLocked()
		kugouLocalMu.Unlock()
	}
	// 往记忆里改一笔:文件没变就该原样沿用,不重新解密 —— 索引里出现的是改过的那个名字。
	kugouLocalMu.Lock()
	f := kugouLocalFiles[path]
	f.entry.title = "记忆里的名字"
	kugouLocalFiles[path] = f
	kugouLocalMu.Unlock()
	rescan()
	kugouLocalMu.Lock()
	_, reused := kugouLocalIndex[kugouLocalKey("周杰伦", "记忆里的名字")]
	kugouLocalMu.Unlock()
	if !reused {
		t.Fatal("文件没变时应当沿用上一轮的解析结果")
	}
	// 文件变了(mtime 动了):重新解密,回到文件里的真名字。
	later := time.Now().Add(48 * time.Hour)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	rescan()
	kugouLocalMu.Lock()
	_, fresh := kugouLocalIndex[kugouLocalKey("周杰伦", "搁浅")]
	kugouLocalMu.Unlock()
	if !fresh {
		t.Fatal("文件变了应当重新解密")
	}
	// 删掉:索引与记忆一起清掉。
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	rescan()
	kugouLocalMu.Lock()
	_, stillIndexed := kugouLocalIndex[kugouLocalKey("周杰伦", "搁浅")]
	_, stillRemembered := kugouLocalFiles[path]
	kugouLocalMu.Unlock()
	if stillIndexed || stillRemembered {
		t.Fatalf("删掉的文件不该留在索引 / 记忆里: indexed=%v remembered=%v", stillIndexed, stillRemembered)
	}
}

func appleLocalEntryFor(album string, ms int) applemusicLocalEntry {
	var e applemusicLocalEntry
	e.song.Attributes.Name = "同名歌"
	e.song.Attributes.ArtistName = "某歌手"
	e.song.Attributes.AlbumName = album
	e.song.Attributes.DurationInMillis = ms
	return e
}

// 播放器还没报时长时时长闸全放行,挑哪条只剩文件顺序:多于一条就只认专辑对得上的唯一那条。
func TestPickApplemusicLocalEntryUnknownDuration(t *testing.T) {
	two := []applemusicLocalEntry{appleLocalEntryFor("演唱会", 300000), appleLocalEntryFor("录音室", 240000)}
	if _, ok := pickApplemusicLocalEntry(two, "", 0); ok {
		t.Error("时长未知、两条候选、没有专辑可认:不该命中")
	}
	if e, ok := pickApplemusicLocalEntry(two, "录音室", 0); !ok || e.song.Attributes.AlbumName != "录音室" {
		t.Errorf("专辑对得上的唯一那条应当命中: ok=%v album=%q", ok, e.song.Attributes.AlbumName)
	}
	if _, ok := pickApplemusicLocalEntry(two[:1], "", 0); !ok {
		t.Error("只有一条候选时时长未知照常命中")
	}
	if e, ok := pickApplemusicLocalEntry(two, "演唱会", 240); !ok || e.song.Attributes.AlbumName != "录音室" {
		t.Errorf("时长已知时时长闸先挡掉现场版: ok=%v album=%q", ok, e.song.Attributes.AlbumName)
	}
	three := append(two, appleLocalEntryFor("演唱会", 300000))
	if _, ok := pickApplemusicLocalEntry(three, "演唱会", 0); ok {
		t.Error("专辑对得上的不止一条时同样认不出,不该命中")
	}
}

// 读入预算从最新的文件花起:要找的恰恰是刚写进来的那一份,按文件名(UUID)顺序花会把它挤到预算之外。
func TestApplemusicLocalBudgetSpendsNewestFirst(t *testing.T) {
	dir := writeAppleLocalCache(t, []appleLocalSpec{
		{ID: "701", Name: "旧的", Rels: map[string]string{"syllable-lyrics": appleLocalTTML("", nil)}},
		{ID: "702", Name: "新的", Rels: map[string]string{"syllable-lyrics": appleLocalTTML("", nil)}},
	})
	now := time.Now()
	for name, age := range map[string]time.Duration{"entrya": 2 * time.Hour, "entryb": time.Hour, "artwork.bin": 3 * time.Hour} {
		at := now.Add(-age)
		if err := os.Chtimes(filepath.Join(dir, name), at, at); err != nil {
			t.Fatal(err)
		}
	}
	st, err := os.Stat(filepath.Join(dir, "entryb"))
	if err != nil {
		t.Fatal(err)
	}
	saved := applemusicLocalMaxTotalBytes
	applemusicLocalMaxTotalBytes = st.Size()
	t.Cleanup(func() { applemusicLocalMaxTotalBytes = saved })
	resetAppleLocalIndex(t, dir)
	if _, ok := applemusicLocalLyric("702", "", "", "", 0); !ok {
		t.Error("预算只够一份时,最新的那份应当读到")
	}
	if _, ok := applemusicLocalLyric("701", "", "", "", 0); ok {
		t.Error("预算花完之后更旧的那份不该再读")
	}
}

// 汽水:队列文件解不开(客户端正写到一半)时不记文件版本,下一次照样重读。
func TestSodaLocalDecodeFailureDoesNotRecordVersion(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "QueueCache")
	if err := os.WriteFile(path, []byte("LUNA not gzip"), 0o644); err != nil {
		t.Fatal(err)
	}
	resetSodaLocalIndex(t, path)
	sodaLocalInstrumental("歌手", "歌", "", 0)
	sodaLocalMu.Lock()
	recorded := !sodaLocalMod.IsZero()
	sodaLocalMu.Unlock()
	if recorded {
		t.Fatal("解不开时不该记下文件版本")
	}
	good := writeTestSodaQueue(t, nil)
	raw, err := os.ReadFile(good)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	sodaLocalMu.Lock()
	sodaLocalScanned = time.Time{}
	sodaLocalMu.Unlock()
	sodaLocalInstrumental("歌手", "歌", "", 0)
	sodaLocalMu.Lock()
	recorded = !sodaLocalMod.IsZero()
	sodaLocalMu.Unlock()
	if !recorded {
		t.Fatal("解析成功之后应当记下文件版本")
	}
}
