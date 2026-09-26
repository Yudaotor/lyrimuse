package main

import (
	"context"
	"fmt"
	neturl "net/url"
	"strings"
	"sync"
)

// 编目匹配扩展搜索的歌手名来源(除 MusicBrainz 别名之外的三路),给 extNames 用。每一路都只提供
// **候选名字**:拿去查的条目仍要过「编目正规条目 + 时长」那道闸(decideExtended),不会绕过。
//
//   - Apple 区服对照(强):同一张专辑 / 同一条录音在中国区和美区的署名(「防弹少年团」↔「BTS」)。先读本机
//     缓存(appleStorefrontArtistCache,有专辑名的歌留下的),再联网按同一个查询问各区商店,**按曲目 id 对上**
//     (appleLinkedArtistNames)。
//   - YouTube Music 英文界面的署名(强):本地语言界面和英文界面各搜一次,**按视频 id 对上**。
//   - 歌词解析时胜出候选报的署名(弱):歌词源自己的署名可能错,按双语名那一档的门槛认。
//
// 前两路都靠 id 对应,不靠「曲名相同 + 时长相近 + 文字系统不同」去猜:那三道门挡不住同名的另一首歌 ——
// Taio Cruz《Dynamite》203 s 跟 BTS《Dynamite》199 s 只差 4 s,署名也是拉丁对汉字,而它在编目里是有 mbid
// 的正规条目,后面那道闸也拦不住,结果就是把 BTS 的打卡永久改写成 Taio Cruz。
//
// 单测一律换成桩(newCatalogServer / TestMain),绝不连 Apple / YouTube。决策见 12 章 §4(PS5)。

var (
	catalogStorefrontAliases = storefrontArtistAliasesCached
	catalogAppleTitleAliases = appleLinkedArtistNames
	catalogYTMusicAliases    = ytmusicOriginalArtistNames
	catalogLyricsIdentity    = enrichLyricsWinnerArtists
)

// storefrontArtistAliasesCached 读 Apple 区服署名缓存里这位歌手名下(任意专辑)记过的其他写法。只读缓存、不联网:
// 缓存键是「归一歌手|归一专辑」,MV 这类没有专辑名的曲目自己查不了,但同一位歌手别的歌查过就能借用。
func storefrontArtistAliasesCached(artist string) []string {
	prefix := normLoose(artist) + "|"
	if prefix == "|" {
		return nil
	}
	appleStorefrontArtistMu.Lock()
	defer appleStorefrontArtistMu.Unlock()
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	for k, names := range appleStorefrontArtistCache {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		for _, n := range names {
			if key := normLoose(n); key != "" && !seen[key] {
				seen[key] = true
				out = append(out, n)
			}
		}
	}
	return out
}

// enrichLyricsWinnerArtists 取这首歌歌词解析时胜出候选报的署名(决策留痕里的 WinnerArtist),按歌手 + 曲名
// 在缓存里找(不管专辑)。pending = 这首歌的歌词还没解析完 —— 开播那一刻就判的话多半如此,调用方据此只记
// 一条短期结论,等到打卡时再判一次。缓存里还没有这首歌也算 pending:新歌开播时条目往往还没建好,这时当成「没有
// 这一路名字」会在缺歌词署名的情况下下长期结论。没加载歌词缓存的进程(回填子命令)不算 pending,也没有名字。
// 按前缀扫一遍缓存,8000 条约 0.2 ms,只在编目匹配时调用。
func enrichLyricsWinnerArtists(artist, title string) (names []string, pending bool) {
	if enrichPath == "" {
		return nil, false
	}
	prefix := cleanMediaTag(artist) + "|" + normEnrichTitle(title) + "|"
	enrichMu.Lock()
	defer enrichMu.Unlock()
	found := false
	for k, e := range enrichCache {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		found = true
		d := e.LyricsDecisionApplied
		if d == nil {
			d = e.LyricsDecision
		}
		if d == nil {
			pending = true
			continue
		}
		if w := strings.TrimSpace(d.WinnerArtist); w != "" {
			names = append(names, w)
		}
	}
	if !found {
		pending = true
	}
	return names, pending
}

// catalogLinkedNameCache:按「来源|歌手|曲名」缓存两路 id 对应查询的结果(含查空),只在内存。短期结论
// (Provisional)几分钟后会重判,不缓存就要重复打同一组搜索。查询失败不缓存。常驻进程一跑好几天,条数封顶
// catalogLinkedNameMax,满了随手丢一条(map 遍历顺序不定)再放新的:丢掉的只是一次能重查的搜索结果。
const catalogLinkedNameMax = 2048

var (
	catalogLinkedNameMu    sync.Mutex
	catalogLinkedNameCache = map[string][]string{}
)

func catalogLinkedCached(key string, fetch func() ([]string, error)) ([]string, error) {
	catalogLinkedNameMu.Lock()
	if v, ok := catalogLinkedNameCache[key]; ok {
		catalogLinkedNameMu.Unlock()
		return v, nil
	}
	catalogLinkedNameMu.Unlock()
	v, err := fetch()
	if err != nil {
		return nil, err
	}
	catalogLinkedNameMu.Lock()
	if _, exists := catalogLinkedNameCache[key]; !exists && len(catalogLinkedNameCache) >= catalogLinkedNameMax {
		for old := range catalogLinkedNameCache {
			delete(catalogLinkedNameCache, old)
			break
		}
	}
	catalogLinkedNameCache[key] = v
	catalogLinkedNameMu.Unlock()
	return v, nil
}

// appleLinkedArtistNames 用「歌手 曲名」问各区商店(appleStorefrontsFor),把署名等于本地写法的那些曲目按 id
// 对到别的商店,取那边的署名。只要是这位歌手的曲目就能对上(不要求就是这首歌),名字归这位歌手本人。
// 任何一个商店没问成返回 error(这一路算没查成)。
func appleLinkedArtistNames(ctx context.Context, artist, title string, _ float64) ([]string, error) {
	if strings.TrimSpace(artist) == "" || strings.TrimSpace(title) == "" {
		return nil, nil
	}
	return catalogLinkedCached("apple|"+normLoose(artist)+"|"+normLoose(title), func() ([]string, error) {
		var results []itunesResult
		q := neturl.QueryEscape(strings.TrimSpace(artist + " " + title))
		for _, country := range appleStorefrontsFor(artist, title) {
			rs, ok := itunesSearch(ctx, q, country)
			if !ok {
				return nil, fmt.Errorf("itunes search %s unavailable", country)
			}
			results = append(results, rs...)
		}
		return pickAppleLinkedNames(results, artist), nil
	})
}

// pickAppleLinkedNames:署名归一后等于本地写法的曲目 id 集合,再在同 id 的结果里收署名不同的,最多两个。纯函数。
func pickAppleLinkedNames(results []itunesResult, artist string) []string {
	local := normLoose(artist)
	if local == "" {
		return nil
	}
	ids := map[int64]bool{}
	for _, r := range results {
		if r.TrackID > 0 && normLoose(r.ArtistName) == local {
			ids[r.TrackID] = true
		}
	}
	seen := map[string]bool{local: true}
	var out []string
	for _, r := range results {
		n := normLoose(r.ArtistName)
		if !ids[r.TrackID] || n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, r.ArtistName)
		if len(out) >= 2 {
			break
		}
	}
	return out
}

// ytmusicOriginalArtistNames 用 YouTube Music 按本地名字的文字对应的界面语言(简体 zh-CN / 繁体 zh-TW / 假名 ja /
// 谚文 ko)和英文界面各搜一次「歌手 曲名」,署名等于本地写法的那些结果按视频 id 对到英文那份,取英文署名。本地名字
// 不含中日韩文字时不查(英文名 → 中文名那个方向智能档现有的别名已经接得住)。网络失败返回 error。
func ytmusicOriginalArtistNames(ctx context.Context, artist, title string, _ float64) ([]string, error) {
	hl := ytmusicLocalHL(artist)
	if hl == "" || strings.TrimSpace(title) == "" {
		return nil, nil
	}
	return catalogLinkedCached("ytm|"+normLoose(artist)+"|"+normLoose(title), func() ([]string, error) {
		visitor := ytmusicEnsureVisitorID(ctx)
		local, err := ytmusicSearchSongsHL(ctx, artist+" "+title, hl, visitor)
		if err != nil {
			return nil, err
		}
		en, err := ytmusicSearchSongsHL(ctx, artist+" "+title, "en", visitor)
		if err != nil {
			return nil, err
		}
		return pickYTMusicLinkedNames(local, en, artist), nil
	})
}

// ytmusicLocalHL:本地署名的文字对应哪个界面语言;不含中日韩文字返回空。
func ytmusicLocalHL(artist string) string {
	switch dominantScript(artist) {
	case scriptKana:
		return "ja"
	case scriptHangul:
		return "ko"
	case scriptHan:
		if toSimplified(artist) != artist {
			return "zh-TW"
		}
		return "zh-CN"
	}
	return ""
}

// ytmusicSearchSongsHL 按指定界面语言跑一次歌曲搜索,返回解析好的条目。
func ytmusicSearchSongsHL(ctx context.Context, query, hl, visitorID string) ([]ytmusicParsedSearchItem, error) {
	body := ytmusicContext(ytmusicWebClientName, ytmusicWebClientVersion())
	if c, ok := body["context"].(map[string]any)["client"].(map[string]any); ok {
		c["hl"] = hl
	}
	body["query"] = strings.TrimSpace(query)
	body["params"] = ytmusicSongsFilterParams
	raw, err := ytmusicPost(ctx, "search", body, visitorID)
	if err != nil {
		return nil, err
	}
	var out []ytmusicParsedSearchItem
	for _, it := range ytmusicExtractSearchItems(raw) {
		if p, ok := ytmusicParseSearchItem(it); ok {
			out = append(out, p)
		}
	}
	return out, nil
}

// pickYTMusicLinkedNames:本地界面里署名等于本地写法的视频 id,在英文界面结果里取同 id、署名不同的,最多两个。纯函数。
func pickYTMusicLinkedNames(local, en []ytmusicParsedSearchItem, artist string) []string {
	want := normLoose(artist)
	ids := map[string]bool{}
	for _, it := range local {
		if it.videoID != "" && normLoose(it.artist) == want {
			ids[it.videoID] = true
		}
	}
	seen := map[string]bool{want: true}
	var out []string
	for _, it := range en {
		n := normLoose(it.artist)
		if !ids[it.videoID] || n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, it.artist)
		if len(out) >= 2 {
			break
		}
	}
	return out
}

// parenthesizedAlias 拆「名字(别名)」「名字（别名）」:两段都非空才算。
func parenthesizedAlias(s string) (outer, inner string, ok bool) {
	s = strings.TrimSpace(s)
	for _, br := range [][2]string{{"(", ")"}, {"（", "）"}} {
		if !strings.HasSuffix(s, br[1]) {
			continue
		}
		i := strings.LastIndex(s, br[0])
		if i <= 0 {
			continue
		}
		outer, inner = strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+len(br[0]):len(s)-len(br[1])])
		if outer != "" && inner != "" {
			return outer, inner, true
		}
	}
	return "", "", false
}
