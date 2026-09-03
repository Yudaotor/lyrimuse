// lyricsgolden_scramble_test.go — 金标样本的**保形置乱**(见 lyricsgolden_test.go 头注第三段)。
//
// 目标:样本里不出现任何一句能读的歌词,但打分链路读到的每一个特征跟原文逐位相同。做法是
// **同一首歌内一致的字符双射**:
//   - 汉字 → CJK 扩展 A 区(U+3400–U+4DBF)的汉字。\p{Han} / unicode.Han / unicode.IsLetter 对它们
//     全部为真,所以 cjkRatio / genericHanCreditLineRe / normLoose 的判定不变;真实歌词几乎不用
//     这一区的字,于是"正文里出现了基本区汉字"就能当作"混进了明文"的探针(goldenFindUnscrambledLine);
//     池子刻意剔掉 OpenCC 繁→简词典和异体字表里出现过的字,保证 toSimplified 对置乱后的文本是恒等;
//   - 拉丁字母 → a–z 上的一个置换,大写跟着小写走(ToLower 与置乱可交换);
//   - 平假名 / 片假名 → 各自块内置换(kanaRatio 的范围判定不变);谚文 → 音节块内置换;
//   - 数字、标点、空白、其它文字:原样。
//
// 置乱之前先做一次 toSimplified + foldDiacritics(canon):normLoose 内部会做同样的归一,先归一
// 再置乱,置乱后的文本对 normLoose 来说就是"已经归一好了的",3-gram 集合与原文的 3-gram 集合一一
// 对应,Jaccard 逐位相同。
//
// 哪些不置乱(打分把它们当结构而不是正文读,改了就会改变判定,而且它们本来也不是歌词):
//   - LRC 时间戳、YRC 的 [行始,行长] 与 (词始,词长,0);
//   - 元数据标签行([ti:]/[ar:]/[offset:]…);[kana:…] 行只置乱方括号里的内容;
//   - 行首的「标签 + 冒号」(演唱者标签「男：」「v1：」、署名「作词：」——lyricSplitLabel /
//     creditLineRe / genericHanCreditLineRe 都只看这一段);
//   - 含「纯音乐」占位文案的整行。
//
// 采集器(lyricsgolden_capture_test.go)在写样本之前会用置乱前后的 rankLyricSourceResults 结果
// 逐项比对,任何一项不同都拒绝入库——这份保形是被验证的,不是被相信的。
package main

import (
	"hash/fnv"
	"math/rand"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode"
)

// ---------- 字符池 ----------

const (
	goldenHanPoolLo      = 0x3400 // CJK 扩展 A 区起点
	goldenHanPoolHi      = 0x4DBF
	goldenHiraganaLo     = 0x3041
	goldenHiraganaHi     = 0x3096
	goldenKatakanaLo     = 0x30A1
	goldenKatakanaHi     = 0x30FA
	goldenHangulLo       = 0xAC00
	goldenHangulHi       = 0xD7A3
	goldenScrambleMarker = "纯音乐"
)

// goldenHanPool 返回扩展 A 区里**不在**任何繁→简词典 / 异体字表出现过的字,按码位升序。
//
// ⚠️ 必须是惰性的(sync.Once),不能写成包级 var 的初始化表达式:t2sCharMap 等词典是在 t2s.go 的
// init() 里填的,而包级 var 初始化跑在所有 init() 之前——那时三张表还是 nil,"剔除词典字"会静默
// 变成什么都不剔(第一版就是这么写的,TestGoldenHanPoolIsSimplifiedStable 当场抓到 U+346E)。
var goldenHanPoolOnce sync.Once
var goldenHanPoolCache []rune

func goldenHanPool() []rune {
	goldenHanPoolOnce.Do(func() { goldenHanPoolCache = buildGoldenHanPool() })
	return goldenHanPoolCache
}

func buildGoldenHanPool() []rune {
	forbidden := map[rune]bool{}
	for k, v := range t2sCharMap {
		for _, r := range k + v {
			forbidden[r] = true
		}
	}
	for k, v := range t2sPhraseMap {
		for _, r := range k + v {
			forbidden[r] = true
		}
	}
	for k, v := range hanVariantMap {
		forbidden[k] = true
		forbidden[v] = true
	}
	var pool []rune
	for r := rune(goldenHanPoolLo); r <= goldenHanPoolHi; r++ {
		if forbidden[r] || !unicode.Is(unicode.Han, r) || !unicode.IsLetter(r) {
			continue
		}
		pool = append(pool, r)
	}
	return pool
}

func goldenRangePool(lo, hi rune) []rune {
	pool := make([]rune, 0, hi-lo+1)
	for r := lo; r <= hi; r++ {
		pool = append(pool, r)
	}
	return pool
}

// ---------- 字符分类 ----------

type goldenRuneClass int

const (
	goldenClassOther goldenRuneClass = iota
	goldenClassHan
	goldenClassLatin // 已折叠成 ASCII 的小写形式参与映射,大写跟着走
	goldenClassHiragana
	goldenClassKatakana
	goldenClassHangul
)

func goldenClassify(r rune) goldenRuneClass {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z':
		return goldenClassLatin
	case r >= goldenHiraganaLo && r <= goldenHiraganaHi:
		return goldenClassHiragana
	case r >= goldenKatakanaLo && r <= goldenKatakanaHi:
		return goldenClassKatakana
	case r >= goldenHangulLo && r <= goldenHangulHi:
		return goldenClassHangul
	case unicode.Is(unicode.Han, r):
		return goldenClassHan
	}
	return goldenClassOther
}

// ---------- 分段:哪些字符该置乱 ----------

type goldenSeg struct {
	text     string
	scramble bool
}

var goldenLRCStampPrefixRe = regexp.MustCompile(`^(?:\[\d{1,2}:\d{2}[.:]\d{1,3}\])+`)
var goldenYRCHeadRe = regexp.MustCompile(`^\[\d+,\d+\]`)
var goldenYRCWordRe = regexp.MustCompile(`\(\d+,\d+(?:,\d+)?\)`)

// goldenSegmentLRCLine 把一行 LRC(歌词 / 译文 / 罗马音都是这个形状)切成"原样 / 置乱"两类段。
func goldenSegmentLRCLine(line string) []goldenSeg {
	var segs []goldenSeg
	keep := func(s string) {
		if s != "" {
			segs = append(segs, goldenSeg{text: s})
		}
	}
	scramble := func(s string) {
		if s != "" {
			segs = append(segs, goldenSeg{text: s, scramble: true})
		}
	}
	rest := line
	// BOM / 前导空白原样。
	lead := 0
	for _, r := range rest {
		if r == '\uFEFF' || unicode.IsSpace(r) {
			lead += len(string(r))
			continue
		}
		break
	}
	keep(rest[:lead])
	rest = rest[lead:]
	// 时间戳前缀。
	if m := goldenLRCStampPrefixRe.FindString(rest); m != "" {
		keep(m)
		rest = rest[len(m):]
	}
	trimmed := strings.TrimSpace(rest)
	if trimmed == "" {
		keep(rest)
		return segs
	}
	if isLRCMetaTagLine(trimmed) {
		lower := strings.ToLower(trimmed)
		if strings.HasPrefix(lower, "[kana:") && strings.HasSuffix(trimmed, "]") {
			start := strings.Index(rest, "[")
			head := rest[:start+len("[kana:")]
			tail := rest[strings.LastIndex(rest, "]"):]
			keep(head)
			scramble(rest[len(head) : len(rest)-len(tail)])
			keep(tail)
			return segs
		}
		keep(rest)
		return segs
	}
	if strings.Contains(trimmed, goldenScrambleMarker) {
		keep(rest)
		return segs
	}
	// 行首「标签+冒号」怎么处理,取决于打分怎么读它(见文件头注):
	//   - 演唱者标记(男：/v1：)——lyricConsensusBody 只取冒号后的正文,标签原样、正文置乱;
	//   - 内容决定分类的标签(署名关键词、乐器/职能词根、代词虚词、精确署名表)——它们的判定读的是
	//     字面(lyricPlausibleSpeakerName / creditLineRe / lyricExactCreditLabels),置乱会翻转判定,
	//     标签原样;这类行几乎都是署名行,整行会被共识比对丢掉,正文置不置乱都不影响特征,置乱只为少漏
	//     人名;
	//   - 其它标签(人名、普通英文词)——分类只看形状(汉字数、有没有字母/标点),置乱保形,**整行连标签
	//     一起置乱**。这里不能像第一版那样"标签一律原样":原样标签与置乱正文的接缝会造出原文里没有的
	//     3-gram(或反过来抹掉重复),3-gram 集合基数一变 Jaccard 就漂——实测《躺在你的衣柜》netease
	//     0.559→0.544 跨过 0.55 阈值丢了 100 分共识,采集闸 3 当场拦下。
	if label, _, ok := lyricSplitLabel(trimmed); ok {
		if lyricKnownSpeakerSet[label] || !lyricPlausibleSpeakerName(label) {
			off := strings.Index(rest, trimmed)
			n := goldenLabelPrefixLen(trimmed)
			keep(rest[:off+n])
			scramble(rest[off+n:])
			return segs
		}
	} else if m := creditLineRe.FindStringIndex(trimmed); m != nil {
		// 「作词 : 某某」——标签与冒号之间有空格,lyricSplitLabel 认不出,creditLineRe 认得出。
		off := strings.Index(rest, trimmed)
		keep(rest[:off+m[1]])
		scramble(rest[off+m[1]:])
		return segs
	}
	scramble(rest)
	return segs
}

// goldenLabelPrefixLen 返回 trimmed 行首「标签+冒号」的字节长度(调用方已确认 lyricSplitLabel 认得出)。
func goldenLabelPrefixLen(trimmed string) int {
	for i, r := range trimmed {
		if r == ':' || r == '：' {
			return i + len(string(r))
		}
	}
	return 0
}

// goldenSegmentYRCLine:YRC 行只置乱词文本,[行始,行长] 与 (词始,词长,0) 原样;词文本本身是
// 「标签+冒号」形态(v1：/男：)时也原样。不是 YRC 行(元数据标签、[kana:] 等)交给 LRC 分段。
func goldenSegmentYRCLine(line string) []goldenSeg {
	trimmedLead := strings.TrimLeft(line, "\uFEFF \t")
	if strings.HasPrefix(trimmedLead, "{") {
		// 网易云 YRC 开头的 JSON 元数据行({"t":…,"c":[{"tx":"作词: "},…]}):署名与链接,不是歌词,
		// 打分也不读(lastYRCTimestampMs 只认 [行始,行长] 开头的行)。原样保留,别把 JSON 键和
		// URL 也置乱成乱码。
		return []goldenSeg{{text: line}}
	}
	if !goldenYRCHeadRe.MatchString(trimmedLead) {
		return goldenSegmentLRCLine(line)
	}
	var segs []goldenSeg
	rest := line
	head := goldenYRCHeadRe.FindStringIndex(strings.TrimLeft(line, "\uFEFF \t"))
	lead := len(line) - len(strings.TrimLeft(line, "\uFEFF \t"))
	segs = append(segs, goldenSeg{text: rest[:lead+head[1]]})
	rest = rest[lead+head[1]:]
	for rest != "" {
		m := goldenYRCWordRe.FindStringIndex(rest)
		if m == nil {
			segs = append(segs, goldenYRCTextSeg(rest))
			break
		}
		if m[0] > 0 {
			segs = append(segs, goldenYRCTextSeg(rest[:m[0]]))
		}
		segs = append(segs, goldenSeg{text: rest[m[0]:m[1]]})
		rest = rest[m[1]:]
	}
	return segs
}

func goldenYRCTextSeg(s string) goldenSeg {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" || strings.Contains(trimmed, goldenScrambleMarker) {
		return goldenSeg{text: s}
	}
	if label, rest, ok := lyricSplitLabel(trimmed); ok && rest == "" && (lyricKnownSpeakerSet[label] || !lyricPlausibleSpeakerName(label)) {
		return goldenSeg{text: s} // 独立的「v1：」词元
	}
	return goldenSeg{text: s, scramble: true}
}

func goldenSegmentText(text string, yrc bool) [][]goldenSeg {
	lines := strings.Split(text, "\n")
	out := make([][]goldenSeg, 0, len(lines))
	for _, line := range lines {
		// CRLF 的 \r 挂在行尾,当空白原样保留。
		if yrc {
			out = append(out, goldenSegmentYRCLine(line))
		} else {
			out = append(out, goldenSegmentLRCLine(line))
		}
	}
	return out
}

// goldenCanon:置乱前的归一,与 normLoose 内部的 toSimplified + foldDiacritics 同一口径(不含 ToLower,
// 大小写由映射自己保持)。
func goldenCanon(s string) string {
	return foldDiacritics(toSimplified(s))
}

// ---------- 映射 ----------

type goldenScrambler struct {
	han, hira, kata, hangul map[rune]rune
	latin                   [26]rune
}

// newGoldenScrambler 扫一遍 texts(每个元素 = 文本 + 是不是 YRC)里所有会被置乱的段,给出现过的每个
// 字符分配替身。seed 只决定分配顺序,同一 seed 同一输入结果确定。
func newGoldenScrambler(seed string, texts []goldenText) *goldenScrambler {
	h := fnv.New64a()
	h.Write([]byte(seed))
	rng := rand.New(rand.NewSource(int64(h.Sum64())))

	present := map[goldenRuneClass]map[rune]bool{
		goldenClassHan: {}, goldenClassHiragana: {}, goldenClassKatakana: {}, goldenClassHangul: {},
	}
	for _, t := range texts {
		for _, segs := range goldenSegmentText(t.text, t.yrc) {
			for _, seg := range segs {
				if !seg.scramble {
					continue
				}
				for _, r := range goldenCanon(seg.text) {
					c := goldenClassify(r)
					if m, ok := present[c]; ok {
						m[r] = true
					}
				}
			}
		}
	}
	assign := func(set map[rune]bool, pool []rune) map[rune]rune {
		src := make([]rune, 0, len(set))
		for r := range set {
			src = append(src, r)
		}
		sort.Slice(src, func(i, j int) bool { return src[i] < src[j] })
		shuffled := append([]rune(nil), pool...)
		rng.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })
		m := make(map[rune]rune, len(src))
		for i, r := range src {
			if i < len(shuffled) {
				m[r] = shuffled[i]
			} else {
				m[r] = r // 池子不够(一首歌不可能),退回原样
			}
		}
		return m
	}
	s := &goldenScrambler{
		han:    assign(present[goldenClassHan], goldenHanPool()),
		hira:   assign(present[goldenClassHiragana], goldenRangePool(goldenHiraganaLo, goldenHiraganaHi)),
		kata:   assign(present[goldenClassKatakana], goldenRangePool(goldenKatakanaLo, goldenKatakanaHi)),
		hangul: assign(present[goldenClassHangul], goldenRangePool(goldenHangulLo, goldenHangulHi)),
	}
	perm := rng.Perm(26)
	for i, p := range perm {
		s.latin[i] = rune('a' + p)
	}
	return s
}

type goldenText struct {
	text string
	yrc  bool
}

func (s *goldenScrambler) mapRune(r rune) rune {
	switch goldenClassify(r) {
	case goldenClassLatin:
		if r >= 'A' && r <= 'Z' {
			return unicode.ToUpper(s.latin[r-'A'])
		}
		return s.latin[r-'a']
	case goldenClassHan:
		if m, ok := s.han[r]; ok {
			return m
		}
	case goldenClassHiragana:
		if m, ok := s.hira[r]; ok {
			return m
		}
	case goldenClassKatakana:
		if m, ok := s.kata[r]; ok {
			return m
		}
	case goldenClassHangul:
		if m, ok := s.hangul[r]; ok {
			return m
		}
	}
	return r
}

func (s *goldenScrambler) scrambleSeg(text string) string {
	var b strings.Builder
	for _, r := range goldenCanon(text) {
		b.WriteRune(s.mapRune(r))
	}
	return b.String()
}

func (s *goldenScrambler) scrambleText(text string, yrc bool) string {
	if text == "" {
		return ""
	}
	lines := goldenSegmentText(text, yrc)
	var b strings.Builder
	for i, segs := range lines {
		if i > 0 {
			b.WriteByte('\n')
		}
		for _, seg := range segs {
			if seg.scramble {
				b.WriteString(s.scrambleSeg(seg.text))
			} else {
				b.WriteString(seg.text)
			}
		}
	}
	return b.String()
}

// scrambleLyricRound 对一整轮各源原始应答做一致置乱。只动歌词类文本;标题/歌手/专辑/封面/时长/
// 语种/标记全部原样(它们是元数据,打分按原文比对,也不是版权正文)。
func scrambleLyricRound(raw map[string]lyricSourceResult, seed string) map[string]lyricSourceResult {
	var texts []goldenText
	for _, r := range raw {
		texts = append(texts,
			goldenText{r.lyr, false}, goldenText{r.yrc, true}, goldenText{r.tr, false}, goldenText{r.roma, false},
			goldenText{r.ne.Lyrics, false}, goldenText{r.ne.Trans, false}, goldenText{r.ne.Roma, false}, goldenText{r.ne.YRC, true},
			goldenText{r.amll.lrc, false}, goldenText{r.amll.yrc, true}, goldenText{r.amll.tr, false},
		)
	}
	// texts 的顺序会影响 present 集合的收集顺序?不会——集合是 map,分配前统一排序。
	s := newGoldenScrambler(seed, texts)
	out := make(map[string]lyricSourceResult, len(raw))
	for src, r := range raw {
		r.lyr = s.scrambleText(r.lyr, false)
		r.yrc = s.scrambleText(r.yrc, true)
		r.tr = s.scrambleText(r.tr, false)
		r.roma = s.scrambleText(r.roma, false)
		r.ne.Lyrics = s.scrambleText(r.ne.Lyrics, false)
		r.ne.Trans = s.scrambleText(r.ne.Trans, false)
		r.ne.Roma = s.scrambleText(r.ne.Roma, false)
		r.ne.YRC = s.scrambleText(r.ne.YRC, true)
		r.amll.lrc = s.scrambleText(r.amll.lrc, false)
		r.amll.yrc = s.scrambleText(r.amll.yrc, true)
		r.amll.tr = s.scrambleText(r.amll.tr, false)
		out[src] = r
	}
	return out
}

// ---------- 明文探针 ----------

// goldenCommonEnglish:置乱后的拉丁文本不可能整词命中这些高频词;命中 ≥3 个不同的词就当明文。
var goldenCommonEnglish = map[string]bool{
	"the": true, "you": true, "and": true, "love": true, "that": true, "with": true,
	"your": true, "this": true, "have": true, "what": true, "never": true, "when": true,
}

// goldenFindUnscrambledLine 在**会被置乱的段**里找明文迹象:基本区(非扩展 A)的汉字,或整段英文
// 高频词。返回第一条可疑的行。
func goldenFindUnscrambledLine(text string) (string, bool) {
	if text == "" {
		return "", false
	}
	yrc := false
	for _, line := range strings.Split(text, "\n") {
		if goldenYRCHeadRe.MatchString(strings.TrimLeft(line, "\uFEFF \t")) {
			yrc = true
			break
		}
	}
	for _, line := range strings.Split(text, "\n") {
		var segs []goldenSeg
		if yrc {
			segs = goldenSegmentYRCLine(line)
		} else {
			segs = goldenSegmentLRCLine(line)
		}
		hits := map[string]bool{}
		for _, seg := range segs {
			if !seg.scramble {
				continue
			}
			for _, r := range seg.text {
				if unicode.Is(unicode.Han, r) && !(r >= goldenHanPoolLo && r <= goldenHanPoolHi) {
					return line, true
				}
			}
			for _, w := range strings.FieldsFunc(strings.ToLower(seg.text), func(r rune) bool { return !unicode.IsLetter(r) }) {
				if goldenCommonEnglish[w] {
					hits[w] = true
				}
			}
		}
		if len(hits) >= 3 {
			return line, true
		}
	}
	return "", false
}
