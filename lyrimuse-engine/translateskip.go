package main

import (
	"regexp"
	"strings"
	"unicode"
)

// 翻译选行专用的跳过规则:只决定一行送不送去翻,不碰展示过滤(looksLikeLyricHeaderLine 镜像的那套)
// 和打分(isRelaxedCreditLine 还喂着曲长端点)。这里多跳一行的代价是少翻一句,所以比那两处都放得宽。
// 送出去的抬头 / 署名 / 拟声行没什么可翻,而中文歌里它们常常是仅有的"外文行":整首只剩它们时每次都翻
// 不出东西,白白用掉重试额度,MyMemory 还会把它当成中文翻中文报错。见 10 章决策 27。

// looksLikeTranslationHeaderLine:展示端那套抬头判据之外,第一条正文行切成两段后只要一段等于歌名就算,
// 不要求另一段含歌手名。歌手名换了语种或写法时(「Throw It Off - 方大同」配 Khalil Fong)展示端宁可不删,
// 翻译这边跳过它只少翻一行。歌名只比整串的几种写法(原样 / 去括号 / 去掉「 - 版本」尾巴),不比按字形
// 切出的段 —— 双语歌名的半段太短,单凭它认会把真歌词当抬头。
// tagTitle / tagArtist 是歌词自己的 [ti:] / [ar:](lyricHeaderTags),展示端那套判据按播放器的和标签的两两搭配判。
func looksLikeTranslationHeaderLine(text, title, artist, tagTitle, tagArtist string) bool {
	if looksLikeLyricHeaderLineTagged(text, title, artist, tagTitle, tagArtist) {
		return true
	}
	if title == "" {
		return false
	}
	stripped := stripHeaderBrackets(title)
	forms := []string{title, stripped}
	if parts := strings.Split(stripped, " - "); len(parts) == 2 {
		forms = append(forms, parts[0])
	}
	titles := headerKeySet(forms)
	// 只认切法唯一的行:「我 - 你 - 他都在等」这种多处分隔每处都切的话,总有一段碰巧等于短歌名。
	splits := headerSplitCandidates(text)
	if len(splits) != 1 {
		return false
	}
	for _, sp := range splits {
		if headerKey(sp[0]) == "" || headerKey(sp[1]) == "" {
			continue
		}
		for _, side := range sp {
			if titles[headerKey(side)] || titles[headerKey(stripHeaderBrackets(side))] {
				return true
			}
		}
	}
	return false
}

// translationHanCreditRe:「角色 : 姓名」里角色是汉字、可以用 / 、 & 串几个角色、最长 16 个字
// (「鼓共同监制/录音师：」「母带后期处理工程师：」)。genericHanCreditLineRe 只认 1~8 个汉字、中间不带分隔。
var translationHanCreditRe = regexp.MustCompile(`^[\p{Han}/、&＆]{1,16}[\s\x{3000}]*[:：]`)

// translationLatinCreditRe:英文职员表(「Mastering Engineer: Dale Becker，」「Vocal Producer:」)。
// 角色词枚举,不放开成"任意拉丁词 + 冒号":`Oh :` `Baby:` 这种形状在真歌词里出得来。
var translationLatinCreditRe = regexp.MustCompile(`(?i)^(?:[a-z&.]+\s+){0,3}(?:engineers?|producers?|mastering|mastered|mixing|mixed|mix|recording|recorded|arrangers?|arrangement|composers?|lyricists?|programming|programmed|vocals?|guitars?|bass|drums|keyboards?|piano|strings|a&r|publishers?)(?:\s+by)?\s*[:：]`)

// translationVocableRe 一个拟声词(Oh / Ooh / Woo / Wu / Yeah / La / Na / Doo / Hey / Whoa / Mm ……)。
var translationVocableRe = regexp.MustCompile(`^(?:o+h*|w+o+h*|w+u+|w+h+o+a+h*|y+e+a*h*|y+a+y*|l+a+|n+a+|d+a+|d+o{2,}|h+e+y+|h+a+|a+h+|u+h+|m{2,}|h+m+|w+o+w+|h+o+|e+h+)$`)

// lowerLetterWords 按非字母切词、转小写。
func lowerLetterWords(text string) []string {
	return strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) })
}

// isVocableLine:整行只有拟声词(「Woo woo」「Oh-oh-oh-oh」「Wu ～」),没有可翻的内容。
func isVocableLine(text string) bool {
	words := lowerLetterWords(text)
	if len(words) == 0 {
		return false
	}
	for _, w := range words {
		if !translationVocableRe.MatchString(w) {
			return false
		}
	}
	return true
}

// translationSolfege 唱名。
var translationSolfege = map[string]bool{"do": true, "re": true, "mi": true, "fa": true, "so": true, "sol": true, "la": true, "si": true, "ti": true}

// isSolfegeLine:整行是唱名(「Re So So Si Do Si La」),或者只有 do / doo 而且不止一个(「Do-do-do-do」)。唱名要三种以上:
// 一两种的是真歌词(「So」「Si, si」);「Do ya, do ya?」里有别的词,不算。见 10 章决策 39。
func isSolfegeLine(text string) bool {
	words := lowerLetterWords(text)
	if len(words) < 2 {
		return false
	}
	kinds := map[string]bool{}
	solfege, scat := true, true
	for _, w := range words {
		solfege = solfege && translationSolfege[w]
		scat = scat && strings.TrimRight(w, "o") == "d"
		kinds[w] = true
	}
	return scat || solfege && len(kinds) >= 3
}

// isTranslationSkipLine:这一行不送去翻。演唱者标签(男：/女：)开头的是真歌词,两条署名规则都不拿它当署名。
func isTranslationSkipLine(text string, speakers map[string]bool) bool {
	if isRelaxedCreditLine(text, speakers) || isVocableLine(text) || isSolfegeLine(text) {
		return true
	}
	if len(speakers) > 0 {
		if label, _, ok := lyricSplitLabel(text); ok && speakers[label] {
			return false
		}
	}
	return translationHanCreditRe.MatchString(text) || translationLatinCreditRe.MatchString(text)
}
