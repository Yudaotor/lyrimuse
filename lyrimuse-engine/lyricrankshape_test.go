package main

import (
	"maps"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// 排序层按行为的守卫。每个来源一组「每一栏都交了」的输入,看排序(rankLyricSourceResults)读了它的哪几栏、译文怎么标、
// 烘入译文摘不摘、括号背景人声拆不拆、凭什么搭纯音乐标记、没带歌名时身份怎么办、借不借别家的封面曲长,看到的要等于期望表
// lyricSourceCandidateShapes 与 parenBGSources;另有几组专门的输入核对通用装配里不随来源变的规矩。输入按公共栏写,
// 内容在专用子结构里的源换成它实际交的摆法(rankShapeInput)。金标集(lyricsgolden_test.go)管真实曲目的判决,这里管
// 「描述符登记的每一项,排序真的照它做了」。

// rankShapeFields:lyricSourceCandidateShape.reads 里的栏名,按这个先后列。
// 另一栏纯文本 = 带时间轴的正文为空时,拿另一栏不带时间戳的正文出纯文本候选。
var rankShapeFields = []string{"逐字", "读音", "自报曲长", "专辑", "封面", "语种", "本机身份", "纯文本", "ISRC", "来源链接", "背景人声轨", "作者", "另一栏纯文本"}

// rankShapeInstrumentalSignals:lyricSourceCandidateShape.instrumental 里的名字。明说 = 没交正文、源说是纯音乐;
// 署名行加无人声 = 正文只有署名行(没交正文也算)、曲目信息说没有人声;占位句 = 正文是纯音乐占位句;
// 没正文加无人声 = 没交正文、曲目信息说没有人声,正文只有署名行的不算。
var rankShapeInstrumentalSignals = []string{"明说", "署名行加无人声", "占位句", "没正文加无人声"}

const (
	rankShapeArtist, rankShapeTitle, rankShapeAlbum = "Shape Artist", "Shape Title", "Shape Album"
	rankShapeDuration                               = 50.0
)

// rankShapeResult:source 每一栏都交了的一份结果,正文是 lines 造的整行加逐字。
func rankShapeResult(source string, lines []string) lyricSourceResult {
	lrc, yrc := rankShapeSong(lines)
	return lyricSourceResult{
		source: source, lyr: lrc, yrc: yrc, tr: rankShapeAux(lrc, "zh", 1), roma: rankShapeAux(lrc, "latin", 1),
		matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, matchAlbum: rankShapeAlbum,
		matchCover: "https://example.com/shape.jpg", srcDur: rankShapeDuration,
		isrc: "USUM71703861", sourceURL: rankShapeSourceURL(source), language: songLanguageMandarin,
		identityFromLocalClient: true, bg: rankShapeBG, songwriters: []string{"Writer A"}, trackIDs: []string{"97773"},
	}
}

// rankShapeInput:r 是按公共栏写的一份结果,换成这个源实际交上来的摆法:网易云的内容在 ne 上、AMLL 的在 amll 上,
// 公共栏上那几样是空的。
func rankShapeInput(r lyricSourceResult) lyricSourceResult {
	if r.source == lyricSourceAMLL {
		r.amll = amllResult{
			lrc: r.lyr, yrc: r.yrc, tr: r.tr, trLang: r.trLang, roma: r.roma, bg: r.bg,
			matchTitle: r.matchTitle, matchArtist: r.matchArtist, matchAlbum: r.matchAlbum,
			songwriters: r.songwriters, pageURL: r.sourceURL,
		}
		r.lyr, r.yrc, r.tr, r.trLang, r.roma, r.bg = "", "", "", "", "", ""
		r.matchTitle, r.matchArtist, r.matchAlbum, r.songwriters, r.sourceURL = "", "", "", nil, ""
		return r
	}
	if r.source != lyricSourceNetease {
		return r
	}
	r.ne = neteaseInfo{
		Lyrics: r.lyr, YRC: r.yrc, Trans: r.tr, Roma: r.roma, PlainLyrics: r.untimed,
		Title: r.matchTitle, Artist: r.matchArtist, Album: r.matchAlbum, Cover: r.matchCover, DurationSecs: r.srcDur,
		FromLocalClient: r.identityFromLocalClient, PureMusic: r.instrumental, NoVocals: r.noVocals,
	}
	r.lyr, r.yrc, r.tr, r.roma, r.untimed = "", "", "", "", ""
	r.matchTitle, r.matchArtist, r.matchAlbum, r.matchCover, r.srcDur = "", "", "", "", 0
	r.identityFromLocalClient, r.instrumental, r.noVocals = false, false, false
	return r
}

// rankShapeSourceURL:source 的歌词页地址,写成过得了它那道链接校验的样子(没登记校验的源随便给一个)。
func rankShapeSourceURL(source string) string {
	if source == lyricSourceAMLL {
		return "https://github.com/amll-dev/amll-ttml-db/blob/main/ncm-lyrics/97773.ttml"
	}
	return "https://www.megalobiz.com/lrc/maker/x.1"
}

func rankShapeRun(lang string, r lyricSourceResult) (cand *scoredLyricCandidateResult, instrumental bool) {
	featuresRef().LyricsTranslationLanguage = lang
	r = rankShapeInput(r)
	out := rankLyricSourceResults(rankShapeArtist, rankShapeTitle, rankShapeAlbum, rankShapeDuration, map[string]lyricSourceResult{r.source: r})
	for i := range out {
		switch {
		case out[i].Source != r.source || out[i].TrackFoundNoLyrics:
		case out[i].Instrumental:
			instrumental = true
		default:
			cand = &out[i]
		}
	}
	return cand, instrumental
}

// rankShapePlainLines:去掉括号段的英文歌(烘入译文的那一组用,不让括号背景人声掺进来)。
func rankShapePlainLines() []string {
	out := make([]string, len(rankShapeEnglish))
	for i, l := range rankShapeEnglish {
		if j := strings.Index(l, " ("); j >= 0 {
			l = l[:j]
		}
		out[i] = l
	}
	return out
}

// rankShapeObserved:排序对 source 实际读了什么,另返回括号背景人声拆不拆。source 交了候选才有意义。
func rankShapeObserved(t *testing.T, source string) (shape lyricSourceCandidateShape, paren bool) {
	t.Helper()
	full := rankShapeResult(source, rankShapeJapanese)
	c, _ := rankShapeRun("zh", full)
	if c == nil {
		t.Fatalf("%s:每一栏都交了却没有候选", source)
	}
	plain := full
	plain.plainOnly = true
	p, _ := rankShapeRun("zh", plain)
	if p == nil {
		t.Fatalf("%s:带纯文本标记的那份没有候选", source)
	}
	// 另一栏纯文本:带时间轴的正文不交,只交不带时间戳的那一栏,逐字、译文照交。出来的得是纯文本候选,逐字、译文都不带。
	second := full
	second.lyr, second.untimed = "", rankShapePlain(full.lyr)
	u, _ := rankShapeRun("zh", second)
	if u != nil && (!u.PlainTextOnly || u.HasWordTiming || u.LyricsYRC != "" || u.LyricsTr != "" || u.Lyrics != second.untimed) {
		t.Fatalf("%s:另一栏纯文本出来的候选不对:%+v", source, *u)
	}
	// 两栏都交了:用带时间轴的那一栏,不带时间戳的那栏只在前一栏为空时顶上来。
	both := full
	both.untimed = "不带时间戳的另一份正文\n第二行"
	if b, _ := rankShapeRun("zh", both); b == nil || b.PlainTextOnly || b.Lyrics != c.Lyrics || b.HasWordTiming != c.HasWordTiming {
		t.Fatalf("%s:两栏正文都交了,候选该是带时间轴的那一栏:%+v", source, b)
	}
	seen := map[string]bool{
		"逐字": c.HasWordTiming, "读音": c.LyricsRoma != "", "自报曲长": c.SourceReportedDurationSecs != 0, "专辑": c.Album != "",
		"封面": c.CoverURL != "", "语种": c.Language != "", "本机身份": c.IdentityFromLocalClient, "纯文本": p.PlainTextOnly,
		"ISRC": c.ISRC != "", "来源链接": c.SourceURL != "", "背景人声轨": c.LyricsBG == rankShapeBG, "作者": len(c.Songwriters) > 0,
		"另一栏纯文本": u != nil,
	}
	var reads []string
	for _, f := range rankShapeFields {
		if seen[f] {
			reads = append(reads, f)
		}
	}
	shape.reads = strings.Join(reads, " ")

	// 译文:四种(译文语言设置,源标的语言)下结果里的译文标成什么。
	var labels []string
	for _, combo := range [][2]string{{"zh", ""}, {"ko", ""}, {"zh", "ja"}, {"ja", "ja"}} {
		r := full
		r.trLang = combo[1]
		tc, _ := rankShapeRun(combo[0], r)
		label := "-"
		if tc != nil && tc.LyricsTr != "" {
			label = tc.LyricsTrLang
		}
		labels = append(labels, label)
	}
	switch got := strings.Join(labels, " "); got {
	case "- - - -":
	case "zh - zh -":
		shape.translation = "zh"
	case "- ko - -":
		shape.translation = "ko"
	case "zh ko zh ja":
		shape.translation = "target"
	case "zh ko - ja":
		shape.translation = "declared"
	default:
		t.Fatalf("%s:译文的标法认不出 %q", source, got)
	}

	// 烘入译文:英文歌每句后面烘一行中文,没有译文轨、没有逐字。
	lrc, _ := rankShapeSong(rankShapePlainLines())
	baked := lyricSourceResult{source: source, lyr: rankShapeBake(lrc, "later"), matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
	if bc, _ := rankShapeRun("zh", baked); bc != nil && bc.BakedTranslationLines > 0 {
		shape.baked = "strip"
		if bc.LyricsTr != "" {
			if bc.LyricsTrLang != "zh" {
				t.Fatalf("%s:摘出来的烘入译文标成了 %q", source, bc.LyricsTrLang)
			}
			shape.baked = "adopt"
		}
	}

	// 括号背景人声:带括号段的英文歌,整行加逐字。
	parenLRC, parenYRC := rankShapeSong(rankShapeEnglish)
	pc, _ := rankShapeRun("zh", lyricSourceResult{source: source, lyr: parenLRC, yrc: parenYRC, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration})
	paren = pc != nil && pc.LyricsBG != ""

	// 纯音乐标记:四种说法各单独喂一次。没交正文加无人声那一种,认「署名行加无人声」的源也会搭(空正文算只有署名行),
	// 所以只在署名行那一种不搭时才记成「没正文加无人声」。
	meta := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, matchAlbum: rankShapeAlbum, srcDur: rankShapeDuration}
	said, credit, placeholder, bare := meta, meta, meta, meta
	said.instrumental = true
	credit.lyr, credit.noVocals = rankShapeCredit, true
	placeholder.lyr = rankShapeNoLyrics
	bare.noVocals = true
	var signals []string
	marks := make([]bool, 4)
	for i, r := range []lyricSourceResult{said, credit, placeholder, bare} {
		_, marks[i] = rankShapeRun("zh", r)
	}
	if marks[1] && !marks[3] {
		t.Fatalf("%s:认署名行加无人声,没交正文加无人声时却不搭标记", source)
	}
	marks[3] = marks[3] && !marks[1]
	for i, marked := range marks {
		if marked {
			signals = append(signals, rankShapeInstrumentalSignals[i])
		}
	}
	shape.instrumental = strings.Join(signals, " ")

	// 没带歌名的结果:候选的歌名、歌手、专辑空着,还是用查询的那一组。
	anon := full
	anon.matchTitle, anon.matchArtist, anon.matchAlbum = "", "", ""
	ac, _ := rankShapeRun("zh", anon)
	switch {
	case ac == nil:
		t.Fatalf("%s:没带歌名的那份没有候选", source)
	case ac.Title == rankShapeTitle && ac.Artist == rankShapeArtist && ac.Album == rankShapeAlbum:
		shape.unnamed = "query"
	case ac.Title != "" || ac.Artist != "" || ac.Album != "":
		t.Fatalf("%s:没带歌名的那份候选的身份认不出:%q / %q / %q", source, ac.Title, ac.Artist, ac.Album)
	}

	// 借封面、曲长:这个源说它是另一家(网易云)那一条录音,那一家交了封面和曲长。
	donor := rankShapeInput(lyricSourceResult{source: lyricSourceNetease, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist,
		matchCover: "https://example.com/donor.jpg", srcDur: rankShapeDuration + 1})
	donor.ne.SongID = 97773
	lent := rankShapeInput(full)
	lent.amll.platform = "ncm-lyrics"
	if source != lyricSourceNetease {
		featuresRef().LyricsTranslationLanguage = "zh"
		for _, r := range rankLyricSourceResults(rankShapeArtist, rankShapeTitle, rankShapeAlbum, rankShapeDuration, map[string]lyricSourceResult{source: lent, lyricSourceNetease: donor}) {
			if r.Source == source && !r.Instrumental && !r.TrackFoundNoLyrics {
				shape.borrows = r.CoverURL == donor.ne.Cover && r.BorrowedDurationSecs == donor.ne.DurationSecs && r.BorrowedDurationFrom == lyricSourceNetease
				if !shape.borrows && (r.CoverURL == donor.ne.Cover || r.BorrowedDurationFrom != "") {
					t.Fatalf("%s:封面和曲长只借了一样:%q / %v / %q", source, r.CoverURL, r.BorrowedDurationSecs, r.BorrowedDurationFrom)
				}
			}
		}
	}
	return shape, paren
}

func TestRankShapesMatchExpected(t *testing.T) {
	saveRankState(t)
	setNativeLyricSourcesForPlayer("")
	featuresRef().LyricsSources = nil
	for _, source := range lyricCandidateTieOrder {
		want, ok := lyricSourceCandidateShapes[source]
		if !ok {
			t.Errorf("%s 不在 lyricSourceCandidateShapes 里", source)
			continue
		}
		got, paren := rankShapeObserved(t, source)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s\n  看到 %+v\n  期望 %+v", source, got, want)
		}
		// 括号段要对着逐字拆,候选不读逐字的源登记了也拆不出来。
		if wantParen := parenBGSources[source] && slices.Contains(strings.Fields(want.reads), "逐字"); paren != wantParen {
			t.Errorf("%s:括号背景人声拆不拆 = %v,该是 %v(parenBGSources %v)", source, paren, wantParen, parenBGSources[source])
		}
	}
	for source := range lyricSourceCandidateShapes {
		if !slices.Contains(lyricCandidateTieOrder, source) {
			t.Errorf("lyricSourceCandidateShapes 里有没登记的来源 %s", source)
		}
	}
}

// 结果的内容在专用子结构里的源,正文不过排序开头那两步对公共栏正文的清理:行内逐字写法不拆,匹配到伴奏版时占位正文不丢。
// 同样的内容放在公共栏上的源两样都做。摊平(unpackSourceResults)因此排在那两步之后。
func TestUnpackedLyricsSkipBodyCleanup(t *testing.T) {
	saveRankState(t)
	setNativeLyricSourcesForPlayer("")
	featuresRef().LyricsSources = nil
	var lines []string
	for i, text := range rankShapePlainLines() {
		ms := 2000 + 4000*i
		line := lrcTimestamp(ms)
		for k, w := range strings.Fields(text) {
			line += "<" + strings.Trim(lrcTimestamp(ms+300*k), "[]") + ">" + w + " "
		}
		lines = append(lines, strings.TrimSpace(line))
	}
	inline := strings.Join(lines, "\n")
	unpacked := 0
	for _, source := range lyricCandidateTieOrder {
		if _, ok := lyricSourceCandidateShapes[source]; !ok {
			continue
		}
		inPayload := lyricSourceUnpackers[source] != ""
		if inPayload {
			unpacked++
		}
		meta := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
		word := meta
		word.lyr = inline
		c, _ := rankShapeRun("zh", word)
		if c == nil {
			t.Fatalf("%s:行内逐字写法的正文没有候选", source)
		}
		if kept := strings.Contains(c.Lyrics, "<00:"); kept != inPayload {
			t.Errorf("%s:行内逐字写法留在正文里=%v,该是 %v", source, kept, inPayload)
		}
		inst := meta
		inst.lyr, inst.matchTitle = rankShapeNoLyrics, rankShapeTitle+" (Instrumental)"
		p, _ := rankShapeRun("zh", inst)
		if kept := p != nil; kept != inPayload {
			t.Errorf("%s:匹配到伴奏版时占位正文还在=%v,该是 %v", source, kept, inPayload)
		}
	}
	if unpacked == 0 {
		t.Error("没有一个内容在专用子结构里的源,这条什么都没比")
	}
}

// 通用装配里不随来源变的几条规矩:每个来源各喂一组专门的输入,出来的结果按期望表该是什么样逐个核对。
func TestRankAssemblyRulesHoldForEverySource(t *testing.T) {
	saveRankState(t)
	setNativeLyricSourcesForPlayer("")
	featuresRef().LyricsSources = nil
	run := func(artist, title string, r lyricSourceResult) *scoredLyricCandidateResult {
		featuresRef().LyricsTranslationLanguage = "zh"
		r = rankShapeInput(r)
		for _, c := range rankLyricSourceResults(artist, title, rankShapeAlbum, rankShapeDuration, map[string]lyricSourceResult{r.source: r}) {
			if c.Source == r.source && !c.Instrumental && !c.TrackFoundNoLyrics {
				return &c
			}
		}
		return nil
	}
	lines := rankShapePlainLines()
	bakedLRC, bakedYRC := rankShapeBakedSong(lines)
	fullLRC, fullYRC := rankShapeSong(rankShapeJapanese)
	for _, source := range lyricCandidateTieOrder {
		shape := lyricSourceCandidateShapes[source]
		readsWords := slices.Contains(strings.Fields(shape.reads), "逐字")
		meta := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}

		// 外文歌,译文连逐字轨一起烘在正文里:摘的源正文里不剩中文行;逐字轨跟着摘的(自带摘法的源不动逐字轨)逐字照带、
		// 里面也不剩中文行。不摘的源原样。
		baked := meta
		baked.lyr, baked.yrc = bakedLRC, bakedYRC
		switch c := run(rankShapeArtist, rankShapeTitle, baked); {
		case c == nil:
			t.Errorf("%s:烘入译文连逐字轨的那份没有候选", source)
		case shape.baked == "":
			if c.BakedTranslationLines != 0 || !containsHan(c.Lyrics) {
				t.Errorf("%s:不摘烘入译文的源动了正文(摘了 %d 行)", source, c.BakedTranslationLines)
			}
		default:
			if c.BakedTranslationLines != len(lines) || containsHan(c.Lyrics) {
				t.Errorf("%s:该摘掉 %d 行烘入译文,摘了 %d 行,正文里还有中文=%v", source, len(lines), c.BakedTranslationLines, containsHan(c.Lyrics))
			}
			if readsWords && !strings.HasPrefix(lyricSourceBakedPolicies[source], "custom:") && (!c.HasWordTiming || containsHan(c.LyricsYRC)) {
				t.Errorf("%s:烘入译文要连逐字轨一起摘,逐字=%v,逐字轨里还有中文=%v", source, c.HasWordTiming, containsHan(c.LyricsYRC))
			}
			if adopted := c.LyricsTr != ""; adopted != (shape.baked == "adopt") {
				t.Errorf("%s:摘出来的译文接没接到译文轨=%v,期望表 baked=%q", source, adopted, shape.baked)
			}
		}

		// 同一份正文,本地标签带汉字:不算外文歌,谁都不摘。
		tagged := baked
		tagged.matchArtist, tagged.matchTitle = "某位歌手", "某首歌名"
		if c := run("某位歌手", "某首歌名", tagged); c == nil || c.BakedTranslationLines != 0 || c.LyricsTr != "" {
			t.Errorf("%s:本地标签带汉字时不该摘烘入译文:%+v", source, c)
		}

		// 逐字轨只有前四分之一:当没有逐字。
		partial := meta
		partial.lyr, partial.yrc = fullLRC, strings.Join(strings.Split(fullYRC, "\n")[:len(rankShapeJapanese)/4], "\n")
		if c := run(rankShapeArtist, rankShapeTitle, partial); c == nil || c.HasWordTiming || c.LyricsYRC != "" {
			t.Errorf("%s:残缺的逐字轨不该进候选:%+v", source, c)
		}

		// 拿汉字当读音的那一轨不进结果。
		hanRoma := meta
		hanRoma.lyr, hanRoma.yrc, hanRoma.roma = fullLRC, fullYRC, rankShapeAux(fullLRC, "zh", 1)
		if c := run(rankShapeArtist, rankShapeTitle, hanRoma); c == nil || c.LyricsRoma != "" {
			t.Errorf("%s:汉字写的读音不该进结果:%+v", source, c)
		}

		// 只有逐字、译文、读音,没有正文:不出候选。
		bodiless := meta
		bodiless.yrc, bodiless.tr, bodiless.roma = fullYRC, "[00:02.00]只有译文", "[00:02.00]tada yomi"
		if c := run(rankShapeArtist, rankShapeTitle, bodiless); c != nil {
			t.Errorf("%s:没有正文却出了候选:%+v", source, *c)
		}

		// 交了真歌词,同时说这首是纯音乐、没有人声(有词的伴奏版):照常出候选,谁都不搭纯音乐标记。
		vocal := meta
		vocal.lyr, vocal.yrc, vocal.instrumental, vocal.noVocals = fullLRC, fullYRC, true, true
		if c, marked := rankShapeRun("zh", vocal); c == nil || marked {
			t.Errorf("%s:交了正文又说是纯音乐:出候选=%v,搭标记=%v,该出候选、不搭标记", source, c != nil, marked)
		}

		// 带时间轴的正文没交、只交了不带时间戳的那一栏,同时说这首是纯音乐、没有人声:搭不搭标记只看带时间轴的那一栏
		// (没交),纯文本候选出不出只看读不读另一栏,两样互不影响。
		claimed := meta
		claimed.untimed, claimed.instrumental, claimed.noVocals = rankShapePlain(fullLRC), true, true
		plainCand, marked := rankShapeRun("zh", claimed)
		if wantCand := slices.Contains(strings.Fields(shape.reads), "另一栏纯文本"); (plainCand != nil) != wantCand || marked != (shape.instrumental != "" && shape.instrumental != "占位句") {
			t.Errorf("%s:只交另一栏纯文本又说是纯音乐:出候选=%v(该是 %v),搭标记=%v(期望表 instrumental=%q)",
				source, plainCand != nil, wantCand, marked, shape.instrumental)
		}

		// 中文歌第一行是「歌名 - 歌手」的抬头,歌手那一段是缩写、只有歌名对得上;中间五句外文各带一行挂在下一句时间戳上的
		// 中文译文,另有一句外文没带译文。打分那道「译文可用」不认这份译文(原文是中文、译文不到一半);另有判据的源
		// (lyricSourceTranslationAccepters)认出抬头、六句译了五句,照收。歌手歌名对调着认,抬头算成又一句没译的,就不收了。
		var mixed []string
		ms := 500
		add := func(text string, step int) {
			mixed = append(mixed, lrcTimestamp(ms)+text)
			ms += step
		}
		add("Throw It Off - K. Fong", 3500)
		for i := 0; i < 3; i++ {
			add(rankShapeHanLine(i), 4000)
		}
		for i := 0; i < 5; i++ {
			add("placeholder foreign line number "+strconv.Itoa(i), 4000)
			add(rankShapeHanLine(10+i), 0)
		}
		add(rankShapeHanLine(3), 4000)
		add("one more foreign line left without a pair", 4000)
		for i := 4; i < 7; i++ {
			add(rankShapeHanLine(i), 4000)
		}
		headed := meta
		headed.lyr, headed.matchArtist, headed.matchTitle = strings.Join(mixed, "\n"), "Khalil Fong", "Throw It Off"
		c := run("Khalil Fong", "Throw It Off", headed)
		if accepts := lyricSourceTranslationAccepters[source] != ""; c == nil || (c.LyricsTr != "") != accepts {
			t.Errorf("%s:中文歌里那段外文的自带译文收没收,该是 %v:%+v", source, accepts, c)
		}
	}
}

// 摊平以专用子结构为准:公共栏上原有的值(调度封口前别的环节可能填过的)不留,子结构里没有的就是没有。
func TestUnpackOverwritesCommonFields(t *testing.T) {
	stale := lyricSourceResult{
		lyr: "[00:01.00]stale", yrc: "[1000,500](1000,500,0)stale", tr: "[00:01.00]旧", trLang: "ja", roma: "[00:01.00]stale", untimed: "stale",
		bg: "[1000,500](1000,500,0)stale", matchTitle: "Stale", matchArtist: "Stale", matchAlbum: "Stale", matchCover: "https://example.com/stale.jpg",
		srcDur: 99, sourceURL: "https://example.com/stale", songwriters: []string{"Stale"},
		identityFromLocalClient: true, instrumental: true, noVocals: true, trackFoundNoLyrics: true,
	}
	ne := unpackNeteaseResult(stale)
	if ne.lyr != "" || ne.yrc != "" || ne.tr != "" || ne.roma != "" || ne.untimed != "" || ne.matchTitle != "" || ne.matchArtist != "" ||
		ne.matchAlbum != "" || ne.matchCover != "" || ne.srcDur != 0 || ne.identityFromLocalClient || ne.instrumental || ne.noVocals || ne.trackFoundNoLyrics {
		t.Errorf("网易云:ne 是空的,摊平后公共栏上还留着原有的值:%+v", ne)
	}
	am := unpackAMLLResult(stale)
	if am.lyr != "" || am.yrc != "" || am.tr != "" || am.trLang != "" || am.roma != "" || am.bg != "" || am.matchTitle != "" || am.matchArtist != "" ||
		am.matchAlbum != "" || am.sourceURL != "" || am.songwriters != nil {
		t.Errorf("AMLL:amll 是空的,摊平后公共栏上还留着原有的值:%+v", am)
	}
}

// 括号背景人声在重挂时间轴之前拆:译文、读音里同一行的括号段按重挂之前的时间戳认,拆完再跟着正文搬到新时间轴上。
// 先后反了,附属歌词里的括号段认不出来,留在译文里。
func TestRankSplitsParenBackgroundBeforeRehang(t *testing.T) {
	saveRankState(t)
	setNativeLyricSourcesForPlayer("")
	featuresRef().LyricsSources = nil
	_, yrc := rankShapeSong(rankShapeEnglish)
	var lrc, tr []string
	parens := 0
	for i, text := range rankShapeEnglish {
		// 整行的时间戳比逐字轴的行起点晚 0.4 秒:两套轴打架,重挂会把整行搬到逐字轴上。
		stamp := lrcTimestamp(2000 + 4000*i + 400)
		lrc = append(lrc, stamp+text)
		line := stamp + rankShapeHanLine(i)
		if j := strings.Index(text, " ("); j >= 0 {
			line += text[j:]
			parens++
		}
		tr = append(tr, line)
	}
	r := lyricSourceResult{source: lyricSourceQQ, lyr: strings.Join(lrc, "\n"), yrc: yrc, tr: strings.Join(tr, "\n"),
		matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
	c, _ := rankShapeRun("zh", r)
	if c == nil || c.LyricsBG == "" || c.LyricsTr == "" || parens == 0 {
		t.Fatalf("前提:QQ 这份要拆出括号背景人声、带上译文:%+v", c)
	}
	if !strings.HasPrefix(c.Lyrics, lrcTimestamp(2000)) || !strings.HasPrefix(c.LyricsTr, lrcTimestamp(2000)) {
		t.Errorf("正文和译文都该搬到逐字轴的行起点上:正文 %.20q 译文 %.20q", c.Lyrics, c.LyricsTr)
	}
	if strings.Contains(c.LyricsTr, "(") || strings.Contains(c.Lyrics, "(") {
		t.Errorf("括号段该从正文和译文里拿掉:\n正文 %q\n译文 %q", c.Lyrics, c.LyricsTr)
	}
}

// AMLL 实际交不出的两种输入(TTML 解析出一行就同时有整行;公共栏上的「有歌没词」它从来不填)也按通用规矩走:
//   - 整行为空、逐字非空:不出候选,跟别的源正文为空时一样。
//   - 公共栏上带「曲库里有这首歌、没有歌词文本」:标记上的歌名是索引里那一份的(摊平后公共栏上的)。
func TestAMLLUnreachableInputsFollowGenericRules(t *testing.T) {
	saveRankState(t)
	setNativeLyricSourcesForPlayer("")
	featuresRef().LyricsSources = nil
	lrc, yrc := rankShapeSong(rankShapeJapanese)
	run := func(r lyricSourceResult) []scoredLyricCandidateResult {
		r.source = lyricSourceAMLL
		return rankLyricSourceResults(rankShapeArtist, rankShapeTitle, rankShapeAlbum, rankShapeDuration, map[string]lyricSourceResult{lyricSourceAMLL: r})
	}
	if got := run(lyricSourceResult{amll: amllResult{yrc: yrc}}); len(got) != 0 {
		t.Errorf("只有逐字没有整行的 AMLL 结果出了候选 %+v", got)
	}
	title, found := "", false
	for _, r := range run(lyricSourceResult{trackFoundNoLyrics: true, amll: amllResult{lrc: lrc, matchTitle: "Index Title", matchArtist: "Index Artist"}}) {
		if r.TrackFoundNoLyrics {
			title, found = r.Title, true
		}
	}
	if !found || title != "Index Title" {
		t.Errorf("标记上的歌名 %q(有标记=%v),该是索引里那一份的", title, found)
	}
}

// 几个源同时说这首是纯音乐时,标记记在 InstrumentalRank 最靠前的那个头上;把它拿掉,轮到下一个。
func TestInstrumentalMarkerFollowsRank(t *testing.T) {
	saveRankState(t)
	setNativeLyricSourcesForPlayer("")
	order := registryNames(func(d *ProviderDescriptor) bool { return d.InstrumentalRank > 0 },
		func(d *ProviderDescriptor) int { return d.InstrumentalRank })
	if !slices.Equal(order, lyricSourceInstrumentalOrder) {
		t.Fatalf("搭纯音乐标记的先后 %v,期望表 %v", order, lyricSourceInstrumentalOrder)
	}
	// 每个源用它认的那种说法:明说的清空正文、署名行加无人声、占位句;网易云的在 ne 上。
	claim := func(source string) lyricSourceResult {
		r := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
		switch source {
		case lyricSourceNetease:
			r.ne = neteaseInfo{Title: rankShapeTitle, Artist: rankShapeArtist, PureMusic: true}
		case lyricSourceMigu:
			r.lyr = rankShapeNoLyrics
		case lyricSourceKugou:
			r.lyr, r.noVocals = rankShapeCredit, true
		default:
			r.instrumental = true
		}
		return r
	}
	for first := range order {
		raw := map[string]lyricSourceResult{}
		for _, source := range order[first:] {
			raw[source] = claim(source)
		}
		var marked []string
		for _, r := range rankLyricSourceResults(rankShapeArtist, rankShapeTitle, rankShapeAlbum, rankShapeDuration, raw) {
			if r.Instrumental {
				marked = append(marked, r.Source)
			}
		}
		if !slices.Equal(marked, order[first:first+1]) {
			t.Errorf("%v 同时说是纯音乐,标记记在 %v 头上,该是 %s", order[first:], marked, order[first])
		}
	}
}

// ---------- 造输入的辅助 ----------

// saveRankState 登记还原:这些用例会改译文语言、来源开关、在放的播放器、歌手别名缓存。
func saveRankState(t *testing.T) {
	t.Helper()
	savedFeatures := features()
	nativeLyricSourcesMu.Lock()
	savedNative, savedPlayer := nativeLyricSources, playingPlayerID
	nativeLyricSourcesMu.Unlock()
	artistAliasMu.Lock()
	savedAlias := maps.Clone(artistAliasCache)
	artistAliasMu.Unlock()
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		nativeLyricSourcesMu.Lock()
		nativeLyricSources, playingPlayerID = savedNative, savedPlayer
		nativeLyricSourcesMu.Unlock()
		artistAliasMu.Lock()
		artistAliasCache = savedAlias
		artistAliasMu.Unlock()
	})
}

var rankShapeStampRe = regexp.MustCompile(`^((?:\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\])+)(.*)$`)

// rankShapeLines:LRC 里带时间戳、有字的行,拆成(时间戳原文,文字)。
func rankShapeLines(lrc string) (stamps, texts []string) {
	for _, line := range strings.Split(lrc, "\n") {
		m := rankShapeStampRe.FindStringSubmatch(strings.TrimRight(line, "\r"))
		if m == nil || strings.TrimSpace(m[2]) == "" {
			continue
		}
		stamps, texts = append(stamps, m[1]), append(texts, strings.TrimSpace(m[2]))
	}
	return
}

const rankShapeHan = "风花雪月山川湖海晨昏昼夜星云雨露春夏秋冬远近高低来去聚散悲欢离合光影声色梦醒心念"

// rankShapeHanLine:第 i 行的一句纯汉字,各行不同。
func rankShapeHanLine(i int) string {
	pool := []rune(rankShapeHan)
	var b strings.Builder
	for k := 0; k < 5+i%4; k++ {
		b.WriteRune(pool[(i*7+k*3)%len(pool)])
	}
	return b.String()
}

// rankShapeAux 照正文的时间戳造一份附属歌词:kind 是 zh(汉字)、ko(谚文)、latin(拉丁字母)。keep 是留下的行的比例。
func rankShapeAux(lrc, kind string, keep float64) string {
	stamps, _ := rankShapeLines(lrc)
	n := int(float64(len(stamps)) * keep)
	var out []string
	for i, s := range stamps[:n] {
		switch kind {
		case "zh":
			out = append(out, s+rankShapeHanLine(i))
		case "ko":
			out = append(out, s+"번역된 가사 "+strings.Repeat("줄", 1+i%3))
		default:
			out = append(out, s+"ro ma ji "+strconv.Itoa(i)+" yomi kata")
		}
	}
	return strings.Join(out, "\n")
}

func rankShapeShiftStamp(stamp string, deltaMs int) string {
	m := lrcTimestampCaptureRe.FindStringSubmatch(stamp)
	if m == nil {
		return stamp
	}
	mm, _ := strconv.Atoi(m[1])
	ss, _ := strconv.Atoi(m[2])
	frac, _ := strconv.Atoi(m[3])
	switch len(m[3]) {
	case 1:
		frac *= 100
	case 2:
		frac *= 10
	}
	return lrcTimestamp(mm*60000 + ss*1000 + frac + deltaMs)
}

// rankShapeBake 把逐句的中文译文烘进正文。style:same = 译文行跟原文同一个时间戳;later = 晚 1.5 秒的独立时间戳;
// next = 挂在下一句原文的时间戳上(酷我的烘法)。
func rankShapeBake(lrc, style string) string {
	stamps, texts := rankShapeLines(lrc)
	var out []string
	for i := range stamps {
		out = append(out, stamps[i]+texts[i])
		switch style {
		case "same":
			out = append(out, stamps[i]+rankShapeHanLine(i))
		case "later":
			out = append(out, rankShapeShiftStamp(stamps[i], 1500)+rankShapeHanLine(i))
		case "next":
			if i+1 < len(stamps) {
				out = append(out, stamps[i+1]+rankShapeHanLine(i))
			}
		}
	}
	return strings.Join(out, "\n")
}

func rankShapePlain(lrc string) string {
	_, texts := rankShapeLines(lrc)
	return strings.Join(texts, "\n")
}

// rankShapeSong 造一首整行与逐字对得上的歌:每行 4 秒。
func rankShapeSong(lines []string) (lrc, yrc string) {
	var l, y []string
	for i, text := range lines {
		ms := 2000 + 4000*i
		l = append(l, lrcTimestamp(ms)+text)
		y = append(y, yrcLine(ms, text))
	}
	return strings.Join(l, "\n"), strings.Join(y, "\n")
}

var (
	rankShapeJapanese = []string{
		"きみのこえが きこえる", "よるのまちを あるいて", "ほしをかぞえて ねむる", "あさがくれば わらう", "かぜにのって とんで",
		"うみのむこう までも", "ゆめをみてた ずっと", "なみだのあと かわく", "はなびらが まいおちる", "ひかりのなか はしる",
		"とおいそらを みあげて", "こころのおく ひびく",
	}
	rankShapeEnglish = []string{
		"Kills me slowly (slowly)", "No parens in this one", "Pray it away (away)", "Walking down the empty road", "Counting every single star",
		"Morning comes and I am gone (gone)", "Dreaming of another day", "Tears are drying on my face", "Petals falling to the ground",
		"Running through the light (the light)", "Looking at the distant sky", "Echoes deep inside my heart",
	}
	rankShapeKorean = []string{
		"너의 목소리가 들려", "밤거리를 걸어가", "별을 세며 잠들어", "아침이 오면 웃어", "바람을 타고 날아",
		"바다 건너 저편까지", "꿈을 꾸고 있었어", "눈물 자국이 말라", "꽃잎이 흩날려", "빛 속을 달려가",
	}
)

const (
	rankShapeBG       = "[2000,800](2100,300,0)ooh (2400,300,0)yeah\n[10000,800](10100,300,0)la (10400,300,0)la"
	rankShapeCredit   = "[00:00.00]作词 : 某人\n[00:01.00]作曲 : 某人\n[00:02.00]编曲 : 某人"
	rankShapeNoLyrics = "[00:00.00]此歌曲为没有填词的纯音乐，请您欣赏"
)

// rankShapeBakedSong:英文歌每句后面烘一行晚 1.5 秒的中文译文,整行和逐字轨里都有。
func rankShapeBakedSong(lines []string) (lrc, yrc string) {
	var l, y []string
	for i, text := range lines {
		ms := 2000 + 4000*i
		l = append(l, lrcTimestamp(ms)+text, lrcTimestamp(ms+1500)+rankShapeHanLine(i))
		y = append(y, yrcLine(ms, text), yrcLine(ms+1500, rankShapeHanLine(i)))
	}
	return strings.Join(l, "\n"), strings.Join(y, "\n")
}
