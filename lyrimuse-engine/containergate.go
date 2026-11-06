package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// 读别的 App 的私有容器(`~/Library/Containers/<bundle id>/Data`)之前先看 Lyrimuse 有没有「完全磁盘访问」,
// 没有就一律当不存在、退回网络解析。没授权时去读,系统会以 Lyrimuse 的名义弹「想访问其他 App 的数据」,
// 常驻引擎和 App 拉起的子命令都一样;点了「允许」,读到容器里别的文件还会再弹。有授权时读不弹。
// 见 02 章决策 238。
//
// 所有指向容器的路径都要经过 otherAppContainer,TestOtherAppContainerPathsGoThroughGate 扫源码守着。

// fullDiskAccessProbePaths:系统的权限库。系统那份对所有人可读(644),只有「完全磁盘访问」挡着,被拒时不弹框;
// 用户那份新系统上可能不存在。别换成探别的 App 的容器,那一下就会弹框。
var fullDiskAccessProbePaths = []string{
	"/Library/Application Support/com.apple.TCC/TCC.db",
	homeSubdir("Library/Application Support/com.apple.TCC/TCC.db"),
}

// fullDiskAccessTTL:结论缓存多久。授权后要重启引擎才生效,这里只是别每读一次都开一次文件。
const fullDiskAccessTTL = 5 * time.Minute

// fullDiskAccessCheck 单测换掉。
var fullDiskAccessCheck = probeFullDiskAccess

var fullDiskAccessMemo struct {
	sync.Mutex
	at time.Time
	ok bool
}

func probeFullDiskAccess() bool {
	for _, p := range fullDiskAccessProbePaths {
		if p == "" {
			continue
		}
		if f, err := os.Open(p); err == nil {
			f.Close()
			return true
		}
	}
	return false
}

func hasFullDiskAccess() bool {
	fullDiskAccessMemo.Lock()
	defer fullDiskAccessMemo.Unlock()
	if fullDiskAccessMemo.at.IsZero() || time.Since(fullDiskAccessMemo.at) > fullDiskAccessTTL {
		fullDiskAccessMemo.ok, fullDiskAccessMemo.at = fullDiskAccessCheck(), time.Now()
	}
	return fullDiskAccessMemo.ok
}

// otherAppContainer 原样返回 path,除非 path 在别的 App 的私有容器里、而 Lyrimuse 没有「完全磁盘访问」,这时返回 ""。
func otherAppContainer(path string) string {
	if containerDataRoot(path) == "" || hasFullDiskAccess() {
		return path
	}
	return ""
}

// localCacheContainerBundles 是每个来源读的那几个容器的 bundle id,没授权时启动探测按它判「装了、被挡着」
// (只看容器目录在不在,不进 Data)。跟 localCacheClientPaths 对得上,TestLocalCacheContainerBundlesMatchClientPaths 守着。
var localCacheContainerBundles = map[string][]string{
	"kugou":   {"com.kugou.mac.Music"},
	"qq":      {"com.tencent.QQMusicMac"},
	"netease": {"com.netease.163music"},
	"soda":    {"com.soda.music"},
	"vox":     {"com.coppertino.Vox"},
}

// noteContainersDeniedWithoutFullDiskAccess:没授权时,容器目录在的来源记成被拒,设置页照常提示去开「完全磁盘访问」。
// skip 是此刻读容器外那一份、不用授权的来源。
func noteContainersDeniedWithoutFullDiskAccess(skip map[string]bool) {
	for source, bundles := range localCacheContainerBundles {
		if skip[source] {
			continue
		}
		for _, bundle := range bundles {
			dir := homeSubdir(filepath.Join("Library/Containers", bundle))
			if dir == "" {
				continue
			}
			if _, err := os.Lstat(dir); errors.Is(err, fs.ErrNotExist) || err != nil && !errors.Is(err, fs.ErrPermission) {
				continue
			}
			noteLocalCacheDenied(source, dir, &fs.PathError{Op: "open", Path: filepath.Join(dir, "Data"), Err: fs.ErrPermission})
			break
		}
	}
}
