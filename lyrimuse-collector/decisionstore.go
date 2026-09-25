package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

// 判决记录的**候选明细**(candidates + queries_tried)不进主缓存,单独存一个目录:
// `<配置目录>/lyrimuse-decisions/<sha256(key) 前 32 位十六进制>.json`,一首歌一个小文件。
//
// ## 为什么(collector 常驻内存)
//
// 主缓存 158 MB / 8064 条里,两槽判决记录占 63 MB(40%),其中 candidates 占 86%、queries_tried
// 占 10%。collector 常驻内存 200 MB 里它们占 90 MB,App 整份解析主缓存也跟着胖。而这两块只有
// 「解析决策」弹窗和离线分析要看 —— 解析逻辑不读判决记录(decision.go 头注铁律 2),collector
// 自己只要胜者的歌手名(`WinnerArtist`,留在主缓存里)。
//
// ## 形状
//
// 主缓存里两槽**只留顶层字段**(路径 / 时间 / 打分版本 / 查询词 / 应答过的源 / 胜者 / WinnerArtist …),
// 旁路文件:
//
//	{"key": "...", "latest": {指纹 + candidates + queries_tried}, "applied": {...}}
//
// 两槽明细一模一样时写 `"applied_same": true`、不再存第二份。**指纹** = path + decided_at +
// scoring_version + winner + reused_from:读的一方(App 的弹窗、备份打包)拿主缓存那一槽的指纹
// 在旁路文件的两份明细里找对得上的那一份,找不到就当「候选明细缺失」—— 绝不拿别的轮次的候选去配
// 这一轮的胜者。
//
// ## 在哪一步拆
//
// **保存那一步**(`saveEnrichCache` 取快照时,`splitDecisionDetails`):不管判决是 collector 新解析的、
// 从老文件读进来的、App 手动选词写进去的、还是配置恢复进来的,只要这一槽还带着明细,保存时先把明细
// 原子写进旁路文件,再把内存里这一条换成去掉明细的版本,最后写主缓存。只有一个出口,不会漏;跟主缓存
// 走同一条落盘路(节流 / flush 都一样),不会被合并丢掉。明细在内存里最多停留到下一次保存。
//
// 旁路文件写失败:明细只是诊断用的证据,记一行错误、照常写主缓存(不能为了它卡住歌词落盘)。
//
// ## 跟着 key 走
//
//   - key 归一(`migrateEnrichKeys`)改了 key:`renameDecisionSidecar` 跟着改名。
//   - 跨专辑复用把兄弟那一槽搬过来、改了 path / reused_from(指纹变了):`withDecisionDetails` 先从兄弟
//     的旁路文件把明细补回来,搬过来的就是完整的一份,下次保存按新 key、新指纹重新拆出去。
//   - 条目被删(撤回、去重、清理、App 里删):常驻进程启动时 `sweepDecisionSidecars` 删掉没有对应 key
//     的旁路文件。撤回在运行中发生,当场删。
//
// 离线扫全库分析候选(09 章决策 81/82 那类)要读这个目录,见 09 章「数据与文件」。

// decisionDetails 是一槽判决的指纹 + 明细。
type decisionDetails struct {
	Path           string                    `json:"path"`
	DecidedAt      int64                     `json:"decided_at"`
	ScoringVersion int                       `json:"scoring_version"`
	Winner         string                    `json:"winner,omitempty"`
	ReusedFrom     string                    `json:"reused_from,omitempty"`
	Candidates     []lyricsDecisionCandidate `json:"candidates,omitempty"`
	QueriesTried   []lyricQueryRecord        `json:"queries_tried,omitempty"`
}

type decisionSidecar struct {
	Key         string           `json:"key"`
	Latest      *decisionDetails `json:"latest,omitempty"`
	Applied     *decisionDetails `json:"applied,omitempty"`
	AppliedSame bool             `json:"applied_same,omitempty"`
}

// decisionSidecarJob 是一次保存要写的一个旁路文件:两槽各自的判决(可能带明细,也可能已经拆过)。
type decisionSidecarJob struct {
	key             string
	latest, applied *lyricsDecision
}

func hasDecisionDetails(d *lyricsDecision) bool {
	return d != nil && (len(d.Candidates) > 0 || len(d.QueriesTried) > 0)
}

func sameDecisionFingerprint(a *decisionDetails, d *lyricsDecision) bool {
	return a != nil && d != nil && a.Path == d.Path && a.DecidedAt == d.DecidedAt &&
		a.ScoringVersion == d.ScoringVersion && a.Winner == d.Winner && a.ReusedFrom == d.ReusedFrom
}

func detailsOf(d *lyricsDecision) *decisionDetails {
	return &decisionDetails{
		Path: d.Path, DecidedAt: d.DecidedAt, ScoringVersion: d.ScoringVersion,
		Winner: d.Winner, ReusedFrom: d.ReusedFrom,
		Candidates: d.Candidates, QueriesTried: d.QueriesTried,
	}
}

// stripDecision 返回去掉明细的一份新拷贝(原对象不动 —— 缓存条目里的指针存进去之后不许原地改),
// 顺手补上 WinnerArtist。没有明细的原样返回。
func stripDecision(d *lyricsDecision) *lyricsDecision {
	if !hasDecisionDetails(d) {
		return d
	}
	cp := *d
	cp.WinnerArtist = decisionWinnerArtist(d)
	cp.Candidates = nil
	cp.QueriesTried = nil
	cp.DetailsExternal = true
	return &cp
}

// splitDecisionDetails:这条的两槽还带明细,就返回去掉明细的条目 + 要写的旁路文件。两槽原本共用一个
// 对象(enrichdedupe.go)的,拆完仍然共用。调用方持 enrichMu。
func splitDecisionDetails(key string, e enrichEntry) (enrichEntry, decisionSidecarJob, bool) {
	d, a := e.LyricsDecision, e.LyricsDecisionApplied
	if !hasDecisionDetails(d) && !hasDecisionDetails(a) {
		return e, decisionSidecarJob{}, false
	}
	job := decisionSidecarJob{key: key, latest: d, applied: a}
	sd := stripDecision(d)
	sa := sd
	if a != d {
		sa = stripDecision(a)
	}
	e.LyricsDecision, e.LyricsDecisionApplied = sd, sa
	return e, job, true
}

// decisionSidecarDir 旁路目录;没有落盘路径(子命令只读、测试)时为空。
func decisionSidecarDir() string {
	if enrichPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(enrichPath), clientName+"-decisions")
}

func decisionSidecarName(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:16]) + ".json"
}

func readDecisionSidecar(path string) *decisionSidecar {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var rec decisionSidecar
	if json.Unmarshal(b, &rec) != nil {
		return nil
	}
	return &rec
}

func (r *decisionSidecar) slots() []*decisionDetails {
	if r == nil {
		return nil
	}
	out := []*decisionDetails{r.Latest}
	if r.Applied != nil {
		out = append(out, r.Applied)
	}
	return out
}

// lookupDetails 在旧文件的两份明细里找指纹对得上的那一份。
func lookupDetails(pool []*decisionDetails, d *lyricsDecision) *decisionDetails {
	for _, p := range pool {
		if sameDecisionFingerprint(p, d) {
			return p
		}
	}
	return nil
}

// resolveSlot:这一槽带明细就用它的,已经拆过的就去旧文件里按指纹找(一轮没被采纳的升级评估只换了
// latest,applied 那份明细要原样留住)。
func resolveSlot(d *lyricsDecision, pool []*decisionDetails) *decisionDetails {
	if d == nil {
		return nil
	}
	if hasDecisionDetails(d) {
		return detailsOf(d)
	}
	return lookupDetails(pool, d)
}

// writeDecisionSidecars 把这一轮保存攒下的旁路文件写出去(调用方持 enrichSaveMu、不持 enrichMu)。
func writeDecisionSidecars(jobs []decisionSidecarJob) {
	dir := decisionSidecarDir()
	if dir == "" || len(jobs) == 0 {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		slog.Error("decision sidecar: mkdir", "err", err)
		return
	}
	failed := 0
	for _, j := range jobs {
		if err := writeDecisionSidecar(dir, j); err != nil {
			failed++
			if failed == 1 {
				slog.Error("decision sidecar: write", "key", j.key, "err", err)
			}
		}
	}
	if failed > 1 {
		slog.Error("decision sidecar: more writes failed", "count", failed)
	}
}

func writeDecisionSidecar(dir string, j decisionSidecarJob) error {
	path := filepath.Join(dir, decisionSidecarName(j.key))
	pool := readDecisionSidecar(path).slots()
	latest := resolveSlot(j.latest, pool)
	applied := resolveSlot(j.applied, pool)
	if latest == nil && applied == nil {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	rec := decisionSidecar{Key: j.key, Latest: latest}
	if applied != nil {
		if latest != nil && reflect.DeepEqual(latest, applied) {
			rec.AppliedSame = true
		} else {
			rec.Applied = applied
		}
	}
	return writeDecisionSidecarFile(path, rec)
}

func writeDecisionSidecarFile(path string, rec decisionSidecar) error {
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// withDecisionDetails:判决已经拆过(不带明细)时,从 key 那条的旁路文件按指纹把明细补回来,返回一份
// 带明细的新拷贝;找不到或本来就带明细时原样返回。跨专辑复用搬运兄弟那一槽之前用 —— 搬过来要改
// path / reused_from,指纹一变就再也对不上兄弟的旁路文件了。
func withDecisionDetails(key string, d *lyricsDecision) *lyricsDecision {
	if d == nil || hasDecisionDetails(d) {
		return d
	}
	dir := decisionSidecarDir()
	if dir == "" {
		return d
	}
	det := lookupDetails(readDecisionSidecar(filepath.Join(dir, decisionSidecarName(key))).slots(), d)
	if det == nil {
		return d
	}
	cp := *d
	cp.Candidates, cp.QueriesTried = det.Candidates, det.QueriesTried
	cp.DetailsExternal = false
	return &cp
}

// renameDecisionSidecar:key 归一改了 key,旁路文件跟着改名(目标已存在就留目标、删旧的)。
func renameDecisionSidecar(oldKey, newKey string) {
	dir := decisionSidecarDir()
	if dir == "" || oldKey == newKey {
		return
	}
	from := filepath.Join(dir, decisionSidecarName(oldKey))
	to := filepath.Join(dir, decisionSidecarName(newKey))
	rec := readDecisionSidecar(from)
	if rec == nil {
		return
	}
	if _, err := os.Stat(to); err == nil {
		os.Remove(from)
		return
	}
	rec.Key = newKey
	if err := writeDecisionSidecarFile(to, *rec); err != nil {
		slog.Error("decision sidecar: rename", "from", oldKey, "to", newKey, "err", err)
		return
	}
	os.Remove(from)
}

// removeDecisionSidecar 条目被删时顺手删它的旁路文件。
func removeDecisionSidecar(key string) {
	dir := decisionSidecarDir()
	if dir == "" {
		return
	}
	if err := os.Remove(filepath.Join(dir, decisionSidecarName(key))); err != nil && !os.IsNotExist(err) {
		slog.Error("decision sidecar: remove", "key", key, "err", err)
	}
}

// externalizeDecisionsAtStartup:常驻进程启动时把存量里还带明细的判决拆出去(一次性:拆过之后主缓存
// 里就没有明细了,再启动是空转一遍廉价的检查),然后清掉没有对应条目的旁路文件。
//
// 必须排在 migrateSodaCoverURLs 之后:那道迁移扫的是内存里的候选 cover_url,拆完之后就扫不到了。
func externalizeDecisionsAtStartup() {
	enrichMu.Lock()
	pending := 0
	for _, e := range enrichCache {
		if hasDecisionDetails(e.LyricsDecision) || hasDecisionDetails(e.LyricsDecisionApplied) {
			pending++
		}
	}
	if pending > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if pending > 0 {
		saveEnrichCache()
		log.Printf("decision sidecar: moved candidate details of %d entries out of the enrich cache", pending)
	}
	sweepDecisionSidecars()
}

// sweepDecisionSidecars 删掉没有对应 key 的旁路文件(条目被删、撤回、去重、App 里清掉之后留下的)。
// 只在常驻进程启动时跑:那时还没有别的写入方在建新条目。
func sweepDecisionSidecars() {
	dir := decisionSidecarDir()
	if dir == "" {
		return
	}
	names, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	enrichMu.Lock()
	live := make(map[string]bool, len(enrichCache))
	for k := range enrichCache {
		live[decisionSidecarName(k)] = true
	}
	enrichMu.Unlock()
	removed := 0
	for _, n := range names {
		name := n.Name()
		// 写到一半被打断留下的临时文件(`<名字>.json.tmp.<随机>`)一并清掉。
		stale := strings.Contains(name, ".json.tmp.")
		if n.IsDir() || (!stale && (!strings.HasSuffix(name, ".json") || live[name])) {
			continue
		}
		if os.Remove(filepath.Join(dir, name)) == nil {
			removed++
		}
	}
	if removed > 0 {
		log.Printf("decision sidecar: removed %d orphaned file(s)", removed)
	}
}
