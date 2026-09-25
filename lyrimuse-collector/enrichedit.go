package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// 歌词缓存的改动一律由 collector 来做:App 的「歌词管理」、各处「采纳候选」、批量锁定、删除、清空、
// 从自动快照恢复,都不自己写 enrich-cache.json 和 lyrics/ 文件,而是把要做的事写成一份请求交给这里。
// collector 是这份缓存唯一的写入方,在内存里改完、存盘、同步歌词文件,改完不用重启。
//
// 两个写入方会互相覆盖:collector 每次存盘都是把整份内存 map 写回去,App 在它背后改盘上的文件,
// 下一次存盘就被盖掉。所以别在 App 侧再加直接写缓存或歌词文件的路径,新的改动种类照这里加一个 op。
//
// 通道:<配置目录>/lyrimuse-enrich-requests/ 下,App 原子写 <id>.json(临时名 + 改名),collector
// 每 enrichEditPollInterval 扫一次,按文件名顺序处理,处理完删掉请求、写 <id>.result.json(App 读完删)。
// 后台服务没在跑时,App 跑 `collector apply-enrich-edit <请求文件>`,先拿单实例锁再走同一段
// applyEnrichEdit,结果打到 stdout。

const (
	enrichEditPollInterval = 250 * time.Millisecond
	// enrichEditStaleAfter:比这更老的请求不再执行。App 等结果最多等十几秒,等不到就已经跟用户报了失败,
	// 过后再悄悄执行会让用户看到一个自己以为没成的改动。
	enrichEditStaleAfter = time.Minute
)

// enrichEditDir 由 main() 设好;空 = 不收请求(CLI 子命令、测试)。
var enrichEditDir string

// 改动序号:每执行一次改动加一,记下被改的 key 在哪个序号上被改(清空 / 恢复记在 enrichEditAllAt)。
// 后台任务(首次解析、升级重试、重评分、机翻)开跑时用 enrichEditStampLocked 记下当时的序号,落盘前用
// enrichEditedSinceLocked 核对:这期间这个 key 被改过,那一轮是按改动之前的状态算的,整轮作废,
// 否则删掉的条目会被写回、刚采纳或手改的歌词会被换回自动结果。由 enrichMu 保护。
var (
	enrichEditSeq   uint64
	enrichEditedAt  = map[string]uint64{}
	enrichEditAllAt uint64
)

// enrichEditNoStamp:不做改动核对(测试与不属于任何一轮后台任务的写入)。
const enrichEditNoStamp = ^uint64(0)

// enrichEditStampLocked 是后台任务开跑时要记下的序号。调用方持 enrichMu。
func enrichEditStampLocked() uint64 { return enrichEditSeq }

// enrichEditedSinceLocked:stamp 之后这个 key 有没有被改过。调用方持 enrichMu。
func enrichEditedSinceLocked(key string, stamp uint64) bool {
	if stamp == enrichEditNoStamp {
		return false
	}
	return enrichEditAllAt > stamp || enrichEditedAt[key] > stamp
}

// markEnrichEditedLocked 记下这几个 key 刚被改过;all = 整份缓存都算(清空、恢复)。调用方持 enrichMu。
func markEnrichEditedLocked(all bool, keys ...string) {
	enrichEditSeq++
	if all {
		enrichEditAllAt = enrichEditSeq
		clear(enrichEditedAt)
		return
	}
	for _, k := range keys {
		enrichEditedAt[k] = enrichEditSeq
	}
}

// enrichRestorePath 是「从自动快照恢复」留下的待采纳文件(见 enrichrestore.go),由 main() / CLI 设好。
var enrichRestorePath string

type enrichEditRequest struct {
	ID   string   `json:"id"`
	Op   string   `json:"op"`
	Key  string   `json:"key,omitempty"`
	Keys []string `json:"keys,omitempty"`

	// save_edit
	Lyrics               string          `json:"lyrics,omitempty"`
	Tr                   string          `json:"tr,omitempty"`
	Roma                 string          `json:"roma,omitempty"`
	YRC                  *string         `json:"yrc,omitempty"`
	Source               string          `json:"source,omitempty"`
	MarkManual           bool            `json:"mark_manual,omitempty"`
	SourceChoice         *string         `json:"source_choice,omitempty"`
	FromManualPick       bool            `json:"from_manual_pick,omitempty"`
	Score                *int            `json:"score,omitempty"`
	ScoringVersion       *int            `json:"scoring_version,omitempty"`
	ResolvedDurationSecs float64         `json:"resolved_duration_secs,omitempty"`
	SourcesSeen          []string        `json:"sources_seen,omitempty"`
	SourcesResponded     []string        `json:"sources_responded,omitempty"`
	Decision             json.RawMessage `json:"decision,omitempty"`

	// save_plain_text
	PlainLyrics       string `json:"plain_lyrics,omitempty"`
	PlainLyricsSource string `json:"plain_lyrics_source,omitempty"`

	// set_instrumental / set_manual_lock
	Value bool `json:"value,omitempty"`
}

type enrichEditResult struct {
	ID      string `json:"id"`
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
	Changed int    `json:"changed"`
}

// enrichEditOutcome 是一次改动之后要在锁外做的事。
type enrichEditOutcome struct {
	changed  int
	exports  []string // 要重新导出歌词文件的 key
	trash    []string // 要把歌词文件挪进废纸篓、删掉判决旁路文件的 key(删除)
	dropped  []string // 只删判决旁路文件的 key(清空:歌词文件由 trashAll 按目录整批处理)
	trashAll bool     // 清空:歌词目录里认得出的歌词文件全部挪进废纸篓
	err      error
}

// applyEnrichEdit 执行一份请求:改内存缓存、存盘、同步歌词文件。常驻进程和 CLI 子命令共用。
func applyEnrichEdit(req enrichEditRequest) enrichEditResult {
	res := enrichEditResult{ID: req.ID}
	var out enrichEditOutcome
	switch req.Op {
	case "adopt_restore":
		out = adoptRestoreEdit()
	default:
		enrichMu.Lock()
		out = applyEnrichEditLocked(req)
		if out.err == nil && out.changed > 0 {
			enrichDirty = true
			touched := append(append([]string{}, out.exports...), out.trash...)
			if req.Key != "" {
				touched = append(touched, req.Key)
			}
			markEnrichEditedLocked(req.Op == "clear_all", touched...)
		}
		enrichMu.Unlock()
	}
	if out.err != nil {
		res.Error = out.err.Error()
		log.Printf("enrich edit: op=%s failed: %v", req.Op, out.err)
		return res
	}
	if out.changed > 0 {
		// 先把删掉的那几首的文件挪走、再存盘导出:导出只写还在缓存里的条目,顺序反过来也不会复活
		// 它们,但先挪走能让「存盘之后盘上就是最终状态」这件事不依赖导出的实现细节。
		for _, k := range out.trash {
			for _, path := range lyricsFilesOwnedBy(k) {
				trashFile(path)
			}
			removeDecisionSidecar(k)
		}
		for _, k := range out.dropped {
			removeDecisionSidecar(k)
		}
		if out.trashAll {
			trashAllLyricsFiles()
		}
		saveEnrichCache()
		exportLyricsFilesFor(out.exports...)
		nudgeEnrichPush()
	}
	res.OK = true
	res.Changed = out.changed
	log.Printf("enrich edit: op=%s changed=%d", req.Op, out.changed)
	return res
}

// applyEnrichEditLocked 改内存里的缓存。调用方持 enrichMu。
func applyEnrichEditLocked(req enrichEditRequest) enrichEditOutcome {
	switch req.Op {
	case "save_edit":
		if req.Key == "" {
			return enrichEditOutcome{err: fmt.Errorf("save_edit: empty key")}
		}
		e := enrichCache[req.Key]
		if err := applySaveEdit(&e, req); err != nil {
			return enrichEditOutcome{err: err}
		}
		enrichCache[req.Key] = e
		cancelInFlightEnrichLocked(req.Key)
		return enrichEditOutcome{changed: 1, exports: []string{req.Key}}
	case "save_plain_text":
		if req.Key == "" {
			return enrichEditOutcome{err: fmt.Errorf("save_plain_text: empty key")}
		}
		e := enrichCache[req.Key]
		e.PlainLyrics = req.PlainLyrics
		e.PlainLyricsSource = req.PlainLyricsSource
		enrichCache[req.Key] = e
		return enrichEditOutcome{changed: 1}
	case "set_instrumental":
		if req.Key == "" {
			return enrichEditOutcome{err: fmt.Errorf("set_instrumental: empty key")}
		}
		e := enrichCache[req.Key]
		e.Instrumental = req.Value
		enrichCache[req.Key] = e
		return enrichEditOutcome{changed: 1}
	case "record_decision":
		if req.Key == "" || len(req.Decision) == 0 {
			return enrichEditOutcome{err: fmt.Errorf("record_decision: empty key or decision")}
		}
		var d lyricsDecision
		if err := json.Unmarshal(req.Decision, &d); err != nil {
			return enrichEditOutcome{err: fmt.Errorf("record_decision: %w", err)}
		}
		e := enrichCache[req.Key]
		e.LyricsDecision, e.LyricsDecisionApplied = &d, &d
		enrichCache[req.Key] = e
		return enrichEditOutcome{changed: 1}
	case "set_manual_lock":
		var flipped []string
		for k, e := range enrichCache {
			if !manualPickShouldFlip(e.ManualPickSHA, e.Lyrics, e.ManualLyrics, req.Value) {
				continue
			}
			e.ManualLyrics = req.Value
			enrichCache[k] = e
			flipped = append(flipped, k)
		}
		sort.Strings(flipped)
		// 导出的 .lrc 文件头里那行 [manual:1] 是这个标记的第二份存档,importLyricsFromFiles 会拿它把缓存
		// 改回去,所以这几首的文件要一起重写。
		return enrichEditOutcome{changed: len(flipped), exports: flipped}
	case "delete":
		var removed []string
		for _, k := range req.Keys {
			if _, ok := enrichCache[k]; !ok {
				continue
			}
			delete(enrichCache, k)
			cancelInFlightEnrichLocked(k)
			removed = append(removed, k)
		}
		return enrichEditOutcome{changed: len(removed), trash: removed}
	case "clear_all":
		keys := make([]string, 0, len(enrichCache))
		for k := range enrichCache {
			cancelInFlightEnrichLocked(k)
			keys = append(keys, k)
		}
		enrichCache = map[string]enrichEntry{}
		// changed 至少记 1:缓存本来就空时也要清歌词目录(那里可能还有上次没清干净的文件),清空的语义是两边都空。
		return enrichEditOutcome{changed: max(len(keys), 1), dropped: keys, trashAll: true}
	}
	return enrichEditOutcome{err: fmt.Errorf("unknown op %q", req.Op)}
}

// applySaveEdit 是「保存编辑 / 采纳一条候选」对一条缓存记录的全部改动。规则逐条对应原先 App 侧的
// EnrichCacheStore.saveEdit,各条的来由见 docs/features/11 章「编辑保存的字段规则」。
func applySaveEdit(e *enrichEntry, req enrichEditRequest) error {
	var decision *lyricsDecision
	if len(req.Decision) > 0 {
		decision = &lyricsDecision{}
		if err := json.Unmarshal(req.Decision, decision); err != nil {
			return fmt.Errorf("save_edit: decision: %w", err)
		}
	}
	// 译文换了内容:描述旧译文的语言、来源、机翻节流与重试计数一起清掉,别拿旧译文的记录给新内容背书。
	if req.Tr != e.LyricsTr {
		e.LyricsTrLang, e.LyricsTrSource = "", ""
		e.TranslationTS, e.TranslationRetryCount = 0, 0
	}
	// 正文改了、罗马音原样交回来(用户没动那一格):那份罗马音描述的是旧正文,清掉。
	roma := req.Roma
	if roma != "" && req.Lyrics != e.Lyrics && roma == e.LyricsRoma {
		roma = ""
	}
	e.Lyrics, e.LyricsTr, e.LyricsRoma = req.Lyrics, req.Tr, roma
	e.ManualLyrics = req.MarkManual
	// nil = 不动;空串 = 显式清掉(交回算法自由选源)。
	if req.SourceChoice != nil {
		e.LyricsSourceChoice = *req.SourceChoice
	}
	// 打分留痕成对写,缺一个就都不动。
	if req.Score != nil && req.ScoringVersion != nil {
		e.LyricsScore, e.LyricsScoringVersion = *req.Score, *req.ScoringVersion
	}
	if req.ResolvedDurationSecs > 0 {
		e.ResolvedDurationSecs = req.ResolvedDurationSecs
	}
	if len(req.SourcesSeen) > 0 {
		e.LyricsSourcesSeen = req.SourcesSeen
	}
	if len(req.SourcesResponded) > 0 {
		e.LyricsSourcesResponded = req.SourcesResponded
	}
	if decision != nil {
		e.LyricsDecision, e.LyricsDecisionApplied = decision, decision
	}
	// nil = 不动;空串 = 清掉逐字时间轴。
	if req.YRC != nil {
		e.LyricsYRC = *req.YRC
	}
	e.LyricsSource = req.Source
	// 「手动采纳的候选」留内容指纹,供「手动选定歌词后锁定」追溯;别的保存一律清掉(旧指纹已不描述新正文)。
	e.ManualPickSHA = ""
	if req.FromManualPick {
		e.ManualPickSHA = manualPickFingerprint(req.Lyrics)
	}
	return nil
}

// manualPickShouldFlip:「手动选定歌词后锁定」开关翻到 locking 时,这条要不要跟着翻。用户采纳过、
// 他选的那一份还在(指纹对得上),而且当前锁定状态跟目标相反。跟 Swift 侧 ManualPickLock.shouldFlip 同一判据。
func manualPickShouldFlip(sha, lyrics string, isLocked, locking bool) bool {
	return sha != "" && sha == manualPickFingerprint(lyrics) && isLocked != locking
}

// cancelInFlightEnrichLocked 取消这个 key 还在飞的解析,免得它搜完把刚做的改动盖掉。调用方持 enrichMu。
func cancelInFlightEnrichLocked(key string) {
	if cancel, ok := enrichCancelFuncs[key]; ok {
		cancel()
	}
}

// adoptRestoreEdit:「从自动快照恢复」已经把歌词文件铺进歌词目录、把非歌词字段留在待采纳文件里,
// 这里把两样都收进缓存(字段先采纳,歌词文件赢),再整份导出。启动迁移水位作废:恢复进来的是更早
// 形态的数据,下次启动让存量迁移照常全量跑。
func adoptRestoreEdit() enrichEditOutcome {
	adopted := enrichRestorePath != "" && adoptEnrichRestore(enrichRestorePath)
	imported := importLyricsFromFiles()
	if adopted || imported > 0 {
		invalidateMigrationState("restored from a lyrics snapshot")
	}
	enrichMu.Lock()
	enrichDirty = true
	markEnrichEditedLocked(true)
	enrichMu.Unlock()
	saveEnrichCache()
	exportLyricsFiles()
	nudgeEnrichPush()
	return enrichEditOutcome{changed: imported}
}

// nudgeEnrichPush 让主循环立刻重推一拍,正在放的那首马上带上改过的歌词。CLI 子命令里没有主循环,空操作。
func nudgeEnrichPush() {
	if enrichNotify == nil {
		return
	}
	select {
	case enrichNotify <- struct{}{}:
	default:
	}
}

// trashFile 把一个歌词文件挪进废纸篓(~/.Trash),删错了还能捞回来。挪不过去(跨卷、没有废纸篓)就直接删:
// 残留文件会在下次启动被 importLyricsFromFiles 当成用户文件,把刚删掉的条目复活。
func trashFile(path string) {
	if home, err := os.UserHomeDir(); err == nil {
		trash := filepath.Join(home, ".Trash")
		name := filepath.Base(path)
		dst := filepath.Join(trash, name)
		if _, err := os.Stat(dst); err == nil {
			ext := filepath.Ext(name)
			dst = filepath.Join(trash, fmt.Sprintf("%s %d%s", strings.TrimSuffix(name, ext), time.Now().UnixNano(), ext))
		}
		if err := os.Rename(path, dst); err == nil {
			return
		}
	}
	_ = os.Remove(path)
}

// trashAllLyricsFiles 把歌词目录里认得出的歌词文件(四个后缀)全部挪进废纸篓。只认后缀:这个目录是用户
// 可以自己指定的,可能还放着别的东西。
func trashAllLyricsFiles() {
	dir := lyricsDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, ent := range entries {
		if ent.IsDir() || lyricsFileSuffixOf(ent.Name()) == "" {
			continue
		}
		trashFile(filepath.Join(dir, ent.Name()))
	}
}

// setEnrichEditDir 登记请求目录并建好它。只有常驻进程调用。
func setEnrichEditDir(dir string) {
	enrichEditDir = dir
	if dir != "" {
		_ = os.MkdirAll(dir, 0o700)
	}
}

// startEnrichEditWatcher 独立节奏扫请求目录,由 run() 单开 goroutine,ctx 取消时退出。
func startEnrichEditWatcher(ctx context.Context) {
	if enrichEditDir == "" {
		return
	}
	ticker := time.NewTicker(enrichEditPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			processEnrichEditRequests()
		}
	}
}

// processEnrichEditRequests 处理目录里全部待办请求,按文件名顺序(App 用时间戳开头的 id,顺序即提交顺序)。
func processEnrichEditRequests() {
	entries, err := os.ReadDir(enrichEditDir)
	if err != nil {
		return
	}
	var names []string
	for _, ent := range entries {
		name := ent.Name()
		if ent.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		if strings.HasSuffix(name, ".result.json") {
			// App 读完就删;还留着的是它早已不等的(等不到结果就走了),过期后清掉。
			if info, err := ent.Info(); err == nil && time.Since(info.ModTime()) > enrichEditStaleAfter {
				_ = os.Remove(filepath.Join(enrichEditDir, name))
			}
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		path := filepath.Join(enrichEditDir, name)
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		data, err := os.ReadFile(path)
		_ = os.Remove(path)
		if err != nil {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		var res enrichEditResult
		if time.Since(info.ModTime()) > enrichEditStaleAfter {
			log.Printf("enrich edit: dropped a stale request id=%s", id)
			continue
		}
		var req enrichEditRequest
		if err := json.Unmarshal(data, &req); err != nil {
			res = enrichEditResult{ID: id, Error: "unreadable request: " + err.Error()}
		} else {
			req.ID = id
			res = applyEnrichEdit(req)
		}
		writeEnrichEditResult(filepath.Join(enrichEditDir, id+".result.json"), res)
	}
}

// writeEnrichEditResult 原子写结果文件:App 在轮询它,不能读到半截。
func writeEnrichEditResult(path string, res enrichEditResult) {
	data, _ := json.Marshal(res)
	if err := writeFileAtomic(path, data); err != nil {
		log.Printf("enrich edit: write result failed: %v", err)
	}
}

// runApplyEnrichEditCLI 是 `collector apply-enrich-edit <请求文件>`:后台服务没在跑时 App 用它执行同一份请求。
// 结果 JSON 打到 stdout;常驻实例在跑(拿不到单实例锁)时拒绝,免得两个实例各写各的缓存。
func runApplyEnrichEditCLI(args []string) {
	emit := func(res enrichEditResult) {
		data, _ := json.Marshal(res)
		fmt.Println(string(data))
	}
	if len(args) != 1 {
		emit(enrichEditResult{Error: "usage: collector apply-enrich-edit <request.json>"})
		os.Exit(2)
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		emit(enrichEditResult{Error: err.Error()})
		os.Exit(1)
	}
	var req enrichEditRequest
	if err := json.Unmarshal(data, &req); err != nil {
		emit(enrichEditResult{Error: "unreadable request: " + err.Error()})
		os.Exit(1)
	}
	cfgDir := configDir()
	if cfgDir == "" {
		emit(enrichEditResult{ID: req.ID, Error: "cannot resolve the config directory"})
		os.Exit(1)
	}
	if !ensureExclusiveForDedupe(cfgDir) {
		emit(enrichEditResult{ID: req.ID, Error: "collector is running"})
		os.Exit(1)
	}
	setFeatures(loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json")))
	defaultLyricsDir = filepath.Join(cfgDir, "lyrics")
	setLyricsDir(resolveLyricsDir(features().LyricsDir))
	enrichRestorePath = filepath.Join(cfgDir, clientName+"-enrich-restore.json")
	loadMigrationState(filepath.Join(cfgDir, clientName+"-migrations.json"))
	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	res := applyEnrichEdit(req)
	emit(res)
	if !res.OK {
		os.Exit(1)
	}
}
