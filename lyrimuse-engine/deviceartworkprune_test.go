package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// withTempArtworkPrune 把设备封面目录、缓存、配置目录、待采纳恢复文件都换成临时的,返回 (配置目录, 封面目录)。
func withTempArtworkPrune(t *testing.T) (string, string) {
	t.Helper()
	cfgDir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", cfgDir)
	artDir := filepath.Join(cfgDir, "artwork")
	if err := os.MkdirAll(artDir, 0o755); err != nil {
		t.Fatal(err)
	}
	savedDir, savedRestore := deviceArtworkDir, enrichRestorePath
	savedPath, savedCache, savedDirty := enrichPath, enrichCache, enrichDirty
	t.Cleanup(func() {
		deviceArtworkDir, enrichRestorePath = savedDir, savedRestore
		enrichMu.Lock()
		enrichPath, enrichCache, enrichDirty = savedPath, savedCache, savedDirty
		enrichMu.Unlock()
	})
	deviceArtworkDir = artDir
	enrichRestorePath = filepath.Join(cfgDir, clientName+"-enrich-restore.json")
	enrichMu.Lock()
	enrichPath = filepath.Join(cfgDir, clientName+"-enrich-cache.json")
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	return cfgDir, artDir
}

// writeArtwork 在封面目录里放一个文件,修改时间往前拨 age。
func writeArtwork(t *testing.T, dir, name string, age time.Duration) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(name), 0o644); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-age)
	if err := os.Chtimes(path, at, at); err != nil {
		t.Fatal(err)
	}
	return path
}

func artworkExists(dir, name string) bool {
	_, err := os.Stat(filepath.Join(dir, name))
	return err == nil
}

const (
	artA = "aaaaaaaaaaaaaaaa.jpg"
	artB = "bbbbbbbbbbbbbbbb.jpg"
	artC = "cccccccccccccccc.png"
	artD = "dddddddddddddddd.jpg"
	artE = "eeeeeeeeeeeeeeee.jpg"
	artF = "ffffffffffffffff.jpg"
	artG = "0123456789abcdef.jpg"
)

// 只删没人引用、7 天以上没用过、名字是设备封面的那些。缓存里任何字段引用的(封面、按专辑定下的封面、
// 动态封面核对的是哪张)、歌曲实体同步留底里的、正在播那一条快照里的都留着。
func TestPruneDeviceArtworkKeepsEveryReference(t *testing.T) {
	_, art := withTempArtworkPrune(t)
	old := 30 * 24 * time.Hour
	for _, n := range []string{artA, artB, artC, artD, artE, artF, "notes.txt", "abcd.jpg"} {
		writeArtwork(t, art, n, old)
	}
	writeArtwork(t, art, artG, time.Hour)
	url := func(n string) string { return "file://" + filepath.Join(art, n) }
	enrichMu.Lock()
	enrichCache["A|a|x"] = enrichEntry{CoverURL: url(artA)}
	enrichCache["B|b|x"] = enrichEntry{CoverURL: "https://p1.music.126.net/x.jpg", CoverSettled: url(artB)}
	enrichCache["C|c|x"] = enrichEntry{CoverURL: "https://p1.music.126.net/y.jpg", MotionCoverFor: url(artC)}
	enrichMu.Unlock()
	pre := songSharePreDir()
	if err := os.MkdirAll(pre, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pre, "k.json"), []byte(`{"entry":{"cover_url":"`+url(artD)+`"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(playingEntryPathFor(enrichPath), []byte(`{"key":"E|e|x","entry":{"cover_url":"`+url(artE)+`"}}`), 0o644); err != nil {
		t.Fatal(err)
	}

	cleared, removed := pruneDeviceArtworkIfDue(time.Now())
	if cleared != 0 || removed != 1 {
		t.Fatalf("cleared=%d removed=%d,只该删 %s", cleared, removed, artF)
	}
	if artworkExists(art, artF) {
		t.Fatal("没人引用、一个月没用过的要删")
	}
	for _, n := range []string{artA, artB, artC, artD, artE, artG, "notes.txt", "abcd.jpg"} {
		if !artworkExists(art, n) {
			t.Fatalf("%s 不该删", n)
		}
	}
	if !artworkExists(art, deviceArtworkPruneStamp) {
		t.Fatal("跑完要记下这一轮的时间")
	}
}

// 一天最多跑一次。
func TestPruneDeviceArtworkRunsOncePerDay(t *testing.T) {
	_, art := withTempArtworkPrune(t)
	now := time.Now()
	pruneDeviceArtworkIfDue(now)
	writeArtwork(t, art, artF, 30*24*time.Hour)
	if _, removed := pruneDeviceArtworkIfDue(now.Add(time.Hour)); removed != 0 || !artworkExists(art, artF) {
		t.Fatal("上一轮不到一天,这次不跑")
	}
	if _, removed := pruneDeviceArtworkIfDue(now.Add(25 * time.Hour)); removed != 1 || artworkExists(art, artF) {
		t.Fatal("过了一天照常跑")
	}
}

// 待采纳的恢复文件还在时不跑:那份里的路径还没进缓存。
func TestPruneDeviceArtworkWaitsForPendingRestore(t *testing.T) {
	_, art := withTempArtworkPrune(t)
	writeArtwork(t, art, artF, 30*24*time.Hour)
	if err := os.WriteFile(enrichRestorePath, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, removed := pruneDeviceArtworkIfDue(time.Now()); removed != 0 || !artworkExists(art, artF) {
		t.Fatal("恢复文件还没采纳,不删")
	}
	if artworkExists(art, deviceArtworkPruneStamp) {
		t.Fatal("没跑就不记时间,采纳之后下次启动照常跑")
	}
}

// 封面、按专辑定下的封面、视频帧指向本机没有的设备封面时清空(配置搬家带来的别处路径也算);本机有的、网络地址、
// 「对着哪张封面核的」那几个记录字段不动。
func TestPruneDeviceArtworkClearsMissingCovers(t *testing.T) {
	_, art := withTempArtworkPrune(t)
	writeArtwork(t, art, artA, time.Hour)
	here := "file://" + filepath.Join(art, artA)
	gone := "file://" + filepath.Join(art, artB)
	elsewhere := "file:///Users/someone-else/.config/lyrimuse/artwork/" + artC
	enrichMu.Lock()
	enrichCache["A|a|x"] = enrichEntry{CoverURL: gone, CoverSource: "device", CoverAlbum: "Album", AccentColor: "#112233",
		CoverSettled: elsewhere, VideoFrameURL: gone, MotionCoverFor: gone}
	enrichCache["B|b|x"] = enrichEntry{CoverURL: here, CoverSettled: "https://p1.music.126.net/x.jpg"}
	enrichCache["C|c|x"] = enrichEntry{CoverURL: "file:///tmp/not-artwork/" + artD}
	enrichMu.Unlock()

	cleared, _ := pruneDeviceArtworkIfDue(time.Now())
	if cleared != 1 {
		t.Fatalf("cleared=%d,只有一条要改", cleared)
	}
	enrichMu.Lock()
	a, b := enrichCache["A|a|x"], enrichCache["B|b|x"]
	enrichMu.Unlock()
	if a.CoverURL != "" || a.CoverSettled != "" || a.VideoFrameURL != "" {
		t.Fatalf("指向不存在的设备封面要清空: %+v", a)
	}
	if a.CoverSource != "" || a.CoverAlbum != "" || a.AccentColor != "" {
		t.Fatalf("封面那张没了,来源、专辑、主色一起清(留着 device 放歌时不再取设备封面): %+v", a)
	}
	if a.MotionCoverFor != gone {
		t.Fatal("核对记录字段不动:封面换了它自然作废")
	}
	if b.CoverURL != here || b.CoverSettled != "https://p1.music.126.net/x.jpg" {
		t.Fatalf("本机有的、网络地址不动: %+v", b)
	}
	enrichMu.Lock()
	c := enrichCache["C|c|x"]
	enrichMu.Unlock()
	if c.CoverURL == "" {
		t.Fatal("不在 artwork 目录下的 file:// 地址不是设备封面,不动")
	}
	if !artworkExists(art, artA) {
		t.Fatal("还在用的图不删")
	}
}

// 复用已有的图时刷新修改时间,清理靠它判这张图多久没用过。
func TestSaveDeviceArtworkTouchesReusedFile(t *testing.T) {
	withTempArtworkPrune(t)
	data := makeTestJPEG(t, 8, 8)
	url, ok := saveDeviceArtwork(data, "image/jpeg")
	if !ok {
		t.Fatal("落盘失败")
	}
	_, path, _ := deviceArtworkRef(url)
	old := time.Now().Add(-30 * 24 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if again, ok := saveDeviceArtwork(data, "image/jpeg"); !ok || again != url {
		t.Fatal("同一张图复用同一个文件")
	}
	info, err := os.Stat(path)
	if err != nil || time.Since(info.ModTime()) > time.Hour {
		t.Fatal("复用时要刷新修改时间")
	}
}

func TestCollectDeviceArtworkRefs(t *testing.T) {
	refs := map[string]bool{}
	collectDeviceArtworkRefs([]byte(`{"a":"file:///x/artwork/`+artA+`","b":"/artwork/notes.txt","c":"/artwork/`+artC+`\"}`), refs)
	if !refs[artA] || !refs[artC] || len(refs) != 2 {
		t.Fatalf("refs=%v", refs)
	}
}
