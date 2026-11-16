package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 合成一个跟酷我客户端落盘形态一致的 .lrcx:`utf8` 行 + 正文异或 yeelion 后去掉 `=` 的 base64 + offset 行(带 NUL 填充)。
// 用合成数据:真文件是用户自己的听歌记录,不进仓库。
func writeTestKuwoLrcx(t *testing.T, dir, name, text string, mod time.Time) string {
	t.Helper()
	data := []byte(text)
	key := []byte(kuwoLrcxKey)
	for i := range data {
		data[i] ^= key[i%len(key)]
	}
	b64 := strings.TrimRight(base64.StdEncoding.EncodeToString(data), "=")
	raw := "utf8\r\n" + b64 + "\r\noffset=0\x00\x00\x00"
	return writeTestKuwoFile(t, dir, name, raw, mod)
}

func writeTestKuwoFile(t *testing.T, dir, name, raw string, mod time.Time) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	if !mod.IsZero() {
		if err := os.Chtimes(path, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

const testKuwoLrcxText = "[kuwo:071]\n[ver:v1.0]\n[ti:漫步人生路]\n[ar:邓丽君]\n[al:177031]\n[offset:0]\n" +
	"[00:01.000]<0,0>前奏\n" +
	"[00:12.500]<1183,-1183>在<2231,-541>你\n" +
	"[00:20.000]<1183,-1183>身<2231,-541>边\n"

func resetKuwoLocalIndex(t *testing.T, dir string) {
	t.Helper()
	reset := func() {
		kuwoLocalMu.Lock()
		kuwoLocalIndex, kuwoLocalReady, kuwoLocalScanned, kuwoLocalDirMod = nil, false, time.Time{}, time.Time{}
		kuwoLocalMu.Unlock()
	}
	reset()
	old := kuwoLocalDirOverride
	kuwoLocalDirOverride = dir
	t.Cleanup(func() {
		kuwoLocalDirOverride = old
		reset()
	})
}

func TestKuwoDecodeLocalLrcx(t *testing.T) {
	dir := t.TempDir()
	path := writeTestKuwoLrcx(t, dir, "x.lrcx", testKuwoLrcxText, time.Time{})
	raw, _ := os.ReadFile(path)
	got, ok := kuwoDecodeLocalLrcx(raw)
	if !ok || got != testKuwoLrcxText {
		t.Fatalf("解开结果不对: ok=%v %q", ok, got)
	}
	// 只有两段(没有 offset 行)的也要解得开。
	two := strings.SplitN(string(raw), "\r\noffset", 2)[0]
	if got, ok := kuwoDecodeLocalLrcx([]byte(two)); !ok || got != testKuwoLrcxText {
		t.Fatalf("两段的解开不对: ok=%v %q", ok, got)
	}
	// 真文件去掉了 base64 末尾的 `=`:正文长度不是 3 的倍数时也要解得开。
	for _, extra := range []string{"\n", "\n\n"} {
		text := testKuwoLrcxText + extra
		raw, _ := os.ReadFile(writeTestKuwoLrcx(t, dir, "pad.lrcx", text, time.Time{}))
		if got, ok := kuwoDecodeLocalLrcx(raw); !ok || got != text {
			t.Fatalf("去掉填充的解开不对(多 %d 字节): ok=%v", len(extra), ok)
		}
	}
	for _, bad := range []string{"", "utf8", "utf8\r\n", "gbk\r\nAAAA", "utf8\r\n%%%%", "<html>blocked</html>"} {
		if _, ok := kuwoDecodeLocalLrcx([]byte(bad)); ok {
			t.Errorf("%q 不该解得开", bad)
		}
	}
}

func TestKuwoLrcxToLRCDropsWordMarks(t *testing.T) {
	got := kuwoLrcxToLRC(testKuwoLrcxText)
	want := "[00:01.000]前奏\n[00:12.500]在你\n[00:20.000]身边"
	if got != want {
		t.Fatalf("got %q\nwant %q", got, want)
	}
	if got := kuwoLrcxToLRC("[ti:x]\n[00:01.000]<0,0>\n"); got != "" {
		t.Fatalf("没有一句正文时该返回空串,得到 %q", got)
	}
}

func TestKuwoLocalLyricExactHit(t *testing.T) {
	dir := t.TempDir()
	resetKuwoLocalIndex(t, dir)
	writeTestKuwoLrcx(t, dir, "邓丽君 - 漫步人生路 - 6680.lrcx", testKuwoLrcxText, time.Time{})
	writeTestKuwoFile(t, dir, "随便 - 什么.txt", "x", time.Time{})

	r, ok := kuwoLocalLyric("邓丽君", "漫步人生路", 200)
	if !ok {
		t.Fatal("文件名精确对上该命中")
	}
	if !r.fromLocalClient || r.rid != "6680" || r.title != "漫步人生路" || r.artist != "邓丽君" {
		t.Fatalf("命中结果不对: %+v", r)
	}
	if !strings.Contains(r.lyrics, "[00:12.500]在你") || r.yrc == "" {
		t.Fatalf("逐行或逐字不对: lrc=%q yrc=%q", r.lyrics, r.yrc)
	}
	if song, album := kuwoPlayingSongIDs("邓丽君", "漫步人生路"); song != "6680" || album != "177031" {
		t.Fatalf("曲目 id / 专辑 id 不对: %q %q", song, album)
	}
	if _, ok := kuwoLocalLyric("邓丽君", "甜蜜蜜", 200); ok {
		t.Fatal("没有这首不该命中")
	}
}

func TestKuwoLocalLyricNewestVersionWins(t *testing.T) {
	dir := t.TempDir()
	resetKuwoLocalIndex(t, dir)
	old := time.Now().Add(-time.Hour)
	writeTestKuwoLrcx(t, dir, "邓丽君 - 漫步人生路 - 111.lrcx", testKuwoLrcxText, old)
	writeTestKuwoLrcx(t, dir, "邓丽君 - 漫步人生路 - 222.lrcx", testKuwoLrcxText, time.Now())
	if r, ok := kuwoLocalLyric("邓丽君", "漫步人生路", 0); !ok || r.rid != "222" {
		t.Fatalf("该取最近写的那份: ok=%v rid=%q", ok, r.rid)
	}
}

func TestKuwoLocalLyricLooseHitHasNoIdentity(t *testing.T) {
	dir := t.TempDir()
	resetKuwoLocalIndex(t, dir)
	writeTestKuwoLrcx(t, dir, "邓丽君 - 漫步人生路(电影插曲) - 333.lrcx", testKuwoLrcxText, time.Time{})
	writeTestKuwoLrcx(t, dir, "邓丽君 - 漫步人生路(电视剧《某某》片尾曲) - 444.lrcx", testKuwoLrcxText, time.Time{})
	// 版本限定词是另一次录音,宽松也不认(kugouLocalTitleMatches)。
	writeTestKuwoLrcx(t, dir, "邓丽君 - 漫步人生路(Live) - 999.lrcx", testKuwoLrcxText, time.Now().Add(time.Hour))
	r, ok := kuwoLocalLyric("邓丽君", "漫步人生路", 0)
	if !ok || r.fromLocalClient || r.rid != "333" {
		t.Fatalf("宽松命中该取歌名最接近的、且不带同源身份: ok=%v %+v", ok, r)
	}
	if song, _ := kuwoPlayingSongIDs("邓丽君", "漫步人生路"); song != "" {
		t.Fatalf("宽松命中不该记曲目 id,得到 %q", song)
	}
	if _, ok := kuwoLocalLyric("别人", "漫步人生路", 0); ok {
		t.Fatal("歌手对不上不该命中")
	}
}

func TestKuwoLocalLyricPlainLRCAndDurationGate(t *testing.T) {
	dir := t.TempDir()
	resetKuwoLocalIndex(t, dir)
	writeTestKuwoFile(t, dir, "Raidas - 吸烟的女人 - 555.lrc",
		"utf8\r\n[ti:吸烟的女人]\r\n[00:05.00]甲\r\n[03:30.00]乙\r\n", time.Time{})
	r, ok := kuwoLocalLyric("Raidas", "吸烟的女人", 230)
	if !ok || r.lyrics != "[00:05.00]甲\n[03:30.00]乙" || r.yrc != "" {
		t.Fatalf(".lrc 读法不对: ok=%v %+v", ok, r)
	}
	if song, album := kuwoPlayingSongIDs("Raidas", "吸烟的女人"); song != "555" || album != "" {
		t.Fatalf(".lrc 只有曲目 id: %q %q", song, album)
	}
	if _, ok := kuwoLocalLyric("Raidas", "吸烟的女人", 60); ok {
		t.Fatal("歌词比歌长出一大截时不该命中")
	}
}

func TestKuwoLocalMissingDirIsQuiet(t *testing.T) {
	resetKuwoLocalIndex(t, filepath.Join(t.TempDir(), "nope"))
	if _, ok := kuwoLocalLyric("邓丽君", "漫步人生路", 0); ok {
		t.Fatal("目录不在不该命中")
	}
	if song, _ := kuwoPlayingSongIDs("邓丽君", "漫步人生路"); song != "" {
		t.Fatal("目录不在不该有曲目 id")
	}
}

func TestKuwoLocalNamedIdentity(t *testing.T) {
	cases := []struct {
		name, artist, title, rid string
		ok                       bool
	}{
		{"关正杰&雷安娜 - 天龙诀 - 6680.lrcx", "关正杰&雷安娜", "天龙诀", "6680", true},
		{"A - B - C - 12.lrc", "A", "B - C", "12", true},
		{"A - B - x12.lrcx", "", "", "", false},
		{"A - B - 12.txt", "", "", "", false},
		{" - B - 12.lrcx", "", "", "", false},
	}
	for _, c := range cases {
		a, ti, rid, ok := kuwoLocalNamedIdentity(c.name)
		if ok != c.ok || (ok && (a != c.artist || ti != c.title || rid != c.rid)) {
			t.Errorf("%q: got %q %q %q %v", c.name, a, ti, rid, ok)
		}
	}
}
