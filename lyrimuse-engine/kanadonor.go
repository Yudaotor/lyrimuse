package main

import (
	"strings"
	"unicode"
)

// 借来的假名标注:当前正文自己不带 `[kana:]`(只有酷狗 / QQ / LRCLIB 那几家给,见 qq.go splitQRCKanaLine、
// lyricsfile.go lyricsfileKanaLine)时,从同一轮里过了身份关、带标注的别的候选借。标注写的是这首歌实际怎么唱
// (「明日」唱 あした 还是 あす),分词器从字面判断不出来,见 10 章决策 44。
//
// 借法:按行借。标注按顺序对齐整份正文的汉字,两家正文开头署名、换行稍有不同整份就对不上,所以拆成「每一行的
// 条目」,当前正文里哪一行跟对方某一行归一后一样(kanaLineKey:汉字和假名的顺序一样),就用对方那一行的条目。
// 产物是一份只含借到的那些行的小 LRC(lyrics_kana):行文字用当前正文的写法、配一行重新拼好的 `[kana:]`,
// App 和 lyrics-romanize 都直接交给 KanaAnnotation.parse,不另写一套对齐。时间戳是占位,没有含义。
// 它留在索引里、不进正文小文件:只有借到的日文歌有,条目去掉了时间,一首约 1 KB。
//
// 不绑正文指纹:条目只对文字一样的行生效,正文换了,对不上的行自然不用;同一首歌同一句词的读音不随版本变。

// kanaDonorMinLines:借到的行少于这么多时不借。一两行短句(「Ah」「Yeah」这类之外、带汉字的)对上的偶然性大,
// 而这几行分词器也多半读得对。
const kanaDonorMinLines = 2

// kanaTimePlaceholder:lyrics_kana 每一行的时间戳。KanaAnnotation.bodyLines 只认带时间戳的行。
const kanaTimePlaceholder = "[00:00.00]"

// kanaDonorLRC:给 lyrics / yrc 这份正文借一份假名标注(格式见文件头注)。正文自己带 `[kana:]`、这首不像日文、
// 没有过身份关又带标注的候选、或借到的行少于 kanaDonorMinLines 时返回空串。
func kanaDonorLRC(lyrics, yrc string, scored []scoredLyricCandidateResult) string {
	if lyrics == "" || strings.Contains(lyrics, "[kana:") || kanaRatio(lyrics) < kanaDonorMinKanaRatio {
		return ""
	}
	targets := kanaTargetLines(lyrics, yrc)
	if len(targets) == 0 {
		return ""
	}
	var best map[string]string
	bestHits := 0
	for _, c := range scored {
		if c.Score < 0 || !strings.Contains(c.Lyrics, "[kana:") {
			continue
		}
		byKey := kanaEntriesByLineKey(c.Lyrics)
		hits := 0
		for _, t := range targets {
			if _, ok := byKey[kanaLineKey(t)]; ok {
				hits++
			}
		}
		if hits > bestHits {
			best, bestHits = byKey, hits
		}
	}
	if bestHits < kanaDonorMinLines {
		return ""
	}
	var tag, body strings.Builder
	for _, t := range targets {
		raw, ok := best[kanaLineKey(t)]
		if !ok {
			continue
		}
		tag.WriteString(raw)
		body.WriteString("\n" + kanaTimePlaceholder + t)
	}
	return "[kana:" + tag.String() + "]" + body.String()
}

// kanaDonorMinKanaRatio:正文里假名占比低于这个值的不借(不像日文歌)。跟 Romanizer.looksJapaneseSong 不是同一个
// 判据,只是挡掉中文 / 韩文歌白跑一遍对齐;判宽一点无害,不是日文的行对不上别家的日文标注。
const kanaDonorMinKanaRatio = 0.05

// kanaTargetLines:当前正文里要借标注的行 —— 整行歌词的正文行和逐字歌词每一行拼起来的文字(两边写法可能不同,
// App 两种都会拿来查),只留带待标字的,去重、保持先后。
func kanaTargetLines(lyrics, yrc string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(t string) {
		t = strings.TrimSpace(t)
		if t == "" || seen[t] || !strings.ContainsFunc(t, kanaNeedsAnnotation) {
			return
		}
		seen[t] = true
		out = append(out, t)
	}
	for _, t := range kanaBodyLines(lyrics) {
		add(t)
	}
	for _, t := range strings.Split(yrcPlainLines(yrc), "\n") {
		add(t)
	}
	return out
}

// kanaEntriesByLineKey:把一份带 `[kana:]` 的 LRC 拆成「正文行的归一键 → 这一行对应的那段原始条目」。条目要按
// 整份正文的待标字对齐(跟 App KanaAnnotation.parse 同一口径):总数对不上返回 nil;一个条目跨了行的那两行不收;
// 归一键相同、条目不同的行(同一句两处标得不一样)都不收。
func kanaEntriesByLineKey(lrc string) map[string]string {
	raw := ""
	for _, ln := range splitLyricLines(lrc) {
		s := strings.TrimSpace(ln)
		if strings.HasPrefix(s, "[kana:") && strings.HasSuffix(s, "]") {
			raw = s[len("[kana:") : len(s)-1]
			break
		}
	}
	entries := kanaRawEntries(raw)
	if len(entries) == 0 {
		return nil
	}
	lines := kanaBodyLines(lrc)
	total := 0
	for _, e := range entries {
		total += e.count
	}
	need := 0
	for _, l := range lines {
		need += kanaNeedCount(l)
	}
	if need != total {
		return nil
	}
	out := map[string]string{}
	conflict := map[string]bool{}
	idx := 0
	carry := 0 // 上一行最后一个条目还没盖完的字数:这一行开头先把它们盖掉,这一行不收
	for _, l := range lines {
		n := kanaNeedCount(l)
		clean := carry == 0
		take := min(carry, n)
		carry -= take
		n -= take
		var b strings.Builder
		for n > 0 && idx < len(entries) {
			e := entries[idx]
			idx++
			if e.count > n {
				carry = e.count - n
				clean = false
				n = 0
				break
			}
			b.WriteString(e.raw)
			n -= e.count
		}
		if !clean || b.Len() == 0 {
			continue
		}
		key := kanaLineKey(l)
		if prev, ok := out[key]; ok && prev != b.String() {
			conflict[key] = true
		}
		out[key] = b.String()
	}
	for k := range conflict {
		delete(out, k)
	}
	return out
}

type kanaRawEntry struct {
	count int
	raw   string // 开头那个数字字符 + 读音,去掉了 (起始,时长):App 不读里面的时间,留着只占地方
}

// kanaRawEntries:把 `[kana:]` 的内容切成条目,切法跟 App KanaAnnotation.parseEntries 一致:一个数字字符开一条,读音
// 读到下一个数字字符为止,`(…)` 整段跳过不看里面的数字;数字 0 按 1 算;开头落单的杂字符丢掉。
func kanaRawEntries(s string) []kanaRawEntry {
	rs := []rune(s)
	var out []kanaRawEntry
	i := 0
	for i < len(rs) {
		if !unicode.IsNumber(rs[i]) {
			i++
			continue
		}
		raw := []rune{rs[i]}
		n := max(1, kanaDigitValue(rs[i]))
		i++
		for i < len(rs) && !unicode.IsNumber(rs[i]) {
			if rs[i] == '(' {
				for i < len(rs) && rs[i] != ')' {
					i++
				}
			} else {
				raw = append(raw, rs[i])
			}
			i++
		}
		out = append(out, kanaRawEntry{count: n, raw: string(raw)})
	}
	return out
}

// kanaDigitValue:条目开头那个数字的值,半角、全角都认;别的数字字符(①这类)按 1 算。
func kanaDigitValue(r rune) int {
	switch {
	case r >= '0' && r <= '9':
		return int(r - '0')
	case r >= '０' && r <= '９':
		return int(r - '０')
	}
	return 1
}

func kanaNeedCount(line string) int {
	n := 0
	for _, r := range line {
		if kanaNeedsAnnotation(r) {
			n++
		}
	}
	return n
}

// kanaLineKey:一行歌词的归一键 —— 去掉空白、标点、符号,全角 ASCII 换成半角,拉丁字母小写。汉字和假名原样留着,
// 所以键相同的两行,待标字的个数和先后一定相同,对方那一行的条目能原样对到这一行上。
func kanaLineKey(line string) string {
	var b strings.Builder
	for _, r := range line {
		if r >= 0xFF01 && r <= 0xFF5E {
			r -= 0xFEE0
		}
		if unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r) {
			continue
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

// lyricsKanaVersion:借假名标注的版本。一轮解析里问到过带标注的源(酷狗 / QQ 过了身份关的候选)、或者补问过一次,
// 条目的 LyricsKanaChecked 记成它。
const lyricsKanaVersion = 1

// kanaDonorSources:会在正文里带 `[kana:]` 的源。
var kanaDonorSources = map[string]bool{"kugou": true, "qq": true, "lrclib": true}

// refreshKana:一轮写完正文之后刷新借来的假名标注。正文自己带标注时清掉;这一轮借到了就换成这一轮的;没借到时
// 原样留着(这一轮可能根本没问到带标注的源,旧的那份只对文字一样的行生效,留着无害)。这一轮有带标注的源给出过
// 身份关的候选时记下 LyricsKanaChecked,存量补问(kanabackfill.go)不必再来。
func refreshKana(e *enrichEntry, scored []scoredLyricCandidateResult) {
	lyrics := e.Lyrics.String()
	switch {
	case strings.Contains(lyrics, "[kana:"):
		e.LyricsKana = ""
	default:
		if donor := kanaDonorLRC(lyrics, e.LyricsYRC.String(), scored); donor != "" {
			e.LyricsKana = donor
		}
	}
	for _, c := range scored {
		if kanaDonorSources[c.Source] && c.Score >= 0 {
			e.LyricsKanaChecked = lyricsKanaVersion
			return
		}
	}
}
