package main

import (
	"context"
	"log"
	"slices"
	"strings"
	"unicode"
)

// titleReverseLookup:标题反查轮的「查出更正后的曲名」这一步 —— 同专辑曲目表、歌手泛搜、Apple 原产地商店三路反查,
// 挑出更正后的曲名、来路(retryMethod,同时是查询原因)和用哪个署名去查。都没查到返回空。samples 是
// lyricSamplesForStorefront(results),原产地商店那一路拿它核对是不是同一首;isrc 是这条录音的 ISRC
// (trustedRecordingISRC),区服遍历给不出原产地曲名时拿它查。
//
// 曲名里自带正式写法的两种形状直接改写、不联网反查,也不再走后面三路:「歌手『歌名』」取引号里的歌名
// (quotedSongAfterArtist),「English Name 中文名」这种英文在前的双语曲名取中文那段(bilingualTitleHanPart)。
// 见 09 章决策 189。
func titleReverseLookup(ctx context.Context, artist, title, album string, durationSecs float64, samples []string, isrc string) (correctedTitle, retryMethod, titleArtist string) {
	if song := quotedSongAfterArtist(artist, title); song != "" {
		log.Printf("lyrics: title-reverse-lookup: quoted song %q in title %q -> corrected=%q", song, title, song)
		return song, lyricQueryReasonTitleSplit, artist
	}
	if part := bilingualTitleHanPart(artist, title); part != "" {
		log.Printf("lyrics: title-reverse-lookup: bilingual title %q -> corrected=%q", title, part)
		return part, lyricQueryReasonTitleBilingual, artist
	}
	titleArtists := titleReverseArtists(ctx, artist)
	// 两条反查都跑、比谁的时长误差更小 —— **不是**"哪个先成功就用哪个"。两条各自都有
	// 例子证明"我更准、对方错":
	//   ①「Love Love Love」= 方大同《爱爱爱》,本地专辑标"This Love"——retryTitleFromAlbum
	//     在这张(名字对得上、收的却不是目标录音的)专辑里找到《春风吹 (Live)》,时长凑巧
	//     也在容差内,却是完全不相干的另一首歌;retryTitleFromArtistSearch 反而在泛搜结果
	//     第一条就搜到真正对的《爱爱爱》,时长分毫不差(0.266s)。
	//   ②「Singer and Model」= 方大同《歌手与模特儿》——两个标题连一个字/一个音都不共享,
	//     retryTitleFromArtistSearch 的泛搜排名前 30 里压根摸不到它(NetEase 的相关性排序
	//     找不到任何文字关联),只有 retryTitleFromAlbum 直接浏览专辑全部曲目才找得到(时长
	//     误差仅 0.0005s);而泛搜矬出一个时长凑巧接近的《Sorry》(误差 0.946s,明显更松),
	//     字面上跟"Singer and Model"毫无关系。
	// 谁先跑、谁的结果就被无条件采纳,必然在另一个案例上出错——只能都跑一遍,拿误差更小
	// 的那个(diff 越小说明这次时长匹配的把握越大),两个都没找到才算这轮兜底失败。同一个
	// 原则再多套一层:每种反查各自也拿原串/别名都试一遍,不预先假定哪个是网易云认的写法。
	var albumTitle, searchTitle, albumWinArtist, searchWinArtist string
	var albumDiff, searchDiff float64
	var albumOK, albumTitleBacked, searchOK bool
	for _, ta := range titleArtists {
		// 近似标题命中(titleBacked)压过纯时长命中,同档再比 diff。
		if t, d, backed, ok := retryTitleFromAlbumDetailed(ctx, ta, album, title, durationSecs); ok &&
			(!albumOK || (backed && !albumTitleBacked) || (backed == albumTitleBacked && d < albumDiff)) {
			albumTitle, albumDiff, albumOK, albumTitleBacked, albumWinArtist = t, d, true, backed, ta
		}
		if t, d, ok := retryTitleFromArtistSearchDetailed(ctx, ta, title, durationSecs); ok && (!searchOK || d < searchDiff) {
			searchTitle, searchDiff, searchOK, searchWinArtist = t, d, true, ta
		}
	}
	// 第三条路:Apple 原产地商店的规范曲名。上面两条**都拿本地标题当输入**
	// (retryTitleFromAlbum 拿它核对时长、retryTitleFromArtistSearch 直接把它拼进搜索词),
	// 本地标题本身就是罗马字时它们结构上够不到 —— 死结的完整说明见
	// appleStorefrontCanonicalTitle 头注(Mrs. GREEN APPLE《クスシキ》那次)。
	// 区服遍历不额外打请求(别名轮那边 appleStorefrontArtistIdentities 本来就要遍历这些商店);它按专辑名定位,
	// 专辑名也是罗马字的单曲 / EP 常定位不到,这时按 ISRC 在原产地商店的 Apple Music 曲库里查(originTitleByISRC,
	// 多一次曲库请求)。只认去掉括号部分之后换了文字的(crossScriptBase)。
	storefrontTitle := titleReverseOriginTitle(ctx, artist, title, album, durationSecs, samples, isrc)
	storefrontOK := storefrontTitle != ""
	// 第四条路:按歌词搜(titlelyrics.go)。只在前三条都没查到时问,最多多两次网易云请求。
	var lyricTitle string
	var lyricDiff float64
	lyricOK := false

	switch {
	// 跨文字系统的改写(罗马字 KUSUSHIKI → 假名「クスシキ」、US 的「情勝策略」→ JP 的
	// 「ハッピーエンド」)排在最前:这正是另两条够不到的那个形状,而且它的证据是**专辑级**的
	// ——先按专辑名精确定位到 collectionId、再在那张专辑的曲目表里按时长 + 跨文字系统对上
	// 这一条录音(appleStorefrontTrackMatches)——或者是录音级的 ISRC,比网易云那两条模糊搜索出来的硬。
	case storefrontOK:
		correctedTitle, retryMethod, titleArtist = storefrontTitle, lyricQueryReasonTitleStorefront, artist
	// 专辑曲目表里有跟本地标题近似的那首:文字证据压过泛搜的纯时长命中,不比 diff。
	case albumOK && albumTitleBacked:
		correctedTitle, retryMethod, titleArtist = albumTitle, "title-from-album", albumWinArtist
	case albumOK && (!searchOK || albumDiff <= searchDiff):
		correctedTitle, retryMethod, titleArtist = albumTitle, "title-from-album", albumWinArtist
	case searchOK:
		correctedTitle, retryMethod, titleArtist = searchTitle, "title-from-artist-search", searchWinArtist
	default:
		var lyricArtist string
		if lyricTitle, lyricArtist, lyricDiff, lyricOK = retryTitleFromLyricSearchDetailed(ctx, titleArtists, samples, durationSecs); lyricOK {
			correctedTitle, retryMethod, titleArtist = lyricTitle, lyricQueryReasonTitleLyrics, lyricArtist
		}
	}
	log.Printf("lyrics: title-reverse-lookup: titleArtists=%v albumTitle=%q albumDiff=%v albumOK=%v albumTitleBacked=%v albumWinArtist=%q searchTitle=%q searchDiff=%v searchOK=%v searchWinArtist=%q storefrontTitle=%q storefrontOK=%v lyricTitle=%q lyricDiff=%v lyricOK=%v -> corrected=%q method=%q titleArtist=%q",
		titleArtists, albumTitle, albumDiff, albumOK, albumTitleBacked, albumWinArtist, searchTitle, searchDiff, searchOK, searchWinArtist, storefrontTitle, storefrontOK, lyricTitle, lyricDiff, lyricOK, correctedTitle, retryMethod, titleArtist)
	return correctedTitle, retryMethod, titleArtist
}

// titleReverseSpec:救急时提前跑的标题反查(反查 + 用更正后的曲名查一轮),跟救急别名轮同时进行。
// 首轮全空、别名也救不回来的歌,最后都要走到标题反查,原来它排在别名轮之后串行,查不到歌词的歌要多等这一整段。
//
// 走到标题反查那一步时,只有歌词样本(lyricSamplesForStorefront)跟提前跑时一模一样才采用它的结果 ——
// 反查的判断只吃曲名 / 专辑 / 时长 / 署名和这份样本,样本一样,提前跑与当场跑就是同一个结论;
// 别名轮救回了歌词、样本变了,就丢掉它当场重跑。提前跑的那一轮不推流式进度(同 rescuefanout.go 的理由)。
// 见 09 章决策 102 第七批。
type titleReverseSpec struct {
	samples []string
	done    chan struct{}
	cancel  context.CancelFunc

	corrected, method, artist string
	fetched                   bool
	ne                        neteaseInfo
	results                   []scoredLyricCandidateResult
}

// titleReverseAliases:取一个署名的别名(retryArtistIdentities)。单测换成假的。
var titleReverseAliases = retryArtistIdentities

// titleReverseArtists:标题反查拿哪几个署名去查 —— 原串和它的头一个别名;多人合唱、feat. 署名时再加首歌手和首歌手的头一个
// 别名(lyricPrimaryQueryArtist:「Khalil Fong feat. Hanggai」原串和它的别名都查不到,「Khalil Fong」的别名「方大同」才按时长
// 反查出《醉》)。按这个顺序去重。见 09 章决策 205。
func titleReverseArtists(ctx context.Context, artist string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(s string) {
		if k := normLoose(s); k != "" && !seen[k] {
			seen[k] = true
			out = append(out, s)
		}
	}
	addWithAlias := func(s string) {
		add(s)
		if aliases := titleReverseAliases(ctx, s); len(aliases) > 0 {
			add(aliases[0])
		}
	}
	addWithAlias(artist)
	if primary := lyricPrimaryQueryArtist(artist); primary != "" {
		addWithAlias(primary)
	}
	if len(out) == 0 {
		out = append(out, artist)
	}
	return out
}

// bilingualTitleHanPart:曲名是整齐的两段 —— 前一段拉丁字母、后一段汉字,空格隔开 —— 时返回汉字那段,否则返回空串。
// 拉丁段只有字母和词内标点、至少两个字母、不是版本词,最后一个词不是合作署名词(feat. / with / x …);
// 汉字段至少两个汉字、不是歌手名。带括号、引号、破折号、斜杠、数字的曲名一律不认。
// 中文在前的不认:那种形状里英文常是整句曲名的一部分。见 09 章决策 189。
func bilingualTitleHanPart(artist, title string) string {
	_, han := bilingualTitleParts(artist, title)
	return han
}

// bilingualTitleParts 同 bilingualTitleHanPart,另外返回拉丁字母那段;认不出时两段都是空串。
func bilingualTitleParts(artist, title string) (latinPart, hanPart string) {
	t := cleanMediaTag(title)
	if t == "" || strings.ContainsAny(t, bilingualTitleRejectRunes) {
		return "", ""
	}
	fields := strings.Fields(t)
	kinds := make([]bool, len(fields)) // true = 汉字段的词
	switches := 0
	for i, f := range fields {
		switch {
		case bilingualLatinWord(f):
		case bilingualHanWord(f):
			kinds[i] = true
		default:
			return "", ""
		}
		if i > 0 && kinds[i] != kinds[i-1] {
			switches++
		}
	}
	if switches != 1 || kinds[0] {
		return "", ""
	}
	var latin, han []string
	for i, f := range fields {
		if kinds[i] {
			han = append(han, f)
		} else {
			latin = append(latin, f)
		}
	}
	if bilingualCreditWords[strings.ToLower(strings.Trim(latin[len(latin)-1], ".,"))] {
		return "", ""
	}
	latinPart, hanPart = strings.Join(latin, " "), strings.Join(han, " ")
	if countRunes(latinPart, isASCIILetter) < 2 || countRunes(hanPart, isHanRune) < 2 ||
		len(titleVersionTags("("+latinPart+")")) > 0 || normLoose(hanPart) == normLoose(cleanMediaTag(artist)) {
		return "", ""
	}
	return latinPart, hanPart
}

const bilingualTitleRejectRunes = "()（）[]［］【】{}<>《》〈〉「」『』\"“”-–—/／|｜:：0123456789０１２３４５６７８９"

// bilingualCreditWords:拉丁段以它结尾时汉字段是署名(「… feat. 某某」),不是曲名的另一种写法。
var bilingualCreditWords = map[string]bool{
	"feat": true, "ft": true, "featuring": true, "with": true, "x": true, "vs": true, "by": true, "prod": true, "and": true, "&": true,
}

// bilingualLatinWord:拉丁段的一个词 —— ASCII 字母,夹着撇号、句点、逗号、感叹号、问号、&。
func bilingualLatinWord(f string) bool {
	letters := 0
	for _, r := range f {
		switch {
		case isASCIILetter(r):
			letters++
		case strings.ContainsRune("'’.,!?&", r):
		default:
			return false
		}
	}
	return letters > 0 || f == "&"
}

// bilingualHanWord:汉字段的一个词 —— 汉字、假名、长音符、间隔号和中文标点,至少一个汉字。
func bilingualHanWord(f string) bool {
	has := false
	for _, r := range f {
		switch {
		case isHanRune(r):
			has = true
		case unicode.In(r, unicode.Hiragana, unicode.Katakana), strings.ContainsRune("ー・·，、！？。…～", r):
		default:
			return false
		}
	}
	return has
}

func isHanRune(r rune) bool { return unicode.Is(unicode.Han, r) }

func countRunes(s string, f func(rune) bool) int {
	n := 0
	for _, r := range s {
		if f(r) {
			n++
		}
	}
	return n
}

func startTitleReverseSpec(ctx context.Context, artist, title, album string, durationSecs float64, samples []string, isrc string) *titleReverseSpec {
	c, cancel := context.WithCancel(ctx)
	s := &titleReverseSpec{samples: samples, done: make(chan struct{}), cancel: cancel}
	go func() {
		defer close(s.done)
		s.corrected, s.method, s.artist = titleReverseLookup(c, artist, title, album, durationSecs, samples, isrc)
		if s.corrected != "" && normLoose(s.corrected) != normLoose(title) {
			s.ne, s.results = fetchScoredLyricCandidatesStreaming(withLyricQueryReason(c, s.method), s.artist, s.corrected, album, durationSecs, nil)
			s.fetched = c.Err() == nil
		}
	}()
	return s
}

// take:样本跟提前跑时一样就等它跑完、返回它;不一样(或根本没提前跑)返回 nil,并取消它。
func (s *titleReverseSpec) take(samples []string) *titleReverseSpec {
	if s == nil {
		return nil
	}
	if !slices.Equal(s.samples, samples) {
		s.cancel()
		return nil
	}
	<-s.done
	return s
}

func (s *titleReverseSpec) stop() {
	if s != nil {
		s.cancel()
	}
}
