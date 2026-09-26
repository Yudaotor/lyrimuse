package main

import (
	"context"
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
	applemusicLocalDirOverride = filepath.Join(missing, "fsCachedData")
	sodaLocalQueueOverride = filepath.Join(missing, "QueueCache")
	sodaPreloadOverride = filepath.Join(missing, "entries.db")
	// 播放队列那几家(upcoming.go 的第一层):prefetchUpcoming 挂在 poller 换歌路径上,
	// 经它的测试同样会读到真实队列,所以每一家的队列文件都要在这里指到不存在的路径
	// (QQ / 酷狗旧库 / 网易云这几份也不例外)。
	qqUpcomingOverride = filepath.Join(missing, "PlayingList.archive")
	neteaseUpcomingOverride = filepath.Join(missing, "playingList")
	kugouUpcomingOverride = filepath.Join(missing, "currentPlayList.sqlite")
	kugouQueuePlistOverride = filepath.Join(missing, "userCurrentPlayList.plist")
	kugouConfigPlistOverride = filepath.Join(missing, "KugouConfigPlist.plist")
	kugouLibraryDBOverride = filepath.Join(missing, "kugou3.sqlite")
	// YouTube Music 队列要去浏览器里跑 AppleScript;测试里一律"读不到",要测的用例自己换。
	ytmusicQueueScript = func(string, string) (string, bool) { return "", false }
	ytmusicVideoTypeScript = func(context.Context, string, string) (string, bool) { return "", false }
	spotifyWebQueueScript = func(string, string) (string, bool) { return "", false }
	browserQueueRetryDelay = 0
	// 信任列表里的其他浏览器要去读本机 App 包判引擎族;测试里一律判不了,要测的用例自己换。
	detectBrowserScriptFamily = func(string) string { return "" }
	// Apple Music 的系统待播队列要跑 App 包里的 perl 加载器,单测里一律当作找不到。
	nowPlayingClientsPathsOverride = func() (string, string) { return "", "" }
	// 网络翻译的 Google 那一家默认指向真实端点;单测一律跳过,免得经 machineTranslateLRC
	// 的用例真的外发请求、还让 MyMemory 假服务器收不到请求。测它的用例自己指向假服务器。
	googleTranslateEndpoint = ""
	// 编目匹配的名字来源(Apple 目录反查 / YouTube Music 英文署名)会联网;单测一律当作「查成了、没有」,
	// 要测它们的用例自己换(stubCatalogNameSources)。
	catalogAppleTitleAliases = func(context.Context, string, string, float64) ([]string, error) { return nil, nil }
	catalogYTMusicAliases = func(context.Context, string, string, float64) ([]string, error) { return nil, nil }
	os.Exit(m.Run())
}
