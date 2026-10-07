package main

import (
	"log"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// 烘进正文的逐行译文。
//
// 起因:现象是 PRINCE《Diamonds and Pearls (2023 Remaster)》匹配错了,追下去发现 QQ 那条正确候选
// 的**正文**长这样(上传者用「krc转qrc工具」把中文译文直接烘进了歌词):
//
//	[00:36.08]This will be the day
//	[00:38.34]这将是我们约定的日子
//	[00:39.00]That you will hear me say
//	[00:41.30]你会听见我郑重承诺
//
// 每句英文后面紧跟一行**独立时间戳**的中文译文,QRC 逐字轨里同样有这些行(每个汉字 66ms 的假计时)。
// 后果有三层:①共识——正文里一半是中文,跟 lrclib/musixmatch 的纯英文正文 3-gram 相似度只有 0.41,
// 拿不到 150~250 的共识分,而冠亚军分差中位只有 22 分;②行数——118 行里 59 行是译文,+1/行 的行数分
// 虚高;③显示——App 把它当歌词逐行播,用户看到英中交替,悬浮窗逐字填色也会在中文行上跑一遍假计时。
// 引擎明明有 lyrics_tr 这条专门放译文的轨,这份数据只是放错了地方。
//
// 做法:候选装配前(rankLyricSourceResults)把这种形态识别出来,中文行从正文与逐字轨里摘掉、改挂到
// 原文行的时间戳上放进 lyrics_tr(App 侧译文按 700ms 最近邻贴行,所以译文行必须复用原文行的时间戳,
// 不能留上传者那个偏 2 秒的戳)。
//
// 判据刻意保守——误伤的代价是把一首**真的**中英双语歌的中文歌词降级成译文:
//   - 这首歌得是外文歌:本地标签(歌手+歌名)不含汉字,或者原文行里过半带假名/谚文(日韩歌常用汉字
//     标歌名,不能靠标签判);
//   - 外文行(F)与纯汉字行(H)各 ≥ 8 行,H/F 在 0.7~1.3 之间(逐句对译才会一比一);
//   - ≥ 80% 的 H 行紧跟在一个 F 行后面(逐句交替)。
//
// 拿用户 3481 条缓存里的**冠军**正文扫过:F、H 各 ≥8 行的有 351 条,其中"紧跟比例"最高的
// 是 0.67(茜拉班级《日出》,真的中英混唱),没有一条 ≥0.8——真双语歌的中文行跟英文行是段落级
// 交错,不是逐句一比一。阈值 0.8 与实测最高值之间有 0.13 的余量。
//
// 只处理"外文原文 + 中文译文"这一种方向:中文平台的上传者烘进去的几乎只有中文;反过来(中文歌烘英文译文)
// 没见过实例,不猜。

// yrcWordTimingRe 匹配 YRC 行里每个词前面的 (起始,时长[,0]) 计时段。
var yrcWordTimingRe = regexp.MustCompile(`\(\d+,\d+(?:,\d+)?\)`)

const (
	bakedTranslationMinLines   = 8
	bakedTranslationMinRatio   = 0.7
	bakedTranslationMaxRatio   = 1.3
	bakedTranslationMinPaired  = 0.8
	bakedTranslationYRCSlackMs = 80
)

type bakedLineClass int

const (
	bakedLineSkip    bakedLineClass = iota // 空行 / 元数据标签 / 署名 / 无时间戳
	bakedLineForeign                       // 外文原文行:含假名/谚文,或 ≥2 个拉丁字母且不含汉字
	bakedLineHan                           // 纯汉字行:≥2 个汉字,不含拉丁字母/假名/谚文
	bakedLineMixed                         // 其它(中英混杂、纯数字/标点等)
)

type bakedLine struct {
	raw     string
	stamps  string // 行首全部时间戳原文,如 "[00:36.08]"
	text    string
	class   bakedLineClass
	startMs int  // 第一个时间戳,毫秒;-1 = 无
	jk      bool // 外文行里含假名/谚文
}

func classifyBakedLine(line string) bakedLine {
	bl := bakedLine{raw: line, startMs: -1}
	m := lrcTimestampCaptureRe.FindAllStringSubmatchIndex(line, -1)
	if len(m) == 0 {
		bl.class = bakedLineSkip
		return bl
	}
	// 只认行首连续的时间戳;正文中间夹的方括号不当时间戳看。
	end := 0
	for _, mm := range m {
		if strings.TrimSpace(line[end:mm[0]]) != "" {
			break
		}
		end = mm[1]
	}
	if end == 0 {
		bl.class = bakedLineSkip
		return bl
	}
	bl.stamps = line[:end]
	bl.text = strings.TrimSpace(line[end:])
	if first := lrcTimestampCaptureRe.FindStringSubmatch(bl.stamps); first != nil {
		mm, _ := strconv.Atoi(first[1])
		ss, _ := strconv.Atoi(first[2])
		frac, _ := strconv.Atoi(first[3])
		switch len(first[3]) {
		case 1:
			frac *= 100
		case 2:
			frac *= 10
		}
		bl.startMs = mm*60000 + ss*1000 + frac
	}
	if bl.text == "" || isLRCMetaTagLine(bl.text) || isCreditLine(bl.text) {
		bl.class = bakedLineSkip
		return bl
	}
	bl.class, bl.jk = classifyBakedText(bl.text)
	return bl
}

// classifyBakedText 按一行文字的字符构成分类(见 bakedLineClass),返回类别与是否含假名/谚文。
// 正文与逐字轨摘译文都按它认译文行,两边必须同一个口径。
func classifyBakedText(text string) (bakedLineClass, bool) {
	han, latin, jk := 0, 0, 0
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case r < 0x80 && unicode.IsLetter(r):
			latin++
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r), unicode.Is(unicode.Hangul, r):
			jk++
		}
	}
	switch {
	case jk > 0:
		return bakedLineForeign, true
	case latin >= 2 && han == 0:
		return bakedLineForeign, false
	case han >= 2 && latin == 0:
		return bakedLineHan, false
	default:
		return bakedLineMixed, false
	}
}

// splitBakedTranslation 识别"外文原文 + 逐行中文译文烘在一起"的正文。命中时返回摘掉译文的正文、
// 挂回原文行时间戳的译文 LRC、摘掉对应行的逐字轨,以及摘掉的译文行数;不命中时原样返回、n=0。
// foreignSong:本地标签(歌手+歌名)不含汉字。
func splitBakedTranslation(lyrics, yrc string, foreignSong bool) (cleanLRC, trLRC, cleanYRC string, n int) {
	if lyrics == "" {
		return lyrics, "", yrc, 0
	}
	lines := splitLyricLines(lyrics)
	parsed := make([]bakedLine, len(lines))
	foreign, han, jkForeign, paired := 0, 0, 0, 0
	prevClass := bakedLineSkip
	for i, l := range lines {
		parsed[i] = classifyBakedLine(l)
		c := parsed[i].class
		switch c {
		case bakedLineForeign:
			foreign++
			if parsed[i].jk {
				jkForeign++
			}
		case bakedLineHan:
			han++
			if prevClass == bakedLineForeign {
				paired++
			}
		}
		if c != bakedLineSkip {
			prevClass = c
		}
	}
	if foreign < bakedTranslationMinLines || han < bakedTranslationMinLines {
		return lyrics, "", yrc, 0
	}
	ratio := float64(han) / float64(foreign)
	if ratio < bakedTranslationMinRatio || ratio > bakedTranslationMaxRatio {
		return lyrics, "", yrc, 0
	}
	if float64(paired) < bakedTranslationMinPaired*float64(han) {
		return lyrics, "", yrc, 0
	}
	if !foreignSong && 2*jkForeign < foreign {
		return lyrics, "", yrc, 0
	}

	// 摘译文:每个 H 行挂到它前面最近那个 F 行的时间戳上;同一 F 行下连续多行译文合成一行。
	// 上面的判定只数纯汉字行;判定成立之后,紧跟在 F 行后面、夹着照搬原文专名的混合行
	// (bakedMixedTranslationOf)同样按译文摘,译文轨的版权 / 译者声明(isTranslationNotice)直接丢掉。
	var clean, tr []string
	removedMs := map[int]bool{}
	removedText := map[string]bool{}
	lastStamps, lastForeign := "", ""
	prevClass = bakedLineSkip
	trText := map[string]string{} // stamps -> 译文
	var trOrder []string
	for _, bl := range parsed {
		class := bl.class
		if class == bakedLineMixed {
			if isTranslationNotice(bl.text) {
				removedText[normLoose(bl.text)] = true
				continue
			}
			if prevClass == bakedLineForeign && bakedMixedTranslationOf(bl.text, lastForeign) {
				class = bakedLineHan
			}
		}
		if class != bakedLineSkip {
			prevClass = class
		}
		switch class {
		case bakedLineHan:
			n++
			if bl.startMs >= 0 {
				removedMs[bl.startMs] = true
			}
			removedText[normLoose(bl.text)] = true
			stamps := lastStamps
			if stamps == "" {
				stamps = bl.stamps
			}
			if prev, ok := trText[stamps]; ok {
				trText[stamps] = prev + " " + bl.text
			} else {
				trText[stamps] = bl.text
				trOrder = append(trOrder, stamps)
			}
			continue
		case bakedLineForeign:
			lastStamps, lastForeign = bl.stamps, bl.text
		}
		clean = append(clean, bl.raw)
	}
	for _, stamps := range trOrder {
		tr = append(tr, stamps+trText[stamps])
	}
	cleanLRC = strings.Join(clean, "\n")
	trLRC = strings.Join(tr, "\n")
	cleanYRC = stripBakedYRCLines(yrc, removedMs, removedText)
	return cleanLRC, trLRC, cleanYRC, n
}

// bakedLatinWordRe:译文里夹着的拉丁字母词(歌名、人名这类照搬原文的专名)。
var bakedLatinWordRe = regexp.MustCompile(`[A-Za-z][A-Za-z0-9'’]*`)

// bakedMixedTranslationOf:一行中英混杂的文字是不是 foreign 这句原文的译文 —— 夹着的拉丁字母词全都
// 出现在这句原文里(不区分大小写),去掉它们之后剩下的是纯汉字行。只在整首已经判定为烘入译文之后用,
// 不参与判定本身的计数。
func bakedMixedTranslationOf(text, foreign string) bool {
	words := bakedLatinWordRe.FindAllString(text, -1)
	if len(words) == 0 || foreign == "" {
		return false
	}
	have := map[string]bool{}
	for _, w := range bakedLatinWordRe.FindAllString(foreign, -1) {
		have[strings.ToLower(w)] = true
	}
	for _, w := range words {
		if !have[strings.ToLower(w)] {
			return false
		}
	}
	class, _ := classifyBakedText(bakedLatinWordRe.ReplaceAllString(text, ""))
	return class == bakedLineHan
}

// stripBakedYRCLines 把逐字轨里对应被摘掉的译文行删掉:按行起始毫秒对(±80ms)且这一行自己也是
// 纯汉字行,或者词文本拼接后的归一形态对上。只按时间对不行:译文行紧挨着下一句原文(实测相差 60ms),
// 原文行也落在窗口里(见 09 章决策 129)。
func stripBakedYRCLines(yrc string, removedMs map[int]bool, removedText map[string]bool) string {
	if yrc == "" || (len(removedMs) == 0 && len(removedText) == 0) {
		return yrc
	}
	lines := strings.Split(yrc, "\n")
	kept := make([]string, 0, len(lines))
	for _, l := range lines {
		m := yrcLineTimeRegex.FindStringSubmatch(l)
		if m == nil {
			kept = append(kept, l)
			continue
		}
		start, _ := strconv.Atoi(m[1])
		raw := strings.TrimSpace(yrcWordTimingRe.ReplaceAllString(l[len(m[0]):], ""))
		drop := false
		if class, _ := classifyBakedText(raw); class == bakedLineHan {
			for ms := range removedMs {
				if d := ms - start; d <= bakedTranslationYRCSlackMs && d >= -bakedTranslationYRCSlackMs {
					drop = true
					break
				}
			}
		}
		if !drop {
			text := normLoose(raw)
			if text != "" && removedText[text] {
				drop = true
			}
		}
		if !drop {
			kept = append(kept, l)
		}
	}
	return strings.Join(kept, "\n")
}

// adoptBakedTranslation 是候选装配处的入口:命中就摘,译文轨为空时把摘出来的译文接上(语言固定中文,
// 所以只给译文轨本来就是中文语义的源用——netease/qq/kugou;musixmatch/amll 的译文语言跟设置走,
// 调用方传 acceptTr=false,只摘不接)。返回 (正文, 译文, 逐字轨, 摘掉的行数)。
func adoptBakedTranslation(lyr, tr, yrc string, foreignSong, acceptTr bool) (string, string, string, int) {
	clean, bakedTr, cleanYRC, n := splitBakedTranslation(lyr, yrc, foreignSong)
	if n == 0 {
		return lyr, tr, yrc, 0
	}
	if acceptTr && tr == "" {
		tr = bakedTr
	}
	return clean, tr, cleanYRC, n
}

// ---- 酷我:译文行挂在下一句的时间戳上 ----
//
// 酷我网页接口的正文里,原文行后面跟一行中文译文,时间戳是**下一句**原文的(见 kuwo.go),所以跟紧接着的那一行
// 同一个时间戳。上面的整首判断只数纯汉字行、按全曲比例判:译文只覆盖一段外文的中文歌、拟声行多的外文歌都判不成;
// 判成了的歌里,单字译文(「我」「噢」)和夹着原文里没有的字母的译文也留在正文里。这里按这个时间戳形状逐行认。
// 只给酷我用:别的源没见过这种烘法,QQ 有「男：」这种标签行挂在下一句的时间戳上,形状相同、不是译文。见 09 章决策 201。

// sharedStampMinLines:还不知道这首带烘入译文时,至少要认到这么多行(原文是拟声行的不算)才摘。
const sharedStampMinLines = 4

// adoptKuwoBakedTranslation 是酷我候选装配处的入口:先走整首判断,剩下的再逐行认(整首判断摘过的,剩一行也摘)。
// 返回 (正文, 译文, 摘掉的行数)。逐字轨不经过这里,见 kuwolrcx.go。
func adoptKuwoBakedTranslation(lyr string, foreignSong bool) (string, string, int) {
	clean, tr, _, n := adoptBakedTranslation(lyr, "", "", foreignSong, true)
	rest, more, m := splitSharedStampTranslation(clean, n > 0)
	if m == 0 {
		return clean, tr, n
	}
	return rest, mergeBakedTranslationLRC(tr, more), n + m
}

// splitSharedStampTranslation 逐行认酷我烘法的译文行:紧跟在一句外文后面(一句只认一行),时间戳比那句晚、跟后面
// 紧接着的一行相同,是中文(sharedStampTranslationText)。全曲最后一行带时间戳的,后面没有行可比,只在一串译文
// 当中才算:它那句外文不是拟声行、紧跟在一行认定的译文后面。中间夹着署名、「男：」这种带字的跳过行就断开。
// 挂在这个位置上的译文声明(isTranslationNotice)直接丢掉,不进译文。
//
// known:已经知道这首带烘入译文(整首判断摘过,或者已有歌词自带的译文),认到一行就摘;否则要有 sharedStampMinLines
// 行原文不是拟声行、也不是最后一行的:拟声原文后面那行中文也可能是合唱里同时唱的另一句。译文挂回那句外文的
// 时间戳。不命中时原样返回、n=0。
func splitSharedStampTranslation(lyrics string, known bool) (cleanLRC, trLRC string, n int) {
	if lyrics == "" {
		return lyrics, "", 0
	}
	lines := splitLyricLines(lyrics)
	parsed := make([]bakedLine, len(lines))
	for i, l := range lines {
		parsed[i] = classifyBakedLine(l)
	}
	// nextAt[i]:i 后面第一行带时间戳的(空的占位行也算),没有是 -1。
	nextAt := make([]int, len(parsed))
	next := -1
	for i := len(parsed) - 1; i >= 0; i-- {
		nextAt[i] = next
		if parsed[i].startMs >= 0 {
			next = i
		}
	}
	owner := make([]int, len(parsed)) // 译文行 → 那句外文的下标;-1 = 不是译文行
	notice := make([]bool, len(parsed))
	strong := 0
	anchor, inRun, prevTaken := -1, false, false
	for i, bl := range parsed {
		owner[i] = -1
		switch bl.class {
		case bakedLineSkip:
			if bl.text != "" {
				anchor, prevTaken = -1, false
			}
			continue
		case bakedLineForeign:
			anchor, inRun, prevTaken = i, prevTaken && !isVocableLine(bl.text), false
			continue
		}
		prevTaken = false
		if anchor >= 0 && bl.startMs > parsed[anchor].startMs {
			j := nextAt[i]
			if j >= 0 && parsed[j].startMs == bl.startMs || j < 0 && inRun {
				matched := true
				switch {
				case isTranslationNotice(bl.text):
					notice[i] = true
				case sharedStampTranslationText(bl.text, parsed[anchor].text):
					owner[i] = anchor
				default:
					matched = false
				}
				if matched {
					n++
					if j >= 0 && !isVocableLine(parsed[anchor].text) {
						strong++
					}
					anchor, prevTaken = -1, true
					continue
				}
			}
		}
		anchor = -1
	}
	if n == 0 || !known && strong < sharedStampMinLines {
		return lyrics, "", 0
	}
	var clean, tr []string
	for i, bl := range parsed {
		if notice[i] {
			continue
		}
		if a := owner[i]; a >= 0 {
			tr = append(tr, parsed[a].stamps+bl.text)
			continue
		}
		clean = append(clean, bl.raw)
	}
	return strings.Join(clean, "\n"), strings.Join(tr, "\n"), n
}

// sharedStampTranslationText:text 能不能是 foreign 这句的中文译文。只有汉字(单字也算:「我」「噢」);或者以汉字为主,
// 夹着的字母词都在原文里(bakedMixedTranslationOf),或者字母不到汉字的一半(「24K纯正魔法即将上演」)。整行只有
// 「男：」这种标签的不算。
func sharedStampTranslationText(text, foreign string) bool {
	if _, rest, ok := lyricSplitLabel(text); ok && rest == "" {
		return false
	}
	han, latin := 0, 0
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case r < 0x80 && unicode.IsLetter(r):
			latin++
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r), unicode.Is(unicode.Hangul, r):
			return false
		}
	}
	switch {
	case han == 0:
		return false
	case latin == 0:
		return true
	default:
		return 2*latin <= han || bakedMixedTranslationOf(text, foreign)
	}
}

// mergeBakedTranslationLRC 把两份译文 LRC 合成一份:同一个时间戳的接成一行,按时间排;不带时间戳的行原样留在最前面。
func mergeBakedTranslationLRC(a, b string) string {
	if a == "" {
		return b
	}
	if b == "" {
		return a
	}
	type trLine struct {
		stamps, text string
		ms           int
	}
	var head []string
	var lines []trLine
	at := map[string]int{}
	for _, src := range []string{a, b} {
		for _, l := range splitLyricLines(src) {
			bl := classifyBakedLine(l)
			if bl.stamps == "" {
				if strings.TrimSpace(l) != "" {
					head = append(head, l)
				}
				continue
			}
			if bl.text == "" {
				continue
			}
			if k, ok := at[bl.stamps]; ok {
				lines[k].text += " " + bl.text
				continue
			}
			at[bl.stamps] = len(lines)
			lines = append(lines, trLine{bl.stamps, bl.text, bl.startMs})
		}
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].ms < lines[j].ms })
	out := head
	for _, l := range lines {
		out = append(out, l.stamps+l.text)
	}
	return strings.Join(out, "\n")
}

// migrateKuwoSharedStampTranslation 把存量酷我正文里还留着的烘入译文行逐行摘出来(splitSharedStampTranslation)。
// 新抓的在候选装配处就摘(adoptKuwoBakedTranslation),运行期不再产生。
//
// 只看酷我冠军,手动锁定的(manual_lyrics)不动。已经有歌词自带译文的,说明整首判断当时摘过,剩一行也摘,摘出来的按
// 时间戳并进去。原来没有译文或者是机翻的,跟候选装配同一道判断(usableValueAdd):摘出来的能用才换上(语言记 zh,
// 机翻重试计数一并清掉);不能用时(中文歌里只有一段外文、译文不到正文一半、目标语言不是中文),中文机翻留着:中文行
// 本来就不送去翻,跟摘干净的正文对得上;别的语言的机翻是按旧正文翻的,摘掉的中文行也翻了、挂在下一句的时间戳上,
// 清掉交给补翻按新正文重翻。读音一律清掉:酷我没有读音轨,存着的都是引擎按旧正文生成的,摘掉的那行中文的读音会
// 贴到同一个时间戳的下一句上;App 播放时现算,下次解析重新生成。逐字轨不动:酷我的逐字转换时已去掉译文行(kuwolrcx.go)。
func migrateKuwoSharedStampTranslation() {
	scope := migrationScopeOf(migrationKuwoSharedStampTranslation, migrationKuwoSharedStampTranslationVersion)
	if scope.skip() {
		return
	}
	target := features().LyricsTranslationLanguage
	enrichMu.Lock()
	fixed := 0
	for k, e := range scope.entries() {
		if e.LyricsSource != "kuwo" || e.ManualLyrics {
			continue
		}
		ownTr := e.LyricsTr != "" && e.LyricsTrSource != "machine"
		clean, tr, n := splitSharedStampTranslation(e.Lyrics, ownTr)
		if n == 0 {
			continue
		}
		if e.ManualPickSHA != "" && e.ManualPickSHA == manualPickFingerprint(e.Lyrics) {
			e.ManualPickSHA = manualPickFingerprint(clean)
		}
		e.Lyrics = clean
		usable, _ := usableValueAdd(clean, tr, "zh", "", target)
		switch {
		case ownTr:
			e.LyricsTr = mergeBakedTranslationLRC(e.LyricsTr, tr)
		case usable:
			e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = tr, "zh", ""
			e.TranslationRetryCount, e.TranslationTS, e.TranslationLang = 0, 0, ""
		case e.LyricsTrSource == "machine" && !strings.HasPrefix(strings.ToLower(e.LyricsTrLang), "zh"):
			e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = "", "", ""
			e.TranslationRetryCount, e.TranslationTS, e.TranslationLang = 0, 0, ""
		}
		e.LyricsRoma = ""
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("kuwo baked translation migration: moved translation lines out of %d entries", fixed)
		saveEnrichCache()
	}
	markMigrationDone(migrationKuwoSharedStampTranslation, migrationKuwoSharedStampTranslationVersion)
}
