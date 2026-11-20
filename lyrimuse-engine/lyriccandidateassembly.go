package main

// candidateSlots 按来源收排序用的候选,一个来源一格。吐出来的先后是同分决胜序(登记表的 tieOrder),跟各来源那段装配
// 写在哪、先装谁没有关系:排序是稳定的,同分的候选谁在前谁赢,这个先后只由这里定。合并几轮结果的
// mergeLyricCandidateRounds 按同一份 tieOrder 重建顺序。
type candidateSlots map[string]lyricCandidate

func (s candidateSlots) put(c lyricCandidate) { s[c.source] = c }

// inTieOrder:收到的候选按同分决胜序。没登记的源名不在决胜序里,不吐。
func (s candidateSlots) inTieOrder() []lyricCandidate {
	var out []lyricCandidate
	for _, name := range lyricProviders().tieOrder {
		if c, ok := s[name]; ok {
			out = append(out, c)
		}
	}
	return out
}

// resultFields:一个源交的结果里哪几栏进它的候选和排序结果,一位一栏。没列的栏源交了也不读。正文、歌名、歌手每个源都读;
// 译文轨看 CandidateAssembly.Translation,词曲作者看 ProviderDescriptor.SongwritersRank。
type resultFields uint16

const (
	// fieldWordTiming:逐字轨(yrc)。
	fieldWordTiming resultFields = 1 << iota
	// fieldRomanization:罗马音(roma)。
	fieldRomanization
	// fieldSourceDuration:源自己报的曲长(srcDur)。
	fieldSourceDuration
	// fieldAlbum:匹配到的专辑(matchAlbum)。
	fieldAlbum
	// fieldCover:匹配到的封面(matchCover)。
	fieldCover
	// fieldLanguage:源上报的语种(language)。
	fieldLanguage
	// fieldLocalIdentity:身份由播放器本机数据给定(identityFromLocalClient),要 privLocalClientIdentity。
	fieldLocalIdentity
	// fieldPlainText:只有不带时间戳的正文(plainOnly)。
	fieldPlainText
	// fieldISRC:这条录音的 ISRC(isrc)。
	fieldISRC
	// fieldSourceURL:这份歌词在源网站上的页面(sourceURL)。
	fieldSourceURL
	// fieldBackground:自带的背景人声轨(bg)。
	fieldBackground
)

func (f resultFields) has(bit resultFields) bool { return f&bit != 0 }

// TranslationPolicy:源交的译文轨是什么语言。
type TranslationPolicy int

const (
	// translationNone:不读译文轨。
	translationNone TranslationPolicy = iota
	// translationFixed:固定是 CandidateAssembly.TranslationLang 这种语言。
	translationFixed
	// translationTarget:按设置里的译文语言取的,标那个语言。
	translationTarget
	// translationDeclared:源自己标了语言(结果的 trLang)就用它,没标按设置里的译文语言。
	translationDeclared
)

// instrumentalSignals:一个源凭什么搭纯音乐标记,一位一种说法。
type instrumentalSignals uint8

const (
	// instrumentalDeclared:没交正文,源明确说这首是纯音乐(结果的 instrumental)。
	instrumentalDeclared instrumentalSignals = 1 << iota
	// instrumentalCreditsNoVocals:正文只有署名行,曲目信息又说这一条没有人声(结果的 noVocals)。
	instrumentalCreditsNoVocals
	// instrumentalPlaceholder:正文就是一句纯音乐占位(isInstrumentalPlaceholderLyric)。
	instrumentalPlaceholder
)

func (s instrumentalSignals) has(bit instrumentalSignals) bool { return s&bit != 0 }

// CandidateAssembly:排序时怎么把这个源交的结果装成候选、往排序结果里抄什么(assembleSourceCandidate)。
type CandidateAssembly struct {
	// Reads:结果里哪几栏进候选。
	Reads resultFields
	// Translation / TranslationLang:译文轨标什么语言;TranslationLang 只在 translationFixed 时有。
	Translation     TranslationPolicy
	TranslationLang string
	// AcceptTranslation:打分那道「译文可用」(usableValueAdd)没过时,这个源另一条把译文写进结果的判据;nil = 没有。
	AcceptTranslation func(lyrics, tr, target, artist, title string) bool
	// Instrumental:凭什么搭纯音乐标记;搭车的先后看 ProviderDescriptor.InstrumentalRank。
	Instrumental instrumentalSignals
}

// translationLang:译文轨的语言。declared 是源在结果里标的,target 是设置里的译文语言。
func (a *CandidateAssembly) translationLang(declared, target string) string {
	switch a.Translation {
	case translationFixed:
		return a.TranslationLang
	case translationTarget:
		return target
	case translationDeclared:
		if declared != "" {
			return declared
		}
		return target
	}
	return ""
}

// assembledSource 是一个来源这一次排序里装好的那一格:候选,和打完分之后往它那条结果里抄的附属内容。
type assembledSource struct {
	// candidate / ok:候选;ok 为假是这个源没交正文。
	candidate lyricCandidate
	ok        bool
	// tr / trLang / roma:译文轨和它的语言、罗马音。抄不抄进结果由 writeAux 按打完分时的候选判。
	tr, trLang, roma string
	// bg / songwriters:自带的背景人声轨、词曲作者名单,原样抄进结果。
	bg          string
	songwriters []string
	// bakedLines:从正文里摘掉的烘入译文行数。
	bakedLines int
	// acceptTranslation:CandidateAssembly.AcceptTranslation。
	acceptTranslation func(lyrics, tr, target, artist, title string) bool
	// instrumental:这个源交的内容说这首是纯音乐(CandidateAssembly.Instrumental 的某一种)。
	instrumental bool
}

// assembleSourceCandidate 按描述符把一个源交的结果装成候选。r 是这个源这一轮的原始应答(缺席的源是零值),foreignSong
// 是「本地标签不含汉字」(烘入译文的前提),target 是设置里的译文语言。
//
// 先后是硬约束:烘在正文里的译文先摘(候选的逐字覆盖、译文可用、之后的共识与行数全都读摘过的正文),再判纯音乐
// 的说法(读摘过的正文),最后装候选。括号背景人声、时间轴重挂在全部候选装完之后整批做(rankLyricSourceResults)。
func assembleSourceCandidate(d *ProviderDescriptor, r lyricSourceResult, foreignSong bool, target string) assembledSource {
	as := d.Assembly
	lyr, yrc, tr, roma := r.lyr, "", "", ""
	if as.Reads.has(fieldWordTiming) {
		yrc = r.yrc
	}
	if as.Translation != translationNone {
		tr = r.tr
	}
	if as.Reads.has(fieldRomanization) {
		roma = r.roma
	}
	var a assembledSource
	switch d.Baked {
	case bakedAdopt:
		lyr, tr, yrc, a.bakedLines = adoptBakedTranslation(lyr, tr, yrc, foreignSong, true)
	case bakedStripOnly:
		lyr, _, yrc, a.bakedLines = adoptBakedTranslation(lyr, "", yrc, foreignSong, false)
	case bakedCustom:
		lyr, tr, a.bakedLines = d.BakedSplit(lyr, foreignSong)
	}
	a.instrumental = as.Instrumental.has(instrumentalDeclared) && lyr == "" && r.instrumental ||
		as.Instrumental.has(instrumentalCreditsNoVocals) && isCreditOnlyLRC(lyr) && r.noVocals ||
		as.Instrumental.has(instrumentalPlaceholder) && isInstrumentalPlaceholderLyric(lyr)
	if lyr == "" {
		return a
	}
	trLang := as.translationLang(r.trLang, target)
	c := lyricCandidate{source: d.Name, lyrics: lyr, title: r.matchTitle, artist: r.matchArtist}
	if as.Reads.has(fieldWordTiming) {
		c.wordTimingYRC, c.hasWordTiming = usableYRC(lyr, yrc), usableWordTiming(lyr, yrc)
	}
	c.hasUsableTranslation, c.hasUsableRomanization = usableValueAdd(lyr, tr, trLang, roma, target)
	if as.Reads.has(fieldSourceDuration) {
		c.sourceReportedDurationSecs = r.srcDur
	}
	if as.Reads.has(fieldAlbum) {
		c.album = r.matchAlbum
	}
	if as.Reads.has(fieldCover) {
		c.cover = r.matchCover
	}
	if as.Reads.has(fieldLanguage) {
		c.language = r.language
	}
	if as.Reads.has(fieldLocalIdentity) {
		c.identityFromLocalClient = r.identityFromLocalClient
	}
	if as.Reads.has(fieldPlainText) {
		c.plainTextOnly = r.plainOnly
	}
	if as.Reads.has(fieldISRC) {
		c.isrc = r.isrc
	}
	if as.Reads.has(fieldSourceURL) {
		c.sourceURL = r.sourceURL
	}
	a.candidate, a.ok = c, true
	a.tr, a.trLang, a.roma = tr, trLang, roma
	if as.Reads.has(fieldBackground) {
		a.bg = r.bg
	}
	if d.SongwritersRank > 0 {
		a.songwriters = r.songwriters
	}
	a.acceptTranslation = as.AcceptTranslation
	return a
}

// writeAux 把这一格的附属内容抄进它那条打好分的结果。c 是打完分时的候选(正文可能修过重音空格、拆过括号背景人声、
// 重挂过时间轴)。译文过了打分那道「可用」才抄(不可用的抄进去,赢了就带着一份没有意义的译文进缓存),罗马音走更宽的
// usableRomaForResult。括号背景人声、时间轴重挂对附属内容的处理在这之后(rankLyricSourceResults)。
func (a assembledSource) writeAux(r *scoredLyricCandidateResult, c lyricCandidate, artist, title, target string) {
	if c.hasUsableTranslation || (a.acceptTranslation != nil && a.acceptTranslation(c.lyrics, a.tr, target, artist, title)) {
		r.LyricsTr, r.LyricsTrLang = a.tr, a.trLang
	}
	if usableRomaForResult(c.lyrics, a.roma) {
		r.LyricsRoma = a.roma
	}
	r.LyricsBG = a.bg
	r.Songwriters = a.songwriters
}
