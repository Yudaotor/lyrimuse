package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"slices"
	"sort"
	"strings"
	"unicode"
)

// 演唱者标注:Musixmatch 的 performer_tagging(macro.subtitles.get 的 part 里加 track_performer_tagging 才回)按文字
// 片段标出谁在唱 —— 一整段、一句,或一句里括号中的和声。这里把它换算成「当前正文每一行是谁唱的」,存进条目的
// lyrics_speakers;App 核对过正文指纹,把 v1：/v2：/合： 补到对应行上,交给现成的对唱分栏(LyricDuet)。
// 正文本身不动:升级重试、重选、跨专辑复用好几处靠「候选正文与缓存正文逐字相同」认是不是同一份,写进正文会让
// 它们全部失配。决策见 09 章决策 163。

// musixmatchPerformerSpan:标注里的一个片段。performers 只收具体歌手的 ID(mxm:artist:…);「未知」「和声」「旁白」
// 这类没有歌手 ID 的标签不收,只剩这类标签的片段 performers 为空(仍要参与定位,见 musixmatchLineOwners)。
type musixmatchPerformerSpan struct {
	text       string
	performers []string
}

// lyricSpeakers:条目里的演唱者标注。For 是它对应的那份正文的指纹(lyricSpeakersFingerprint);LRC / YRC 跟
// lyrics / lyrics_yrc 按原文行号一一对应(splitLyricLines 切出来的下标),值是 v1…v4、合 或空串。App 侧
// LyricSpeakerTags 按同样的切法补标记,指纹对不上就整份不用。
type lyricSpeakers struct {
	For string   `json:"for"`
	LRC []string `json:"lrc,omitempty"`
	YRC []string `json:"yrc,omitempty"`
}

const (
	// lyricSpeakersMaxSingers:标注里认出的演唱者超过这么多位不标。App 只分左右两边,第 3 位起轮回左边,
	// 人一多左右就对不上具体的人。
	lyricSpeakersMaxSingers = 4
	// lyricSpeakersMinCoverage:正文里标得上的行不到这个比例时整首不标(多半对到了别的版本上)。
	lyricSpeakersMinCoverage = 0.5
	// lyricSpeakersMinLineMatch:逐字对齐那一步,一行至少这么多比例的字对上了才认它的归属。
	lyricSpeakersMinLineMatch = 0.4
	// lyricSpeakersMaxAlignCells:逐字对齐一段时 DP 的格数上限,超出的那一段不对。
	lyricSpeakersMaxAlignCells = 4_000_000
)

// lyricSpeakersGroupLabel:两位以上一起唱的行。LyricDuet 认它是合唱(居中)。
const lyricSpeakersGroupLabel = "合"

// lyricSpeakersFingerprint:去掉开头 BOM 的 lyrics + "\x01" + 去掉开头 BOM 的 yrc 的 SHA256,取前 12 位十六进制。
// App 侧 LyricSpeakerTags.fingerprint 必须是同一算法,两边各有一条同输入同输出的单测钉着。
func lyricSpeakersFingerprint(lyrics, yrc string) string {
	sum := sha256.Sum256([]byte(strings.TrimLeft(lyrics, "\uFEFF") + "\x01" + strings.TrimLeft(yrc, "\uFEFF")))
	return hex.EncodeToString(sum[:])[:12]
}

// speakersFromScored:这一轮过了身份关(分数不为负)、带演唱者标注的 Musixmatch 候选,换算到 lyrics / yrc 上。
// 正文自己带着认得出的演唱者标记、没有这样的候选、标注里的演唱者不是 2~lyricSpeakersMaxSingers 位,或者两份正文
// 都过不了 speakerLabels 的闸时返回 nil。
func speakersFromScored(lyrics, yrc string, scored []scoredLyricCandidateResult) *lyricSpeakers {
	if lyrics == "" && yrc == "" {
		return nil
	}
	var mx *scoredLyricCandidateResult
	for i := range scored {
		if scored[i].Source == "musixmatch" && scored[i].Score >= 0 && len(scored[i].Performers) > 0 {
			mx = &scored[i]
			break
		}
	}
	if mx == nil {
		return nil
	}
	if len(lyricSpeakerLabels(lyrics)) > 0 || len(lyricSpeakerLabels(yrcPlainLines(yrc))) > 0 {
		return nil
	}
	var mxLines []string
	for _, ln := range splitLyricLines(mx.Lyrics) {
		if t := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(ln, "")); t != "" && !isLRCMetaTagLine(ln) {
			mxLines = append(mxLines, t)
		}
	}
	owners := musixmatchLineOwners(mxLines, mx.Performers)
	mxKeys := make([]string, len(owners))
	singers := map[string]bool{}
	for j := range owners {
		mxKeys[j] = speakerLineKey(owners[j])
		if mxKeys[j] != "" && !strings.Contains(mxKeys[j], "+") {
			singers[mxKeys[j]] = true
		}
	}
	if len(singers) < 2 || len(singers) > lyricSpeakersMaxSingers {
		return nil
	}
	sp := &lyricSpeakers{For: lyricSpeakersFingerprint(lyrics, yrc)}
	if lyrics != "" {
		texts := speakerLineTexts(lyrics, false)
		sp.LRC = speakerLabels(speakerTransfer(mxLines, owners, mxKeys, texts), texts)
	}
	if yrc != "" {
		texts := speakerLineTexts(yrc, true)
		sp.YRC = speakerLabels(speakerTransfer(mxLines, owners, mxKeys, texts), texts)
	}
	if sp.LRC == nil && sp.YRC == nil {
		return nil
	}
	return sp
}

// refreshedSpeakers:一轮写完正文之后条目该带的演唱者标注。这一轮算得出就用新的;算不出时,旧的还对得上当前正文
// (指纹相同)就留着 —— 这一轮 Musixmatch 没应答不该把已有的抹掉;对不上就清掉。
func refreshedSpeakers(old *lyricSpeakers, lyrics, yrc string, scored []scoredLyricCandidateResult) *lyricSpeakers {
	if sp := speakersFromScored(lyrics, yrc, scored); sp != nil {
		return sp
	}
	if old != nil && old.For == lyricSpeakersFingerprint(lyrics, yrc) {
		return old
	}
	return nil
}

// yrcPlainLines:YRC 每行去掉行头和词标记后的文字,一行一句,给 lyricSpeakerLabels 认标记用。
func yrcPlainLines(yrc string) string {
	if yrc == "" {
		return ""
	}
	var b strings.Builder
	for _, ln := range splitLyricLines(yrc) {
		if !yrcLineTimeRegex.MatchString(ln) {
			continue
		}
		b.WriteString(strings.TrimSpace(yrcWordTokenRe.ReplaceAllString(yrcLineTimeRegex.ReplaceAllString(ln, ""), "")))
		b.WriteByte('\n')
	}
	return b.String()
}

// speakerLineTexts:raw 按原文行(splitLyricLines)切开后每行的正文;元数据标签行、署名行、单独一行的演唱者名或段落名
// (speakerNonLyricLine)和空行给空串,它们不参与对齐、也不标。yrc 为 true 时按 YRC 的行头与词标记去掉时间信息。
func speakerLineTexts(raw string, yrc bool) []string {
	lines := splitLyricLines(raw)
	out := make([]string, len(lines))
	for i, ln := range lines {
		var text string
		if yrc {
			if !yrcLineTimeRegex.MatchString(ln) {
				continue
			}
			text = strings.TrimSpace(yrcWordTokenRe.ReplaceAllString(yrcLineTimeRegex.ReplaceAllString(ln, ""), ""))
		} else {
			if isLRCMetaTagLine(ln) {
				continue
			}
			text = strings.TrimSpace(lrcTimestampRe.ReplaceAllString(ln, ""))
		}
		if text == "" || isCreditLine(text) || speakerNonLyricLine(text) {
			continue
		}
		out[i] = text
	}
	return out
}

// speakerNonLyricLine:单独一行的演唱者名或段落名 —— 以冒号结尾的短行(「Singer Name：」)、整行方括号(「[Chorus]」)。
func speakerNonLyricLine(s string) bool {
	if (strings.HasSuffix(s, "：") || strings.HasSuffix(s, ":")) && len(strings.Fields(s)) <= 4 && len([]rune(s)) <= 40 {
		return true
	}
	return strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]")
}

// speakerRunes:按字比对用的归一化(转简体、小写,只留字母和数字),同时给出每个字在不在括号里。
func speakerRunes(s string) ([]rune, []bool) {
	var out []rune
	var inParen []bool
	depth := 0
	for _, r := range toSimplified(strings.ToLower(s)) {
		switch r {
		case '(', '（':
			depth++
			continue
		case ')', '）':
			if depth > 0 {
				depth--
			}
			continue
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			out = append(out, r)
			inParen = append(inParen, depth > 0)
		}
	}
	return out, inParen
}

// speakerAlignKey:整行对齐用的键 —— 去掉括号里的和声再归一化。有的源把和声写进正文、有的不写,这样都对得上。
func speakerAlignKey(s string) string {
	rs, inParen := speakerRunes(s)
	var b strings.Builder
	for i, r := range rs {
		if !inParen[i] {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// speakerChar:一个字(归一化后)和它的归属。key 是演唱者 ID,两人以上按字典序用 + 连起来;空 = 没有片段盖到它,
// 或盖到它的片段没有具体歌手。bg = 这个字在标注片段的括号里(和声)。
type speakerChar struct {
	r   rune
	key string
	bg  bool
}

// musixmatchLineOwners:标注片段按文字顺序依次落到 Musixmatch 那份正文的行(lines,已去掉时间戳)上,给出每行每个字的
// 归属。片段从上一个片段结束处往后找,找不到再从头找,都找不到的丢掉;一个字只认第一个盖到它的片段。
func musixmatchLineOwners(lines []string, spans []musixmatchPerformerSpan) [][]speakerChar {
	var flat []rune
	var lineOf []int
	for i, ln := range lines {
		rs, _ := speakerRunes(ln)
		for _, r := range rs {
			flat = append(flat, r)
			lineOf = append(lineOf, i)
		}
	}
	keys := make([]string, len(flat))
	bgs := make([]bool, len(flat))
	owned := make([]bool, len(flat))
	cursor := 0
	for _, sp := range spans {
		rs, inParen := speakerRunes(sp.text)
		if len(rs) == 0 {
			continue
		}
		ids := slices.Clone(sp.performers)
		sort.Strings(ids)
		key := strings.Join(slices.Compact(ids), "+")
		p := speakerIndexRunes(flat, rs, cursor)
		if p < 0 {
			p = speakerIndexRunes(flat, rs, 0)
		}
		if p < 0 {
			continue
		}
		for k := range rs {
			if !owned[p+k] {
				owned[p+k], keys[p+k], bgs[p+k] = true, key, inParen[k]
			}
		}
		cursor = max(cursor, p+len(rs))
	}
	out := make([][]speakerChar, len(lines))
	for k, r := range flat {
		out[lineOf[k]] = append(out[lineOf[k]], speakerChar{r: r, key: keys[k], bg: bgs[k]})
	}
	return out
}

// speakerIndexRunes:needle 在 hay[from:] 里第一次出现的下标,没有返回 -1。
func speakerIndexRunes(hay, needle []rune, from int) int {
	for i := from; i+len(needle) <= len(hay); i++ {
		if slices.Equal(hay[i:i+len(needle)], needle) {
			return i
		}
	}
	return -1
}

// speakerLineKey:一行归谁 —— 括号外字数最多的那组演唱者(括号外没有归属就看括号里的),都没有为空。
func speakerLineKey(chars []speakerChar) string {
	main, bg := map[string]int{}, map[string]int{}
	for _, c := range chars {
		if c.key == "" {
			continue
		}
		if c.bg {
			bg[c.key]++
		} else {
			main[c.key]++
		}
	}
	if len(main) > 0 {
		return speakerMajority(main)
	}
	return speakerMajority(bg)
}

// speakerMajority:票数最多的那个;票数相同取字典序小的,结果不随 map 的遍历顺序变。
func speakerMajority(votes map[string]int) string {
	best, bn := "", 0
	for k, n := range votes {
		if n > bn || (n == bn && k < best) {
			best, bn = k, n
		}
	}
	return best
}

// speakerTransfer:把 Musixmatch 那份正文的演唱者(每行的归属 mxKeys、每个字的归属 owners)搬到 target 的每一行上
// (target 由 speakerLineTexts 给出,空串的行不参与)。先按 speakerAlignKey 整行相同对齐(LCS),对上的行照抄那一行的
// 归属;没对上的行在前后两个已对上的行之间逐字对齐(speakerFillGap)。返回每行的归属,标不上的为空。
func speakerTransfer(mxLines []string, owners [][]speakerChar, mxKeys []string, target []string) []string {
	mxAlign := make([]string, len(mxLines))
	for j, ln := range mxLines {
		mxAlign[j] = speakerAlignKey(ln)
	}
	tAlign := make([]string, len(target))
	for i, t := range target {
		if t != "" {
			tAlign[i] = speakerAlignKey(t)
		}
	}
	al := speakerLCS(tAlign, mxAlign)
	out := make([]string, len(target))
	for i, j := range al {
		if j >= 0 {
			out[i] = mxKeys[j]
		}
	}
	prevT, prevM := -1, -1
	for i := 0; i <= len(al); i++ {
		if i < len(al) && al[i] < 0 {
			continue
		}
		curM := len(mxLines)
		if i < len(al) {
			curM = al[i]
		}
		if i-prevT > 1 {
			speakerFillGap(out, target, prevT, i, owners, prevM, curM)
		}
		prevT, prevM = i, curM
	}
	return out
}

// speakerFillGap:target 的 (t0, t1) 这几行没有整行对上,跟 Musixmatch 的 (m0, m1) 那几行逐字对齐(LCS),把对上的字的
// 归属搬过来。一行里对上、且有归属的字至少占这一行的 lyricSpeakersMinLineMatch,才按多数认(括号外的字优先,同
// speakerLineKey)。
func speakerFillGap(out, target []string, t0, t1 int, owners [][]speakerChar, m0, m1 int) {
	var tr []rune
	var tLine []int
	var tParen []bool
	for i := t0 + 1; i < t1; i++ {
		if target[i] == "" {
			continue
		}
		rs, inParen := speakerRunes(target[i])
		for k := range rs {
			tr = append(tr, rs[k])
			tLine = append(tLine, i)
			tParen = append(tParen, inParen[k])
		}
	}
	var mc []speakerChar
	for j := m0 + 1; j < m1; j++ {
		mc = append(mc, owners[j]...)
	}
	if len(tr) == 0 || len(mc) == 0 || len(tr)*len(mc) > lyricSpeakersMaxAlignCells {
		return
	}
	mr := make([]rune, len(mc))
	for k, c := range mc {
		mr[k] = c.r
	}
	match := speakerRuneLCS(tr, mr)
	mainV, bgV := map[int]map[string]int{}, map[int]map[string]int{}
	lineLen := map[int]int{}
	for k, mi := range match {
		i := tLine[k]
		lineLen[i]++
		if mi < 0 || mc[mi].key == "" {
			continue
		}
		v := mainV
		if tParen[k] || mc[mi].bg {
			v = bgV
		}
		if v[i] == nil {
			v[i] = map[string]int{}
		}
		v[i][mc[mi].key]++
	}
	for i, n := range lineLen {
		pick := mainV[i]
		if len(pick) == 0 {
			pick = bgV[i]
		}
		tot := 0
		for _, c := range pick {
			tot += c
		}
		if best := speakerMajority(pick); best != "" && float64(tot) >= lyricSpeakersMinLineMatch*float64(n) {
			out[i] = best
		}
	}
}

// speakerLabels:把每行的归属换成 App 认的标记 —— 单人按在这份正文里首次出现的顺序编号 v1、v2…,两人以上记「合」。
// 标上的正文行不到 lyricSpeakersMinCoverage,或者单人少于两位时返回 nil。
func speakerLabels(keys, target []string) []string {
	content, labeled := 0, 0
	order := map[string]int{}
	out := make([]string, len(keys))
	for i, k := range keys {
		if target[i] == "" {
			continue
		}
		content++
		if k == "" {
			continue
		}
		labeled++
		if strings.Contains(k, "+") {
			out[i] = lyricSpeakersGroupLabel
			continue
		}
		n, ok := order[k]
		if !ok {
			n = len(order) + 1
			order[k] = n
		}
		out[i] = fmt.Sprintf("v%d", n)
	}
	if len(order) < 2 || float64(labeled) < lyricSpeakersMinCoverage*float64(content) {
		return nil
	}
	return out
}

// speakerLCS:a 的每一项对到 b 的下标(最长公共子序列),没对上为 -1。空串不参与。
func speakerLCS(a, b []string) []int {
	n, m := len(a), len(b)
	dp := make([]int32, (n+1)*(m+1))
	at := func(i, j int) int32 { return dp[i*(m+1)+j] }
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			v := max(at(i+1, j), at(i, j+1))
			if a[i] != "" && a[i] == b[j] {
				v = max(v, at(i+1, j+1)+1)
			}
			dp[i*(m+1)+j] = v
		}
	}
	out := make([]int, n)
	for i := range out {
		out[i] = -1
	}
	for i, j := 0, 0; i < n && j < m; {
		switch {
		case a[i] != "" && a[i] == b[j] && at(i, j) == at(i+1, j+1)+1:
			out[i] = j
			i++
			j++
		case at(i+1, j) >= at(i, j+1):
			i++
		default:
			j++
		}
	}
	return out
}

// speakerRuneLCS:同 speakerLCS,按字。
func speakerRuneLCS(a, b []rune) []int {
	n, m := len(a), len(b)
	dp := make([]int32, (n+1)*(m+1))
	at := func(i, j int) int32 { return dp[i*(m+1)+j] }
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			v := max(at(i+1, j), at(i, j+1))
			if a[i] == b[j] {
				v = max(v, at(i+1, j+1)+1)
			}
			dp[i*(m+1)+j] = v
		}
	}
	out := make([]int, n)
	for i := range out {
		out[i] = -1
	}
	for i, j := 0, 0; i < n && j < m; {
		switch {
		case a[i] == b[j] && at(i, j) == at(i+1, j+1)+1:
			out[i] = j
			i++
			j++
		case at(i+1, j) >= at(i, j+1):
			i++
		default:
			j++
		}
	}
	return out
}
