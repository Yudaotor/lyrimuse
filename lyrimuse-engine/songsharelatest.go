package main

import "log"

// migrateShareLatestDecisions:存量里按组重搜时被拿名字去搜的那条写法(shareLatestDecisionStale),最近一次评估还停在共享那一轮
// 之前,「解析决策」面板把一轮更早的评估当成「后来又评过什么」给人看。改成指向共享那一轮,两槽同一份 —— 跟 applyShareRound
// 现在的写法一样,运行期不再产生。只动解析决策两槽,不碰歌词、来源、打分。见 18 章决策 71。
func migrateShareLatestDecisions() {
	scope := migrationScopeOf(migrationShareLatestDecisions, migrationShareLatestDecisionsVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	fixed := 0
	for k, e := range scope.entries() {
		if !shareLatestDecisionStale(e) {
			continue
		}
		e.LyricsDecision = e.LyricsDecisionApplied
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("share decision migration: %d entries' latest evaluation now points at the song-entity-share round they were searched in", fixed)
		saveEnrichCache()
	}
	markMigrationDone(migrationShareLatestDecisions, migrationShareLatestDecisionsVersion)
}

// shareLatestDecisionStale:这条写法现在的歌词是按组重搜时拿它的名字搜来的(出处 song-entity-share、没有 reused_from;组里
// 跟着用的写法记着 reused_from),最近一次评估却比那一轮早。
func shareLatestDecisionStale(e enrichEntry) bool {
	a, d := e.LyricsDecisionApplied, e.LyricsDecision
	return a != nil && d != nil && a.Path == lyricsDecisionPathSongEntityShare && a.ReusedFrom == "" && d.DecidedAt < a.DecidedAt
}
