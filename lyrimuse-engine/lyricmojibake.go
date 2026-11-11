package main

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// 歌词源自己存坏了的正文(scoreTermGarbledText)。判据与全库实测见 09 章决策 368。
//
// 两种样子:
//   - UTF-8 字节被当成 Windows-1252 解了一遍(`youâ€™re`、`manhÃ£`)。字节都还在的,repairLyricMojibake 原样还原;
//   - 字节已经丢了的:替换字符 U+FFFD(`pr�ent`)、还原不了的残段(`tÃo`、`Â¨C`)。只能换别家的,
//     由 applyGarbledTextPenalty 扣分。

// cp1252HighBytes:Windows-1252 里 0x80–0x9F 这一段的字符 → 原字节。0xA0–0xFF 跟 Latin-1 同码,不用查表;
// 没定义的 0x81 / 0x8D / 0x8F / 0x90 / 0x9D 多被解成同值的 C1 控制符,也按同值认。
var cp1252HighBytes = map[rune]byte{
	'€': 0x80, '‚': 0x82, 'ƒ': 0x83, '„': 0x84, '…': 0x85, '†': 0x86, '‡': 0x87, 'ˆ': 0x88,
	'‰': 0x89, 'Š': 0x8A, '‹': 0x8B, 'Œ': 0x8C, 'Ž': 0x8E, '‘': 0x91, '’': 0x92, '“': 0x93,
	'”': 0x94, '•': 0x95, '–': 0x96, '—': 0x97, '˜': 0x98, '™': 0x99, 'š': 0x9A, '›': 0x9B,
	'œ': 0x9C, 'ž': 0x9E, 'Ÿ': 0x9F,
}

// mojibakeContinuationByte:r 按 Windows-1252 编回去是不是一个 UTF-8 后续字节(0x80–0xBF)。
func mojibakeContinuationByte(r rune) (byte, bool) {
	if r >= 0x80 && r <= 0xBF {
		return byte(r), true
	}
	b, ok := cp1252HighBytes[r]
	return b, ok
}

// mojibakeRepairable:还原出来的字符只认带重音的拉丁字母和歌词里常见的标点。别放宽:`Â¨C`(GBK 套 Latin-1 的双层
// 乱码)按字节还原是 `¨C`,不比原来好;带重音的大写字母后面紧跟 `»` `…` 这类正常写法,按字节拼出来是别的文字,也靠这里挡。
func mojibakeRepairable(r rune) bool {
	switch {
	case r >= 0xC0 && r <= 0x17F && r != '×' && r != '÷':
		return true
	case r >= 0x2010 && r <= 0x2027, r == '€', r == '™':
		return true
	}
	return strings.ContainsRune("¡¿«»°·´©®", r)
}

// repairLyricMojibake 把「一个 UTF-8 首字节 + 恰好够数的后续字节」被当成 Windows-1252 解出来的片段还原成原字符,
// 其余原样。没有 0xC2 以上字符的文本直接返回。
func repairLyricMojibake(s string) string {
	if !strings.ContainsFunc(s, func(r rune) bool { return r >= 0xC2 && r <= 0xF4 }) {
		return s
	}
	rs := []rune(s)
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		need := 0
		switch {
		case r >= 0xC2 && r <= 0xDF:
			need = 1
		case r >= 0xE0 && r <= 0xEF:
			need = 2
		case r >= 0xF0 && r <= 0xF4:
			need = 3
		}
		if need > 0 && i+need < len(rs) {
			raw := []byte{byte(r)}
			for _, c := range rs[i+1 : i+1+need] {
				cb, ok := mojibakeContinuationByte(c)
				if !ok {
					break
				}
				raw = append(raw, cb)
			}
			if len(raw) == need+1 {
				if u, size := utf8.DecodeRune(raw); u != utf8.RuneError && size == len(raw) && mojibakeRepairable(u) {
					b.WriteRune(u)
					i += need
					continue
				}
			}
		}
		b.WriteRune(r)
	}
	return b.String()
}

// lyricTextGarbled:一段歌词文本里有没有还原不了的乱码。只认正常歌词里不会出现的写法:替换字符、`Ã` / `Â` 后面跟着
// 0x80–0xBF 那段符号、`â€`、夹在两个小写字母中间的大写 `Ã`。`SÃO PAULO`、`Mötley Crüe`、`naïve` 都不算。
func lyricTextGarbled(s string) bool {
	if strings.ContainsRune(s, utf8.RuneError) {
		return true
	}
	if !strings.ContainsAny(s, "ÃÂâ") {
		return false
	}
	rs := []rune(s)
	for i, r := range rs {
		next := rune(0)
		if i+1 < len(rs) {
			next = rs[i+1]
		}
		switch r {
		case 'Ã', 'Â':
			if next >= 0x80 && next <= 0xBF {
				return true
			}
			if r == 'Ã' && i > 0 && unicode.IsLower(rs[i-1]) && unicode.IsLower(next) {
				return true
			}
		case 'â':
			if next == '€' {
				return true
			}
		}
	}
	return false
}

// lyricBodyGarbled:LRC 的正文行(署名、声明行不算,口径同 timelineBodyText)里有没有乱码。
func lyricBodyGarbled(lrc string) bool {
	if lrc == "" {
		return false
	}
	speakers := lyricSpeakerLabels(lrc)
	for _, line := range strings.Split(lrc, "\n") {
		if !lrcTimestampRe.MatchString(line) {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if lyricTextGarbled(timelineBodyText(text, speakers)) {
			return true
		}
	}
	return false
}

// garbledTextPenalty:正文有乱码的候选扣多少。跟另外几项批级扣分同量级,够把冠军让给分数差一大截的干净候选。
const garbledTextPenalty = 600

// applyGarbledTextPenalty 给正文有乱码的候选扣 garbledTextPenalty 分,并记一条 scoreTermGarbledText。扣完之后的第一名
// 必须是正文干净的候选,否则整批不动:只有这一家有、或家家都坏的,宁可显示带乱码的也别没有歌词。
// 调用位置同 applyTimelineIntrusionPenalty(紧跟在它后面):两条流水线都要调,且在排序之前。
func applyGarbledTextPenalty(results []scoredLyricCandidateResult) {
	penalized := map[int]bool{}
	for i, r := range results {
		if r.Score >= 0 && lyricBodyGarbled(r.Lyrics) {
			penalized[i] = true
		}
	}
	if len(penalized) == 0 {
		return
	}
	scores := make([]int, len(results))
	for i, r := range results {
		scores[i] = r.Score
		if penalized[i] {
			scores[i] = max(r.Score-garbledTextPenalty, 1) // 跟 scoreLyricCandidateDetailed 末尾同一条夹底纪律
		}
	}
	top := -1
	for i := range results {
		if results[i].Score >= 0 && (top == -1 || scores[i] > scores[top]) {
			top = i
		}
	}
	if top == -1 || penalized[top] {
		return
	}
	for i := range penalized {
		results[i].Score = scores[i]
		results[i].ScoreTerms = append(results[i].ScoreTerms, scoreTerm{Kind: scoreTermGarbledText, Points: -garbledTextPenalty})
	}
}
