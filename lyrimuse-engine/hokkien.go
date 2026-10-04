package main

import (
	"log"
	"regexp"
	"strings"
	"unicode"
)

// 台语(闽南语)歌:不标普通话拼音。
//
// 汉字歌词的罗马音只有两套:粤语歌出粤拼(jyutping.go),其余一律当普通话出拼音。台语歌按普通话拼音读是错的
// (「袂」台语读 bē,拼音标成 mèi;「毋」读 m̄,标成 wú),而台罗拼音要一份带文白异读的台语词典,没有接。
// 所以认出是台语歌之后,汉字行干脆不标:引擎不生成拼音、歌词源自带的(给台语歌的只会是普通话拼音)也不留,
// App 侧看到 SongLanguage == songLanguageHokkien 也不现算(Romanizer / LyricsSyncEngine 的 songIsHokkien)。
// 夹在歌里的日文、韩文行不受影响。见 10 章决策 24。
//
// songLanguageHokkien 的取值 Swift 侧 EnrichCacheReader.swift 有一份同名常量,两边必须一致(hokkien_test.go 钉着)。
const songLanguageHokkien = "nan"

// hokkienMarkers:台语书写里的特有字 / 词,普通话歌词里几乎不用。简体转写之后「攏」「閣」会变成「拢」「阁」,两种都认。
// 「欲」「咧」「予」「遮」「較」「嘛」这类普通话 / 日文 / 粤语里也常见的字不收:单看它们,日文歌(欲しい)和
// 普通话歌(干嘛)会被成片误判。
var hokkienMarkers = []string{"阮", "袂", "毋", "佇", "恁", "𪜶", "佮", "攏", "拢", "厝", "遐", "閣", "阁", "按怎", "啥物"}

// hokkienSharedMarkers:hokkienMarkers 里普通话歌词偶尔也会用到的几个(楼阁、靠拢、遐想)。靠「两种特征」判定时,
// 至少要有一种不在这里 —— 否则一首普通话歌里「楼阁」「靠拢」各出现一次就会被判成台语。
var hokkienSharedMarkers = map[string]bool{"攏": true, "拢": true, "閣": true, "阁": true, "厝": true, "遐": true}

// hokkienSoloMarkers:单独出现就够说明问题的那几个 —— 任何一个出现 hokkienSoloMinCount 次以上也算台语歌
// (「阮」「拢」「按怎」是不少台语歌里仅有的特有字,只要求两种特征会漏掉它们)。
// 「厝」「阁」「遐」不在里面:普通话歌词里偶尔也用。
var hokkienSoloMarkers = []string{"阮", "袂", "毋", "按怎", "恁", "𪜶", "攏", "拢"}

const (
	hokkienMinKinds     = 2  // 至少这么多种特征字 / 词
	hokkienSoloMinCount = 3  // 或者 hokkienSoloMarkers 里任何一个出现这么多次
	hokkienMinHan       = 60 // 正文汉字少于这么多不判(样本太小)
	hokkienMaxKana      = 5  // 假名到这么多就是日文歌,不判
	hokkienMaxCantonese = 3  // 粤语特有字到这么多就是粤语歌,不判
)

var (
	lrcTagRe        = regexp.MustCompile(`\[[^\]]*\]`)
	cantoneseMarker = []rune("嘅咗唔冇啲喺嚟佢睇嘢咁")
)

// lyricsLookHokkien:这份歌词是不是台语歌。判据与阈值是拿本机 4371 首汉字歌词的缓存标定的,见 10 章决策 24。
// 只看正文:时间戳标签和带冒号的署名行(作词:/ 编曲:)去掉。
func lyricsLookHokkien(lyrics string) bool {
	var body strings.Builder
	for _, line := range strings.Split(lrcTagRe.ReplaceAllString(lyrics, ""), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.ContainsAny(line, ":：") {
			continue
		}
		body.WriteString(line)
	}
	text := body.String()
	han, kana, canto := 0, 0, 0
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case unicode.In(r, unicode.Hiragana, unicode.Katakana):
			kana++
		}
	}
	for _, r := range cantoneseMarker {
		canto += strings.Count(text, string(r))
	}
	if han < hokkienMinHan || kana >= hokkienMaxKana || canto >= hokkienMaxCantonese {
		return false
	}
	kinds, anchored := 0, false
	for _, m := range hokkienMarkers {
		if strings.Contains(text, m) {
			kinds++
			anchored = anchored || !hokkienSharedMarkers[m]
		}
	}
	if kinds >= hokkienMinKinds && anchored {
		return true
	}
	for _, m := range hokkienSoloMarkers {
		if strings.Count(text, m) >= hokkienSoloMinCount {
			return true
		}
	}
	return false
}

// entrySongLanguage:条目的 SongLanguage。源上报了粤语就是粤语;否则歌词像台语就记台语(源上报的「普通话」
// 压不过它:平台常把台语歌标成国语);再否则照源上报的。
func entrySongLanguage(lyrics string, scored []scoredLyricCandidateResult) string {
	lang := songLanguageFromScored(scored)
	if lang != songLanguageCantonese && lyricsLookHokkien(lyrics) {
		return songLanguageHokkien
	}
	return lang
}

// dropHokkienRoma:台语歌不留罗马音(理由见文件头)。用户手改过的歌词不动。
func (e *enrichEntry) dropHokkienRoma() {
	if e.SongLanguage == songLanguageHokkien && !e.lyricsHandEdited() {
		e.LyricsRoma = ""
	}
}

// migrateHokkienSongLanguage:存量条目补记台语、清掉已经生成的普通话拼音。运行期在源头已经这样做
// (entrySongLanguage / dropHokkienRoma / shouldGenerateHelperRoma),所以是一次性的,挂水位闸。
// 位置(main.go):import 与 export 之间 —— 清掉的罗马音由 exportLyricsFiles 同步成删掉对应的 .roma.lrc。
func migrateHokkienSongLanguage() {
	scope := migrationScopeOf(migrationHokkienSongLanguage, migrationHokkienSongLanguageVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	marked, cleared := 0, 0
	for k, e := range scope.entries() {
		if e.Lyrics == "" || e.SongLanguage == songLanguageCantonese || e.SongLanguage == songLanguageHokkien ||
			!lyricsLookHokkien(e.Lyrics) {
			continue
		}
		e.SongLanguage = songLanguageHokkien
		if e.LyricsRoma != "" && !e.lyricsHandEdited() {
			cleared++
		}
		e.dropHokkienRoma()
		enrichCache[k] = e
		marked++
	}
	if marked > 0 {
		enrichDirty = true // 同 migrateQRCLeftoverTokens:不置脏 saveEnrichCache 不写盘
	}
	enrichMu.Unlock()
	if marked > 0 {
		log.Printf("hokkien song language: marked %d entries, cleared romanization on %d", marked, cleared)
		saveEnrichCache()
	}
	markMigrationDone(migrationHokkienSongLanguage, migrationHokkienSongLanguageVersion)
}
