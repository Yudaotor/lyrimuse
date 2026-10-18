package main

import (
	"context"
	"log"
	"sort"
	"time"
)

// artistAliasRecheckDelay:常驻进程启动后等多久再重核,不跟启动时那一批请求抢 MusicBrainz 的限速。
const artistAliasRecheckDelay = 2 * time.Minute

// startArtistAliasRecheck:常驻进程启动后调。水位到了就什么都不做。
func startArtistAliasRecheck(ctx context.Context) {
	scope := migrationScopeOf(migrationArtistAliasJudge, migrationArtistAliasJudgeVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(artistAliasRecheckDelay):
		}
		if _, complete := recheckArtistAliases(ctx, scope); complete {
			scope.markDone(migrationArtistAliasJudge, migrationArtistAliasJudgeVersion)
		}
	}()
}

// recheckArtistAliases 把 artistAliasCache 里存量的中文名按 lookupMusicBrainzChineseAlias 现在的判据重查一遍。旧判据只看
// 搜索首条的分数,认错人的结果落盘后不过期,还写进了条目的 canonical_artist(合并时只在空着才补,不会自己换掉),
// App 的歌手归并也直接读这份缓存。手工表里的写法不重查,它们本来就压过 MusicBrainz。
//
// 范围照迁移水位:全库时重查缓存里每一位;只补扫 lyrics/ 文件夹改过的那几条时,只重查那几首歌的歌手。
//
// 重查结果不同:改缓存(查空的记进 artistAliasRemoved,存盘时从盘上删掉),同一位歌手、canonical_artist 还是旧值的条目
// 一起改成新值(查空就清掉,下次解析再补)。全部查完才落改动:作废的超过一半(至少 recheckMaxRemovedFloor 条)时整批
// 不改 —— 那更像 MusicBrainz 的应答变了形状,不是这么多条都认错了人。有一条没问成就不算完成,下次启动再来。
func recheckArtistAliases(ctx context.Context, scope migrationScope) (changed int, complete bool) {
	var wanted map[string]bool // 补扫时:这几条歌的歌手段(缓存键里那一段)
	if !scope.all {
		wanted = map[string]bool{}
		enrichMu.Lock()
		for k := range scope.entries() {
			artist, _, _ := splitEnrichKey(k)
			wanted[artist] = true
		}
		enrichMu.Unlock()
	}
	artistAliasMu.Lock()
	olds := map[string]string{}
	for raw, v := range artistAliasCache {
		if v == "" || knownArtistAlias(raw) != "" {
			continue
		}
		if wanted != nil && !wanted[cleanMediaTag(raw)] {
			continue
		}
		olds[raw] = v
	}
	artistAliasMu.Unlock()
	raws := make([]string, 0, len(olds))
	for raw := range olds {
		raws = append(raws, raw)
	}
	sort.Strings(raws)

	fresh := map[string]string{}
	complete = true
	removed := 0
	for _, raw := range raws {
		v, err := lookupMusicBrainzChineseAlias(ctx, raw)
		if err != nil {
			if ctx.Err() != nil {
				return 0, false
			}
			complete = false
			continue
		}
		if v != olds[raw] {
			fresh[raw] = v
			if v == "" {
				removed++
			}
		}
	}
	if removed >= recheckMaxRemovedFloor && removed*2 > len(raws) {
		log.Printf("artist alias recheck: %d of %d would be dropped, looks like a MusicBrainz response change; kept them all", removed, len(raws))
		return 0, false
	}

	for _, raw := range raws {
		v, ok := fresh[raw]
		if !ok {
			continue
		}
		old := olds[raw]
		artistAliasMu.Lock()
		if artistAliasCache[raw] != old {
			artistAliasMu.Unlock()
			continue
		}
		artistAliasCache[raw] = v
		if v == "" {
			artistAliasRemoved[raw] = true
		} else {
			delete(artistAliasRemoved, raw)
		}
		artistAliasDirty = true
		artistAliasMu.Unlock()
		n := replaceCanonicalArtist(raw, old, v)
		log.Printf("artist alias recheck: %q %q -> %q (canonical_artist on %d entries)", raw, old, v, n)
		changed++
	}
	if changed > 0 {
		saveArtistAliasCache()
	}
	return changed, complete
}

// recheckMaxRemovedFloor:重核作废的条数到这么多、又超过一半时整批不改,见 recheckArtistAliases。
const recheckMaxRemovedFloor = 5

// replaceCanonicalArtist:这位歌手(按缓存键里的歌手段比)canonical_artist 还是 old 的条目换成 v,返回改了几条。
func replaceCanonicalArtist(raw, old, v string) int {
	want, _, _ := splitEnrichKey(enrichKey(raw, "", ""))
	enrichMu.Lock()
	n := 0
	for k, e := range enrichCache {
		if e.CanonicalArtist != old {
			continue
		}
		if artist, _, _ := splitEnrichKey(k); artist != want {
			continue
		}
		e.CanonicalArtist = v
		enrichCache[k] = e
		n++
	}
	if n > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if n > 0 {
		saveEnrichCache()
	}
	return n
}
