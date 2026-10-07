package main

import (
	"context"
	"strings"
)

// 网易云 / Apple / QQ 三源和同专辑邻居都没给出封面时的补查,只在封面还空着时跑,按顺序、拿到一张就停:
//  1. 双语曲名(「Gold Rush Town 淘金小鎮」)拆出的汉字那段 —— 查歌词的标题反查早就这么拆(bilingualTitleHanPart),
//     曲库按整串搜不到。拆出来的曲名时长当未知:这类标题多半是视频,比录音室版长。
//  2. 这一轮歌词判决里被认下的候选报的歌手写法(「蒋雪儿Snow.J」),播放器报的写法(「蒋雪儿」)过不了各源的歌手比对。
//  3. 这首录音的 ISRC 在 Deezer 上那一条的专辑封面,歌手或曲名对得上才用。
// 第 1、2 步另外试去掉合作署名的写法:歌手取第一位(「Khalil Fong feat. Hanggai」→「Khalil Fong」),曲名去掉 feat. 那段
// (「Drunken (feat. Hanggai)」→「Drunken」),见决策 38。
//
// 写 CoverAlbum 跟三源同一个口径:网易云 / Apple / Deezer 写来源自己报的专辑名,QQ 不回传、写空。见 03 章决策 37。

// coverRetryLookups:补查用到的联网调用。包级变量 coverRetry 是正式那一套,单测换成假的。
type coverRetryLookups struct {
	netease func(ctx context.Context, artist, title, album string, durationSecs float64) neteaseInfo
	apple   func(ctx context.Context, artist, title, album string, durationSecs float64) appleMusicMatch
	qq      func(ctx context.Context, artist, title, album string) (string, string)
	deezer  func(ctx context.Context, isrc string) (deezerTrack, bool)
}

var coverRetry = coverRetryLookups{
	netease: neteaseLookup,
	apple:   appleMusicMatchCached,
	qq:      qqCoverFallback,
	deezer:  deezerTrackByISRC,
}

const (
	// coverRetryMaxQueries:「歌手写法 × 曲名写法」最多补查几组,每组最多三个请求。
	coverRetryMaxQueries = 4
	// coverRetryMaxArtistNames:从歌词判决里取几个别的歌手写法。
	coverRetryMaxArtistNames = 2
	// coverRetryMaxISRCs:最多拿几个 ISRC 问 Deezer。
	coverRetryMaxISRCs = 2
)

type coverRetryResult struct {
	url, source, album string
}

// fillMissingCover:e 还没有封面时补查,拿到就写进 e。歌手写法取 e 自己的歌词判决,没有(周边补全只查了网易云)就取缓存里
// 这首的那份。ISRC 取这一轮认下的那条录音(trustedRecordingISRC);周边补全没有候选,只剩播放器报的。调用方不能持有 enrichMu。
func fillMissingCover(ctx context.Context, e *enrichEntry, scored []scoredLyricCandidateResult,
	artist, title, album string, durationSecs float64, coverArtist, coverTitle, coverAlbum string, coverDuration float64) {
	if e.CoverURL != "" {
		return
	}
	decision := e.LyricsDecision
	if !hasDecisionDetails(decision) {
		if key, cached, ok := resolvedEnrichEntryKey(artist, title, album); ok {
			decision = withDecisionDetails(key, cached.LyricsDecision)
		}
	}
	var isrcs []string
	if isrc := trustedRecordingISRC(artist, title, album, durationSecs, scored); isrc != "" {
		isrcs = []string{isrc}
	}
	r, ok := retryMissingCover(ctx, coverRetry, coverArtist, coverTitle, coverAlbum, coverDuration,
		coverRetryArtistNames(decision, coverArtist), isrcs)
	if ok {
		e.CoverURL, e.CoverSource, e.CoverAlbum = r.url, r.source, r.album
	}
}

// coverRetryArtistNames:歌词判决里得了正分的候选报的歌手写法,跟 artist 不同的那些,按候选顺序去重,最多
// coverRetryMaxArtistNames 个。纯函数。
func coverRetryArtistNames(d *lyricsDecision, artist string) []string {
	if d == nil {
		return nil
	}
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	for _, c := range d.Candidates {
		k := normLoose(c.Artist)
		if c.Score <= 0 || k == "" || seen[k] {
			continue
		}
		seen[k] = true
		if out = append(out, c.Artist); len(out) == coverRetryMaxArtistNames {
			break
		}
	}
	return out
}

// retryMissingCover 按文件头那三步补查,返回拿到的那张。artist / title / album / durationSecs 是三源用过的那一套,
// 原样那一组不再查。
func retryMissingCover(ctx context.Context, l coverRetryLookups, artist, title, album string, durationSecs float64,
	artistNames, isrcs []string) (coverRetryResult, bool) {
	type query struct {
		artist, title string
		duration      float64
	}
	titles := []query{{title: title, duration: durationSecs}}
	latin, han := bilingualTitleParts(artist, title)
	if han != "" {
		titles = append(titles, query{title: han})
	}
	if t := titleWithoutFeatCredit(title); t != "" {
		titles = append(titles, query{title: t, duration: durationSecs})
	}
	artists := []string{artist}
	if first := primaryCreditedArtist(artist); first != "" && normLoose(first) != normLoose(artist) {
		artists = append(artists, first)
	}
	var queries []query
	for _, a := range append(artists, artistNames...) {
		for _, t := range titles {
			if a == artist && t.title == title {
				continue
			}
			queries = append(queries, query{a, t.title, t.duration})
		}
	}
	if len(queries) > coverRetryMaxQueries {
		queries = queries[:coverRetryMaxQueries]
	}
	for _, q := range queries {
		if ctx.Err() != nil {
			return coverRetryResult{}, false
		}
		if lyricSourceEnabled("netease") {
			if ne := l.netease(ctx, q.artist, q.title, album, q.duration); ne.Cover != "" {
				return coverRetryResult{ne.Cover, "netease", ne.Album}, true
			}
		}
		if m := l.apple(ctx, q.artist, q.title, album, q.duration); m.cover != "" {
			return coverRetryResult{m.cover, "apple", m.album}, true
		}
		if cover, _ := l.qq(ctx, q.artist, q.title, album); cover != "" {
			return coverRetryResult{cover, "qq", ""}, true
		}
	}
	if !lyricSourceEnabled("deezer") {
		return coverRetryResult{}, false
	}
	names := append([]string{artist}, artistNames...)
	for i, isrc := range isrcs {
		if i == coverRetryMaxISRCs || ctx.Err() != nil {
			break
		}
		t, ok := l.deezer(ctx, isrc)
		if !ok || t.cover() == "" || !deezerCoverTrackFits(t, names, title, latin, han) {
			continue
		}
		return coverRetryResult{t.cover(), "deezer", t.Album.Title}, true
	}
	return coverRetryResult{}, false
}

// primaryCreditedArtist:署名里的第一位。「X feat. Y」去掉 feat. 那段,「X、Y」「X & Y」取 X(firstCreditedArtist);
// 只有一位时原样返回。纯函数。
func primaryCreditedArtist(artist string) string {
	if s, ok := stripTitleFeatCredit(artist); ok {
		return strings.TrimSpace(s)
	}
	return firstCreditedArtist(artist)
}

// titleWithoutFeatCredit:曲名里带合作署名(「Drunken (feat. Hanggai)」「Song feat. X」)时去掉那段,不带时返回空串。纯函数。
func titleWithoutFeatCredit(title string) string {
	if !titleFeatCreditRe.MatchString(title) {
		return ""
	}
	t := strings.TrimSpace(stripParens(title))
	if s, ok := stripTitleFeatCredit(t); ok {
		t = strings.TrimSpace(s)
	}
	if t == "" || normLoose(t) == normLoose(title) {
		return ""
	}
	return t
}

// deezerCoverTrackFits:按 ISRC 取回的那条录音,歌手跟 names 里任意一个对得上,或者曲名跟 title、双语曲名拆出的哪一段对得上。
// 纯函数。
func deezerCoverTrackFits(t deezerTrack, names []string, title string, parts ...string) bool {
	for _, n := range names {
		if artistMatches(t.Artist.Name, n) {
			return true
		}
	}
	if lyricTitleAccepted(t.Title, title) {
		return true
	}
	for _, p := range parts {
		if p != "" && lyricTitleAccepted(t.Title, p) {
			return true
		}
	}
	return false
}
