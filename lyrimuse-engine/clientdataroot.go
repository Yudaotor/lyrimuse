package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// 网易云、QQ 音乐、汽水各有两种安装包,数据各在一处、两处底下的相对路径一样:App Store 的沙盒版在
// `~/Library/Containers/<bundle id>/Data/…`(读它要「完全磁盘访问」),官网下载的非沙盒版在
// `~/Library/Application Support/…`(不用授权)。每家要读的几份文件都从 clientDataRoots.root 挑出的同一个根读。
// 见 09 章决策 342 与 09 章决策 343。

type clientDataRoots struct {
	// container 是沙盒版那一处的根,standalone 是非沙盒版那一处;取不到家目录时都是 ""。
	container, standalone string
	// files 是根下要读的那几份(相对路径),挑根时比它们的修改时间。
	files []string
}

func homeSubdir(rel string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, rel)
}

const (
	neteaseLibraryRel = "storage/sqlite_storage.sqlite3"
	neteaseQueueRel   = "storage/file_storage/webdata/file/playingList"
	neteaseFMRel      = "storage/file_storage/webdata/file/fmPlay"

	qqLibraryRel = "qqmusic.sqlite"
	qqQueueRel   = "iTemp/PlayingList.archive"
	qqRRCacheRel = "iRRCache/rrdbcache.sqlite"

	sodaQueueRel   = "LunaStorage/QueueCache"
	sodaPreloadRel = "LunaCacheV2/entries.db"
)

func neteaseDataRoots() clientDataRoots {
	return clientDataRoots{
		container:  homeSubdir("Library/Containers/com.netease.163music/Data/Documents"),
		standalone: homeSubdir("Library/Application Support/com.netease.163music/Documents"),
		files:      []string{neteaseLibraryRel, neteaseQueueRel, neteaseFMRel},
	}
}

func qqDataRoots() clientDataRoots {
	return clientDataRoots{
		container:  homeSubdir("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"),
		standalone: homeSubdir("Library/Application Support/QQMusicMac"),
		files:      []string{qqLibraryRel, qqQueueRel, qqRRCacheRel},
	}
}

func sodaDataRoots() clientDataRoots {
	return clientDataRoots{
		container:  homeSubdir("Library/Containers/com.soda.music/Data/Library/Application Support/SodaMusic"),
		standalone: homeSubdir("Library/Application Support/SodaMusic"),
		files:      []string{sodaQueueRel, sodaPreloadRel},
	}
}

// clientDataRootsBySource 键是 localCacheClientPaths 里的来源名。新接一家有两种安装包的播放器在这里登记,
// 启动探测据此判断它此刻读的那一份要不要授权。
func clientDataRootsBySource() map[string]clientDataRoots {
	return map[string]clientDataRoots{
		"netease": neteaseDataRoots(),
		"qq":      qqDataRoots(),
		"soda":    sodaDataRoots(),
	}
}

func (r clientDataRoots) root() string {
	return pickClientDataRoot(r.container, r.standalone, r.files)
}

// path 是 rel 在此刻读的那个根下的完整路径;根是 "" 时也是 ""。
func (r clientDataRoots) path(rel string) string {
	return joinRoot(r.root(), rel)
}

// containerPath 是 rel 在沙盒版那一处的路径,启动探测按它找容器(localCacheClientPaths)。
func (r clientDataRoots) containerPath(rel string) string {
	return joinRoot(r.container, rel)
}

// usesStandalone:此刻读的是非沙盒那一处,读它不用「完全磁盘访问」。
func (r clientDataRoots) usesStandalone() bool {
	return r.standalone != "" && r.root() == r.standalone
}

func joinRoot(root, rel string) string {
	if root == "" {
		return ""
	}
	return filepath.Join(root, rel)
}

// pickClientDataRoot 在两处之间挑:默认容器;非沙盒那一处的文件比容器里的都新(含容器里一份都没有)才用它。
// 几份文件挑同一个根、不各挑各的:网易云按私人漫游和普通队列哪份改得晚判断此刻在放哪一份(neteasefm.go),
// 汽水的队列和预载缓存要是同一个客户端写的,跨两个根比就不准。
// 容器里的文件 stat 出了「不存在」以外的错(没授权)照样返回容器,让读的那一步把拒绝报出来,别退回可能过期的另一处。
func pickClientDataRoot(container, standalone string, files []string) string {
	cmod, err := newestClientFile(container, files)
	if err != nil {
		return container
	}
	if smod, err := newestClientFile(standalone, files); err == nil && smod.After(cmod) {
		return standalone
	}
	return container
}

// newestClientFile 是 root 下这几份文件里最晚的修改时间;一份都没有(含 root 是 "")是零值。
func newestClientFile(root string, files []string) (time.Time, error) {
	var newest time.Time
	if root == "" {
		return newest, nil
	}
	for _, rel := range files {
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
