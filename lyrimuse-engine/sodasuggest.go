package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"slices"
	"strings"
	"sync"
	"time"
)

// ---- 搜索联想:整页搜索不给结果时找汽水曲目 id 的第二条腿 ----
//
// 整页搜索(soda.go 的 sodaSearchAt)对不带客户端签名的请求可能整体回 200 + 空应答体;搜索联想 `/luna/sug` 不看签名、
// 不看 UA,两个主机都答。联想按前缀补全,每次最多 10 条,曲目那几条只给 id 和一行提示(「歌名 歌手」「歌名 - Live 歌手」
// 之类的写法),所以:
//
//   - 查询词歌名在前、歌手在后(「歌手 歌名」排不上原曲);先带版本、署名括号问(提示里常写着「feat. 某某」),
//     再去掉所有括号问,还没有就只按歌名问,
//     问到歌名、歌手、版本都对得上的就停(sodaSuggestQueries / sodaSuggestFound);
//   - 提示里含着去括号歌名的曲目才去问 `seo_track`,一次最多 sodaSuggestMaxLookups 条,并发问;`seo_track` 给的歌名、
//     歌手、专辑、时长、试听段拼成跟整页搜索同一个形状的 sodaSearchItem,之后的身份闸、排序、试听段挑选都不分来路;
//   - 问到的歌词顺手放进 sodaCache(按曲目 id),取词那一步不再问一遍。见 09 章决策 375。

const (
	// sodaSuggestPath:搜索联想。主机同整页搜索(sodaSearchHosts)。
	sodaSuggestPath = "/luna/sug"
	// sodaSuggestMaxLookups:一次联想里最多拿几条曲目去问 seo_track(每条应答约 200KB);sodaSuggestMaxLookupsTotal 是
	// 一次搜索换几个联想词加起来的上限。
	sodaSuggestMaxLookups      = 4
	sodaSuggestMaxLookupsTotal = 8
	// sodaSuggestParserName:parserdrift.go 里联想这条路径的名字;sodaSearchHealthItem 也读它。
	sodaSuggestParserName = "soda-search-suggest"
	// sodaSuggestMetaMax:按 id 记住问到的曲目信息,满了整张清掉。别名轮、备用主机那一轮会拿同一批 id 再问。
	sodaSuggestMetaMax = 512
)

// errSodaSearchRefused:整页搜索或联想回了 200,应答体却不是认得的形状(空的、不是 JSON、缺结果字段)。
var errSodaSearchRefused = errors.New("answered 200 without a search result")

var (
	sodaSuggestMetaMu sync.Mutex
	sodaSuggestMeta   = map[string]sodaSearchItem{}
)

type sodaSuggestion struct {
	ID   string
	Text string
}

// sodaSuggestResponse 只摘曲目那几条。没有联想时应答只带 status_info、省略 sugs(同一个词时有时无);两个字段都没有
// 才算认不出。
type sodaSuggestResponse struct {
	StatusInfo json.RawMessage `json:"status_info"`
	Sugs       *[]struct {
		Suggestion  string `json:"suggestion"`
		ContentType string `json:"content_type"`
		Entity      struct {
			Track struct {
				ID string `json:"id"`
			} `json:"track"`
		} `json:"entity"`
	} `json:"sugs"`
}

// sodaParseSuggest 把联想应答摊成曲目列表;ok=false 是认不出的形状。纯函数。
func sodaParseSuggest(raw []byte) ([]sodaSuggestion, bool) {
	var body sodaSuggestResponse
	if json.Unmarshal(raw, &body) != nil {
		return nil, false
	}
	if body.Sugs == nil {
		return nil, len(body.StatusInfo) > 0 && string(body.StatusInfo) != "null"
	}
	var out []sodaSuggestion
	for _, s := range *body.Sugs {
		id := strings.TrimSpace(s.Entity.Track.ID)
		if s.ContentType != "track" || id == "" {
			continue
		}
		out = append(out, sodaSuggestion{ID: id, Text: s.Suggestion})
	}
	return out, true
}

// sodaRefusalDetail:认不出的应答给健康检查看的一句线索。field 是应该有的那个结果字段。
func sodaRefusalDetail(raw []byte, field string) string {
	switch {
	case len(raw) == 0:
		return "200 with an empty body"
	case !json.Valid(raw):
		return "200 without JSON"
	default:
		return "JSON without " + field
	}
}

// sodaSuggestTitle:歌名去掉结尾所有括号段(破折号尾段先改写成括号段)。联想的提示里只看得到这一截。
func sodaSuggestTitle(title string) string {
	return trimTrailingBrackets(dashTailAsBracket(title), func(string) bool { return false })
}

// sodaSuggestQueries 依次要问的联想词,去重。纯函数。
func sodaSuggestQueries(artist, title string) []string {
	first := strings.TrimSpace(primaryCreditedArtist(artist))
	core := strings.TrimSpace(sodaSuggestTitle(title))
	versioned := strings.TrimSpace(normEnrichTitle(dashTailAsBracket(title)))
	var out []string
	add := func(q string) {
		if q = strings.TrimSpace(q); q != "" && !slices.Contains(out, q) {
			out = append(out, q)
		}
	}
	add(versioned + " " + first)
	add(core + " " + first)
	add(core)
	return out
}

// sodaSuggestCandidates 挑出值得问 seo_track 的曲目:提示里含着去括号的歌名,没问过;提示里也含着歌手的排前面,
// 其余保持联想自己的顺序;最多 limit 条。纯函数。
func sodaSuggestCandidates(sugs []sodaSuggestion, artist, title string, seen map[string]bool, limit int) []string {
	core := normLoose(sodaSuggestTitle(title))
	first := normLoose(primaryCreditedArtist(artist))
	var withArtist, rest []string
	for _, s := range sugs {
		if seen[s.ID] || slices.Contains(withArtist, s.ID) || slices.Contains(rest, s.ID) {
			continue
		}
		text := normLoose(s.Text)
		if !strings.Contains(text, core) {
			continue
		}
		if first != "" && strings.Contains(text, first) {
			withArtist = append(withArtist, s.ID)
		} else {
			rest = append(rest, s.ID)
		}
	}
	out := append(withArtist, rest...)
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// sodaSuggestFound:已经问到歌名、歌手、版本都对得上的曲目,不用再换联想词。纯函数。
func sodaSuggestFound(items []sodaSearchItem, artist, title string) bool {
	for _, it := range items {
		if lyricTitleAccepted(it.Name, title) && lyricSourceArtistMatches(it.Artist, artist) &&
			!versionTagsMismatch(title, "", it.Name, it.Album) {
			return true
		}
	}
	return false
}

// sodaSearchBySuggest 按联想找曲目。host 是答了联想的主机。err 非空时 items 可能还带着已经问到的几条
// (有候选的 seo_track 没问成):能用,但这份结果不完整,别缓存。
func sodaSearchBySuggest(ctx context.Context, hosts []string, artist, title string) ([]sodaSearchItem, string, error) {
	var items []sodaSearchItem
	var answered string
	var lookupErr error
	seen := map[string]bool{}
	for _, q := range sodaSuggestQueries(artist, title) {
		limit := min(sodaSuggestMaxLookups, sodaSuggestMaxLookupsTotal-len(seen))
		if limit <= 0 {
			break
		}
		var sugs []sodaSuggestion
		err := tryEach(ctx, hosts, func(host string) error {
			got, err := sodaSuggestAt(ctx, host, q)
			if err == nil {
				sugs, answered = got, host
			}
			return err
		})
		if err != nil {
			return items, answered, err
		}
		ids := sodaSuggestCandidates(sugs, artist, title, seen, limit)
		for _, id := range ids {
			seen[id] = true
		}
		got, err := sodaLookupSuggested(ctx, ids)
		items = append(items, got...)
		if err != nil {
			lookupErr = err
		}
		if sodaSuggestFound(items, artist, title) || ctx.Err() != nil {
			break
		}
	}
	return items, answered, lookupErr
}

// sodaSuggestAt 问一个主机上的联想。200 但认不出形状的,按这个接口被拒记一次(连着被拒由 hostguard 熔断),
// 并记进解析漂移(健康检查看得到)。
func sodaSuggestAt(ctx context.Context, host, q string) ([]sodaSuggestion, error) {
	params := neturl.Values{}
	params.Set("q", q)
	params.Set("aid", sodaSearchAID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+sodaSuggestPath+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", sodaUserAgent)
	resp, err := doHTTPTracked(lyricHTTPClient(sodaLyricTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes))
	if err != nil {
		return nil, err
	}
	sugs, ok := sodaParseSuggest(raw)
	if !ok {
		reportEndpointRejected(req.URL)
		noteParserUnrecognized(sodaSuggestParserName, sodaRefusalDetail(raw, "sugs or status_info"))
		return nil, errSodaSearchRefused
	}
	reportEndpointAccepted(req.URL)
	noteParserRecognized(sodaSuggestParserName)
	return sugs, nil
}

// sodaLookupSuggested 并发按 id 问 seo_track,按 ids 的顺序交回认得出的那几条。err 是最后一个没问成的。
func sodaLookupSuggested(ctx context.Context, ids []string) ([]sodaSearchItem, error) {
	type answer struct {
		item sodaSearchItem
		ok   bool
		err  error
	}
	answers := make([]answer, len(ids))
	var wg sync.WaitGroup
	for i, id := range ids {
		wg.Add(1)
		go func(i int, id string) {
			defer wg.Done()
			it, ok, err := sodaSuggestedItem(ctx, id)
			answers[i] = answer{it, ok, err}
		}(i, id)
	}
	wg.Wait()
	var items []sodaSearchItem
	var lastErr error
	for _, a := range answers {
		if a.err != nil {
			lastErr = a.err
		}
		if a.ok {
			items = append(items, a.item)
		}
	}
	return items, lastErr
}

// sodaSuggestedItem 问一条曲目的 seo_track。ok=false、err=nil:应答认不出这个 id(下架、端点换了形状),跳过。
// 有词的那份放进 sodaCache:直取 seo_track,跟 sodaLyricByID 取到的是同一份、带译文。
func sodaSuggestedItem(ctx context.Context, id string) (sodaSearchItem, bool, error) {
	sodaSuggestMetaMu.Lock()
	it, ok := sodaSuggestMeta[id]
	sodaSuggestMetaMu.Unlock()
	if ok {
		return it, true, nil
	}
	var raw []byte
	err := tryEach(ctx, sodaSeoHosts, func(host string) error {
		var e error
		raw, e = sodaGetSeoTrackAt(ctx, host, id)
		return e
	})
	if err != nil {
		return sodaSearchItem{}, false, err
	}
	var body sodaSeoTrackResponse
	if json.Unmarshal(raw, &body) != nil {
		return sodaSearchItem{}, false, nil
	}
	it, ok = sodaSearchItemFromSeo(body, id)
	if !ok {
		return sodaSearchItem{}, false, nil
	}
	if r, _, broken := sodaParseSeoTrack(body); !broken && !r.empty() {
		sodaMu.Lock()
		sodaCache[id] = r
		sodaMu.Unlock()
	}
	sodaSuggestMetaMu.Lock()
	if len(sodaSuggestMeta) >= sodaSuggestMetaMax {
		sodaSuggestMeta = map[string]sodaSearchItem{}
	}
	sodaSuggestMeta[id] = it
	sodaSuggestMetaMu.Unlock()
	return it, true, nil
}

// sodaSearchItemFromSeo 把 seo_track 的曲目信息换成搜索候选;不是这个 id、没有歌名的不认。纯函数。
func sodaSearchItemFromSeo(body sodaSeoTrackResponse, id string) (sodaSearchItem, bool) {
	t := body.SeoTrack.Track
	if strings.TrimSpace(t.ID) != id || strings.TrimSpace(t.Name) == "" {
		return sodaSearchItem{}, false
	}
	names := make([]string, 0, len(t.Artists))
	for _, a := range t.Artists {
		if n := strings.TrimSpace(a.Name); n != "" {
			names = append(names, n)
		}
	}
	return sodaSearchItem{
		ID:                id,
		Name:              dashTailAsBracket(t.Name),
		Artist:            strings.Join(names, "/"),
		Album:             strings.TrimSpace(t.Album.Name),
		Duration:          float64(t.Duration) / 1000,
		PreviewStartMs:    t.Preview.Start,
		PreviewDurationMs: t.Preview.Duration,
	}, true
}

// sodaSearchHealthItem:健康检查里「汽水搜索」那一行,读常驻实例落盘的解析漂移记录。汽水没启用时不出这一行。
// 整页搜索认不出、联想还好是 ok(已退到联想);两条都认不出是 warn:按歌名找不到汽水曲目,只有用汽水放过的歌还能取词。
func sodaSearchHealthItem(drift map[string]parserDriftEntry, sodaEnabled bool) (healthCheckItem, bool) {
	if !sodaEnabled {
		return healthCheckItem{}, false
	}
	full, fullBad := drift[sodaSearchParserName]
	sug, sugBad := drift[sodaSuggestParserName]
	since := func(e parserDriftEntry) string { return time.Unix(e.FirstAt, 0).Format("2006-01-02 15:04") }
	item := healthCheckItem{Name: "汽水搜索"}
	switch {
	case fullBad && sugBad:
		item.Status = healthWarn
		item.Detail = fmt.Sprintf("不可用:整页搜索自 %s 起连续 %d 次 %s,联想自 %s 起连续 %d 次 %s;只有用汽水放过的歌还取得到词",
			since(full), full.Streak, full.Detail, since(sug), sug.Streak, sug.Detail)
	case sugBad:
		item.Status = healthWarn
		item.Detail = fmt.Sprintf("联想自 %s 起连续 %d 次 %s,整页搜索还在用", since(sug), sug.Streak, sug.Detail)
	case fullBad:
		item.Status = healthOK
		item.Detail = fmt.Sprintf("整页搜索自 %s 起连续 %d 次 %s,已改用联想", since(full), full.Streak, full.Detail)
	default:
		item.Status = healthOK
		item.Detail = "没有连续认不出的应答"
	}
	return item, true
}
