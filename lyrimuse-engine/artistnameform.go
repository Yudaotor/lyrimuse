package main

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 歌手比对前把同一个名字的几种写法对齐。只给 artistMatches / artistCreditParts 和网易云认身份的 neteaseArtistMatches 用;
// 搜索词、缓存 key、normLoose 都不经过这里。见 09 章决策 177。

// artistMatchKey:artistMatches 比对前的写法 —— 全角字母数字折成半角、「々」展开、繁转简、去变音、小写、去首尾空白。
func artistMatchKey(s string) string {
	return strings.TrimSpace(strings.ToLower(foldDiacritics(toSimplified(foldIterationMark(foldFullwidthAlnum(s))))))
}

// artistSpacingKey:artistMatches 最后一档比的写法 —— 挨着汉字、假名、谚文的空白和「&」两边的空白去掉。同一位歌手在
// 不同曲库里常只差这几处空格:「G.E.M. 鄧紫棋」对「G.E.M.邓紫棋」、「米津 玄師」对「米津玄師」、「A & B」对「A&B」。
// 只去空白、不碰标点,「周杰伦-」「周杰伦、」这类仿冒号的尾巴照样对不上;拉丁字母之间的空白不动。s 先过 artistMatchKey。
// 见 09 章决策 200。
func artistSpacingKey(s string) string {
	if !strings.ContainsFunc(s, unicode.IsSpace) {
		return s
	}
	rs := []rune(s)
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(rs); {
		if !unicode.IsSpace(rs[i]) {
			b.WriteRune(rs[i])
			i++
			continue
		}
		j := i
		for j < len(rs) && unicode.IsSpace(rs[j]) {
			j++
		}
		if !(i > 0 && spacingDroppedNextTo(rs[i-1])) && !(j < len(rs) && spacingDroppedNextTo(rs[j])) {
			b.WriteString(string(rs[i:j]))
		}
		i = j
	}
	return b.String()
}

// spacingDroppedNextTo:挨着它的空白在 artistSpacingKey 里去掉。
func spacingDroppedNextTo(r rune) bool {
	return r == '&' || unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul)
}

// artistJoinedKey:artistSpacingKey 之外,夹在两个中日韩字之间的「-」「·」「・」也去掉 —— 酷我把「小宇 宋念宇」写成「小宇-宋念宇」。
// 只去夹在中间的:「周杰伦-」这类仿冒号的尾巴、「周杰伦-翻唱」去掉之后照样对不上。s 先过 artistMatchKey。见 09 章决策 280。
func artistJoinedKey(s string) string {
	s = artistSpacingKey(s)
	if !strings.ContainsAny(s, "-·・") {
		return s
	}
	rs := []rune(s)
	var b strings.Builder
	b.Grow(len(s))
	for i, r := range rs {
		if (r == '-' || r == '·' || r == '・') && i > 0 && i < len(rs)-1 && isCJKLetter(rs[i-1]) && isCJKLetter(rs[i+1]) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// isCJKLetter:汉字、假名、谚文。
func isCJKLetter(r rune) bool {
	return unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul)
}

// artistGenericWords:拉丁字母那一半里有这些词就不当名字认(「邓紫棋Cover」「某某 Fans」是上传者,不是这位歌手)。
var artistGenericWords = map[string]bool{
	"cover": true, "covers": true, "remix": true, "mix": true, "live": true, "dj": true, "demo": true, "ver": true, "version": true,
	"official": true, "music": true, "band": true, "mv": true, "ost": true, "inst": true, "karaoke": true, "acoustic": true,
	"fan": true, "fans": true, "club": true, "studio": true, "records": true, "channel": true, "tv": true, "radio": true,
	"feat": true, "ft": true, "and": true, "x": true, "vs": true, "edit": true, "bgm": true, "sped": true, "slowed": true,
}

// artistScriptHalves:署名恰好是一段中日韩字跟一段拉丁字母连写(「G.E.M.邓紫棋」「袁娅维TIA RAY」「法兰Fran」),返回两半;中文那半
// 至少两个字、拉丁那半至少两个字母。带合作分隔符(「&」「/」「,」这些)、两种文字交替不止一次的不算。s 先过 artistMatchKey。
func artistScriptHalves(s string) (cjk, latin string, ok bool) {
	if strings.ContainsFunc(s, isArtistCreditMatchSep) {
		return "", "", false
	}
	cut, last := -1, 0
	for i, r := range s {
		k := 0
		switch {
		case isCJKLetter(r):
			k = 1
		case unicode.In(r, unicode.Latin):
			k = 2
		default:
			continue
		}
		if last != 0 && k != last {
			if cut >= 0 {
				return "", "", false
			}
			cut = i
		}
		last = k
	}
	if cut < 0 {
		return "", "", false
	}
	a, b := strings.Trim(s[:cut], " -·・"), strings.Trim(s[cut:], " -·・")
	if strings.ContainsFunc(a, isCJKLetter) {
		cjk, latin = a, b
	} else {
		cjk, latin = b, a
	}
	if utf8.RuneCountInString(strings.TrimFunc(cjk, func(r rune) bool { return !isCJKLetter(r) })) < 2 {
		return "", "", false
	}
	for _, w := range strings.FieldsFunc(latin, func(r rune) bool { return !unicode.IsLetter(r) }) {
		if artistGenericWords[w] {
			return "", "", false
		}
	}
	if latinLetterCount(latin) < 2 {
		return "", "", false
	}
	return cjk, latin, true
}

// latinLetterCount:s 里拉丁字母的个数。
func latinLetterCount(s string) int {
	n := 0
	for _, r := range s {
		if unicode.In(r, unicode.Latin) {
			n++
		}
	}
	return n
}

// artistNameFormMatches:候选署名 candidate 跟本地署名 query 是同一位歌手的两种写法 —— 只差夹在中日韩字之间的分隔符
// (artistJoinedKey,两个方向都认);或者候选是「中文名英文名」连写、其中一半跟本地整个名字相等,本地只有那一种文字
// (artistScriptHalves,酷我把「邓紫棋」写成「G.E.M.邓紫棋」)。反过来本地是双语署名、候选只写一半的不认:首轮按双语署名搜出来的
// 常是单曲版、精选集,见 09 章决策 180。比的都是整个名字,不按段求交集。见 09 章决策 280。
func artistNameFormMatches(candidate, query string) bool {
	kc, kq := artistJoinedKey(artistMatchKey(candidate)), artistJoinedKey(artistMatchKey(query))
	if kc == "" || kq == "" {
		return false
	}
	if kc == kq {
		return true
	}
	c, l, ok := artistScriptHalves(kc)
	if !ok {
		return false
	}
	switch {
	case !strings.ContainsFunc(kq, isCJKLetter):
		// 拿拉丁那半去比,至少三个字母:两个字母的名字(「en」)太容易撞上别人。
		return latinLetterCount(l) >= 3 && artistJoinedKey(l) == kq
	case !strings.ContainsFunc(kq, func(r rune) bool { return unicode.In(r, unicode.Latin) }):
		return artistJoinedKey(c) == kq
	}
	return false
}

// foldIterationMark 把跟在汉字后面的「々」换成那个字:中文曲库把「水樹奈々」写成「水树奈奈」、「佐々木」写成
// 「佐佐木」。别的位置的「々」原样留着。
func foldIterationMark(s string) string {
	if !strings.ContainsRune(s, '々') {
		return s
	}
	rs := []rune(s)
	for i := 1; i < len(rs); i++ {
		if rs[i] == '々' && unicode.Is(unicode.Han, rs[i-1]) {
			rs[i] = rs[i-1]
		}
	}
	return string(rs)
}

// parenAliasPart:一段署名「X (Y)」或「X（Y）」,括号里没有再套括号。
var parenAliasPart = regexp.MustCompile(`^(.+?)\s*[(（]([^()（）]+)[)）]\s*$`)

// parenAliasNames:署名里每一段「X (Y)」换成括号里的 Y,其余段原样,用 / 连起来;一段都没换时返回空串。
// 中文曲库常把日文名写成「译名 (原名)」(「水濑祈 (水瀬いのり)」),角色歌也有不带 CV 标记的「角色 (声优)」,
// 括号里的名字拿来再比一次 —— 只当同一位演唱者的另一个名字,不当角色和声优的配对。CV 括号(parseCVCredit 管)
// 和 feat. / with 这类合作者标注不换。
func parenAliasNames(s string) string {
	if !strings.ContainsAny(s, "(（") {
		return ""
	}
	parts := strings.FieldsFunc(s, isArtistCreditMatchSep)
	changed := false
	for i, p := range parts {
		m := parenAliasPart.FindStringSubmatch(strings.TrimSpace(p))
		if m == nil {
			continue
		}
		inner := strings.TrimSpace(m[2])
		if _, cv := trimCVMarker(inner); cv || isCollaboratorNote(inner) {
			continue
		}
		parts[i] = inner
		changed = true
	}
	if !changed {
		return ""
	}
	return strings.Join(parts, "/")
}

// bilingualNameParts:「中文名 英文名」「英文名 中文名」这种同一位演唱者两种写法连在一起的署名(「田馥甄 Hebe Tien」
// 「Anson Lo 卢瀚霆」「八三夭 831」),拆出汉字那段和另一段。s 先过 artistMatchKey。只认按空白切开后一头是一整段汉字
// (至少两个字)、其余每个词都只由拉丁字母、数字和 . ' - 组成的;夹着 feat. / ft. / with / x 这类合作者标记、分隔符,
// 或者汉字不在头尾的,都不算。
func bilingualNameParts(s string) (han, other string, ok bool) {
	if !strings.ContainsAny(s, " \t\u3000") {
		return "", "", false
	}
	fields := strings.Fields(s)
	if len(fields) < 2 {
		return "", "", false
	}
	var hanField string
	var rest []string
	switch {
	case isHanWord(fields[0]):
		hanField, rest = fields[0], fields[1:]
	case isHanWord(fields[len(fields)-1]):
		hanField, rest = fields[len(fields)-1], fields[:len(fields)-1]
	default:
		return "", "", false
	}
	if utf8.RuneCountInString(hanField) < 2 {
		return "", "", false
	}
	for _, f := range rest {
		if !latinNameWord.MatchString(f) || bilingualCollaboratorWords[f] {
			return "", "", false
		}
	}
	return hanField, strings.Join(rest, " "), true
}

// bilingualHanPart:「中文名 英文名」连写的署名里汉字那段(artistMatchKey 的写法);不是这种署名时为空串。
func bilingualHanPart(s string) string {
	han, _, ok := bilingualNameParts(artistMatchKey(s))
	if !ok {
		return ""
	}
	return han
}

// bilingualCollaboratorWords:另一段里出现就说明是合作署名、不是同一个人两种写法的词(已小写)。
var bilingualCollaboratorWords = map[string]bool{"feat": true, "feat.": true, "ft": true, "ft.": true, "with": true, "x": true, "vs": true, "vs.": true, "and": true}

// latinNameWord:拉丁字母或数字写的一个词,首字是字母或数字,结尾不是 - 或 '(「周杰伦-」这类尾巴是仿冒号的写法)。
var latinNameWord = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.'\-]*[a-z0-9.])?$`)

func isHanWord(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.Is(unicode.Han, r) {
			return false
		}
	}
	return true
}

// isCollaboratorNote:括号里写的是合作者(「feat. 某某」「ft. 某某」「with 某某」),不是同一个人的另一个名字。
func isCollaboratorNote(s string) bool {
	l := strings.ToLower(s)
	for _, p := range []string{"feat.", "feat ", "ft.", "ft ", "with "} {
		if strings.HasPrefix(l, p) {
			return true
		}
	}
	return false
}
