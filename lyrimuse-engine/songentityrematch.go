package main

import (
	"log/slog"
	"sort"
	"strings"
	"time"
)

// shareFollowWriting:歌词同步开着时,一条写法刚由「重新自动匹配」或后台重评、升级重试、补空、全量扫库定下歌词之后,它所在
// 共享组的其余写法跟着用这一条现在那份(18 章决策 33、34)。规则同跟着校准换词(sharePinnedGroup):对方钉着、标了纯音乐、手改或采纳的、歌词正是同一首歌一份校准
// 对着的(读穿着那个偏移)不动,不变式 6 前四条照样护着(songPlanKeep);换之前写留底,出处记 song-entity-share、reused_from
// 记这一条。实体里有手改原件时不跟:那时整首歌按手改同步。返回跟着换了的写法。
func shareFollowWriting(key string, now time.Time) []string {
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
	slog.Info("song entities: share group followed a version", "from", key, "changed", len(changed), "kept", kept)
	return changed
}

// shareFollowAfterSwap:后台那几条路径(rescoreLyricsWith / retryLyricsUpgradeWith,不是手动重新匹配)给 key 换了词、落了盘
// 之后调:共享组跟上,跟上的落盘、导出、通知重推。
func shareFollowAfterSwap(key string) {
	if changed := shareFollowWriting(key, time.Now()); len(changed) > 0 {
		flushShareChanges(changed)
	}
}

// songShareFollower:这条写法现在的歌词是从同一首歌别的写法同步来的(出处 song-entity-share:按组重搜、跟着校准、跟着别的写法、
// 手改副本)。后台给这种写法换了词不让共享组跟着它:两条名字不同的写法各自重评可能搜出不同的冠军,互相跟会来回换;交给
// 每天建表那一轮按组的代表名重搜统一。
func songShareFollower(e enrichEntry) bool {
	return e.LyricsEntityOrigin != "" ||
		(e.LyricsDecisionApplied != nil && e.LyricsDecisionApplied.Path == lyricsDecisionPathSongEntityShare)
}

// shareImportedEditsLocked:歌词同步开着时,歌词文件夹里被用户改过的那几条(导入时状态记录确认导出之后改过、正文或逐字真的变了)
// 按手改处理:标上手改,像歌词管理保存手改一样同步到整首歌(shareManualEditLocked,18 章决策 35)。不这样做的话,它只是这一条
// 写法的歌词变了,下一次建表那一组会被重搜、用户改的词被整组那一份盖掉。返回跟着改了的写法(不含 keys 本身)。调用方持 enrichMu。
func shareImportedEditsLocked(keys []string, now time.Time) []string {
	if len(keys) == 0 || !songEntitySharing() {
		return nil
	}
	var changed []string
	for _, k := range keys {
		e, ok := enrichCache[k]
		if !ok || e.Song == "" || strings.TrimSpace(e.Lyrics) == "" {
			continue
		}
		if !e.ManualLyrics || e.LyricsEntityOrigin != "" {
			e.ManualLyrics, e.LyricsEntityOrigin = true, ""
			enrichCache[k] = e
			enrichDirty = true
		}
		changed = append(changed, shareManualEditLocked(k, now)...)
	}
	if len(changed) > 0 {
		markEnrichEditedLocked(false, changed...)
		enrichDirty = true
		slog.Info("song entities: synced lyrics edited in the lyrics folder", "edited", len(keys), "synced", len(changed))
	}
	return changed
}
