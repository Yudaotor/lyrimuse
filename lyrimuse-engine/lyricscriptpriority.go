package main

import (
	"regexp"
	"strings"
	"unicode"
)

// 候选歌词按文字判对错的三条规矩,见 09 章决策 403:
//   - 原文优先(applyNativeScriptPriority):同一批里有一份可信的希腊 / 西里尔 / 阿拉伯(不含乌尔都)/ 希伯来字母原文,
//     排在它前面的拉丁字母候选又是它的转写时,转写降到原文之下。只有转写版时不动。
//   - 语种标记(applyScriptMarkerVerdicts):歌名或专辑名里写明了语种(「(Telugu)」「[Tamil]」「Hindi Version」),
//     候选正文的文字既不是那门语言的文字、也不是拉丁字母时,按语种版本不符处理。没有标记时不判。
//   - 唱名谱(isSolfegeNotation):整份几乎全是 sa re ga ma 这类唱名的候选在 rank 门口当成没有歌词。
//     歌里真唱了唱名段、其余是歌词的不算。
//
// 只看这几种文字:印度系文字的歌拉丁转写本来就是通行写法,中日韩的读音另有一轨,都不在原文优先之列。

// writingSystem:一段正文主要用哪套文字。比 lyricScript 分得细:希腊字母、各种印度系文字在那边都算拉丁字母。
type writingSystem int

const (
	wsNone writingSystem = iota
	wsLatin
	wsGreek
	wsCyrillic
	wsArabic
	wsHebrew
	wsDevanagari
	wsBengali
	wsGurmukhi
	wsGujarati
	wsOriya
	wsTamil
	wsTelugu
	wsKannada
	wsMalayalam
	wsSinhala
	wsThai
	wsOther
)

var writingSystemTables = []struct {
	ws    writingSystem
	table *unicode.RangeTable
}{
	{wsLatin, unicode.Latin}, {wsGreek, unicode.Greek}, {wsCyrillic, unicode.Cyrillic}, {wsArabic, unicode.Arabic},
	{wsHebrew, unicode.Hebrew}, {wsDevanagari, unicode.Devanagari}, {wsBengali, unicode.Bengali},
	{wsGurmukhi, unicode.Gurmukhi}, {wsGujarati, unicode.Gujarati}, {wsOriya, unicode.Oriya}, {wsTamil, unicode.Tamil},
	{wsTelugu, unicode.Telugu}, {wsKannada, unicode.Kannada}, {wsMalayalam, unicode.Malayalam},
	{wsSinhala, unicode.Sinhala}, {wsThai, unicode.Thai},
}

// runeWritingSystem:一个字母属于哪套文字;不是字母时是 wsNone。
func runeWritingSystem(r rune) writingSystem {
	if !unicode.IsLetter(r) {
		return wsNone
	}
	for _, t := range writingSystemTables {
		if unicode.Is(t.table, r) {
			return t.ws
		}
	}
	return wsOther
}

// urduOnlyLetters:乌尔都文(及同一套写法的旁遮普沙木基文)才用、波斯文和阿拉伯文不用的字母。
const urduOnlyLetters = "ٹڈڑںےۓھہ"

// dominantMinShare:主文字至少要占正文字母的这么多,不然算混写、哪条规矩都不判。
const dominantMinShare = 0.6

// lyricWritingSystem:正文("真的在唱的行",见 eachContentLyricLine)的主文字;字母不到 dominantMinShare 的算 wsNone。
// urdu:主文字是阿拉伯字母且写法是乌尔都文(urduOnlyLetters 至少 3 个、占阿拉伯字母 1% 以上)。
func lyricWritingSystem(lyrics string) (ws writingSystem, urdu bool) {
	counts := map[writingSystem]int{}
	urduLetters, total := 0, 0
	eachContentLyricLine(lyrics, func(text string) {
		for _, r := range text {
			w := runeWritingSystem(r)
			if w == wsNone {
				continue
			}
			counts[w]++
			total++
			if w == wsArabic && strings.ContainsRune(urduOnlyLetters, r) {
				urduLetters++
			}
		}
	})
	if total == 0 {
		return wsNone, false
	}
	best, bestN := wsNone, 0
	for w := wsLatin; w <= wsOther; w++ {
		if counts[w] > bestN {
			best, bestN = w, counts[w]
		}
	}
	if float64(bestN) < dominantMinShare*float64(total) {
		return wsNone, false
	}
	return best, best == wsArabic && urduLetters >= 3 && float64(urduLetters) >= 0.01*float64(counts[wsArabic])
}

// nativePriorityScript:这套文字的原文压过拉丁转写。乌尔都文不算(乌尔都语歌的拉丁转写是通行写法)。
func nativePriorityScript(ws writingSystem, urdu bool) bool {
	switch ws {
	case wsGreek, wsCyrillic, wsHebrew:
		return true
	case wsArabic:
		return !urdu
	}
	return false
}

// 转写比对:原文和拉丁字母正文各自折成辅音骨架(元音、长短音符号、各家转写方案的写法差异都折掉),比 4 字符片段的重合度。
// 骨架类别:B 唇音、M、N、L、R、T 齿音塞音、S 咝音、K 软腭与喉音、J。阿拉伯 / 希伯来字母的词尾 ه / ה 是元音,不算。
var nativeSkeletonClasses = func() map[writingSystem]map[rune]string {
	build := func(groups ...string) map[rune]string {
		m := map[rune]string{}
		for i := 0; i+1 < len(groups); i += 2 {
			for _, r := range groups[i] {
				m[r] = groups[i+1]
			}
		}
		return m
	}
	return map[writingSystem]map[rune]string{
		wsGreek: build("πβφ", "B", "μ", "M", "ν", "N", "λ", "L", "ρ", "R", "τδθ", "T", "σςζ", "S", "κγχ", "K", "ψ", "BS", "ξ", "KS"),
		wsCyrillic: build("бпфв", "B", "м", "M", "нңњ", "N", "лљ", "L", "р", "R", "тдђћ", "T", "сзцчшщжџ", "S",
			"кгхґғқһ", "K"),
		wsArabic: build("بپف", "B", "م", "M", "ن", "N", "ل", "L", "رڕ", "R", "تطدض", "T", "سصشزژچثذظ", "S",
			"کكگقغخحه", "K", "ج", "J"),
		wsHebrew: build("בפף", "B", "מם", "M", "נן", "N", "ל", "L", "ר", "R", "תטד", "T", "סשצץז", "S", "כךקגחה", "K"),
	}
}()

// latinSkeletonDigraphs / latinSkeletonLetters:拉丁字母那一侧按原文是哪套文字取对应的转写习惯(希腊转写的 ch、x 是 χ,
// 西里尔转写的 ch 是 ч)。表里没有的字母(元音、y、w 等)不进骨架。
var latinSkeletonDigraphs = map[writingSystem][][2]string{
	wsGreek:    {{"ch", "K"}, {"kh", "K"}, {"th", "T"}, {"ps", "BS"}, {"ks", "KS"}, {"ph", "B"}},
	wsCyrillic: {{"shch", "S"}, {"sch", "S"}, {"sh", "S"}, {"ch", "S"}, {"zh", "S"}, {"ts", "S"}, {"tz", "S"}, {"kh", "K"}, {"ph", "B"}},
	wsArabic:   {{"sh", "S"}, {"ch", "S"}, {"kh", "K"}, {"gh", "K"}, {"th", "S"}, {"dh", "S"}, {"zh", "S"}},
	wsHebrew:   {{"ch", "K"}, {"kh", "K"}, {"sh", "S"}, {"ts", "S"}, {"tz", "S"}, {"th", "T"}, {"ph", "B"}},
}

var latinSkeletonLetters = func() map[writingSystem]map[byte]string {
	base := func(extra map[byte]string) map[byte]string {
		m := map[byte]string{'b': "B", 'p': "B", 'f': "B", 'm': "M", 'n': "N", 'l': "L", 'r': "R", 't': "T", 'd': "T",
			's': "S", 'z': "S", 'k': "K", 'g': "K", 'q': "K", 'x': "K", 'h': "K"}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	return map[writingSystem]map[byte]string{
		wsGreek:    base(map[byte]string{'v': "B", 'c': "K"}),
		wsCyrillic: base(map[byte]string{'v': "B", 'w': "B", 'c': "S"}),
		wsArabic:   base(map[byte]string{'c': "K", 'j': "J"}),
		wsHebrew:   base(map[byte]string{'v': "B", 'c': "K", 'j': "J"}),
	}
}()

// arabiziDigits:阿拉伯语拉丁转写里拿数字代字母的写法(5 = خ、7 = ح、9 = ق、8 = غ)。
var arabiziDigits = strings.NewReplacer("5", "kh", "7", "h", "9", "q", "8", "gh")

// lyricTimingMarkRe:LRC 时间戳、逐字时间标记。
var lyricTimingMarkRe = regexp.MustCompile(`\[[^\]]*\]|\(\d+,\d+(?:,\d+)?\)`)

func skeletonWords(text string, split func(rune) bool) []string {
	return strings.FieldsFunc(stripLyricDiacritics(strings.ToLower(text)), split)
}

// latinConsonantFold:带附加符号的拉丁辅音折成转写里常见的写法;带附加符号的元音不用折,本来就不进骨架。
var latinConsonantFold = strings.NewReplacer("š", "sh", "č", "ch", "ž", "zh", "ş", "sh", "ç", "ch", "ć", "ch", "ñ", "n",
	"ğ", "g", "đ", "d", "ł", "l", "ṣ", "s", "ḥ", "h", "ṭ", "t", "ḍ", "d", "ẓ", "z", "ġ", "gh", "ḫ", "kh")

// stripLyricDiacritics:拉丁辅音折掉附加符号(latinConsonantFold),去掉独立的附加符号(希伯来 / 阿拉伯字母的元音点等)。
// 小写之后调。
func stripLyricDiacritics(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range latinConsonantFold.Replace(s) {
		if unicode.Is(unicode.Mn, r) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// nativeSkeleton:原文每行折成骨架,词之间用空格隔开;没有一个辅音的行不要。
func nativeSkeleton(lyrics string, ws writingSystem) []string {
	classes := nativeSkeletonClasses[ws]
	var out []string
	eachContentLyricLine(lyrics, func(text string) {
		var words []string
		for _, w := range skeletonWords(text, func(r rune) bool { return !unicode.IsLetter(r) }) {
			runes := []rune(w)
			var sk strings.Builder
			for i, r := range runes {
				if (r == 'ه' || r == 'ה') && i == len(runes)-1 {
					continue
				}
				sk.WriteString(classes[r])
			}
			if sk.Len() > 0 {
				words = append(words, sk.String())
			}
		}
		if len(words) > 0 {
			out = append(out, strings.Join(words, " "))
		}
	})
	return out
}

// latinSkeleton:拉丁字母正文按 ws 那套文字的转写习惯折成骨架。
func latinSkeleton(lyrics string, ws writingSystem) []string {
	digraphs, letters := latinSkeletonDigraphs[ws], latinSkeletonLetters[ws]
	var out []string
	eachContentLyricLine(lyrics, func(text string) {
		var words []string
		for _, w := range skeletonWords(text, func(r rune) bool { return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9') }) {
			switch ws {
			case wsGreek:
				w = strings.ReplaceAll(w, "8", "th")
			case wsArabic:
				w = arabiziDigits.Replace(w)
			}
			if (ws == wsArabic || ws == wsHebrew) && len(w) > 1 && strings.HasSuffix(w, "h") &&
				!strings.HasSuffix(w, "sh") && !strings.HasSuffix(w, "ch") && !strings.HasSuffix(w, "kh") {
				w = w[:len(w)-1]
			}
			var sk strings.Builder
		next:
			for i := 0; i < len(w); {
				for _, d := range digraphs {
					if strings.HasPrefix(w[i:], d[0]) {
						sk.WriteString(d[1])
						i += len(d[0])
						continue next
					}
				}
				sk.WriteString(letters[w[i]])
				i++
			}
			if sk.Len() > 0 {
				words = append(words, sk.String())
			}
		}
		if len(words) > 0 {
			out = append(out, strings.Join(words, " "))
		}
	})
	return out
}

// skeletonGrams:骨架按行加上首尾和词间分隔符,数 4 字符片段。
func skeletonGrams(lines []string) map[string]int {
	grams := map[string]int{}
	for _, l := range lines {
		s := "_" + strings.ReplaceAll(l, " ", "_") + "_"
		for i := 0; i+4 <= len(s); i++ {
			grams[s[i:i+4]]++
		}
	}
	return grams
}

// transliterationMinSimilarity:两份骨架的 4 字符片段按次数算的重合度(Dice)到这个数才算转写。真转写在 0.57～0.96,
// 同一批语料里互不相干的两首最高 0.33,同一首歌另一个语种版本的歌词 0.28。
// transliterationMinGrams:骨架太短的不比,片段少了重合度会碰巧偏高。
const (
	transliterationMinSimilarity = 0.45
	transliterationMinGrams      = 60
)

// transliterationSimilarity:latin 是不是 native(ws 那套文字)的转写,返回骨架重合度;骨架太短时返回 0。
func transliterationSimilarity(native string, ws writingSystem, latin string) float64 {
	a, b := skeletonGrams(nativeSkeleton(native, ws)), skeletonGrams(latinSkeleton(latin, ws))
	na, nb, inter := 0, 0, 0
	for g, n := range a {
		na += n
		inter += min(n, b[g])
	}
	for _, n := range b {
		nb += n
	}
	if na < transliterationMinGrams || nb < transliterationMinGrams {
		return 0
	}
	return 2 * float64(inter) / float64(na+nb)
}

// lyricsTransliterate:latin 是拉丁字母正文、native 是原文优先那几套文字之一,而且前者是后者的转写。
func lyricsTransliterate(latin, native string) bool {
	nws, urdu := lyricWritingSystem(native)
	if !nativePriorityScript(nws, urdu) {
		return false
	}
	if lws, _ := lyricWritingSystem(latin); lws != wsLatin {
		return false
	}
	return transliterationSimilarity(native, nws, latin) >= transliterationMinSimilarity
}

// nativeScriptVetoTerms:原文那份带着其中任何一项就不算可信,不拿它去压转写。
var nativeScriptVetoTerms = []string{
	scoreTermVersionTags, scoreTermDurationOff, scoreTermDurationOvershoot, scoreTermSourceDurationOff,
	scoreTermLiveAlbumConflict, scoreTermTimelineOffset, scoreTermTimelineIntrusion, scoreTermSourceDurationNearMiss,
	scoreTermGarbledText,
}

// nativeScriptCredible:这份原文能不能拿来压转写 —— 没有否决类扣分、末句跟曲长对得上(或别家印证了结束点)。被判废的、
// 纯音乐和没词的标记不带时长项,一并挡在外面。
func nativeScriptCredible(c scoredLyricCandidateResult) bool {
	for _, k := range nativeScriptVetoTerms {
		if c.hasScoreTerm(k) {
			return false
		}
	}
	return scoreTermPoints(c.ScoreTerms, scoreTermDuration) > 0 || scoreTermPoints(c.ScoreTerms, scoreTermCorroborated) > 0
}

// transliterationLineRatioMax:转写跟原文是同一份歌词,真在唱的行数差不出这个倍数。
const transliterationLineRatioMax = 1.6

// applyNativeScriptPriority:排在可信原文前面的拉丁字母转写降到原文之下(versionTags,至少 versionMismatchPenalty,
// 不够压到原文之下时扣到正好低 1 分,夹到 1)。批级、排序之前跑,两条流水线都要调。见文件头注与 09 章决策 403。
func applyNativeScriptPriority(results []scoredLyricCandidateResult) {
	type native struct {
		idx   int
		ws    writingSystem
		lines int
	}
	var natives []native
	for i, c := range results {
		if !nativeScriptCredible(c) {
			continue
		}
		if ws, urdu := lyricWritingSystem(c.Lyrics); nativePriorityScript(ws, urdu) {
			natives = append(natives, native{i, ws, contentLineCount(c.Lyrics)})
		}
	}
	if len(natives) == 0 {
		return
	}
	for i := range results {
		c := &results[i]
		if c.Score <= 0 || c.Instrumental || c.TrackFoundNoLyrics || c.hasScoreTerm(scoreTermVersionTags) {
			continue
		}
		if ws, _ := lyricWritingSystem(c.Lyrics); ws != wsLatin {
			continue
		}
		lines := contentLineCount(c.Lyrics)
		best := -1
		for _, n := range natives {
			nc := results[n.idx]
			if nc.Score >= c.Score || (best >= 0 && nc.Score <= results[best].Score) {
				continue
			}
			lo, hi := min(lines, n.lines), max(lines, n.lines)
			if lo == 0 || float64(hi) > transliterationLineRatioMax*float64(lo) {
				continue
			}
			if transliterationSimilarity(nc.Lyrics, n.ws, c.Lyrics) >= transliterationMinSimilarity {
				best = n.idx
			}
		}
		if best < 0 {
			continue
		}
		penalty := max(versionMismatchPenalty, c.Score-results[best].Score+1)
		c.Score = max(1, c.Score-penalty)
		c.ScoreTerms = append(c.ScoreTerms, scoreTerm{Kind: scoreTermVersionTags, Points: -penalty})
	}
}

// declaredLanguageScripts:歌名、专辑名里写明的语种允许哪几套文字(拉丁字母总是允许,不在表里)。
var declaredLanguageScripts = map[string][]writingSystem{
	"hindi": {wsDevanagari}, "marathi": {wsDevanagari}, "bhojpuri": {wsDevanagari},
	"urdu": {wsArabic, wsDevanagari}, "punjabi": {wsGurmukhi, wsArabic, wsDevanagari},
	"telugu": {wsTelugu}, "tamil": {wsTamil}, "malayalam": {wsMalayalam}, "kannada": {wsKannada},
	"bengali": {wsBengali}, "bangla": {wsBengali}, "gujarati": {wsGujarati}, "odia": {wsOriya}, "oriya": {wsOriya},
	"sinhala": {wsSinhala}, "greek": {wsGreek}, "russian": {wsCyrillic}, "ukrainian": {wsCyrillic},
	"arabic": {wsArabic}, "persian": {wsArabic}, "farsi": {wsArabic}, "hebrew": {wsHebrew}, "thai": {wsThai},
}

// declaredLanguageRe:语种标记只认三种写法 —— 括号里只有语种名(可带 Version / Ver. / Dubbed)、「<语种> Version」、
// 结尾的「- <语种>」。专辑名里随口提到语种的(「Best of Tamil Hits」)不算。
var declaredLanguageRe = func() *regexp.Regexp {
	names := make([]string, 0, len(declaredLanguageScripts))
	for k := range declaredLanguageScripts {
		names = append(names, k)
	}
	l := `(` + strings.Join(names, "|") + `)`
	return regexp.MustCompile(`(?i)(?:[(\[（【]\s*` + l + `(?:\s+(?:version|ver\.?|dubbed|dub))?\s*[)\]）】])|(?:\b` + l +
		`\s+(?:version|ver\.?)(?:[^a-z]|$))|(?:[-–—]\s*` + l + `\s*$)`)
}()

// declaredLanguage:歌名和专辑名里写明的语种(小写);没写、或写了两种不同的,返回空串。
func declaredLanguage(title, album string) string {
	found := ""
	for _, s := range []string{title, album} {
		for _, m := range declaredLanguageRe.FindAllStringSubmatch(s, -1) {
			for _, g := range m[1:] {
				if g == "" {
					continue
				}
				g = strings.ToLower(g)
				if found != "" && found != g {
					return ""
				}
				found = g
			}
		}
	}
	return found
}

// applyScriptMarkerVerdicts:歌名或专辑名写明了语种时,正文主文字既不是那门语言的文字、也不是拉丁字母的候选判语种版本不符
// (languageVersionMismatch,打分时吃 versionTags)。混写、认不出主文字的不判;拉丁字母分不出是哪门语言的转写,不判。
// 跟在 applyLanguageVersionVerdicts 后面调(那一步会先清掉标记),两条流水线都要调。见 09 章决策 403。
func applyScriptMarkerVerdicts(localTitle, localAlbum string, candidates []lyricCandidate) {
	allowed := declaredLanguageScripts[declaredLanguage(localTitle, localAlbum)]
	if len(allowed) == 0 {
		return
	}
	for i := range candidates {
		ws, _ := lyricWritingSystem(candidates[i].lyrics)
		if ws == wsNone || ws == wsLatin {
			continue
		}
		ok := false
		for _, a := range allowed {
			ok = ok || a == ws
		}
		if !ok {
			candidates[i].languageVersionMismatch = true
		}
	}
}

// solfegeSyllables:各文字写的印度唱名(sa re ga ma pa dha ni 及常见的长音、简写)。拉丁字母不收 da、na、la:那是拟声。
var solfegeSyllables = func() map[string]bool {
	m := map[string]bool{}
	for _, s := range strings.Fields(`sa saa re ri ree ga gaa ma maa pa paa dha dhaa ni nee nii
		सा स रे रि र ग गा म मा प पा ध धा नि नी न सां
		ச ஸ ரி க ம ப த நி சா ஸா
		స రి గ మ ప ద ని ಸ ರಿ ಗ ಮ ಪ ದ ನಿ സ രി ഗ മ പ ധ നി সা রে গা মা পা ধা নি ਸਾ ਰੇ ਗਾ ਮਾ ਪਾ ਧਾ ਨੀ`) {
		m[s] = true
	}
	return m
}()

// solfegeMinLines / solfegeMinShare / solfegeMinDistinct:整份当唱名谱的门槛 —— 至少这么多行有字,其中这个比例以上的行
// 是唱名行,整份用到的唱名至少这么多种。歌里唱了唱名段、其余是歌词的,唱名行实测占五到六成,不到门槛。
const (
	solfegeMinLines    = 4
	solfegeMinShare    = 0.85
	solfegeMinDistinct = 4
)

// isSolfegeNotation:整份正文(LRC、逐字或纯文本)是不是唱名谱。唱名行:至少 3 个词、九成以上是唱名、至少两种。
func isSolfegeNotation(s string) bool {
	if s == "" {
		return false
	}
	lines, notation := 0, 0
	distinct := map[string]bool{}
	for _, line := range strings.Split(s, "\n") {
		text := strings.TrimSpace(lyricTimingMarkRe.ReplaceAllString(line, " "))
		if text == "" {
			continue
		}
		lines++
		toks := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsMark(r) })
		if len(toks) < 3 {
			continue
		}
		hit, kinds := 0, map[string]bool{}
		for _, t := range toks {
			if solfegeSyllables[t] {
				hit++
				kinds[t] = true
			}
		}
		if float64(hit) >= 0.9*float64(len(toks)) && len(kinds) >= 2 {
			notation++
			for k := range kinds {
				distinct[k] = true
			}
		}
	}
	return lines >= solfegeMinLines && float64(notation) >= solfegeMinShare*float64(lines) && len(distinct) >= solfegeMinDistinct
}

// dropSolfegeNotation:整份是唱名谱(isSolfegeNotation)时返回空串,当成这个源没给歌词。
func dropSolfegeNotation(s string) string {
	if isSolfegeNotation(s) {
		return ""
	}
	return s
}
