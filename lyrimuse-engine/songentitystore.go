package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sort"
	"sync"
	"time"
)

// 歌曲实体表的落盘与后台重建(阶段 0:只建表、只出报告,不改任何写法的歌词与设置)。
//
// 两个文件都是派生数据,丢了、坏了、版本对不上就下一次重建:
//   - `lyrimuse-song-entities.json`:实体表。每首歌的写法、共享组、各种 id、时长两端、证据边,被否决的合并,重定向。
//   - `lyrimuse-song-entity-report.txt`:诊断报告(songEntityReport.writeText),随 App 的诊断包一起导出。
//
// 启动后 songEntityBuildDelay 建第一次(避开启动迁移、ISRC 补扫),之后每 songEntityRebuildInterval 一次。持锁只复制缓存,
// 摘字段、读解析决策、建表都在锁外。开关(features().SongEntityShadow)关着时两个文件都删掉。每次建完接着按阶段 3 的开关
// 同步歌词或者把同步过的恢复回去;第一次建完之后,那个开关一翻面也立刻这样做一次(songentityshare.go)。
//
// 实体 id 延续(songEntityIDs):种子先取各写法条目上的 `song`,没有的再取上一份实体表;每个实体取跟种子共有写法最多的
// id。建完把变了的 `song` 写回条目、同步落盘(待落盘小文件,攒满了整份落盘,见 saveSongEntityIDs),之后才写实体表:哪一步之间
// 被杀,下次都接得上(18 章决策 8)。
// 用户拆开过的写法对记在 `lyrimuse-song-entity-user.json`(user_splits),写在 songentityuser.go;实体表重建、删除都不碰它。
// 拆开、恢复合并之后马上重建一次(songEntityRebuildNow);名字 / 录音补扫补到证据之后攒 songEntityEvidenceDelay 重建一次
// (songEntityEvidence)。两次全量建表之间,缓存落盘几秒后增量重算变了的写法所在的那一块(songEntityCacheSaved,见
// songentityincremental.go),实体表攒 songEntityTableWriteDelay 才写盘。实体表 4.8 MB 整份重写,预取一张专辑时增量重算
// 几秒一次、补扫每补到一条就全量建一次,当场写的话半小时重写二三十次(15 章决策 40)。

const (
	songEntityTableVersion = 1

	songEntityBuildDelay      = 4 * time.Minute
	songEntityRebuildInterval = 24 * time.Hour
)

var (
	// songEntityTableWriteDelay:增量重算之后实体表最多攒多久才写盘。内存里的状态(songEntityLive)当场就是新的,同步歌词照常
	// 接着跑;盘上这份只有 App「其它写法」面板读证据边、全量建表读它当种子(先用还没写盘的那份)。退出前写掉
	// (flushSongEntityTable)。
	songEntityTableWriteDelay = time.Minute
	// songEntityEvidenceDelay:补扫补到证据之后最多攒多久才全量建表,几个补扫前后脚补到的并成一次。
	songEntityEvidenceDelay = 2 * time.Minute
	// songEntityTableUnsaved:增量重算改过、还没写盘的实体表。持 songEntityRebuildMu 读写。
	songEntityTableUnsaved *songEntityTableFile
	// songEntityEvidence:补扫补到了证据,请常驻循环攒一会儿再全量建表(requestSongEntityEvidenceRebuild 发)。只缓冲一个。
	songEntityEvidence = make(chan struct{}, 1)
)

// requestSongEntityEvidenceRebuild:名字 / 录音补扫补到证据之后调。
func requestSongEntityEvidenceRebuild() {
	select {
	case songEntityEvidence <- struct{}{}:
	default:
	}
}

// songEntityTableFile 是实体表文件的形状。
type songEntityTableFile struct {
	Version   int                         `json:"version"`
	BuiltAt   int64                       `json:"built_at"`
	Songs     map[string]songEntityRecord `json:"songs"`
	Vetoed    []songVetoRecord            `json:"vetoed,omitempty"`
	Redirects map[string]string           `json:"redirects,omitempty"`
}

// songEntityRecord:一首歌。Share 跟 Variants 逐条对齐,是共享组编号(跨重建延续,不一定连续,见 songShareNumbers);全在一组时省略。
type songEntityRecord struct {
	Created      int64                     `json:"created"`
	Variants     []string                  `json:"variants"`
	Share        []int                     `json:"share,omitempty"`
	IDs          map[string][]songIDRecord `json:"ids,omitempty"`
	DurationSecs []float64                 `json:"duration_secs,omitempty"` // 已知时长的两端
	Evidence     []songEdgeRecord          `json:"evidence,omitempty"`
}

type songIDRecord struct {
	ID    string `json:"id"`
	Level string `json:"level"`
}

type songEdgeRecord struct {
	Kind      string `json:"kind"`
	A         string `json:"a"`
	B         string `json:"b"`
	Value     string `json:"value,omitempty"`
	CountOnly bool   `json:"count_only,omitempty"`
}

// songVetoRecord:一次被否决的合并:哪种否决(Reason)挡下了哪条边(Kind、A、B),因为哪一对写法(X、Y)。
type songVetoRecord struct {
	Reason string `json:"reason"`
	Kind   string `json:"kind"`
	A      string `json:"a"`
	B      string `json:"b"`
	X      string `json:"x"`
	Y      string `json:"y"`
}

// songEntityUserFile 是用户判断文件里这里读的那几个键。
type songEntityUserFile struct {
	Version    int        `json:"version"`
	UserSplits [][]string `json:"user_splits,omitempty"` // 每项一对写法键
}

func songEntityTablePath() string  { return configFilePath(clientName + "-song-entities.json") }
func songEntityReportPath() string { return configFilePath(clientName + "-song-entity-report.txt") }
func songEntityUserPath() string   { return configFilePath(clientName + "-song-entity-user.json") }

// startSongEntityShadow 由 poller 单开一个 goroutine,ctx 取消时退出。
func startSongEntityShadow(ctx context.Context) {
	timer := time.NewTimer(songEntityBuildDelay)
	defer timer.Stop()
	check := time.NewTicker(songShareCheckInterval)
	defer check.Stop()
	started, sharing := false, false
	var update <-chan time.Time     // 缓存落盘之后攒几秒,到点增量重算一次
	var tableWrite <-chan time.Time // 增量重算之后攒着,到点写实体表
	var evidenceAt <-chan time.Time // 补扫补到证据之后攒着,到点全量建表
	for {
		rebuild, evidence := false, false
		select {
		case <-ctx.Done():
			flushSongEntityTable()
			return
		case <-tableWrite:
			tableWrite = nil
			flushSongEntityTable()
			continue
		case <-songEntityEvidence:
			if evidenceAt == nil {
				evidenceAt = time.After(songEntityEvidenceDelay)
			}
			continue
		case <-evidenceAt:
			evidenceAt = nil
			if features().SongEntityShadow {
				rebuildSongEntityTableForEvidence(time.Now())
			}
			continue
		case <-songEntityCacheSaved:
			if update == nil {
				update = time.After(songEntityUpdateDelay)
			}
			continue
		case <-update:
			update = nil
			if !features().SongEntityShadow {
				continue
			}
			b, full := updateSongEntityTable(time.Now())
			if b != nil && tableWrite == nil {
				tableWrite = time.After(songEntityTableWriteDelay)
			}
			if full {
				b = rebuildSongEntityTableWith(time.Now(), evidenceAt == nil)
				evidenceAt = nil
			}
			if b != nil && songEntitySharing() {
				sharing = songEntityShareStep(ctx, b)
			}
			continue
		case <-timer.C:
			timer.Reset(songEntityRebuildInterval)
			started, rebuild = true, true
		case <-check.C:
			if !started || songEntitySharing() == sharing {
				continue
			}
			rebuild = songEntitySharing()
		case <-songEntityRebuildNow:
			rebuild, evidence = true, true
		}
		if rebuild && evidenceAt != nil {
			// 补扫补到的证据已经写好,这一次建表读得到:攒着的那次并进来(跟它一样不对比),不再另建一次。
			evidence, evidenceAt = true, nil
		}
		var b *songEntityBuild
		if rebuild {
			if features().SongEntityShadow {
				b = rebuildSongEntityTableWith(time.Now(), !evidence)
			} else {
				removeSongEntityFiles()
			}
		}
		sharing = songEntityShareStep(ctx, b)
	}
}

// songEntityShareStep:建完表(b 为 nil 时是没建)之后按阶段 3 的开关同步一轮,或者把同步过的恢复回去,返回按哪种做的。
func songEntityShareStep(ctx context.Context, b *songEntityBuild) bool {
	if !songEntitySharing() {
		revertSongEntityShare()
		return false
	}
	if b != nil {
		runSongEntitySharePass(ctx, b)
	}
	return true
}

// songEntityRebuildMu:每天那一次和名字补扫之后那一次(startAppleNamesSweep)不同时跑,免得两份结果互相覆盖。
var songEntityRebuildMu sync.Mutex

// rebuildSongEntityTable 全量建一次实体表,写实体表和报告两个文件,返回这次建出来的(写实体表失败时为 nil)。建完的状态
// 留给增量重算(songEntityLive);之前有增量维护的那份时跟它对一遍,不一样的写法记一行日志。
func rebuildSongEntityTable(now time.Time) *songEntityBuild {
	return rebuildSongEntityTableWith(now, true)
}

// rebuildSongEntityTableForEvidence:补扫补到了新证据、用户拆开或恢复合并之后的全量建表。这些输入不在增量的指纹里,建出来
// 跟增量维护的那份不一样是预期的,不对比(对比那行日志只留给定时建表,用来发现增量算错)。
func rebuildSongEntityTableForEvidence(now time.Time) *songEntityBuild {
	return rebuildSongEntityTableWith(now, false)
}

func rebuildSongEntityTableWith(now time.Time, compare bool) *songEntityBuild {
	songEntityRebuildMu.Lock()
	defer songEntityRebuildMu.Unlock()
	start := time.Now()
	src := songEntityLiveSource(songEntityPrepare())
	seed := songEntityTableUnsaved
	songEntityTableUnsaved = nil
	if seed == nil {
		seed = readSongEntityTable(songEntityTablePath())
	}
	b, table, st := buildSongEntityState(src, seed, now)
	prev := songEntityLive
	if songEntityLivePath != songEntityTablePath() {
		prev = nil
	}
	songEntityLive = nil
	if n := writeBackSongEntityIDs(table); n > 0 {
		saveSongEntityIDs()
		slog.Info("song entities: wrote song ids", "variants", n)
	}
	data, err := json.Marshal(table)
	if err != nil {
		slog.Error("song entities: encode table", "err", err)
		return nil
	}
	if err := writeFileAtomic(songEntityTablePath(), data); err != nil {
		slog.Error("song entities: write table", "err", err)
		return nil
	}
	var report bytes.Buffer
	r := b.report()
	r.writeText(&report, 0)
	if err := writeFileAtomic(songEntityReportPath(), report.Bytes()); err != nil {
		slog.Error("song entities: write report", "err", err)
	}
	slog.Info("song entities: rebuilt", "variants", r.variants, "songs", r.entities, "multi", r.multi,
		"merges", len(b.merged), "vetoed", len(b.vetoed), "took", time.Since(start).Round(time.Millisecond))
	if compare && prev != nil {
		songEntityCompareLive(prev.table, table)
	}
	songEntityLive, songEntityLivePath = st, songEntityTablePath()
	return b
}

// songEntityCompareLive:全量建出来的 t 跟增量维护的那份 prev 比,两份里都有的写法不一样时记一行日志(歌手身份缓存、目录
// 名字、Spotify 演唱语言这些不在指纹里的输入变了也会不一样)。
func songEntityCompareLive(prev, t *songEntityTableFile) {
	inPrev, inNew := map[string]bool{}, map[string]bool{}
	for _, rec := range prev.Songs {
		for _, k := range rec.Variants {
			inPrev[k] = true
		}
	}
	for _, rec := range t.Songs {
		for _, k := range rec.Variants {
			inNew[k] = true
		}
	}
	var diff []string
	for _, k := range songEntityTableDiff(prev, t) {
		if inPrev[k] && inNew[k] {
			diff = append(diff, k)
		}
	}
	if len(diff) > 0 {
		slog.Info("song entities: full rebuild differs from the incrementally kept table", "variants", len(diff),
			"examples", diff[:min(len(diff), 3)])
	}
}

// updateSongEntityTable 增量重算一次(见 songentityincremental.go),返回重算的那一块(没有改动时为 nil)。实体表留在
// songEntityTableUnsaved,由常驻循环攒一会儿写(flushSongEntityTable)。第一次全量建表之前什么都不做。full 为 true 时要全量
// 建表。报告只在全量建表时写。
func updateSongEntityTable(now time.Time) (b *songEntityBuild, full bool) {
	songEntityRebuildMu.Lock()
	defer songEntityRebuildMu.Unlock()
	st := songEntityLive
	if st == nil || songEntityLivePath != songEntityTablePath() {
		return nil, false
	}
	start := time.Now()
	up, err := st.update(songEntityLiveSource(st.prepare), now)
	if err != nil {
		songEntityLive = nil
		return nil, true
	}
	if up == nil {
		return nil, false
	}
	if n := writeBackSongEntityIDs(up.table); n > 0 {
		saveSongEntityIDs()
	}
	songEntityTableUnsaved = up.table
	slog.Info("song entities: updated", "changed", up.changed, "removed", up.removed, "block", len(up.build.variants),
		"songs", len(up.table.Songs), "took", time.Since(start).Round(time.Millisecond))
	return up.build, false
}

// flushSongEntityTable:增量重算攒着的实体表写盘。写失败留着,下一次到点再写(全量建表会先拿它当种子、再整份写)。
// 开关关着时丢掉不写,别把 removeSongEntityFiles 删掉的派生文件写回来。常驻循环到点调,引擎退出前 main 再调一次。
func flushSongEntityTable() {
	songEntityRebuildMu.Lock()
	defer songEntityRebuildMu.Unlock()
	t := songEntityTableUnsaved
	if t == nil {
		return
	}
	if !features().SongEntityShadow {
		songEntityTableUnsaved = nil
		return
	}
	data, err := json.Marshal(t)
	if err == nil {
		err = writeFileAtomic(songEntityTablePath(), data)
	}
	if err != nil {
		slog.Error("song entities: write table", "err", err)
		return
	}
	songEntityTableUnsaved = nil
}

// saveSongEntityIDs:写回了实体 id 之后落盘,在写实体表之前(18 章决策 8 的顺序)。写回的条目当场写进待落盘小文件(App 叠上去
// 就看得到,下次启动叠回内存),整份落盘跟别的改动一起攒(enrichpending.go):新歌一进缓存、补扫补到一个名字都会走到这里,
// 当场整份写的话预取一张专辑就是一首一次。小文件里是完整条目,攒到 enrichPendingMaxKeys 条(规则一改整批写回)就当场整份写。
// 见 15 章决策 38。
func saveSongEntityIDs() {
	enrichMu.Lock()
	full := len(enrichPendingKeys) >= enrichPendingMaxKeys
	enrichMu.Unlock()
	if !full {
		enrichPendingNow()
		requestEnrichBackgroundSave()
		return
	}
	if err := saveEnrichCacheChecked(); err != nil {
		slog.Error("song entities: save song ids", "err", err)
	}
}

// removeSongEntityFiles:开关关着时删掉两个派生文件(用户判断文件不动)。
func removeSongEntityFiles() {
	for _, p := range []string{songEntityTablePath(), songEntityReportPath()} {
		err := os.Remove(p)
		noteFileErr("remove", p, err)
		if err == nil {
			slog.Info("song entities: switched off, removed derived file", "path", p)
		}
	}
}

// readSongEntityTable 读上一份实体表(给 id 延续当种子);缺失、坏掉、版本对不上都返回 nil。
func readSongEntityTable(path string) *songEntityTableFile {
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return nil
	}
	var t songEntityTableFile
	if err := json.Unmarshal(data, &t); err != nil {
		noteFileErr("decode", path, err)
		return nil
	}
	if t.Version != songEntityTableVersion {
		return nil
	}
	return &t
}

// readSongEntityUserSplits 读用户拆开过的写法对(songPairKey);文件不存在或解不开时没有。
func readSongEntityUserSplits(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return nil
	}
	var f songEntityUserFile
	if err := json.Unmarshal(data, &f); err != nil {
		noteFileErr("decode", path, err)
		return nil
	}
	out := map[string]bool{}
	for _, p := range f.UserSplits {
		if len(p) == 2 && p[0] != "" && p[1] != "" && p[0] != p[1] {
			out[songPairKey(p[0], p[1])] = true
		}
	}
	return out
}

// writeBackSongEntityIDs 把实体表里每条写法的实体 id 写进条目的 `song`、共享组编号写进 `song_share`,返回改了几条。
// 缓存里已经没有的写法跳过。
func writeBackSongEntityIDs(t *songEntityTableFile) int {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	n := 0
	for id, rec := range t.Songs {
		for i, k := range rec.Variants {
			share := 0
			if i < len(rec.Share) {
				share = rec.Share[i]
			}
			e, ok := enrichCache[k]
			if !ok || (e.Song == id && e.SongShare == share) {
				continue
			}
			e.Song, e.SongShare = id, share
			enrichCache[k] = e
			noteEnrichPendingLocked(k)
			n++
		}
	}
	if n > 0 {
		enrichDirty = true
	}
	return n
}

// songEntitySeed:条目上记着的实体 id(`song`)和共享组编号(`song_share`),建表时给 id、组号延续当种子。
type songEntitySeed struct {
	song  string
	share int
}

// songShareNumbers:一个实体里各共享组的编号(groups 按组里第一条写法的先后排,每组是写法键)。跟上一次共有写法最多的组沿用
// 那个编号(同样多取小的编号、再取排在前面的组),一个编号只给一组;其余组按先后取最小的空号。prev 是写法 → 它上一次在这个实体里
// 的组号。编号按成员先后重排的话,一条键小的写法挂进第二组就会让两组对调编号、整组写回(18 章决策 60)。
func songShareNumbers(groups [][]string, prev map[string]int) []int {
	type claim struct{ group, number, shared int }
	var claims []claim
	for gi, keys := range groups {
		count := map[int]int{}
		for _, k := range keys {
			if n, ok := prev[k]; ok {
				count[n]++
			}
		}
		for n, c := range count {
			claims = append(claims, claim{group: gi, number: n, shared: c})
		}
	}
	sort.Slice(claims, func(i, j int) bool {
		x, y := claims[i], claims[j]
		if x.shared != y.shared {
			return x.shared > y.shared
		}
		if x.number != y.number {
			return x.number < y.number
		}
		return x.group < y.group
	})
	out := make([]int, len(groups))
	assigned := make([]bool, len(groups))
	used := map[int]bool{}
	for _, c := range claims {
		if assigned[c.group] || used[c.number] {
			continue
		}
		out[c.group], assigned[c.group], used[c.number] = c.number, true, true
	}
	next := 0
	for gi := range groups {
		if assigned[gi] {
			continue
		}
		for used[next] {
			next++
		}
		out[gi], used[next] = next, true
	}
	return out
}

// table 把这次建表的结果整理成实体表文件。id 延续的种子:songs(写法键 → 条目上的 `song` / `song_share`)优先,其次是 old
// (上一份实体表);都没有时新开。建立时刻只有旧表里有,只从 `song` 来的 id 按 now 算。共享组编号也延续(songShareNumbers)。
func (b *songEntityBuild) table(old *songEntityTableFile, songs map[string]songEntitySeed, now time.Time) *songEntityTableFile {
	seeds, created := map[string]string{}, map[string]int64{}
	if old != nil {
		for id, s := range old.Songs {
			created[id] = s.Created
			for _, k := range s.Variants {
				seeds[k] = id
			}
		}
	}
	for k, s := range songs {
		seeds[k] = s.song
	}
	// prevShare:写法 k 上一次在实体 id 里的共享组编号;上一次不在这个实体里时 ok 为 false。
	prevShare := func(k, id string) (int, bool) {
		if s, ok := songs[k]; ok && s.song != "" {
			return s.share, s.song == id
		}
		if old == nil {
			return 0, false
		}
		rec, ok := old.Songs[id]
		if !ok {
			return 0, false
		}
		for i, v := range rec.Variants {
			if v == k {
				if i < len(rec.Share) {
					return rec.Share[i], true
				}
				return 0, true
			}
		}
		return 0, false
	}
	keys := make([][]string, len(b.clusters))
	for ci, members := range b.clusters {
		for _, m := range members {
			keys[ci] = append(keys[ci], b.variants[m].key)
		}
	}
	ids, redirects := songEntityIDs(keys, seeds, created, newSongEntityID)
	t := &songEntityTableFile{Version: songEntityTableVersion, BuiltAt: now.Unix(), Songs: map[string]songEntityRecord{}, Redirects: map[string]string{}}
	edgesOf := make([][]songEdgeRecord, len(b.clusters))
	for i, e := range b.edges {
		ca, cb := b.entityOf[e.a], b.entityOf[e.b]
		if b.edgeVeto[i] || ca != cb {
			continue
		}
		edgesOf[ca] = append(edgesOf[ca], songEdgeRecord{Kind: e.kind, A: b.variants[e.a].key, B: b.variants[e.b].key, Value: e.value, CountOnly: e.countOnly})
	}
	for ci, members := range b.clusters {
		rec := songEntityRecord{Created: now.Unix(), Variants: keys[ci], Evidence: edgesOf[ci]}
		if c, ok := created[ids[ci]]; ok {
			rec.Created = c
		}
		var order []int // 共享组的根,按组里第一条写法的先后
		groupKeys := map[int][]string{}
		for _, m := range members {
			r := b.shareOf[m]
			if _, ok := groupKeys[r]; !ok {
				order = append(order, r)
			}
			groupKeys[r] = append(groupKeys[r], b.variants[m].key)
		}
		groupList := make([][]string, len(order))
		for i, r := range order {
			groupList[i] = groupKeys[r]
		}
		prev := map[string]int{}
		for _, k := range keys[ci] {
			if n, ok := prevShare(k, ids[ci]); ok {
				prev[k] = n
			}
		}
		numbers := songShareNumbers(groupList, prev)
		groups := make(map[int]int, len(order))
		for i, r := range order {
			groups[r] = numbers[i]
		}
		lo, hi := 0.0, 0.0
		rec.IDs = map[string][]songIDRecord{}
		seen := map[string]bool{}
		for _, m := range members {
			rec.Share = append(rec.Share, groups[b.shareOf[m]])
			v := &b.variants[m]
			if d := v.durationSecs; d > 0 {
				if lo == 0 || d < lo {
					lo = d
				}
				hi = max(hi, d)
			}
			for _, g := range v.ids {
				if seen[g.ns+"\x1f"+g.id+"\x1f"+g.level.String()] {
					continue
				}
				seen[g.ns+"\x1f"+g.id+"\x1f"+g.level.String()] = true
				rec.IDs[g.ns] = append(rec.IDs[g.ns], songIDRecord{ID: g.id, Level: g.level.String()})
			}
		}
		if len(groups) <= 1 {
			rec.Share = nil
		}
		if hi > 0 {
			rec.DurationSecs = []float64{lo, hi}
		}
		for ns := range rec.IDs {
			sort.Slice(rec.IDs[ns], func(i, j int) bool { return rec.IDs[ns][i].ID < rec.IDs[ns][j].ID })
		}
		t.Songs[ids[ci]] = rec
	}
	for _, v := range b.vetoed {
		t.Vetoed = append(t.Vetoed, songVetoRecord{Reason: v.reason, Kind: v.edge.kind,
			A: b.variants[v.edge.a].key, B: b.variants[v.edge.b].key, X: b.variants[v.x].key, Y: b.variants[v.y].key})
	}
	// 重定向压平:旧表里指向的 id 这次又被并走的,直接指到现在的 id;指向已经不存在的 id 的丢掉。
	for from, to := range redirects {
		t.Redirects[from] = to
	}
	// 旧表里的 id 这次没分到实体、也没记重定向(种子全被条目上的 `song` 盖掉了):指向拿走它写法最多的那个实体。
	if old != nil {
		of := map[string]string{}
		for id, rec := range t.Songs {
			for _, k := range rec.Variants {
				of[k] = id
			}
		}
		for id, s := range old.Songs {
			if _, live := t.Songs[id]; live {
				continue
			}
			if _, ok := t.Redirects[id]; ok {
				continue
			}
			count, best := map[string]int{}, ""
			for _, k := range s.Variants {
				to := of[k]
				if to == "" {
					continue
				}
				count[to]++
				if best == "" || count[to] > count[best] || (count[to] == count[best] && to < best) {
					best = to
				}
			}
			if best != "" {
				t.Redirects[id] = best
			}
		}
	}
	if old != nil {
		for from, to := range old.Redirects {
			if next, ok := t.Redirects[to]; ok {
				to = next
			}
			if _, live := t.Songs[to]; live {
				if _, stillLive := t.Songs[from]; !stillLive {
					t.Redirects[from] = to
				}
			}
		}
	}
	if len(t.Redirects) == 0 {
		t.Redirects = nil
	}
	return t
}
