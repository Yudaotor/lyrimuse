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

// dropUnneededLines 删掉机翻译文里原文那一行现在不用翻的行(lineNeedsTranslation 为假,先剥演唱者标签,跟
// selectTranslationWork 同一套),按时间戳对到原文行:同一时间戳有几行原文时,有一行要翻就留着;对不上原文的行不动。
// 没有要删的行时返回 (原文, false);删完一行不剩返回空串。
func dropUnneededLines(lyrics, tr, target string) (string, bool) {
	speakers := lyricSpeakerLabels(lyrics)
	needed := map[string]bool{}
	for _, l := range parseLRCLines(lyrics) {
		needed[l.tag] = needed[l.tag] || lineNeedsTranslation(withoutSpeakerLabel(l.text, speakers), target)
	}
	var b strings.Builder
	changed := false
	for _, l := range parseLRCLines(tr) {
		if need, ok := needed[l.tag]; ok && !need {
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
		dropUntranslatedLines, "left untranslated")
}

// migrateUnneededMachineLines 对存量机翻跑一遍 dropUnneededLines。新翻的在送翻选行(selectTranslationWork)就不收这种行。
func migrateUnneededMachineLines() {
	migrateMachineTranslationLines(migrationUnneededMachineLines, migrationUnneededMachineLinesVersion,
		dropUnneededLines, "that need no translation")
}

// migrateMachineTranslationLines 对存量机翻(lyrics_tr_source = machine、记了语言的)逐条跑 drop;社区译文不动。运行期
// 在源头就不再产生这些行,所以带水位、只跑一次。位置(main.go):夹在 importLyricsFromFiles 与 exportLyricsFiles 之间,
// 删空的连同语言、来源一起清掉,由 export 删掉 .tr.lrc。
func migrateMachineTranslationLines(name string, version int, drop func(lyrics, tr, target string) (string, bool), what string) {
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
		tr, ok := drop(e.Lyrics, e.LyricsTr, myMemoryLangCode(e.LyricsTrLang))
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
