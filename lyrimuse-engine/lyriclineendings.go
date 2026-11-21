package main

import (
	"log"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 歌词文本的换行统一成 LF、去掉开头的 BOM 和控制字符,行内的制表符和行 / 段分隔符换成空格,只有一行占位文字的当成没有歌词。
//
// 酷狗的网络歌词几乎全是 CRLF(本机 3509 条里 3494 条),三分之一开头带 BOM(1198 条,偶尔两个);QQ 偶有 CRLF(34 条);
// 逐字轨 1304 份、译文 28 份同样带着。App 的 LRCParser / YRCParser 和这边的打分都自己兜了底,显示不受影响,但每个新的
// 消费方都得记得兜一次(lyricspeaker.go 就为此单独修过一回),导出的 .lrc 文件里也带着这些字符。
//
// 新抓取的在 rank 那道门口统一(decodeLyricSourceResultEntities);存量由 migrateLyricLineEndings 统一。两头必须一起做:
// 只做一头的话,重评时新抓的和存着的只差换行,也会被当成「正文变了」整份重写(机翻清掉重翻,App 按内容指纹存的单曲
// 偏移跟着失效)。

// normalizeLyricText 去掉开头的 BOM(可能不止一个)和控制字符(stripLyricControlChars),把 CRLF / 单独的 CR 统一成 LF,
// 行内的制表符和 U+2028 / U+2029 换成空格(flattenInlineBreaks);整份只是「暂无歌词」这类占位的当成没有歌词,返回空串。
func normalizeLyricText(s string) string {
	for strings.HasPrefix(s, "\ufeff") {
		s = strings.TrimPrefix(s, "\ufeff")
	}
	s = stripLyricControlChars(s)
	if strings.Contains(s, "\r") {
		s = strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
	}
	s = flattenInlineBreaks(s)
	if isPlaceholderLyrics(s) {
		return ""
	}
	return s
}

// flattenInlineBreaks 把制表符、U+2028(行分隔符)、U+2029(段分隔符)换成一个空格;紧挨着空白、换行或在开头结尾的直接去掉,
// 不留两个空格或行尾空格。App 按 Character.isNewline 切行的地方(读音、假名标注)会在 U+2028 处多切出一行,
// 跟时间戳对不上;制表符在歌词窗口里画成一大段空白。见 09 章决策 399。
func flattenInlineBreaks(s string) string {
	if !strings.ContainsAny(s, "\t\u2028\u2029") {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for i, r := range s {
		if r != '\t' && r != '\u2028' && r != '\u2029' {
			b.WriteRune(r)
			continue
		}
		prev, _ := utf8.DecodeLastRuneInString(b.String())
		next, size := utf8.DecodeRuneInString(s[i+utf8.RuneLen(r):])
		if b.Len() == 0 || unicode.IsSpace(prev) || size == 0 || unicode.IsSpace(next) {
			continue
		}
		b.WriteByte(' ')
	}
	return b.String()
}

// lyricPlaceholderLines:有的源查无歌词时不报空,而是交一行占位文字(「[00:00.00]暂无歌词」)。
var lyricPlaceholderLines = map[string]bool{"暂无歌词": true, "暫無歌詞": true, "无歌词": true, "無歌詞": true, "<not found>": true}

var lyricPlaceholderTagRe = regexp.MustCompile(`^(?:\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+|^\[[A-Za-z#]+:[^\]]*\]$`)

// isPlaceholderLyrics:去掉时间戳和 [ti:] 这类标签行后,只剩一行、而且是占位文字。
func isPlaceholderLyrics(s string) bool {
	if len(s) > 512 {
		return false
	}
	found := false
	for _, line := range strings.Split(s, "\n") {
		text := strings.TrimSpace(lyricPlaceholderTagRe.ReplaceAllString(strings.TrimSpace(line), ""))
		if text == "" {
			continue
		}
		if found || !lyricPlaceholderLines[text] {
			return false
		}
		found = true
	}
	return found
}

// migrateLyricLineEndings 对存量 enrich 缓存的六个歌词文本字段跑一遍 normalizeLyricText。
//
// 调用时机(main.go):importLyricsFromFiles 之后(lyrics/ 文件夹赢完,改的才是权威内容)、exportLyricsFiles 之前
// (改完由 export 把统一过的正文写回导出文件),也在 migrateManualPickMarks 之前。带水位闸,只跑一遍。
//
// 不跳过 manual_lyrics、不跳过校准过时间轴的:这是格式规范化,时间戳不变,字只差空白和占位行。手动选定留痕
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
		lyrics := normalizeLyricText(e.Lyrics.String())
		tr := normalizeLyricText(e.LyricsTr.String())
		roma := normalizeLyricText(e.LyricsRoma.String())
		yrc := normalizeLyricText(e.LyricsYRC.String())
		plain := normalizeLyricText(e.PlainLyrics.String())
		bg := normalizeLyricText(e.LyricsBG.String())
		if e.Lyrics.EqualString(lyrics) && e.LyricsTr.EqualString(tr) && e.LyricsRoma.EqualString(roma) && e.LyricsYRC.EqualString(yrc) && e.PlainLyrics.EqualString(plain) &&
			e.LyricsBG.EqualString(bg) {
			continue
		}
		if e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(e.Lyrics.String()) {
			e.ManualPickSHA = manualPickFingerprint(lyrics)
		}
		e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics, e.LyricsBG = bt(lyrics), bt(tr), bt(roma), bt(yrc), bt(plain), bt(bg)
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
