package main

import (
	"log"
	"regexp"
	"strings"
	"unicode"
)

// 歌词本身是粤语口语的歌记成粤语歌。
//
// 粤语歌的语种平常只有 QQ、酷狗上报。粤语流行歌大多按书面语写,单看歌词认不出;但满篇粤语口语字
// (嘅、咗、唔、佢……)的,一定是粤语:独白、对白、口语写的歌。平台常把这种标成国语,照源报的会标成普通话拼音。
// 只往粤语这一边判:口语字少说明不了什么,不据此改成别的语种。见 10 章决策 55。

const (
	cantoneseMinHanLines  = 8   // 含汉字的正文行少于这么多不判(样本太小)
	cantoneseMinLineShare = 0.5 // 含汉字的正文行里,带粤语口语字的至少占这么多
	cantoneseMaxKana      = 5   // 假名到这么多就是日文歌,不判
)

// lyricsBodyLines:正文行。时间戳标签和带冒号的署名行(作词:/ 编曲:)去掉,空行不要。
func lyricsBodyLines(lyrics string) []string {
	var out []string
	for _, line := range strings.Split(lrcTagRe.ReplaceAllString(lyrics, ""), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.ContainsAny(line, ":：") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// lyricsLookCantonese:这份歌词是不是粤语口语写的。阈值的标定见 10 章决策 55。
func lyricsLookCantonese(lyrics string) bool {
	hanLines, marked, kana := 0, 0, 0
	for _, line := range lyricsBodyLines(lyrics) {
		hasHan := false
		for _, r := range line {
			switch {
			case unicode.Is(unicode.Han, r):
				hasHan = true
			case unicode.In(r, unicode.Hiragana, unicode.Katakana):
				kana++
			}
		}
		if !hasHan {
			continue
		}
		hanLines++
		if strings.ContainsAny(line, string(cantoneseMarker)) {
			marked++
		}
	}
	if hanLines < cantoneseMinHanLines || kana >= cantoneseMaxKana {
		return false
	}
	return float64(marked) >= float64(hanLines)*cantoneseMinLineShare
}

// 读音是粤拼的歌记成粤语歌。
//
// Apple Music 这类不报语种的源,粤语歌给的读音就是粤拼。粤语段是书面语、整首又夹着英文的,口语字判不出来,
// 记不成粤语,App 就按普通话那一档管它的读音。粤拼有几种拼法普通话拼音里从来没有:收 -p/-t/-k、带 eo/oe/aa、
// 声母 gw/kw/ng、j 后面跟 a/e/o/y。只数正文里整行是汉字的那几行对着的读音(英文行、日文行、阿拉伯文行的
// 读音会混进这些拼法)。阈值的标定见 10 章决策 73。
const (
	jyutpingRomaMinSyllables = 8    // 汉字行的读音音节少于这么多不判
	jyutpingRomaMinShare     = 0.25 // 其中粤拼才有的拼法至少占这么多
)

// speakerPrefixRe:对唱署名前缀(「v1：」「合：」),去掉再看这行是不是整行汉字。
var speakerPrefixRe = regexp.MustCompile(`^[^\s:：]{1,12}[:：]\s*`)

// jyutpingOnlySyllable:这个音节(去掉声调数字)的拼法只有粤拼有,普通话拼音没有。
func jyutpingOnlySyllable(s string) bool {
	s = strings.TrimRight(s, "123456")
	if len(s) < 2 {
		return false
	}
	switch s[len(s)-1] {
	case 'p', 't', 'k':
		return true
	}
	return strings.Contains(s, "eo") || strings.Contains(s, "oe") || strings.Contains(s, "aa") ||
		strings.HasPrefix(s, "gw") || strings.HasPrefix(s, "kw") || strings.HasPrefix(s, "ng") ||
		(s[0] == 'j' && strings.ContainsRune("aeoy", rune(s[1])))
}

// romaLooksJyutping:源自带的读音在整行汉字的正文行上是粤拼。读音行按时间标签跟正文行对上。
func romaLooksJyutping(lyrics, roma string) bool {
	if roma == "" || lyrics == "" {
		return false
	}
	romaByTag := map[string]string{}
	for _, l := range parseLRCLines(roma) {
		romaByTag[l.tag] = l.text
	}
	var syllables []string
	kana := 0
	for _, l := range parseLRCLines(lyrics) {
		body := speakerPrefixRe.ReplaceAllString(l.text, "")
		letters, han := 0, 0
		for _, r := range body {
			if unicode.In(r, unicode.Hiragana, unicode.Katakana) {
				kana++
			}
			if unicode.IsLetter(r) {
				letters++
				if unicode.Is(unicode.Han, r) {
					han++
				}
			}
		}
		r, ok := romaByTag[l.tag]
		if !ok || han < 2 || han != letters {
			continue
		}
		for _, f := range strings.Fields(strings.ToLower(r)) {
			if f = strings.Trim(f, ",.!?;:'\"()"); f != "" && unicode.IsLetter(rune(f[0])) {
				syllables = append(syllables, f)
			}
		}
	}
	if kana >= cantoneseMaxKana || len(syllables) < jyutpingRomaMinSyllables {
		return false
	}
	if looksMandarinPinyin(strings.Join(syllables, " ")) {
		return false
	}
	only := 0
	for _, s := range syllables {
		if jyutpingOnlySyllable(s) {
			only++
		}
	}
	return float64(only) >= float64(len(syllables))*jyutpingRomaMinShare
}

// migrateCantoneseSongLanguage:存量里歌词是粤语口语、或者读音是粤拼(romaLooksJyutping),却没记成粤语的歌补记粤语,普通话拼音换成粤拼。运行期在源头
// 已经这样做(entrySongLanguage),所以是一次性的,挂水位闸。读音的清和补跟运行期同一套:dropUnusableCantoneseRoma
// 只清普通话拼音和没标声调的(用户手改过的不动),maybeGenerateJyutpingRoma 只在空着时补。
// 位置(main.go):import 与 export 之间 —— 换掉的罗马音由 exportLyricsFiles 同步成新的 .roma.lrc。
func migrateCantoneseSongLanguage() {
	scope := migrationScopeOf(migrationCantoneseSongLanguage, migrationCantoneseSongLanguageVersion)
	if scope.skip() {
		return
	}
	enrichMu.Lock()
	marked := 0
	for k, e := range scope.entries() {
		if e.Lyrics.IsZero() || e.SongLanguage == songLanguageCantonese ||
			!(lyricsLookCantonese(e.Lyrics.String()) || romaLooksJyutping(e.Lyrics.String(), e.LyricsRoma.String())) {
			continue
		}
		e.SongLanguage = songLanguageCantonese
		e.dropUnusableCantoneseRoma()
		e.maybeGenerateJyutpingRoma()
		enrichCache[k] = e
		marked++
	}
	if marked > 0 {
		enrichDirty = true // 同 migrateHokkienSongLanguage:不置脏 saveEnrichCache 不写盘
	}
	enrichMu.Unlock()
	if marked > 0 {
		log.Printf("cantonese song language: marked %d entries", marked)
		saveEnrichCache()
	}
	markMigrationDone(migrationCantoneseSongLanguage, migrationCantoneseSongLanguageVersion)
}
