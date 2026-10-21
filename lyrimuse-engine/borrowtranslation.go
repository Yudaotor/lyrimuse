package main

import (
	"sort"
	"strings"
)

// 候选自己没有可用译文时借别的候选的译文(scoredLyricCandidateResult.LyricsTrFrom)。见 10 章决策 42。
//
// 译文是各源照自己正文的时间戳写的。借的时候先在供体那边按时间戳把译文配到正文行上,再按正文
// (normTimelineText 归一后逐字相同,剥掉演唱者标签)做 LCS 配到这一份的正文行上,译文挂到这一份那一行的原样时间戳下,
// App 按时间戳和原文把它贴回这一行。两边分行不同时(一句拆成两行),LCS 配上的两对之间再按「连着几行拼起来逐字
// 相同」成组(每边至多 borrowTranslationMaxGroup 行),供体那几行的译文接起来挂在这一份那组的第一行。配不上的行
// 不挂;配上的行不到这一份正文行数的 borrowTranslationMinShare 或不到 borrowTranslationMinLines 行,这个供体不用。
// 供体按名次挑第一个够数的,自己就是借来的不当供体。
//   - 放在打分和排序之后:借来的译文不加 translation 那 +50,名次不变。
//   - 自己的译文对当前目标语言可用的不借;借来的整份还要过 usableValueAdd。
const (
	borrowTranslationMinShare     = 0.6
	borrowTranslationMinLines     = 4
	borrowTranslationStampSlackMs = 20
	borrowTranslationMaxGroup     = 3
)

// lyricsTrSourceBorrowedPrefix + 供体源名 是借来的译文写进 enrichEntry.LyricsTrSource 的取值。
const lyricsTrSourceBorrowedPrefix = "borrowed:"

// lyricsTrSourceFor:把候选写进条目时 LyricsTrSource 填什么。自带的社区译文是空串。
func lyricsTrSourceFor(c *scoredLyricCandidateResult) string {
	if c.LyricsTrFrom == "" {
		return ""
	}
	return lyricsTrSourceBorrowedPrefix + c.LyricsTrFrom
}

type borrowLine struct {
	stamp string // 原样的时间戳,如 [01:02.34]
	ms    int
	norm  string
	text  string
}

// borrowLRCLines 把 LRC 展开成逐戳的行,按时刻排序;署名行和归一后为空的行不要。
func borrowLRCLines(lrc string) []borrowLine {
	speakers := lyricSpeakerLabels(lrc)
	var out []borrowLine
	for _, line := range strings.Split(lrc, "\n") {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) == 0 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || isCreditLine(text) {
			continue
		}
		n := normTimelineText(timelineSungText(text, speakers))
		if n == "" {
			continue
		}
		for _, s := range stamps {
			out = append(out, borrowLine{stamp: s[0], ms: lrcStampMs(s), norm: n, text: text})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ms < out[j].ms })
	return out
}

// borrowedTranslation 把供体的译文 donorTr(照 donorLyrics 的时间戳写的)搬到 lyrics 的时间轴上。
// 不够数时 ok 为假。纯函数。
func borrowedTranslation(lyrics, donorLyrics, donorTr string) (string, bool) {
	own := borrowLRCLines(lyrics)
	donor := borrowLRCLines(donorLyrics)
	var trLines []borrowLine
	for _, line := range strings.Split(donorTr, "\n") {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		for _, s := range stamps {
			trLines = append(trLines, borrowLine{ms: lrcStampMs(s), text: text})
		}
	}
	sort.SliceStable(trLines, func(i, j int) bool { return trLines[i].ms < trLines[j].ms })
	// 供体正文同一时刻有几行、译文也有几条时按先后一一配对;译文条数不够时后面那行沿用窗口里的第一条。
	donorTrText := make([]string, len(donor))
	used := make([]bool, len(trLines))
	for j, d := range donor {
		first := -1
		k := sort.Search(len(trLines), func(k int) bool { return trLines[k].ms >= d.ms-borrowTranslationStampSlackMs })
		for ; k < len(trLines) && trLines[k].ms <= d.ms+borrowTranslationStampSlackMs; k++ {
			if first < 0 {
				first = k
			}
			if !used[k] {
				break
			}
		}
		switch {
		case k < len(trLines) && trLines[k].ms <= d.ms+borrowTranslationStampSlackMs:
			used[k] = true
			donorTrText[j] = trLines[k].text
		case first >= 0:
			donorTrText[j] = trLines[first].text
		}
	}
	var out []string
	if tag := lrcOffsetTagRe.FindString(lyrics); tag != "" {
		out = append(out, tag)
	}
	n := 0
	for _, g := range borrowLineGroups(own, donor) {
		var parts []string
		for j := g.donorFrom; j < g.donorTo; j++ {
			if donorTrText[j] != "" {
				parts = append(parts, donorTrText[j])
			}
		}
		if len(parts) == 0 {
			continue
		}
		out = append(out, own[g.ownFrom].stamp+strings.Join(parts, " "))
		n += g.ownTo - g.ownFrom
	}
	if n < borrowTranslationMinLines || float64(n) < borrowTranslationMinShare*float64(len(own)) {
		return "", false
	}
	return strings.Join(out, "\n"), true
}

// borrowGroup:这一份的 own[ownFrom:ownTo] 跟供体的 donor[donorFrom:donorTo] 是同一段正文。
type borrowGroup struct{ ownFrom, ownTo, donorFrom, donorTo int }

// borrowLineGroups:先按整行逐字相同做 LCS,再在相邻两对之间按拼接成组(borrowGapGroups)。按 ownFrom 升序。
func borrowLineGroups(own, donor []borrowLine) []borrowGroup {
	align := timelineLCSAlignFunc(len(own), len(donor), func(i, j int) bool { return own[i].norm == donor[j].norm })
	var out []borrowGroup
	oi, di := 0, 0
	for i, j := range align {
		if j < 0 {
			continue
		}
		out = append(out, borrowGapGroups(own, donor, oi, i, di, j)...)
		out = append(out, borrowGroup{i, i + 1, j, j + 1})
		oi, di = i+1, j+1
	}
	return append(out, borrowGapGroups(own, donor, oi, len(own), di, len(donor))...)
}

// borrowGapGroups:两边各自一段没配上的行,从头起逐组往后配:较短的一边往后接一行,直到两边拼出来逐字相同就成一组;
// 一边拼满 borrowTranslationMaxGroup 行或到了这段末尾还对不上就停,后面的不配。
func borrowGapGroups(own, donor []borrowLine, oi, oEnd, di, dEnd int) []borrowGroup {
	var out []borrowGroup
	for oi < oEnd && di < dEnd {
		a, b := own[oi].norm, donor[di].norm
		oj, dj := oi+1, di+1
		for a != b {
			switch {
			case len(a) < len(b) && oj < oEnd && oj-oi < borrowTranslationMaxGroup:
				a += own[oj].norm
				oj++
			case len(b) < len(a) && dj < dEnd && dj-di < borrowTranslationMaxGroup:
				b += donor[dj].norm
				dj++
			default:
				return out
			}
		}
		out = append(out, borrowGroup{oi, oj, di, dj})
		oi, di = oj, dj
	}
	return out
}

// applyBorrowedTranslations 给自己没有可用译文的候选借一份。results 已按名次排好;两条流水线都在排序之后调。
func applyBorrowedTranslations(results []scoredLyricCandidateResult) {
	target := features().LyricsTranslationLanguage
	if target == "" {
		return
	}
	for i := range results {
		r := &results[i]
		if r.Score < 0 || r.Lyrics == "" {
			continue
		}
		if own, _ := usableValueAdd(r.Lyrics, r.LyricsTr, r.LyricsTrLang, "", target); own {
			continue
		}
		for j := range results {
			d := &results[j]
			// 供体没有译文就不解析两份正文去配对:每到一个源都要重排一次,多数候选不带译文。
			if j == i || d.Score < 0 || d.Lyrics == "" || d.LyricsTr == "" || d.LyricsTrFrom != "" {
				continue
			}
			tr, ok := borrowedTranslation(r.Lyrics, d.Lyrics, d.LyricsTr)
			if !ok {
				continue
			}
			if usable, _ := usableValueAdd(r.Lyrics, tr, d.LyricsTrLang, "", target); !usable {
				continue
			}
			r.LyricsTr, r.LyricsTrLang, r.LyricsTrFrom = tr, d.LyricsTrLang, d.Source
			break
		}
	}
}

// gainBorrowedTranslation:条目自己没有可用译文、这一轮有候选借到了译文时,按条目自己的正文再对齐一次补进条目
// (正文没换、只差几个时间戳时也补得上,对不齐就不补)。升级重试与重新打分两条路在正文没换时调。
func gainBorrowedTranslation(e *enrichEntry, scored []scoredLyricCandidateResult) bool {
	target := myMemoryLangCode(features().LyricsTranslationLanguage)
	if target == "" || e.Instrumental || e.Lyrics.IsZero() || translationUsable(*e, target) {
		return false
	}
	for i := range scored {
		c := &scored[i]
		if c.Score < 0 || c.LyricsTrFrom == "" {
			continue
		}
		tr := c.LyricsTr
		if !e.Lyrics.EqualString(c.Lyrics) {
			var ok bool
			if tr, ok = borrowedTranslation(e.Lyrics.String(), c.Lyrics, c.LyricsTr); !ok {
				continue
			}
		}
		e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = bt(tr), c.LyricsTrLang, lyricsTrSourceFor(c)
		return true
	}
	return false
}
