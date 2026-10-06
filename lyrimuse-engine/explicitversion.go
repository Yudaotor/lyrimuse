package main

import (
	"regexp"
	"strings"
	"unicode"
)

var versionLabelSepRe = regexp.MustCompile(`[|;/,()\[\]（）【】]`)

// explicitLabelWords / cleanLabelWords:标明不删减版 / 删减版的词。
var (
	explicitLabelWords = map[string]bool{"explicit": true, "dirty": true, "uncensored": true}
	cleanLabelWords    = map[string]bool{"clean": true, "edited": true, "censored": true}
)

// versionLabelFillers:跟上面的词写在同一个标签里、不改变意思的词(「Deluxe Explicit Version」「Clean Album Version」
// 「Explicit Edition」「iTunes Edited」),四位数的年份也算。cleanLabelFillers 只能跟删减版的词搭配(「Clean Radio Edit」
// 「Censored Radio Version」)。
var (
	versionLabelFillers = map[string]bool{
		"version": true, "ver": true, "edition": true, "album": true, "deluxe": true, "standard": true, "expanded": true,
		"limited": true, "super": true, "squeaky": true, "single": true, "lp": true, "main": true, "original": true,
		"the": true, "lyrics": true, "content": true, "itunes": true,
	}
	cleanLabelFillers = map[string]bool{"radio": true, "edit": true}
)

// explicitnessOf:歌名、专辑名的限定段(titleQualifierSegments)里标明的是不删减版(explicit)还是删减版(clean)。一段里
// 几个标签用「|」「;」「/」「,」或内层括号隔开时逐个看(versionLabelKind)。两样都标了、或都没标,返回空串。
func explicitnessOf(title, album string) string {
	found := ""
	for _, seg := range append(titleQualifierSegments(title), titleQualifierSegments(album)...) {
		for _, part := range versionLabelSepRe.Split(seg, -1) {
			kind := versionLabelKind(part)
			if kind == "" {
				continue
			}
			if found != "" && found != kind {
				return ""
			}
			found = kind
		}
	}
	return found
}

// versionLabelKind:一个标签说的是不是删减版 / 不删减版。切成词以后只能有一种标签词,其余全是 versionLabelFillers
// (删减版另外可以带 cleanLabelFillers);有一个别的词就不算 ——「Non Explicit」「No Explicit Content」说的正好相反,
// 「Censored Artwork Version」遮的是封面,「Explicit Dance Edition」是另一个混音,「feat. Ol' Dirty Bastard」是人名。
func versionLabelKind(part string) string {
	words := strings.FieldsFunc(strings.ToLower(foldDiacritics(narrowASCII(part))), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	kind, cleanOnly := "", false
	for _, w := range words {
		k := ""
		switch {
		case explicitLabelWords[w]:
			k = "explicit"
		case cleanLabelWords[w]:
			k = "clean"
		case versionLabelFillers[w] || isFourDigitYear(w):
			continue
		case cleanLabelFillers[w]:
			cleanOnly = true
			continue
		default:
			return ""
		}
		if kind != "" && kind != k {
			return ""
		}
		kind = k
	}
	if cleanOnly && kind != "clean" {
		return ""
	}
	return kind
}

func isFourDigitYear(w string) bool {
	if len(w) != 4 || !(strings.HasPrefix(w, "19") || strings.HasPrefix(w, "20")) {
		return false
	}
	for _, r := range w {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// explicitnessConflict:一边标明不删减版、另一边标明删减版。两版伴奏、时长一样,词不一样(删减版把词去掉或换掉),
// 是两个版本。只有一边标、两边都没标都不算:很多曲目只有一家写了「(Explicit)」,别家没写,那不是另一个版本。
// versionTagsMismatch 和同一次录音的豁免(sameRecordingDespiteVersionTagsIgnoringLanguage)都认它。
func explicitnessConflict(localTitle, localAlbum, candidateTitle, candidateAlbum string) bool {
	l := explicitnessOf(localTitle, localAlbum)
	c := explicitnessOf(candidateTitle, candidateAlbum)
	return l != "" && c != "" && l != c
}
