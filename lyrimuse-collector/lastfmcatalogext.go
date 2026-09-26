package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"unicode"
)

// 编目匹配的**扩展搜索**:基础判定(lastfmcatalog.go 的 decide)一条够格的候选都没找到、
// 本来要判 defer 时才跑。
//
// # 要解决的是什么
//
// 基础判定只在「播放器报的歌手名 / 第一位歌手」名下找,而 Last.fm 经常把一个歌手收在
// **别的名字**下面:英文名、双语名里的一半、繁体写法、合唱里的另一位。实测分布与逐首
// 核对见 docs/features/12 §4「扩展搜索」。
//
// # 新增的三处候选来源,以及各自凭什么认定「是同一个人」
//
//   - 合唱里的**每一位**歌手(基础判定只看第一位):署名本身就写着他。
//   - 这些歌手在 MusicBrainz 登记的别名(catalogArtistAliases):MB 明确登记过本地写法
//     属于这位艺人才给(见 musicBrainzArtistAliases 头注),身份是 MB 背书的。
//   - track.search 按曲名搜全站,**只收**歌手名折叠后等于上面某个名字的结果。它按字面串
//     搜全网,会带回同名不同歌手的结果 —— 歌手必须对得上是它能用的前提,那一类进不来。
//     它补的是繁简不同的歌手名:折叠后相等,但 artist.getTopTracks 的 autocorrect 不管繁简。
//
// 上面三处都是**强**身份。另有一处**弱**身份:
//
//   - 中英双语的歌手名拆成两半(`鹤 The Crane` → `鹤` / `The Crane`)。拆出来的一半可能
//     恰好是另一个同名艺人,所以从这一半名下找到的条目必须同时满足:有 mbid 或听众 ≥
//     lastfmCatalogListenersMin、编目时长和播放器时长都有且对得上(见 weakCandidateOK)。
//
// # 选哪一条
//
// 按强弱分三档依次找,找到即停:
//
//  1. 强身份里「编目正规条目」(catalogued)听众最多、过时长闸的那条;
//  2. 弱身份里同样够格、且过 weakCandidateOK 的那条;
//  3. 都没有 → 强身份候选里听众最多的那条,前提是它明显比原样的人多
//     (lastfmCatalogFallbackMinListeners / lastfmCatalogFallbackFactor)。这一档对应的是
//     「编目里根本没有正规条目」的歌:几个影子条目里挑大家实际在用的那条,而不是自己再
//     建一条只有自己的影子。
//
// 版本标记(Live / Remix / DJ 版 / 伴奏)仍由曲名折叠键原样保留,时长闸仍然生效 ——
// 扩展的只是「去哪些名字下面找」,不是「什么算同一首歌」。
//
// # 只在基础判定判 defer 时才跑
//
// 基础判定能得出 keep / match 的歌一律不走这里,结论跟改动前逐字相同。否则一个已经有
// 正规条目的歌手会因为 MB 别名名下「听众更多」被挪到另一个名字下,跟他以前判过的歌分成
// 两个歌手页。
//
// # 没查成时不下永久结论
//
// Last.fm 那几路(track.getInfo / 曲目表 / track.search)任何一路没查成都返回 error,整次判定不落盘。
// 名字来源(MusicBrainz 别名 / Apple / YouTube Music / 歌词署名)有一路没查成时,其余名字照查:第 1、2 档
// 找到的编目正规条目照用,第 3 档(兜底)不走,defer 只记短期(Provisional)—— 候选集残缺时判出的 defer
// 或兜底结论可能漏掉真正的条目,而那两种结论是长期的。
const (
	// 第三档(兜底)候选至少要有这么多听众。一两个人用过的写法多半是某个人手打错的,
	// 不能当成「大家实际在用的那条」。
	lastfmCatalogFallbackMinListeners = 20
	// 第三档候选的听众数至少是原样的这么多倍,才值得挪过去。
	lastfmCatalogFallbackFactor = 2
	// 扩展搜索最多查几个名字(合唱各位 + MB 别名 + 双语两半)。每个名字两个请求。
	lastfmCatalogExtMaxNames = 8
	// 最多给几个合唱歌手查 MusicBrainz 别名 —— 没缓存时每位要两次限速请求(约 2.2 s)。
	lastfmCatalogExtMaxAliasCredits = 3
	// track.search 一页取多少条。结果按歌手严格过滤,取多一点只是多几行 JSON。
	lastfmCatalogSearchLimit = "30"
	// 扩展判定的口径版本。旧口径下判的 defer 在加载后按这个版本重判一次(见 lookup)。
	lastfmCatalogExtVersion = 2
)

// catalogArtistAliases 是 MusicBrainz 别名来源,单测替换成桩。
var catalogArtistAliases = musicBrainzArtistAliasesChecked

type identityStrength int

const (
	identityStrong identityStrength = iota
	identityWeak
)

// extName 是扩展搜索要查的一个名字,带着它的身份强弱。
type extName struct {
	name     string
	strength identityStrength
}

// extCandidate 是扩展搜索找到的候选。
type extCandidate struct {
	catalogCandidate
	strength identityStrength
	via      string
}

// decideExtended 在基础判定判 defer 之后跑。base 是基础判定已经查过、确认不够格的候选
// (原样 / 第一位歌手 / 该歌手曲目表里的同名条目),own 是原样的收录情况。
func (c *lastfmCatalogMatcher) decideExtended(ctx context.Context, artist, track string, durationSecs float64,
	scope matchScope, own lastfmCatalogProbe, base []catalogCandidate) (lastfmCatalogDecision, error) {
	deferred := lastfmCatalogDecision{Verdict: verdictDefer, Artist: artist, Track: track, Own: &own, Scope: scope.id()}
	if catalogBaseOnly(ctx) {
		return deferred, nil
	}
	// 不许改歌手时,别的名字下的条目一条都用不上,只剩 track.search 里歌手折叠后跟原样相等
	// 的那几条(繁简不同的同一个写法,跟基础判定 candidates 的 allowed 同一口径)。
	var names []extName
	partial := false
	if scope.artist {
		names, partial = c.extNames(ctx, artist, track, durationSecs)
	}
	cands, err := c.extCandidates(ctx, artist, track, names, base, scope)
	if err != nil {
		return lastfmCatalogDecision{}, err
	}

	// 第 1、2 档:编目正规条目,强身份在前。
	for _, want := range []identityStrength{identityStrong, identityWeak} {
		group := filterExt(cands, func(e extCandidate) bool { return e.strength == want })
		sortExtByListeners(group)
		for _, e := range group {
			if !e.probe.catalogued() {
				continue
			}
			p, err := c.confirm(ctx, e.catalogCandidate)
			if err != nil {
				return lastfmCatalogDecision{}, err
			}
			if !p.catalogued() || !p.durationFits(durationSecs) {
				continue
			}
			if want == identityWeak && !weakCandidateOK(p, durationSecs) {
				continue
			}
			return lastfmCatalogDecision{
				Verdict: verdictMatch, Artist: e.artist, Track: e.track,
				Own: &own, Chosen: &p, Scope: scope.id(), Via: e.via,
			}, nil
		}
	}

	// 名字来源有一路没查成(MusicBrainz 退避 / 503、YouTube Music 失败、歌词还没解析完):上面两档用的都是编目
	// 正规条目,缺了某些名字只是可能少找到一条,找到的那条照用;第 3 档要在「全部候选」里挑大家在用的那条,
	// 候选不全就可能挑错而结论是永久的,所以不走,只记一条短期 defer(Provisional),几分钟后重判。
	if partial {
		deferred.Provisional = true
		return deferred, nil
	}

	// 第 3 档:编目里没有正规条目。在强身份候选(含基础判定查过的那几条)里挑大家实际在用的那条。
	pool := filterExt(cands, func(e extCandidate) bool { return e.strength == identityStrong })
	for _, b := range base {
		if b.artist == artist && b.track == track {
			continue // 原样本身不是「挪过去」的目标
		}
		pool = append(pool, extCandidate{catalogCandidate: b, strength: identityStrong, via: "base"})
	}
	sortExtByListeners(pool)
	threshold := own.Listeners * lastfmCatalogFallbackFactor
	if threshold < lastfmCatalogFallbackMinListeners {
		threshold = lastfmCatalogFallbackMinListeners
	}
	for _, e := range pool {
		if e.probe.Listeners < threshold {
			break // 已按听众降序
		}
		p, err := c.confirm(ctx, e.catalogCandidate)
		if err != nil {
			return lastfmCatalogDecision{}, err
		}
		if !p.Found || p.Listeners < threshold || !p.durationFits(durationSecs) {
			continue
		}
		return lastfmCatalogDecision{
			Verdict: verdictMatch, Artist: e.artist, Track: e.track,
			Own: &own, Chosen: &p, Scope: scope.id(), Via: e.via + "+fallback",
		}, nil
	}
	return deferred, nil
}

// weakCandidateOK 是弱身份(双语名拆出来的一半)候选的额外门槛:编目正规身份要硬
// (mbid 或听众够多,光有编目时长不算),两边时长都得有且对得上 —— 同名的另一个艺人
// 恰好有一首同名、同时长(± lastfmCatalogDurationTolerance)的歌,概率才小到可以接受。
func weakCandidateOK(p lastfmCatalogProbe, durationSecs float64) bool {
	if p.MBID == "" && p.Listeners < lastfmCatalogListenersMin {
		return false
	}
	return p.DurationMS > 0 && durationSecs > 0 && p.durationFits(durationSecs)
}

// extNames 列出扩展搜索要查的名字,强身份在前:合唱各位、他们的 MusicBrainz 别名、Apple 区服对照、
// YouTube Music 英文署名(都是强);歌词解析时胜出候选报的署名、双语名的两半(弱)。不含原样整串本身
// (基础判定查过了)。去重按折叠键,强身份优先,超过 lastfmCatalogExtMaxNames 截掉的是排在后面的弱身份。
// 第二个返回值 partial = 有一路名字来源这次没查成(见 decideExtended 里怎么处理),其余照常列出。
func (c *lastfmCatalogMatcher) extNames(ctx context.Context, artist, track string, durationSecs float64) ([]extName, bool) {
	partial := false
	var out []extName
	seen := map[string]bool{lastfmCatalogArtistKey(artist): true}
	add := func(name string, strength identityStrength) {
		name = strings.TrimSpace(name)
		key := lastfmCatalogArtistKey(name)
		if key == "" || seen[key] {
			return
		}
		seen[key] = true
		out = append(out, extName{name: name, strength: strength})
	}

	credits := catalogCreditNames(artist)
	for _, cr := range credits {
		add(cr, identityStrong)
	}
	// 别名查询对象:合唱各位;单人时就是原样整串。
	aliasOf := credits
	if len(aliasOf) == 0 {
		aliasOf = []string{strings.TrimSpace(artist)}
	}
	if len(aliasOf) > lastfmCatalogExtMaxAliasCredits {
		aliasOf = aliasOf[:lastfmCatalogExtMaxAliasCredits]
	}
	for _, who := range aliasOf {
		aliases, err := catalogArtistAliases(ctx, who)
		if err != nil {
			log.Printf("lastfm catalog: artist aliases for %q unavailable: %v (continuing with other names)", who, err)
			partial = true
			continue
		}
		for _, a := range aliases {
			add(a, identityStrong)
		}
	}
	for _, who := range aliasOf {
		for _, a := range catalogStorefrontAliases(who) {
			add(a, identityStrong)
		}
	}
	if appleNames, err := catalogAppleTitleAliases(ctx, artist, track, durationSecs); err != nil {
		log.Printf("lastfm catalog: apple storefront names for %q / %q unavailable: %v", artist, track, err)
		partial = true
	} else {
		for _, a := range appleNames {
			add(a, identityStrong)
		}
	}
	if ytNames, err := catalogYTMusicAliases(ctx, artist, track, durationSecs); err != nil {
		log.Printf("lastfm catalog: youtube music names for %q / %q unavailable: %v", artist, track, err)
		partial = true
	} else {
		for _, a := range ytNames {
			add(a, identityStrong)
		}
	}
	lyricNames, pending := catalogLyricsIdentity(artist, track)
	if pending {
		partial = true
	}
	for _, n := range lyricNames {
		// 「BTS(防弹少年团)」这种括号写法拆成括号外、括号里两个名字;整串本身不是任何人的名字,不查。
		if outer, inner, ok := parenthesizedAlias(n); ok {
			add(outer, identityWeak)
			add(inner, identityWeak)
			continue
		}
		add(n, identityWeak)
		if han, latin, ok := bilingualArtistHalves(n); ok {
			add(han, identityWeak)
			add(latin, identityWeak)
		}
	}
	halvesOf := aliasOf
	if len(credits) > 0 {
		halvesOf = credits
	}
	for _, who := range halvesOf {
		if han, latin, ok := bilingualArtistHalves(who); ok {
			add(han, identityWeak)
			add(latin, identityWeak)
		}
	}
	// 加入顺序就是强身份在前(歌词署名、双语两半这两路弱身份最后加),截断截掉的是弱身份。
	if len(out) > lastfmCatalogExtMaxNames {
		out = out[:lastfmCatalogExtMaxNames]
	}
	return out, partial
}

// extCandidates 对每个名字查一次「这个名字 + 原曲名」和它的曲目表,再按曲名搜一次全站。
// 请求并发发出(每个都有自己的超时,合计仍受调用方 ctx 管)。任何一路没查成就整体失败。
func (c *lastfmCatalogMatcher) extCandidates(ctx context.Context, artist, track string, names []extName,
	base []catalogCandidate, scope matchScope) ([]extCandidate, error) {
	trackKey := lastfmCatalogTitleKey(track)
	artistKey := lastfmCatalogArtistKey(artist)
	strengthOf := map[string]identityStrength{}
	for _, n := range names {
		strengthOf[lastfmCatalogArtistKey(n.name)] = n.strength
	}
	strengthOf[artistKey] = identityStrong

	var (
		mu       sync.Mutex
		out      []extCandidate
		firstErr error
		wg       sync.WaitGroup
	)
	addCand := func(e extCandidate) {
		mu.Lock()
		defer mu.Unlock()
		if !scope.track && lastfmCatalogTitleKey(e.track) != trackKey {
			return
		}
		if !scope.artist && lastfmCatalogArtistKey(e.artist) != artistKey {
			return
		}
		if containsCandidate(base, e.artist, e.track) {
			return // 基础判定已经查过、确认不够格
		}
		for i, x := range out {
			if x.artist == e.artist && x.track == e.track {
				if e.strength < x.strength {
					out[i].strength = e.strength // 同一条被强身份也找到了,按强算
				}
				return
			}
		}
		out = append(out, e)
	}
	fail := func(err error) {
		mu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		mu.Unlock()
	}

	for _, n := range names {
		n := n
		wg.Add(2)
		go func() {
			defer wg.Done()
			if containsCandidate(base, n.name, track) {
				return // 基础判定已经按这个名字查过原曲名(第一位歌手)
			}
			p, err := c.probe(ctx, n.name, track)
			if err != nil {
				fail(err)
				return
			}
			if !p.Found {
				return
			}
			// 按应答里那条条目自己的写法提交,不按查询串:autocorrect 把别名归到正规条目上时,
			// 提交别名能不能被同样纠正过去没有保证,纠不过去就是又建了一条影子。纠正后曲名折叠键
			// 变了 = autocorrect 把我们带到了另一条录音上,不收。
			a, tr := orDefault(p.Artist, n.name), orDefault(p.Name, track)
			if lastfmCatalogTitleKey(tr) != trackKey {
				return
			}
			addCand(extCandidate{catalogCandidate: catalogCandidate{artist: a, track: tr, probe: p},
				strength: n.strength, via: "name"})
		}()
		go func() {
			defer wg.Done()
			rows, err := c.topTracks(ctx, n.name)
			if err != nil {
				fail(err)
				return
			}
			for _, m := range catalogTitleMatches(rows, track, lastfmCatalogMaxTitleMatches) {
				// 曲目表的 autocorrect 可能把名字归到别的歌手页上,歌手按表里实际写的那个名字认身份。
				s, ok := strengthOf[lastfmCatalogArtistKey(m.Artist)]
				if !ok {
					s = n.strength
				}
				addCand(extCandidate{catalogCandidate: catalogCandidate{artist: m.Artist, track: m.Name,
					probe: lastfmCatalogProbe{Found: true, MBID: m.MBID, Listeners: m.Listeners}, needsConfirm: true},
					strength: s, via: "top"})
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		rows, err := c.searchTracks(ctx, track)
		if err != nil {
			fail(err)
			return
		}
		for _, m := range rows {
			if lastfmCatalogTitleKey(m.Name) != trackKey {
				continue
			}
			s, ok := strengthOf[lastfmCatalogArtistKey(m.Artist)]
			if !ok {
				continue // 歌手对不上的一律不收 —— 这是 track.search 能用的前提
			}
			addCand(extCandidate{catalogCandidate: catalogCandidate{artist: m.Artist, track: m.Name,
				probe: lastfmCatalogProbe{Found: true, MBID: m.MBID, Listeners: m.Listeners}, needsConfirm: true},
				strength: s, via: "search"})
		}
	}()
	wg.Wait()
	if firstErr != nil {
		return nil, firstErr
	}
	return out, nil
}

// searchTracks 调 track.search。返回 error = 没查成。结果只是候选线索,调用方必须按歌手和
// 曲名折叠键严格过滤(见 extCandidates)。
func (c *lastfmCatalogMatcher) searchTracks(ctx context.Context, track string) ([]lastfmTopTrack, error) {
	q := neturl.Values{}
	q.Set("method", "track.search")
	q.Set("api_key", c.apiKey)
	q.Set("format", "json")
	q.Set("track", track)
	q.Set("limit", lastfmCatalogSearchLimit)

	base := c.baseURL
	if base == "" {
		base = lastfmAPIBase
	}
	ctx, cancel := context.WithTimeout(ctx, lastfmTopTracksTimeout)
	defer cancel()
	// 双重编码同 probe(见 lastfmGetQuery)。
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+lastfmGetQuery(q), nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(c.hc, req)
	if err != nil {
		return nil, fmt.Errorf("track.search: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		Results struct {
			TrackMatches struct {
				Track []struct {
					Name      string `json:"name"`
					Artist    string `json:"artist"`
					MBID      string `json:"mbid"`
					Listeners string `json:"listeners"`
				} `json:"track"`
			} `json:"trackmatches"`
		} `json:"results"`
		Error   int    `json:"error"`
		Message string `json:"message"`
	}
	decodeErr := json.NewDecoder(resp.Body).Decode(&body)
	if body.Error == lastfmErrRateLimited {
		reportEndpointRateLimited(req.URL, "")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("track.search status %d", resp.StatusCode)
	}
	if decodeErr != nil {
		return nil, fmt.Errorf("decode track.search: %w", decodeErr)
	}
	if body.Error != 0 {
		return nil, fmt.Errorf("track.search error %d: %s", body.Error, body.Message)
	}
	out := make([]lastfmTopTrack, 0, len(body.Results.TrackMatches.Track))
	for _, t := range body.Results.TrackMatches.Track {
		if strings.TrimSpace(t.Name) == "" || strings.TrimSpace(t.Artist) == "" {
			continue
		}
		listeners, err := atoiOrZero(t.Listeners)
		if err != nil {
			return nil, fmt.Errorf("track.search listeners %q: %w", t.Listeners, err)
		}
		out = append(out, lastfmTopTrack{Name: t.Name, Artist: t.Artist, Listeners: listeners, MBID: t.MBID})
	}
	return out, nil
}

// catalogCreditNames 把合唱署名按主分隔符(、 & , ,以及「和」)切开,保留原始写法。
// 切不出两段返回 nil —— 单人名(含 `AC/DC`、`K/DA` 这类带斜杠的)不在这里处理。
func catalogCreditNames(artist string) []string {
	normalized := normalizeArtistCreditHanAnd(strings.TrimSpace(artist))
	var parts []string
	for _, p := range strings.FieldsFunc(normalized, isArtistCreditPrimarySep) {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) < 2 {
		return nil
	}
	return parts
}

// bilingualArtistHalves 把「中文名 + 英文名」这种双语歌手名拆成两半:`鹤 The Crane` 到
// (`鹤`, `The Crane`),`YELLOW黄宣` → (`黄宣`, `YELLOW`)。
//
// 只认**恰好两段**:一段全是中日韩文字、一段全是拉丁字母(中间的空格 / 标点 / 数字跟着
// 相邻那段走)。三段以上(`A吴B`)的结构说不清哪半是名字,不拆;拉丁那段少于两个字母的
// 不拆(一个字母当不了歌手名)。
func bilingualArtistHalves(name string) (han, latin string, ok bool) {
	type seg struct {
		cjk bool
		b   strings.Builder
	}
	var segs []*seg
	for _, r := range strings.TrimSpace(name) {
		var cjk, letter bool
		switch {
		case unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul):
			cjk, letter = true, true
		case unicode.In(r, unicode.Latin):
			letter = true
		}
		if letter && (len(segs) == 0 || segs[len(segs)-1].cjk != cjk) {
			segs = append(segs, &seg{cjk: cjk})
		}
		if len(segs) == 0 {
			continue // 开头的标点 / 数字,没有段可挂
		}
		segs[len(segs)-1].b.WriteRune(r)
	}
	if len(segs) != 2 {
		return "", "", false
	}
	for _, s := range segs {
		text := strings.TrimSpace(s.b.String())
		if s.cjk {
			han = text
		} else {
			latin = text
		}
	}
	letters := 0
	for _, r := range latin {
		if unicode.IsLetter(r) {
			letters++
		}
	}
	if han == "" || letters < 2 {
		return "", "", false
	}
	return han, latin, true
}

func filterExt(in []extCandidate, keep func(extCandidate) bool) []extCandidate {
	var out []extCandidate
	for _, e := range in {
		if keep(e) {
			out = append(out, e)
		}
	}
	return out
}

// sortExtByListeners 按听众降序,同听众保持原顺序(候选只有十几条,插入排序)。
func sortExtByListeners(cands []extCandidate) {
	for i := 1; i < len(cands); i++ {
		for j := i; j > 0 && cands[j].probe.Listeners > cands[j-1].probe.Listeners; j-- {
			cands[j], cands[j-1] = cands[j-1], cands[j]
		}
	}
}
