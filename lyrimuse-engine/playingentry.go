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
	return filepath.Join(filepath.Dir(enrichPath), clientName+"-playing-entry.json")
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

// overlayPlayingEntryReadOnly:一次性子命令读完主缓存(loadEnrichCacheReadOnly)之后,正在播的那首的单条快照 path 比
// 主缓存 cachePath 新,就把那一条盖进内存(同 App 的 EnrichCacheReader.lookup,按 mtime 挑)。常驻进程整份落盘最多攒
// enrichBackgroundSaveDelay,刚放起来的这首在那之前只在快照里:不盖的话手动搜索读不到它的 ISRC、Amazon 曲目页、
// 学到的署名,见 09 章决策 245。只读,不写任何文件。
func overlayPlayingEntryReadOnly(path, cachePath string) {
	pi, err := os.Stat(path)
	if err != nil {
		return
	}
	if ci, err := os.Stat(cachePath); err == nil && !pi.ModTime().After(ci.ModTime()) {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var f playingEntryFile
	if err := json.Unmarshal(data, &f); err != nil || f.Key == "" {
		return
	}
	enrichMu.Lock()
	if enrichCache == nil {
		enrichCache = map[string]enrichEntry{}
	}
	enrichCache[f.Key] = f.Entry
	enrichMu.Unlock()
}
