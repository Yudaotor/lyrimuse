package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/xml"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// qqArchiveStringForTest 把一个字符串归档成 QQ 缓存里那种 NSKeyedArchiver 二进制 plist(根对象就是这个字符串)。
func qqArchiveStringForTest(t *testing.T, s string) []byte {
	t.Helper()
	var esc bytes.Buffer
	if err := xml.EscapeText(&esc, []byte(s)); err != nil {
		t.Fatal(err)
	}
	doc := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>` +
		`<key>$archiver</key><string>NSKeyedArchiver</string>` +
		`<key>$objects</key><array><string>$null</string><string>` + esc.String() + `</string></array>` +
		`<key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>` +
		`<key>$version</key><integer>100000</integer></dict></plist>`
	cmd := exec.Command("/usr/bin/plutil", "-convert", "binary1", "-o", "-", "-")
	cmd.Stdin = strings.NewReader(doc)
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// qqRRCacheFixture 造一份跟 QQ 客户端同表结构的缓存库,entries 是 keyId → data 原始字节,返回库路径并指过去。
func qqRRCacheFixture(t *testing.T, wal bool, entries map[string][]byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rrdbcache.sqlite")
	var b strings.Builder
	b.WriteString("CREATE TABLE Cache(keyId TEXT PRIMARY KEY,createTime INTEGER,accessTime INTEGER,type INTEGER,data BLOB,size INTEGER);\n")
	b.WriteString("CREATE TABLE CacheInfo(keyId TEXT PRIMARY KEY,int_1 INTEGER,int_2 INTEGER,uint64_1 INTEGER);\n")
	for k, v := range entries {
		b.WriteString("INSERT INTO Cache VALUES('" + k + "',0,0,3,X'" + hex.EncodeToString(v) + "'," + "0);\n")
	}
	script := sqliteBatch(b.String())
	if wal {
		script = "PRAGMA journal_mode=WAL;\n" + script
	}
	if out, err := exec.Command("/usr/bin/sqlite3", path, script).CombinedOutput(); err != nil {
		t.Fatalf("造库失败: %v %s", err, out)
	}
	old := qqRRCacheOverride
	qqRRCacheOverride = path
	t.Cleanup(func() { qqRRCacheOverride = old })
	return path
}

const qqTestTransLRC = "[00:01.00]line one\n[00:02.00]line two\n[00:03.00]line three\n[00:04.00]line four"

func qqLocalCacheEntriesForTest(t *testing.T, id string) map[string][]byte {
	return map[string][]byte{
		id + ".qrc":       qqArchiveStringForTest(t, qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCContent))),
		id + "_trans.lrc": qqArchiveStringForTest(t, qqEncryptQRCForTest(t, qqTestTransLRC)),
		id + ".lrc":       qqArchiveStringForTest(t, "[00:00:00]此歌曲为没有填词的纯音乐，请您欣赏"),
		"other.qrc":       []byte("not a plist"),
	}
}

// 本机缓存里的逐字和译文跟接口那份同一种密文:解出来的整行、逐字、译文跟问到的一样。
func TestQQLocalQRCReadsClientCache(t *testing.T) {
	qqRRCacheFixture(t, false, qqLocalCacheEntriesForTest(t, "97773"))
	res, ok := qqLocalQRC(97773)
	if !ok || res.line != qqTestQRCLine || res.yrc == "" || !strings.Contains(res.tr, "line three") {
		t.Fatalf("该读到逐字、整行和译文: ok=%v line=%q yrc=%q tr=%q", ok, res.line, res.yrc, res.tr)
	}
	for _, id := range []int64{0, 12345} {
		if _, ok := qqLocalQRC(id); ok {
			t.Fatalf("id %d 不在缓存里,不该命中", id)
		}
	}
}

// 只有整行(.lrc,纯音乐那条是明文提示句)、或逐字那条不是归档的字符串,都不算命中。
func TestQQLocalQRCIgnoresLineOnlyAndMalformedEntries(t *testing.T) {
	entries := qqLocalCacheEntriesForTest(t, "1")
	delete(entries, "1.qrc")
	entries["2.qrc"] = []byte("not a plist")
	entries["3.qrc"] = qqArchiveStringForTest(t, "ZZ not hex")
	qqRRCacheFixture(t, false, entries)
	for _, id := range []int64{1, 2, 3} {
		if res, ok := qqLocalQRC(id); ok {
			t.Fatalf("id %d 不该命中: %+v", id, res)
		}
	}
}

// QQ 退出时检查点过、-wal / -shm 被删的 WAL 库:只读连接打不开,改用 immutable 照样读到,而且不在库旁边建文件。
func TestQQLocalQRCReadsCheckpointedWALCache(t *testing.T) {
	path := qqRRCacheFixture(t, true, qqLocalCacheEntriesForTest(t, "97773"))
	if out, err := exec.Command("/usr/bin/sqlite3", path, "PRAGMA wal_checkpoint(TRUNCATE);").CombinedOutput(); err != nil {
		t.Fatalf("检查点失败: %v %s", err, out)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if err := os.Remove(path + suffix); err != nil {
			t.Fatal(err)
		}
	}
	if res, ok := qqLocalQRC(97773); !ok || res.line != qqTestQRCLine {
		t.Fatalf("检查点过的 WAL 库该读得到: ok=%v line=%q", ok, res.line)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if _, err := os.Stat(path + suffix); err == nil {
			t.Fatalf("只读不该在库旁边建 %s", suffix)
		}
	}
}

func TestQQLocalLyricsFirstOnlyForLanguagesWithoutRomaji(t *testing.T) {
	for lang, want := range map[int]bool{0: true, 5: true, 1: false, 3: false, 4: false, 9: false} {
		if got := qqLocalLyricsFirst(lang); got != want {
			t.Fatalf("language %d: got %v want %v", lang, got, want)
		}
	}
}

// qqLyricRequestsForTest 装一个 QQ 接口桩:单曲详情按 detail 答,两个歌词接口按 lyricsOK 答(同一份 QRC 换了第一句,
// 认得出用的是哪一份),返回歌词接口被问的次数。
func qqLyricRequestsForTest(t *testing.T, detail string, lyricsOK bool) *atomic.Int32 {
	t.Helper()
	resetQQSessionForTest(t)
	qqSessionFetch = func(ctx context.Context) ([]byte, error) {
		return []byte(`{"session":{"uid":"1","sid":"s1","userip":"1.1.1.1"}}`), nil
	}
	cipher := qqEncryptQRCForTest(t, qqTestQRCXML(strings.Replace(qqTestQRCContent, "第(1000,300)一(1300,300)", "接(1000,300)口(1300,300)", 1)))
	var asked atomic.Int32
	withQQFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
			return http.StatusOK, `{"code":0,"data":[` + detail + `]}`
		case target == "u.y.qq.com/musicu:GetPlayLyricInfo":
			asked.Add(1)
			if lyricsOK {
				return http.StatusOK, musicuOK(`{"lyric":"` + cipher + `","qrc_t":1,"lrc_t":0,"trans":"","roma":""}`)
			}
			return http.StatusNotFound, ""
		case strings.HasSuffix(target, "/qqmusic/fcgi-bin/lyric_download.fcg"):
			asked.Add(1)
			return http.StatusNotFound, ""
		}
		return http.StatusNotFound, ""
	})
	return &asked
}

// 国语歌本机有就不问歌词接口;日语(这里拿 3 当没核过的语种)先问接口,接口答了用接口那份。
func TestQQQRCLyricUsesLocalCacheFirstOnlyWithoutRomaji(t *testing.T) {
	qqRRCacheFixture(t, false, qqLocalCacheEntriesForTest(t, "97773"))
	asked := qqLyricRequestsForTest(t, qqDetailRow, true)
	if res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269); res.line != qqTestQRCLine || asked.Load() != 0 {
		t.Fatalf("国语歌该用本机那份、不问接口: line=%q 问了 %d 次", res.line, asked.Load())
	}
	asked = qqLyricRequestsForTest(t, strings.Replace(qqDetailRow, `"language":0`, `"language":3`, 1), true)
	if res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269); !strings.Contains(res.line, "接口") || asked.Load() != 1 {
		t.Fatalf("别的语种先问接口、用接口那份: line=%q 问了 %d 次", res.line, asked.Load())
	}
}

// 别的语种两个歌词接口都没问成时,本机那份兜底。
func TestQQQRCLyricFallsBackToLocalCacheWhenEndpointsFail(t *testing.T) {
	qqRRCacheFixture(t, false, qqLocalCacheEntriesForTest(t, "97773"))
	asked := qqLyricRequestsForTest(t, strings.Replace(qqDetailRow, `"language":0`, `"language":3`, 1), false)
	if res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269); res.line != qqTestQRCLine || asked.Load() == 0 {
		t.Fatalf("接口都没问成时该用本机那份: line=%q 问了 %d 次", res.line, asked.Load())
	}
}
