package main

import (
	"encoding/json"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// 整份落盘攒着的这段时间里改过的条目:`lyrimuse-enrich-pending.json` = {"entries": {key: 完整条目}}。
//
// 主缓存每次都整份重写(二十几 MB),而一次改动通常只有几条:放歌时后台预取、补全、扫库一直在改别的歌,
// 原来 30 秒攒一次,一小时整份写上百次、两三 GB(15 章决策 26 之后的实测)。整份落盘放宽到
// enrichBackgroundSaveDelay 之后,改过的条目先写进这份小文件(enrichPendingWriteDelay 攒一下):
//   - App 读主缓存时,这份比主缓存新就把它的条目叠上去(歌词管理的列表、补空扫描的进度不用等整份落盘);一次性子命令
//     只读加载(loadEnrichCacheReadOnly)时同样叠上去;
//   - 引擎启动时这份比主缓存新就叠回内存(上一次没来得及整份落盘就退出 / 崩溃,改动不丢);
//   - 整份落盘之后清掉已经写进主缓存的那些 key,一条不剩就删掉文件。
//
// 记的是带 key 的存盘入口(commitEnrichSaveTimed / requestEnrichSaveFor / requestEnrichBookkeepingSave)。
// 不带 key 的后台批量改动(requestEnrichBackgroundSave)不进这份,等整份落盘;直接 saveEnrichCache 的路径当场整份写,
// 也不用进。见 15 章决策 36。
func enrichPendingPath() string {
	if enrichPath == "" {
		return ""
	}
	return enrichPendingPathFor(enrichPath)
}

// enrichPendingPathFor:主缓存 cachePath 旁边那份待落盘小文件。
func enrichPendingPathFor(cachePath string) string {
	return filepath.Join(filepath.Dir(cachePath), clientName+"-enrich-pending.json")
}

type enrichPendingFile struct {
	Entries map[string]enrichEntry `json:"entries"`
}

// enrichPendingWriteDelay:改动攒多久写一次小文件。解析一首要连着提交好几次,一秒内的合成一次。
var enrichPendingWriteDelay = time.Second

// enrichPendingMaxKeys:攒到这么多条就不等了,当场整份落盘(小文件里是完整条目、带正文,太多就不小了)。
const enrichPendingMaxKeys = 200

var (
	// enrichPendingKeys:还没写进主缓存的 key → 记下它的那一次的序号。只在 enrichMu 临界区内读写。
	enrichPendingKeys = map[string]uint64{}
	enrichPendingSeq  uint64
	// enrichPendingHasNew:这批里有之前不在缓存里的 key(新歌):写完小文件提醒歌曲实体增量重算,不等整份落盘。
	enrichPendingHasNew bool

	enrichPendingTimerMu sync.Mutex
	enrichPendingTimer   *time.Timer
	// enrichPendingWriteMu 把「读条目 → 写文件」整段串起来,同 playingEntryWriteMu。锁序:先它后 enrichMu。
	enrichPendingWriteMu sync.Mutex
	// enrichPendingNow 可换(单测用),默认就是写一次小文件。
	enrichPendingNow = writeEnrichPending
)

// noteEnrichPending 记下 key 改过、还没整份落盘;isNew = 这一条之前不在缓存里。调用方不持 enrichMu。
func noteEnrichPending(key string, isNew bool) {
	if key == "" || enrichPendingPath() == "" {
		return
	}
	enrichMu.Lock()
	noteEnrichPendingLocked(key)
	if isNew {
		enrichPendingHasNew = true
	}
	full := len(enrichPendingKeys) >= enrichPendingMaxKeys
	enrichMu.Unlock()
	if full {
		go requestEnrichSave()
		return
	}
	scheduleEnrichPendingWrite()
}

// noteEnrichPendingLocked 同 noteEnrichPending 的记账部分,调用方持 enrichMu,写小文件由调用方另外安排(scheduleEnrichPendingWrite)。
func noteEnrichPendingLocked(key string) {
	enrichPendingSeq++
	enrichPendingKeys[key] = enrichPendingSeq
}

func scheduleEnrichPendingWrite() {
	enrichPendingTimerMu.Lock()
	defer enrichPendingTimerMu.Unlock()
	if enrichPendingTimer != nil {
		return
	}
	enrichPendingTimer = time.AfterFunc(enrichPendingWriteDelay, func() {
		enrichPendingTimerMu.Lock()
		enrichPendingTimer = nil
		enrichPendingTimerMu.Unlock()
		enrichPendingNow()
	})
}

// saveEnrichPendingBatch:后台一批改动之后落盘,keys 是这批改过的条目,调用方已在锁里逐条记了 noteEnrichPendingLocked。正在播的
// 那首在里面就重写它的单条快照:App 读正在播的这首先看快照,快照比主缓存新时不看小文件。小文件里没攒满 enrichPendingMaxKeys 条
// 就写小文件、排一次延后整份落盘,攒满了才当场整份写(小文件里是完整条目,太多就不小了)。改的是已有条目时不提醒歌曲实体增量
// 重算,补上的 id 等下一次整份落盘再进实体表。调用方不持 enrichMu。见 15 章决策 39。
func saveEnrichPendingBatch(keys []string) {
	for _, k := range keys {
		notePlayingEntryChanged(k)
	}
	enrichMu.Lock()
	full := len(enrichPendingKeys) >= enrichPendingMaxKeys
	enrichMu.Unlock()
	if full {
		saveEnrichCache()
		return
	}
	scheduleEnrichPendingWrite()
	requestEnrichBackgroundSave()
}

// writeEnrichPending 把还没整份落盘的条目写成小文件;一条都没有就删掉文件。
func writeEnrichPending() {
	path := enrichPendingPath()
	if path == "" {
		return
	}
	enrichPendingWriteMu.Lock()
	defer enrichPendingWriteMu.Unlock()
	enrichMu.Lock()
	entries := make(map[string]enrichEntry, len(enrichPendingKeys))
	for k := range enrichPendingKeys {
		if e, ok := enrichCache[k]; ok {
			entries[k] = e
		}
	}
	hasNew := enrichPendingHasNew
	enrichPendingHasNew = false
	enrichMu.Unlock()
	if len(entries) == 0 {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			slog.Error("enrich pending: remove", "err", err)
		}
		return
	}
	// 候选明细给 App 没用,跟主缓存落盘时一样拆掉(明细由整份写盘写进旁路文件)。
	for k, e := range entries {
		if stripped, _, split := splitDecisionDetails(k, e); split {
			entries[k] = stripped
		}
	}
	b, err := json.Marshal(enrichPendingFile{Entries: entries})
	if err == nil {
		err = writeFileAtomic(path, b)
	}
	if err != nil {
		slog.Error("enrich pending: write", "entries", len(entries), "err", err)
		return
	}
	if hasNew {
		noteSongEntityCacheSaved()
	}
}

// enrichPendingSeqLocked:整份落盘取快照那一刻的序号,写完之后按它清(enrichPendingSavedThrough)。调用方持 enrichMu。
func enrichPendingSeqLocked() uint64 { return enrichPendingSeq }

// enrichPendingSavedThrough:整份落盘成功,序号不超过 seq 的 key 都已经在主缓存里了。取快照之后又改过的留着,
// 重写一次小文件(这时它比主缓存新,App 会叠上去);一条不剩就删掉文件。
func enrichPendingSavedThrough(seq uint64) {
	enrichMu.Lock()
	for k, s := range enrichPendingKeys {
		if s <= seq {
			delete(enrichPendingKeys, k)
		}
	}
	enrichMu.Unlock()
	enrichPendingNow()
}

// readEnrichPendingIfNewer:待落盘小文件 path 比主缓存 cachePath 新(主缓存不在也算)时读出它的条目;比主缓存旧(已经写进去了)、
// 不在、读不了都是 nil。
func readEnrichPendingIfNewer(path, cachePath string) map[string]enrichEntry {
	pst, err := os.Stat(path)
	if err != nil {
		return nil
	}
	if cst, err := os.Stat(cachePath); err == nil && !pst.ModTime().After(cst.ModTime()) {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		slog.Error("enrich pending: read", "err", err)
		return nil
	}
	var f enrichPendingFile
	if err := json.Unmarshal(data, &f); err != nil {
		slog.Error("enrich pending: unreadable, ignored", "err", err)
		return nil
	}
	return f.Entries
}

// applyEnrichPendingAtLoad:启动读完主缓存之后调。小文件比主缓存新,说明上一次退出前那批改动没来得及整份落盘:
// 叠回内存、记成待落盘,下一次整份保存一并写掉。比主缓存旧的是已经写进去了,不动(下一次写小文件时会删掉)。
func applyEnrichPendingAtLoad(cachePath string) {
	path := enrichPendingPath()
	if path == "" {
		return
	}
	entries := readEnrichPendingIfNewer(path, cachePath)
	if len(entries) == 0 {
		return
	}
	enrichMu.Lock()
	for k, e := range entries {
		enrichCache[k] = e
		enrichPendingSeq++
		enrichPendingKeys[k] = enrichPendingSeq
	}
	enrichDirty = true
	enrichMu.Unlock()
	log.Printf("cache: restored %d entries changed after the last full save", len(entries))
}
