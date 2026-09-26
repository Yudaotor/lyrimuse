package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"math"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 上送 Last.fm 之前,在它自己的编目里找这首歌对应的条目 —— 找到就按**那个条目的写法**
// 提交(features().LastfmScrobbleArtistMode == scrobbleArtistSmart)。
//
// # 要解决的是什么
//
// 播放器报的标签和 Last.fm 编目里的写法经常不是同一套字,原样提交就落进一个「影子」
// 条目:没有 mbid、没有专辑、时长 0、听众只有你一个。结果不是「记得不够好看」,而是这次
// 收听跟这首歌真正的条目、跟你自己以前的收听全都对不上。实测陶喆《那个女孩》:
//
//	陶喆, 卢广仲 / 那个女孩   → track.getInfo 查无此条(我们自己发过去的那几次造出来的)
//	陶喆 / 那个女孩(简体)    → 126 听众、无 mbid、无编目时长 —— 也是影子
//	陶喆 / 那個女孩(繁体)    → 889 听众、编目时长 267 s —— 这才是这首歌的条目
//
// 同一首歌在这台机器的历史里已经裂成三本账(`陶喆/那個女孩` 8 次、`David Tao/那个女孩
// (feat. 卢广仲)` 2 次、`陶喆, 卢广仲/那个女孩` 1 次)。
//
// # 判定
//
//  0. 曲名结尾带再版 / 分级尾巴(`(Remastered 2014)`、` - 2012 Remaster`、`(Explicit)`)→ 先按去掉尾巴的
//     写法整个判一遍,判出编目条目就发它(lastfmcatalogtail.go)。这一步排在下面的 mbid 前面。
//  1. 按原样查一次 track.getInfo。**有 mbid** → 原样发,永久。mbid 是编目正规身份最硬的
//     信号(影子条目不会有),有它就说明播放器报的写法本身已经是编目认的那条 ——
//     Hall & Oates、`Michael Jackson & Janet Jackson / Scream` 这类正规合体署名靠这一步
//     保住,不会被下面的「听众更多」挪到单人页上去。
//  2. 收集候选:原样、第一位歌手(firstCreditedArtist)、以及该歌手在编目里曲名折到同一个
//     键上的条目(artist.getTopTracks,见 lastfmtoptracks.go)。
//  3. 在**已被编目收录**(catalogued)的候选里取听众最多的一条,拿它复核一次时长;过闸
//     就按它的歌手 + 曲名提交,永久。
//  4. 一条够格的都没有 到 扩展搜索(lastfmcatalogext.go):去合唱各位、MusicBrainz 别名、
//     双语名两半名下找,再按曲名搜全站(只收歌手对得上的)。还找不到才 defer,原样发,
//     过一段时间可重判。
//
// # 为什么这里可以改写歌手名和曲名
//
// Last.fm 官方指南里有一句 "Do not use the corrections returned by the now playing
// service as input for the scrobble request",这个档**刻意不遵守它**。取舍是:原样上送
// 保的是「如实记录播放器报了什么」,代价是这次收听记进一个谁也看不见的影子条目;这里
// 选的是让收听落到真实条目上。完整论证(含当初定「一律原样上送」时的三条依据、以及
// 推翻它的实测)见 docs/features/12 §4。
//
// 安全边界靠的不是「不动」,而是下面这几道:
//
//   - 基础判定的候选**只**来自「原样」「第一位歌手」「该歌手名下曲名折叠等值的条目」三处。
//     扩展搜索用到 track.search,但只收歌手名折叠后跟这首歌的署名 / MB 别名对得上的结果:
//     它按字面串搜全网,会把 `张泽熙 / 那个女孩` 这种同名不同歌带进来(实测),不按歌手
//     过滤就拿它决定一条不可逆的 scrobble,是永久记错。
//   - 曲名折叠只折「同一份录音的写法差异」(繁简/异体/变音/客串署名/再版标记),
//     Live / Remix / 伴奏 这类真版本标记一律保留(lastfmcatalogkey.go)。
//   - 选中的候选要过**时长闸**:两边都有时长且差超过 lastfmCatalogDurationTolerance 就
//     不认 —— 挡的是同一歌手名下同名不同曲。
//   - 原样已有 mbid 就完全不动(第 1 步)。唯一例外是第 0 步的再版 / 分级尾巴:去掉尾巴的写法要自己
//     在编目里判得出来才换。
//
// # 为什么每首歌只判一次、结论永久
//
// 听众数在阈值附近的条目会随时间翻面,同一首歌两次运行发出不同的写法,而 scrobble 落进
// Last.fm 基本删不掉。keep / match 一旦得出就不再重查;唯一允许重查的是 defer(一条够格
// 的候选都没有),那是「暂时判不了」而不是结论。要强制重判,删缓存文件(lastfmCatalogPath)。
//
// # 失败即维持原样、且不缓存
//
// 网络/限流/5xx/坏 JSON/非 "not found" 的 API 错误一律返回原串、不写缓存 —— 改写不可逆,
// 默认行为必须是「维持现状」;而一次偶发失败也不该把这条记录钉死。
//
// # now-playing 与 scrobble 的一致性
//
// 两条路径 + 回填共用同一份缓存,同一首歌的第二次判定必然命中缓存,发的是同一个写法。
// **唯一**可能不一致的情形:now-playing 那次查询失败(维持原样、不缓存),几分钟后
// scrobble 那次查成功并判 match。此时以 scrobble 为准 —— 它是永久记录,now-playing 只是
// 几分钟的瞬时状态;这是刻意的取舍,不是漏洞。
//
// # 预算
//
// 基础判定最多 4 个 GET(原样 / 第一位歌手 / 该歌手曲目表 / 选中候选的复核);扩展搜索
// 每个名字两个 GET、外加一次 track.search,并发发出,另有没缓存时的 MusicBrainz 别名查询。
// 合计 lastfmCatalogBudget;mirrorAsync 在智能档下把总窗口加大同样的量(mirrorTimeout),
// 写入那 8 秒不被挤占。结论永久缓存,同一首歌反复播放不再打网络;曲目表按歌手在进程内
// 复用,同一个歌手连播几首只拉一次。
const (
	lastfmAPIBase = "https://ws.audioscrobbler.com/2.0/"
	// Last.fm 的限流错误码。多以 200 + {"error":29} 返回,认出来就让 Last.fm 读接口进
	// 出站闸的限流窗口(reportEndpointRateLimited),别接着一首一首地撞。
	lastfmErrRateLimited = 29
	// 无 mbid 时,听众数 ≥ 这个值视为编目里的正规条目。实测:影子条目的听众数是
	// 1~180,编目里最冷门的正规合体条目(《Scream Louder (Flyte Tyme Remix)》)是 597 且带 mbid。
	lastfmCatalogListenersMin = 500
	// defer(一条够格的候选都没有)多久之后允许重查。keep / match 永不重查(见头注)。
	lastfmCatalogDeferRecheck = 90 * 24 * time.Hour
	// 候选名字来源不全时判出的 defer(Provisional)多久后重判。开播那一刻判的多半是这种(歌词还没解析完),
	// 打卡在几分钟之后,要赶在那之前让它失效。
	lastfmCatalogProvisionalRecheck = 3 * time.Minute
	// 一次判定没查成时,预算还剩这么多才再试一次(出站闸排满这类一两秒就恢复的情况)。
	lastfmCatalogRetryMinBudget = 8 * time.Second
	lastfmCatalogRetryDelay     = 1500 * time.Millisecond
	// 一次判定的总预算(含扩展搜索)。扩展搜索的 Last.fm 请求并发发出,大头是没缓存时的
	// MusicBrainz 别名(每位歌手约 2.2 s,最多 lastfmCatalogExtMaxAliasCredits 位)。
	lastfmCatalogBudget = 25 * time.Second
	// 单个 track.getInfo 的上限。collector 直连(不走系统代理)实测 p50 0.4 s,4 s 够用;
	// 查不动时本来就退回「按原样提交」,宁可判不出也不能把提交本身拖死。
	lastfmCatalogProbeTimeout = 4 * time.Second
	// 编目条目与播放器报的时长差超过这个值就不认。整秒级编目时长与播放器的毫秒值天然
	// 有零点几秒的差(实测 267 s vs 267.333 s),不同发行版之间还会再差几秒;放到 8 秒是
	// 为了不误伤同一份录音,挡的是「同一歌手名下同名但完全是另一首」那种量级的差距。
	lastfmCatalogDurationTolerance = 8.0
	// 曲目表里同名条目最多取几条来复核。同一首歌在编目里的不同写法通常只有一两条,
	// 取太多只会为越来越冷门的写法多打 track.getInfo。
	lastfmCatalogMaxTitleMatches = 3
	// 判定口径版本。判据变了之后旧结论必须重判 —— 老结论是按「只看歌手」那套判出来的,
	// 直接沿用就等于新口径永远生效不了(keep/match 永不重查)。加载时版本不符一律丢弃。
	lastfmCatalogDecisionVersion = 2
)

// lastfmCatalogPath 由 main.go / backfillcli.go 跟其它落盘路径一起设置;空 = 不落盘(单测)。
var lastfmCatalogPath string

type catalogVerdict string

const (
	// 原样就是编目里的条目(有 mbid,或它本身就是听众最多的那条):原样发,永久。
	verdictKeep catalogVerdict = "keep"
	// 编目里有听众更多的同一首歌:按那条的歌手 + 曲名发,永久。
	verdictMatch catalogVerdict = "match"
	// 一条够格的候选都没有:暂维持原样,lastfmCatalogDeferRecheck 之后重查。
	verdictDefer catalogVerdict = "defer"
)

// lastfmCatalogProbe 是一次 track.getInfo 的判据留痕 —— 写进缓存文件是为了让人能事后
// 核对「当时为什么这么判」,不参与之后的判断(结论一旦得出就按 Verdict 走)。
type lastfmCatalogProbe struct {
	// 200 且不是 "Track not found"。
	Found      bool   `json:"found"`
	MBID       string `json:"mbid,omitempty"`
	Listeners  int    `json:"listeners"`
	DurationMS int    `json:"duration_ms"`
	// Artist / Name 是应答里那条条目自己的写法。autocorrect=1 时它可以跟查询串不同
	// (查别名回的是正规条目那条)。基础判定不读它;扩展搜索按它提交(见 extCandidates)。
	Artist string `json:"artist,omitempty"`
	Name   string `json:"name,omitempty"`
}

// catalogued 判「这是编目里的正规条目」。三个信号任一成立即可 —— 都是影子条目不会有的
// 东西:mbid 来自 MusicBrainz 关联,时长来自编目元数据(scrobble 带的 duration 参数不会
// 写进编目),听众数够多说明不是一两个人的私有写法。
func (p lastfmCatalogProbe) catalogued() bool {
	return p.Found && (p.MBID != "" || p.Listeners >= lastfmCatalogListenersMin || p.DurationMS > 0)
}

func (p lastfmCatalogProbe) summary() string {
	if !p.Found {
		return "not found"
	}
	return fmt.Sprintf("mbid=%q listeners=%d duration_ms=%d", p.MBID, p.Listeners, p.DurationMS)
}

// durationFits 判编目时长跟播放器报的时长对不对得上。任一侧拿不到时长就不构成反对
// 意见(放行)—— 编目条目本来就常常没有时长,把「不知道」当成「不匹配」会让匹配几乎
// 永远不成立。
func (p lastfmCatalogProbe) durationFits(durationSecs float64) bool {
	if p.DurationMS <= 0 || durationSecs <= 0 {
		return true
	}
	return math.Abs(float64(p.DurationMS)/1000-durationSecs) <= lastfmCatalogDurationTolerance
}

type lastfmCatalogDecision struct {
	Verdict catalogVerdict `json:"verdict"`
	// Artist / Track 是判定后应该提交的写法(keep/defer = 原样)。
	Artist string `json:"artist"`
	Track  string `json:"track,omitempty"`
	TS     int64  `json:"ts"`
	// V 是判定口径版本,见 lastfmCatalogDecisionVersion。
	V int `json:"v"`
	// Scope 是判定时允许改写哪些字段(matchScope.id())。设置改了作用域就变了,
	// 旧结论对不上、必须重判 —— 否则「自定义只改曲名」会继续沿用「智能」时算出的结论。
	Scope string `json:"scope,omitempty"`
	// 判据留痕,只写不读。
	Own    *lastfmCatalogProbe `json:"own,omitempty"`
	Chosen *lastfmCatalogProbe `json:"chosen,omitempty"`
	// Via 是扩展搜索选中的候选从哪一路来的(name / top / search,兜底档带 +fallback),只写不读。
	Via string `json:"via,omitempty"`
	// Ext 是得出这条结论时的扩展判定口径(lastfmCatalogExtVersion)。只对 defer 有意义:
	// 旧口径下的 defer 没跑过扩展搜索,要重判(见 lookup)。
	Ext int `json:"ext,omitempty"`
	// Provisional:这条 defer 是在候选名字来源不全时判的(见 decideExtended),只在
	// lastfmCatalogProvisionalRecheck 之内有效。
	Provisional bool `json:"provisional,omitempty"`
	// Tail 是得出这条结论时的尾巴判定口径(lastfmCatalogTailVersion)。曲名带尾巴、口径更旧的要重判(见 lookup)。
	Tail int `json:"tail,omitempty"`
}

// lastfmCatalogMatcher 按上面的判据决定一条 scrobble 该用哪个歌手名 + 曲名。
// 缓存键是 "歌手串\n曲名" —— 收录情况是**按曲目**的,同一个歌手串在不同歌上完全可能
// 一个是正规条目、一个是影子条目,不能只按歌手名缓存。
type lastfmCatalogMatcher struct {
	apiKey  string // 只读用的 api_key:track.getInfo / artist.getTopTracks 不需要签名/session key
	baseURL string // 可注入,单测用;空则用 Last.fm 正式端点
	hc      *http.Client

	mu    sync.Mutex
	cache map[string]lastfmCatalogDecision
	// 歌手 → 编目曲目表,进程内复用,不落盘(见 topTracks)。
	tops map[string][]lastfmTopTrack
}

func newLastfmCatalogMatcher(apiKey string) *lastfmCatalogMatcher {
	if apiKey == "" {
		return nil
	}
	c := &lastfmCatalogMatcher{
		apiKey: apiKey,
		hc:     &http.Client{Timeout: lastfmCatalogProbeTimeout},
		cache:  map[string]lastfmCatalogDecision{},
		tops:   map[string][]lastfmTopTrack{},
	}
	c.load()
	return c
}

// matchScope 说明这次判定允许改写哪些字段(「自定义」档可以只放开一个)。
//
// 不许改的那个字段必须**与原样一致**才采纳候选(见 candidates)。否则「只改曲名」会拼出
// `陶喆, 卢广仲 / 那個女孩` 这种编目里根本不存在的组合 —— 又落回影子条目,比不改还糟。
type matchScope struct {
	artist, track bool
}

// id 是缓存里的作用域留痕。同一首歌在不同作用域下结论不同,换了设置必须重判。
func (s matchScope) id() string {
	switch {
	case s.artist && s.track:
		return "at"
	case s.artist:
		return "a"
	case s.track:
		return "t"
	}
	return ""
}

// resolve 返回这条提交应该用的歌手名和曲名,以及**有没有匹配到编目条目**(第三个返回值)。
// 任何一步不确定都返回原串 —— 改写不可逆,默认行为必须是「维持现状」。nil 接收者
// (没配只读 api_key)整体退化成原样返回。
func (c *lastfmCatalogMatcher) resolve(ctx context.Context, artist, track string, durationSecs float64, scope matchScope) (string, string, bool) {
	if c == nil || (!scope.artist && !scope.track) {
		return artist, track, false
	}
	trimmedArtist, trimmedTrack := strings.TrimSpace(artist), strings.TrimSpace(track)
	if trimmedArtist == "" || trimmedTrack == "" {
		return artist, track, false
	}

	key := trimmedArtist + "\n" + trimmedTrack
	if d, ok := c.lookup(key, time.Now(), scope); ok {
		return d.Artist, orDefault(d.Track, trimmedTrack), d.Verdict == verdictMatch
	}

	ctx, cancel := context.WithTimeout(ctx, lastfmCatalogBudget)
	defer cancel()
	d, err := c.decide(ctx, trimmedArtist, trimmedTrack, durationSecs, scope)
	if err != nil && catalogRetryable(err) && budgetLeft(ctx) >= lastfmCatalogRetryMinBudget {
		// 再试一次:出站闸排满、单个请求超时这类一两秒就恢复的失败,不值得为它按原样发出去。
		// Last.fm 明确回了限流 / 参数错误 / 坏数据的不重试(限流时最该做的就是停手)。
		select {
		case <-time.After(lastfmCatalogRetryDelay):
			d, err = c.decide(ctx, trimmedArtist, trimmedTrack, durationSecs, scope)
		case <-ctx.Done():
		}
	}
	if err != nil {
		// 查不动(限流/网络/Last.fm 抽风)时不缓存也不改写:下次再判,别把一次偶发失败
		// 变成一个永久的错误决定。
		log.Printf("lastfm catalog: lookup %q / %q failed: %v (keeping as-is, not cached)", trimmedArtist, trimmedTrack, err)
		return artist, track, false
	}
	c.store(key, d)
	switch d.Verdict {
	case verdictMatch:
		log.Printf("lastfm catalog: %q / %q -> %q / %q (own: %s; chosen: %s; via %s)",
			trimmedArtist, trimmedTrack, d.Artist, d.Track, d.Own.summary(), d.Chosen.summary(), orDefault(d.Via, "base"))
	case verdictKeep:
		log.Printf("lastfm catalog: keep %q / %q (%s)", trimmedArtist, trimmedTrack, d.Own.summary())
	default:
		recheck := lastfmCatalogDeferRecheck
		if d.Provisional {
			recheck = lastfmCatalogProvisionalRecheck
		}
		log.Printf("lastfm catalog: defer %q / %q (nothing catalogued: %s; recheck after %s)",
			trimmedArtist, trimmedTrack, d.Own.summary(), recheck)
	}
	return d.Artist, orDefault(d.Track, trimmedTrack), d.Verdict == verdictMatch
}

func orDefault(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

// decide 跑完整套判定。返回 error 表示「没查成」——调用方维持原样且不缓存。
func (c *lastfmCatalogMatcher) decide(ctx context.Context, artist, track string, durationSecs float64, scope matchScope) (lastfmCatalogDecision, error) {
	own, err := c.probe(ctx, artist, track)
	if err != nil {
		return lastfmCatalogDecision{}, err
	}
	keep := lastfmCatalogDecision{Verdict: verdictKeep, Artist: artist, Track: track, Own: &own, Scope: scope.id()}
	// 曲名带再版 / 分级尾巴:先按去掉尾巴的写法判(lastfmcatalogtail.go),要排在 mbid 那一步前面。
	if d, done, err := c.decideReleaseTail(ctx, artist, track, durationSecs, scope, own); err != nil || done {
		return d, err
	}
	// 原样已经是编目认的那条:一个字节都不动。这一步保住正规合体署名不被「听众更多」
	// 挪到单人页上去。
	if own.MBID != "" {
		return keep, nil
	}
	// MV 标题(parseVideoTitle):按拆出来的「演唱者 / 歌名」整个判一遍,时长当未知(MV 比录音室版长)。
	// 判出编目条目就改写成它;判不出就原样发 —— 拿视频标题本身再跑一遍扩展搜索没有意义。翻唱 / 特辑不拆。
	if v := parseVideoTitle(artist, track); v.Kind == videoTitleMusicVideo && scope.track {
		va := v.Artist
		if !scope.artist {
			va = artist
		}
		if va != artist || v.Song != track {
			vd, err := c.decide(ctx, va, v.Song, 0, scope)
			if err != nil {
				return lastfmCatalogDecision{}, err
			}
			switch vd.Verdict {
			case verdictKeep, verdictMatch:
				chosen := vd.Chosen
				if vd.Verdict == verdictKeep {
					chosen = vd.Own
				}
				return lastfmCatalogDecision{
					Verdict: verdictMatch, Artist: vd.Artist, Track: orDefault(vd.Track, v.Song),
					Own: &own, Chosen: chosen, Scope: scope.id(), Via: strings.TrimSuffix("video+"+vd.Via, "+"),
				}, nil
			}
			return lastfmCatalogDecision{Verdict: verdictDefer, Artist: artist, Track: track, Own: &own,
				Scope: scope.id(), Provisional: vd.Provisional}, nil
		}
	}

	cands, err := c.candidates(ctx, artist, track, own, scope)
	if err != nil {
		return lastfmCatalogDecision{}, err
	}
	// 按听众降序逐个复核,第一个过时长闸的就是结论。排序稳定:同听众时保持收集顺序
	// (原样 → 第一位歌手 → 曲目表自带的降序),免得同分候选每次判出不同的写法。
	sortCandidatesByListeners(cands)
	for _, cand := range cands {
		if !cand.probe.catalogued() {
			continue
		}
		p, err := c.confirm(ctx, cand)
		if err != nil {
			return lastfmCatalogDecision{}, err
		}
		if !p.catalogued() || !p.durationFits(durationSecs) {
			continue
		}
		if cand.artist == artist && cand.track == track {
			return keep, nil
		}
		return lastfmCatalogDecision{
			Verdict: verdictMatch, Artist: cand.artist, Track: cand.track,
			Own: &own, Chosen: &p, Scope: scope.id(),
		}, nil
	}
	return c.decideExtended(ctx, artist, track, durationSecs, scope, own, cands)
}

// catalogCandidate 是一个「可能是这首歌在编目里的条目」的写法。probe 是已知的收录信息;
// needsConfirm 表示它来自曲目表(没有时长),选中前要再打一次 track.getInfo 才能过时长闸。
type catalogCandidate struct {
	artist, track string
	probe         lastfmCatalogProbe
	needsConfirm  bool
}

// candidates 收集全部候选。**只**有这三处来源,理由见头注。
//
// scope 不许改的字段会在这里就把候选筛掉:不许改歌手时,候选的歌手必须跟原样折叠后相等
// (曲名同理)。**原样那条永远留着** —— 它是「什么都没匹配上」时的落点,不参与筛选。
func (c *lastfmCatalogMatcher) candidates(ctx context.Context, artist, track string, own lastfmCatalogProbe, scope matchScope) ([]catalogCandidate, error) {
	out := []catalogCandidate{{artist: artist, track: track, probe: own}}
	artistKey, trackKey := lastfmCatalogArtistKey(artist), lastfmCatalogTitleKey(track)
	allowed := func(a, t string) bool {
		if !scope.artist && lastfmCatalogArtistKey(a) != artistKey {
			return false
		}
		if !scope.track && lastfmCatalogTitleKey(t) != trackKey {
			return false
		}
		return true
	}

	searchArtist := artist
	// firstCreditedArtist 切不开时返回原串本身(含 "周杰伦、" 这种结尾带分隔符的单人名、
	// 以及 K/DA 这种头部不像名字的 `/`)。
	if primary := firstCreditedArtist(artist); primary != "" && primary != artist {
		// 查它仍然有意义(它是曲目表的检索起点),但只在允许改歌手时才当候选。
		p, err := c.probe(ctx, primary, track)
		if err != nil {
			return nil, err
		}
		if allowed(primary, track) {
			out = append(out, catalogCandidate{artist: primary, track: track, probe: p})
		}
		searchArtist = primary
	}

	rows, err := c.topTracks(ctx, searchArtist)
	if err != nil {
		return nil, err
	}
	for _, m := range catalogTitleMatches(rows, track, lastfmCatalogMaxTitleMatches) {
		if containsCandidate(out, m.Artist, m.Name) || !allowed(m.Artist, m.Name) {
			continue
		}
		out = append(out, catalogCandidate{
			artist: m.Artist, track: m.Name,
			probe:        lastfmCatalogProbe{Found: true, MBID: m.MBID, Listeners: m.Listeners},
			needsConfirm: true,
		})
	}
	return out, nil
}

func containsCandidate(cands []catalogCandidate, artist, track string) bool {
	for _, c := range cands {
		if c.artist == artist && c.track == track {
			return true
		}
	}
	return false
}

// confirm 把「曲目表给的那点信息」补成完整的收录信息(主要是时长)。已经查过的候选
// 直接返回,不重复打网络。
func (c *lastfmCatalogMatcher) confirm(ctx context.Context, cand catalogCandidate) (lastfmCatalogProbe, error) {
	if !cand.needsConfirm {
		return cand.probe, nil
	}
	return c.probe(ctx, cand.artist, cand.track)
}

// sortCandidatesByListeners 按听众降序排,同听众保持原顺序(插入排序,候选只有几条)。
func sortCandidatesByListeners(cands []catalogCandidate) {
	for i := 1; i < len(cands); i++ {
		for j := i; j > 0 && cands[j].probe.Listeners > cands[j-1].probe.Listeners; j-- {
			cands[j], cands[j-1] = cands[j-1], cands[j]
		}
	}
}

// probe 查一次「歌手 + 曲名」在 Last.fm 编目里的收录情况。返回 error 表示**没查成**(网络、
// 限流、5xx、坏 JSON、非 not-found 的 API 错误),调用方必须当"不知道"处理;"Track not found"
// 是确定的答案(Found=false),不是错误。
func (c *lastfmCatalogMatcher) probe(ctx context.Context, artist, track string) (lastfmCatalogProbe, error) {
	q := neturl.Values{}
	q.Set("method", "track.getInfo")
	q.Set("api_key", c.apiKey)
	q.Set("format", "json")
	q.Set("artist", artist)
	q.Set("track", track)
	// autocorrect=1 让 Last.fm 先套一遍它自己的纠错表再查 —— 纠错后能命中正规条目的就不该
	// 被我们再改写一次(提交时 Last.fm 会套同一张表,落点一样)。
	// 它**不管繁简**:实测简体串纠不到繁体条目,那一层归 lastfmcatalogkey.go。
	q.Set("autocorrect", "1")

	base := c.baseURL
	if base == "" {
		base = lastfmAPIBase
	}
	ctx, cancel := context.WithTimeout(ctx, lastfmCatalogProbeTimeout)
	defer cancel()
	// 不用 q.Encode():Last.fm 的 GET 端点会对 query value 多解一次码,含加号的歌名走标准
	// 编码必然 error 6 —— 而这里 error 6 的语义是"没收录 → 可以改写",查错了就是把正规条目
	// 判成影子(真实事故,见 lastfmGetQuery)。
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+lastfmGetQuery(q), nil)
	if err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(c.hc, req)
	if err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("get track info: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		Track struct {
			Name      string `json:"name"`
			MBID      string `json:"mbid"`
			Listeners string `json:"listeners"`
			Duration  string `json:"duration"`
			Artist    struct {
				Name string `json:"name"`
			} `json:"artist"`
		} `json:"track"`
		Error   int    `json:"error"`
		Message string `json:"message"`
	}
	// 先解 body 再看状态码:Last.fm 的 API 错误多以 200 + {"error":N} 返回,偶尔也带 4xx;
	// 两种形态下 "Track not found" 都是确定答案,其余非 200 才是"没查成"。
	decodeErr := json.NewDecoder(resp.Body).Decode(&body)
	if body.Error == lastfmErrRateLimited {
		reportEndpointRateLimited(req.URL, "")
	}
	if body.Error == 6 && strings.Contains(strings.ToLower(body.Message), "not found") {
		return lastfmCatalogProbe{Found: false}, nil
	}
	if resp.StatusCode != http.StatusOK {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo status %d", resp.StatusCode)
	}
	if decodeErr != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("decode track.getInfo: %w", decodeErr)
	}
	if body.Error != 0 {
		// 其它 error 6(参数问题)、29(限流)、8/11/16(服务端)…都不是"没收录",不能当结论用。
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo error %d: %s", body.Error, body.Message)
	}
	p := lastfmCatalogProbe{Found: true, MBID: body.Track.MBID,
		Artist: strings.TrimSpace(body.Track.Artist.Name), Name: strings.TrimSpace(body.Track.Name)}
	// 听众数/时长:字段缺失按 0(Last.fm 对影子条目就是这么给的);字段**在但解析不出**
	// 说明应答形态跟预期不符,信号不可信 —— 当"没查成",不缓存。这两个数字是判"收录"的
	// 依据,读错了会让一条影子看着像正规条目,而改写不可逆,宁可这一次判不出。
	if p.Listeners, err = atoiOrZero(body.Track.Listeners); err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo listeners %q: %w", body.Track.Listeners, err)
	}
	if p.DurationMS, err = atoiOrZero(body.Track.Duration); err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo duration %q: %w", body.Track.Duration, err)
	}
	return p, nil
}

// atoiOrZero:空串 → 0,nil;其余必须是整数。
func atoiOrZero(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	return strconv.Atoi(s)
}

// lookup 只认当前口径版本、且作用域相同的三个 verdict;defer 到期、旧口径、换过设置、
// 老格式/损坏条目都当未命中重查。没跑过当前扩展搜索的 defer(Ext 旧)也重查 ——
// keep / match 不受 Ext 影响,永不重查。
func (c *lastfmCatalogMatcher) lookup(key string, now time.Time, scope matchScope) (lastfmCatalogDecision, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d, ok := c.cache[key]
	if !ok || d.V != lastfmCatalogDecisionVersion || d.Scope != scope.id() {
		return d, false
	}
	if d.Tail < lastfmCatalogTailVersion && catalogKeyHasReleaseTail(key) {
		return d, false
	}
	switch d.Verdict {
	case verdictKeep, verdictMatch:
		return d, true
	case verdictDefer:
		recheck := lastfmCatalogDeferRecheck
		if d.Provisional {
			recheck = lastfmCatalogProvisionalRecheck
		}
		return d, d.Ext >= lastfmCatalogExtVersion && now.Sub(time.Unix(d.TS, 0)) <= recheck
	default:
		return d, false
	}
}

func (c *lastfmCatalogMatcher) store(key string, d lastfmCatalogDecision) {
	d.TS = time.Now().Unix()
	d.V = lastfmCatalogDecisionVersion
	d.Ext = lastfmCatalogExtVersion
	d.Tail = lastfmCatalogTailVersion
	c.mu.Lock()
	c.cache[key] = d
	snapshot := make(map[string]lastfmCatalogDecision, len(c.cache))
	for k, v := range c.cache {
		snapshot[k] = v
	}
	c.mu.Unlock()
	c.save(snapshot)
}

func (c *lastfmCatalogMatcher) load() {
	if lastfmCatalogPath == "" {
		return
	}
	data, err := os.ReadFile(lastfmCatalogPath)
	if err != nil {
		return // 首次运行没有这个文件是正常的
	}
	var m map[string]lastfmCatalogDecision
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("lastfm catalog: cache unreadable, starting empty: %v", err)
		return
	}
	// 旧口径的结论不认、丢掉重判 —— 它们是按「只看歌手、只查播放器报的那个曲名」判出来的,
	// keep/match 又永不重查,沿用就等于新口径对这些歌永远不生效。
	for k, d := range m {
		if d.V != lastfmCatalogDecisionVersion {
			delete(m, k)
			continue
		}
		switch d.Verdict {
		case verdictKeep, verdictMatch, verdictDefer:
		default:
			delete(m, k)
		}
	}
	c.mu.Lock()
	c.cache = m
	c.mu.Unlock()
}

func (c *lastfmCatalogMatcher) save(snapshot map[string]lastfmCatalogDecision) {
	if lastfmCatalogPath == "" {
		return
	}
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		log.Printf("lastfm catalog: marshal cache: %v", err)
		return
	}
	// 先写临时文件再 rename,跟 saveEnrichCache 同一个理由(半截文件不能被下次读到);
	// 常驻 collector 和 backfill 子命令都会写这份:writeFileAtomic 的临时文件名是随机的。
	if err := writeFileAtomic(lastfmCatalogPath, data); err != nil {
		slog.Error("lastfm catalog: write cache failed", "err", err)
	}
}

// catalogRetryable:本地出站闸排队排满(errHostRateLimited,不含 429 窗口 / 冷却那种 errHostGuarded)
// 或单个请求超时。
func catalogRetryable(err error) bool {
	return errors.Is(err, errHostRateLimited) || errors.Is(err, context.DeadlineExceeded)
}

// catalogDurationUnknownKey:ctx 上标记「这一条的时长是视频的长度」(Music.app 的 music video、
// YouTube Music 页面认出的 MV,见 snapshot.notAudioMedia)。编目匹配按未知时长判 —— MV 比录音室版长,
// 拿它比时长会把正规条目挡掉(实测 JISOO《FLOWER》174 s 的条目被 MV 时长挡下);发给 Last.fm 的
// duration 参数照报真实长度。
type catalogDurationUnknownKey struct{}

func withCatalogDurationUnknown(ctx context.Context, notAudio bool) context.Context {
	if !notAudio {
		return ctx
	}
	return context.WithValue(ctx, catalogDurationUnknownKey{}, true)
}

func catalogDurationUnknown(ctx context.Context) bool {
	v, _ := ctx.Value(catalogDurationUnknownKey{}).(bool)
	return v
}

// budgetLeft 是 ctx 离截止还剩多久;没有截止时当作充足。
func budgetLeft(ctx context.Context) time.Duration {
	if dl, ok := ctx.Deadline(); ok {
		return time.Until(dl)
	}
	return lastfmCatalogBudget
}
