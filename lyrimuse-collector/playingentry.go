package main

import (
	"encoding/json"
	"log/slog"
	"path/filepath"
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

// writePlayingEntry 把 key 那一条当前的内存状态写成小文件。条目不在(被撤回 / 删了)就不写。
func writePlayingEntry(key string) {
	path := playingEntryPath()
	if path == "" {
		return
	}
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
