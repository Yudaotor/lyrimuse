package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestMain 把"读其它 App 本地数据"的那几条路径统一指到一个不存在的位置。
//
// 为什么必须有:kugouLocalLyric(kugoulocal.go)与 qqLocalMatch(qqlocal.go)的 override
// 默认为空 = **读真实路径**,而 fetchScoredLyricCandidatesStreaming 那条链路上的测试会
// 一路走到它们 —— 于是测试结果取决于**跑测试的人在酷狗 / QQ 音乐里听过什么歌**。
// 实测(在 refreshQQLocalIndexLocked 里用 debug.PrintStack 抓到的调用栈):不设这层隔离时,
// 一次全量 go test 会真读进 503 首 QQ 曲库记录,本机酷狗缓存里的 113 个 .krc 同样在被读。
//
// 这类污染最难缠的地方是它不会让测试**稳定**变红,只会偶尔变红 —— 取决于本机缓存里
// 正好有没有那首同名歌;换台机器、换个人听歌口味,结论就变,排查时几乎无法复现。
//
// 要用真实数据的测试自己 override 回去即可:resetKugouLocalIndex / resetQQLocalIndex
// 的 t.Cleanup 恢复的就是这里设的值,不是空串。
func TestMain(m *testing.M) {
	missing := filepath.Join(os.TempDir(), "lyrimuse-no-such-external-app-data")
	kugouLocalDirOverride = missing
	qqLocalDBOverride = filepath.Join(missing, "qqmusic.sqlite")
	neteaseLocalDBOverride = filepath.Join(missing, "sqlite_storage.sqlite3")
	spotifyISRCUsersDirOverride = filepath.Join(missing, "SpotifyUsers")
	os.Exit(m.Run())
}
