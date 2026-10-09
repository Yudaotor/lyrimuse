package main

import (
	"encoding/json"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
)

// 歌手榜归并的第四个信号(artistMergeGroups):同一个人在另一种文字里的名字。播放器把歌手名换成中文译名
// (「王子」之于 Prince)之后,Last.fm 上就记成两个歌手,MusicBrainz 别名和名字键都连不上。证据全部取自本机
// enrich 缓存,不联网,两条:
//
//  1. 双语写法:一边只有 CJK、一边只有拉丁字母的「A (B)」(「BTS (防弹少年团)」)是同一个人的两个名字,
//     见 bilingualNameHalves。播放器标签或采纳的歌词署名里,出现在 bilingualAliasMinSongs 首以上不同的歌上
//     才收;榜上那一行自己就是这种写法时直接拆成两半。
//  2. 歌词源的署名:一个歌手标签名下的歌,采纳的歌词候选在源那边一致署成另一种文字的同一个名字,
//     判据见 deriveArtistSourceAliases。
//
// 只加合并键,显示名的改动只有 artistNameIsTranslation 一处。只认跨文字的理由与门槛的出处见 12 章决策 24。

// artistSourceAliasTable 是推出来的别名表。
type artistSourceAliasTable struct {
	// aliases:artistMergeFold(写法) → 同一个人的其他写法(原样,去重后按字典序)。
	aliases map[string][]string
	// translated:判据 2 学到别名的那些标签(artistMergeFold)。
	translated map[string]bool
}

// sourceCreditSample 是 enrich 缓存里的一条:播放器标签的歌手、歌名,和采纳的歌词候选在源那边的署名
// (decisionWinnerArtist;没有采纳结果时为空)。
type sourceCreditSample struct {
	artist, title, credit string
}

const (
	// 判据 2:署成同一个名字的不同的歌至少这么多首,并且占这个标签有采纳结果的歌的一半以上、
	// 占署名不是它自己的歌的三分之二以上。
	sourceAliasMinSongs = 3
	// 判据 1:同一个双语写法至少出现在这么多首不同的歌上。
	bilingualAliasMinSongs = 2
	// 常驻进程里别名表的重算间隔,见 refreshArtistSourceAliases。
	artistSourceAliasMaxAge = time.Hour
)

var (
	artistSourceAliasMu sync.RWMutex
	artistSourceAliases artistSourceAliasTable
	artistSourceAliasAt time.Time // 上次换表的时刻;零值 = 还没有表
)

const (
	artistScriptOther = iota
	artistScriptCJK
	artistScriptLatin
)

// artistNameScript 判名字的文字:只有 CJK(汉字 / 假名 / 谚文)、只有拉丁字母,两样都有或都没有归 artistScriptOther。
func artistNameScript(s string) int {
	cjk, latin := false, false
	for _, r := range s {
		switch {
		case isCJKScriptRune(r):
			cjk = true
		case unicode.Is(unicode.Latin, r):
			latin = true
		}
	}
	switch {
	case cjk && !latin:
		return artistScriptCJK
	case latin && !cjk:
		return artistScriptLatin
	}
	return artistScriptOther
}

// crossScriptNames:一个只有 CJK、另一个只有拉丁字母。
func crossScriptNames(a, b string) bool {
	sa, sb := artistNameScript(a), artistNameScript(b)
	return sa != artistScriptOther && sb != artistScriptOther && sa != sb
}

// 结尾一对括号(半角或全角),括号里不再套括号。
var bilingualNameRe = regexp.MustCompile(`^(.+?)\s*[(（]\s*([^()（）]+?)\s*[)）]$`)

// bilingualNameHalves 认「A (B)」这种双语写法,返回两半:一半只有 CJK、另一半只有拉丁字母,两半都是单个歌手。
// 「Young K (DAY6)」(成员加团名,同一种文字)、「曾溢(小五)」、「Coldplay、BTS (防弹少年团)」、
// 「某某 (feat. X)」都不算。
func bilingualNameHalves(name string) (string, string, bool) {
	name = strings.TrimSpace(name)
	if isMultiArtistCredit(name) {
		return "", "", false
	}
	m := bilingualNameRe.FindStringSubmatch(name)
	if m == nil {
		return "", "", false
	}
	a, b := strings.TrimSpace(m[1]), strings.TrimSpace(m[2])
	if strings.ContainsAny(a, "()（）") || !crossScriptNames(a, b) || isMultiArtistCredit(a) || isMultiArtistCredit(b) {
		return "", "", false
	}
	return a, b, true
}

// artistNameForms:名字本身,是双语写法时再加上两半。
func artistNameForms(name string) []string {
	if a, b, ok := bilingualNameHalves(name); ok {
		return []string{name, a, b}
	}
	return []string{name}
}

// creditNamesArtist:署名里有没有一位就是 self(artistMergeFold 后相等;合唱串逐位比,双语写法两半都算)。
func creditNamesArtist(credit, self string) bool {
	names := append(artistCreditParts(credit), artistCreditPrimary(credit))
	for _, n := range names {
		for _, f := range artistNameForms(n) {
			if artistMergeFold(f) == self {
				return true
			}
		}
	}
	return false
}

// deriveArtistSourceAliases 从 enrich 样本推别名表,结果只取决于样本集合、与顺序无关。
//
// 判据 2 只看单个歌手、文字单一(artistNameScript 不是 Other)的标签;一首歌按 lastfmCatalogTitleKey 计一次,
// 同一首收在几张专辑里不重复算。候选名字 Y 必须是单个歌手、跟标签不同文字;署名里有标签自己的(合唱、双语写法)
// 算「署的是它自己」。同时满足 sourceAliasMinSongs 那三条的 Y 恰好一个才收。
func deriveArtistSourceAliases(samples []sourceCreditSample) artistSourceAliasTable {
	alias := map[string]map[string]bool{}
	add := func(fromFold, to string) {
		if fromFold == "" || artistMergeFold(to) == fromFold {
			return
		}
		if alias[fromFold] == nil {
			alias[fromFold] = map[string]bool{}
		}
		alias[fromFold][to] = true
	}

	type pair struct{ a, b string }
	pairSongs := map[pair]map[string]bool{} // 两半的 artistMergeFold → 出现过的歌
	pairSpelling := map[pair]pair{}         // 同上 → 字典序最小的原样两半
	noteBilingual := func(name, song string) {
		a, b, ok := bilingualNameHalves(name)
		if !ok {
			return
		}
		k := pair{artistMergeFold(a), artistMergeFold(b)}
		if pairSongs[k] == nil {
			pairSongs[k] = map[string]bool{}
		}
		pairSongs[k][song] = true
		if p, seen := pairSpelling[k]; !seen || a+"\x1f"+b < p.a+"\x1f"+p.b {
			pairSpelling[k] = pair{a, b}
		}
	}

	type labelStats struct {
		songs, others map[string]bool            // 有采纳结果的歌;其中署名不是它自己的
		cands         map[string]map[string]bool // 候选 Y 的 artistMergeFold → 署成 Y 的歌
		spelling      map[string]string          // 同上 → 字典序最小的原样写法
	}
	labels := map[string]*labelStats{}

	for _, s := range samples {
		artist, credit := strings.TrimSpace(s.artist), strings.TrimSpace(s.credit)
		titleKey := lastfmCatalogTitleKey(s.title)
		if artist == "" || titleKey == "" {
			continue
		}
		self := artistMergeFold(artist)
		song := self + "\x1f" + titleKey
		noteBilingual(artist, song)
		if credit == "" {
			continue
		}
		noteBilingual(credit, song)

		if !expectsCanonicalArtist(artist) || artistNameScript(artist) == artistScriptOther {
			continue
		}
		st := labels[self]
		if st == nil {
			st = &labelStats{songs: map[string]bool{}, others: map[string]bool{},
				cands: map[string]map[string]bool{}, spelling: map[string]string{}}
			labels[self] = st
		}
		st.songs[titleKey] = true
		if creditNamesArtist(credit, self) {
			continue
		}
		st.others[titleKey] = true
		if !expectsCanonicalArtist(credit) || !crossScriptNames(artist, credit) {
			continue
		}
		ck := artistMergeFold(credit)
		if st.cands[ck] == nil {
			st.cands[ck] = map[string]bool{}
		}
		st.cands[ck][titleKey] = true
		if sp, seen := st.spelling[ck]; !seen || credit < sp {
			st.spelling[ck] = credit
		}
	}

	for k, songs := range pairSongs {
		if len(songs) < bilingualAliasMinSongs {
			continue
		}
		p := pairSpelling[k]
		add(k.a, p.b)
		add(k.b, p.a)
	}
	translated := map[string]bool{}
	for self, st := range labels {
		winner, n := "", 0
		for ck, songs := range st.cands {
			c := len(songs)
			if c >= sourceAliasMinSongs && 2*c >= len(st.songs) && 3*c >= 2*len(st.others) {
				winner, n = ck, n+1
			}
		}
		if n != 1 {
			continue
		}
		add(self, st.spelling[winner])
		translated[self] = true
	}

	t := artistSourceAliasTable{aliases: make(map[string][]string, len(alias)), translated: translated}
	for k, set := range alias {
		list := make([]string, 0, len(set))
		for n := range set {
			list = append(list, n)
		}
		sort.Strings(list)
		t.aliases[k] = list
	}
	return t
}

func setArtistSourceAliases(t artistSourceAliasTable, at time.Time) {
	artistSourceAliasMu.Lock()
	artistSourceAliases, artistSourceAliasAt = t, at
	artistSourceAliasMu.Unlock()
}

// artistAlternateNames 给 artistMergeGroups 加合并键用:name 是双语写法时的两半,加上别名表里
// name 和这两半各自的其他写法。
func artistAlternateNames(name string) []string {
	forms := artistNameForms(strings.TrimSpace(name))
	out := append([]string(nil), forms[1:]...)
	artistSourceAliasMu.RLock()
	for _, f := range forms {
		out = append(out, artistSourceAliases.aliases[artistMergeFold(f)]...)
	}
	artistSourceAliasMu.RUnlock()
	return out
}

// artistNameIsTranslation:这个写法不参加显示名的「中文成员名」那条轨(mergeAliasedArtistBuckets)——
// 双语写法本身,或判据 2 认出的标签(歌词源一致署的是另一种文字的名字,这个中文写法是播放器给的译名)。
func artistNameIsTranslation(name string) bool {
	if _, _, ok := bilingualNameHalves(name); ok {
		return true
	}
	artistSourceAliasMu.RLock()
	defer artistSourceAliasMu.RUnlock()
	return artistSourceAliases.translated[artistMergeFold(name)]
}

// refreshArtistSourceAliases 用常驻进程内存里的 enrich 缓存重算别名表;上次换表不到 artistSourceAliasMaxAge
// 就跳过。自己取 enrichMu,必须在不持有该锁时调用。
func refreshArtistSourceAliases(now time.Time) {
	artistSourceAliasMu.RLock()
	at := artistSourceAliasAt
	artistSourceAliasMu.RUnlock()
	if age := now.Sub(at); !at.IsZero() && age >= 0 && age < artistSourceAliasMaxAge {
		return
	}
	enrichMu.Lock()
	samples := make([]sourceCreditSample, 0, len(enrichCache))
	for k, e := range enrichCache {
		artist, title, _ := splitEnrichKey(k)
		samples = append(samples, sourceCreditSample{artist: artist, title: title, credit: decisionWinnerArtist(e.LyricsDecisionApplied)})
	}
	enrichMu.Unlock()
	setArtistSourceAliases(deriveArtistSourceAliases(samples), now)
}

// loadArtistSourceAliases 给一次性子命令(top-artists / artist-tracks)用:只解 enrich 缓存里推别名要的几个字段,
// 读不出来就当没有。不碰 enrichCache / enrichPath,理由同 loadEnrichCacheReadOnly。
func loadArtistSourceAliases(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var m map[string]struct {
		Decision *struct {
			Winner       string `json:"winner"`
			WinnerArtist string `json:"winner_artist"`
			Candidates   []struct {
				Source string `json:"source"`
				Artist string `json:"artist"`
			} `json:"candidates"`
		} `json:"lyrics_decision_applied"`
	}
	if json.Unmarshal(data, &m) != nil {
		return
	}
	samples := make([]sourceCreditSample, 0, len(m))
	for k, e := range m {
		artist, title, _ := splitEnrichKey(k)
		s := sourceCreditSample{artist: artist, title: title}
		if d := e.Decision; d != nil {
			full := lyricsDecision{Winner: d.Winner, WinnerArtist: d.WinnerArtist}
			for _, c := range d.Candidates {
				full.Candidates = append(full.Candidates, lyricsDecisionCandidate{Source: c.Source, Artist: c.Artist})
			}
			s.credit = decisionWinnerArtist(&full)
		}
		samples = append(samples, s)
	}
	setArtistSourceAliases(deriveArtistSourceAliases(samples), time.Now())
}
