package main

import (
	"log/slog"
	"sort"
	"time"
)

// shareFollowRematch:歌词同步开着时,歌词管理「重新自动匹配」一条写法之后,它所在共享组的其余写法跟着用这一条现在那份
// (18 章决策 33)。规则同跟着校准换词(sharePinnedGroup):对方钉着、标了纯音乐、手改或采纳的、歌词正是同一首歌一份校准
// 对着的(读穿着那个偏移)不动,不变式 6 前四条照样护着(songPlanKeep);换之前写留底,出处记 song-entity-share、reused_from
// 记这一条。实体里有手改原件时不跟:那时整首歌按手改同步。返回跟着换了的写法。
func shareFollowRematch(key string, now time.Time) []string {
	if !songEntitySharing() {
		return nil
	}
	pins, content := lyricsPinSnapshot() // 读文件,拿 enrichMu 之前取
	enrichMu.Lock()
	src, ok := enrichCache[key]
	if !ok || src.Song == "" || src.Instrumental || src.ManualLyrics || songSharePickHeld(src) ||
		songOffsetFingerprint(src.Lyrics, src.LyricsYRC) == "" {
		enrichMu.Unlock()
		return nil
	}
	var mates []string
	snap := map[string]enrichEntry{}
	for k, e := range enrichCache {
		if e.Song != src.Song {
			continue
		}
		if songShareManualOriginal(e) {
			enrichMu.Unlock()
			return nil
		}
		if k != key && e.SongShare == src.SongShare {
			mates = append(mates, k)
			snap[k] = e
		}
	}
	calibrated := songShareCalibrationsLocked(pins, content)
	enrichMu.Unlock()
	if len(mates) == 0 {
		return nil
	}
	sort.Strings(mates)
	dir := decisionSidecarDir()
	to := songPlanLyricsFor(key, src.Lyrics, src.LyricsYRC, src.LyricsSource, false, false, src.LyricsDecisionApplied, dir)
	own := map[string]*songPlanLyrics{}
	for _, k := range mates {
		e := snap[k]
		own[k] = songPlanLyricsFor(k, e.Lyrics, e.LyricsYRC, e.LyricsSource, false, pins[k], e.LyricsDecisionApplied, dir)
	}

	enrichMu.Lock()
	defer enrichMu.Unlock()
	live, ok := enrichCache[key]
	if !ok || songOffsetFingerprint(live.Lyrics, live.LyricsYRC) != to.fp || live.SongShare != src.SongShare {
		return nil
	}
	var changed []string
	kept := 0
	for _, k := range mates {
		e, ok := enrichCache[k]
		if !ok || pins[k] || e.Instrumental || e.ManualLyrics || songSharePickHeld(e) || calibrated.holds(e) ||
			e.Song != src.Song || e.SongShare != src.SongShare {
			continue
		}
		fp := songOffsetFingerprint(e.Lyrics, e.LyricsYRC)
		if fp == to.fp || fp != songOffsetFingerprint(snap[k].Lyrics, snap[k].LyricsYRC) {
			continue
		}
		if cur := own[k]; cur != nil && songPlanKeep(cur, to, false) != "" {
			kept++
			continue
		}
		if _, err := writeSongSharePre(k, e, to.fp, now); err != nil {
			slog.Error("song entities: back up before following a rematch", "key", k, "err", err)
			continue
		}
		songShareCopyPinned(&e, live, key, now)
		enrichCache[k] = e
		cancelInFlightEnrichLocked(k)
		changed = append(changed, k)
	}
	if len(changed) > 0 {
		markEnrichEditedLocked(false, changed...)
		enrichDirty = true
	}
	slog.Info("song entities: share group followed a rematch", "from", key, "changed", len(changed), "kept", kept)
	return changed
}
