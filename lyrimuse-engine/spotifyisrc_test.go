package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 合成的元数据缓存,不读本机真实的 Spotify 数据。形状照搬实测:primary.ldb 里
// `!xmeta#cache#` + 01 2a + 曲目 uri 这个 key 下是 spotify.metadata.Track,ISRC 在它的
// external_id(第 10 个字段 {1: "isrc", 2: 码})里。

func testSpotifyTrackWithISRC(isrc string) []byte {
	v := pbMsg(pbStr(2, "某首歌"), pbVarint(7, 360000))
	if isrc != "" {
		// 前面先放一个别的类型的外部 id —— 取数必须按 type 认,不能拿第一个就走。
		v = append(v, pbBytes(10, pbMsg(pbStr(1, "upc"), pbStr(2, "000000000000")))...)
		v = append(v, pbBytes(10, pbMsg(pbStr(1, "isrc"), pbStr(2, isrc)))...)
	}
	return pbMsg(pbVarint(1, 10), pbBytes(2, pbMsg(pbStr(1, "type.googleapis.com/spotify.metadata.Track"), pbBytes(2, v))))
}

// writeTestSpotifyISRCCache 建一个 Users/<账号>-user/primary.ldb,每个账号一份 id→ISRC(空串 = 有记录但没 ISRC)。
func writeTestSpotifyISRCCache(t *testing.T, accounts ...map[string]string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Users")
	for i, recs := range accounts {
		dir := filepath.Join(root, "acct"+string(rune('a'+i))+"-user", "primary.ldb")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		var entries []testLDBEntry
		seq := uint64(1)
		for id, isrc := range recs {
			entries = append(entries, testLDBEntry{key: string(spotifyXmetaKey(spotifyTrackKind, id)), seq: seq, value: string(testSpotifyTrackWithISRC(isrc))})
			seq++
		}
		testWriteTable(t, filepath.Join(dir, "000123.ldb"), entries, 2, true)
	}
	return root
}

func resetSpotifyISRCCache(t *testing.T, root string) {
	t.Helper()
	clear := func() {
		spotifyISRCMu.Lock()
		spotifyISRCHits, spotifyISRCMisses, spotifyISRCLogged = map[string]string{}, map[string]time.Time{}, map[string]bool{}
		spotifyISRCMu.Unlock()
	}
	clear()
	old := spotifyISRCUsersDirOverride
	spotifyISRCUsersDirOverride = root
	t.Cleanup(func() {
		spotifyISRCUsersDirOverride = old
		clear()
	})
}

const (
	testSpotifyID1 = "0VTzUEuHYD8s7CgQ15cDPo"
	testSpotifyID2 = "005lwxGU1tms6HGELIcUv9"
	testSpotifyID3 = "51ZQ1vr10ffzbwIjDCwqm4"
)

func TestSpotifyLocalISRCHit(t *testing.T) {
	resetSpotifyISRCCache(t, writeTestSpotifyISRCCache(t, map[string]string{
		testSpotifyID1: "HKA351401008",
		testSpotifyID3: "", // 有记录但没 ISRC
		testSpotifyID2: "USCA20801738",
	}))
	for id, want := range map[string]string{testSpotifyID1: "HKA351401008", testSpotifyID2: "USCA20801738"} {
		if got, ok := spotifyLocalISRC(id); !ok || got != want {
			t.Errorf("%s: 期望 %q,得到 ok=%v %q", id, want, ok, got)
		}
	}
	// 有记录但记录里没 ISRC 的必须报没命中 —— 不能把别的记录的 ISRC 串给它。
	if got, ok := spotifyLocalISRC(testSpotifyID3); ok {
		t.Errorf("无 ISRC 的记录不该命中,却给了 %q", got)
	}
}

// 第一次查就能命中:原来是后台全量建索引,第一次播到的歌必然查不到。
func TestSpotifyLocalISRCHitsOnFirstLookup(t *testing.T) {
	resetSpotifyISRCCache(t, writeTestSpotifyISRCCache(t, map[string]string{testSpotifyID1: "HKA351401008"}))
	if got, ok := spotifyLocalISRC(testSpotifyID1); !ok || got != "HKA351401008" {
		t.Fatalf("第一次查就该命中,得到 ok=%v %q", ok, got)
	}
}

func TestSpotifyLocalISRCRejectsMalformed(t *testing.T) {
	resetSpotifyISRCCache(t, writeTestSpotifyISRCCache(t, map[string]string{
		testSpotifyID1: "HKA351401008",
		testSpotifyID2: "not-an-isrc",
	}))
	for _, bad := range []string{"", "太短", "0VTzUEuHYD8s7CgQ15cDP", "0VTzUEuHYD8s7CgQ15cDPoX"} {
		if _, ok := spotifyLocalISRC(bad); ok {
			t.Errorf("%q 长度不是 22,不该命中", bad)
		}
	}
	if got, ok := spotifyLocalISRC(testSpotifyID2); ok {
		t.Errorf("形状不对的 ISRC 不该认,却给了 %q", got)
	}
}

func TestSpotifyLocalISRCMissingDir(t *testing.T) {
	resetSpotifyISRCCache(t, filepath.Join(t.TempDir(), "没有这个目录"))
	if _, ok := spotifyLocalISRC(testSpotifyID1); ok {
		t.Error("目录不存在时不该命中")
	}
}

// 「查过、没有」只记一小会儿:客户端过一会儿才写进元数据是常态,过了 TTL 要重新查。
func TestSpotifyLocalISRCMissExpires(t *testing.T) {
	root := writeTestSpotifyISRCCache(t, map[string]string{testSpotifyID2: "USCA20801738"})
	resetSpotifyISRCCache(t, root)
	if _, ok := spotifyLocalISRC(testSpotifyID1); ok {
		t.Fatal("还没写进缓存,不该命中")
	}
	// 客户端把这首写进来了(换一份库模拟)。TTL 之内仍按「没有」返回,不重读。
	resetSpotifyISRCCache(t, root)
	spotifyISRCUsersDirOverride = writeTestSpotifyISRCCache(t, map[string]string{testSpotifyID1: "HKA351401008"})
	spotifyISRCMu.Lock()
	spotifyISRCMisses[testSpotifyID1] = time.Now()
	spotifyISRCMu.Unlock()
	if _, ok := spotifyLocalISRC(testSpotifyID1); ok {
		t.Error("TTL 之内该直接返回「没有」")
	}
	spotifyISRCMu.Lock()
	spotifyISRCMisses[testSpotifyID1] = time.Now().Add(-2 * spotifyISRCMissTTL)
	spotifyISRCMu.Unlock()
	if got, ok := spotifyLocalISRC(testSpotifyID1); !ok || got != "HKA351401008" {
		t.Errorf("过了 TTL 该重新查到,得到 ok=%v %q", ok, got)
	}
}

func TestSpotifyISRCLedgerDirsSkipsNonLedger(t *testing.T) {
	root := t.TempDir()
	// 一个正常账号目录 + 一个没有 primary.ldb 的目录 + 一个普通文件
	if err := os.MkdirAll(filepath.Join(root, "acct-a", "primary.ldb"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "acct-b", "other"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "afile"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	dirs := spotifyISRCLedgerDirs(root)
	if len(dirs) != 1 || filepath.Base(filepath.Dir(dirs[0])) != "acct-a" {
		t.Fatalf("应只认带 primary.ldb 的账号目录,得到 %v", dirs)
	}
}

// 登录过多个账号时每个账号一份 primary.ldb,都要查。
func TestSpotifyISRCMultiAccount(t *testing.T) {
	resetSpotifyISRCCache(t, writeTestSpotifyISRCCache(t,
		map[string]string{testSpotifyID1: "HKA351401008"},
		map[string]string{testSpotifyID2: "USCA20801738"}))
	for id, want := range map[string]string{testSpotifyID1: "HKA351401008", testSpotifyID2: "USCA20801738"} {
		if got, ok := spotifyLocalISRC(id); !ok || got != want {
			t.Errorf("%s: 期望 %q,得到 ok=%v %q", id, want, ok, got)
		}
	}
}
