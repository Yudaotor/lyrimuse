package main

import (
	"log"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 括号里的背景人声:除 AMLL / Apple Music 外的歌词源没有背景人声的结构化标记,和声、回声写在主句的括号里
// (「Kills me slowly (slowly)」)。有逐字歌词的,行尾 / 行中 / 行首的括号段拆成背景人声轨(lyrics_bg,形状同
// amllResult.bg:行头是所属主句的起止,词带自己的时间),正文与逐字里去掉这一段;译文、罗马音同一行里的括号段一起去掉。
// 整行都在括号里的不拆:App 按主句挂背景人声,主句空了这一行就不显示。拿不准的整行不拆。见 09 章决策 337。

// parenBGSources:拆括号背景人声的源。amll / applemusic 自带结构化的背景人声,正文里剩下的括号是它们判成主唱的部分,
// 而且存量回填(bgbackfill.go)会整份换掉它们的 lyrics_bg;本机文件、各客户端缓存里的用户歌词不动。
var parenBGSources = map[string]bool{
	"netease": true, "qq": true, "kugou": true, "lrclib": true, "musixmatch": true, "lyricfind": true, "kuwo": true,
	"migu": true, "deezer": true, "soda": true, "vibe": true, "genie": true, "petitlyrics": true,
	lxMusicLocalLyricsSource: true,
}

// parenBGPairToleranceMs:逐行歌词的一行跟逐字的一行按文字配对时,两边行首时间最多差这么多。拆分在时间轴重挂之前做,
// 同一行两边的时间戳可能差几百毫秒;文字已经要求逐字相同,这里只防同一句副歌配到隔得很远的另一遍。
const parenBGPairToleranceMs = 3000

var (
	parenBGSegRe      = regexp.MustCompile(`[(（]([^()（）]*)[)）]`)
	parenBGDuetRe     = regexp.MustCompile(`^(?:v[1-8]|合|男|女)[:：]\s*`)
	parenBGCountRe    = regexp.MustCompile(`(?i)^(?:[x×*]\s*\d+|\d+\s*[x×*]|repeat|rep|bis)$`)
	parenBGNoteRe     = regexp.MustCompile(`(?i)^(?:live|explicit|clean|remix|pt\.?\s*\d+|part\s*\d+|.*\bversion|ver\.?|.*\bedit|.*\bmix|instrumental|acoustic|demo|remaster(?:ed)?|intro|outro|chorus|verse.*|bridge|hook|pre-chorus|refrain|interlude|skit|spoken(?: word)?|laughs?|laughing|whispers?|whispering|(?:feat|ft|prod)\..*)$`)
	parenBGNoteZhRe   = regexp.MustCompile(`伴奏|现场|現場|电影|電影|电视剧|電視劇|插曲|主题曲|主題曲|片尾|片头|片頭|翻唱|原唱|版$`)
	yrcLineHeadFullRe = regexp.MustCompile(`^\[(\d+),(\d+)\]`)
	// parenBGCreditZhRe:中文署名行里的职务词。
	parenBGCreditZhRe = regexp.MustCompile(`制作|製作|作词|作詞|作曲|编曲|編曲|监制|監製|混音|录音|錄音|出品|发行|發行`)
	// parenBGCreditEnRe:英文署名行与版权行。
	parenBGCreditEnRe = regexp.MustCompile(`(?i)\b(?:recorded|mixed|mastered|produced|engineered|programm(?:ed|ing)|arranged|written|composed|strings|vocals)\s+by\b|©|℗|all rights reserved|\bpublishing\b`)
	// parenBGCJKHyphenRe:紧挨着中日韩字的「-」,标题行「歌手-歌名」的写法。
	parenBGCJKHyphenRe = regexp.MustCompile(`[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]-|-[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]`)
)

// parenBGRoleLabels:括号里写的是谁在唱(「(男)他们告诉我」「（合）不忍心」),不是和声。比对前转小写。
var parenBGRoleLabels = map[string]bool{
	"男": true, "女": true, "合": true, "合唱": true, "齐唱": true, "齊唱": true, "伴唱": true, "和声": true, "和聲": true,
	"独白": true, "獨白": true, "念白": true, "白": true, "说唱": true, "說唱": true, "旁白": true, "童声": true, "童聲": true,
	"男声": true, "女声": true, "男聲": true, "女聲": true, "男女": true, "rap": true, "all": true, "both": true,
	"国": true, "國": true, "粤": true, "粵": true, "国语": true, "國語": true, "粤语": true, "粵語": true, "台语": true, "台語": true,
}

type parenBGScript int

const (
	parenBGScriptOther parenBGScript = iota
	parenBGScriptLatin
	parenBGScriptCJK
)

func parenBGRuneScript(r rune) parenBGScript {
	switch {
	case unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul):
		return parenBGScriptCJK
	case unicode.Is(unicode.Latin, r):
		return parenBGScriptLatin
	}
	return parenBGScriptOther
}

// parenBGTextScript:一段文字的文字系统,有中日韩字就算中日韩。
func parenBGTextScript(s string) parenBGScript {
	out := parenBGScriptOther
	for _, r := range s {
		switch parenBGRuneScript(r) {
		case parenBGScriptCJK:
			return parenBGScriptCJK
		case parenBGScriptLatin:
			out = parenBGScriptLatin
		}
	}
	return out
}

func parenBGHasKana(s string) bool {
	for _, r := range s {
		if unicode.In(r, unicode.Hiragana, unicode.Katakana) {
			return true
		}
	}
	return false
}

func parenBGHasWord(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return true
		}
	}
	return false
}

// parenBGNormKey:配对用的键,只留字母和数字、转小写。
func parenBGNormKey(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

// parenBGBalanced:括号成对、不嵌套。
func parenBGBalanced(s string) bool {
	depth := 0
	for _, r := range s {
		switch r {
		case '(', '（':
			depth++
			if depth > 1 {
				return false
			}
		case ')', '）':
			depth--
			if depth < 0 {
				return false
			}
		}
	}
	return depth == 0
}

// parenBGLine:一行歌词(不含时间戳)里能拆的括号段。返回去掉括号段后的主句和按顺序的括号段(带括号);有一段拿不准
// 整行就不拆。译文 / 音译走 parenBGAuxLine。
//
// 不拆:标签行、署名行与标题行(以 `[` 开头、带冒号、带「 - 」「 – 」「 — 」或紧挨中日韩字的「-」、带中英文职务词或版权字样)、括号不配对或嵌套、
// 括号里没有字母或带「/」(人名清单)、是演唱者 / 语言 / 重复次数 / 版本与段落标注、行首括号里只有不超过 4 个中日韩字(多半是演唱者名字)、括号紧贴前一个字而且换了文字(注释,
// 如「Einstein(愛因斯坦)」;带假名的行紧贴就不拆,日文的读音注释是同一种文字)、右括号后面紧跟着字或「-」、拆完主句没有字。
func parenBGLine(text string) (main string, segs []string, ok bool) {
	prefix := parenBGDuetRe.FindString(text)
	body := text[len(prefix):]
	if body == "" || strings.HasPrefix(body, "[") || strings.Contains(body, " - ") || strings.Contains(body, " – ") ||
		strings.Contains(body, " — ") || (strings.Contains(body, ":") || strings.Contains(body, "：")) {
		return "", nil, false
	}
	if !parenBGBalanced(body) {
		return "", nil, false
	}
	ms := parenBGSegRe.FindAllStringSubmatchIndex(body, -1)
	if len(ms) == 0 {
		return "", nil, false
	}
	kana := parenBGHasKana(body)
	for _, m := range ms {
		content := strings.TrimSpace(body[m[2]:m[3]])
		if !strings.ContainsFunc(content, unicode.IsLetter) || strings.Contains(content, "/") {
			return "", nil, false
		}
		lower := strings.ToLower(content)
		if parenBGRoleLabels[lower] || parenBGCountRe.MatchString(lower) || parenBGNoteRe.MatchString(lower) || parenBGNoteZhRe.MatchString(content) {
			return "", nil, false
		}
		before := body[:m[0]]
		if strings.TrimSpace(before) == "" {
			if parenBGTextScript(content) == parenBGScriptCJK && !strings.ContainsFunc(content, func(r rune) bool { return unicode.Is(unicode.Latin, r) }) &&
				utf8.RuneCountInString(content) <= 4 && strings.TrimSpace(body[m[1]:]) != "" {
				return "", nil, false
			}
		} else if prev, _ := utf8.DecodeLastRuneInString(before); !unicode.IsSpace(prev) {
			if kana || parenBGRuneScript(prev) != parenBGTextScript(content) {
				return "", nil, false
			}
		}
		if next, _ := utf8.DecodeRuneInString(body[m[1]:]); unicode.IsLetter(next) || unicode.IsDigit(next) || next == '-' {
			return "", nil, false
		}
		segs = append(segs, body[m[0]:m[1]])
	}
	main = parenBGRemoveSegs(body, ms)
	if !parenBGHasWord(main) || parenBGCreditLine(body) {
		return "", nil, false
	}
	return prefix + main, segs, true
}

// parenBGRemoveSegs:去掉 body 里的这几段括号(parenBGSegRe 的匹配位置),连同每段前面的空白;在行首时去掉它后面的空白。
func parenBGRemoveSegs(body string, ms [][]int) string {
	var b strings.Builder
	last := 0
	for _, m := range ms {
		kept := body[last:m[0]]
		if strings.TrimSpace(b.String()+kept) == "" {
			b.Reset()
			kept = ""
		} else {
			kept = strings.TrimRightFunc(kept, unicode.IsSpace)
		}
		b.WriteString(kept)
		last = m[1]
		if strings.TrimSpace(b.String()) == "" {
			for last < len(body) {
				r, size := utf8.DecodeRuneInString(body[last:])
				if !unicode.IsSpace(r) {
					break
				}
				last += size
			}
		}
	}
	b.WriteString(body[last:])
	return strings.TrimSpace(b.String())
}

// parenBGAuxLine:译文 / 音译里同一行的括号段整段去掉。这一行的正文已经按 parenBGLine 拆过,括号里是背景人声的译文 / 音译,
// 正文那套标签、署名、紧贴、紧跟字的规矩不再适用(中文译文括号前后本来就不留空格)。只要括号配对、每段有字母、
// 去掉之后还有字;整行都在括号里的不动,这一行的译文就是背景人声的,去掉就空了。
func parenBGAuxLine(text string) (string, bool) {
	prefix := parenBGDuetRe.FindString(text)
	body := text[len(prefix):]
	if !parenBGBalanced(body) {
		return "", false
	}
	ms := parenBGSegRe.FindAllStringSubmatchIndex(body, -1)
	if len(ms) == 0 {
		return "", false
	}
	for _, m := range ms {
		if !strings.ContainsFunc(body[m[2]:m[3]], unicode.IsLetter) {
			return "", false
		}
	}
	main := parenBGRemoveSegs(body, ms)
	if !parenBGHasWord(main) {
		return "", false
	}
	return prefix + main, true
}

// parenBGCreditLine:署名行、版权行、标题行「歌手-歌名」。几个正则放在 parenBGLine 最后、各带一道子串前筛:启动迁移每次
// 都要把带括号的行全判一遍,多数行在前面就被拒了。
func parenBGCreditLine(body string) bool {
	if parenBGCreditZhRe.MatchString(body) {
		return true
	}
	if lower := strings.ToLower(body); (strings.Contains(lower, "by") || strings.Contains(lower, "reserved") || strings.Contains(lower, "publishing") ||
		strings.Contains(body, "©") || strings.Contains(body, "℗")) && parenBGCreditEnRe.MatchString(body) {
		return true
	}
	return strings.Contains(body, "-") && parenBGCJKHyphenRe.MatchString(body)
}

// parenBGYRCMayHaveParen:逐字一行的歌词文字里可能有括号 —— 有全角左括号,或者有不是词条时间 `(起点,时长,0)` 开头的半角左括号。
// 只是前筛,判错了的行照样交给 parenBGYRCLine。
func parenBGYRCMayHaveParen(line string) bool {
	if strings.Contains(line, "（") {
		return true
	}
	for i := 0; i < len(line); i++ {
		if line[i] == '(' && !parenBGTimingAt(line, i) {
			return true
		}
	}
	return false
}

// parenBGTimingAt:line[i:] 以 `(数字,数字,数字)` 开头。
func parenBGTimingAt(line string, i int) bool {
	j := i + 1
	for n := 0; n < 3; n++ {
		k := j
		for j < len(line) && line[j] >= '0' && line[j] <= '9' {
			j++
		}
		if j == k || j >= len(line) {
			return false
		}
		want := byte(',')
		if n == 2 {
			want = ')'
		}
		if line[j] != want {
			return false
		}
		j++
	}
	return true
}

// parenBGHasParen:有半角或全角左括号。别写成 strings.ContainsAny(s, "(（"):字符集里有非 ASCII 字符时它逐字比,
// 启动迁移要把全库歌词扫一遍,慢几倍。
func parenBGHasParen(s string) bool {
	return strings.Contains(s, "(") || strings.Contains(s, "（")
}

// parenBGYRCWord:YRC 一行里的一个词条。
type parenBGYRCWord struct {
	timing string // `(起点,时长,0)` 原样
	text   string
}

// parenBGYRCLine 按 parenBGLine 的规矩拆一行逐字:括号段从某个词条的开头起(前面只有空白),或者左括号粘在前一个词条的
// 末尾(后面只剩空白);在某个词条里结束,右括号后面只剩标点和空白(那段并回前一个主句词条)。返回主句那一行、背景人声那一行(行头相同)、两边的配对键。
// 背景人声那一行每段各自去掉首尾括号、丢掉只剩括号的词条:App 显示时只剥整行首尾的一对括号,一行几段时中间的
// 括号会留下来(「a) (b」)。
func parenBGYRCLine(line string) (mainLine, bgLine, mainKey, bgKey string, ok bool) {
	head := yrcLineHeadFullRe.FindString(line)
	if head == "" {
		return "", "", "", "", false
	}
	locs := yrcWordTokenRe.FindAllStringIndex(line, -1)
	if len(locs) == 0 || locs[0][0] != len(head) {
		return "", "", "", "", false
	}
	words := make([]parenBGYRCWord, len(locs))
	var full strings.Builder
	starts := make([]int, len(locs))
	for i, m := range locs {
		end := len(line)
		if i+1 < len(locs) {
			end = locs[i+1][0]
		}
		words[i] = parenBGYRCWord{timing: line[m[0]:m[1]], text: line[m[1]:end]}
		starts[i] = full.Len()
		full.WriteString(words[i].text)
	}
	text := full.String()
	mainText, segs, ok := parenBGLine(text)
	if !ok {
		return "", "", "", "", false
	}
	wordAt := func(pos int) int {
		k := 0
		for k+1 < len(starts) && starts[k+1] <= pos {
			k++
		}
		return k
	}
	isBG := make([]bool, len(words))
	var bgWords []parenBGYRCWord
	tails := map[int]string{} // 括号段之后、同一词条里剩下的标点:并到这个下标之前最近的主句词条
	after := map[int]bool{}   // 紧跟在括号段后面的词条下标:它以标点开头时,前一个主句词条末尾的空白去掉
	gaps := map[int]string{}  // 括号段之后、同一词条里剩下的空白:前一个主句词条末尾没有空白时补上
	cut := map[int]string{}   // 左括号粘在末尾的主句词条:去掉括号之后的文字
	for _, m := range parenBGSegRe.FindAllStringIndex(text, -1) {
		wi, wj := wordAt(m[0]), wordAt(m[1]-1)
		first := wi
		if strings.TrimSpace(text[starts[wi]:m[0]]) != "" {
			// 左括号粘在一个主句词条的末尾(「hype (」「now(」),后面只剩空白:那个词条去掉括号留在主句,背景人声从下一个词条起。
			_, size := utf8.DecodeRuneInString(text[m[0]:])
			if wj == wi || strings.TrimSpace(text[m[0]+size:starts[wi]+len(words[wi].text)]) != "" {
				return "", "", "", "", false
			}
			cut[wi] = text[starts[wi]:m[0]]
			first = wi + 1
		}
		var seg []parenBGYRCWord
		for k := first; k <= wj; k++ {
			isBG[k] = true
			w := words[k]
			if k == wj {
				at := m[1] - starts[wj]
				rest := words[wj].text[at:]
				// 下一段的左括号粘在这个词条末尾(「right?) (」):那是下一段的开头,不是这一段之后剩下的标点。
				if i := strings.IndexAny(rest, "(（"); i >= 0 {
					rest = rest[:i]
				}
				if parenBGHasWord(rest) {
					return "", "", "", "", false
				}
				w.text = w.text[:at]
				if strings.TrimSpace(rest) != "" {
					tails[first] = rest
				} else if rest != "" {
					gaps[first] = rest
				}
			}
			if k == first {
				w.text = strings.TrimLeft(strings.TrimLeftFunc(w.text, unicode.IsSpace), "(（")
			}
			if k == wj {
				w.text = strings.TrimRight(w.text, ")）")
			}
			if strings.TrimSpace(w.text) != "" {
				seg = append(seg, w)
			}
		}
		if len(seg) == 0 {
			return "", "", "", "", false
		}
		seg[len(seg)-1].text = strings.TrimRightFunc(seg[len(seg)-1].text, unicode.IsSpace) + " "
		bgWords = append(bgWords, seg...)
		after[wj+1] = true
	}
	var mainWords []parenBGYRCWord
	for k, w := range words {
		if tail, ok := tails[k]; ok && len(mainWords) > 0 {
			p := &mainWords[len(mainWords)-1]
			p.text = strings.TrimRightFunc(p.text, unicode.IsSpace) + tail
		} else if gap, ok := gaps[k]; ok && len(mainWords) > 0 {
			if p := &mainWords[len(mainWords)-1]; strings.TrimRightFunc(p.text, unicode.IsSpace) == p.text {
				p.text += gap
			}
		}
		if c, ok := cut[k]; ok {
			w.text = c
		}
		if !isBG[k] {
			if first, _ := utf8.DecodeRuneInString(w.text); after[k] && len(mainWords) > 0 && first != utf8.RuneError &&
				!unicode.IsLetter(first) && !unicode.IsDigit(first) && !unicode.IsSpace(first) {
				p := &mainWords[len(mainWords)-1]
				p.text = strings.TrimRightFunc(p.text, unicode.IsSpace)
			}
			mainWords = append(mainWords, w)
		}
	}
	if len(mainWords) == 0 || len(bgWords) == 0 {
		return "", "", "", "", false
	}
	mainWords[len(mainWords)-1].text = strings.TrimRightFunc(mainWords[len(mainWords)-1].text, unicode.IsSpace)
	bgWords[len(bgWords)-1].text = strings.TrimRightFunc(bgWords[len(bgWords)-1].text, unicode.IsSpace)
	join := func(ws []parenBGYRCWord) (string, string) {
		var l, t strings.Builder
		l.WriteString(head)
		for _, w := range ws {
			l.WriteString(w.timing)
			l.WriteString(w.text)
			t.WriteString(w.text)
		}
		return l.String(), t.String()
	}
	mainLine, mainPlain := join(mainWords)
	bgLine, bgPlain := join(bgWords)
	if parenBGNormKey(mainPlain) != parenBGNormKey(mainText) || parenBGNormKey(bgPlain) != parenBGNormKey(strings.Join(segs, "")) {
		return "", "", "", "", false
	}
	return mainLine, bgLine, parenBGNormKey(mainPlain), parenBGNormKey(bgPlain), true
}

// parenBGSplit:splitParenBackground 的结果。stamps 是拆过的逐行歌词行的时间戳(毫秒),译文 / 罗马音按它找同一行。
type parenBGSplit struct {
	lrc, yrc, bg string
	stamps       map[int]bool
}

// splitParenBackground 把一份歌词的括号背景人声拆出来。逐行与逐字各按 parenBGLine 拆,再按文字配对:逐行的一行
// (每个时间戳)都要配上一行拆得开、主句与括号段文字都相同、时间相近的逐字,两边才一起拆;配不上的两边都不动。
// 没有逐字、或一行都没拆时 ok 为假。
func splitParenBackground(lrc, yrc string) (parenBGSplit, bool) {
	if yrc == "" || !parenBGHasParen(lrc) {
		return parenBGSplit{}, false
	}
	// 逐行歌词按位置扫,不先切成数组:启动迁移每次把全库带括号的歌词判一遍,多数一行都拆不了。
	type lSplit struct {
		from, textAt, to int // 这一行在 lrc 里的起止,textAt 是时间戳之后
		stamps           []int
		main             string
		mainK, bgK       string
	}
	var ls []lSplit
	// 正文自带 `[kana:]` 假名标注时,括号里有待标汉字的行不拆:标注按整份正文的汉字逐个对齐(KanaAnnotation.parse、
	// kanaEntriesByLineKey),移走几个汉字总数就对不上,整份标注作废、退回分词器猜读音。
	hasKana := strings.Contains(lrc, "[kana:")
	for from := 0; from <= len(lrc); {
		to := strings.IndexByte(lrc[from:], '\n')
		if to < 0 {
			to = len(lrc)
		} else {
			to += from
		}
		line := lrc[from:to]
		lineFrom := from
		from = to + 1
		if !parenBGHasParen(line) {
			continue
		}
		stamps, end := parenBGLRCStamps(line)
		if len(stamps) == 0 {
			continue
		}
		mainText, segs, ok := parenBGLine(strings.TrimSpace(line[end:]))
		if !ok || (hasKana && strings.ContainsFunc(strings.Join(segs, ""), kanaNeedsAnnotation)) {
			continue
		}
		ls = append(ls, lSplit{from: lineFrom, textAt: lineFrom + end, to: to, stamps: stamps, main: mainText,
			mainK: parenBGNormKey(mainText), bgK: parenBGNormKey(strings.Join(segs, ""))})
	}
	if len(ls) == 0 {
		return parenBGSplit{}, false
	}
	type ySplit struct {
		idx, start           int
		main, bg, mainK, bgK string
		used                 bool
	}
	ylines := strings.Split(yrc, "\n")
	var heads []int
	for _, line := range ylines {
		if m := yrcLineHeadFullRe.FindStringSubmatch(line); m != nil {
			h, _ := strconv.Atoi(m[1])
			heads = append(heads, h)
		}
	}
	var ys []*ySplit
	for i, line := range ylines {
		if !parenBGYRCMayHaveParen(line) {
			continue
		}
		mainLine, bgLine, mk, bk, ok := parenBGYRCLine(line)
		if !ok {
			continue
		}
		start, _ := strconv.Atoi(yrcLineHeadFullRe.FindStringSubmatch(line)[1])
		if parenBGHeadCrowded(heads, start) {
			continue
		}
		ys = append(ys, &ySplit{idx: i, start: start, main: mainLine, bg: bgLine, mainK: mk, bgK: bk})
	}
	stamps := map[int]bool{}
	var newLRC strings.Builder
	prev, split := 0, 0
	for _, l := range ls {
		var picked []*ySplit
		for _, t := range l.stamps {
			var best *ySplit
			for _, y := range ys {
				if y.used || y.mainK != l.mainK || y.bgK != l.bgK || parenBGAbs(y.start-t) > parenBGPairToleranceMs {
					continue
				}
				if best == nil || parenBGAbs(y.start-t) < parenBGAbs(best.start-t) {
					best = y
				}
			}
			if best == nil {
				break
			}
			best.used = true
			picked = append(picked, best)
		}
		if len(picked) != len(l.stamps) {
			for _, y := range picked {
				y.used = false
			}
			continue
		}
		newLRC.WriteString(lrc[prev:l.textAt])
		newLRC.WriteString(l.main)
		prev = l.to
		for _, t := range l.stamps {
			stamps[t] = true
		}
		split++
	}
	if split == 0 {
		return parenBGSplit{}, false
	}
	newLRC.WriteString(lrc[prev:])
	var bg strings.Builder
	for _, y := range ys {
		if !y.used {
			continue
		}
		ylines[y.idx] = y.main
		bg.WriteString(y.bg)
		bg.WriteByte('\n')
	}
	return parenBGSplit{lrc: newLRC.String(), yrc: strings.Join(ylines, "\n"), bg: bg.String(), stamps: stamps}, true
}

// parenBGHeadCrowded:还有别的逐字行的行首跟 start 相差不超过背景人声挂行的容差(App 按行首 ±30ms 把背景人声挂到主句上,
// 见 bgBackfillAlignToleranceMs)。这样的行拆出来的背景人声会挂错行或挂两遍。heads 含 start 自己那一行。
func parenBGHeadCrowded(heads []int, start int) bool {
	n := 0
	for _, h := range heads {
		if parenBGAbs(h-start) <= bgBackfillAlignToleranceMs {
			n++
		}
	}
	return n > 1
}

// parenBGLRCStamps:一行逐行歌词开头连着的时间戳(毫秒)和它们结束的位置;不以时间戳开头时为空。
//
// 手写解析,跟 lrcTimestampCaptureRe(`\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]`)从行首连着匹配的结果一致,
// 省掉每行一次的正则分配(TestParenBGLRCStampsMatchesRegexp 对拍)。
func parenBGLRCStamps(line string) ([]int, int) {
	end := 0
	var out []int
	for {
		ms, next, ok := parenBGStampAt(line, end)
		if !ok {
			return out, end
		}
		out = append(out, ms)
		end = next
	}
}

// parenBGStampAt:line[i:] 开头的一个 `[mm:ss]` / `[mm:ss.xx]` 时间戳,返回毫秒和它之后的位置。
func parenBGStampAt(line string, i int) (int, int, bool) {
	digits := func(j, max int) int {
		n := 0
		for j+n < len(line) && n < max && line[j+n] >= '0' && line[j+n] <= '9' {
			n++
		}
		return n
	}
	if i >= len(line) || line[i] != '[' {
		return 0, 0, false
	}
	j := i + 1
	mmN := digits(j, 2)
	if mmN == 0 || j+mmN >= len(line) || line[j+mmN] != ':' {
		return 0, 0, false
	}
	mm, _ := strconv.Atoi(line[j : j+mmN])
	j += mmN + 1
	if digits(j, 2) != 2 {
		return 0, 0, false
	}
	ss, _ := strconv.Atoi(line[j : j+2])
	j += 2
	frac := ""
	if j < len(line) && (line[j] == '.' || line[j] == ':') {
		fN := digits(j+1, 3)
		if fN == 0 {
			return 0, 0, false
		}
		frac = line[j+1 : j+1+fN]
		j += 1 + fN
	}
	if j >= len(line) || line[j] != ']' {
		return 0, 0, false
	}
	return (mm*60+ss)*1000 + lrcFracMs(frac), j + 1, true
}

func parenBGAbs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// stripParenBackgroundAux:译文 / 罗马音里,时间戳都跟 stamps 里某一个相差不超过 bgBackfillAlignToleranceMs 的行去掉括号段
// (parenBGAuxLine)。候选阶段的 stamps 是拆过的逐行歌词行的时间戳(重挂时间轴之前);存量迁移是背景人声各行的行头 ——
// 不知道当初拆的是哪几行,挂着背景人声的就是拆过的。译文的时间戳常跟正文差几十毫秒,所以不要求相等。
func stripParenBackgroundAux(aux string, stamps map[int]bool) string {
	if aux == "" || len(stamps) == 0 || !parenBGHasParen(aux) {
		return aux
	}
	lines := strings.Split(aux, "\n")
	changed := false
	for i, line := range lines {
		ms, end := parenBGLRCStamps(line)
		if len(ms) == 0 {
			continue
		}
		all := true
		for _, t := range ms {
			if !parenBGNearStamp(stamps, t) {
				all = false
			}
		}
		if !all {
			continue
		}
		if mainText, ok := parenBGAuxLine(strings.TrimSpace(line[end:])); ok {
			lines[i] = line[:end] + mainText
			changed = true
		}
	}
	if !changed {
		return aux
	}
	return strings.Join(lines, "\n")
}

func parenBGNearStamp(stamps map[int]bool, t int) bool {
	if stamps[t] {
		return true
	}
	for s := range stamps {
		if parenBGAbs(s-t) <= bgBackfillAlignToleranceMs {
			return true
		}
	}
	return false
}

// parenBGHeadStamps:背景人声各行的行头(毫秒)。
func parenBGHeadStamps(bg string) map[int]bool {
	out := map[int]bool{}
	for _, l := range strings.Split(bg, "\n") {
		if m := yrcLineHeadFullRe.FindStringSubmatch(l); m != nil {
			h, _ := strconv.Atoi(m[1])
			out[h] = true
		}
	}
	return out
}

// splitCandidateParenBackground 就地拆一批候选。调用时机同 repairCandidateAccentSplits(候选装配完、重挂时间轴与
// 打分之前)。已经带背景人声的(parenBG 非空,合并轮从打好分的结果还原时带过来)不再拆。
func splitCandidateParenBackground(candidates []lyricCandidate) {
	for i := range candidates {
		c := &candidates[i]
		if !parenBGSources[c.source] || c.plainTextOnly || c.wordTimingYRC == "" || c.parenBG != "" {
			continue
		}
		sp, ok := splitParenBackground(c.lyrics, c.wordTimingYRC)
		if !ok {
			continue
		}
		c.lyrics, c.wordTimingYRC, c.parenBG, c.parenBGStamps = sp.lrc, sp.yrc, sp.bg, sp.stamps
	}
}

// migrateParenBackground 把存量条目按同一套规矩拆一遍。只动 parenBGSources 选出的、有逐字、没锁定(手改或采纳时锁上的)
// 的条目。这些源的背景人声只会是拆出来的,已经有的也再拆一遍:拆过的行不带括号了,剩下的行规矩改了能拆时并进来,
// 跟新解析出来的候选一次拆完的结果相同,不然两边正文对不上,重评时当前这份永远不在候选里(rescoreKeepsCurrent)。演唱者标注按行记,拆分不增删行:原先对得上正文的,指纹跟着换;原样采纳的指纹同理,
// 同 migrateAccentSplits。
//
// 位置(main.go):migrateAccentSplits 之后、exportLyricsFiles 之前,导出的文件跟着拆过的正文写。不加水位:每次启动
// 重判一遍,只扫还带括号的行。
func migrateParenBackground() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		if e.ManualLyrics || e.Instrumental || !parenBGSources[e.LyricsSource] || e.LyricsYRC.IsZero() {
			continue
		}
		lrc, yrc := e.Lyrics.String(), e.LyricsYRC.String()
		changed := false
		stamps := map[int]bool{}
		if sp, ok := splitParenBackground(lrc, yrc); ok {
			if s := e.LyricsSpeakers; s != nil && s.For == lyricSpeakersFingerprint(lrc, yrc) {
				moved := *s
				moved.For = lyricSpeakersFingerprint(sp.lrc, sp.yrc)
				e.LyricsSpeakers = &moved
			}
			if e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(lrc) {
				e.ManualPickSHA = manualPickFingerprint(sp.lrc)
			}
			e.Lyrics, e.LyricsYRC, e.LyricsBG = bt(sp.lrc), bt(sp.yrc), bt(mergeParenBGTracks(e.LyricsBG.String(), sp.bg))
			stamps = sp.stamps
			changed = true
		}
		if e.LyricsBG.IsZero() {
			continue
		}
		// 译文 / 罗马音按挂着背景人声的那几行清:以前拆过的行这一轮不再出现在 sp.stamps 里。
		for h := range parenBGHeadStamps(e.LyricsBG.String()) {
			stamps[h] = true
		}
		if tr := e.LyricsTr.String(); tr != "" {
			if fixedTr := stripParenBackgroundAux(tr, stamps); fixedTr != tr {
				e.LyricsTr, changed = bt(fixedTr), true
			}
		}
		if roma := e.LyricsRoma.String(); roma != "" {
			if fixedRoma := stripParenBackgroundAux(roma, stamps); fixedRoma != roma {
				e.LyricsRoma, changed = bt(fixedRoma), true
			}
		}
		if !changed {
			continue
		}
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		enrichDirty = true // 同 migrateAccentSplits:不置脏 saveEnrichCache 不写盘
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("paren background vocals: updated %d entries", fixed)
		saveEnrichCache()
	}
}

// mergeParenBGTracks 把新拆出来的背景人声行并进已有的,按行头的起点排序(同一起点保持原有在前)。两边来自逐字的不同行。
func mergeParenBGTracks(old, add string) string {
	if old == "" {
		return add
	}
	type line struct {
		start int
		text  string
	}
	var lines []line
	for _, part := range []string{old, add} {
		for _, l := range strings.Split(part, "\n") {
			m := yrcLineHeadFullRe.FindStringSubmatch(l)
			if m == nil {
				continue
			}
			st, _ := strconv.Atoi(m[1])
			lines = append(lines, line{st, l})
		}
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].start < lines[j].start })
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l.text)
		b.WriteByte('\n')
	}
	return b.String()
}
