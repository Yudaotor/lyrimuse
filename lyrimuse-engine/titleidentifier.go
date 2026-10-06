package main

import (
	"context"
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// 歌名括号里的编号:标明这一首是系列里的第几个、哪一部分、哪一集,或者哪一年重录的。「Song (#6)」和
// 「Song (#11)」去掉括号都是「Song」,却是两首歌。
//
// 缓存 key 照旧按 normEnrichTitle 剥括号,解析流水线(别名轮、标题反查、打分……)也照旧用 key 里的歌名。只有交给各
// 歌词源去搜、去挑候选的那一份换成 lyricSearchTitle:剥到明说第几个的编号那一层就停,编号一路带进各源的搜索词、
// lyricTitleAccepted 和各源挑候选的排序(见 withLyricSourceTitle)。播放器报的歌名里没有这类编号时两者逐字相同。
// 见 09 章决策 196。
type titleIdentifier struct {
	kind  string
	value int
}

var (
	titleIDHashRe   = regexp.MustCompile(`#\s*(\d{1,4})\b`)
	titleIDNumberRe = regexp.MustCompile(`\b(part|partie|pt|volume|vol|episode|ep|chapter|ch|act|no)\.?\s*(\d{1,4}|[ivx]{1,5})\b`)
	titleIDCJKRe    = regexp.MustCompile(`第\s*([0-9]{1,4}|[一二三四五六七八九十百零〇两]{1,4})\s*([集话話回期季章部篇卷幕弹彈])`)
	titleIDBareRe   = regexp.MustCompile(`^\s*([0-9]{1,4}|[ivx]{1,5}|[一二三四五六七八九十]{1,3})\s*$`)
	titleIDHalfRe   = regexp.MustCompile(`^\s*(上|中|下|前篇|後篇|后篇|前編|後編|后编|前编)\s*$`)
	titleIDYearRe   = regexp.MustCompile(`\b((?:19|20)\d{2})\b`)
	// 跟年份同在一个括号里、说明这是哪一年重录的那一版的词。括号里还有 remaster、live 这类词时整段不算(剥不干净,见
	// bracketIdentifiers):重制是同一段录音,现场版另有 versionTagsMismatch / liveAlbumIdentityConflict 管。
	titleIDRerecordRe = regexp.MustCompile(`\bver\b|\bver\.|version|re-?record`)
	// 编号之外括号里还准许剩下的词:说明这是哪一年重录的那几个。
	titleIDFillerRe = regexp.MustCompile(`\bver\b|\bversion\b|\bre-?record(?:ing|ed)?\b|\brecording\b`)
)

// titleIDNumberKinds:titleIDNumberRe 第一组的写法归到哪一类。
var titleIDNumberKinds = map[string]string{
	"part": "part", "partie": "part", "pt": "part",
	"volume": "vol", "vol": "vol",
	"episode": "episode", "ep": "episode",
	"chapter": "chapter", "ch": "chapter",
	"act": "act", "no": "no",
}

// bracketIdentifiers 认一段括号里的编号(inner 不带括号本身)。括号里除了编号只能剩下标点和说明重录的词
// (titleIDFillerRe),还有别的字就是出处、用途这类说明(「第1話〜26話 OP」「《某剧第二季》插曲」
// 「From "X: Vol. 1"」),整段不算;同一类编号出现不止一个(「第78話〜第102話」这种范围)也不算。
func bracketIdentifiers(inner string) []titleIdentifier {
	s := strings.ToLower(foldDiacritics(narrowASCII(inner)))
	out := bracketIdentifierTokens(s)
	if len(out) == 0 {
		return nil
	}
	kinds := map[string]bool{}
	for _, id := range out {
		if kinds[id.kind] {
			return nil
		}
		kinds[id.kind] = true
	}
	rest := s
	for _, re := range []*regexp.Regexp{titleIDHashRe, titleIDNumberRe, titleIDCJKRe, titleIDBareRe, titleIDHalfRe, titleIDYearRe, titleIDFillerRe} {
		rest = re.ReplaceAllString(rest, " ")
	}
	for _, r := range rest {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return nil
		}
	}
	return out
}

// bracketIdentifierTokens 找出 s(已经转小写、半角)里所有像编号的片段,不管括号里还有没有别的字。
func bracketIdentifierTokens(s string) []titleIdentifier {
	var out []titleIdentifier
	for _, m := range titleIDHashRe.FindAllStringSubmatch(s, -1) {
		if n, ok := parseTitleNumber(m[1]); ok {
			out = append(out, titleIdentifier{"hash", n})
		}
	}
	for _, m := range titleIDNumberRe.FindAllStringSubmatch(s, -1) {
		kind := titleIDNumberKinds[m[1]]
		if kind == "no" && !isASCIIDigits(m[2]) {
			continue
		}
		if n, ok := parseTitleNumber(m[2]); ok {
			out = append(out, titleIdentifier{kind, n})
		}
	}
	for _, m := range titleIDCJKRe.FindAllStringSubmatch(s, -1) {
		if n, ok := parseTitleNumber(m[1]); ok {
			out = append(out, titleIdentifier{"第" + m[2], n})
		}
	}
	if m := titleIDBareRe.FindStringSubmatch(s); m != nil && m[1] != "x" {
		if n, ok := parseTitleNumber(m[1]); ok {
			out = append(out, titleIdentifier{"number", n})
		}
	}
	if m := titleIDHalfRe.FindStringSubmatch(s); m != nil {
		out = append(out, titleIdentifier{"half", titleHalfOrder(m[1])})
	}
	if titleIDRerecordRe.MatchString(s) {
		for _, m := range titleIDYearRe.FindAllStringSubmatch(s, -1) {
			n, _ := strconv.Atoi(m[1])
			out = append(out, titleIdentifier{"rerecord", n})
		}
	}
	return out
}

// titleIdentifiers 收一个歌名里所有括号段(parentheticalSegments)的编号。
func titleIdentifiers(title string) []titleIdentifier {
	var out []titleIdentifier
	for _, seg := range parentheticalSegments(title) {
		out = append(out, bracketIdentifiers(seg)...)
	}
	return out
}

// isStrongTitleIdentifier:明说「第几个」的编号。光秃秃的数字(number)、上 / 下(half)说不准是不是编号,不算。
func isStrongTitleIdentifier(id titleIdentifier) bool {
	return id.kind != "number" && id.kind != "half"
}

// hasStrongTitleIdentifier:歌名带着明说「第几个」的编号。带这种编号的歌,完整歌名排在搜索词最前面(searchTitleVariants):
// 系列曲在各家曲库里几乎都连编号一起登记,先拿去掉括号的去搜,结果里常常只有同系列别的号。
func hasStrongTitleIdentifier(title string) bool {
	for _, id := range titleIdentifiers(title) {
		if isStrongTitleIdentifier(id) {
			return true
		}
	}
	return false
}

// bracketHasStrongIdentifier:这段括号(inner 不带括号本身)里有明说第几个的编号。
func bracketHasStrongIdentifier(inner string) bool {
	for _, id := range bracketIdentifiers(inner) {
		if isStrongTitleIdentifier(id) {
			return true
		}
	}
	return false
}

// titleIdentifiersConflict:两个歌名都带某一类编号、而这一类的值没有一个相同,就是两首歌(「#6」对「#11」、「Part 1」
// 对「Part 2」)。只有一边带、两边类别不同,都说不清,不算冲突。
func titleIdentifiersConflict(a, b string) bool {
	ia := titleIdentifiers(a)
	if len(ia) == 0 {
		return false
	}
	ib := titleIdentifiers(b)
	if len(ib) == 0 {
		return false
	}
	va, vb := map[string]map[int]bool{}, map[string]map[int]bool{}
	for _, id := range ia {
		if va[id.kind] == nil {
			va[id.kind] = map[int]bool{}
		}
		va[id.kind][id.value] = true
	}
	for _, id := range ib {
		if vb[id.kind] == nil {
			vb[id.kind] = map[int]bool{}
		}
		vb[id.kind][id.value] = true
	}
	for kind, as := range va {
		bs, ok := vb[kind]
		if !ok {
			continue
		}
		shared := false
		for v := range as {
			if bs[v] {
				shared = true
				break
			}
		}
		if !shared {
			return true
		}
	}
	return false
}

// lyricSearchTitle 是交给各歌词源去搜、去挑候选的歌名:跟 normEnrichTitle 一样从结尾一层层剥括号,碰到版本标记或明说
// 第几个的编号就停。光数字、上 / 下照样剥:说不准是不是编号,带着去搜常常整轮落空。
func lyricSearchTitle(title string) string {
	return trimTrailingBrackets(title, func(inner string) bool {
		return enrichKeyKeepsBracket(inner) || bracketHasStrongIdentifier(inner)
	})
}

// lyricQueryTitle:只拿「歌手 + 歌名」原样当搜索词、没有去括号那一种写法的源用它拼搜索词。歌名带明说第几个的编号时去掉
// 带编号的那几层(搜索词跟按 key 搜的时候一样,不多问一次),搜回来的候选照旧拿带编号的歌名去比。不带时原样返回。
func lyricQueryTitle(title string) string {
	if !hasStrongTitleIdentifier(title) {
		return title
	}
	return normEnrichTitle(title)
}

// lyricTitleSameName:候选歌名跟本地歌名算不算逐字同名(normLoose 相等)。本地歌名带明说第几个的编号时,候选跟去掉编号
// 那几层的本地歌名逐字相同也算:各家常把编号只写在专辑名里,这样的候选跟本地歌名不带编号时一样对待。各源挑候选时
// 「逐字同名」那一档、歌手对不上时的三角判据都用它;编号也对得上的另由 lyricTitleSameNumber 排在前面。
func lyricTitleSameName(candidateTitle, localTitle string) bool {
	nc := normLoose(candidateTitle)
	if nc == normLoose(localTitle) {
		return true
	}
	if !hasStrongTitleIdentifier(localTitle) {
		return false
	}
	return nc == normLoose(normEnrichTitle(localTitle)) || lyricTitleSameNumber(candidateTitle, localTitle)
}

// lyricTitleSameNumber:本地歌名带明说第几个的编号,候选带着同一个号:逐字同名,或者两边去掉结尾括号后同名、本地的每一类编号
// 候选都带着同一个值(「Part I」对「Pt. 1」、「(Episode 1)」对「(Episode 1) (Explicit)」)。各源挑候选时排在只是
// lyricTitleSameName 的前面:不带编号的同名候选可能是同系列别的号。
func lyricTitleSameNumber(candidateTitle, localTitle string) bool {
	if !hasStrongTitleIdentifier(localTitle) {
		return false
	}
	if normLoose(candidateTitle) == normLoose(localTitle) {
		return true
	}
	if normLoose(normEnrichTitle(candidateTitle)) != normLoose(normEnrichTitle(localTitle)) {
		return false
	}
	have := map[titleIdentifier]bool{}
	for _, id := range titleIdentifiers(candidateTitle) {
		have[id] = true
	}
	for _, id := range titleIdentifiers(localTitle) {
		if isStrongTitleIdentifier(id) && !have[id] {
			return false
		}
	}
	return true
}

type lyricSearchTitleCtxKey struct{}

// withLyricSearchTitle 把这首歌的 lyricSearchTitle(按播放器原样标签剥出来的,还没归一化)挂到 ctx 上,交给首次解析 /
// 升级重试 / 重打分 / 周边补全,由它们经 withLyricSourceTitle 换成交给各源的写法。空串不挂。
func withLyricSearchTitle(ctx context.Context, title string) context.Context {
	if title == "" {
		return ctx
	}
	return context.WithValue(ctx, lyricSearchTitleCtxKey{}, title)
}

// lyricSearchTitleFor:ctx 上挂的搜索用歌名是这一首的(剥括号后跟 title 相同)就用它,否则用 title。
func lyricSearchTitleFor(ctx context.Context, title string) string {
	if t, ok := ctx.Value(lyricSearchTitleCtxKey{}).(string); ok && t != "" && normEnrichTitle(t) == normEnrichTitle(title) {
		return t
	}
	return title
}

// lyricSearchTitleWorthStoring:searchTitle 跟 title 是同一首(剥括号后相同)、写法又不一样时返回它,要记进条目
// LyricsSearchTitle;否则返回空串。
func lyricSearchTitleWorthStoring(searchTitle, title string) string {
	if searchTitle != "" && searchTitle != title && normEnrichTitle(searchTitle) == normEnrichTitle(title) {
		return searchTitle
	}
	return ""
}

// lyricSearchTitleToStore:ctx 上挂的搜索用歌名要不要记进条目,见 lyricSearchTitleWorthStoring。
func lyricSearchTitleToStore(ctx context.Context, title string) string {
	return lyricSearchTitleWorthStoring(lyricSearchTitleFor(ctx, title), title)
}

// lyricSearchTitleOrStored:搜歌词用的歌名。ctx 上挂着这一首的就用它,没有就用条目里记下的(LyricsSearchTitle),
// 都没有用 title。
func lyricSearchTitleOrStored(ctx context.Context, stored, title string) string {
	if t := lyricSearchTitleFor(ctx, title); t != title {
		return t
	}
	if t := lyricSearchTitleWorthStoring(stored, title); t != "" {
		return t
	}
	return title
}

type lyricSourceTitleCtxKey struct{}

// withLyricSourceTitle 把交给各歌词源的歌名挂到 ctx 上:searchTitle(lyricSearchTitle,按原样标签剥出来的)经
// searchQueryFields 归一化之后的写法,由 fetchScoredLyricCandidatesStreaming 经 lyricSourceTitleFor 交给各源。
// artist / title / album 是归一化之前的三栏,title 是 key 里的歌名;searchTitle 不是这一首的、或跟 title 相同时原样返回 ctx。
func withLyricSourceTitle(ctx context.Context, searchTitle, artist, title, album string) context.Context {
	if lyricSearchTitleWorthStoring(searchTitle, title) == "" {
		return ctx
	}
	_, q, _ := searchQueryFields(artist, searchTitle, album)
	return context.WithValue(ctx, lyricSourceTitleCtxKey{}, q)
}

// lyricSourceTitleFor:交给各歌词源的歌名。ctx 上挂着的是这一首的(剥括号后跟 title 相同)就用它,否则用 title:别名轮
// 换的是歌手、歌名没变,照样用;拆分、标题反查这类换了歌名的轮次用它们自己的歌名。
func lyricSourceTitleFor(ctx context.Context, title string) string {
	if t, ok := ctx.Value(lyricSourceTitleCtxKey{}).(string); ok && t != title && normEnrichTitle(t) == normEnrichTitle(title) {
		return t
	}
	return title
}

// narrowASCII 把全角的数字、字母、「#」「.」和全角空格换成半角,别的字原样。全角 ASCII 那一段(U+FF01~U+FF5E)跟半角
// 差一个固定的偏移 0xFEE0。
func narrowASCII(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= '０' && r <= '９', r >= 'Ａ' && r <= 'Ｚ', r >= 'ａ' && r <= 'ｚ', r == '＃', r == '．':
			return r - 0xFEE0
		case r == '\u3000':
			return ' '
		}
		return r
	}, s)
}

func isASCIIDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// parseTitleNumber 认阿拉伯数字、小写罗马数字(i~xx 这一段)、中文数字(一~九十九,含零、两、百)。
func parseTitleNumber(s string) (int, bool) {
	if isASCIIDigits(s) {
		n, err := strconv.Atoi(s)
		return n, err == nil
	}
	if n, ok := parseRomanNumber(s); ok {
		return n, true
	}
	return parseChineseNumber(s)
}

func parseRomanNumber(s string) (int, bool) {
	vals := map[rune]int{'i': 1, 'v': 5, 'x': 10}
	total, prev := 0, 0
	rs := []rune(s)
	for i := len(rs) - 1; i >= 0; i-- {
		v, ok := vals[rs[i]]
		if !ok {
			return 0, false
		}
		if v < prev {
			total -= v
		} else {
			total += v
			prev = v
		}
	}
	return total, total > 0
}

func parseChineseNumber(s string) (int, bool) {
	digits := map[rune]int{'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
	total, cur := 0, 0
	seen := false
	for _, r := range s {
		switch {
		case r == '十':
			if cur == 0 {
				cur = 1
			}
			total += cur * 10
			cur = 0
		case r == '百':
			if cur == 0 {
				cur = 1
			}
			total += cur * 100
			cur = 0
		default:
			d, ok := digits[r]
			if !ok {
				return 0, false
			}
			cur = d
		}
		seen = true
	}
	return total + cur, seen
}

// titleHalfOrder:上 / 前篇 = 1,中 = 2,下 / 后篇 = 3。
func titleHalfOrder(s string) int {
	switch s {
	case "上", "前篇", "前編", "前编":
		return 1
	case "中":
		return 2
	}
	return 3
}
