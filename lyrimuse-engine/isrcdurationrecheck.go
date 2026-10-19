package main

import (
	"encoding/json"
	"log"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// 存量条目上按别的时长核过的 ISRC 降成 searched(18 章决策 77)。运行期在源头已经这样做:并条目(mergeEntryISRCs)、原地改
// 时长(demoteISRCsAcrossDuration)都按 isrcLevelAcrossDuration 降;这之前留下的按两种证据找,播放器报的号都不动:
//   - 条目记下的时长跟选词时长(ResolvedDurationSecs,这份歌词按多长的时长选的,这一轮候选报的号也按它核)差过两倍容差:
//     按选词时长核过的号离现在的时长一定超过一倍容差,核不过。原地改了时长、没重搜的条目是这样。
//   - 启动迁移并条目前留的备份(`.keynorm-<时间>.bak`,backupEnrichKeyMergeGroups):合并前记着这个号的那几条,时长都对不上
//     现在这一条的。「~durN」并回基条目时两边时长可以差很多(variantFoldsIntoBase),落选那条的号原样并了过来。

// isrcBackupEntry:合并备份里一条记录用得上的两样。
type isrcBackupEntry struct {
	ISRCs        []string `json:"isrcs"`
	DurationSecs float64  `json:"duration_secs"`
}

// readEnrichKeyMergeBackups:主缓存旁边的几份 `.keynorm-<时间>.bak`,按文件名排序;读不出、解不开的跳过。
func readEnrichKeyMergeBackups() []map[string]isrcBackupEntry {
	if enrichPath == "" {
		return nil
	}
	dir, base := filepath.Dir(enrichPath), filepath.Base(enrichPath)
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []map[string]isrcBackupEntry
	for _, ent := range ents {
		rest, ok := strings.CutPrefix(ent.Name(), base+".")
		if !ok || ent.IsDir() || !strings.HasPrefix(rest, "keynorm-") || !strings.HasSuffix(rest, ".bak") {
			continue
		}
		path := filepath.Join(dir, ent.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			noteFileErr("read", path, err)
			continue
		}
		var m map[string]isrcBackupEntry
		if err := json.Unmarshal(data, &m); err != nil {
			noteFileErr("decode", path, err)
			continue
		}
		out = append(out, m)
	}
	return out
}

// isrcRecheckGroupKey:合并备份里的旧键跟现在的键对上用的组键:去掉「~durN」再归一化(enrichKey)。
func isrcRecheckGroupKey(key string) string {
	artist, title, album := splitEnrichKey(key)
	return enrichKey(artist, titleWithoutDurationVariant(title), album)
}

// isrcMergeBackupDurations:组键 → 号 → 合并前记着这个号的那几条的时长(没有时长的不算)。
func isrcMergeBackupDurations(backups []map[string]isrcBackupEntry) map[string]map[string][]float64 {
	out := map[string]map[string][]float64{}
	for _, m := range backups {
		for k, e := range m {
			if e.DurationSecs <= 0 {
				continue
			}
			g := isrcRecheckGroupKey(k)
			for _, raw := range e.ISRCs {
				c := normalizeISRC(raw)
				if c == "" {
					continue
				}
				if out[g] == nil {
					out[g] = map[string][]float64{}
				}
				out[g][c] = append(out[g][c], e.DurationSecs)
			}
		}
	}
	return out
}

// recheckISRCDurations:key 这一条按上面两种证据该降的号降成 searched,返回改没改。known 是 isrcMergeBackupDurations 的结果。
func recheckISRCDurations(key string, e *enrichEntry, known map[string]map[string][]float64) bool {
	d, r := e.DurationSecs, e.ResolvedDurationSecs
	offResolved := d > 0 && r > 0 && math.Abs(d-r) > 2*isrcDurationToleranceSecs
	group := known[isrcRecheckGroupKey(key)]
	return demoteISRCs(e, func(code, level string) bool {
		if level == isrcLevelPlayer {
			return false
		}
		if offResolved {
			return true
		}
		secs := group[code]
		return d > 0 && len(secs) > 0 && !slices.ContainsFunc(secs, func(s float64) bool { return isrcDurationFits(s, d) })
	})
}

// migrateISRCDurationRecheck:存量跑一遍 recheckISRCDurations。readBackups 给合并备份(水位到了整道跳过时不调)。
func migrateISRCDurationRecheck(readBackups func() []map[string]isrcBackupEntry) {
	scope := migrationScopeOf(migrationISRCDurationRecheck, migrationISRCDurationRecheckVersion)
	if scope.skip() {
		return
	}
	known := isrcMergeBackupDurations(readBackups())
	enrichMu.Lock()
	n := 0
	for k, e := range scope.entries() {
		if !recheckISRCDurations(k, &e, known) {
			continue
		}
		enrichCache[k] = e
		n++
		log.Printf("isrc: %q codes recorded at another duration demoted to searched (%.1fs, lyrics chosen at %.1fs)",
			k, e.DurationSecs, e.ResolvedDurationSecs)
	}
	if n > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if n > 0 {
		log.Printf("isrc: demoted codes recorded at another duration on %d entries", n)
		saveEnrichCache()
	}
	markMigrationDone(migrationISRCDurationRecheck, migrationISRCDurationRecheckVersion)
}
