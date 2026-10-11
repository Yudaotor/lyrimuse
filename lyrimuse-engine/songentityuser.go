package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
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
	restored := releaseStaleCopiesLocked(keys)
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
