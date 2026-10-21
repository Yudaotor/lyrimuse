package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
// testRealHome:换 HOME 之前的家目录,TestConfigDirIsSandboxed 拿它核对。
var testRealHome string

// 测试期间的配置目录不在真实家目录下(见 TestMain)。
func TestConfigDirIsSandboxed(t *testing.T) {
	if testRealHome == "" || strings.HasPrefix(configDir(), testRealHome+string(filepath.Separator)) {
		t.Fatalf("配置目录 %s 落在真实家目录 %s 下", configDir(), testRealHome)
	}
}

func TestMain(m *testing.M) {
	// HOME 指到临时目录,配置目录(默认在 HOME 下)跟着走:没设 LYRIMUSE_CONFIG_DIR 的用例(只换了 enrichPath 的那些)
	// 会落到真实的 ~/.config/lyrimuse,启动清理(sweepKeyedDir)会把真实的留底当孤儿删掉。别在这里设 LYRIMUSE_CONFIG_DIR:
	// 靠 t.Setenv("HOME") 隔离的用例(代理提示等)就不再跟着自己的 HOME 走了。
	sandbox, err := os.MkdirTemp("", "lyrimuse-engine-test-")
	if err != nil {
		panic(err)
	}
	testRealHome, _ = os.UserHomeDir()
	// 凭据保险箱一律当没有条目,不起 security、不碰真实钥匙串;测它的用例自己换。
	credentialVaultRead = func() ([]byte, error) { return nil, nil }
	// 系统时区不跟:用例都按启动时的 time.Local 拼时间,中途被换掉会对不上(换时区的用例自己设,digestschedule_test.go)。
	localZoneLink = ""
	canonicalMemoTTL = 0 // 各用例直接换 enrichCache,不让上一个用例记下的宽松匹配漏到下一个(见 canonicalMemoTTL)
	_ = os.Unsetenv("LYRIMUSE_CONFIG_DIR")
	_ = os.Setenv("HOME", sandbox)
	missing := filepath.Join(os.TempDir(), "lyrimuse-no-such-external-app-data")
	kugouLocalDirOverride = missing
	qqLocalDBOverride = filepath.Join(missing, "qqmusic.sqlite")
	neteaseLocalDBOverride = filepath.Join(missing, "sqlite_storage.sqlite3")
	spotifyISRCUsersDirOverride = filepath.Join(missing, "SpotifyUsers")
	applemusicLocalDirOverride = filepath.Join(missing, "fsCachedData")
	sodaLocalQueueOverride = filepath.Join(missing, "QueueCache")
	sodaPreloadOverride = filepath.Join(missing, "entries.db")
	lxMusicDataDirOverride = filepath.Join(missing, "LxDatas")
	// 播放队列那几家(upcoming.go 的第一层):prefetchUpcoming 挂在 poller 换歌路径上,
	// 经它的测试同样会读到真实队列,所以每一家的队列文件都要在这里指到不存在的路径
	// (QQ / 酷狗旧库 / 网易云这几份也不例外)。
	qqUpcomingOverride = filepath.Join(missing, "PlayingList.archive")
	neteaseUpcomingOverride = filepath.Join(missing, "playingList")
	neteaseFMOverride = filepath.Join(missing, "fmPlay")
	kugouUpcomingOverride = filepath.Join(missing, "currentPlayList.sqlite")
	kugouQueuePlistOverride = filepath.Join(missing, "userCurrentPlayList.plist")
	kugouConfigPlistOverride = filepath.Join(missing, "KugouConfigPlist.plist")
	kugouLibraryDBOverride = filepath.Join(missing, "kugou3.sqlite")
	// 两家网页版的队列要请 App 去浏览器里读;测试里一律"读不到",要测的用例自己换。
	ytmusicQueueScript = func(string) (appQueryTracks, bool) { return appQueryTracks{}, false }
	spotifyWebQueueScript = func(string) (appQueryTracks, bool) { return appQueryTracks{}, false }
	browserQueueRetryDelay = 0
	// 网易云、MusicBrainz 两家的请求间隔:单测里连发的是假服务器,按真实间隔等只会拖慢整套;测节流本身的用例自己设。
	neteaseMinIntervalBetweenCalls = 0
	musicbrainzMinIntervalBetweenCalls = 0
	// 网络翻译的 Google 那一家默认指向真实端点;单测一律跳过,免得经 machineTranslateLRC
	// 的用例真的外发请求、还让 MyMemory 假服务器收不到请求。测它的用例自己指向假服务器。
	googleTranslateEndpoint = ""
	// 机翻链第 0 级(歌词源自带的译文)会问 YouTube Music;单测一律当作没有,要测它的用例自己换回 ytmusicTranslationsFor。
	lyricsSourceTranslations = func(context.Context, string, string) map[string]string { return nil }
	// 编目匹配的名字来源(Apple 目录反查 / YouTube Music 英文署名)会联网;单测一律当作「查成了、没有」,
	// 要测它们的用例自己换(stubCatalogNameSources)。
	catalogAppleTitleAliases = func(context.Context, string, string, float64) ([]string, error) { return nil, nil }
	catalogYTMusicAliases = func(context.Context, string, string, float64) ([]string, error) { return nil, nil }
	// amll 的索引会读配置目录、在后台联网下载;单测一律当作没有索引,要测的用例自己换(setSharedAMLLIndexStore)。
	setSharedAMLLIndexStore(newAMLLIndexStore("", time.Now))
	// 本机播放器数据里按歌名记着的封面(KKBOX 缓存、网易云曲库):单测一律当作没有,要测的用例自己换。
	localPlayerCovers = func(string, string, string, float64) []string { return nil }
	// 散落副本恢复之后的后台重评会联网,而且跑在用例结束之后;单测一律不跑,要测的用例自己换。
	rescoreReleasedStrays = func([]string) {}
	// 出站闸令牌给足:请求多半打到假服务器或拨号即失败,按真实速率排队只是干等。专测限速的用例自己设 rateFor。
	newHostGuardRateFor = func(string) hostRate { return hostRate{perSec: 1000, burst: 1000} }
	setSharedHostGuard(newHostGuard(time.Now))
	code := m.Run()
	_ = os.RemoveAll(sandbox)
	os.Exit(code)
}
