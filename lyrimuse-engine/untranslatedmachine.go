package main

import (
	"log"
	"strings"
)

// dropUntranslatedLines 删掉机翻译文里不算译文的行(lineTranslated 为假:外文原样没动,只换了繁简写法、标点、空白
// 或大小写),按时间戳对到原文行;对不上原文的行不动。没有要删的行时返回 (原文, false);删完一行不剩返回空串。
func dropUntranslatedLines(lyrics, tr, target string) (string, bool) {
	orig := map[string]string{}
	for _, l := range parseLRCLines(lyrics) {
		if _, ok := orig[l.tag]; !ok {
			orig[l.tag] = l.text
		}
	}
	var b strings.Builder
	changed := false
	for _, l := range parseLRCLines(tr) {
		if o, ok := orig[l.tag]; ok && !lineTranslated(o, l.text, target) {
			changed = true
			continue
		}
		b.WriteString(l.tag)
		b.WriteString(l.text)
		b.WriteByte('\n')
	}
	if !changed {
		return tr, false
	}
	return strings.TrimRight(b.String(), "\n"), true
}

// dropUnneededLines 删掉机翻译文里现在不会再送翻的行:按时间戳对到原文行,那个时间戳上没有一行会被送翻选行
// (selectTranslationWork,歌名、歌手取自 key)选中就删,不用翻的文字、抬头、署名、拟声词、唱名都在里面。同一时间戳有几行
// 原文时,有一行会送翻就留着;对不上原文的行不动。没有要删的行时返回 (原文, false);删完一行不剩返回空串。
func dropUnneededLines(key, lyrics, tr, target string) (string, bool) {
	artist, title, _ := splitEnrichKey(key)
	work := selectTranslationWork(lyrics, target, artist, title)
	sent := map[string]bool{}
	for _, occ := range work.occurrences {
		for _, i := range occ {
			sent[work.lines[i].tag] = true
		}
	}
	present := map[string]bool{}
	for _, l := range work.lines {
		present[l.tag] = true
	}
	var b strings.Builder
	changed := false
	for _, l := range parseLRCLines(tr) {
		if present[l.tag] && !sent[l.tag] {
			changed = true
			continue
		}
		b.WriteString(l.tag)
		b.WriteString(l.text)
		b.WriteByte('\n')
	}
	if !changed {
		return tr, false
	}
	return strings.TrimRight(b.String(), "\n"), true
}

// migrateUntranslatedMachineLines 对存量机翻跑一遍 dropUntranslatedLines。新翻出来的在各级出口(dropUntranslated)就不收
// 这种行。
func migrateUntranslatedMachineLines() {
	migrateMachineTranslationLines(migrationUntranslatedMachineLines, migrationUntranslatedMachineLinesVersion,
		func(_, lyrics, tr, target string) (string, bool) { return dropUntranslatedLines(lyrics, tr, target) }, "left untranslated")
}

// migrateUnneededMachineLines 对存量机翻跑一遍 dropUnneededLines。新翻的在送翻选行(selectTranslationWork)就不收这种行。
func migrateUnneededMachineLines() {
	migrateMachineTranslationLines(migrationUnneededMachineLines, migrationUnneededMachineLinesVersion,
		dropUnneededLines, "that need no translation")
}

// migrateMachineTranslationLines 对存量机翻(lyrics_tr_source = machine、记了语言的)逐条跑 drop;社区译文不动。运行期
// 在源头就不再产生这些行,所以带水位、只跑一次。位置(main.go):夹在 importLyricsFromFiles 与 exportLyricsFiles 之间,
// 删空的连同语言、来源一起清掉,由 export 删掉 .tr.lrc。
func migrateMachineTranslationLines(name string, version int, drop func(key, lyrics, tr, target string) (string, bool), what string) {
	scope := migrationScopeOf(name, version)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	fixed, emptied := 0, 0
	for k, e := range scope.entries() {
		if e.LyricsTrSource != lyricsTrSourceMachine || e.LyricsTr == "" || e.LyricsTrLang == "" {
			continue
		}
		tr, ok := drop(k, e.Lyrics, e.LyricsTr, myMemoryLangCode(e.LyricsTrLang))
		if !ok {
			continue
		}
		e.LyricsTr = tr
		if tr == "" {
			e.LyricsTrLang, e.LyricsTrSource = "", ""
			emptied++
		}
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		// 必须显式置脏,否则 saveEnrichCache 是空操作。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("machine translations: dropped lines %s in %d entries (%d emptied)", what, fixed, emptied)
		saveEnrichCache()
	}
	markMigrationDone(name, version)
}
