package main

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
)

// 原产地曲名:Apple Music 中国区 / 美区把不少日文歌的曲名登记成罗马字或英文(「Hanataba」=「花束」、
// 「Happy End」=「ハッピーエンド」),本地标签跟着这么写,而网易云 / QQ / 酷狗 / 汽水 / 酷我 / 咪咕收录的是原文,
// 拿本地曲名搜不到;同一位歌手另一首时长相近的歌还可能被当成这一首。这首歌在原产地商店(originStorefronts)的曲名
// 有两个来处:按这条录音的 ISRC 在原产地商店的 Apple Music 曲库里查(appleMusicRecordingByISRC,同时带回那边的署名),
// 和区服遍历留下的结论(appleStorefrontCanonicalTitle / appleStorefrontCachedTitle,只有曲名)。消费方:标题反查
// (titleReverseLookup)和可用源已经够数、还有源缺着时的原产地曲名轮(enrich.go)。决策见 09 章决策 153。

// crossScriptBase:canonical 去掉括号部分之后,跟 local 去掉括号部分是不是两套文字(一边有中日韩文字、一边没有)。
// 只有括号里换了文字的不算:「First Love (feat. デヴィッド・サンボーン)」对「In My Room」、「GIRL (feat. 呂布)」对「GIRL」。
func crossScriptBase(local, canonical string) bool {
	l, c := strings.TrimSpace(stripParens(local)), strings.TrimSpace(stripParens(canonical))
	return l != "" && c != "" && artistScriptDiffers(l, c)
}

// originStorefronts:appleStorefrontsFor 在基线 CN / US 之外按样本的文字系统加进来的商店,小写(Apple Music 曲库接口的写法)。
func originStorefronts(samples ...string) []string {
	var out []string
	for _, c := range appleStorefrontsFor(samples...) {
		if c != "CN" && c != "US" {
			out = append(out, strings.ToLower(c))
		}
	}
	return out
}

// trustedRecordingISRC:这一条录音的 ISRC。播放器给的(playbackISRC,就是正在播的这一条)优先,其次是已被认可的
// Apple Music 候选报的(acceptedAppleMusicISRC)。都没有返回空。
func trustedRecordingISRC(artist, title, album string, durationSecs float64, results []scoredLyricCandidateResult) string {
	if code := playbackISRC(artist, title, album); code != "" {
		return code
	}
	return acceptedAppleMusicISRC(results, durationSecs)
}

// originRecording:这一条录音在原产地商店里的曲名和署名。artist 为空 = 只知道曲名(区服遍历的结论不带署名)。
type originRecording struct {
	title, artist string
}

// originRecordingByISRC:按 ISRC 依次问 origins 里的商店,第一个曲名跟本地曲名换了文字(crossScriptBase)的那条;没有返回零值。
func originRecordingByISRC(ctx context.Context, title, isrc string, origins []string, durationSecs float64) originRecording {
	if isrc == "" {
		return originRecording{}
	}
	for _, sf := range origins {
		if rec := appleMusicRecordingByISRC(ctx, isrc, sf, durationSecs); crossScriptBase(title, rec.title) {
			return rec
		}
	}
	return originRecording{}
}

// lyricOriginRecording:本地曲名在这首歌的原产地商店里换了一套文字写时,返回原产地的曲名(和署名);否则零值。原产地商店按
// 署名 / 曲名 / 专辑名和首轮歌词正文(samples)的文字系统判(originStorefronts)。先按 ISRC 查(originRecordingByISRC,
// 带回署名);没有 ISRC 或查不出时用区服遍历留下的结论(只读缓存,不打请求,只有曲名)。
func lyricOriginRecording(ctx context.Context, artist, title, album string, durationSecs float64, samples []string, isrc string) originRecording {
	origins := originStorefronts(append([]string{artist, title, album}, samples...)...)
	if len(origins) == 0 {
		return originRecording{}
	}
	if rec := originRecordingByISRC(ctx, title, isrc, origins, durationSecs); rec.title != "" {
		return rec
	}
	if t, ok := appleStorefrontCachedTitle(artist, album, title); ok && crossScriptBase(title, t) {
		return originRecording{title: t}
	}
	return originRecording{}
}

// titleReverseOriginTitle:标题反查第三条路的曲名 —— 区服遍历的结论(appleStorefrontCanonicalTitle),给不出跨文字的
// 原产地曲名时按 ISRC 查(originRecordingByISRC)。只认去掉括号部分之后换了文字的(crossScriptBase),否则空。
func titleReverseOriginTitle(ctx context.Context, artist, title, album string, durationSecs float64, samples []string, isrc string) string {
	if t := appleStorefrontCanonicalTitle(ctx, artist, title, album, durationSecs, samples); crossScriptBase(title, t) {
		return t
	}
	return originRecordingByISRC(ctx, title, isrc, originStorefronts(append([]string{artist, title, album}, samples...)...), durationSecs).title
}

// appleMusicISRCCache:appleMusicRecordingByISRC 的结论(含查空),键 isrc|storefront,只在内存。条数封顶
// appleMusicISRCMax,满了随手丢一条再放新的:丢掉的只是一次能重查的请求。
const appleMusicISRCMax = 2048

var (
	appleMusicISRCMu    sync.Mutex
	appleMusicISRCCache = map[string]originRecording{}
)

// appleMusicRecordingByISRC:ISRC 在 storefront(小写,如 jp)这个商店的 Apple Music 曲库里对应的曲名和署名(pickISRCSong)。
// 只要 developer token。没问成返回零值、不记结论。
func appleMusicRecordingByISRC(ctx context.Context, isrc, storefront string, durationSecs float64) originRecording {
	key := isrc + "|" + storefront
	appleMusicISRCMu.Lock()
	if v, ok := appleMusicISRCCache[key]; ok {
		appleMusicISRCMu.Unlock()
		return v
	}
	appleMusicISRCMu.Unlock()
	devToken := applemusicEnsureDeveloperToken(ctx)
	if devToken == "" {
		return originRecording{}
	}
	path := neturl.PathEscape(storefront) + "/songs?filter[isrc]=" + neturl.QueryEscape(isrc)
	raw, status, err := applemusicAPIGet(ctx, path, devToken, "")
	if err == nil && (status == http.StatusUnauthorized || status == http.StatusForbidden) {
		// developer token 失效(Apple 换了 bundle 里那张票),作废重取一次,同 applemusicSearch。
		applemusicClearDevToken()
		if newTok := applemusicEnsureDeveloperToken(ctx); newTok != "" && newTok != devToken {
			raw, status, err = applemusicAPIGet(ctx, path, newTok, "")
		}
	}
	if err != nil || status != http.StatusOK {
		return originRecording{}
	}
	var resp struct {
		Data []applemusicSong `json:"data"`
	}
	if json.Unmarshal(raw, &resp) != nil {
		return originRecording{}
	}
	rec := pickISRCSong(resp.Data, durationSecs)
	appleMusicISRCMu.Lock()
	if _, exists := appleMusicISRCCache[key]; !exists && len(appleMusicISRCCache) >= appleMusicISRCMax {
		for old := range appleMusicISRCCache {
			delete(appleMusicISRCCache, old)
			break
		}
	}
	appleMusicISRCCache[key] = rec
	appleMusicISRCMu.Unlock()
	return rec
}

// pickISRCSong:一个 ISRC 常挂着好几个发行(单曲、专辑、精选),取时长最接近本地、而且差在
// appleStorefrontCrossScriptToleranceSecs 之内的那一条的曲名和署名;没有本地时长时取第一条有曲名的。纯函数。
func pickISRCSong(songs []applemusicSong, durationSecs float64) originRecording {
	var best originRecording
	bestDiff := math.Inf(1)
	for _, s := range songs {
		rec := originRecording{title: strings.TrimSpace(s.Attributes.Name), artist: strings.TrimSpace(s.Attributes.ArtistName)}
		if rec.title == "" {
			continue
		}
		if durationSecs <= 0 {
			return rec
		}
		d := math.Abs(float64(s.Attributes.DurationInMillis)/1000 - durationSecs)
		if d <= appleStorefrontCrossScriptToleranceSecs && d < bestDiff {
			best, bestDiff = rec, d
		}
	}
	return best
}

// originTitleRound:原产地曲名轮。本地曲名在原产地商店里换了一套文字写(罗马字写的日文歌名)时,缺着的源
// (lyricSourcesWorthAliasRetry)多半是拿本地曲名搜不到原文登记的这首歌:拿原产地曲名(lyricOriginRecording)只问它们,
// 合并(mergeLyricCandidateRounds)照旧按本地署名、本地曲名统一重打分。先用本地署名问;原产地的署名跟本地不同
// (本地是中文区的写法:「爱缪」对「あいみょん」、「Official胡子男dism」对「Official髭男dism」)时,还缺着的源再拿
// 原产地署名问一次。没有缺着的源、或拿不到原产地曲名时原样返回。
func originTitleRound(ctx context.Context, artist, title, album string, durationSecs float64, ne neteaseInfo,
	results []scoredLyricCandidateResult, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	if len(lyricSourcesWorthAliasRetry(ctx, results)) == 0 {
		return ne, results
	}
	origin := lyricOriginRecording(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results),
		trustedRecordingISRC(artist, title, album, durationSecs, results))
	if origin.title == "" {
		return ne, results
	}
	notifyProvisionalLyrics(ctx, ne, results)
	queryArtists := []string{artist}
	if origin.artist != "" && normLoose(origin.artist) != normLoose(artist) {
		queryArtists = append(queryArtists, origin.artist)
	}
	for _, qa := range queryArtists {
		only := lyricSourcesWorthAliasRetry(ctx, results)
		if len(only) == 0 {
			break
		}
		originUpdate := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
		originCtx := withLyricQueryReason(withLyricSourceOnly(ctx, only), lyricQueryReasonTitleStorefront)
		originNe, originResults := fetchScoredLyricCandidatesStreaming(originCtx, qa, origin.title, album, durationSecs, originUpdate)
		for i := range originResults {
			originResults[i].RetryMethod = lyricQueryReasonTitleStorefront
			originResults[i].RetriedTitle = origin.title
		}
		merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, originResults)
		if usableLyricSourceCount(merged) > usableLyricSourceCount(results) {
			log.Printf("lyrics: origin title %q by %q added candidates for %q - %q: usable_sources=%d->%d",
				origin.title, qa, artist, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
		}
		if ne.Cover == "" && originNe.Cover != "" {
			ne.Cover, ne.Album, ne.AlbumID = originNe.Cover, originNe.Album, originNe.AlbumID
		}
		if ne.SongURL == "" && originNe.SongURL != "" {
			ne.SongURL = originNe.SongURL
		}
		results = merged
	}
	return ne, results
}
