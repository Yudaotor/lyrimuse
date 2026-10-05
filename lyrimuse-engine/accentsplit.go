package main

import (
	"log"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// 重音字母旁多切的空格:`groß en`(großen)、`mirá ndote`(mirándote),也有切在重音字母前面的:
// `derni ère`(dernière)。整行文字和逐字词条都可能这样切,也有只坏了逐字的。
//
// 删一处空格的唯一依据:去掉它之后跨过它的那个词,在证据词表里出现过。别改成按字形或词典判断,
// 见 09 章决策 178。证据分两级:
//
//  1. 同一首歌的整行与逐字文字:这一轮的全部候选(纯文本候选也算),存量条目则是它自己;
//  2. 缓存里全部条目的整行歌词(refreshAccentCacheWords),整行与逐字各自在 accentInsideWord 为假时才用。
//
// 只删空格:词条不合并、时间不动,整行文字与逐字数据按同一个判据各删各的。只看拉丁字母之间的空格。

// isAccentLetter:lyricLatinLetter 那张表里非 ASCII 的部分。
func isAccentLetter(r rune) bool {
	return r >= 0xC0 && lyricLatinLetter(r)
}

// mayContainAccentLetter:按 UTF-8 首字节粗筛有没有重音字母(U+00C0–U+024F 的首字节是 0xC3–0xC9,
// U+1E00–U+1EFF 是 0xE1 0xB8–0xBB)。为假就一定没有;为真再逐字看。
func mayContainAccentLetter(s string) bool {
	for i := 0; i < len(s); i++ {
		b := s[i]
		if b >= 0xC3 && b <= 0xC9 {
			return true
		}
		if b == 0xE1 && i+1 < len(s) && s[i+1] >= 0xB8 && s[i+1] <= 0xBB {
			return true
		}
	}
	return false
}

// accentSplitPoint:相邻两个空格分隔片段之间是不是可能多切的位置 —— 紧挨空格的两边都是拉丁字母,
// 至少一边是重音字母。
func accentSplitPoint(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	la, _ := utf8.DecodeLastRuneInString(a)
	fb, _ := utf8.DecodeRuneInString(b)
	return lyricLatinLetter(la) && lyricLatinLetter(fb) && (isAccentLetter(la) || isAccentLetter(fb))
}

func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.Is(unicode.Mn, r)
}

// trailingLetters / leadingLetters:片段末尾 / 开头的连续字母(含组合附加符号)。
func trailingLetters(s string) string {
	i := len(s)
	for i > 0 {
		r, n := utf8.DecodeLastRuneInString(s[:i])
		if !isWordRune(r) {
			break
		}
		i -= n
	}
	return s[i:]
}

func leadingLetters(s string) string {
	i := 0
	for i < len(s) {
		r, n := utf8.DecodeRuneInString(s[i:])
		if !isWordRune(r) {
			break
		}
		i += n
	}
	return s[:i]
}

// accentWordKey:证据词表与拼出的词共用的比对形式。strings.ToLower 保留 ß,别换成大小写折叠
// (折叠把 ß 变成 ss)。
func accentWordKey(s string) string {
	return strings.ToLower(composeNFC(s))
}

// accentSplitJoined:toks 之间的空格全删掉之后跨过它们的那个词。中间的片段必须整段是字母。
func accentSplitJoined(toks []string) (string, bool) {
	var b strings.Builder
	b.WriteString(trailingLetters(toks[0]))
	for _, t := range toks[1 : len(toks)-1] {
		if t == "" || leadingLetters(t) != t {
			return "", false
		}
		b.WriteString(t)
	}
	b.WriteString(leadingLetters(toks[len(toks)-1]))
	return accentWordKey(b.String()), true
}

// accentWordSet:含重音字母的词,accentWordKey 形式。
type accentWordSet map[string]struct{}

// addText 收下一份歌词(LRC 或纯文本)里含重音字母的词。词 = 连续字母,撇号、连字符等处断开。
func (s accentWordSet) addText(text string) {
	if !mayContainAccentLetter(text) {
		return
	}
	for _, line := range strings.Split(text, "\n") {
		if isLRCMetaTagLine(line) {
			continue
		}
		start := -1
		for i, r := range line {
			if isWordRune(r) {
				if start < 0 {
					start = i
				}
				continue
			}
			if start >= 0 {
				s.addWord(line[start:i])
				start = -1
			}
		}
		if start >= 0 {
			s.addWord(line[start:])
		}
	}
}

func (s accentWordSet) addWord(w string) {
	k := accentWordKey(w)
	if strings.IndexFunc(k, isAccentLetter) >= 0 {
		s[k] = struct{}{}
	}
}

// addYRC 收下逐字数据里各词条文字拼成的句子中含重音字母的词。
func (s accentWordSet) addYRC(yrc string) {
	if mayContainAccentLetter(yrc) {
		s.addText(yrcPlainLines(yrc))
	}
}

func (s accentWordSet) has(w string) bool {
	_, ok := s[w]
	return ok
}

// accentInsideWord:有没有重音字母紧跟着 ASCII 字母(`für`、`dernière`)。为假的文本才用第二级证据。
// 逐字数据看 yrcAccentInsideWord。
func accentInsideWord(text string) bool {
	if !mayContainAccentLetter(text) {
		return false
	}
	prevAccent := false
	for _, r := range text {
		if prevAccent && isASCIILetter(r) {
			return true
		}
		prevAccent = isAccentLetter(r)
	}
	return false
}

// yrcAccentInsideWord:逐字数据里各词条文字拼成的句子的 accentInsideWord。
func yrcAccentInsideWord(yrc string) bool {
	return mayContainAccentLetter(yrc) && accentInsideWord(yrcPlainLines(yrc))
}

// hasAccentSplitPoint:文本里有没有 accentSplitPoint 那样的位置(一个空格两边紧挨着拉丁字母,至少一边是重音字母)。
func hasAccentSplitPoint(s string) bool {
	if !mayContainAccentLetter(s) {
		return false
	}
	for i := 1; i+1 < len(s); i++ {
		if s[i] != ' ' {
			continue
		}
		l, _ := utf8.DecodeLastRuneInString(s[:i])
		r, _ := utf8.DecodeRuneInString(s[i+1:])
		if lyricLatinLetter(l) && lyricLatinLetter(r) && (isAccentLetter(l) || isAccentLetter(r)) {
			return true
		}
	}
	return false
}

// accentSplitDrops:一行文字里该删的空格,字节下标、升序。连着的几个可能多切的位置当一串,先试拼得最长的。
func accentSplitDrops(line string, attested func(string) bool) []int {
	if !mayContainAccentLetter(line) {
		return nil
	}
	toks := strings.Split(line, " ")
	starts := make([]int, len(toks))
	pos := 0
	for i, t := range toks {
		starts[i] = pos
		pos += len(t) + 1
	}
	var drops []int
	for i := 0; i+1 < len(toks); {
		if !accentSplitPoint(toks[i], toks[i+1]) {
			i++
			continue
		}
		j := i + 1
		for j+1 < len(toks) && accentSplitPoint(toks[j], toks[j+1]) {
			j++
		}
		hit := -1
		for k := j; k > i; k-- {
			if w, ok := accentSplitJoined(toks[i : k+1]); ok && attested(w) {
				hit = k
				break
			}
		}
		if hit < 0 {
			i++
			continue
		}
		for m := i; m < hit; m++ {
			drops = append(drops, starts[m]+len(toks[m]))
		}
		i = hit + 1
	}
	return drops
}

// deleteBytesAt:去掉 s 里这些下标(升序)上的单字节。
func deleteBytesAt(s string, idx []int) string {
	var b strings.Builder
	b.Grow(len(s) - len(idx))
	prev := 0
	for _, i := range idx {
		b.WriteString(s[prev:i])
		prev = i + 1
	}
	b.WriteString(s[prev:])
	return b.String()
}

// repairAccentSplitLRC:整行歌词(LRC 或纯文本)里删掉证实过的多余空格。返回修好的文本与是否改过。
func repairAccentSplitLRC(lrc string, attested func(string) bool) (string, bool) {
	if !mayContainAccentLetter(lrc) {
		return lrc, false
	}
	lines := strings.Split(lrc, "\n")
	changed := false
	for i, line := range lines {
		if isLRCMetaTagLine(line) {
			continue
		}
		if drops := accentSplitDrops(line, attested); len(drops) > 0 {
			lines[i] = deleteBytesAt(line, drops)
			changed = true
		}
	}
	if !changed {
		return lrc, false
	}
	return strings.Join(lines, "\n"), true
}

// repairAccentSplitYRC:逐字数据里删掉证实过的多余空格。一行的文字 = 各词条文字依次拼起来,删的是落在某个
// 词条文字里的那个空格;那个词条的文字只有这一个空格时不删(纯空白词条归 yrcMergeWhitespaceTokens)。
func repairAccentSplitYRC(yrc string, attested func(string) bool) (string, bool) {
	if !mayContainAccentLetter(yrc) {
		return yrc, false
	}
	lines := strings.Split(yrc, "\n")
	changed := false
	for li, line := range lines {
		if !strings.HasPrefix(line, "[") {
			continue
		}
		locs := yrcWordTokenRe.FindAllStringIndex(line, -1)
		if len(locs) == 0 {
			continue
		}
		var text strings.Builder
		inLine := make([]int, len(locs)) // 词条文字在 line 里的起点
		inText := make([]int, len(locs)) // 词条文字在拼起来的文字里的起点
		size := make([]int, len(locs))
		for i, m := range locs {
			end := len(line)
			if i+1 < len(locs) {
				end = locs[i+1][0]
			}
			inLine[i], inText[i], size[i] = m[1], text.Len(), end-m[1]
			text.WriteString(line[m[1]:end])
		}
		var at []int
		k := 0
		for _, d := range accentSplitDrops(text.String(), attested) {
			for k+1 < len(locs) && inText[k+1] <= d {
				k++
			}
			if size[k] > 1 {
				at = append(at, inLine[k]+d-inText[k])
			}
		}
		if len(at) == 0 {
			continue
		}
		lines[li] = deleteBytesAt(line, at)
		changed = true
	}
	if !changed {
		return yrc, false
	}
	return strings.Join(lines, "\n"), true
}

// accentAttested:先查 own;useCached 时再查第二级证据词表 cached。
func accentAttested(own, cached accentWordSet, useCached bool) func(string) bool {
	if !useCached || len(cached) == 0 {
		return own.has
	}
	return func(w string) bool { return own.has(w) || cached.has(w) }
}

// repairCandidateAccentSplits 就地修一批候选的整行歌词与逐字数据。第一级证据是整批候选的整行与逐字文字。
//
// 调用时机(enrich.go):候选装配完、打分之前,rankLyricSourceResults 与 mergeLyricCandidateRounds 都调 ——
// 后一轮到的源可能正好带来证据。
func repairCandidateAccentSplits(candidates []lyricCandidate) {
	inRound := accentWordSet{}
	for _, c := range candidates {
		inRound.addText(c.lyrics)
		inRound.addYRC(c.wordTimingYRC)
	}
	if len(inRound) == 0 {
		return
	}
	cached := currentAccentCacheWords()
	for i := range candidates {
		c := &candidates[i]
		if fixed, ok := repairAccentSplitLRC(c.lyrics, accentAttested(inRound, cached, !accentInsideWord(c.lyrics))); ok {
			c.lyrics = fixed
		}
		if fixed, ok := repairAccentSplitYRC(c.wordTimingYRC, accentAttested(inRound, cached, !yrcAccentInsideWord(c.wordTimingYRC))); ok {
			c.wordTimingYRC = fixed
		}
	}
}

var (
	accentCacheWordsMu sync.Mutex
	accentCacheWords   accentWordSet
)

// refreshAccentCacheWords 按 enrichCache 里全部条目的整行歌词重建第二级证据词表。调用方不能持有 enrichMu。
// 常驻引擎在 migrateAccentSplits 里建,search-lyrics 在只读加载缓存之后建,运行期不增量更新。
func refreshAccentCacheWords() {
	set := accentWordSet{}
	enrichMu.Lock()
	for _, e := range enrichCache {
		set.addText(e.Lyrics)
	}
	enrichMu.Unlock()
	accentCacheWordsMu.Lock()
	accentCacheWords = set
	accentCacheWordsMu.Unlock()
}

// currentAccentCacheWords:第二级证据词表,没建过时为空。只整份替换、不原地改,拿到的那份不加锁也能查。
func currentAccentCacheWords() accentWordSet {
	accentCacheWordsMu.Lock()
	defer accentCacheWordsMu.Unlock()
	return accentCacheWords
}

// migrateAccentSplits 把存量条目修一遍。证据是这条自己的整行与逐字文字,加上第二级证据词表;手改过的条目不碰。
// 对唱标注按行记,删空格不改行的结构:原先对得上正文的,指纹跟着换成新正文的。
//
// 位置(main.go):importLyricsFromFiles 之后、exportLyricsFiles 与 migrateManualPickMarks 之前,必须排在
// migrateYRCWhitespaceTokens 之后 —— 纯空白词条先并进前一个词,repairAccentSplitYRC 才删得到那个空格。
// 不加水位:真正逐行走一遍的只有带重音字母的条目;词表跟着缓存长,下次启动能证实的更多。
func migrateAccentSplits() {
	refreshAccentCacheWords()
	cached := currentAccentCacheWords()
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		if e.ManualLyrics {
			continue
		}
		yrcText := ""
		if mayContainAccentLetter(e.LyricsYRC) {
			yrcText = yrcPlainLines(e.LyricsYRC)
		}
		if !hasAccentSplitPoint(e.Lyrics) && !hasAccentSplitPoint(yrcText) {
			continue
		}
		own := accentWordSet{}
		own.addText(e.Lyrics)
		own.addText(yrcText)
		lrc, lrcChanged := repairAccentSplitLRC(e.Lyrics, accentAttested(own, cached, !accentInsideWord(e.Lyrics)))
		yrc, yrcChanged := repairAccentSplitYRC(e.LyricsYRC, accentAttested(own, cached, !accentInsideWord(yrcText)))
		if !lrcChanged && !yrcChanged {
			continue
		}
		if sp := e.LyricsSpeakers; sp != nil && sp.For == lyricSpeakersFingerprint(e.Lyrics, e.LyricsYRC) {
			moved := *sp
			moved.For = lyricSpeakersFingerprint(lrc, yrc)
			e.LyricsSpeakers = &moved
		}
		e.Lyrics, e.LyricsYRC = lrc, yrc
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		enrichDirty = true // 同 migrateKRCNegativeOffsets:不置脏 saveEnrichCache 不写盘
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("accent split repair: fixed %d entries", fixed)
		saveEnrichCache()
	}
}
