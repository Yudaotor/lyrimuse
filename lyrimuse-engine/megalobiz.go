package main

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	neturl "net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	// megalobizHourlyBudget:Megalobiz 不带 key 时每个 IP 每天 1000 次,摊到每小时约 41 次。后台(待播队列的预解析)用完这一小时的
	// 就不问它,正在放的那首照问;超了对方回 429,走熔断和后台暂停。登记在描述符的 HourlyBudget。
	megalobizHourlyBudget = 40
	// megalobizDayQuotaReserve:Megalobiz 每天剩到这么多时只留给前台。登记在描述符的 DayQuotaReserve。
	megalobizDayQuotaReserve = 100
)

// megalobizLyric 是 Megalobiz 这一路:公开接口搜索 → 按元数据重新打分排序 → 按名次逐条取词,第一份带时间轴的就用。
// 接口是官方开放的 `api.megalobiz.com/api/public/v1`(开发者说明 https://megalobiz.com/developers),不要账号、不签名,回 JSON。
// 只有逐行(用户手打上传的 LRC,`lines[].time_ms` + `text`),没有逐字、译文、罗马音、封面、专辑。
//
// 条款(见 09 章决策 386):
//   - 不许整库镜像、批量下载,只查用户实际在放的歌:只在正在放的那首、待播队列、手动搜索 / 重新匹配、设置页测试时问,
//     别的轮次(全量扫库、补空扫描、专辑预取、导入清单、开发命令行)一律不问(lyricSourceAllowedForRound,白名单)。
//   - 请求带写明 App 名和联系网址的 User-Agent(megalobizUserAgent)。
//   - 不带 key 时每个 IP 每分钟 30 次、每天 1000 次:令牌桶按每分钟不超过 30 次配(描述符的 HostRates),后台的小时额度见
//     megalobizHourlyBudget,429 走歌词源熔断和后台暂停;应答头报的每日剩余次数见 sourcedayquota.go(剩得少只给前台、
//     用完停到重置)。这几样跟手动搜索的子进程共用一份记账。同一个请求地址的答复存 megalobizAnswerTTL,别名轮不重发。
//   - 显示它的歌词时链回这首在 megalobiz.com 上的歌词页:页地址(`url`)随候选带到条目的 lyrics_source_url,App 在来源处做成链接。
//
// 曲库是用户上传的,写法不齐:约三成条目歌手栏是空的,其中一部分把歌手写进歌名(「Dorofeeva - Кохаю, але не зовсім」),还有挂着下载站
// 标记的(「[SPOTDOWNLOADER.COM] Обійми」)。歌名由 megalobizSongTitle 整理;歌手栏空、也拆不出歌手的条目,只在歌名归一后相同、
// 候选歌名没有本地没有的括号段、时长差不超过 megalobizNoArtistMaxDiffSecs 时才收。时间轴准度不齐(实测热门歌多数在半秒内,个别整体晚好几秒):
// 正文共识只比文字,整体错开的照样拿共识分,所以另跟正文共识的那几家逐行对一次时间轴,错开的重扣(applyMegalobizTimelinePenalty);
// 没有别家可比时不扣,也不按源写死偏移(09 章决策 294)。
type megalobizResult struct {
	lyrics, title, artist string
	// url:这份歌词在 megalobiz.com 上的歌词页,只收 megalobiz.com 自己的 https 地址(megalobizPageURL)。
	url string
	// durationSecs:这份歌词登记的时长(秒,带小数),0 = 没给。
	durationSecs float64
}

const (
	megalobizAPIBase = "https://api.megalobiz.com/api/public/v1"
	// megalobizSearchLimit:一次搜索取几条。同名的翻唱、Remix、别人传的另一份常排在后面几位,10 条够把原版留在里面。
	megalobizSearchLimit = 10
	// megalobizMaxCandidatesToFetch:过了闸之后最多取几份词。条目全是带时间轴的 LRC,第一份取到就用,
	// 不像 VIBE 那样并发取前几名:那只会多耗每天的请求额度。第二份只在第一份没取到(404、不是有效 LRC)时取。
	megalobizMaxCandidatesToFetch = 2
	// megalobizScoreDurationTolerance 跟别的源的时长闸(match.go 的 0.25)取同一个值。
	megalobizScoreDurationTolerance = 0.25
	// megalobizMaxDurationDiffSecs:两边时长都知道时差多少秒就不是同一版,同 VIBE。
	megalobizMaxDurationDiffSecs = 8.0
	// megalobizNoArtistMaxDiffSecs:歌手栏空、也拆不出歌手的条目,时长差不超过这么多才收。Megalobiz 的时长取自上传者的音频、
	// 带小数,同一版跟播放器报的差不过一秒上下;只凭歌名认人,时长要卡得比有歌手的严。
	megalobizNoArtistMaxDiffSecs = 2.0
)

var (
	megalobizMu    sync.Mutex
	megalobizCache = map[string]megalobizResult{}
	// megalobizAnswers:请求地址 → 对方的答复(搜索结果含空的、取到的词、答了「没有」的 400 / 404),megalobizAnswerTTL 内同一地址不再发。
	// 别名轮换了歌手再走一遍检索词时,「只按歌名」那条跟首轮一字不差,靠它不重发;没问成的(429、5xx、网络)不存。
	megalobizAnswers = map[string]megalobizAnswer{}
	megalobizNow     = time.Now
)

type megalobizAnswer struct {
	at  time.Time
	val any
	err error
}

const (
	megalobizAnswerTTL = 30 * time.Minute
	// megalobizAnswerMax:存的地址数上限,满了先丢过期的,还满就整份清掉。
	megalobizAnswerMax = 512
)

// megalobizGetCached:按地址取一份答复,megalobizAnswerTTL 内同一地址直接用存下的。
func megalobizGetCached[T any](ctx context.Context, u string) (T, error) {
	megalobizMu.Lock()
	if a, ok := megalobizAnswers[u]; ok && megalobizNow().Sub(a.at) < megalobizAnswerTTL {
		megalobizMu.Unlock()
		v, _ := a.val.(T)
		return v, a.err
	}
	megalobizMu.Unlock()
	var out T
	err := megalobizGetJSON(ctx, u, &out)
	if err != nil && !megalobizAnsweredNone(err) {
		return out, err
	}
	megalobizMu.Lock()
	defer megalobizMu.Unlock()
	now := megalobizNow()
	if len(megalobizAnswers) >= megalobizAnswerMax {
		for k, a := range megalobizAnswers {
			if now.Sub(a.at) >= megalobizAnswerTTL {
				delete(megalobizAnswers, k)
			}
		}
		if len(megalobizAnswers) >= megalobizAnswerMax {
			megalobizAnswers = map[string]megalobizAnswer{}
		}
	}
	megalobizAnswers[u] = megalobizAnswer{at: now, val: out, err: err}
	return out, err
}

// megalobizProvider 把 megalobizLyric 接到 LyricProvider 上。结果的源名由调度填(runLyricProvider);只在用户在听、在找的
// 轮次里问它由描述符的 Rounds 定,调度按它判,这里不看轮次。
type megalobizProvider struct{ desc *ProviderDescriptor }

func (p megalobizProvider) Descriptor() *ProviderDescriptor { return p.desc }

func (p megalobizProvider) Resolve(ctx context.Context, q ProviderQuery, _ RoundEnv) SourceResult {
	r := megalobizLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)
	return SourceResult{lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, srcDur: r.durationSecs, sourceURL: r.url}
}

func megalobizLyric(ctx context.Context, artist, title, album string, durationSecs float64) megalobizResult {
	if title == "" {
		return megalobizResult{}
	}
	// 带上时长:选候选要过时长闸,同名的不同剪辑不能共用一份结果。
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(math.Round(durationSecs)))
	megalobizMu.Lock()
	if v, ok := megalobizCache[key]; ok {
		megalobizMu.Unlock()
		return v
	}
	megalobizMu.Unlock()

	ctx, sub := withLyricSubFetch(ctx)
	r := resolveMegalobizLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" && sub.complete(ctx) {
		megalobizMu.Lock()
		megalobizCache[key] = r
		megalobizMu.Unlock()
	}
	return r
}

// megalobizSearchItem 是搜索结果里用得上的字段。
type megalobizSearchItem struct {
	ID       int64   `json:"id"`
	Title    string  `json:"title"`
	Artist   string  `json:"artist"`
	Duration float64 `json:"duration"`
	URL      string  `json:"url"`
}

type megalobizLine struct {
	TimeMs int    `json:"time_ms"`
	Text   string `json:"text"`
}

// megalobizLRCBody 是 /lrc/{id} 的应答。
type megalobizLRCBody struct {
	ID       int64           `json:"id"`
	Title    string          `json:"title"`
	Artist   string          `json:"artist"`
	Duration float64         `json:"duration"`
	URL      string          `json:"url"`
	Lines    []megalobizLine `json:"lines"`
	LRC      string          `json:"lrc"`
}

// megalobizStatusError:Megalobiz 回了非 200。404(没有这份词)、400(参数不合它的意)是答了「没有」,不算没问成;
// 429(超了每分钟 / 每天的次数)和 5xx 是没问成。
type megalobizStatusError int

func (e megalobizStatusError) Error() string { return fmt.Sprintf("status %d", int(e)) }

func megalobizAnsweredNone(err error) bool {
	var se megalobizStatusError
	return errors.As(err, &se) && (se == http.StatusNotFound || se == http.StatusBadRequest)
}

// megalobizUserAgent:条款要求带上写明 App 名和联系网址的 User-Agent,联系网址用仓库主页。
func megalobizUserAgent() string {
	return clientName + "/" + clientVersion + " (+https://github.com/Yudaotor/lyrimuse)"
}

func megalobizGetJSON(ctx context.Context, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", megalobizUserAgent())
	resp, err := doHTTPTracked(lyricHTTPClient(megalobizHTTPTimeout), req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	noteSourceDayQuota(lyricSourceMegalobiz, resp.StatusCode, resp.Header, time.Now())
	if resp.StatusCode != http.StatusOK {
		return megalobizStatusError(resp.StatusCode)
	}
	return decodeLyricSourceJSON(req, resp, lyricSourceResponseMaxBytes, out)
}

// megalobizSearchURL 拼搜索地址。artist 为空时不带这个参数(只按歌名搜);时长按整秒给,0 不给。纯函数,便于单测。
func megalobizSearchURL(title, artist string, durationSecs float64) string {
	q := neturl.Values{}
	q.Set("title", title)
	if artist != "" {
		q.Set("artist", artist)
	}
	if d := int(math.Round(durationSecs)); d > 0 {
		q.Set("duration", strconv.Itoa(d))
	}
	q.Set("limit", strconv.Itoa(megalobizSearchLimit))
	return megalobizAPIBase + "/search?" + q.Encode()
}

// megalobizSearchBody 是 /search 的应答。
type megalobizSearchBody struct {
	Results []megalobizSearchItem `json:"results"`
}

func megalobizSearch(ctx context.Context, title, artist string, durationSecs float64) ([]megalobizSearchItem, error) {
	out, err := megalobizGetCached[megalobizSearchBody](ctx, megalobizSearchURL(title, artist, durationSecs))
	if err != nil {
		return nil, err
	}
	return out.Results, nil
}

func megalobizFetchLRC(ctx context.Context, id int64) (megalobizLRCBody, error) {
	return megalobizGetCached[megalobizLRCBody](ctx, fmt.Sprintf("%s/lrc/%d", megalobizAPIBase, id))
}

// megalobizIDTagRe:LRC 开头的标签行([ar:]、[ti:]、[length:]、[re:Megalobiz]、[by:]…)。
var megalobizIDTagRe = regexp.MustCompile(`^\[[A-Za-z]+:[^\]]*\]$`)

// megalobizBuildLRC 把 lines 拼成 LRC。空句写成只有时间戳的行(一句唱完、后面是间奏的标记);上传者加的装饰行
// (「====」「~」这类没有字母数字的)同空句处理;时间倒退的句子丢掉。
// lines 是空的时退回应答里的 lrc 全文,去掉开头的标签行,装饰行同样只留时间戳。纯函数,便于单测。
func megalobizBuildLRC(body megalobizLRCBody) string {
	if len(body.Lines) == 0 {
		var b strings.Builder
		for _, l := range strings.Split(strings.ReplaceAll(body.LRC, "\r\n", "\n"), "\n") {
			l = strings.TrimSpace(l)
			if l == "" || megalobizIDTagRe.MatchString(l) {
				continue
			}
			if text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(l, "")); text != "" && megalobizAlnumCount(text) == 0 {
				l = strings.TrimSpace(strings.TrimSuffix(l, text))
			}
			b.WriteString(l + "\n")
		}
		return b.String()
	}
	var b strings.Builder
	last := -1
	for _, l := range body.Lines {
		if l.TimeMs < 0 || l.TimeMs < last {
			continue
		}
		last = l.TimeMs
		text := strings.TrimSpace(l.Text)
		if megalobizAlnumCount(text) == 0 {
			text = ""
		}
		b.WriteString(formatLRCStamp(l.TimeMs) + text + "\n")
	}
	return b.String()
}

// megalobizMarkupRe:有人把别的编辑器的分段标记(「{00:02.65,A]」)原样粘进了正文。
var megalobizMarkupRe = regexp.MustCompile(`\{\d+:\d+(?:\.\d+)?,`)

// megalobizMarkupHeavy:带这种标记的句子超过五分之一,整份当坏的不用,换下一份。纯函数,便于单测。
func megalobizMarkupHeavy(lrc string) bool {
	total, marked := 0, 0
	for _, l := range strings.Split(lrc, "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		total++
		if megalobizMarkupRe.MatchString(l) {
			marked++
		}
	}
	return total > 0 && marked*5 > total
}

// megalobizPageURL:只收 megalobiz.com 自己的 https 歌词页(默认端口),别的地址(含 http、别的域名、别的端口)一律当没给。
// App 侧 LyricsSourceLink.url 同一口径,两边一起改。纯函数,便于单测。
func megalobizPageURL(raw string) string {
	u, err := neturl.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return ""
	}
	if h := strings.ToLower(u.Hostname()); h != "megalobiz.com" && h != "www.megalobiz.com" {
		return ""
	}
	return u.String()
}

// megalobizSiteTagRe:歌名开头挂的下载站标记(「[SPOTDOWNLOADER.COM] 」),方括号里带点号的才算。
var megalobizSiteTagRe = regexp.MustCompile(`^\s*\[[^\]]*\.[^\]]*\]\s*`)

// megalobizSongTitle 整理一条搜索结果的歌名和歌手:去掉开头的下载站标记;歌手栏空、歌名原样对不上本地歌名、又写成「歌手 - 歌名」
// 的,拆成两半(只拆第一个「 - 」,拆出来的歌名对得上本地歌名才拆)。纯函数,便于单测。
func megalobizSongTitle(rawTitle, rawArtist, localTitle string) (title, artist string) {
	title = strings.TrimSpace(megalobizSiteTagRe.ReplaceAllString(rawTitle, ""))
	artist = strings.TrimSpace(rawArtist)
	if artist != "" || lyricTitleAccepted(title, localTitle) {
		return title, artist
	}
	left, right, ok := strings.Cut(title, " - ")
	if !ok {
		return title, artist
	}
	left, right = strings.TrimSpace(left), strings.TrimSpace(right)
	if left == "" || right == "" || !lyricTitleAccepted(right, localTitle) {
		return title, artist
	}
	return right, left
}

// megalobizCandidateScore 给一条搜索结果打分,越高越像本地这首;负数 = 淘汰。Megalobiz 没有专辑,歌手对不上时没有三角验证可走。
// 纯函数,便于单测。
func megalobizCandidateScore(item megalobizSearchItem, artist, title, album string, durationSecs float64) int {
	name, credit := megalobizSongTitle(item.Title, item.Artist, title)
	if !lyricTitleAccepted(name, title) {
		return -1
	}
	if versionTagsMismatch(title, album, name, "") {
		return -1
	}
	score := 100
	switch {
	case credit != "":
		if !lyricSourceArtistMatches(credit, artist) {
			return -1
		}
		score += 30
	default:
		// 只凭歌名认人:歌名去掉括号后归一要完全相同,候选歌名带着本地没有的括号段(「(From The Lion King Soundtrack)」)不收,
		// 时长两边都要知道、而且卡得更严。
		if normLoose(stripParens(name)) != normLoose(stripParens(title)) ||
			(stripParens(name) != name && normLoose(name) != normLoose(title)) ||
			durationSecs <= 0 || item.Duration <= 0 || math.Abs(item.Duration-durationSecs) > megalobizNoArtistMaxDiffSecs {
			return -1
		}
	}
	if durationSecs > 0 && item.Duration > 0 {
		diff := math.Abs(item.Duration-durationSecs) / durationSecs
		if diff > megalobizScoreDurationTolerance || math.Abs(item.Duration-durationSecs) > megalobizMaxDurationDiffSecs {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// megalobizQuery 是一次搜索的两个参数。
type megalobizQuery struct{ title, artist string }

// megalobizQueries:按顺序要搜的检索词(「清理过的歌名 + 第一位歌手」、只按歌名、原样的歌名),去掉空的和重复的。
// 不带歌手、歌名里字母数字不到 megalobizMinQueryAlnum 个的不搜:接口回 400 还扣额度。纯函数,便于单测。
func megalobizQueries(artist, title string) []megalobizQuery {
	qTitle := strings.TrimSpace(lyricQueryTitle(title))
	raw := strings.TrimSpace(title)
	var out []megalobizQuery
	for _, q := range []megalobizQuery{{qTitle, strings.TrimSpace(firstCreditedArtist(artist))}, {qTitle, ""}, {raw, ""}} {
		if q.title == "" || slices.Contains(out, q) {
			continue
		}
		if q.artist == "" && megalobizAlnumCount(q.title) < megalobizMinQueryAlnum {
			continue
		}
		out = append(out, q)
	}
	return out
}

// megalobizMinQueryAlnum:接口要求检索词里至少有这么多个字母或数字(「at least 2 letters or digits」)。
const megalobizMinQueryAlnum = 2

func megalobizAlnumCount(s string) int {
	n := 0
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			n++
		}
	}
	return n
}

// resolveMegalobizLyric:先按「歌名 + 第一位歌手」搜,一条都没过闸再只按歌名搜(歌手在 Megalobiz 上常是另一种写法或干脆空着),
// 还没有且歌名被清理过时再按原样的歌名搜一次;过闸的按分数排,逐条取词,第一份是有效 LRC 的就用。
func resolveMegalobizLyric(ctx context.Context, artist, title, album string, durationSecs float64) megalobizResult {
	type scoredItem struct {
		item  megalobizSearchItem
		score int
	}
	queries := megalobizQueries(artist, title)
	var candidates []scoredItem
	for qi, q := range queries {
		items, err := megalobizSearch(ctx, q.title, q.artist, durationSecs)
		if err != nil {
			if megalobizAnsweredNone(err) && qi < len(queries)-1 {
				continue
			}
			return megalobizResult{}
		}
		for _, it := range items {
			if it.ID <= 0 {
				continue
			}
			if s := megalobizCandidateScore(it, artist, title, album, durationSecs); s >= 0 && !slices.ContainsFunc(candidates, func(c scoredItem) bool { return c.item.ID == it.ID }) {
				candidates = append(candidates, scoredItem{it, s})
			}
		}
		if len(candidates) > 0 {
			break
		}
	}
	if len(candidates) == 0 {
		return megalobizResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > megalobizMaxCandidatesToFetch {
		candidates = candidates[:megalobizMaxCandidatesToFetch]
	}
	for _, c := range candidates {
		body, err := megalobizFetchLRC(ctx, c.item.ID)
		if err != nil {
			if !megalobizAnsweredNone(err) {
				noteLyricSubFetchFailure(ctx)
				return megalobizResult{}
			}
			continue
		}
		lrc := megalobizBuildLRC(body)
		if !isTimedLRC(lrc) || megalobizMarkupHeavy(lrc) {
			continue
		}
		name, credit := megalobizSongTitle(c.item.Title, c.item.Artist, title)
		page := megalobizPageURL(body.URL)
		if page == "" {
			page = megalobizPageURL(c.item.URL)
		}
		d := c.item.Duration
		if body.Duration > 0 {
			d = body.Duration
		}
		return megalobizResult{lyrics: lrc, title: name, artist: credit, url: page, durationSecs: d}
	}
	return megalobizResult{}
}

// megalobizTimelineShiftMs:Megalobiz 那份跟正文共识的另一家逐行对齐后,中位偏移到这么多就算整体错开。取值依据见 09 章决策 387。
const megalobizTimelineShiftMs = 1500

// applyMegalobizTimelinePenalty:Megalobiz 的时间轴是上传者手打的,个别整体晚好几秒,而正文共识只比文字、照样给分。
// 它跟正文共识的另一家(ConsensusPeers 里的信源家族)逐行对齐:有一家对得上就不动;对不上的里至少一家整体平移
// megalobizTimelineShiftMs 以上、方向一致时,扣 timelineOffsetPenalty 分、记一条 scoreTermTimelineOffset。
// 没有别家可比(只有它一家、共识的几家都是纯文本或配不上行)时不扣。只看 Megalobiz,别的源的分不动。
// 调用位置紧跟 applyTimelineOffsetPenalty,两条流水线都要调;那一步已经扣过它的就不再扣。
func applyMegalobizTimelinePenalty(results []scoredLyricCandidateResult) {
	for i := range results {
		r := &results[i]
		if r.Source != lyricSourceMegalobiz || r.Score < 0 || r.Lyrics == "" || len(r.ConsensusPeers) == 0 ||
			scoreTermPoints(r.ScoreTerms, scoreTermTimelineOffset) != 0 {
			continue
		}
		families := map[string]bool{}
		for _, p := range r.ConsensusPeers {
			families[lyricSourceConsensusFamily(p)] = true
		}
		own := displayedTimeline(r.Lyrics, r.LyricsYRC)
		later, earlier := 0, 0
		aligned := false
		for j, peer := range results {
			if j == i || peer.Score < 0 || peer.Lyrics == "" || !families[lyricSourceConsensusFamily(peer.Source)] {
				continue
			}
			switch classifyTimelines(own, displayedTimeline(peer.Lyrics, peer.LyricsYRC), megalobizTimelineShiftMs) {
			case timelineAligned:
				aligned = true
			case timelineShiftedLater:
				later++
			case timelineShiftedEarlier:
				earlier++
			}
		}
		if aligned || later+earlier == 0 || (later > 0 && earlier > 0) {
			continue
		}
		r.Score = max(r.Score-timelineOffsetPenalty, 1)
		r.ScoreTerms = append(r.ScoreTerms, scoreTerm{Kind: scoreTermTimelineOffset, Points: -timelineOffsetPenalty})
	}
}
