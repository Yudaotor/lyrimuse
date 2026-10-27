package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// 网易云有两种安装包,数据各在一处:沙盒版在 `~/Library/Containers/com.netease.163music/Data/Documents/`
// (读它要「完全磁盘访问」),非沙盒版在 `~/Library/Application Support/com.netease.163music/Documents/`
// (不用授权)。两处下面的相对路径一样。曲库、播放队列、私人漫游三份文件都从 neteaseDataRoot 挑出的同一个根读。
// 见 09 章决策 342。

const (
	neteaseLibraryRel = "storage/sqlite_storage.sqlite3"
	neteaseQueueRel   = "storage/file_storage/webdata/file/playingList"
	neteaseFMRel      = "storage/file_storage/webdata/file/fmPlay"
)

func neteaseContainerRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.netease.163music/Data/Documents")
}

func neteaseStandaloneRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Application Support/com.netease.163music/Documents")
}

// neteaseContainerPath 是 rel 在沙盒版那一处的路径,启动探测按它找容器(localCacheClientPaths)。
func neteaseContainerPath(rel string) string {
	root := neteaseContainerRoot()
	if root == "" {
		return ""
	}
	return filepath.Join(root, rel)
}

// neteaseDataRoot 是此刻真正去读的那个根;取不到家目录时是 ""。
func neteaseDataRoot() string {
	return pickNeteaseDataRoot(neteaseContainerRoot(), neteaseStandaloneRoot())
}

// neteaseDataPath 是 rel 在 neteaseDataRoot 下的完整路径;根是 "" 时也是 ""。
func neteaseDataPath(rel string) string {
	root := neteaseDataRoot()
	if root == "" {
		return ""
	}
	return filepath.Join(root, rel)
}

// neteaseUsesStandalone:此刻读的是非沙盒那一处,读它不用「完全磁盘访问」。
func neteaseUsesStandalone() bool {
	standalone := neteaseStandaloneRoot()
	return standalone != "" && neteaseDataRoot() == standalone
}

// pickNeteaseDataRoot 在两处之间挑:默认容器;容器里三份文件一份都没有、另一处有才用另一处;两处都有取最近改过的那一处。
// 三份文件挑同一个根、不各挑各的:私人漫游和普通队列按哪份改得晚判断此刻在放哪一份(neteasefm.go),跨两个根比就不准。
// 容器里的文件 stat 出了「不存在」以外的错(没授权)照样返回容器,让读的那一步把拒绝报出来,同 pickSodaDataPath。
func pickNeteaseDataRoot(container, standalone string) string {
	cmod, err := newestNeteaseFile(container)
	if err != nil {
		return container
	}
	if smod, err := newestNeteaseFile(standalone); err == nil && smod.After(cmod) {
		return standalone
	}
	return container
}

// newestNeteaseFile 是 root 下三份文件里最晚的修改时间;一份都没有(含 root 是 "")是零值。
func newestNeteaseFile(root string) (time.Time, error) {
	var newest time.Time
	if root == "" {
		return newest, nil
	}
	for _, rel := range []string{neteaseLibraryRel, neteaseQueueRel, neteaseFMRel} {
		st, err := os.Stat(filepath.Join(root, rel))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return time.Time{}, err
		}
		if st.ModTime().After(newest) {
			newest = st.ModTime()
		}
	}
	return newest, nil
}
