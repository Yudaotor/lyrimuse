package main

import "log"

// migrateInstrumentalPlaceholders 给存量里正文只有纯音乐占位和署名的条目标上纯音乐(isInstrumentalPlaceholderLyric)。
// 这类正文在打分时判废(isCreditOnlyLRC),网易云那一路也不再把它当歌词交出来,运行期不再产生。
//
// 只打标、不删正文,跟自动加标的另两条路径一致(见 enrichEntry.Instrumental)。用户存过歌词、采纳过候选、
// 锁定过来源或撤过纯音乐标记的不动。
func migrateInstrumentalPlaceholders() {
	scope := migrationScopeOf(migrationInstrumentalPlaceholder, migrationInstrumentalPlaceholderVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	marked := 0
	for k, e := range scope.entries() {
		if e.Lyrics == "" || e.ManualLyrics || e.ManualPickSHA != "" || e.LyricsSourceChoice != "" || !e.autoMarksInstrumental() {
			continue
		}
		if !isInstrumentalPlaceholderLyric(e.Lyrics) {
			continue
		}
		e.Instrumental = true
		enrichCache[k] = e
		marked++
	}
	if marked > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if marked > 0 {
		log.Printf("instrumental placeholder migration: marked %d entries instrumental", marked)
		saveEnrichCache()
	}
	markMigrationDone(migrationInstrumentalPlaceholder, migrationInstrumentalPlaceholderVersion)
}
