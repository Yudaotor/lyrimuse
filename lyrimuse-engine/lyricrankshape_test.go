package main

import (
	"reflect"
	"slices"
	"strings"
	"testing"
)

// 每个来源一组「每一栏都交了」的输入,看排序读了它的哪几栏、译文怎么标、烘入译文摘不摘、括号背景人声拆不拆、凭什么搭
// 纯音乐标记;参照(handwrittenRankLyricSourceResults)和生产(rankLyricSourceResults)看到的都要等于期望表
// lyricSourceCandidateShapes 与 parenBGSources。输入按公共栏写,内容在专用子结构里的源换成它实际交的摆法(rankShapeInput)。

type rankFunc func(artist, title, album string, durationSecs float64, raw map[string]lyricSourceResult) []scoredLyricCandidateResult

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
	lrc, yrc := rankParitySong(lines)
	return lyricSourceResult{
		source: source, lyr: lrc, yrc: yrc, tr: rankParityAux(lrc, "zh", 1), roma: rankParityAux(lrc, "latin", 1),
		matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, matchAlbum: rankShapeAlbum,
		matchCover: "https://example.com/shape.jpg", srcDur: rankShapeDuration,
		isrc: "USUM71703861", sourceURL: "https://www.megalobiz.com/lrc/maker/x.1", language: songLanguageMandarin,
		identityFromLocalClient: true, bg: rankParityBG, songwriters: []string{"Writer A"}, trackIDs: []string{"97773"},
	}
}

// rankShapeInput:r 是按公共栏写的一份结果,换成这个源实际交上来的摆法:网易云的内容在 ne 上,公共栏上那几样是空的。
func rankShapeInput(r lyricSourceResult) lyricSourceResult {
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

func rankShapeRun(rank rankFunc, lang string, r lyricSourceResult) (cand *scoredLyricCandidateResult, instrumental bool) {
	featuresRef().LyricsTranslationLanguage = lang
	r = rankShapeInput(r)
	out := rank(rankShapeArtist, rankShapeTitle, rankShapeAlbum, rankShapeDuration, map[string]lyricSourceResult{r.source: r})
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
	out := make([]string, len(rankParityEnglish))
	for i, l := range rankParityEnglish {
		if j := strings.Index(l, " ("); j >= 0 {
			l = l[:j]
		}
		out[i] = l
	}
	return out
}

// rankShapeObserved:rank 对 source 实际读了什么,另返回括号背景人声拆不拆。source 交了候选才有意义。
func rankShapeObserved(t *testing.T, rank rankFunc, source string) (shape lyricSourceCandidateShape, paren bool) {
	t.Helper()
	full := rankShapeResult(source, rankParityJapanese)
	c, _ := rankShapeRun(rank, "zh", full)
	if c == nil {
		t.Fatalf("%s:每一栏都交了却没有候选", source)
	}
	plain := full
	plain.plainOnly = true
	p, _ := rankShapeRun(rank, "zh", plain)
	if p == nil {
		t.Fatalf("%s:带纯文本标记的那份没有候选", source)
	}
	// 另一栏纯文本:带时间轴的正文不交,只交不带时间戳的那一栏,逐字、译文照交。出来的得是纯文本候选,逐字、译文都不带。
	second := full
	second.lyr, second.untimed = "", rankParityPlain(full.lyr)
	u, _ := rankShapeRun(rank, "zh", second)
	if u != nil && (!u.PlainTextOnly || u.HasWordTiming || u.LyricsYRC != "" || u.LyricsTr != "" || u.Lyrics != second.untimed) {
		t.Fatalf("%s:另一栏纯文本出来的候选不对:%+v", source, *u)
	}
	seen := map[string]bool{
		"逐字": c.HasWordTiming, "读音": c.LyricsRoma != "", "自报曲长": c.SourceReportedDurationSecs != 0, "专辑": c.Album != "",
		"封面": c.CoverURL != "", "语种": c.Language != "", "本机身份": c.IdentityFromLocalClient, "纯文本": p.PlainTextOnly,
		"ISRC": c.ISRC != "", "来源链接": c.SourceURL != "", "背景人声轨": c.LyricsBG == rankParityBG, "作者": len(c.Songwriters) > 0,
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
		tc, _ := rankShapeRun(rank, combo[0], r)
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
	lrc, _ := rankParitySong(rankShapePlainLines())
	baked := lyricSourceResult{source: source, lyr: rankParityBake(lrc, "later"), matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
	if bc, _ := rankShapeRun(rank, "zh", baked); bc != nil && bc.BakedTranslationLines > 0 {
		shape.baked = "strip"
		if bc.LyricsTr != "" {
			if bc.LyricsTrLang != "zh" {
				t.Fatalf("%s:摘出来的烘入译文标成了 %q", source, bc.LyricsTrLang)
			}
			shape.baked = "adopt"
		}
	}

	// 括号背景人声:带括号段的英文歌,整行加逐字。
	parenLRC, parenYRC := rankParitySong(rankParityEnglish)
	pc, _ := rankShapeRun(rank, "zh", lyricSourceResult{source: source, lyr: parenLRC, yrc: parenYRC, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration})
	paren = pc != nil && pc.LyricsBG != ""

	// 纯音乐标记:四种说法各单独喂一次。没交正文加无人声那一种,认「署名行加无人声」的源也会搭(空正文算只有署名行),
	// 所以只在署名行那一种不搭时才记成「没正文加无人声」。
	meta := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, matchAlbum: rankShapeAlbum, srcDur: rankShapeDuration}
	said, credit, placeholder, bare := meta, meta, meta, meta
	said.instrumental = true
	credit.lyr, credit.noVocals = rankParityCredit, true
	placeholder.lyr = rankParityNoLyrics
	bare.noVocals = true
	var signals []string
	marks := make([]bool, 4)
	for i, r := range []lyricSourceResult{said, credit, placeholder, bare} {
		_, marks[i] = rankShapeRun(rank, "zh", r)
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
	return shape, paren
}

func TestRankShapesMatchExpected(t *testing.T) {
	saveRankParityState(t)
	setNativeLyricSourcesForPlayer("")
	featuresRef().LyricsSources = nil
	var special []string
	for _, source := range lyricCandidateTieOrder {
		want, ok := lyricSourceCandidateShapes[source]
		if !ok {
			special = append(special, source)
			continue
		}
		for name, rank := range map[string]rankFunc{"参照": handwrittenRankLyricSourceResults, "生产": rankLyricSourceResults} {
			got, paren := rankShapeObserved(t, rank, source)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("%s(%s)\n  看到 %+v\n  期望 %+v", source, name, got, want)
			}
			// 括号段要对着逐字拆,候选不读逐字的源登记了也拆不出来。
			if wantParen := parenBGSources[source] && slices.Contains(strings.Fields(want.reads), "逐字"); paren != wantParen {
				t.Errorf("%s(%s):括号背景人声拆不拆 = %v,该是 %v(parenBGSources %v)", source, name, paren, wantParen, parenBGSources[source])
			}
		}
	}
	if want := []string{lyricSourceAMLL}; !slices.Equal(special, want) {
		t.Errorf("不在 lyricSourceCandidateShapes 里的来源 %v,该只有候选还由专门那一段装的 %v", special, want)
	}
	for source := range lyricSourceCandidateShapes {
		if !slices.Contains(lyricCandidateTieOrder, source) {
			t.Errorf("lyricSourceCandidateShapes 里有没登记的来源 %s", source)
		}
	}
}

// 结果的内容在专用子结构里的源,正文不过排序开头那两步对公共栏正文的清理:行内逐字写法不拆,匹配到伴奏版时占位正文不丢。
// 同样的内容放在公共栏上的源两样都做。摊平(unpackSourceResults)因此排在那两步之后;参照和生产都这样。
func TestUnpackedLyricsSkipBodyCleanup(t *testing.T) {
	saveRankParityState(t)
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
		for name, rank := range map[string]rankFunc{"参照": handwrittenRankLyricSourceResults, "生产": rankLyricSourceResults} {
			meta := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
			word := meta
			word.lyr = inline
			c, _ := rankShapeRun(rank, "zh", word)
			if c == nil {
				t.Fatalf("%s(%s):行内逐字写法的正文没有候选", source, name)
			}
			if kept := strings.Contains(c.Lyrics, "<00:"); kept != inPayload {
				t.Errorf("%s(%s):行内逐字写法留在正文里=%v,该是 %v", source, name, kept, inPayload)
			}
			inst := meta
			inst.lyr, inst.matchTitle = rankParityNoLyrics, rankShapeTitle+" (Instrumental)"
			p, _ := rankShapeRun(rank, "zh", inst)
			if kept := p != nil; kept != inPayload {
				t.Errorf("%s(%s):匹配到伴奏版时占位正文还在=%v,该是 %v", source, name, kept, inPayload)
			}
		}
	}
	if unpacked == 0 {
		t.Error("没有一个内容在专用子结构里的源,这条什么都没比")
	}
}

// rankParityCoverageGaps:语料的计数里,哪个来源的哪种装配结果一次都没出现。读的栏要出现过「读进去了」,不读的栏要出现过
// 「交了但没读」;每个来源都要交过候选、过过闸、跟别的源同过分。
func rankParityCoverageGaps(ta *rankParityTally) []string {
	var gaps []string
	need := func(source, what string) {
		if ta.counts[source+"/"+what] == 0 {
			gaps = append(gaps, source+"/"+what)
		}
	}
	unread := map[string]string{
		"逐字": "逐字没进候选", "读音": "读音没进结果", "自报曲长": "自报曲长没进候选", "专辑": "专辑没进候选", "封面": "封面没进候选",
		"语种": "语种没进候选", "本机身份": "本机身份没进候选", "纯文本": "纯文本标记没进候选", "ISRC": "ISRC没进候选",
		"来源链接": "来源链接没进候选", "背景人声轨": "背景人声没进结果", "作者": "作者没进结果",
	}
	read := map[string]string{"背景人声轨": "背景人声"}
	for _, source := range lyricCandidateTieOrder {
		need(source, "候选")
		need(source, "过闸")
		// 导入库自带 300 分(scoreTermImported),碰不上跟别的源同分。
		if source != importLyricsSource && ta.counts[source+"/同分领先"]+ta.counts[source+"/同分落后"] == 0 {
			gaps = append(gaps, source+"/同分")
		}
		shape, ok := lyricSourceCandidateShapes[source]
		if !ok {
			continue
		}
		reads := strings.Fields(shape.reads)
		for _, f := range rankShapeFields {
			switch {
			case f == "另一栏纯文本":
				if slices.Contains(reads, f) {
					need(source, "纯文本")
				}
			case !slices.Contains(reads, f):
				need(source, unread[f])
			case read[f] != "":
				need(source, read[f])
			default:
				need(source, f)
			}
		}
		need(source, "译文没进结果")
		if shape.translation != "" {
			need(source, "译文")
		}
		if shape.baked != "" {
			need(source, "烘入译文")
		}
		if parenBGSources[source] && slices.Contains(reads, "逐字") {
			need(source, "括号背景人声")
		}
		if shape.instrumental != "" {
			need(source, "纯音乐标记")
		}
	}
	for _, source := range lyricSourceNames {
		need(source, "有歌没词标记")
	}
	for _, source := range []string{lyricSourceNetease, lyricSourceQQ, lyricSourceSoda, lyricSourceAppleMusic, spotifyLocalLyricsSource} {
		need(source, "播放器纯音乐标记")
	}
	for _, source := range []string{lyricSourceLRCLIB, lyricSourceQQ, lyricSourceNetease, lyricSourceMigu, lyricSourceKugou} {
		need(source, "纯音乐标记")
	}
	return gaps
}

// 几个源同时说这首是纯音乐时,标记记在 InstrumentalRank 最靠前的那个头上;把它拿掉,轮到下一个。参照和生产都这样。
func TestInstrumentalMarkerFollowsRank(t *testing.T) {
	saveRankParityState(t)
	setNativeLyricSourcesForPlayer("")
	order := registryNames(func(d *ProviderDescriptor) bool { return d.InstrumentalRank > 0 },
		func(d *ProviderDescriptor) int { return d.InstrumentalRank })
	if want := []string{lyricSourceLRCLIB, lyricSourceQQ, lyricSourceNetease, lyricSourceMigu, lyricSourceKugou}; !slices.Equal(order, want) {
		t.Fatalf("搭纯音乐标记的先后 %v,期望 %v", order, want)
	}
	// 每个源用它认的那种说法:明说的清空正文、署名行加无人声、占位句;网易云的在 ne 上。
	claim := func(source string) lyricSourceResult {
		r := lyricSourceResult{source: source, matchTitle: rankShapeTitle, matchArtist: rankShapeArtist, srcDur: rankShapeDuration}
		switch source {
		case lyricSourceNetease:
			r.ne = neteaseInfo{Title: rankShapeTitle, Artist: rankShapeArtist, PureMusic: true}
		case lyricSourceMigu:
			r.lyr = rankParityNoLyrics
		case lyricSourceKugou:
			r.lyr, r.noVocals = rankParityCredit, true
		default:
			r.instrumental = true
		}
		return r
	}
	for name, rank := range map[string]rankFunc{"参照": handwrittenRankLyricSourceResults, "生产": rankLyricSourceResults} {
		for first := range order {
			raw := map[string]lyricSourceResult{}
			for _, source := range order[first:] {
				raw[source] = claim(source)
			}
			var marked []string
			for _, r := range rank(rankShapeArtist, rankShapeTitle, rankShapeAlbum, rankShapeDuration, raw) {
				if r.Instrumental {
					marked = append(marked, r.Source)
				}
			}
			if !slices.Equal(marked, order[first:first+1]) {
				t.Errorf("%s:%v 同时说是纯音乐,标记记在 %v 头上,该是 %s", name, order[first:], marked, order[first])
			}
		}
	}
}
