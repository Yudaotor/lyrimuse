package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 启动时主动探一遍各家客户端的私有容器,把「读得到 / 被拒」先发布出去(localcachefs.go)。
//
// 不探的话,状态只在某条快速路径真的读过那一家之后才有 —— 设置页 / 引导页「完全磁盘访问」那一行
// 在这之前只能显示「未确认」,用户刚授权完点「重启后台服务」也要等到下一次读到那一家才看得到结果。
//
// 要不要授权按**路径在不在 `~/Library/Containers/` 下**判定(见 localcachefs.go 头注),
// 所以探测对象从下面这张路径表推出来,不另列播放器名单。

// localCacheClientPaths 是每条快速路径读的客户端文件,键是来源名(与状态文件里的名字同一套)。
// 新接一条读客户端文件的路径必须在这里登记:启动探测和 players.json `needsFullDiskAccess`
// 的一致性测试(TestPlayersNeedFullDiskAccessMatchesClientPaths)都读这一张表。
func localCacheClientPaths() map[string][]string {
	return map[string][]string{
		"kugou": {kugouLocalLyricDir(), kugouUpcomingPath(), kugouQueuePlistPath(),
			kugouConfigPlistPath(), kugouLibraryDBPath(), kugouNowPlayingPath()},
		"qq":         {qqLocalDBPath(), qqUpcomingPath()},
		"netease":    {neteaseLocalDBPath(), neteaseUpcomingPath()},
		"soda":       {sodaLocalQueuePath(), sodaPreloadPath()},
		"applemusic": {applemusicLocalCacheDir()},
		"spotify":    {spotifyISRCUsersDir()},
		"kkbox":      {kkboxLocalStorageDir(), kkboxCacheDir()},
	}
}

// containerDataRoot 返回 path 所在的 `…/Library/Containers/<bundle id>/Data`;不在任何 App 的
// 私有容器里返回 ""。
func containerDataRoot(path string) string {
	const marker = "/Library/Containers/"
	i := strings.Index(path, marker)
	if i < 0 {
		return ""
	}
	rest := path[i+len(marker):]
	bundle, _, _ := strings.Cut(rest, "/")
	if bundle == "" {
		return ""
	}
	return path[:i+len(marker)] + bundle + "/Data"
}

// localCacheProbeTargets 是「来源 → 要探的容器根」,只含路径落在私有容器里的来源。
func localCacheProbeTargets(paths map[string][]string) map[string][]string {
	targets := map[string][]string{}
	for source, list := range paths {
		seen := map[string]bool{}
		for _, p := range list {
			root := containerDataRoot(p)
			if root == "" || seen[root] {
				continue
			}
			seen[root] = true
			targets[source] = append(targets[source], root)
		}
		sort.Strings(targets[source])
	}
	return targets
}

// probeLocalCacheAccess 由 main() 在设好状态文件路径之后调一次。容器目录不存在(没装 / 没打开过)
// 的来源跳过,不发布任何结论;只列目录、不读内容。
func probeLocalCacheAccess() {
	probeLocalCacheTargets(localCacheProbeTargets(localCacheClientPaths()))
}

func probeLocalCacheTargets(targets map[string][]string) {
	for source, roots := range targets {
		for _, root := range roots {
			if _, err := os.Lstat(filepath.Dir(root)); errors.Is(err, fs.ErrNotExist) {
				continue
			}
			if _, err := os.ReadDir(root); err != nil {
				noteLocalCacheDenied(source, root, err)
				continue
			}
			noteLocalCacheReadable(source)
		}
	}
}
