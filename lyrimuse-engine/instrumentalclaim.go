package main

import (
	"log"
	"regexp"
	"sync"
)

// 源匹配到的是伴奏版、在放的这首不是:那个源给的纯音乐信号说的是伴奏版,不算这首的。见 09 章决策 238。

// instrumentalAbbrevTag 认歌名括号里的伴奏缩写:QQ 常写的「(Inst.)」「(inst)」、日系的「(Off Vocal)」。
// 只用在纯音乐信号这一处,不进打分的版本词表(distinctRecordingVersionTags / versionTagAliases)。
var instrumentalAbbrevTag = regexp.MustCompile(`(?i)[(\[（【][^)\]）】]*\b(?:inst\b\.?|off[\s-]*vocal\b)[^)\]）】]*[)\]）】]`)

// titleClaimsInstrumentalVersion:歌名(或专辑)说明这是伴奏版。
func titleClaimsInstrumentalVersion(title, album string) bool {
	return localIsInstrumentalVersion(title, album) || instrumentalAbbrevTag.MatchString(title)
}

var instrumentalClaimLogged sync.Map

// dropOtherVersionInstrumentalClaims 清掉「匹配到伴奏版」的源结果里的纯音乐信号(instrumental / noVocals /
// 网易云 PureMusic、NoVocals / 占位歌词),其余字段不动。在放的这首本身是伴奏版时原样返回。
// raw 是 rankLyricSourceResults 自己复制出来的那份,可以就地改。
func dropOtherVersionInstrumentalClaims(title, album string, raw map[string]lyricSourceResult) map[string]lyricSourceResult {
	if titleClaimsInstrumentalVersion(title, album) {
		return raw
	}
	for k, r := range raw {
		matched := r.matchTitle
		if matched == "" {
			matched = r.ne.Title
		}
		if matched == "" || !titleClaimsInstrumentalVersion(matched, "") {
			continue
		}
		placeholder := isInstrumentalPlaceholderLyric(r.lyr)
		if !r.instrumental && !r.noVocals && !r.ne.PureMusic && !r.ne.NoVocals && !placeholder {
			continue
		}
		if _, seen := instrumentalClaimLogged.LoadOrStore(k+"|"+matched+"|"+title, true); !seen {
			log.Printf("lyrics: instrumental claim from another version dropped: source=%s matched=%q playing=%q", k, matched, title)
		}
		r.instrumental, r.noVocals, r.ne.PureMusic, r.ne.NoVocals = false, false, false, false
		if placeholder {
			r.lyr = ""
		}
		raw[k] = r
	}
	return raw
}
