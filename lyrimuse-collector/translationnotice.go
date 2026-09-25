package main

import (
	"log"
	"strings"
)

// stripTranslationNotices 删掉逐行 LRC 译文里正文是源塞进去的声明(isTranslationNotice)
// 的行,其余行原样保留;没有这种行时返回 (原文, false)。删完不够 isTimedLRC 的门槛就返回空串,
// 跟各源出口「不够 3 行带戳当没有」同一口径。
func stripTranslationNotices(tr string) (string, bool) {
	if !strings.Contains(tr, "著作权") && !strings.Contains(tr, "歌词翻译由") {
		return tr, false
	}
	lines := strings.Split(tr, "\n")
	out := lines[:0:0]
	changed := false
	for _, line := range lines {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(strings.TrimSpace(line), ""))
		if text != "" && lrcTimestampRe.MatchString(line) && isTranslationNotice(text) {
			changed = true
			continue
		}
		out = append(out, line)
	}
	if !changed {
		return tr, false
	}
	stripped := strings.Join(out, "\n")
	if !isTimedLRC(stripped) {
		return "", true
	}
	return stripped, true
}

// migrateTranslationNotices 对存量 enrich 缓存的 lyrics_tr 跑一遍
// stripTranslationNotices。源头(qq.go 两个译文出口、kugou.go krcLanguageTrackToLRC)
// 已经在剔,这一步只管已经落盘的。
//
// 位置(main.go):importLyricsFromFiles 之后(.tr.lrc 文件导回缓存的也要洗)、exportLyricsFiles
// 之前(洗完由 export 写回 .tr.lrc)。幂等,且只对含「著作权」「歌词翻译由」的译文做逐行扫描,不加水位闸。
// 不跳过 manual_lyrics:删的是源塞进译文轨的声明,不是用户选的词。
func migrateTranslationNotices() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		tr, ok := stripTranslationNotices(e.LyricsTr)
		if !ok {
			continue
		}
		e.LyricsTr = tr
		if tr == "" {
			e.LyricsTrLang = ""
			e.LyricsTrSource = ""
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
		log.Printf("translation notices: stripped from %d entries", fixed)
		saveEnrichCache()
	}
}
