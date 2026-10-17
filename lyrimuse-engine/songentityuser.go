package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"
)

// 拆开与恢复合并(歌词管理「同一首歌的其它写法」,请求通道 split_song / unsplit_song,见 18 章决策 28)。
//
// 用户判断文件 lyrimuse-song-entity-user.json 只有引擎写:只改 user_splits,其余键原样保留(新版加的字段被这一版读写一遍
// 不会丢)。拆开记的是「拆出去的每条写法 × 实体里留下的每条写法」这些写法对,建表时任何一对两边分在两个簇里都不并。
//
// 拆开当场:拆出去的写法换一个新的实体 id(两边写法少的那一半换,一样多时换拆出去的),歌词是同步写进去那份的按留底恢复;
// 然后请常驻进程马上重建一次实体表、按开关同步一轮(requestSongEntityRebuild)。恢复合并删掉一组写法内部的全部写法对(App
// 传两边各自所在实体的全部写法),同样请重建。

const songEntityUserVersion = 1

// songEntityRebuildNow:拆开、恢复合并之后请常驻进程马上重建一次(startSongEntityShadow 收)。只缓冲一个:连着几次只建一次。
var songEntityRebuildNow = make(chan struct{}, 1)

func requestSongEntityRebuild() {
	select {
	case songEntityRebuildNow <- struct{}{}:
	default:
	}
}

// editSongEntityUserSplits 读用户判断文件,交给 edit 改写法对(songPairKey → 一对键),改了才写回;返回 edit 的结果。
// 文件不存在时从空的开始;解不开时报错、不覆盖。
func editSongEntityUserSplits(path string, edit func(pairs map[string][2]string) bool) error {
	doc := map[string]json.RawMessage{}
	pairs := map[string][2]string{}
	switch data, err := os.ReadFile(path); {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return err
	default:
		if err := json.Unmarshal(data, &doc); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		var raw [][]string
		if v, ok := doc["user_splits"]; ok {
			if err := json.Unmarshal(v, &raw); err != nil {
				return fmt.Errorf("%s: user_splits: %w", path, err)
			}
		}
		for _, p := range raw {
			if len(p) == 2 && p[0] != "" && p[1] != "" && p[0] != p[1] {
				pairs[songPairKey(p[0], p[1])] = songSplitPair(p[0], p[1])
			}
		}
	}
	if !edit(pairs) {
		return nil
	}
	list := make([][2]string, 0, len(pairs))
	for _, p := range pairs {
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i][0] != list[j][0] {
			return list[i][0] < list[j][0]
		}
		return list[i][1] < list[j][1]
	})
	enc, err := json.Marshal(list)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		delete(doc, "user_splits")
	} else {
		doc["user_splits"] = enc
	}
	if _, ok := doc["version"]; !ok {
		doc["version"] = json.RawMessage(fmt.Sprint(songEntityUserVersion))
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data)
}

// songSplitPair:一对写法键,小的在前。
func songSplitPair(a, b string) [2]string {
	if b < a {
		a, b = b, a
	}
	return [2]string{a, b}
}

// splitSongEdit:把 keys 这几条写法从它们所在的实体里拆出去。keys 必须都在缓存里、属于同一个实体,实体里还得留下至少一条。
func splitSongEdit(keys []string, now time.Time) enrichEditOutcome {
	if len(keys) == 0 {
		return enrichEditOutcome{err: fmt.Errorf("split_song: empty keys")}
	}
	enrichMu.Lock()
	song, rest, err := songSplitSidesLocked(keys)
	enrichMu.Unlock()
	if err != nil {
		return enrichEditOutcome{err: err}
	}
	added := 0
	err = editSongEntityUserSplits(songEntityUserPath(), func(pairs map[string][2]string) bool {
		for _, a := range keys {
			for _, b := range rest {
				pk := songPairKey(a, b)
				if _, ok := pairs[pk]; !ok {
					pairs[pk] = songSplitPair(a, b)
					added++
				}
			}
		}
		return added > 0
	})
	if err != nil {
		return enrichEditOutcome{err: fmt.Errorf("split_song: %w", err)}
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	// 写文件期间实体变了(重建、别的请求)就不再动条目:写法对已经记下,下一次建表照样拆开。
	if s, r, err := songSplitSidesLocked(keys); err != nil || s != song || !slices.Equal(r, rest) {
		slog.Info("song entities: split recorded, entity changed meanwhile", "song", song, "keys", len(keys))
		requestSongEntityRebuild()
		return enrichEditOutcome{changed: 0}
	}
	moved := keys
	if len(rest) < len(keys) {
		moved = rest
	}
	id := newSongEntityID()
	for _, k := range moved {
		e := enrichCache[k]
		e.Song, e.SongShare = id, 0
		enrichCache[k] = e
	}
	restored := songSplitRestoreLocked(keys)
	for _, k := range keys {
		cancelInFlightEnrichLocked(k)
	}
	slog.Info("song entities: user split", "song", song, "split", len(keys), "kept", len(rest), "new", id,
		"restored", len(restored), "pairs", added)
	requestSongEntityRebuild()
	touched := append(slices.Clone(keys), rest...)
	markEnrichEditedLocked(false, touched...)
	enrichDirty = true
	return enrichEditOutcome{changed: len(touched), exports: restored}
}

// songSplitSidesLocked:keys 所在的实体 id 和实体里留下的写法(按键排序)。调用方持 enrichMu。
func songSplitSidesLocked(keys []string) (string, []string, error) {
	song := ""
	in := map[string]bool{}
	for _, k := range keys {
		e, ok := enrichCache[k]
		switch {
		case !ok:
			return "", nil, fmt.Errorf("split_song: %q is not in the cache", k)
		case e.Song == "":
			return "", nil, fmt.Errorf("split_song: %q has no song", k)
		case song != "" && e.Song != song:
			return "", nil, fmt.Errorf("split_song: keys belong to different songs")
		}
		song = e.Song
		in[k] = true
	}
	var rest []string
	for k, e := range enrichCache {
		if e.Song == song && !in[k] {
			rest = append(rest, k)
		}
	}
	if len(rest) == 0 {
		return "", nil, fmt.Errorf("split_song: nothing would be left in %s", song)
	}
	sort.Strings(rest)
	return song, rest, nil
}

// songSplitRestoreLocked:拆出去的写法里,歌词是同步写进去那份的按留底恢复、删掉留底;手改副本没有能用的留底时只去掉副本
// 标记(同 releaseStaleCopiesLocked)。它们自己的手改、校准不动。返回歌词变了的写法。调用方持 enrichMu。
func songSplitRestoreLocked(keys []string) []string {
	restored := releaseStaleCopiesLocked(keys, nil)
	done := map[string]bool{}
	for _, k := range restored {
		done[k] = true
	}
	for _, k := range keys {
		if done[k] {
			continue
		}
		e := enrichCache[k]
		pre, ok := songShareRestorable(k, e)
		if !ok {
			continue
		}
		songShareRestore(&e, pre)
		enrichCache[k] = e
		noteFileErr("remove", songSharePrePath(k), removeIfExists(songSharePrePath(k)))
		restored = append(restored, k)
	}
	sort.Strings(restored)
	return restored
}

// unsplitSongEdit:删掉两端都在 keys 里的拆开记录,删了就请常驻进程马上重建。条目不动:重建时按证据重新合。
func unsplitSongEdit(keys []string) (int, error) {
	if len(keys) < 2 {
		return 0, fmt.Errorf("unsplit_song: need at least two keys")
	}
	in := map[string]bool{}
	for _, k := range keys {
		in[k] = true
	}
	removed := 0
	err := editSongEntityUserSplits(songEntityUserPath(), func(pairs map[string][2]string) bool {
		for pk, p := range pairs {
			if in[p[0]] && in[p[1]] {
				delete(pairs, pk)
				removed++
			}
		}
		return removed > 0
	})
	if err != nil {
		return 0, fmt.Errorf("unsplit_song: %w", err)
	}
	if removed > 0 {
		slog.Info("song entities: user unsplit", "key_pairs", removed)
		requestSongEntityRebuild()
	}
	return removed, nil
}

// resolveManualConflictEdit:同一个共享组里有几份内容不同的手改原件(建表之后那一轮不替用户选,见 shareManualLocked)时,用户在
// 歌词管理里选 key 那一份统一(请求 resolve_manual_conflict,18 章决策 31)。别的原件换成它的副本:先按 writeSongSharePre 留底,
// 另把它们这一刻的整条存进 ~/.config/lyrimuse-backups/<时刻>-song-entity-manual/(留底只存第一次同步之前那份,这一刻的手改
// 只有这里有);其余写法照手改同步跟上。开关关着、这条不是手改原件、没有实体 id 时拒绝。
func resolveManualConflictEdit(key string, now time.Time) enrichEditOutcome {
	if !songEntitySharing() {
		return enrichEditOutcome{err: fmt.Errorf("resolve_manual_conflict: lyrics sharing is off")}
	}
	pins := lyricsPinnedKeys() // 读文件,拿 enrichMu 之前取
	enrichMu.Lock()
	defer enrichMu.Unlock()
	src, ok := enrichCache[key]
	if !ok || src.Song == "" || !songShareManualOriginal(src) {
		return enrichEditOutcome{err: fmt.Errorf("resolve_manual_conflict: %q is not a manual original of a song", key)}
	}
	fp := songOffsetFingerprint(src.Lyrics, src.LyricsYRC)
	var keys, others []string
	for k, e := range enrichCache {
		if e.Song != src.Song || e.SongShare != src.SongShare {
			continue
		}
		keys = append(keys, k)
		if k != key && songShareManualOriginal(e) && songOffsetFingerprint(e.Lyrics, e.LyricsYRC) != fp {
			others = append(others, k)
		}
	}
	sort.Strings(keys)
	sort.Strings(others)
	if len(others) > 0 {
		if err := backupManualOriginalsLocked(songShareManualBackupDir(now), others); err != nil {
			return enrichEditOutcome{err: fmt.Errorf("resolve_manual_conflict: back up: %w", err)}
		}
		if err := writeSongSharePresLocked(others, fp, now); err != nil {
			return enrichEditOutcome{err: fmt.Errorf("resolve_manual_conflict: %w", err)}
		}
	}
	changed := slices.Clone(others)
	for _, k := range others {
		e := enrichCache[k]
		songShareCopyManual(&e, src, key, now)
		enrichCache[k] = e
	}
	more, _ := shareManualLocked(keys, key, pins, now)
	changed = append(changed, more...)
	for _, k := range changed {
		cancelInFlightEnrichLocked(k)
	}
	if len(changed) > 0 {
		markEnrichEditedLocked(false, changed...)
		enrichDirty = true
	}
	slog.Info("song entities: resolved manual lyrics conflict", "song", src.Song, "kept", key, "replaced", len(others),
		"synced", len(more))
	return enrichEditOutcome{changed: len(changed), exports: changed}
}

// writeSongSharePresLocked:keys 逐条按 writeSongSharePre 留底(条目取 enrichCache 里这一刻的),有一条写不成就把这一次已经
// 写了的撤回(新建的删掉,已有的 synced 改回原来的)、报错:要么都写成,要么留底跟没调过一样,不留 synced 对着没写进去的
// 歌词的。调用方持 enrichMu。
func writeSongSharePresLocked(keys []string, synced string, now time.Time) error {
	type written struct {
		key, prev string
		created   bool
	}
	var done []written
	for _, k := range keys {
		prev := ""
		if p, err := readSongSharePre(songSharePrePath(k)); err == nil {
			prev = p.Synced
		}
		created, err := writeSongSharePre(k, enrichCache[k], synced, now)
		if err == nil {
			done = append(done, written{key: k, prev: prev, created: created})
			continue
		}
		for _, w := range done {
			path := songSharePrePath(w.key)
			if w.created {
				noteFileErr("remove", path, os.Remove(path))
				continue
			}
			if _, uerr := writeSongSharePre(w.key, enrichCache[w.key], w.prev, now); uerr != nil {
				slog.Error("song entities: undo a sync backup", "key", w.key, "err", uerr)
			}
		}
		return err
	}
	return nil
}

// songShareManualBackupDir:统一手改时被替换的原件存在这里(跟 songShareBackupDir 同级)。
func songShareManualBackupDir(now time.Time) string {
	dir := configDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(dir), clientName+"-backups", now.Format("20060102-150405")+"-song-entity-manual")
}

// backupManualOriginalsLocked:keys 这几条此刻的整条(当前歌词的出处带候选明细)写进 dir/entries.json(写法键 → 条目)。
// 调用方持 enrichMu。
func backupManualOriginalsLocked(dir string, keys []string) error {
	if dir == "" {
		return fmt.Errorf("no config directory")
	}
	out := make(map[string]enrichEntry, len(keys))
	for _, k := range keys {
		e := enrichCache[k]
		e.LyricsDecisionApplied = withDecisionDetails(k, e.LyricsDecisionApplied)
		out[k] = e
	}
	data, err := json.Marshal(out)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, "entries.json"), data)
}

// withShareGroupMatesLocked:歌词同步开着时,用户对一条写法标 / 撤纯音乐作用到它的共享组(同一实体、同一共享组编号):keys 后面
// 按键排补上组里其余写法,自己手改过词、或采纳的那份还在的不补(用户给了词,就不是纯音乐)。去重,原有的顺序不变。
// 调用方持 enrichMu。
func withShareGroupMatesLocked(keys []string) []string {
	type group struct {
		song  string
		share int
	}
	seen := map[string]bool{}
	groups := map[group]bool{}
	for _, k := range keys {
		seen[k] = true
		if e, ok := enrichCache[k]; ok && e.Song != "" {
			groups[group{e.Song, e.SongShare}] = true
		}
	}
	if len(groups) == 0 {
		return keys
	}
	var extra []string
	for k, e := range enrichCache {
		if !seen[k] && e.Song != "" && groups[group{e.Song, e.SongShare}] && !e.ManualLyrics && !songSharePickHeld(e) {
			extra = append(extra, k)
		}
	}
	sort.Strings(extra)
	return append(slices.Clone(keys), extra...)
}
