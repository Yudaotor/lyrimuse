package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strings"
	"time"
)

// 每日/每周/每月/年度听歌报告可以自选用哪个账号的数据(Last.fm 或 ListenBrainz)：默认取已经
// 配置好的那个，两个都配了就用 Last.fm，都没配就提示需要先配置。这个文件是各 cadence
// 共用的部分：统一的统计结果形状、按数据源分派的取数路径、统一的推送文案拼装、以及默认
// 数据源的判定逻辑。daily.go/weekly.go/calendardigest.go 各自只保留"什么时候算一个新周期
// 已经收官、该不该检查"这部分跟周期长度强相关、没法共用的逻辑。

const (
	digestSourceLastfm       = "lastfm"
	digestSourceListenBrainz = "listenbrainz"
)

// defaultDigestTopN：推送里 Top 歌手/专辑/歌曲默认各列几条，Bark 锁屏预览要能读完，不铺开全量。用户在推送提醒页
// 「每类列出」改(features.json 的 digest_top_n,1～10),四档、两种数据源共用。见 15 章决策 72。
//
// 条数调大以后正文不截断(推送正文从来不截):按本机真实榜单估,每类 10 条时正文约 1.1～1.5 KB,企业微信文本消息
// 上限 2048 字节、Discord 2000 字,名字都很长的极端情况可能超过,超了那次推送按平台拒收记失败。
const (
	defaultDigestTopN = 3
	minDigestTopN     = 1
	maxDigestTopN     = 10
)

// resolveDigestTopN:缺失按 defaultDigestTopN,越界夹回 1～10。
func resolveDigestTopN(n *int) int {
	if n == nil {
		return defaultDigestTopN
	}
	return min(max(*n, minDigestTopN), maxDigestTopN)
}

// digestTopN:这一轮各类列几条。features() 是单测里直接拼的 featureFlags 时这一项是零值,按缺省算。
func digestTopN() int {
	if n := features().DigestTopN; n != 0 {
		return n
	}
	return defaultDigestTopN
}

// digestTally 是某首歌/某张专辑/某个歌手在统计区间内被听了几次。
type digestTally struct {
	Name  string `json:"name"`
	Sub   string `json:"sub,omitempty"` // 歌曲/专辑:Name=歌名或专辑名,Sub=歌手；歌手:Name=歌手名,Sub 留空
	Count int    `json:"count"`
}

// digestStats 是一段时间范围内的统计结果，跟数据源无关——两条取数路径
// (lastfmDigestStats/listenbrainzDigestStats)分别产出同一种形状。
//
// 整份原样存进推送记录(notifyLogEntry.Digest),重发时照它重新排版,所以带 json 标签。
type digestStats struct {
	TotalPlays      int   `json:"total_plays"`
	TotalDurationMs int64 `json:"total_duration_ms,omitempty"` // 0 表示"这个数据源给不出时长"，
	// 推送文案据此判断要不要显示"累计时长"这一句，不是当成"今天真的听了 0 秒"。
	TopTracks  []digestTally `json:"top_tracks,omitempty"`
	TopArtists []digestTally `json:"top_artists,omitempty"`
	TopAlbums  []digestTally `json:"top_albums,omitempty"`
	// Truncated:逐条翻收听记录翻到上限还没翻完,上面的数字只是最近那一部分。推送里会写明。
	Truncated bool `json:"truncated,omitempty"`

	// 下面是报告在三份榜单之外多写的几样和排版要用的,由 digestextras.go 补;取不到就留零值,那一句不写。
	Source string `json:"source,omitempty"` // digestSourceLastfm / digestSourceListenBrainz
	From   string `json:"from,omitempty"`   // 这一期的起止日期(本地,含两头,YYYY-MM-DD)
	To     string `json:"to,omitempty"`
	// PrevPlays:上一期的播放次数,PrevLabel 是正文里怎么叫它(「前一周」「9 月」「2025 年」)。0 = 不比(日报、取不到、上一期没听)。
	PrevPlays int    `json:"prev_plays,omitempty"`
	PrevLabel string `json:"prev_label,omitempty"`
	// NewArtists:这一期之前在这个账号上一次都没听过的歌手有几位;NewArtistNames 是其中这期听得最多的前几位。
	NewArtists     int      `json:"new_artists,omitempty"`
	NewArtistNames []string `json:"new_artist_names,omitempty"`
	// DurationEstimated:TotalDurationMs 是估出来的:Last.fm 源按曲目时长估(lastfmEstimateDuration),ListenBrainz 源
	// 有一部分收听没带时长、按带了的平均补(digestStatsFromListens)。
	DurationEstimated bool   `json:"duration_estimated,omitempty"`
	CoverURL          string `json:"cover_url,omitempty"` // 这一期头号专辑的封面,公网地址
	Link              string `json:"link,omitempty"`      // 点开去看这一期完整榜单的地址

	// 取数时顺手留下的原始数据,补上面几样时用,不进推送记录。
	chartTracks, chartArtists []lastfmChartEntry
	listens                   []lbListenEntry
}

// digestEnv 是后台定时任务(四档听歌报告、Top 歌手榜)这一轮要用的配置快照。这些任务在单独的
// goroutine 里跑(runDigestsAsync),而 p.cfg / p.lb.alerter 会被主循环的配置热重读换掉,所以
// 开跑前在主循环上取一份,任务里只读这份,不读 p.cfg / p.lb。
type digestEnv struct {
	ctx     context.Context
	cfg     *config
	alerter *alerter
	lbRoot  string
}

func (p *poller) digestEnvSnapshot() digestEnv {
	env := digestEnv{ctx: p.ctx, cfg: p.cfg}
	if p.lb != nil {
		env.alerter, env.lbRoot = p.lb.alerter, p.lb.apiRoot()
	}
	return env
}

// runDigestsAsync 由主循环每一拍调用:上一轮还没跑完就跳过,否则开一个 goroutine 依次跑各任务。
// 它们要联网取数、推送,网络差时一轮能到几十秒甚至几分钟,不能占住主循环(主循环停住期间换歌、
// 暂停、拖进度都察觉不到,网页状态也不推)。各任务的 lastCheckedAt 与状态文件只在这个
// goroutine 里读写,digestBusy 保证同一时刻只有一轮。
func (p *poller) runDigestsAsync(now time.Time) {
	if !p.digestBusy.CompareAndSwap(false, true) {
		return
	}
	env := p.digestEnvSnapshot()
	go func() {
		defer p.digestBusy.Store(false)
		p.runDigests(now, env)
	}()
}

func (p *poller) runDigests(now time.Time, env digestEnv) {
	if localZoneChanged() {
		return // 换了时区,引擎重启后按新时区算(digestschedule.go)
	}
	refreshArtistSourceAliases(now) // 下面几份报告的歌手归并要用,见 artistsourcealias.go
	p.weeklyDigest(now, env)
	p.dailyDigest(now, env)
	p.monthlyDigest(now, env)
	p.yearlyDigest(now, env)
	p.topArtistsDigest(now, env)
	p.platformPagesDigest(now, env)
	p.artistIdentityRecheckDigest(now, env)
	p.artistRegionsDigest(now, env)
}

// digestCheckDue 判各份报告「距上次检查是否已满 interval」(last 为零值 = 这个进程里还没查过，算到期)。
// 按墙钟比：主循环的 now 来自 time.Now()，带 Go 的单调读数，darwin 上它取 mach_absolute_time，
// 系统睡眠期间不走(本机实测开机 14 小时 18 分、pmset 记的睡眠合计 68 分 52 秒，单调读数正好少
// 1 小时 8 分)。两头都带单调读数时 Sub 用的是单调读数，睡前刚查过的话，醒来还得再等满 interval 的
// 清醒时间。调用方记 lastCheckedAt 时也存 now.Round(0)(只留墙钟)。见 15 章决策 69。
func digestCheckDue(now, last time.Time, interval time.Duration) bool {
	return last.IsZero() || now.Round(0).Sub(last.Round(0)) >= interval
}

// resolveDigestSource 判定"这次检查该用哪个数据源"：preference 非空且明确指定就用它；
// 否则按"两个都配了→Last.fm，只配了一个→用那个，都没配→返回空字符串"解析出默认值。
// 空字符串意味着两个账号都没配，调用方应该跳过这次检查(等同于既有 weeklyDigest/
// dailyDigest 顶部那些"缺前提就 return"的判断，不是新增行为，只是把"该用哪个源"这一步
// 单独抽出来)。Swift 侧 AccountLinkingTab 的 Picker 默认值展示用的是同一套规则(各自
// 独立实现,因为跑在不同进程/语言里,但判定规则本身写在这条注释里，两边改动务必同步)。
func resolveDigestSource(preference string, lastfmConfigured, listenBrainzConfigured bool) string {
	switch preference {
	case digestSourceLastfm:
		if lastfmConfigured {
			return digestSourceLastfm
		}
	case digestSourceListenBrainz:
		if listenBrainzConfigured {
			return digestSourceListenBrainz
		}
	}
	// preference 为空、或者显式指定的那个源其实没配好(比如曾经配过、后来又清空了账号)——
	// 都落到这条自动判定：两个都配了优先 Last.fm(它自带聚合/排行，不用自己再聚合一遍)。
	switch {
	case lastfmConfigured:
		return digestSourceLastfm
	case listenBrainzConfigured:
		return digestSourceListenBrainz
	default:
		return ""
	}
}

// lastfmDigestStats 用 Last.fm 的周榜接口(weekly.go 里的 lastfmWeeklyTopTracks/
// lastfmWeeklyTopArtists/lastfmWeeklyTopAlbums)取 [from,to) 区间的统计——这几个函数名字叫
// "weekly"，但参数本来就是任意 from/to，一天、一个月、一年的范围一样能用。没有时长数据
// (TotalDurationMs 留 0)。
func lastfmDigestStats(ctx context.Context, user, apiKey string, from, to int64) (digestStats, error) {
	tracks, err := lastfmWeeklyTopTracks(ctx, user, apiKey, from, to)
	if err != nil {
		return digestStats{}, err
	}
	artists, err := lastfmWeeklyTopArtists(ctx, user, apiKey, from, to)
	if err != nil {
		return digestStats{}, err
	}
	albums, err := lastfmWeeklyTopAlbums(ctx, user, apiKey, from, to)
	if err != nil {
		return digestStats{}, err
	}
	stats := digestStatsFromCharts(tracks, artists, albums)
	stats.chartTracks, stats.chartArtists = tracks, artists
	return stats, nil
}

// digestStatsFromCharts 把三份已按次数降序排好的榜单拼成统计结果。
//
// 播放次数取曲目榜合计和歌手榜合计里**大的那个**，不能只加曲目榜：Last.fm 的曲目榜一次
// 最多返回 1000 条，月、年这种长区间会被截断；歌手条目少得多，一般是全量。见 15 章。
func digestStatsFromCharts(tracks, artists, albums []lastfmChartEntry) digestStats {
	var stats digestStats
	trackSum, artistSum := 0, 0
	for _, t := range tracks {
		trackSum += t.PlayCount
	}
	for _, a := range artists {
		artistSum += a.PlayCount
	}
	stats.TotalPlays = max(trackSum, artistSum)
	topN := digestTopN()
	for i, t := range tracks {
		if i >= topN {
			break
		}
		stats.TopTracks = append(stats.TopTracks, digestTally{Name: t.Name, Sub: t.Artist, Count: t.PlayCount})
	}
	stats.TopArtists = digestTopArtists(artists)
	for _, a := range albums {
		if len(stats.TopAlbums) >= topN {
			break
		}
		if strings.TrimSpace(a.Name) == "" {
			continue
		}
		stats.TopAlbums = append(stats.TopAlbums, digestTally{Name: a.Name, Sub: a.Artist, Count: a.PlayCount})
	}
	return stats
}

// digestTopArtists 把 Last.fm 歌手榜条目**先归并、再取 Top N**。
//
// 抽成独立的纯函数而不是内联在 lastfmDigestStats 里,是为了让"这条路径确实做了归并"
// 这件事可测 —— lastfmDigestStats 自己要打网络,测不了;内联的话把归并那一行删掉,
// 单测(只测 mergeAliasedArtists 本身)照样全绿,等于没守住。
//
// 归并跟歌手榜(topartists.go)走**同一套**,别自己再造一份 —— 通盘梳理时
// 发现 digest 原来完全不归并,于是同一个二进制里同一个人在推送里是两个、在榜单里是
// 一个(实测这台机器 389 个歌手写法里有 1 例:"张震岳"/"张震嶽")。
//
// 用 mergeAliasedArtists 而不是自己按名字键 group:它内部除了名字键还看 mbid(并查集,
// 允许链式传递),口径跟榜单一致;名字键、展示名、mbid 三样都**只读本地缓存、一个网络请求都
// 不发**——月、年的歌手榜有几百位,不能逐个联网。
//
// 顺序依赖:取前 N 之前必须已经按次数降序排好。mergeAliasedArtistsNamed 结尾有
// sort.SliceStable 保证了这一点(合并会让次数相加、名次变动,不重排就会取错)。
//
// 已知取舍:合并之后名次和次数会跟**历史推送**对不上。接受 ——
// 那是口径修正带来的一次性台阶,比"两处口径永久不一致"好。
func digestTopArtists(artists []lastfmChartEntry) []digestTally {
	merged := mergeAliasedArtists(artists)
	topN := digestTopN()
	var out []digestTally
	for i, a := range merged {
		if i >= topN {
			break
		}
		out = append(out, digestTally{Name: a.Name, Count: a.PlayCount})
	}
	return out
}

// lbListenEntry 是一条 ListenBrainz 收听记录，只留这个功能要用的字段。
type lbListenEntry struct {
	Title, Artist, Release string // Release 可能为空(播放器没报专辑)，不计入专辑榜
	ListenedAt             int64
	DurationMs             int64  // 0 = 这条记录没带时长(比如 iPhone 桥接来的 playing_now 转发)，不计入总时长
	CoverURL               string // ListenBrainz 给这条匹配到的专辑封面(Cover Art Archive),没匹配上为空
}

// lbListensMaxPages:逐条翻收听记录的页数上限(一页 100 条)。一周听上千首并不罕见(本机
// 8 月一个月 3,000 多条),上限按一周 5,000 条留足;这是保险丝,碰到了就在推送里写明不完整。
const lbListensMaxPages = 50

// lbListensInRange 拉该用户 [fromUnix,toUnix) 区间内的收听记录，按 max_ts 游标翻页
// (ListenBrainz 一页最多 100 条，一周的量级可能不止一页，日报一般用不到翻页但同一份
// 实现两边共用，不用维护两份"翻不翻页"的取数逻辑)。翻到 lbListensMaxPages 页还没翻完时
// truncated=true。
func lbListensInRange(ctx context.Context, root, user string, fromUnix, toUnix int64) (all []lbListenEntry, truncated bool, err error) {
	cursor := toUnix
	for page := 0; page < lbListensMaxPages; page++ {
		entries, oldestInPage, err := lbListensBefore(ctx, root, user, fromUnix, cursor)
		if err != nil {
			return nil, false, err
		}
		all = append(all, entries...)
		if len(entries) < 100 || oldestInPage <= fromUnix {
			return all, false, nil // 这一页不满 100 条(已经翻到底)，或者已经翻到区间起点之前，没有更早的了
		}
		cursor = oldestInPage // 下一页从"这一页最早一条"往更早继续翻
	}
	return all, true, nil
}

// lbListensBefore 拉一页(至多100条) listened_at 落在 (fromUnix, maxTs] 的记录，返回
// 这一页里最早一条的时间戳(供翻页游标用；没有记录时返回 0)。
func lbListensBefore(ctx context.Context, root, user string, fromUnix, maxTs int64) ([]lbListenEntry, int64, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	// 用户名进路径段要转义:LB 用户名允许的字符里有路径里有含义的(空格、#、?),原样拼会拉到别的地址或整个 404。
	url := fmt.Sprintf("%s/1/user/%s/listens?count=100&min_ts=%d&max_ts=%d", root, neturl.PathEscape(user), fromUnix, maxTs)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, err
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, 0, fmt.Errorf("listenbrainz status %d", resp.StatusCode)
	}
	var out struct {
		Payload struct {
			Listens []struct {
				ListenedAt    int64 `json:"listened_at"`
				TrackMetadata struct {
					TrackName      string `json:"track_name"`
					ArtistName     string `json:"artist_name"`
					ReleaseName    string `json:"release_name"`
					AdditionalInfo struct {
						DurationMs int64 `json:"duration_ms"`
					} `json:"additional_info"`
					MBIDMapping struct {
						CAAReleaseMBID string `json:"caa_release_mbid"`
						CAAID          int64  `json:"caa_id"`
					} `json:"mbid_mapping"`
				} `json:"track_metadata"`
			} `json:"listens"`
		} `json:"payload"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, 0, err
	}
	entries := make([]lbListenEntry, 0, len(out.Payload.Listens))
	oldest := int64(0)
	for _, l := range out.Payload.Listens {
		entries = append(entries, lbListenEntry{
			Title: l.TrackMetadata.TrackName, Artist: l.TrackMetadata.ArtistName, Release: l.TrackMetadata.ReleaseName,
			ListenedAt: l.ListenedAt, DurationMs: l.TrackMetadata.AdditionalInfo.DurationMs,
			CoverURL: caaCoverURL(l.TrackMetadata.MBIDMapping.CAAReleaseMBID, l.TrackMetadata.MBIDMapping.CAAID),
		})
		if oldest == 0 || l.ListenedAt < oldest {
			oldest = l.ListenedAt
		}
	}
	return entries, oldest, nil
}

// listenbrainzDigestStats 取 [fromUnix,toUnix) 区间的 ListenBrainz 收听记录并在本地
// 聚合——不像 Last.fm 那边有现成的服务端聚合接口，这里自己按(歌名,歌手)/(专辑,歌手)/歌手
// 分别计数、按次数排序取 Top N，同时能顺带算出总时长(Last.fm 那条路径给不出这个)。
// 逐条翻页有上限(见 lbListensInRange)，只用于日报、周报；月报、年报走 lbStatsDigest。
func listenbrainzDigestStats(ctx context.Context, root, user string, from, to int64) (digestStats, error) {
	listens, truncated, err := lbListensInRange(ctx, root, user, from, to)
	if err != nil {
		return digestStats{}, err
	}
	stats := digestStatsFromListens(listens)
	stats.Truncated = truncated
	stats.listens = listens
	return stats, nil
}

// digestStatsFromListens 是 listenbrainzDigestStats 的聚合部分，纯函数。
func digestStatsFromListens(listens []lbListenEntry) digestStats {
	var stats digestStats
	stats.TotalPlays = len(listens)
	trackIndex, artistIndex, albumIndex := map[string]int{}, map[string]int{}, map[string]int{}
	var trackTallies, artistTallies, albumTallies []digestTally
	var knownMs int64
	knownPlays := 0
	for _, l := range listens {
		if l.DurationMs > 0 {
			knownMs += l.DurationMs
			knownPlays++
		}
		tk := l.Title + "|" + l.Artist
		if idx, ok := trackIndex[tk]; ok {
			trackTallies[idx].Count++
		} else {
			trackIndex[tk] = len(trackTallies)
			trackTallies = append(trackTallies, digestTally{Name: l.Title, Sub: l.Artist, Count: 1})
		}
		// 按归并键计数,不按原串 —— 跟上面 Last.fm 那条路径和歌手榜同一个口径
		// (一并统一,否则用户换个数据源"同一个人被算成两个"这个坑还在)。
		// 这里只能用 artistMergeNameKeyCached 这个按名字算键的版本,不能套 mergeAliasedArtists:
		// 那个吃的是 lastfmChartEntry(带 mbid),而 LB 的收听记录里没有 mbid,并查集
		// 的第二个信号本来就用不上,按名字键分桶已经是这条路径能做到的全部。
		ak := artistMergeNameKeyCached(l.Artist)
		if idx, ok := artistIndex[ak]; ok {
			artistTallies[idx].Count++
		} else {
			artistIndex[ak] = len(artistTallies)
			// 展示名用 artistMergeDisplayNameCached:只把已知罗马字艺名换成中文本名,**不**做
			// 繁简/大小写折叠 —— 那两步只是判同一个人时内部用的,不该篡改用户库里原本
			// 的书写(理由见 artistMergeDisplayName 的注释)。
			artistTallies = append(artistTallies, digestTally{Name: artistMergeDisplayNameCached(l.Artist), Count: 1})
		}
		if release := strings.TrimSpace(l.Release); release != "" {
			// 同一张专辑、同一个人的不同写法算一张(歌手部分用同一个归并键)。
			rk := release + "|" + ak
			if idx, ok := albumIndex[rk]; ok {
				albumTallies[idx].Count++
			} else {
				albumIndex[rk] = len(albumTallies)
				albumTallies = append(albumTallies, digestTally{Name: release, Sub: artistMergeDisplayNameCached(l.Artist), Count: 1})
			}
		}
	}
	stats.TopTracks = topTallies(trackTallies)
	stats.TopArtists = topTallies(artistTallies)
	stats.TopAlbums = topTallies(albumTallies)
	// 时长:没带时长的收听(iPhone 桥接来的等)按带了的平均补上;带时长的不到三成就不写,同 Last.fm 那一路的估法
	// (lastfmEstimateDuration),不然「约 X 小时」只算了一部分、明显偏小。
	if knownPlays > 0 && float64(knownPlays) >= float64(len(listens))*lastfmEstimateDurationMinShare {
		stats.TotalDurationMs = knownMs * int64(len(listens)) / int64(knownPlays)
		stats.DurationEstimated = knownPlays < len(listens)
	}
	return stats
}

// topTallies 按次数降序(同次数保持首次出现的顺序)取前 digestTopN() 条。
func topTallies(tallies []digestTally) []digestTally {
	sort.SliceStable(tallies, func(i, j int) bool { return tallies[i].Count > tallies[j].Count })
	if topN := digestTopN(); len(tallies) > topN {
		tallies = tallies[:topN]
	}
	return tallies
}

// digestPush 推送一条听歌报告——各 cadence 各自算好 title、拿到 stats 后调用同一份文案
// 拼装逻辑(digestBody)。一个渠道都没收下才返回错误，调用方不记「已推送」，下次检查重推。
// 正文是纯文本那一份(推送记录、纯文本平台用);按平台排版的由 notifyrich.go 照 stats 另排。
func digestPush(a *alerter, event, title string, stats digestStats) error {
	return a.sendMessage(notifyMessage{Event: event, Title: title, Body: digestBody(stats), Digest: &stats})
}

// digestShown:某一类要不要列。只有超过 1 条时才列(只有一条时排名没有意义)，「每类列出」设成 1 时例外：用户要的就是各类第一名。
func digestShown(list []digestTally) bool {
	return len(list) > 1 || (len(list) == 1 && digestTopN() == 1)
}

// digestSummaryLine 是正文第一行:总次数、跟上一期比、听了多久。按平台排版的也用这一行。
func digestSummaryLine(stats digestStats) string {
	var b strings.Builder
	if stats.Truncated {
		fmt.Fprintf(&b, "共播放 %d 次以上（记录太多，只统计了最近这些）", stats.TotalPlays)
	} else {
		fmt.Fprintf(&b, "共播放 %d 次", stats.TotalPlays)
		if stats.PrevPlays > 0 && stats.PrevLabel != "" {
			fmt.Fprintf(&b, "（%s %d，%s）", stats.PrevLabel, stats.PrevPlays, digestChange(stats.TotalPlays, stats.PrevPlays))
		}
	}
	if stats.TotalDurationMs > 0 {
		totalMin := stats.TotalDurationMs / 60000
		if totalMin >= 60 {
			fmt.Fprintf(&b, " · 约 %d 小时 %d 分", totalMin/60, totalMin%60)
		} else {
			fmt.Fprintf(&b, " · 约 %d 分", totalMin)
		}
	}
	return b.String()
}

// digestChange:「↑12%」「↓32%」,四舍五入后是 0 写「持平」。
func digestChange(cur, prev int) string {
	pct := int(math.Round(float64(cur-prev) * 100 / float64(prev)))
	switch {
	case pct > 0:
		return fmt.Sprintf("↑%d%%", pct)
	case pct < 0:
		return fmt.Sprintf("↓%d%%", -pct)
	}
	return "持平"
}

// digestNewArtistsLine:「新听了 44 位歌手：A、B、C 等」。名字列全了就不写「等」;一位都没有返回空。
func digestNewArtistsLine(stats digestStats) string {
	if stats.NewArtists <= 0 {
		return ""
	}
	line := fmt.Sprintf("新听了 %d 位歌手", stats.NewArtists)
	if len(stats.NewArtistNames) == 0 {
		return line
	}
	line += "：" + strings.Join(stats.NewArtistNames, "、")
	if stats.NewArtists > len(stats.NewArtistNames) {
		line += " 等"
	}
	return line
}

// digestBody 拼推送正文:第一行(digestSummaryLine),然后歌手、专辑、歌曲(digestShown),最后一句新听的歌手。
func digestBody(stats digestStats) string {
	shown := digestShown
	var b strings.Builder
	b.WriteString(digestSummaryLine(stats))
	b.WriteString("\n")
	if shown(stats.TopArtists) {
		b.WriteString("\nTop 歌手：\n")
		for i, t := range stats.TopArtists {
			fmt.Fprintf(&b, "%d. %s（%d）\n", i+1, t.Name, t.Count)
		}
	}
	if shown(stats.TopAlbums) {
		b.WriteString("\nTop 专辑：\n")
		for i, t := range stats.TopAlbums {
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Sub, t.Name, t.Count)
		}
	}
	if shown(stats.TopTracks) {
		b.WriteString("\nTop 歌曲：\n")
		for i, t := range stats.TopTracks {
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Sub, t.Name, t.Count)
		}
	}
	if line := digestNewArtistsLine(stats); line != "" {
		b.WriteString("\n" + line + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}
