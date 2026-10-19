package main

import (
	"context"
	"encoding/json"
	"log"
	"maps"
	"math"
	"net/http"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// 这条录音的 ISRC(国际标准录音编码)。一份录音一个,不随商店语言、上架的专辑变;同一份录音也可能被不同发行商各登记
// 过一个。记进条目的 isrcs,App 合并收听写法时按它认「是不是同一首」(EnrichTitleAliases),见 12 章决策 61。
//
// 来路:Spotify 原生客户端、Amazon Music 在播时报的(playbackISRC,就是这一条录音);这一轮已被认可(分数 >= 0)、自报时长跟
// 播放器报的对得上(isrcDurationFits)的 applemusic / deezer 候选报的;存量条目由 startRecordingISRCSweep 按已存的 Apple 歌曲 id、
// Spotify 曲目 id、Amazon 曲目 ASIN 补,正在放的那首由 playbackISRCJobLocked 当场补(18 章决策 63)。ISRC 有脏数据(占位符样式的
// 编号被注册给了不相干的歌),候选报的都要过时长闸,占位符样式的直接丢掉。
//
// 每个号写进来时在 isrc_levels 记来路级别(歌曲实体按它定这个号能不能当强证据,见 18 章决策 5):播放器报的是 player,按曲目
// id 从本机 Spotify、Amazon 缓存读到的,在 Apple Music 上放过的条目按它报的目录锚点问到的也是;候选、补扫按检索配上的 Apple
// 链接取回的,配上的那一轨版本词跟这一条对得上是 verified(补扫另要那一轨的署名写全了合作者或时长几乎相等),对不上是
// searched。同一个号取更高的级别;没记级别的号(这一机制之前写进来的)由歌曲实体按写法有没有版本词推断。

// recordingISRCMax:一条最多记几个。
const recordingISRCMax = 4

const (
	isrcLevelPlayer   = "player"
	isrcLevelVerified = "verified"
	isrcLevelSearched = "searched"
)

var isrcLevelRank = map[string]int{isrcLevelSearched: 1, isrcLevelVerified: 2, isrcLevelPlayer: 3}

// recordedISRC:一个号和它的来路级别(级别为空:不知道)。
type recordedISRC struct {
	code, level string
}

// isrcDurationToleranceSecs:候选自报时长跟播放器报的最多差多少才认它报的 ISRC。Apple 报毫秒,同一份录音差不到
// 0.01 秒;Deezer 报整秒,差不到 1 秒。
const isrcDurationToleranceSecs = 1.5

var isrcFormatRe = regexp.MustCompile(`^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$`)

// normalizeISRC:去掉连字符和空白、转大写。格式不对(国家码两位 + 登记者三位 + 年份两位 + 序号五位),或是占位符样式
// (后七位是同一个数字,如 ZZZZZ9999999)时返回空串。
func normalizeISRC(code string) string {
	c := strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code)))
	if !isrcFormatRe.MatchString(c) {
		return ""
	}
	if digits := c[5:]; strings.Count(digits, digits[:1]) == len(digits) {
		return ""
	}
	return c
}

// isrcDurationFits:两边时长都知道,且差在 isrcDurationToleranceSecs 以内。
func isrcDurationFits(localSecs, sourceSecs float64) bool {
	return localSecs > 0 && sourceSecs > 0 && math.Abs(localSecs-sourceSecs) <= isrcDurationToleranceSecs
}

// recordingISRCsFromScored:这一轮认出来的这条录音的 ISRC,带级别。playback 是播放器报的(没有传空串),排在前面;候选报的
// 按候选顺序接在后面。title / album 是本地这一条的,候选配上的那一轨跟它比版本词;候选的曲名证明不了它就是这一条时
// (isrcCandidateTitleUnproven)也只记 searched。
func recordingISRCsFromScored(playback string, scored []scoredLyricCandidateResult, durationSecs float64, title, album string) []recordedISRC {
	var out []recordedISRC
	if c := normalizeISRC(playback); c != "" {
		out = append(out, recordedISRC{c, isrcLevelPlayer})
	}
	for _, r := range scored {
		c := normalizeISRC(r.ISRC)
		if c == "" || (r.Source != "applemusic" && r.Source != "deezer") || r.Score < 0 ||
			!isrcDurationFits(durationSecs, r.SourceReportedDurationSecs) {
			continue
		}
		level := isrcLevelVerified
		if versionTagsMismatch(title, album, r.Title, r.Album) || isrcCandidateTitleUnproven(title, album, r) {
			level = isrcLevelSearched
		}
		out = append(out, recordedISRC{c, level})
	}
	return out
}

// isrcCandidateTitleUnproven:候选 r 的曲名证明不了它就是本地这一条 —— 它是标题反查里歌手泛搜只凭时长改写曲名之后那一轮搜到的
// (RetryMethod 是 title-from-artist-search:改写对不对全看时长凑不凑巧),或者两边都是拉丁字母、明摆着是两首歌
// (titleSearchContradicts)。这种号不能当核对过的用:confidentISRC、trustedRecordingISRC 的缓存退路拿它去原产地商店查原名,
// 配错的那首就被钉住了。同专辑曲目表那一路有专辑钉着,照旧算。调用方可能持 enrichMu,这里只做纯文本判断。见 18 章决策 70。
func isrcCandidateTitleUnproven(title, album string, r scoredLyricCandidateResult) bool {
	return r.RetryMethod == lyricQueryReasonTitleSearch || titleSearchContradicts(title, album, r.Title)
}

// confidentISRC:写入时记了级别、能拿去给别人认录音的号:播放器报的优先,其次核对过的;没有返回空串。检索配的、
// 没记级别的(存量)不算。核对过的号都是按这一条现在的时长核的:条目时长原地改了、或并进来的条目时长对不上,按别的时长
// 核过的号已经降成检索配的(isrcLevelAcrossDuration),时长对不上的号进不了这一步,拿不准的不报。同级别还剩几个号时,
// 它们的时长都对得上这一条(同一份录音两家发行商各登记一个),按号排序取第一个,结果稳定。见 18 章决策 77。
func (e enrichEntry) confidentISRC() string {
	best, bestRank := "", 0
	for _, code := range e.ISRCs {
		code = normalizeISRC(code)
		rank := 0
		switch e.ISRCLevels[code] {
		case isrcLevelPlayer:
			rank = 2
		case isrcLevelVerified:
			rank = 1
		}
		if rank > bestRank || (rank == bestRank && rank > 0 && code < best) {
			best, bestRank = code, rank
		}
	}
	return best
}

// recordISRCs 把 add 并进条目:号照 mergeRecordingISRCs 的规矩进 isrcs,级别记进 isrc_levels(同一个号取更高的)。
// 满了以后新来的号级别比已记的最低那个高,就挤掉那一个(evictForHigherISRCs);挤不掉的号不记。isrc_levels 换一份新的写,
// 不改原来那份(快照可能还拿着它)。
func recordISRCs(e *enrichEntry, add []recordedISRC) {
	codes := make([]string, len(add))
	for i, a := range add {
		codes[i] = a.code
	}
	isrcs, evicted := evictForHigherISRCs(mergeRecordingISRCs(e.ISRCs, codes), e.ISRCLevels, add)
	e.ISRCs = isrcs
	var levels map[string]string
	if len(evicted) > 0 {
		levels = maps.Clone(e.ISRCLevels)
		for _, c := range evicted {
			delete(levels, c)
		}
		if levels == nil {
			levels = map[string]string{}
		}
	}
	for _, a := range add {
		c := normalizeISRC(a.code)
		have := e.ISRCLevels[c]
		if levels != nil {
			have = levels[c]
		}
		if c == "" || isrcLevelRank[a.level] <= isrcLevelRank[have] || !slices.Contains(e.ISRCs, c) {
			continue
		}
		if levels == nil {
			levels = maps.Clone(e.ISRCLevels)
			if levels == nil {
				levels = map[string]string{}
			}
		}
		levels[c] = a.level
	}
	if levels != nil {
		if len(levels) == 0 {
			levels = nil
		}
		e.ISRCLevels = levels
	}
}

// evictForHigherISRCs:isrcs 已经记满、add 里还有没进去的号时,按 add 的顺序,一个号的级别比 isrcs 里级别最低的那个高
// (播放器报的 > 核对过的 > 检索配的 > 没记级别的存量),就挤掉那一个、把它接在末尾;最低的有几个时挤最后进来的那个。
// 只在有新号进来时挤,存量不回头重排。返回新的列表和挤掉的号。
func evictForHigherISRCs(isrcs []string, levels map[string]string, add []recordedISRC) ([]string, []string) {
	incoming := map[string]int{}
	for _, a := range add {
		if c := normalizeISRC(a.code); c != "" && isrcLevelRank[a.level] > incoming[c] {
			incoming[c] = isrcLevelRank[a.level]
		}
	}
	rank := func(c string) int {
		return max(isrcLevelRank[levels[normalizeISRC(c)]], incoming[normalizeISRC(c)])
	}
	var evicted []string
	for _, a := range add {
		c := normalizeISRC(a.code)
		if c == "" || slices.Contains(isrcs, c) || len(isrcs) < recordingISRCMax {
			continue
		}
		victim := -1
		for i, have := range isrcs {
			if victim < 0 || rank(have) <= rank(isrcs[victim]) {
				victim = i
			}
		}
		if victim < 0 || isrcLevelRank[a.level] <= rank(isrcs[victim]) {
			continue
		}
		evicted = append(evicted, normalizeISRC(isrcs[victim]))
		isrcs = append(slices.Delete(slices.Clone(isrcs), victim, victim+1), c)
	}
	return isrcs, evicted
}

// mergeEntryISRCs:把 src 的号连同级别并进 dst(外围补全、合并条目用)。src 的号是按 src 的时长核过的,两边时长对不上时
// 按 isrcLevelAcrossDuration 降级并进来;两条记着同一个播放器的同一个曲目 id(sameRecordingEntries)时播放器报的号照旧。
func mergeEntryISRCs(dst *enrichEntry, src enrichEntry) {
	keepPlayer := sameRecordingEntries(*dst, src)
	add := make([]recordedISRC, len(src.ISRCs))
	for i, c := range src.ISRCs {
		level := isrcLevelAcrossDuration(src.ISRCLevels[normalizeISRC(c)], src.DurationSecs, dst.DurationSecs, keepPlayer)
		add[i] = recordedISRC{c, level}
	}
	recordISRCs(dst, add)
}

// isrcLevelAcrossDuration:按 fromSecs 这个时长记下的号,放到时长是 toSecs 的条目上该记什么级别。候选、补扫报的号写入时按当时的
// 时长过了 isrcDurationFits,两个时长都知道又对不上时它证明不了是这一条,降成 searched(confidentISRC 不报、歌曲实体只当弱证据,
// 号本身留着);keepPlayer 时播放器报的号不降(按曲目 id 来的,跟时长无关)。对得上、任一边不知道时级别不变。见 18 章决策 77。
func isrcLevelAcrossDuration(level string, fromSecs, toSecs float64, keepPlayer bool) string {
	if fromSecs <= 0 || toSecs <= 0 || isrcDurationFits(fromSecs, toSecs) || (keepPlayer && level == isrcLevelPlayer) {
		return level
	}
	return isrcLevelSearched
}

// demoteISRCsAcrossDuration:条目记下的时长从 fromSecs 原地改成 toSecs 之前调,按旧时长记下的号照 isrcLevelAcrossDuration
// 降级;播放器报的号不降(原地改时长的几处,播放器报的都还是同一首)。返回改没改。
func demoteISRCsAcrossDuration(e *enrichEntry, fromSecs, toSecs float64) bool {
	return demoteISRCs(e, func(_, level string) bool {
		return isrcLevelAcrossDuration(level, fromSecs, toSecs, true) != level
	})
}

// demoteISRCs:demote 认定的号(参数是号和它现在的级别)级别改成 searched,号本身留着;已经是 searched 的不动。
// isrc_levels 换一份新的写,不改原来那份(快照可能还拿着它)。返回改没改。
func demoteISRCs(e *enrichEntry, demote func(code, level string) bool) bool {
	var levels map[string]string
	for _, raw := range e.ISRCs {
		c := normalizeISRC(raw)
		have := e.ISRCLevels[c]
		if c == "" || have == isrcLevelSearched || !demote(c, have) {
			continue
		}
		if levels == nil {
			levels = maps.Clone(e.ISRCLevels)
			if levels == nil {
				levels = map[string]string{}
			}
		}
		levels[c] = isrcLevelSearched
	}
	if levels == nil {
		return false
	}
	e.ISRCLevels = levels
	return true
}

// removeISRCs:拿掉 drop 认定的号,连同它们的级别。都拿光时两个字段都是 nil。
func removeISRCs(e *enrichEntry, drop func(code string) bool) {
	e.ISRCs = slices.DeleteFunc(slices.Clone(e.ISRCs), func(c string) bool { return drop(normalizeISRC(c)) })
	if len(e.ISRCs) == 0 {
		e.ISRCs = nil
	}
	if len(e.ISRCLevels) == 0 {
		return
	}
	levels := map[string]string{}
	for c, l := range e.ISRCLevels {
		if slices.Contains(e.ISRCs, c) {
			levels[c] = l
		}
	}
	if len(levels) == 0 {
		levels = nil
	}
	e.ISRCLevels = levels
}

// mergeRecordingISRCs:已有的在前,新的接在后面,去重,最多 recordingISRCMax 个(满了按级别挤换在 recordISRCs 里做)。
func mergeRecordingISRCs(have, add []string) []string {
	out := slices.Clone(have)
	for _, raw := range add {
		c := normalizeISRC(raw)
		if c == "" || slices.Contains(out, c) {
			continue
		}
		if len(out) >= recordingISRCMax {
			break
		}
		out = append(out, c)
	}
	return out
}

// ---- 存量条目补 ISRC ----

// isrcSweepDelay:引擎起来后多久开始补;isrcSweepPace:两次请求之间隔多久;isrcSweepBatch:一次问 Apple 几个歌曲 id。
const (
	isrcSweepDelay = 3 * time.Minute
	isrcSweepPace  = time.Second
	isrcSweepBatch = 100
)

var appleStorefrontInURLRe = regexp.MustCompile(`music\.apple\.com/([a-z]{2})/`)

// appleStorefrontFromURL:Apple Music 链接里的商店(两位小写字母),没有返回空串。
func appleStorefrontFromURL(u string) string {
	if m := appleStorefrontInURLRe.FindStringSubmatch(u); m != nil {
		return m[1]
	}
	return ""
}

// isrc_lookup 记补过哪几支,一支一个记号、空格隔开:
//   - `apple:<商店>:<id>`:按条目上的 Apple 链接问过曲库(链接多是按歌名检索配的,号的级别按 appleSweepISRCLevel 定);
//   - `apple-anchor:<商店>:<id>`:这条链接就是 Apple Music 播放时报的目录锚点,按它问过,取回的号记 player;
//   - `spotify-local:<曲目 id>`:从本机 Spotify 缓存读到过这首的号(player);
//   - `amazon-local:<ASIN>`:从本机 Amazon Music 目录缓存读到过这首的号(player)。
//
// 本机缓存那两支读到了号才记:客户端开播之后才把这首写进缓存,没读到的下次再读。id 换了记号跟着换,按新的再补一次。
// 更早写下的 `spotify:<id>` 那时不记级别,不算 spotify-local 补过,存量按本机缓存重读一遍(18 章决策 63)。
const (
	isrcPartApple       = "apple:"
	isrcPartAppleAnchor = "apple-anchor:"
	isrcPartSpotify     = "spotify-local:"
	isrcPartAmazon      = "amazon-local:"
)

// isrcLookupParts:这条现在该补的几支,按 apple、spotify-local、amazon-local 的顺序;一个 id 都没有时为空。锚点那一支要不要补
// 得在 enrichMu 外核对(isrcResolveAnchors),不在这里。
func isrcLookupParts(e enrichEntry) []string {
	var parts []string
	if p := isrcApplePart(e); p != "" {
		parts = append(parts, p)
	}
	if len(e.SpotifyTrackID) == 22 {
		parts = append(parts, isrcPartSpotify+e.SpotifyTrackID)
	}
	if asin := amazonASINFromTrackURL(e.AmazonURL); asin != "" {
		parts = append(parts, isrcPartAmazon+asin)
	}
	return parts
}

// isrcApplePart / isrcAnchorPart:按这条的 Apple 链接问曲库那一支的记号;链接里没有 id 或商店时为空串。
func isrcApplePart(e enrichEntry) string  { return isrcAppleToken(isrcPartApple, e.AppleURL) }
func isrcAnchorPart(e enrichEntry) string { return isrcAppleToken(isrcPartAppleAnchor, e.AppleURL) }

func isrcAppleToken(prefix, appleURL string) string {
	id, sf := appleCatalogIDFromURL(appleURL), appleStorefrontFromURL(appleURL)
	if id == "" || sf == "" {
		return ""
	}
	return prefix + sf + ":" + id
}

// isrcLookupDone:isrc_lookup 里记着补过的几支。
func isrcLookupDone(e enrichEntry) map[string]bool {
	done := map[string]bool{}
	for _, p := range strings.Fields(e.ISRCLookup) {
		done[p] = true
	}
	return done
}

// isrcLookupWith:原来记着的加上 add,只留跟现在的 id 对得上的几支(isrcLookupParts 的几支,锚点那一支排在 apple 后面),
// 写成 isrc_lookup。
func isrcLookupWith(e enrichEntry, add ...string) string {
	done := isrcLookupDone(e)
	for _, p := range add {
		done[p] = true
	}
	parts := isrcLookupParts(e)
	if a := isrcAnchorPart(e); a != "" {
		parts = slices.Insert(parts, 1, a)
	}
	var out []string
	for _, p := range parts {
		if done[p] {
			out = append(out, p)
		}
	}
	return strings.Join(out, " ")
}

// isrcSweepJob:一条要补的条目。parts 是拿出来那一刻的 isrcLookupParts,写回前核对 id 没变。askApple / readSpotify / readAmazon
// 是这一轮要做的几支;applePlayer:Apple 那一支的 id 就是 Apple Music 播放时报的目录锚点,取回的号记 player、做完记上锚点
// 那一支;anchorCheck:条目在 Apple Music 上放过、锚点那一支还没做过,要在锁外核对链接是不是锚点(isrcResolveAnchors)。
type isrcSweepJob struct {
	key                                        string
	parts                                      []string
	appleID, storefront, spotifyID, amazonASIN string
	durationSecs                               float64
	askApple, readSpotify, readAmazon          bool
	applePlayer, anchorCheck                   bool
}

// isrcSweepJobFor:key 这条这一轮要补哪几支;都补过、也不用核对锚点时 ok 为 false。
func isrcSweepJobFor(key string, e enrichEntry) (isrcSweepJob, bool) {
	parts := isrcLookupParts(e)
	if len(parts) == 0 {
		return isrcSweepJob{}, false
	}
	done := isrcLookupDone(e)
	job := isrcSweepJob{key: key, parts: parts, durationSecs: e.DurationSecs}
	if p := isrcApplePart(e); p != "" {
		job.appleID, job.storefront = appleCatalogIDFromURL(e.AppleURL), appleStorefrontFromURL(e.AppleURL)
		job.askApple = !done[p]
		job.anchorCheck = slices.Contains(e.Players, appleMusicBundleID) && !done[isrcAnchorPart(e)]
	}
	if len(e.SpotifyTrackID) == 22 {
		job.spotifyID = e.SpotifyTrackID
		job.readSpotify = !done[isrcPartSpotify+job.spotifyID]
	}
	if asin := amazonASINFromTrackURL(e.AmazonURL); asin != "" {
		job.amazonASIN = asin
		job.readAmazon = !done[isrcPartAmazon+asin]
	}
	if !job.askApple && !job.readSpotify && !job.readAmazon && !job.anchorCheck {
		return isrcSweepJob{}, false
	}
	return job, true
}

// isrcSweepJobsLocked:有没补过的几支、或者要核对锚点的条目,按 key 排序。调用方持有 enrichMu。
func isrcSweepJobsLocked() []isrcSweepJob {
	var jobs []isrcSweepJob
	for k, e := range enrichCache {
		if job, ok := isrcSweepJobFor(k, e); ok {
			jobs = append(jobs, job)
		}
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].key < jobs[j].key })
	return jobs
}

// isrcResolveAnchors:要核对锚点的几条,链接就是锚点时(anchor 按写法键的歌手、歌名、专辑和时长查,同 appleCatalogLinkFor)
// 改成按锚点问、号记 player;不是锚点、别的几支也都补过的那几条去掉。anchor 要拿 appleCatalogMu,不能持着 enrichMu 调。
func isrcResolveAnchors(jobs []isrcSweepJob, anchor func(artist, title, album string, durationSecs float64) string) []isrcSweepJob {
	var out []isrcSweepJob
	for _, job := range jobs {
		if job.anchorCheck {
			artist, title, album := splitEnrichKey(job.key)
			title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
			if link := anchor(artist, title, album, job.durationSecs); link != "" &&
				appleCatalogIDFromURL(link) == job.appleID && appleStorefrontFromURL(link) == job.storefront {
				job.askApple, job.applePlayer = true, true
			}
			job.anchorCheck = false
		}
		if job.askApple || job.readSpotify || job.readAmazon {
			out = append(out, job)
		}
	}
	return out
}

// appleCatalogSong:按 id 取回来的一首。补 ISRC 用 isrc、durationSecs;按合作署名重核链接(applecreditlinks.go)另用 artist、title。
type appleCatalogSong struct {
	isrc                 string
	durationSecs         float64
	artist, title, album string
	audioLocale          string
	contentRating        string
}

// isrcFromAppleSong:这首报的 ISRC 时长跟播放器报的对得上才认,不认返回空串。没取到这首(这个商店没有)也是空串。
func isrcFromAppleSong(song appleCatalogSong, found bool, durationSecs float64) string {
	if !found || !isrcDurationFits(durationSecs, song.durationSecs) {
		return ""
	}
	return normalizeISRC(song.isrc)
}

// appleSweepISRCLevel:补扫按条目上的 Apple 链接取回的那一轨,号的级别。链接是按歌名检索配上的,可能配到同专辑的另一版
// (合唱重录版配到独唱那一轨):版本词对得上、署名写全了本地点名的合作者或时长几乎相等(appleTrackCreditFits)才算
// verified。key 是条目的键。
func appleSweepISRCLevel(key string, song appleCatalogSong, durationSecs float64) string {
	artist, title, album := splitEnrichKey(key)
	title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
	if versionTagsMismatch(title, album, song.title, song.album) ||
		!appleTrackCreditFits(creditCoArtists(artist, title), song.artist, song.title, song.durationSecs, durationSecs) {
		return isrcLevelSearched
	}
	return isrcLevelVerified
}

// applyISRCSweepResultLocked:把一条的结果写回。条目还在、几支的 id 没变、这一轮做成了(o.settled)、又真有东西要记才写;
// 号合进已有的,isrc_lookup 记上这一轮做完的几支。返回写没写。调用方持有 enrichMu。
func applyISRCSweepResultLocked(job isrcSweepJob, o isrcSweepOutcome) bool {
	cur, ok := enrichCache[job.key]
	if !ok || !o.settled || (len(o.isrcs) == 0 && len(o.done) == 0) || !slices.Equal(isrcLookupParts(cur), job.parts) {
		return false
	}
	recordISRCs(&cur, o.isrcs)
	cur.ISRCLookup = isrcLookupWith(cur, o.done...)
	enrichCache[job.key] = cur
	return true
}

// appleCatalogSongsByID:按歌曲 id 一次取一批(storefront 这个商店的曲库,只要 developer token)。返回 id → 这首;
// ok=false 表示这一批没问成(网络、令牌),调用方别把这批记成补过。
func appleCatalogSongsByID(ctx context.Context, storefront string, ids []string) (map[string]appleCatalogSong, bool) {
	devToken := applemusicEnsureDeveloperToken(ctx)
	if devToken == "" {
		return nil, false
	}
	path := storefront + "/songs?ids=" + strings.Join(ids, ",")
	raw, status, err := applemusicAPIGet(ctx, path, devToken, "")
	if err == nil && (status == http.StatusUnauthorized || status == http.StatusForbidden) {
		// developer token 失效,作废重取一次,同 appleMusicRecordingByISRC。
		applemusicClearDevToken(devToken)
		if newTok := applemusicEnsureDeveloperToken(ctx); newTok != "" && newTok != devToken {
			raw, status, err = applemusicAPIGet(ctx, path, newTok, "")
		}
	}
	if err != nil || status != http.StatusOK {
		return nil, false
	}
	return appleCatalogSongsFrom(raw)
}

// appleCatalogSongsFrom:曲库 songs 应答体 → id → 这首;解不开返回 ok=false。
func appleCatalogSongsFrom(raw []byte) (map[string]appleCatalogSong, bool) {
	var resp struct {
		Data []applemusicSong `json:"data"`
	}
	if json.Unmarshal(raw, &resp) != nil {
		return nil, false
	}
	out := make(map[string]appleCatalogSong, len(resp.Data))
	for _, s := range resp.Data {
		out[s.ID] = appleCatalogSong{isrc: s.Attributes.Isrc, durationSecs: float64(s.Attributes.DurationInMillis) / 1000,
			artist: s.Attributes.ArtistName, title: s.Attributes.Name, album: s.Attributes.AlbumName, audioLocale: s.Attributes.AudioLocale,
			contentRating: s.Attributes.ContentRating}
	}
	return out, true
}

// isrcSweepDeps:补号的几处来路、两批 Apple 请求之间的间隔,单测换成假的。一批没问成等 backoff 再问同一批,同一个商店连续
// tries 次没问成就不再问它(0 当 1 次)。
type isrcSweepDeps struct {
	spotify func(trackIDs []string) map[string]string
	amazon  func(asin string) string
	apple   func(ctx context.Context, storefront string, ids []string) (map[string]appleCatalogSong, bool)
	pace    time.Duration
	backoff time.Duration
	tries   int
}

// isrcSweepLiveDeps:启动后那一轮补扫用。正在放的那首当场补号只问一次(runPlaybackISRCJob),没问成隔 isrcPlaybackRetry 再试。
var isrcSweepLiveDeps = isrcSweepDeps{spotify: spotifyLocalISRCs, amazon: amazonISRCForASIN, apple: appleCatalogSongsByID, pace: isrcSweepPace,
	backoff: catalogSweepBackoff, tries: catalogSweepMaxFailures}

// isrcSweepOutcome:一条做完的样子。isrcs 是取回的号(带级别),done 是做完的几支记号。settled 为 false:要问 Apple 的那一批
// 没问成(网络、令牌)或没轮到,整条不写回、下次再来。
type isrcSweepOutcome struct {
	isrcs   []recordedISRC
	done    []string
	settled bool
}

// runISRCSweepJobs:把几条要补的做完。本机缓存那两支直接读;Apple 那一支按商店分批问(后台请求:只用主机限速里富余的额度,不跟
// 正在播的那首排队,见 hostguard.go 第 3 道),两批之间隔 deps.pace,ctx 取消就停。一批没问成等 deps.backoff 再问同一批,同一个
// 商店连续 deps.tries 次没问成就不再问这个商店(断网、token 失效、一直被限流,同目录名字补扫),剩下的留给下一次。
// 返回每条的结果(按 key)和问了 Apple 几次。要读别的 App 的本机缓存、要联网,不能持着 enrichMu 调。
func runISRCSweepJobs(ctx context.Context, jobs []isrcSweepJob, deps isrcSweepDeps) (map[string]*isrcSweepOutcome, int) {
	out := make(map[string]*isrcSweepOutcome, len(jobs))
	var spotifyIDs []string
	for _, job := range jobs {
		out[job.key] = &isrcSweepOutcome{settled: !job.askApple}
		if job.readSpotify {
			spotifyIDs = append(spotifyIDs, job.spotifyID)
		}
	}
	// Spotify 那几条一次查完:本机库每个账号只扫一遍(见 spotifyLocalISRCs)。
	var spotifyCodes map[string]string
	if len(spotifyIDs) > 0 {
		spotifyCodes = deps.spotify(spotifyIDs)
	}
	byStorefront := map[string][]isrcSweepJob{}
	for _, job := range jobs {
		o := out[job.key]
		if job.readSpotify {
			if code := normalizeISRC(spotifyCodes[job.spotifyID]); code != "" {
				o.isrcs = append(o.isrcs, recordedISRC{code, isrcLevelPlayer})
				o.done = append(o.done, isrcPartSpotify+job.spotifyID)
			}
		}
		if job.readAmazon {
			if code := normalizeISRC(deps.amazon(job.amazonASIN)); code != "" {
				o.isrcs = append(o.isrcs, recordedISRC{code, isrcLevelPlayer})
				o.done = append(o.done, isrcPartAmazon+job.amazonASIN)
			}
		}
		if job.askApple {
			byStorefront[job.storefront] = append(byStorefront[job.storefront], job)
		}
	}
	storefronts := make([]string, 0, len(byStorefront))
	for sf := range byStorefront {
		storefronts = append(storefronts, sf)
	}
	sort.Strings(storefronts)
	requests := 0
	for _, sf := range storefronts {
		group := byStorefront[sf]
		failures := 0
		for start := 0; start < len(group); {
			if requests > 0 {
				wait := deps.pace
				if failures > 0 {
					wait = deps.backoff
				}
				select {
				case <-ctx.Done():
				case <-time.After(wait):
				}
			}
			if ctx.Err() != nil {
				return out, requests
			}
			batch := group[start:min(start+isrcSweepBatch, len(group))]
			ids := make([]string, len(batch))
			for i, job := range batch {
				ids[i] = job.appleID
			}
			songs, ok := deps.apple(withBackgroundOutbound(ctx), sf, ids)
			requests++
			if !ok {
				if failures++; failures >= max(deps.tries, 1) {
					log.Printf("isrc sweep: apple %s failed %d times in a row, leaving %d entries for the next run", sf, failures, len(group)-start)
					break
				}
				continue
			}
			failures = 0
			start += len(batch)
			for _, job := range batch {
				o := out[job.key]
				song, has := songs[job.appleID]
				if code := isrcFromAppleSong(song, has, job.durationSecs); code != "" {
					level := isrcLevelPlayer
					if !job.applePlayer {
						level = appleSweepISRCLevel(job.key, song, job.durationSecs)
					}
					o.isrcs = append(o.isrcs, recordedISRC{code, level})
				}
				o.done = append(o.done, isrcPartApple+job.storefront+":"+job.appleID)
				if job.applePlayer {
					o.done = append(o.done, isrcPartAppleAnchor+job.storefront+":"+job.appleID)
				}
				o.settled = true
			}
		}
	}
	return out, requests
}

// startRecordingISRCSweep:引擎起来后给存量条目补一次 ISRC。本机 Spotify、Amazon 缓存按曲目 id 读(不联网);Apple 链接按商店
// 分批问曲库,时长跟播放器报的对得上才记(没有播放器时长的不记,只标成补过);在 Apple Music 上放过、链接就是它报的目录锚点的,
// 号记 player。没问成、没轮到(引擎在退出)的那几条不写,下次起来再补。
func startRecordingISRCSweep(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(isrcSweepDelay):
	}
	enrichMu.Lock()
	jobs := isrcSweepJobsLocked()
	enrichMu.Unlock()
	// 锚点在 appleCatalogMu 后面,放开 enrichMu 再核对。
	jobs = isrcResolveAnchors(jobs, appleCatalogLinkFor)
	if len(jobs) == 0 {
		return
	}
	outcomes, requests := runISRCSweepJobs(ctx, jobs, isrcSweepLiveDeps)
	updated, withISRC, left := 0, 0, 0
	enrichMu.Lock()
	for _, job := range jobs {
		o := outcomes[job.key]
		if !o.settled {
			left++
			continue
		}
		if !applyISRCSweepResultLocked(job, *o) {
			continue
		}
		updated++
		if len(o.isrcs) > 0 {
			withISRC++
		}
	}
	if updated > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if updated > 0 {
		requestEnrichBackgroundSave()
	}
	log.Printf("isrc sweep: %d of %d entries updated, %d with isrc, %d apple requests, %d left for the next run",
		updated, len(jobs), withISRC, requests, left)
}

// 正在放的那首当场补播放器给的号,不等下次启动的补扫:本机缓存那两支,还有 Apple Music 正在放、条目链接就是它报的目录锚点时
// 问一次曲库。按歌名配的 Apple 链接照旧留给补扫,联网请求量不变(18 章决策 63)。isrcPlaybackInflight:正在做的;
// isrcPlaybackTried:同一条、同一组 id 上次起的时刻,没做成的隔 isrcPlaybackRetry 再试。都受 enrichMu 保护。
var (
	isrcPlaybackInflight = map[string]bool{}
	isrcPlaybackTried    = map[string]time.Time{}
)

const (
	isrcPlaybackRetry    = 10 * time.Minute
	isrcPlaybackTriedCap = 512
)

// playbackISRCJobLocked:正在放的 key 这一拍要不要起一轮补号、补哪几支。e 是这一拍写好的条目,bundleID 是在放的播放器,
// anchorLink 是这首的目录锚点(appleCatalogLinkFor,锁外取好)。返回 ok 时已记成在做,做完由 runPlaybackISRCJob 清掉。
// 调用方持有 enrichMu。
func playbackISRCJobLocked(key string, e enrichEntry, bundleID, anchorLink string, now time.Time) (isrcSweepJob, bool) {
	job, ok := isrcSweepJobFor(key, e)
	if !ok || isrcPlaybackInflight[key] {
		return isrcSweepJob{}, false
	}
	job.askApple, job.anchorCheck = false, false
	if bundleID == appleMusicBundleID && anchorLink != "" && e.AppleURL == anchorLink && job.appleID != "" &&
		!isrcLookupDone(e)[isrcAnchorPart(e)] {
		job.askApple, job.applePlayer = true, true
	}
	if !job.askApple && !job.readSpotify && !job.readAmazon {
		return isrcSweepJob{}, false
	}
	sig := key + "\x1f" + strings.Join(job.parts, " ")
	if at, tried := isrcPlaybackTried[sig]; tried && now.Sub(at) < isrcPlaybackRetry {
		return isrcSweepJob{}, false
	}
	if len(isrcPlaybackTried) >= isrcPlaybackTriedCap {
		clear(isrcPlaybackTried)
	}
	isrcPlaybackTried[sig] = now
	isrcPlaybackInflight[key] = true
	return job, true
}

// runPlaybackISRCJob:在后台把 playbackISRCJobLocked 起的那一轮做完、写回。
func runPlaybackISRCJob(job isrcSweepJob) {
	deps := isrcSweepLiveDeps
	deps.tries = 1
	runPlaybackISRCJobWith(job, deps)
}

// runPlaybackISRCJobWith 同 runPlaybackISRCJob,取号的几支由 deps 给(单测换成不联网的)。写回走带 key 的存盘
// (requestEnrichSaveFor):这一条当场进单条快照和待落盘小文件,App 和一次性子命令不用等整份落盘就读得到这个号。
func runPlaybackISRCJobWith(job isrcSweepJob, deps isrcSweepDeps) {
	outcomes, _ := runISRCSweepJobs(context.Background(), []isrcSweepJob{job}, deps)
	o := outcomes[job.key]
	enrichMu.Lock()
	delete(isrcPlaybackInflight, job.key)
	changed := applyISRCSweepResultLocked(job, *o)
	if changed {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if changed {
		requestEnrichSaveFor(job.key)
		if len(o.isrcs) > 0 {
			log.Printf("isrc: %q recorded %d code(s) while playing (%s)", job.key, len(o.isrcs), strings.Join(o.done, " "))
		}
	}
}
