package main

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"slices"
	"strconv"
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

// originStorefronts:这首歌的原产地商店,按这个顺序问(小写,Apple Music 曲库接口的写法)。
//   - ISRC 的登记国有对应商店的(isrcOriginStorefront)排最前:三项标签全是罗马字、又没有任何正文时,它是唯一的原产地线索;
//   - 再是 appleStorefrontsFor 在基线 CN / US 之外按样本文字系统加进来的(假名 → jp、谚文 → kr……);
//   - 本地曲名没有中日韩文字、样本里又有以汉字为主的,最后接上三个中文区商店(chineseOriginStorefronts):华语歌的曲库分在
//     cn / tw / hk,常常只在其中一两个上架(港台歌手的歌大陆商店多半没有),简繁看不出是哪个。排在别的商店后面:日文歌的正文
//     汉字一多也会被判成汉字为主,先问 jp 才拿得到日文原名。本地曲名带中日韩文字时中文区那边也是,换不了文字,不问。
//
// 样本里要包含本地曲名。见 09 章决策 243。
func originStorefronts(isrc, title string, samples ...string) []string {
	var out []string
	add := func(c string) {
		if c != "" && !slices.Contains(out, c) {
			out = append(out, c)
		}
	}
	add(isrcOriginStorefront(isrc))
	for _, c := range appleStorefrontsFor(samples...) {
		if c != "CN" && c != "US" {
			add(strings.ToLower(c))
		}
	}
	if !containsCJKScript(stripParens(title)) {
		for _, c := range chineseOriginStorefronts(samples...) {
			add(c)
		}
	}
	return out
}

// isrcOriginCountries:ISRC 前两位(登记国)→ 原产地商店。只收 appleStorefrontsFor 按文字系统会挑的几个区和三个中文区;美国等
// 其余登记国(含 QM / QZ 这类美国代发的前缀)不是原产地信号。
var isrcOriginCountries = map[string]string{"JP": "jp", "KR": "kr", "TH": "th", "RU": "ru", "CN": "cn", "TW": "tw", "HK": "hk"}

func isrcOriginStorefront(isrc string) string {
	if len(isrc) < 2 {
		return ""
	}
	return isrcOriginCountries[strings.ToUpper(isrc[:2])]
}

// recordingOrigins:这条录音该去问的原产地商店(originStorefronts),和拿去问的 ISRC。标签、ISRC 登记国都定不出原产地、手上又一行
// 正文都没有(samples 为空)时,拿这条录音的身份问一次 Apple 曲库,按它报的演唱语言(audioLocale)定(localeOriginStorefronts):
// 有 ISRC 按 ISRC 问;没有 ISRC、正在放的是 Apple 目录里的这一条(playbackTrackIDsFor)时按目录 id 问,同时带回 ISRC。有正文时
// 不问:正文的文字就是更直接的信号,全是拉丁字母的多半是西文歌,问了也是 en,原产地曲名轮里每首西文歌都会白问一次。见 09 章决策 244。
func recordingOrigins(ctx context.Context, artist, title, album string, durationSecs float64, samples []string, isrc string) ([]string, string) {
	all := append([]string{artist, title, album}, samples...)
	if origins := originStorefronts(isrc, title, all...); len(origins) > 0 || len(samples) > 0 {
		return origins, isrc
	}
	appleID := ""
	if isrc == "" {
		appleID, _ = playbackTrackIDsFor(artist, title, album)
	}
	if isrc == "" && appleID == "" {
		return nil, ""
	}
	locale, idISRC := appleRecordingLocale(ctx, isrc, appleID, durationSecs)
	if isrc == "" {
		isrc = idISRC
	}
	if isrc == "" {
		return nil, ""
	}
	origins := originStorefronts(isrc, title, all...)
	for _, c := range localeOriginStorefronts(locale) {
		if appleChineseStorefront(strings.ToUpper(c)) && containsCJKScript(stripParens(title)) {
			continue
		}
		if !slices.Contains(origins, c) {
			origins = append(origins, c)
		}
	}
	return origins, isrc
}

// localeOriginStorefronts:Apple 曲库报的演唱语言(audioLocale,如 ja、ko、zh-Hans-CN、zh-Hant-HK)对应的原产地商店(小写)。
// 中文给三个中文区:简繁标记分不出上架的商店(台湾登记的周杰伦报 zh-Hans-CN),只拿它定顺序,繁体 / 粤语 tw、hk、cn,其余 cn、tw、hk。
// 英文、没有人声(zxx)等不是原产地信号,空。
func localeOriginStorefronts(locale string) []string {
	lang, _, _ := strings.Cut(strings.ToLower(locale), "-")
	switch lang {
	case "ja":
		return []string{"jp"}
	case "ko":
		return []string{"kr"}
	case "th":
		return []string{"th"}
	case "ru":
		return []string{"ru"}
	case "zh", "cmn", "yue":
		if lang == "yue" || strings.Contains(locale, "Hant") {
			return []string{"tw", "hk", "cn"}
		}
		return []string{"cn", "tw", "hk"}
	}
	return nil
}

// appleRecordingLocaleCache:appleRecordingLocale 的结论(含查空),键「isrc:<ISRC>」或「id:<目录 id>」,只在内存;满了随手丢一条。
const appleRecordingLocaleMax = 1024

type appleRecordingFacts struct {
	locale, isrc string
}

var (
	appleRecordingLocaleMu    sync.Mutex
	appleRecordingLocaleCache = map[string]appleRecordingFacts{}
)

// appleRecordingLocale:这条录音在 Apple 曲库里报的演唱语言。有 ISRC 按 ISRC 依次问 us、cn(先有的那个,一个 ISRC 挂着几个发行时
// 按时长挑,同 pickISRCSong);只有目录 id 时在它所在的商店(目录锚点的链接,没有就 us)按 id 问,ISRC 也取回来(时长对得上才认)。
// 只要 developer token;没问成不记结论。
func appleRecordingLocale(ctx context.Context, isrc, appleID string, durationSecs float64) (locale, idISRC string) {
	key := "isrc:" + isrc
	if isrc == "" {
		key = "id:" + appleID
	}
	appleRecordingLocaleMu.Lock()
	if v, ok := appleRecordingLocaleCache[key]; ok {
		appleRecordingLocaleMu.Unlock()
		return v.locale, v.isrc
	}
	appleRecordingLocaleMu.Unlock()
	var facts appleRecordingFacts
	answered := false
	if isrc != "" {
		devToken := applemusicEnsureDeveloperToken(ctx)
		if devToken == "" {
			return "", ""
		}
		for _, sf := range []string{"us", "cn"} {
			raw, status, err := applemusicAPIGet(ctx, sf+"/songs?filter[isrc]="+neturl.QueryEscape(isrc), devToken, "")
			if err != nil || status != http.StatusOK {
				continue
			}
			answered = true
			var resp struct {
				Data []applemusicSong `json:"data"`
			}
			if json.Unmarshal(raw, &resp) != nil {
				continue
			}
			if s, ok := pickISRCSongEntry(resp.Data, durationSecs); ok {
				facts.locale = s.Attributes.AudioLocale
				break
			}
		}
	} else {
		sf := "us"
		if id, err := strconv.ParseInt(appleID, 10, 64); err == nil {
			if t, ok := appleCatalogTrackCachedOnly(id); ok {
				if s := appleStorefrontFromURL(t.TrackViewURL); s != "" {
					sf = s
				}
			}
		}
		songs, ok := appleCatalogSongsByID(ctx, sf, []string{appleID})
		if ok {
			answered = true
			song, has := songs[appleID]
			if has {
				facts.locale = song.audioLocale
				facts.isrc = isrcFromAppleSong(song, has, durationSecs)
			}
		}
	}
	if !answered {
		return "", ""
	}
	appleRecordingLocaleMu.Lock()
	if _, exists := appleRecordingLocaleCache[key]; !exists && len(appleRecordingLocaleCache) >= appleRecordingLocaleMax {
		for old := range appleRecordingLocaleCache {
			delete(appleRecordingLocaleCache, old)
			break
		}
	}
	appleRecordingLocaleCache[key] = facts
	appleRecordingLocaleMu.Unlock()
	return facts.locale, facts.isrc
}

// chineseOriginStorefronts:样本里有以汉字为主的,三个中文区商店按问的顺序给出(小写):有一条是繁体就 tw、hk、cn,否则 cn、tw、hk。
// 没有以汉字为主的样本时空。
func chineseOriginStorefronts(samples ...string) []string {
	han, trad := false, false
	for _, s := range samples {
		if dominantScript(s) != scriptHan {
			continue
		}
		han = true
		if toSimplified(s) != s {
			trad = true
		}
	}
	switch {
	case !han:
		return nil
	case trad:
		return []string{"tw", "hk", "cn"}
	default:
		return []string{"cn", "tw", "hk"}
	}
}

// trustedRecordingISRC:这一条录音的 ISRC。播放器给的(playbackISRC,就是正在播的这一条)优先,其次是已被认可的
// Apple Music 候选报的(acceptedAppleMusicISRC),再次是已被认可的 Deezer 候选报的(Apple Music 这一轮没给出可用候选时),
// 最后是缓存里这首记着的(confidentISRC:播放器报过或核对过的号;检索配的不算)。手动搜索是另起的进程、没有播放状态,
// 罗马字曲名这一轮又常常一个候选都没有,只剩缓存这一条能去原产地商店查原名,见 09 章决策 245。
// 都没有返回空。调用方不能持有 enrichMu。
func trustedRecordingISRC(artist, title, album string, durationSecs float64, results []scoredLyricCandidateResult) string {
	if code := playbackISRC(artist, title, album); code != "" {
		return code
	}
	if code := acceptedAppleMusicISRC(results, durationSecs); code != "" {
		return code
	}
	if code := acceptedSourceISRC(results, "deezer", durationSecs); code != "" {
		return code
	}
	if e, ok := resolvedEnrichEntry(artist, title, album); ok {
		return e.confidentISRC()
	}
	return ""
}

// originRecording:这一条录音在原产地商店里的曲名和署名。artist 为空 = 只知道曲名(区服遍历的结论不带署名)。
type originRecording struct {
	title, artist string
}

// originRecordingByISRC:按 ISRC 依次问 origins 里的商店,第一个上架了这条录音的商店说了算:它的曲名跟本地曲名换了文字
// (crossScriptBase)就返回那条,没换(那边也这么写,本地写法就是原名)就是零值、后面的商店不再问。都没有这条录音时零值。
func originRecordingByISRC(ctx context.Context, title, isrc string, origins []string, durationSecs float64) originRecording {
	if isrc == "" {
		return originRecording{}
	}
	for _, sf := range origins {
		rec := appleMusicRecordingByISRC(ctx, isrc, sf, durationSecs)
		if rec.title == "" {
			continue
		}
		if crossScriptBase(title, rec.title) {
			return rec
		}
		return originRecording{}
	}
	return originRecording{}
}

// lyricOriginRecording:本地曲名在这首歌的原产地商店里换了一套文字写时,返回原产地的曲名(和署名);否则零值。原产地商店按
// 署名 / 曲名 / 专辑名和首轮歌词正文(samples)的文字系统判(originStorefronts)。先按 ISRC 查(originRecordingByISRC,
// 带回署名);没有 ISRC 或查不出时用区服遍历留下的结论(只读缓存,不打请求,只有曲名)。
func lyricOriginRecording(ctx context.Context, artist, title, album string, durationSecs float64, samples []string, isrc string) originRecording {
	origins, isrc := recordingOrigins(ctx, artist, title, album, durationSecs, samples, isrc)
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
	origins, isrc := recordingOrigins(ctx, artist, title, album, durationSecs, samples, isrc)
	return originRecordingByISRC(ctx, title, isrc, origins, durationSecs).title
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
		applemusicClearDevToken(devToken)
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
	s, ok := pickISRCSongEntry(songs, durationSecs)
	if !ok {
		return originRecording{}
	}
	return originRecording{title: strings.TrimSpace(s.Attributes.Name), artist: strings.TrimSpace(s.Attributes.ArtistName)}
}

// pickISRCSongEntry:pickISRCSong 挑中的那一条本身(有曲名的里面时长差 4 秒以内最接近的;没有本地时长取第一条有曲名的)。
func pickISRCSongEntry(songs []applemusicSong, durationSecs float64) (applemusicSong, bool) {
	var best applemusicSong
	found := false
	bestDiff := math.Inf(1)
	for _, s := range songs {
		if strings.TrimSpace(s.Attributes.Name) == "" {
			continue
		}
		if durationSecs <= 0 {
			return s, true
		}
		d := math.Abs(float64(s.Attributes.DurationInMillis)/1000 - durationSecs)
		if d <= appleStorefrontCrossScriptToleranceSecs && d < bestDiff {
			best, bestDiff, found = s, d, true
		}
	}
	return best, found
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
	return originRecordingPasses(ctx, artist, title, album, durationSecs, origin.title, queryArtists, ne, results, onUpdate)
}

// titleReverseOriginArtistRound:标题反查拿原产地曲名(用本地署名)问完之后,这条录音在原产地商店的署名(按 ISRC 查,
// originRecordingByISRC)跟本地写法不同、而且曲名就是这次反查用的那个时,还缺着的源再拿原产地署名问一轮(同
// originTitleRound 的第二遍)。没有缺着的源、拿不到署名时原样返回。只在反查走的是原产地曲名那条路时调。
func titleReverseOriginArtistRound(ctx context.Context, artist, title, album string, durationSecs float64, samples []string,
	correctedTitle string, ne neteaseInfo, results []scoredLyricCandidateResult, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	if len(lyricSourcesWorthAliasRetry(ctx, results)) == 0 {
		return ne, results
	}
	origins, isrc := recordingOrigins(ctx, artist, title, album, durationSecs, samples, trustedRecordingISRC(artist, title, album, durationSecs, results))
	origin := originRecordingByISRC(ctx, title, isrc, origins, durationSecs)
	if origin.artist == "" || normLoose(origin.artist) == normLoose(artist) || normLoose(origin.title) != normLoose(correctedTitle) {
		return ne, results
	}
	return originRecordingPasses(ctx, artist, title, album, durationSecs, origin.title, []string{origin.artist}, ne, results, onUpdate)
}

// originRecordingPasses:拿原产地曲名依次用 queryArtists 里的署名只问还缺着的源(lyricSourcesWorthAliasRetry,每问一遍
// 重算一次),候选带上改写记号,合并(mergeLyricCandidateRounds)照旧按本地署名、本地曲名统一重打分。
func originRecordingPasses(ctx context.Context, artist, title, album string, durationSecs float64, originTitle string, queryArtists []string,
	ne neteaseInfo, results []scoredLyricCandidateResult, onUpdate lyricSearchUpdateFunc) (neteaseInfo, []scoredLyricCandidateResult) {
	for _, qa := range queryArtists {
		only := lyricSourcesWorthAliasRetry(ctx, results)
		if len(only) == 0 {
			break
		}
		originUpdate := mergedRoundUpdate(onUpdate, artist, title, album, durationSecs, results)
		originCtx := withLyricQueryReason(withLyricSourceOnly(ctx, only), lyricQueryReasonTitleStorefront)
		originNe, originResults := fetchScoredLyricCandidatesStreaming(originCtx, qa, originTitle, album, durationSecs, originUpdate)
		for i := range originResults {
			originResults[i].RetryMethod = lyricQueryReasonTitleStorefront
			originResults[i].RetriedTitle = originTitle
		}
		merged := mergeLyricCandidateRounds(artist, title, album, durationSecs, results, originResults)
		if usableLyricSourceCount(merged) > usableLyricSourceCount(results) {
			log.Printf("lyrics: origin title %q by %q added candidates for %q - %q: usable_sources=%d->%d",
				originTitle, qa, artist, title, usableLyricSourceCount(results), usableLyricSourceCount(merged))
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
