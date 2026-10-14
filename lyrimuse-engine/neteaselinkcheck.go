package main

import (
	"log"
	"strings"
	"unicode"
)

// 网易云单曲链接按网易云登记的歌名、别名、时长重核(03 章决策 45)。本地歌名是罗马字、拼音、英文名时网易云按它搜不到,
// 只凭时长挑的话,同一位歌手时长相近的另一首、或者同一首的另一个版本会被当成这一首;链接配错了,同一次匹配给的封面也跟着错。
// 判错的清掉链接,记下那个 id(enrichEntry.NeteaseRejected),外围补全、去重合并再遇到它时链接、封面都不收;封面也来自网易云、
// 又不能当本地这张专辑的封面的,封面一族一起清,判错过的条目每一轮再核一次留下的网易云封面。网易云名字补扫
// (songentityneteasenames.go)每一轮之后跑一遍,只用补扫存下的登记信息,不另外联网。

// neteaseLinkOwner:同一个网易云歌曲 id 挂着的另一条写法。
type neteaseLinkOwner struct {
	key, title string
	isrcs      []string
}

// neteaseLinkCompat:比歌名之前把康熙部首、兼容表意文字换成标准字,全角 ASCII 换成半角。
func neteaseLinkCompat(s string) string { return songWidthFold(normalizeHanCompat(s)) }

// neteaseLinkTitlesMatch:两个歌名按写法族折过之后相同,或者一个包含另一个。
func neteaseLinkTitlesMatch(a, b string) bool {
	fa, fb := songFamilyTitle(neteaseLinkCompat(a)), songFamilyTitle(neteaseLinkCompat(b))
	return fa != "" && fb != "" && (fa == fb || strings.Contains(fa, fb) || strings.Contains(fb, fa))
}

// neteaseLinkScript:能不能逐词比要看两边是不是同一种文字。不含汉字、假名、谚文的是 latin;含汉字、不带假名谚文的是 han;
// 带假名或谚文的是 other,不逐词比:日文同一首有汉字写法和假名写法,逐字比会把它们判成两首。
func neteaseLinkScript(s string) string {
	han := false
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r), unicode.Is(unicode.Hangul, r):
			return "other"
		case unicode.Is(unicode.Han, r):
			han = true
		}
	}
	if han {
		return "han"
	}
	return "latin"
}

// neteaseLinkWords:逐词比用的词。拉丁文字按词(两个字符以上),汉字一个字一个词。
func neteaseLinkWords(s string) map[string]bool {
	out := map[string]bool{}
	for _, w := range strings.FieldsFunc(strings.ToLower(toSimplified(neteaseLinkCompat(s))), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		latin := true
		for _, r := range w {
			if unicode.Is(unicode.Han, r) {
				out[string(r)] = true
				latin = false
			}
		}
		if lw := normLoose(w); latin && len([]rune(lw)) >= 2 {
			out[lw] = true
		}
	}
	return out
}

// isrcSetsOverlap:两组 ISRC 有没有一个相同。
func isrcSetsOverlap(a, b []string) bool {
	for _, x := range a {
		cx := normalizeISRC(x)
		if cx == "" {
			continue
		}
		for _, y := range b {
			if normalizeISRC(y) == cx {
				return true
			}
		}
	}
	return false
}

// neteaseLinkMismatch:网易云链接是不是配错了,配错时给原因(写日志),判不出或没配错给空串。title / album / durationSecs / isrcs
// 是这一条的;names 是这条录音别的已知名字(Apple 各区的);rec 是链接那个 id 在网易云的登记信息;owners 是同一个 id 挂着的
// 别的写法。按顺序:
//  1. 时长超出 isrcDurationFits 的容差,版本词也对不上(Live、伴奏、DJ 版……):配成了另一个版本。排在比歌名之前:
//     歌名按包含算对得上,「偷笑」对「偷笑 (Live)」也算。两个歌名折过之后一字不差的不算(版本词不带括号时认不出来)。
//  2. 歌名或别的名字跟登记名、别名对得上:没配错。
//  3. 同一个 id 挂着的另一条写法歌名对得上登记名、跟这一条对不上,两边都有 ISRC 而且没有一个相同:那条才是这个 id 的录音。
//  4. 这一条和登记名都是拉丁文字、或都是纯汉字,却跟登记名、别名一个词(字)都不相同:配成了另一首。能不能逐词比只看
//     登记名(别名里常有英文译名,拿它判会把罗马字歌名判成另一首),相同的词把别名的也算上。
//  5. 歌名是一字一词的拼音,读音跟纯汉字的登记名明摆着对不上(pinyinTitleContradicts):配成了另一首。
//
// 两边文字不同、又没有上面这些证据的不动(英文名、罗马字对原文名):多半是同一首的译名。
func neteaseLinkMismatch(title, album string, durationSecs float64, isrcs, names []string, rec neteaseCatalogName,
	owners []neteaseLinkOwner) string {
	if rec.Name == "" {
		return ""
	}
	registered := append([]string{rec.Name}, rec.Aliases...)
	local := append([]string{title}, names...)
	matchesRegistered := func(s string) bool {
		for _, r := range registered {
			if neteaseLinkTitlesMatch(s, r) {
				return true
			}
		}
		return false
	}
	if durationSecs > 0 && rec.DurationSecs > 0 && !isrcDurationFits(durationSecs, rec.DurationSecs) &&
		normLoose(neteaseLinkCompat(title)) != normLoose(neteaseLinkCompat(rec.Name)) && versionTagsMismatch(title, album, rec.Name, "") {
		return "another version"
	}
	for _, l := range local {
		if matchesRegistered(l) {
			return ""
		}
	}
	if len(isrcs) > 0 {
		for _, o := range owners {
			if len(o.isrcs) > 0 && matchesRegistered(o.title) && !neteaseLinkTitlesMatch(o.title, title) &&
				!isrcSetsOverlap(isrcs, o.isrcs) {
				return "the recording of " + o.key
			}
		}
	}
	recScript := neteaseLinkScript(neteaseLinkCompat(rec.Name))
	comparable := false
	if recScript != "other" {
		recWords := neteaseLinkWords(strings.Join(registered, " "))
		for _, l := range local {
			if neteaseLinkScript(neteaseLinkCompat(l)) != recScript {
				continue
			}
			comparable = true
			for w := range neteaseLinkWords(l) {
				if recWords[w] {
					return ""
				}
			}
		}
	}
	if comparable {
		return "unrelated title"
	}
	// 这里没有「是中文歌」的线索,只判一字一词的拼音(pinyinTitleContradicts)。
	if pinyinTitleContradicts(title, album, rec.Name, false) {
		return "pinyin reads differently"
	}
	return ""
}

// clearWrongNeteaseLink 清掉配错的网易云链接、记下那个 id。封面也来自网易云的是同一次匹配给的:本地没报专辑、或者封面专辑
// 不能当本地这张(candidateCoverAlbumFits)时一起清。外围补全计数归零:下次播到时空链接算缺,按现在的规则重新匹配。
func clearWrongNeteaseLink(e enrichEntry, album string) enrichEntry {
	e.NeteaseRejected = neteaseSongIDFromURL(e.NeteaseURL)
	e.NeteaseURL = ""
	e.PeripheralRetryCount = 0
	if e.CoverSource == "netease" && (strings.TrimSpace(album) == "" || !candidateCoverAlbumFits(e.CoverAlbum, album)) {
		e = withoutCover(e)
	}
	return e
}

// staleRejectedNeteaseCover:判错过、现在没有网易云链接的条目还留着一张网易云封面,封面专辑又不能当本地这张。本地没报专辑时
// candidateCoverAlbumFits 什么专辑都算对得上,这里也就不清:外围补全拿歌词判决里的候选封面兜底用的是同一个判据
// (winnerCandidateCover),判据不一样就会清了又补。
func staleRejectedNeteaseCover(e enrichEntry, album string) bool {
	return e.NeteaseURL == "" && e.NeteaseRejected != "" && e.CoverSource == "netease" && !candidateCoverAlbumFits(e.CoverAlbum, album)
}

// withoutCover:封面、主色、动态封面一起清。
func withoutCover(e enrichEntry) enrichEntry {
	e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = "", "", "", ""
	e.MotionCoverURL, e.MotionPreviewURL = "", ""
	e.MotionCoverChecked, e.MotionCoverIdentityVerified = false, false
	return e
}

// neteaseResultRejected:这一轮网易云给的结果是不是这一条判错过的那首(链接、封面都不收)。
func neteaseResultRejected(e, fresh enrichEntry) bool {
	return e.NeteaseRejected != "" && neteaseSongIDFromURL(fresh.NeteaseURL) == e.NeteaseRejected
}

// recheckNeteaseLinks 拿补扫存下的网易云登记信息重核全部网易云链接,返回清掉了几条链接。判定在锁外;写回时链接还是当初核的
// 那一个才改。判错过的条目留下的网易云封面(staleRejectedNeteaseCover)在取快照时顺手清掉,外围补全计数不动。
func recheckNeteaseLinks(registry map[string]neteaseCatalogName, apple map[string]appleCatalogNames) int {
	enrichMu.Lock()
	linked := map[string]enrichEntry{}
	var staleCovers []string
	for k, e := range enrichCache {
		if e.NeteaseURL != "" {
			linked[k] = e
			continue
		}
		if _, _, album := splitEnrichKey(k); staleRejectedNeteaseCover(e, album) {
			enrichCache[k] = withoutCover(e)
			noteEnrichPendingLocked(k)
			staleCovers = append(staleCovers, k)
		}
	}
	if len(staleCovers) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	for _, k := range staleCovers {
		log.Printf("netease link recheck: %q still had the cover from its rejected link, cleared it", k)
	}
	owners := map[string][]neteaseLinkOwner{}
	for k, e := range linked {
		_, title, _ := splitEnrichKey(k)
		id := neteaseSongIDFromURL(e.NeteaseURL)
		owners[id] = append(owners[id], neteaseLinkOwner{key: k, title: enrichKeyDurationVariantRe.ReplaceAllString(title, ""), isrcs: e.ISRCs})
	}
	type wrongLink struct{ key, url, album string }
	var wrong []wrongLink
	checked := 0
	for k, e := range linked {
		id := neteaseSongIDFromURL(e.NeteaseURL)
		rec, ok := registry[id]
		if id == "" || !ok || rec.Name == "" {
			continue
		}
		checked++
		_, title, album := splitEnrichKey(k)
		title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
		secs := e.DurationSecs
		if secs <= 0 {
			secs = e.ResolvedDurationSecs
		}
		var names []string
		if aid := appleCatalogIDFromURL(e.AppleURL); aid != "" {
			for _, n := range apple[aid].Names {
				names = append(names, n.Name)
			}
		}
		var others []neteaseLinkOwner
		for _, o := range owners[id] {
			if o.key != k {
				others = append(others, o)
			}
		}
		if why := neteaseLinkMismatch(title, album, secs, e.ISRCs, names, rec, others); why != "" {
			log.Printf("netease link recheck: %q links to %q by %s (%s), clearing it", k, rec.Name, strings.Join(rec.Artists, " / "), why)
			wrong = append(wrong, wrongLink{k, e.NeteaseURL, album})
		}
	}
	var changed []string
	enrichMu.Lock()
	for _, w := range wrong {
		e, ok := enrichCache[w.key]
		if !ok || e.NeteaseURL != w.url {
			continue
		}
		enrichCache[w.key] = clearWrongNeteaseLink(e, w.album)
		noteEnrichPendingLocked(w.key)
		changed = append(changed, w.key)
	}
	if len(changed) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if saved := append(staleCovers, changed...); len(saved) > 0 {
		saveEnrichPendingBatch(saved)
	}
	log.Printf("netease link recheck: %d entries checked, %d links cleared, %d leftover covers cleared", checked, len(changed), len(staleCovers))
	return len(changed)
}
