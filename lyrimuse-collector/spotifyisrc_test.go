package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 合成的缓存块,不读本机真实的 Spotify 数据。形状照搬实测:一个 `k:<22位>#` 之后跟一段
// protobuf 二进制,ISRC 以 `isrc` + 一个长度字节 + 12 位码的形式躺在里面。
func synthSpotifyBlock(trackID, isrc string, withISRC bool) []byte {
	b := []byte("k:" + trackID + "#")
	b = append(b, 0x2a, 0x00, 0x12) // 一点二进制噪声,模拟 protobuf 头
	b = append(b, []byte("type.googleapis.com/sp.data.T")...)
	b = append(b, 0x51, 0x00)
	if withISRC {
		b = append(b, []byte("isrc")...)
		b = append(b, 0x0c) // protobuf 的长度字节
		b = append(b, []byte(isrc)...)
		b = append(b, 'b', 0x00)
	}
	b = append(b, 0x7a, 0x00, 0x00)
	return b
}

func writeTestSpotifyCache(t *testing.T, blocks [][]byte) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Users")
	dir := filepath.Join(root, "someaccount-user", "primary.ldb")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	var all []byte
	for _, b := range blocks {
		all = append(all, b...)
	}
	if err := os.WriteFile(filepath.Join(dir, "000123.ldb"), all, 0o644); err != nil {
		t.Fatalf("写文件失败: %v", err)
	}
	return root
}

func resetSpotifyISRCIndex(t *testing.T, root string) {
	t.Helper()
	clear := func() {
		spotifyISRCMu.Lock()
		spotifyISRCIndex, spotifyISRCReady = nil, false
		spotifyISRCScanned, spotifyISRCDirMod = time.Time{}, time.Time{}
		spotifyISRCBuilding = false
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
	// ⚠️ 无 ISRC 的那条**必须夹在中间**,后面还得有一条带 ISRC 的。放最后的话,
	// 切段逻辑写错(一路扫到文件末尾)也不会露馅 —— 变异测试实测过这个漏洞。
	root := writeTestSpotifyCache(t, [][]byte{
		synthSpotifyBlock(testSpotifyID1, "HKA351401008", true),
		synthSpotifyBlock(testSpotifyID3, "", false), // 有记录但没 ISRC
		synthSpotifyBlock(testSpotifyID2, "USCA20801738", true),
	})
	resetSpotifyISRCIndex(t, root)
	spotifyISRCBuildIndexNow() // 生产走异步,测试里同步建一次

	for id, want := range map[string]string{
		testSpotifyID1: "HKA351401008",
		testSpotifyID2: "USCA20801738",
	} {
		got, ok := spotifyLocalISRC(id)
		if !ok || got != want {
			t.Errorf("%s: 期望 %q,得到 ok=%v %q", id, want, ok, got)
		}
	}
	// ⚠️ 有记录但记录里没 ISRC 的,必须报没命中 —— 不能把**下一条**记录的 ISRC 串给它。
	// 切段逻辑写错(比如往后多扫一截)就会在这里露馅。
	if got, ok := spotifyLocalISRC(testSpotifyID3); ok {
		t.Errorf("无 ISRC 的记录不该命中,却给了 %q", got)
	}
}

func TestSpotifyLocalISRCRejectsMalformed(t *testing.T) {
	resetSpotifyISRCIndex(t, writeTestSpotifyCache(t, [][]byte{
		synthSpotifyBlock(testSpotifyID1, "HKA351401008", true),
	}))
	spotifyISRCBuildIndexNow()
	for _, bad := range []string{"", "太短", "0VTzUEuHYD8s7CgQ15cDP", "0VTzUEuHYD8s7CgQ15cDPoX"} {
		if _, ok := spotifyLocalISRC(bad); ok {
			t.Errorf("%q 长度不是 22,不该命中", bad)
		}
	}
}

func TestSpotifyLocalISRCNeverBlocks(t *testing.T) {
	// 索引没建过时必须**立刻**返回(生产路径在歌词热路径上,一轮全量扫描实测约 5 秒)。
	resetSpotifyISRCIndex(t, writeTestSpotifyCache(t, [][]byte{
		synthSpotifyBlock(testSpotifyID1, "HKA351401008", true),
	}))
	start := time.Now()
	_, ok := spotifyLocalISRC(testSpotifyID1)
	if elapsed := time.Since(start); elapsed > 300*time.Millisecond {
		t.Fatalf("首次查询不该阻塞,用了 %v", elapsed)
	}
	if ok {
		t.Log("首次即命中(后台构建已抢先完成),不算错")
	}
}

func TestSpotifyLocalISRCMissingDir(t *testing.T) {
	resetSpotifyISRCIndex(t, filepath.Join(t.TempDir(), "没有这个目录"))
	spotifyISRCBuildIndexNow()
	if _, ok := spotifyLocalISRC(testSpotifyID1); ok {
		t.Error("目录不存在时不该命中")
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

func TestSpotifyISRCMultiAccount(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Users")
	for i, spec := range []struct{ id, isrc string }{
		{testSpotifyID1, "HKA351401008"},
		{testSpotifyID2, "USCA20801738"},
	} {
		dir := filepath.Join(root, fmt.Sprintf("acct%d-user", i), "primary.ldb")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "0001.ldb"),
			synthSpotifyBlock(spec.id, spec.isrc, true), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	resetSpotifyISRCIndex(t, root)
	spotifyISRCBuildIndexNow()
	// 登录过多个账号时每个账号一份 primary.ldb,都要扫。
	for id, want := range map[string]string{testSpotifyID1: "HKA351401008", testSpotifyID2: "USCA20801738"} {
		if got, ok := spotifyLocalISRC(id); !ok || got != want {
			t.Errorf("%s: 期望 %q,得到 ok=%v %q", id, want, ok, got)
		}
	}
}
