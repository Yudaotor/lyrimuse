package main

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// 歌词里的屏蔽词:几家源把脏话和平台屏蔽词换成星号(词中打码「f**k」、整词「*****」、中文屏蔽词「**」),同一轮里
// 别的源常给着原词。补词只换文字:按行对齐,星号那几个字换成别的候选同一行里的原词,逐字时间不动,分数不变。见 09 章决策 317。

// lyricMaskRunRe:一段星号。单个「*」不算(歌词里有当装饰、当乘号用的)。
var lyricMaskRunRe = regexp.MustCompile(`\*{2,}`)

// lyricMaskFill:一段星号能换成的原词。不含空白和星号,最多 24 个字。
const lyricMaskFill = `([^\s*]{1,24}?)`

// lyricMaskMinContextRunes:一行去掉星号之后至少要剩这么多字才补。整行只有「*****」、或只剩一两个字时,能对上的原词太多。
const lyricMaskMinContextRunes = 3

// lyricUnmaskOrig:补词之前的原文,只记改过的那几份(空串 = 这一份没改)。
type lyricUnmaskOrig struct {
	lyrics, yrc, tr, roma string
}

// hasLyricMask:文本里有没有一段星号。
func hasLyricMask(s string) bool {
	return strings.Contains(s, "**") && lyricMaskRunRe.MatchString(s)
}

// yrcHasLyricMask:逐字歌词去掉词条时间之后有没有一段星号(每个星号单独计时的,原文里星号中间隔着时间)。
func yrcHasLyricMask(yrc string) bool {
	return strings.Contains(yrc, "*") && hasLyricMask(yrcWordTokenRe.ReplaceAllString(yrc, ""))
}

// lyricMaskPunctRe:对行时不算的标点,换成空格再比(别家同一行常多带逗号、问号、引号括号)。
var lyricMaskPunctRe = regexp.MustCompile(`[,.!?;:"“”„«»()\[\]{}（）【】「」『』、，。！？；：…]+`)

func normMaskLine(s string) string {
	return collapseLyricSpace(lyricMaskPunctRe.ReplaceAllString(s, " "))
}

// lyricMaskMaxGapMs:donor 那一行跟打码这一行的时间最多差这么多。几家的时间轴常差一两秒;放得更宽,所有源都打码时
// 会拿同一首里别处一句同形的歌词来填。
const lyricMaskMaxGapMs = 3000

// lyricMaskMinLooseContextRunes:按「是别家那一行中间的一段」对时,上下文至少要这么多字(不算空格)。
const lyricMaskMinLooseContextRunes = 8

// lyricMaskMatcher:masked 这一行的几档对法,依次放宽:整行一致;是别家那一行的开头(别家把两行并成了一行);
// 是别家那一行中间从词边界起的一段(上下文够长才用)。都不分大小写、不算标点、连续空白算一个,每段星号是一个捕获组。
type lyricMaskMatcher struct {
	tiers []*regexp.Regexp
}

// newLyricMaskMatcher:上下文不够(lyricMaskMinContextRunes)或没有星号时返回 nil。
func newLyricMaskMatcher(masked string) *lyricMaskMatcher {
	parts := lyricMaskRunRe.Split(normMaskLine(masked), -1)
	if len(parts) < 2 {
		return nil
	}
	context := 0
	for _, p := range parts {
		context += utf8.RuneCountInString(strings.ReplaceAll(p, " ", ""))
	}
	if context < lyricMaskMinContextRunes {
		return nil
	}
	// 不锚行尾时,行尾那段星号的原词要吃到词尾,不能停在第一个字。
	build := func(head, tail string) *regexp.Regexp {
		var b strings.Builder
		b.WriteString("(?i)" + head)
		for i, p := range parts {
			if i > 0 {
				if tail == "" && i == len(parts)-1 && p == "" {
					b.WriteString(`([^\s*]{1,24})`)
				} else {
					b.WriteString(lyricMaskFill)
				}
			}
			b.WriteString(regexp.QuoteMeta(p))
		}
		b.WriteString(tail)
		return regexp.MustCompile(b.String())
	}
	m := &lyricMaskMatcher{tiers: []*regexp.Regexp{build("^", "$"), build("^", "")}}
	if context >= lyricMaskMinLooseContextRunes {
		m.tiers = append(m.tiers, build(`(?:^|\s)`, ""))
	}
	return m
}

// match:donor 这一行按哪一档对上了、各段星号的原词。对不上 tier 为 -1。
func (m *lyricMaskMatcher) match(donor string) (fills []string, tier int) {
	d := normMaskLine(donor)
	for t, re := range m.tiers {
		if g := re.FindStringSubmatch(d); g != nil {
			return g[1:], t
		}
	}
	return nil, -1
}

func collapseLyricSpace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// fillLyricMasks:把 masked 里的每段星号依次换成 fills。段数对不上原样返回。
func fillLyricMasks(masked string, fills []string) (string, bool) {
	if len(lyricMaskRunRe.FindAllStringIndex(masked, -1)) != len(fills) {
		return masked, false
	}
	i := 0
	return lyricMaskRunRe.ReplaceAllStringFunc(masked, func(string) string {
		i++
		return fills[i-1]
	}), true
}

// unmaskLine 一行带时间的文本:at 是这一行的时间(毫秒),text 是去掉行首时间标签之后的正文。
type unmaskLine struct {
	at   int
	text string
}

// lrcTimedLines:LRC 里带时间标签的行(行首几个时间标签取第一个)。
func lrcTimedLines(lrc string) []unmaskLine {
	var out []unmaskLine
	for _, raw := range strings.Split(lrc, "\n") {
		raw = strings.TrimRight(raw, "\r")
		m := lrcLinePattern.FindStringSubmatch(raw)
		if m == nil {
			continue
		}
		stamp := lrcTimestampCaptureRe.FindStringSubmatch(m[1])
		if stamp == nil {
			continue
		}
		if text := strings.TrimSpace(m[2]); text != "" {
			out = append(out, unmaskLine{at: lrcStampMs(stamp), text: text})
		}
	}
	return out
}

// lyricMaskFillsNear:masked 这一行在 donors 里能对上的那一行给出的原词:只看时间相差 lyricMaskMaxGapMs 以内的行,
// 先比对法的档(越严越好),同档取时间最近的。
// donor 自己打码的那一段对不上(原词不收星号)。
func lyricMaskFillsNear(masked string, at int, donors []unmaskLine) []string {
	m := newLyricMaskMatcher(masked)
	if m == nil {
		return nil
	}
	var best []string
	bestTier, bestGap := -1, 0
	for _, d := range donors {
		gap := d.at - at
		if gap < 0 {
			gap = -gap
		}
		if gap > lyricMaskMaxGapMs {
			continue
		}
		fills, tier := m.match(d.text)
		if tier < 0 {
			continue
		}
		if bestTier < 0 || tier < bestTier || tier == bestTier && gap < bestGap {
			best, bestTier, bestGap = fills, tier, gap
		}
	}
	return best
}

// unmaskLRC:LRC 里带星号的行按 donors 补词。filled 按这一行的时间记下补进去的原词,给罗马音照着补(unmaskRomaASCII)。
func unmaskLRC(lrc string, donors []unmaskLine) (out string, filled map[int][]string) {
	if !hasLyricMask(lrc) {
		return lrc, nil
	}
	lines := strings.Split(lrc, "\n")
	for i, raw := range lines {
		if !hasLyricMask(raw) {
			continue
		}
		cr := strings.HasSuffix(raw, "\r")
		m := lrcLinePattern.FindStringSubmatch(strings.TrimRight(raw, "\r"))
		if m == nil {
			continue
		}
		stamp := lrcTimestampCaptureRe.FindStringSubmatch(m[1])
		text := strings.TrimSpace(m[2])
		if stamp == nil || !hasLyricMask(text) {
			continue
		}
		at := lrcStampMs(stamp)
		fills := lyricMaskFillsNear(text, at, donors)
		if fills == nil {
			continue
		}
		fixed, ok := fillLyricMasks(m[2], fills)
		if !ok {
			continue
		}
		lines[i] = m[1] + fixed
		if cr {
			lines[i] += "\r"
		}
		if filled == nil {
			filled = map[int][]string{}
		}
		filled[at] = fills
	}
	if filled == nil {
		return lrc, nil
	}
	return strings.Join(lines, "\n"), filled
}

// unmaskYRC:逐字歌词里带星号的行按 donors 补词。每段星号落在一个词条里就只换那个词条的字;落在连着的几个词条里
// (逐字给每个星号单独计时)就并成一个词条,起点取第一个、终点取最后一个,文字换成原词。别的词条的时间一个都不动。
// 跨词条时这几个词条里只能有星号(末一个词条后面可以跟空白),跟别的字混在一起就整行不补:并进来的字会丢掉自己的时间。
func unmaskYRC(yrc string, donors []unmaskLine) string {
	if !yrcHasLyricMask(yrc) {
		return yrc
	}
	lines := strings.Split(yrc, "\n")
	changed := false
	for li, line := range lines {
		if !strings.HasPrefix(line, "[") || !yrcHasLyricMask(line) {
			continue
		}
		if fixed, ok := unmaskYRCLine(line, donors); ok {
			lines[li] = fixed
			changed = true
		}
	}
	if !changed {
		return yrc
	}
	return strings.Join(lines, "\n")
}

type yrcUnmaskToken struct {
	start, dur int64
	flag, text string
}

func unmaskYRCLine(line string, donors []unmaskLine) (string, bool) {
	locs := yrcWordTokenRe.FindAllStringSubmatchIndex(line, -1)
	if len(locs) == 0 {
		return line, false
	}
	head := line[:locs[0][0]]
	lineStart := 0
	if h := yrcLineHeadRe.FindStringSubmatch(head); h != nil {
		lineStart, _ = strconv.Atoi(h[1])
	}
	toks := make([]yrcUnmaskToken, 0, len(locs))
	var plain strings.Builder
	offsets := make([]int, 0, len(locs)) // 每个词条的字在 plain 里的起点
	for i, m := range locs {
		start, _ := strconv.ParseInt(line[m[2]:m[3]], 10, 64)
		dur, _ := strconv.ParseInt(line[m[4]:m[5]], 10, 64)
		end := len(line)
		if i+1 < len(locs) {
			end = locs[i+1][0]
		}
		t := yrcUnmaskToken{start, dur, line[m[6]:m[7]], line[m[1]:end]}
		offsets = append(offsets, plain.Len())
		plain.WriteString(t.text)
		toks = append(toks, t)
	}
	text := plain.String()
	fills := lyricMaskFillsNear(strings.TrimSpace(text), lineStart, donors)
	runs := lyricMaskRunRe.FindAllStringIndex(text, -1)
	if fills == nil || len(fills) != len(runs) {
		return line, false
	}
	tokenAt := func(pos int) int {
		return sort.Search(len(offsets), func(i int) bool { return offsets[i] > pos }) - 1
	}
	// 从后往前改:后面那段并词条不影响前面那段的下标。
	for r := len(runs) - 1; r >= 0; r-- {
		a, b := runs[r][0], runs[r][1]
		i, j := tokenAt(a), tokenAt(b-1)
		if i < 0 || j < 0 {
			return line, false
		}
		if i == j {
			t := &toks[i]
			t.text = t.text[:a-offsets[i]] + fills[r] + t.text[b-offsets[i]:]
			continue
		}
		// 跨几个词条:星号段正好从头一个词条的开头起、到末一个词条的末尾止。
		if strings.TrimSpace(toks[j].text[b-offsets[j]:]) != "" ||
			strings.Trim(toks[i].text, "*") != "" || strings.Trim(toks[j].text[:b-offsets[j]], "*") != "" {
			return line, false
		}
		for k := i + 1; k < j; k++ {
			if strings.Trim(toks[k].text, "*") != "" {
				return line, false
			}
		}
		merged := toks[i]
		merged.text = fills[r] + toks[j].text[b-offsets[j]:]
		if end := toks[j].start + toks[j].dur; end > merged.start {
			merged.dur = end - merged.start
		}
		toks = append(append(toks[:i:i], merged), toks[j+1:]...)
	}
	var out strings.Builder
	out.WriteString(head)
	for _, t := range toks {
		out.WriteString("(" + strconv.FormatInt(t.start, 10) + "," + strconv.FormatInt(t.dur, 10) + "," + t.flag + ")" + t.text)
	}
	return out.String(), true
}

// unmaskRomaASCII:罗马音里跟正文同一时刻的那一行,星号段数跟正文补词那一行一样、补进去的原词全是 ASCII 时照样补上
// (罗马音由打码的正文生成时,星号原样留在里面)。原词不是 ASCII(补进去的是汉字)就不补:那要重新注音。
func unmaskRomaASCII(roma string, filled map[int][]string) string {
	if len(filled) == 0 || !hasLyricMask(roma) {
		return roma
	}
	lines := strings.Split(roma, "\n")
	changed := false
	for i, raw := range lines {
		if !hasLyricMask(raw) {
			continue
		}
		m := lrcLinePattern.FindStringSubmatch(strings.TrimRight(raw, "\r"))
		if m == nil {
			continue
		}
		stamp := lrcTimestampCaptureRe.FindStringSubmatch(m[1])
		if stamp == nil {
			continue
		}
		fills, ok := filled[lrcStampMs(stamp)]
		if !ok || !allASCII(fills) {
			continue
		}
		if fixed, ok := fillLyricMasks(m[2], fills); ok {
			lines[i] = m[1] + fixed + raw[len(strings.TrimRight(raw, "\r")):]
			changed = true
		}
	}
	if !changed {
		return roma
	}
	return strings.Join(lines, "\n")
}

func allASCII(ss []string) bool {
	for _, s := range ss {
		for i := 0; i < len(s); i++ {
			if s[i] >= utf8.RuneSelf {
				return false
			}
		}
	}
	return true
}

// unmaskDonors:除 self 之外各候选的某一份文本(正文 / 译文 / 罗马音)里带时间的行。
func unmaskDonors(results []scoredLyricCandidateResult, self int, field func(*scoredLyricCandidateResult) string) []unmaskLine {
	var out []unmaskLine
	for j := range results {
		if j == self {
			continue
		}
		if s := field(&results[j]); s != "" {
			out = append(out, lrcTimedLines(s)...)
		}
	}
	return out
}

// applyUnmaskedWords 给带星号的候选补词,原文记在 unmasked 里。donor 取的是这一批的原文:先算完所有补词再写回,
// 补过的候选不当别人的 donor。results 已按名次排好;两条流水线都在排序之后、借译文之前调。
func applyUnmaskedWords(results []scoredLyricCandidateResult) {
	type fix struct {
		i                     int
		lyrics, yrc, tr, roma string
	}
	var fixes []fix
	for i := range results {
		r := &results[i]
		if r.unmasked != nil || r.Lyrics == "" ||
			!hasLyricMask(r.Lyrics) && !yrcHasLyricMask(r.LyricsYRC) && !hasLyricMask(r.LyricsTr) && !hasLyricMask(r.LyricsRoma) {
			continue
		}
		body := unmaskDonors(results, i, func(c *scoredLyricCandidateResult) string { return c.Lyrics })
		f := fix{i: i}
		var filled map[int][]string
		f.lyrics, filled = unmaskLRC(r.Lyrics, body)
		f.yrc = unmaskYRC(r.LyricsYRC, body)
		f.tr, _ = unmaskLRC(r.LyricsTr, unmaskDonors(results, i, func(c *scoredLyricCandidateResult) string { return c.LyricsTr }))
		f.roma, _ = unmaskLRC(r.LyricsRoma, unmaskDonors(results, i, func(c *scoredLyricCandidateResult) string { return c.LyricsRoma }))
		f.roma = unmaskRomaASCII(f.roma, filled)
		if f.lyrics != r.Lyrics || f.yrc != r.LyricsYRC || f.tr != r.LyricsTr || f.roma != r.LyricsRoma {
			fixes = append(fixes, f)
		}
	}
	for _, f := range fixes {
		r := &results[f.i]
		o := &lyricUnmaskOrig{}
		if f.lyrics != r.Lyrics {
			o.lyrics, r.Lyrics = r.Lyrics, f.lyrics
		}
		if f.yrc != r.LyricsYRC {
			o.yrc, r.LyricsYRC = r.LyricsYRC, f.yrc
		}
		if f.tr != r.LyricsTr {
			o.tr, r.LyricsTr = r.LyricsTr, f.tr
		}
		if f.roma != r.LyricsRoma {
			o.roma, r.LyricsRoma = r.LyricsRoma, f.roma
		}
		r.unmasked = o
	}
}

// unmaskedCounterpart:当前歌词是这一轮某个同源候选补词之前的原文时,返回补好的那一份正文;不是就原样返回。
// 升级重试和重新打分在上锁之前拿它把快照换成跟候选同一口径。
func unmaskedCounterpart(source string, current bodyText, scored []scoredLyricCandidateResult) bodyText {
	if c := unmaskedSameAs(source, current, scored); c != nil && c.unmasked.lyrics != "" {
		return bt(c.Lyrics)
	}
	return current
}

func unmaskedSameAs(source string, current bodyText, scored []scoredLyricCandidateResult) *scoredLyricCandidateResult {
	for i := range scored {
		c := &scored[i]
		if c.unmasked == nil || c.Source != source {
			continue
		}
		orig := c.unmasked.lyrics
		if orig == "" {
			orig = c.Lyrics
		}
		if current.EqualString(orig) {
			return c
		}
	}
	return nil
}

// gainUnmaskedWords:条目存着的是这一轮某个同源候选补词之前的原文时,换成补好的那几份(正文、逐字、译文、罗马音各自对得上
// 原文才换)。罗马音是由打码的正文生成的,照正文补进去的 ASCII 原词补。升级重试与重新打分在比较之前调。
func gainUnmaskedWords(e *enrichEntry, scored []scoredLyricCandidateResult) bool {
	if e.Lyrics.IsZero() {
		return false
	}
	c := unmaskedSameAs(e.LyricsSource, e.Lyrics, scored)
	if c == nil {
		return false
	}
	o, changed := c.unmasked, false
	if o.lyrics != "" {
		old := e.Lyrics.String()
		e.Lyrics = bt(c.Lyrics)
		changed = true
		if o.roma == "" && hasLyricMask(e.LyricsRoma.String()) {
			_, filled := unmaskLRC(old, lrcTimedLines(c.Lyrics))
			if roma := unmaskRomaASCII(e.LyricsRoma.String(), filled); roma != e.LyricsRoma.String() {
				e.LyricsRoma = bt(roma)
			}
		}
	}
	if o.yrc != "" && e.LyricsYRC.EqualString(o.yrc) {
		e.LyricsYRC, changed = bt(c.LyricsYRC), true
	}
	if o.tr != "" && e.LyricsTr.EqualString(o.tr) {
		e.LyricsTr, changed = bt(c.LyricsTr), true
	}
	if o.roma != "" && e.LyricsRoma.EqualString(o.roma) {
		e.LyricsRoma, changed = bt(c.LyricsRoma), true
	}
	return changed
}

// maskedLyricsWorthRecheck:当前歌词里有被打码的词,值得再全源搜一轮,让同一轮里给了原词的源把它补上。
// 跟别的开播补查理由同一组闸(手改、校准过时间轴、标了纯音乐、关了自动跟进都不来),也算进升级重试的次数上限:
// 同一轮里没有别的源给原词的歌,最多白搜这几次。
func maskedLyricsWorthRecheck(e enrichEntry, pinned, autoUpgrade bool) bool {
	if !autoUpgrade || pinned || e.ManualLyrics || e.Instrumental || e.LyricsRetryCount >= lyricsRetryMaxAttempts {
		return false
	}
	return hasLyricMask(e.Lyrics.String()) || yrcHasLyricMask(e.LyricsYRC.String())
}

// maskedLyricsRechecked:这次进程里已经为打码词重来过的条目,一次进程只来一次:同一轮里没有别的源给原词时,
// 再搜也补不上。只在 enrichMu 里读写。
var maskedLyricsRechecked = map[string]bool{}
