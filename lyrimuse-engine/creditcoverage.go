package main

import (
	"regexp"
	"strings"
)

// 合作署名的覆盖:本地署名(歌手栏 + 歌名)点了名的合作者,目录里那一轨的署名是不是都写到了。同一张专辑的同一个版次里
// 常同时收着独唱版和请人合唱重新录的那一版,歌名、专辑名都一样,只有署名分得开。只拿它在同一批检索结果里挑哪一轨,
// 不拿它单独否掉一轨:各家对合作者的写法差得多(王力宏 / Leehom Wang、只署主歌手),写法对不上的绝大多数是同一份录音
// (见 03 章决策 43)。

// creditTitleWithRe:歌名里「(with X)」「[with X]」这一种合作署名。
var creditTitleWithRe = regexp.MustCompile(`(?i)[(\[（【]\s*with\s+([^)\]）】]+)`)

// creditTailNames:feat. / with 后面那一截里的人名,到第一个右括号为止;「A and B」按「A & B」拆。
func creditTailNames(s string) []string {
	if j := strings.IndexAny(s, ")]）】"); j >= 0 {
		s = s[:j]
	}
	return artistCreditParts(strings.NewReplacer(" and ", " & ", " And ", " & ").Replace(s))
}

// creditNames:一份署名里点到的人。歌手栏 feat. 之前按 artistCreditParts 拆出的第一位是 primary;其余几位、歌手栏
// feat. 之后的、歌名里 feat. / with 后面的进 others。名字是 artistCreditParts 的形态(小写、繁简折过)。
func creditNames(artist, title string) (primary string, others []string) {
	a := strings.TrimSpace(artist)
	if loc := featCreditSepRe.FindStringIndex(a); loc != nil && loc[0] > 0 {
		others = append(others, creditTailNames(a[loc[1]:])...)
		a = strings.TrimRight(a[:loc[0]], " ([（【")
	}
	if parts := artistCreditParts(a); len(parts) > 0 {
		primary, others = parts[0], append(others, parts[1:]...)
	}
	if loc := titleFeatCreditRe.FindStringIndex(title); loc != nil {
		rest := title[loc[0]:]
		if m := featCreditSepRe.FindStringIndex(rest); m != nil {
			rest = rest[m[1]:]
		}
		others = append(others, creditTailNames(rest)...)
	}
	for _, m := range creditTitleWithRe.FindAllStringSubmatch(title, -1) {
		others = append(others, creditTailNames(m[1])...)
	}
	return primary, others
}

// creditCoArtists:本地署名里主歌手之外点了名的合作者,按 normLoose 去重,跟主歌手同名的不算。没有返回 nil。
func creditCoArtists(artist, title string) []string {
	primary, others := creditNames(artist, title)
	seen := map[string]bool{normLoose(primary): true}
	var out []string
	for _, o := range others {
		k := normLoose(o)
		if k == "" || seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, o)
	}
	return out
}

// creditAllNames:本地署名点了名的每一个人:主歌手在前(歌手栏为空时没有),其后是 creditCoArtists。
func creditAllNames(artist, title string) []string {
	primary, _ := creditNames(artist, title)
	co := creditCoArtists(artist, title)
	if primary == "" {
		return co
	}
	return append([]string{primary}, co...)
}

// creditCovers:一轨的署名(歌手栏 artist + 歌名 title)写到了 co 里的每一位。co 为空时为 true。
func creditCovers(co []string, artist, title string) bool {
	if len(co) == 0 {
		return true
	}
	primary, others := creditNames(artist, title)
	names := append([]string{primary}, others...)
	hay := normLoose(artist + " " + title)
	for _, c := range co {
		if !creditNamed(c, names, hay) {
			return false
		}
	}
	return true
}

// creditNamed:c 是 names 里的某一位(同一个人按 songArtistMatch 认:双语写法、MusicBrainz 身份),或者折成 normLoose
// 后至少三个字、出现在整份署名 hay 里(团体名的拆法各家不同:「Earth, Wind & Fire」对「Earth, Wind and Fire」)。
func creditNamed(c string, names []string, hay string) bool {
	k := normLoose(c)
	for _, n := range names {
		if n != "" && (normLoose(n) == k || songArtistMatch(n, c)) {
			return true
		}
	}
	return len([]rune(k)) >= 3 && strings.Contains(hay, k)
}
