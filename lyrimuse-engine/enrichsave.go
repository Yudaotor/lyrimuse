package main

import (
	"bufio"
	"encoding/json"
	"io"
	"log"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// 歌词缓存落盘的两件事:流式写、常驻进程里合并连续保存。
//
// ## 为什么(引擎在活动监视器里占过 1.96 GB)
//
// 缓存文件已经涨到 158 MB / 7928 条。原来每次保存是 `json.Marshal(整份快照)`:编码缓冲按翻倍
// 扩容,最后还要再拷一份给调用方 —— 实测(只读副本,runtime.MemStats)一次保存临时分配约 680 MB,
// 堆向系统要到 1.1 GB;而换歌、预取后面几首、补搜、封面升级、译文回填都会触发保存,一首歌里连着
// 好几次。Go 回收之后不急着把页还给系统,footprint 就停在 2 GB 上下。
//
// ## 流式写
//
// `writeEnrichSnapshot` 按 key 排序后逐条编码、经 bufio 直接写进临时文件,峰值只剩一条条目的编码
// 缓冲。输出跟 `json.Marshal(map)` **逐字节一致**(同样按 key 排序、同样的 HTML 转义、条目各自
// 走同一个 MarshalJSON),单测钉住 —— App 那边的读取、备份比对都不受影响。
//
// 条目直接调 `enrichEntry.MarshalJSON`,不经 `json.Marshal(entry)`:后者拿到 Marshaler 的输出后还要
// 整段再校验、压缩一遍,而 MarshalJSON 的输出本来就是 json.Marshal 编出来的(已压缩、已做 HTML 转义),
// 那一遍一个字节都不改。8600 多条的缓存上,那一遍占了一次保存的四分之三(0.7~0.9 秒 → 0.16~0.22 秒),
// 切歌前后连着保存十来次时引擎就一直顶在 60%~100%。
//
// ## 合并连续保存
//
// 每次整份落盘都要重写整个主缓存(几十 MB),App 也要跟着比对、采纳一遍(`EnrichCacheReader`),所以整份落盘能攒就攒
// (见 15 章决策 23、26):
//
//   - 改了正在播的那首(`noteEnrichPlayingKey` 记下的 key):当场写一份这一首的单条快照(`writePlayingEntry`,
//     App 查当前这首先看它),整份落盘跟别的改动一样攒着。
//   - 改动走 `requestEnrichSaveFor` / `requestEnrichBackgroundSave`,最多攒 `enrichBackgroundSaveDelay` 整份写一次;
//     只推进记账字段的(`requestEnrichBookkeepingSave`)最多攒 `enrichBookkeepingSaveDelay`。两种延后共用一个
//     定时器,先到期的为准;到点走 `requestEnrichSave`,距上次保存不到 `enrichSaveMinInterval` 就等到那一刻。
//   - 换歌那一拍:内存里已经有新这首的条目(预取过)就当场写它的单条快照,排着的延后存盘提前到现在。
//   - 整份写盘期间正在播的那首又改过:写完补写一次单条快照(`saveKeepingPlayingEntryFresh`)。
//
// 只在常驻进程里节流(`enableEnrichSaveThrottle`,main 在进 run 之前打开):命令行子命令存完就退出,
// 排上的补写会随进程一起丢;测试也要同步写才能读回。默认关着 = 每次都当场写。
// 常驻进程退出前 `flushEnrichSave` 把排着的补写当场做掉。

// enrichSaveMinInterval 两次保存之间的最小间隔(节流打开时)。
var enrichSaveMinInterval = 2 * time.Second

// enrichBackgroundSaveDelay 改动最多攒多久才整份落盘(正在播的那首另有单条快照,见文件头注)。
var enrichBackgroundSaveDelay = 30 * time.Second

var (
	enrichSaveThrottleMu sync.Mutex
	enrichSaveThrottled  bool
	enrichLastSaveAt     time.Time
	enrichSaveTimer      *time.Timer
	// enrichDeferredSaveTimer 排着的那次延后存盘,到点走 requestEnrichSave;enrichDeferredSaveAt 是它到点的时刻。
	// enrichDeferredSaveSeq 每排一次、每取消一次都加一:被提前、被取消的旧定时器回调对不上号就什么都不做。
	enrichDeferredSaveTimer *time.Timer
	enrichDeferredSaveAt    time.Time
	enrichDeferredSaveSeq   uint64
	// enrichSaveNow 可换(单测用),默认当场执行一次保存。
	enrichSaveNow = func() { saveKeepingPlayingEntryFresh(saveEnrichCache) }
)

// enableEnrichSaveThrottle 打开常驻进程的保存节流。只在 main 进 run 之前调一次。
func enableEnrichSaveThrottle() {
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled = true
	enrichSaveThrottleMu.Unlock()
}

// requestEnrichSave 整份落盘一次:延后存盘到点、换歌提前的那一次都走它,距上次保存不到 enrichSaveMinInterval
// 就等到那一刻。调用方跟调 saveEnrichCache 一样:先置脏、解锁 enrichMu,再调它。
func requestEnrichSave() {
	enrichSaveThrottleMu.Lock()
	if !enrichSaveThrottled {
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow()
		return
	}
	if enrichSaveTimer != nil {
		// 已经排了一次补写:这次的改动会被它一起带上(补写时才取快照)。
		enrichSaveThrottleMu.Unlock()
		return
	}
	wait := enrichSaveMinInterval - time.Since(enrichLastSaveAt)
	if wait <= 0 {
		enrichLastSaveAt = time.Now()
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow()
		return
	}
	enrichSaveTimer = time.AfterFunc(wait, func() {
		enrichSaveThrottleMu.Lock()
		enrichSaveTimer = nil
		enrichLastSaveAt = time.Now()
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow()
	})
	enrichSaveThrottleMu.Unlock()
}

// enrichPlayingKey 此刻在播的那首的缓存 key,poller 换歌那一拍记下(`noteEnrichPlayingKey`)。
// 别挪进 `trackEnrichment`:它也会被「上一首」调到(切歌后给上一首提交收听、Mac 空闲时中继推上一首的
// 历史),在那里记会在新歌首次出词的那一刻把 key 换成上一首,新歌那次提交就被节流推迟了。
var enrichPlayingKey atomic.Pointer[string]

func isEnrichPlayingKey(key string) bool {
	cur := enrichPlayingKey.Load()
	return cur != nil && *cur == key
}

// noteEnrichPlayingKey 换歌那一拍记下正在播的那首。内存里已经有这首的条目(预取过)就当场写它的单条快照:
// 它的整份落盘可能还攒着,App 先读快照出词。排着的延后存盘提前到现在,另起 goroutine 写,不让 poller 等一次整份写。
func noteEnrichPlayingKey(key string) {
	if isEnrichPlayingKey(key) {
		return
	}
	enrichPlayingKey.Store(&key)
	writePlayingEntry(key)
	enrichSaveThrottleMu.Lock()
	pending := cancelEnrichDeferredSaveLocked()
	enrichSaveThrottleMu.Unlock()
	if pending {
		go requestEnrichSave()
	}
}

// commitEnrichSave 是 `commitEnrichEntry` 的落盘入口。**正在播的这首**当场写单条快照(playingentry.go):
// 那一刻就是歌词出现在界面上的时刻,App 查当前这首先看它,不等整份缓存。整份落盘攒着,规则见文件头注
// (09 章决策 108、15 章决策 26)。
func commitEnrichSave(key string) {
	commitEnrichSaveTimed(key, nil)
}

// commitEnrichSaveTimed 同 commitEnrichSave,顺带给 commitEnrichEntrySince 的分段计时记两段。
func commitEnrichSaveTimed(key string, timer *stepTimer) {
	if notePlayingEntryChanged(key) {
		timer.mark("playing_entry")
	}
	requestEnrichDeferredSave(enrichBackgroundSaveDelay)
	timer.mark("save")
}

// requestEnrichSaveFor key 那一条改了:正在播的那首当场写单条快照;整份落盘攒着,最多 enrichBackgroundSaveDelay。
// 调用方同 requestEnrichSave。
func requestEnrichSaveFor(key string) {
	notePlayingEntryChanged(key)
	requestEnrichDeferredSave(enrichBackgroundSaveDelay)
}

// enrichPlayingChanges 正在播的那首改过几次(notePlayingEntryChanged 加一),整份写盘前后对一下,见 saveKeepingPlayingEntryFresh。
var enrichPlayingChanges atomic.Uint64

// notePlayingEntryChanged key 是正在播的那首就记一次改动、当场写它的单条快照,返回是不是。调用方先改完内存里那一条。
func notePlayingEntryChanged(key string) bool {
	if !isEnrichPlayingKey(key) {
		return false
	}
	enrichPlayingChanges.Add(1)
	writePlayingEntry(key)
	return true
}

// saveKeepingPlayingEntryFresh 整份存盘一次;这期间正在播的那首又改过,写完补写一次它的单条快照。主缓存先取快照、
// 写完才改名,这期间写的单条快照 mtime 比主缓存旧、内容却更新,App 按 mtime 挑,不补写就会改读主缓存里旧的那份。
func saveKeepingPlayingEntryFresh(save func()) {
	before := enrichPlayingChanges.Load()
	save()
	if enrichPlayingChanges.Load() == before {
		return
	}
	if key := enrichPlayingKey.Load(); key != nil {
		writePlayingEntry(*key)
	}
}

// requestEnrichBackgroundSave 后台扫一遍改了一批别的歌(没有单独一个 key):攒着,同 requestEnrichSaveFor 里别的歌。
func requestEnrichBackgroundSave() {
	requestEnrichDeferredSave(enrichBackgroundSaveDelay)
}

// enrichBookkeepingSaveDelay 只推进了记账字段(重试计数 / 时间戳)的改动最多攒多久才落盘。
var enrichBookkeepingSaveDelay = 60 * time.Second

// requestEnrichBookkeepingSave 是「这一趟一个歌词字段都没换,只推进了重试计数 / 时间戳」时的保存入口
// (升级重试、重评)。全量扫库、补空扫描每首都走这两条路,大多数一个字都没改:每首都整份写一次主缓存
// (三十几 MB),App 跟着整份重读、重算一遍,一场扫库下来两边都断断续续满载。记账字段晚一点落盘没人
// 等着看:攒着跟下一次正常保存一起写(那次保存取快照时会带上它们),没有别的保存时最多
// enrichBookkeepingSaveDelay 之后补写一次。正在播的这首当场写单条快照,整份同样攒着;退出前 flushEnrichSave 一并写掉。
func requestEnrichBookkeepingSave(key string) {
	notePlayingEntryChanged(key)
	requestEnrichDeferredSave(enrichBookkeepingSaveDelay)
}

// requestEnrichDeferredSave 最多 delay 之后整份落盘一次:已经排着的那次到点更早就不动它,更晚就提前到这次。
// 节流关着(CLI / 测试)时当场写。
func requestEnrichDeferredSave(delay time.Duration) {
	enrichSaveThrottleMu.Lock()
	if !enrichSaveThrottled {
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow()
		return
	}
	at := time.Now().Add(delay)
	if enrichDeferredSaveTimer != nil && !at.Before(enrichDeferredSaveAt) {
		enrichSaveThrottleMu.Unlock()
		return
	}
	cancelEnrichDeferredSaveLocked()
	seq := enrichDeferredSaveSeq
	enrichDeferredSaveAt = at
	enrichDeferredSaveTimer = time.AfterFunc(delay, func() {
		enrichSaveThrottleMu.Lock()
		if seq != enrichDeferredSaveSeq {
			enrichSaveThrottleMu.Unlock()
			return
		}
		enrichDeferredSaveTimer = nil
		enrichSaveThrottleMu.Unlock()
		requestEnrichSave()
	})
	enrichSaveThrottleMu.Unlock()
}

// cancelEnrichDeferredSaveLocked 取消排着的延后存盘,返回之前有没有排着。调用方持 enrichSaveThrottleMu。
func cancelEnrichDeferredSaveLocked() bool {
	enrichDeferredSaveSeq++
	if enrichDeferredSaveTimer == nil {
		return false
	}
	enrichDeferredSaveTimer.Stop()
	enrichDeferredSaveTimer = nil
	return true
}

// flushEnrichSave 取消排着的补写并当场保存一次(没有脏数据时 saveEnrichCache 自己会直接返回)。
// 常驻进程退出前调。
func flushEnrichSave() {
	enrichSaveThrottleMu.Lock()
	if enrichSaveTimer != nil {
		enrichSaveTimer.Stop()
		enrichSaveTimer = nil
	}
	cancelEnrichDeferredSaveLocked()
	enrichLastSaveAt = time.Now()
	enrichSaveThrottleMu.Unlock()
	enrichSaveNow()
}

// writeEnrichSnapshot 把快照按 `json.Marshal(map)` 的格式流式写出:`{"k1":v1,"k2":v2}`,
// key 按字节序排序。
func writeEnrichSnapshot(w io.Writer, snapshot map[string]enrichEntry) error {
	keys := make([]string, 0, len(snapshot))
	for k := range snapshot {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	bw := bufio.NewWriterSize(w, 256<<10)
	if err := bw.WriteByte('{'); err != nil {
		return err
	}
	for i, k := range keys {
		if i > 0 {
			if err := bw.WriteByte(','); err != nil {
				return err
			}
		}
		kb, err := json.Marshal(k)
		if err != nil {
			return err
		}
		vb, err := snapshot[k].MarshalJSON()
		if err != nil {
			return err
		}
		if _, err := bw.Write(kb); err != nil {
			return err
		}
		if err := bw.WriteByte(':'); err != nil {
			return err
		}
		if _, err := bw.Write(vb); err != nil {
			return err
		}
	}
	if err := bw.WriteByte('}'); err != nil {
		return err
	}
	return bw.Flush()
}

// staleEnrichTempAge:主缓存保存用的临时文件(`<缓存名>.tmp.<随机>`)超过这么久还在,就是保存中途被打断
// (被强杀 / 断电 / 磁盘满)的残骸 —— 正常保存几秒内就改名成正式文件。一天远大于任何一次正常保存,
// 不会误删另一个进程(命令行子命令)正在写的那一份。
const staleEnrichTempAge = 24 * time.Hour

// removeStaleEnrichTemps 删掉超过 staleEnrichTempAge 的保存残骸。实测本机攒过 9 份、555 MB,
// 从来没人清过。只认 os.CreateTemp 在 saveEnrichCache 里起的那种名字,别的文件(各次迁移前的备份
// `backup-*` / `*.bak*`)一概不碰。常驻进程启动时调一次。
func removeStaleEnrichTemps() {
	if enrichPath == "" {
		return
	}
	if removed, freed := removeStaleWriteTemps(enrichPath, staleEnrichTempAge); removed > 0 {
		log.Printf("enrich cache: removed %d stale save temp file(s), %d MB freed", removed, freed>>20)
	}
}
