package main

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// 角色歌的署名「角色(CV:声优)」:括号里 CV 标记后面写的是真正演唱的人。各歌词源有的按声优收录、有的按角色、
// 有的照抄整串,检索换名和歌手比对都按这个结构拆开用。只认带 CV 标记的括号,普通括号(艺名、外文名)不当成
// 角色/声优来猜。见 09 章决策 173。

// cvCredit 是一串署名拆出来的结构。
type cvCredit struct {
	// actors:各个 CV 括号里的声优,按出现顺序、去重;CJK 姓名中间的空格去掉(「平野 綾」→「平野綾」)。
	actors []string
	// characters:带 CV 括号的那几段,去掉括号后剩下的角色名,CJK 姓名中间的空格同样去掉;括号前什么都没写的段不记。
	characters []string
	// others:不带 CV 括号的段——团体 / 组合名,或一起署名的别的歌手,按出现顺序。
	others []string
	// pairs:每个带 CV 括号的段里,角色(段里括号外的那部分,可能为空)跟括号里的每一位声优各配一对。
	pairs []cvPair
}

// cvPair 是一组「角色 + 声优」。名字的写法跟 characters / actors 一样。
type cvPair struct{ character, actor string }

// cvParenMark:parseCVCredit 把每个 CV 括号换成的占位符。
const cvParenMark = '\x00'

// parseCVCredit 拆一串署名;一个 CV 括号都没有时 ok 为 false。没闭合的括号、括号里 CV 后面没写名字、
// CV 后面直接接拉丁字母(「(CVLTE)」)都不算 CV 括号,原样留在段落里。
func parseCVCredit(s string) (cvCredit, bool) {
	var c cvCredit
	if !mayHaveCVMarker(s) {
		return c, false
	}
	// 每个 CV 括号换成一个占位符,声优按出现顺序收进 actors;再按段切开,第 k 个占位符配第 k 个括号里的名单。
	var rest strings.Builder
	seenActor := map[string]bool{}
	var parenActors [][]string
	runes := []rune(s)
	for i := 0; i < len(runes); i++ {
		if !isCVOpenParen(runes[i]) {
			// 原串里自带的占位符字符丢掉,不然配对时数出来的占位符比括号多。
			if runes[i] != cvParenMark {
				rest.WriteRune(runes[i])
			}
			continue
		}
		end := -1
		for j := i + 1; j < len(runes); j++ {
			if isCVOpenParen(runes[j]) {
				break
			}
			if runes[j] == ')' || runes[j] == '）' {
				end = j
				break
			}
		}
		if end < 0 {
			rest.WriteRune(runes[i])
			continue
		}
		names, ok := cvParenActors(string(runes[i+1 : end]))
		if !ok {
			rest.WriteRune(runes[i])
			continue
		}
		for _, n := range names {
			if !seenActor[n] {
				seenActor[n] = true
				c.actors = append(c.actors, n)
			}
		}
		parenActors = append(parenActors, names)
		rest.WriteRune(cvParenMark)
		i = end
	}
	if len(c.actors) == 0 {
		return cvCredit{}, false
	}
	next := 0
	for _, seg := range splitCVCreditSegments(rest.String()) {
		n := strings.Count(seg, string(cvParenMark))
		if n == 0 {
			c.others = append(c.others, seg)
			continue
		}
		ch := cvCharacterName(seg)
		if ch != "" {
			c.characters = append(c.characters, ch)
		}
		for _, names := range parenActors[next : next+n] {
			for _, a := range names {
				c.pairs = append(c.pairs, cvPair{character: ch, actor: a})
			}
		}
		next += n
	}
	return c, true
}

// cvCharacterName:段里去掉 CV 括号之后的角色名。两侧的引号括号(「」『』“”‘’ 和半角引号)去掉,CJK 字之间的空格去掉。
func cvCharacterName(seg string) string {
	ch := strings.TrimSpace(strings.ReplaceAll(seg, string(cvParenMark), ""))
	ch = strings.TrimSpace(strings.Trim(ch, "「」『』“”‘’\"'"))
	if t := cjkSpaceStripped(ch); t != "" {
		ch = t
	}
	return ch
}

func isCVOpenParen(r rune) bool { return r == '(' || r == '（' }

// mayHaveCVMarker:串里有没有连着的 C、V 两个字母(半角或全角,不分大小写)。歌手比对每过一条候选都要拆一次,
// 绝大多数署名在这里就返回。
func mayHaveCVMarker(s string) bool {
	for i := 0; i+1 < len(s); i++ {
		if s[i]|0x20 == 'c' && s[i+1]|0x20 == 'v' {
			return true
		}
	}
	for _, fw := range []string{"ｃｖ", "ＣＶ", "Ｃｖ", "ｃＶ"} {
		if strings.Contains(s, fw) {
			return true
		}
	}
	return false
}

// cvParenActors:括号里的内容是不是「CV:声优…」,是的话拆出声优名单。
func cvParenActors(inner string) ([]string, bool) {
	body, ok := trimCVMarker(strings.TrimSpace(inner))
	if !ok || body == "" {
		return nil, false
	}
	var names []string
	for _, p := range splitCVActorList(body) {
		// 名单里每一位前面可能各自又写一次 CV(「上村祐翔、cv.柿原徹也」)。
		if t, ok := trimCVMarker(p); ok {
			p = t
		}
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if t := cjkSpaceStripped(p); t != "" {
			p = t
		}
		names = append(names, p)
	}
	return names, len(names) > 0
}

// trimCVMarker:s 以 CV 标记开头时去掉标记,返回后面的名字。标记后面可以跟 : ： . ． 或空白,
// 也可以直接接名字,但直接接的不能是拉丁字母或数字(那是「CVLTE」这类名字本身)。
func trimCVMarker(s string) (string, bool) {
	r1, n1 := utf8.DecodeRuneInString(s)
	r2, n2 := utf8.DecodeRuneInString(s[n1:])
	if !(r1 == 'c' || r1 == 'C' || r1 == 'ｃ' || r1 == 'Ｃ') || !(r2 == 'v' || r2 == 'V' || r2 == 'ｖ' || r2 == 'Ｖ') {
		return "", false
	}
	rest := s[n1+n2:]
	next, n := utf8.DecodeRuneInString(rest)
	switch {
	case rest == "":
		return "", true
	case next == ':' || next == '：' || next == '.' || next == '．':
		return strings.TrimSpace(rest[n:]), true
	case next < utf8.RuneSelf && (unicode.IsLetter(next) || unicode.IsDigit(next)):
		return "", false
	}
	return strings.TrimSpace(rest), true
}

// splitCVActorList 按 、 , ， & ＆ / ／ 和单词 with 切声优名单。「・」(半角的「･」先换成它)只在切出来的每一段都
// 至少两个字时才切:名单常用它连接(「阿澄佳奈・原紗友里」),但也有名字本身带它的(「M・A・O」)。
func splitCVActorList(s string) []string {
	parts := splitOnWithWord(s, func(r rune) bool {
		return r == '、' || r == ',' || r == '，' || r == '&' || r == '＆' || r == '/' || r == '／'
	})
	var out []string
	for _, p := range parts {
		p = strings.ReplaceAll(p, "･", "・")
		dot := strings.Split(p, "・")
		ok := len(dot) > 1
		for _, d := range dot {
			if utf8.RuneCountInString(strings.TrimSpace(d)) < 2 {
				ok = false
				break
			}
		}
		if ok {
			out = append(out, dot...)
		} else {
			out = append(out, p)
		}
	}
	return out
}

// splitCVCreditSegments 切去掉 CV 括号之后的整串署名。& 和 / 两侧都是拉丁字母时不切(「GRAC&E」「K/DA」是名字本身)。
func splitCVCreditSegments(s string) []string {
	runes := []rune(s)
	latin := func(i int) bool { return i >= 0 && i < len(runes) && isASCIILetter(runes[i]) }
	// 不切的 & 和 / 先换成占位符,切完再换回来。
	const keptAmp, keptSlash = '\x01', '\x02'
	var b strings.Builder
	for i, r := range runes {
		switch {
		case r == '&' && latin(i-1) && latin(i+1):
			b.WriteRune(keptAmp)
		case r == '/' && latin(i-1) && latin(i+1):
			b.WriteRune(keptSlash)
		default:
			b.WriteRune(r)
		}
	}
	parts := splitOnWithWord(b.String(), func(r rune) bool {
		return r == '、' || r == ',' || r == '，' || r == '&' || r == '＆' || r == '/' || r == '／'
	})
	restore := strings.NewReplacer(string(keptAmp), "&", string(keptSlash), "/")
	var out []string
	for _, p := range parts {
		if p = strings.TrimSpace(restore.Replace(p)); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// splitOnWithWord:按 sep 认的字符和前后都是空白的单词 with(不分大小写)切开,裁掉每段首尾空白。
func splitOnWithWord(s string, sep func(rune) bool) []string {
	var out []string
	var cur strings.Builder
	runes := []rune(s)
	flush := func() {
		out = append(out, strings.TrimSpace(cur.String()))
		cur.Reset()
	}
	for i := 0; i < len(runes); i++ {
		if sep(runes[i]) {
			flush()
			continue
		}
		if unicode.IsSpace(runes[i]) && i+5 < len(runes) && strings.EqualFold(string(runes[i+1:i+5]), "with") && unicode.IsSpace(runes[i+5]) {
			flush()
			i += 5
			continue
		}
		cur.WriteRune(runes[i])
	}
	flush()
	return out
}

// cvRetryIdentities:换名重查时从 CV 署名里拿的名字,依次是第一位声优、第一个不带 CV 的名字(团体 / 组合),各带出处。
// 多人署名也只拿这两个:源里多半署全体声优,任意一位都过得了歌手闸。角色名不拿:按角色名再查一轮不改变选中的歌词,
// 见 09 章决策 173。不是 CV 署名时为空。
func cvRetryIdentities(artist string) []artistIdentity {
	c, ok := parseCVCredit(artist)
	if !ok {
		return nil
	}
	out := []artistIdentity{{name: c.actors[0], origin: lyricQueryOriginCVActor}}
	if len(c.others) > 0 {
		out = append(out, artistIdentity{name: c.others[0], origin: lyricQueryOriginCVUnit})
	}
	return out
}

// cvCreditNames:歌手比对时一串 CV 署名可以拿来顶替整串的名字——每一位声优和每一个角色。
func cvCreditNames(artist string) []string {
	c, ok := parseCVCredit(artist)
	if !ok {
		return nil
	}
	return append(append([]string{}, c.actors...), c.characters...)
}

// isCVCredit:s 里有没有 CV 括号。
func isCVCredit(s string) bool {
	_, ok := parseCVCredit(s)
	return ok
}

// cvCreditsShareSinger:两串 CV 署名有没有同一组演唱者——有一对声优相同、角色也相同(任一边那一对没写角色时只看声优)。
// 只共享声优(同一位声优唱的另一个角色)、只共享角色(换了声优)、只同属一个团体都不算。名字逐字比,调用方先把两串
// 归一化成同一种写法(artistMatches 里的 na / nb)。
func cvCreditsShareSinger(a, b cvCredit) bool {
	for _, p := range a.pairs {
		for _, q := range b.pairs {
			if p.actor == q.actor && (p.character == "" || q.character == "" || p.character == q.character) {
				return true
			}
		}
	}
	return false
}
