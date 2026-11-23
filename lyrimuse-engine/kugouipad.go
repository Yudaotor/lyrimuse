package main

import (
	"os"
	"path/filepath"
	"strings"
)

// iPad 版酷狗(iOS 应用跑在 Apple 芯片 Mac 上,bundle id com.kugou.kugou1002)的本地数据跟 Mac 版是同一套:歌词缓存
// `kgLyric`(见 kugouIPadLocalLyricDir)、播放队列库 `Library/Preferences/currentPlayList.sqlite`。队列库换了表:
// 每首的 JSON(字段跟 Mac 版 CurrentSongList 的 songInfo 同名:musicName、showName、musicTime、mixId、payAlbumID、
// albumImgUrl、classname)放在 FullSongInfo,次序在 CurrentSongListNew(songid → FullSongInfo.id,songIndex 是次序;
// CurrentSongListNew 自己的 songInfo 一直是空的)。App 把它按 Mac 版认,引擎拿到的都是 Mac 版的 bundle id,所以读 Mac 版
// 数据的几处在认不出当前这首时再看这一份;按歌名、署名、时长认,两个版本的队列不会串。读它的成败不记进 "kugou" 的访问状态
// (那一份管 Mac 版的完全磁盘访问)。见 02 章决策 292。

// kugouIPadQueueOverride 让单测把队列库指到临时路径。空 = 用真实路径。
var kugouIPadQueueOverride string

func kugouIPadQueuePath() string {
	if kugouIPadQueueOverride != "" {
		return kugouIPadQueueOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return otherAppContainer(filepath.Join(home, "Library/Containers/com.kugou.kugou1002/Data/Library/Preferences",
		"currentPlayList.sqlite"))
}

// kugouIPadQueueFrom 是 Mac 版查询里 `FROM CurrentSongList ORDER BY songIndex` 在 iPad 版库里的写法。
const kugouIPadQueueFrom = "FROM CurrentSongListNew c JOIN FullSongInfo f ON f.id = c.songid ORDER BY c.songIndex"

// kugouIPadQueueSQL 把读 Mac 版队列库的查询改成读 iPad 版的:字段照旧从每首的 JSON 里取,只换表。纯函数,单测覆盖。
func kugouIPadQueueSQL(macQuery string) string {
	q := strings.ReplaceAll(macQuery, "cast(songInfo as text)", "cast(f.songInfo as text)")
	q = strings.Replace(q, "SELECT songIndex AS i,", "SELECT c.songIndex AS i,", 1)
	return strings.Replace(q, "FROM CurrentSongList ORDER BY songIndex", kugouIPadQueueFrom, 1)
}
