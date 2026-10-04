package main

import (
	"log"
	"strings"
)

// 歌词文本的换行统一成 LF、去掉开头的 BOM。
//
// 酷狗的网络歌词几乎全是 CRLF(本机 3509 条里 3494 条),三分之一开头带 BOM(1198 条,偶尔两个);QQ 偶有 CRLF(34 条);
// 逐字轨 1304 份、译文 28 份同样带着。App 的 LRCParser / YRCParser 和这边的打分都自己兜了底,显示不受影响,但每个新的
// 消费方都得记得兜一次(lyricspeaker.go 就为此单独修过一回),导出的 .lrc 文件里也带着这些字符。
//
// 新抓取的在 rank 那道门口统一(decodeLyricSourceResultEntities);存量由 migrateLyricLineEndings 统一。两头必须一起做:
// 只做一头的话,重评时新抓的和存着的只差换行,也会被当成「正文变了」整份重写(机翻清掉重翻,App 按内容指纹存的单曲
// 偏移跟着失效)。

// normalizeLyricText 去掉开头的 BOM(可能不止一个),把 CRLF / 单独的 CR 统一成 LF。
func normalizeLyricText(s string) string {
	for strings.HasPrefix(s, "\ufeff") {
		s = strings.TrimPrefix(s, "\ufeff")
	}
	if !strings.Contains(s, "\r") {
		return s
	}
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
}

// migrateLyricLineEndings 对存量 enrich 缓存的六个歌词文本字段跑一遍 normalizeLyricText。
//
// 调用时机(main.go):importLyricsFromFiles 之后(lyrics/ 文件夹赢完,改的才是权威内容)、exportLyricsFiles 之前
// (改完由 export 把统一过的正文写回导出文件),也在 migrateManualPickMarks 之前。带水位闸,只跑一遍。
//
// 不跳过 manual_lyrics、不跳过校准过时间轴的:这是无损的格式规范化,一个字、一个时间戳都不变。手动选定留痕
// manual_pick_sha 改前跟正文对得上的,按新正文重算(开头的 BOM 会进指纹,CRLF 不会 —— 那一步本来就逐行 TrimSpace)。
// App 侧单曲偏移的 key 含正文指纹(剥了 BOM、没剥 CR),正文一变旧值就查不到;校准过的歌由 App 的
// LyricsOffsetStore.carryOverOffset 在下次播放时挪到新指纹上(同一首只剩这一条旧值时),那条兜底就是为这类无损
// 改写准备的。
func migrateLyricLineEndings() {
	scope := migrationScopeOf(migrationLyricLineEndings, migrationLyricLineEndingsVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	fixed := 0
	for k, e := range scope.entries() {
		lyrics := normalizeLyricText(e.Lyrics)
		tr := normalizeLyricText(e.LyricsTr)
		roma := normalizeLyricText(e.LyricsRoma)
		yrc := normalizeLyricText(e.LyricsYRC)
		plain := normalizeLyricText(e.PlainLyrics)
		bg := normalizeLyricText(e.LyricsBG)
		if lyrics == e.Lyrics && tr == e.LyricsTr && roma == e.LyricsRoma && yrc == e.LyricsYRC && plain == e.PlainLyrics &&
			bg == e.LyricsBG {
			continue
		}
		if e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(e.Lyrics) {
			e.ManualPickSHA = manualPickFingerprint(lyrics)
		}
		e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics, e.LyricsBG = lyrics, tr, roma, yrc, plain, bg
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("lyric line-ending migration: normalized %d entries", fixed)
		saveEnrichCache()
	}
	markMigrationDone(migrationLyricLineEndings, migrationLyricLineEndingsVersion)
}
