package main

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
)

// 正在播的那首的单条快照:`lyrimuse-playing-entry.json` = {"key": 缓存 key, "entry": 那一条完整的 enrichEntry}。
//
// App 靠磁盘上的缓存拿歌词,而整份缓存(主缓存一百多 MB + 精简索引三十多 MB)写一遍要好几秒,机器忙时十几秒
// —— 正在播的这首选出歌词之后,界面要等这么久才出词。这份小文件在整份写盘**之前**写好,App 查当前这首时
// 先看它(`EnrichCacheReader.lookup`),整份写完、App 解码完之后它就比缓存旧,自然不再生效。
//
// 只写正在播的那首(commitEnrichSave 那一支),一次覆盖一份,不累积。
func playingEntryPath() string {
	if enrichPath == "" {
		return ""
	}
	return playingEntryPathFor(enrichPath)
}

// playingEntryPathFor:主缓存 cachePath 旁边那份单条快照。
func playingEntryPathFor(cachePath string) string {
	return filepath.Join(filepath.Dir(cachePath), clientName+"-playing-entry.json")
}

type playingEntryFile struct {
	Key   string      `json:"key"`
	Entry enrichEntry `json:"entry"`
}

// playingEntryWriteMu 把「读条目 → 写文件」整段串起来。解析、补译文、动态封面几个 goroutine 常常同时提交
// 正在播的这首:读是在 enrichMu 里、写在锁外,不串起来的话先读到旧版本的那个可能后写完,文件里留下旧的一份,
// 而它的 mtime 更新,App 会优先读它(缺译文 / 缺字段),直到整份缓存写完。锁序:先它后 enrichMu。
var playingEntryWriteMu sync.Mutex

// writePlayingEntry 把 key 那一条当前的内存状态写成小文件。条目不在(被撤回 / 删了)就不写。
func writePlayingEntry(key string) {
	path := playingEntryPath()
	if path == "" {
		return
	}
	playingEntryWriteMu.Lock()
	defer playingEntryWriteMu.Unlock()
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok {
		return
	}
	// 候选明细给 App 没用、还占几十 KB,跟主缓存落盘时一样拆掉(明细由整份写盘写进旁路文件)。
	if stripped, _, split := splitDecisionDetails(key, e); split {
		e = stripped
	}
	b, err := json.Marshal(playingEntryFile{Key: key, Entry: e})
	if err == nil {
		err = writeFileAtomic(path, b)
	}
	if err != nil {
		slog.Error("playing entry: write", "key", key, "err", err)
	}
}

// readPlayingEntryIfNewer:单条快照 path 比主缓存 cachePath 新(主缓存不在也算)时读出那一条;比主缓存旧、不在、读不了都是 ok=false。
func readPlayingEntryIfNewer(path, cachePath string) (key string, e enrichEntry, ok bool) {
	pi, err := os.Stat(path)
	if err != nil {
		return "", enrichEntry{}, false
	}
	if ci, err := os.Stat(cachePath); err == nil && !pi.ModTime().After(ci.ModTime()) {
		return "", enrichEntry{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return "", enrichEntry{}, false
	}
	var f playingEntryFile
	if err := json.Unmarshal(data, &f); err != nil || f.Key == "" {
		return "", enrichEntry{}, false
	}
	return f.Key, f.Entry, true
}
