package main

import (
	"bufio"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// 歌词缓存落盘的两件事:流式写、常驻进程里合并连续保存。
//
// ## 为什么(collector 在活动监视器里占过 1.96 GB)
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
// 切歌前后连着保存十来次时 collector 就一直顶在 60%~100%。
//
// ## 合并连续保存
//
// App 靠这个文件的 mtime 发现新歌词(`EnrichCacheReader`,播放时每 2 秒轮询一次),所以**第一次**
// 保存绝不能晚:`requestEnrichSave` 是「先写、再节流」—— 距上次保存超过 `enrichSaveMinInterval`
// 就当场写;间隔内再来的请求只排一次到点补写,期间再多的请求都合进这一次。后续更新(晚到的译文、
// 换上来的更好的歌词)最多晚 2 秒,落在 App 轮询的粒度之内。
//
// 例外:`commitEnrichEntry` 提交的若是**正在播的这首**,当场写(`commitEnrichSave`),并且在整份写盘
// 之前先写一份这一首的单条快照(`writePlayingEntry`)。
//
// 只在常驻进程里节流(`enableEnrichSaveThrottle`,main 在进 run 之前打开):命令行子命令存完就退出,
// 排上的补写会随进程一起丢;测试也要同步写才能读回。默认关着 = 跟原来一样当场写。
// 常驻进程退出前 `flushEnrichSave` 把排着的那次补写当场做掉。

// enrichSaveMinInterval 两次保存之间的最小间隔(节流打开时)。
var enrichSaveMinInterval = 2 * time.Second

var (
	enrichSaveThrottleMu sync.Mutex
	enrichSaveThrottled  bool
	enrichLastSaveAt     time.Time
	enrichSaveTimer      *time.Timer
	// enrichSaveNow 可换(单测用),默认当场执行一次保存。
	enrichSaveNow = saveEnrichCache
)

// enableEnrichSaveThrottle 打开常驻进程的保存节流。只在 main 进 run 之前调一次。
func enableEnrichSaveThrottle() {
	enrichSaveThrottleMu.Lock()
	enrichSaveThrottled = true
	enrichSaveThrottleMu.Unlock()
}

// requestEnrichSave 是播放热路径上的保存入口,规则见文件头注。调用方跟调 saveEnrichCache 一样:
// 先置脏、解锁 enrichMu,再调它。
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

func noteEnrichPlayingKey(key string) {
	if cur := enrichPlayingKey.Load(); cur != nil && *cur == key {
		return
	}
	enrichPlayingKey.Store(&key)
}

// commitEnrichSave 是 `commitEnrichEntry` 的落盘入口:**正在播的这首**当场写(那一刻就是歌词出现在
// 界面上的时刻 —— App 读的是这个文件,见 09 章决策 78「首次出词提速」;前 2 秒内刚写过盘,比如上一首
// 的收尾或预解析刚落盘,也不能让它等),预解析别的歌走节流。当场写也顺手取消排着的补写:这次快照
// 已经把它们带上了。整份写盘要好几秒,所以先写这一首的单条快照(playingentry.go),App 读它先出词。
func commitEnrichSave(key string) {
	if cur := enrichPlayingKey.Load(); cur != nil && *cur == key {
		writePlayingEntry(key)
		flushEnrichSave()
		return
	}
	requestEnrichSave()
}

// flushEnrichSave 取消排着的补写并当场保存一次(没有脏数据时 saveEnrichCache 自己会直接返回)。
// 常驻进程退出前调。
func flushEnrichSave() {
	enrichSaveThrottleMu.Lock()
	if enrichSaveTimer != nil {
		enrichSaveTimer.Stop()
		enrichSaveTimer = nil
	}
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
	pattern := filepath.Join(filepath.Dir(enrichPath), filepath.Base(enrichPath)+".tmp.*")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return
	}
	var removed int
	var freed int64
	for _, m := range matches {
		info, err := os.Stat(m)
		if err != nil || info.IsDir() || time.Since(info.ModTime()) < staleEnrichTempAge {
			continue
		}
		if os.Remove(m) == nil {
			removed++
			freed += info.Size()
		}
	}
	if removed > 0 {
		log.Printf("enrich cache: removed %d stale save temp file(s), %d MB freed", removed, freed>>20)
	}
}
