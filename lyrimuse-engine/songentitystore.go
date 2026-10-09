package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"sort"
	"time"
)

// 歌曲实体表的落盘与后台重建(阶段 0:只建表、只出报告,不改任何写法的歌词与设置)。
//
// 两个文件都是派生数据,丢了、坏了、版本对不上就下一次重建:
//   - `lyrimuse-song-entities.json`:实体表。每首歌的写法、共享组、各种 id、时长两端、证据边,被否决的合并,重定向。
//   - `lyrimuse-song-entity-report.txt`:诊断报告(songEntityReport.writeText),随 App 的诊断包一起导出。
//
// 启动后 songEntityBuildDelay 建第一次(避开启动迁移、ISRC 补扫),之后每 songEntityRebuildInterval 一次。持锁只复制缓存,
// 摘字段、读解析决策、建表都在锁外。开关(features().SongEntityShadow)关着时两个文件都删掉。
//
// 实体 id 用上一份实体表做种子延续(songEntityIDs):每个实体取跟旧表共有写法最多的旧 id。
// 用户拆开过的写法对记在 `lyrimuse-song-entity-user.json`(user_splits),这里只读;实体表重建、删除都不碰它。
// 写它的一方必须原样保留不认识的键。

const (
	songEntityTableVersion = 1

	songEntityBuildDelay      = 4 * time.Minute
	songEntityRebuildInterval = 24 * time.Hour
)

// songEntityTableFile 是实体表文件的形状。
type songEntityTableFile struct {
	Version   int                         `json:"version"`
	BuiltAt   int64                       `json:"built_at"`
	Songs     map[string]songEntityRecord `json:"songs"`
	Vetoed    []songVetoRecord            `json:"vetoed,omitempty"`
	Redirects map[string]string           `json:"redirects,omitempty"`
}

// songEntityRecord:一首歌。Share 跟 Variants 逐条对齐,是共享组编号(从 0 起);全在一组时省略。
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
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		if features().SongEntityShadow {
			rebuildSongEntityTable(time.Now())
		} else {
			removeSongEntityFiles()
		}
		timer.Reset(songEntityRebuildInterval)
	}
}

// rebuildSongEntityTable 全量建一次实体表,写实体表和报告两个文件。
func rebuildSongEntityTable(now time.Time) {
	start := time.Now()
	enrichMu.Lock()
	snapshot := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		snapshot[k] = v
	}
	enrichMu.Unlock()
	variants := songVariantsFromCache(snapshot, lyricsPinnedKeys())
	b := buildSongEntities(variants, readSongEntityUserSplits(songEntityUserPath()), decisionSidecarDir())
	table := b.table(readSongEntityTable(songEntityTablePath()), now)
	data, err := json.Marshal(table)
	if err != nil {
		slog.Error("song entities: encode table", "err", err)
		return
	}
	if err := writeFileAtomic(songEntityTablePath(), data); err != nil {
		slog.Error("song entities: write table", "err", err)
		return
	}
	var report bytes.Buffer
	r := b.report()
	r.writeText(&report, 0)
	if err := writeFileAtomic(songEntityReportPath(), report.Bytes()); err != nil {
		slog.Error("song entities: write report", "err", err)
	}
	slog.Info("song entities: rebuilt", "variants", r.variants, "songs", r.entities, "multi", r.multi,
		"merges", len(b.merged), "vetoed", len(b.vetoed), "took", time.Since(start).Round(time.Millisecond))
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

// table 把这次建表的结果整理成实体表文件。old 是上一份(id 延续的种子),没有时全部新开。
func (b *songEntityBuild) table(old *songEntityTableFile, now time.Time) *songEntityTableFile {
	seeds, created := map[string]string{}, map[string]int64{}
	if old != nil {
		for id, s := range old.Songs {
			created[id] = s.Created
			for _, k := range s.Variants {
				seeds[k] = id
			}
		}
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
		groups := map[int]int{}
		lo, hi := 0.0, 0.0
		rec.IDs = map[string][]songIDRecord{}
		seen := map[string]bool{}
		for _, m := range members {
			if _, ok := groups[b.shareOf[m]]; !ok {
				groups[b.shareOf[m]] = len(groups)
			}
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
