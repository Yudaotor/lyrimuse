// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
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

// digestTopN：推送里 Top 歌手/专辑/歌曲最多展示几条，Bark 锁屏预览要能读完，不铺开全量。
const digestTopN = 3

// digestTally 是某首歌/某张专辑/某个歌手在统计区间内被听了几次。
type digestTally struct {
	Name, Sub string // 歌曲/专辑:Name=歌名或专辑名,Sub=歌手；歌手:Name=歌手名,Sub 留空
	Count     int
}

// digestStats 是一段时间范围内的统计结果，跟数据源无关——两条取数路径
// (lastfmDigestStats/listenbrainzDigestStats)分别产出同一种形状。
type digestStats struct {
	TotalPlays      int
	TotalDurationMs int64 // 0 表示"这个数据源给不出时长"(目前是 Last.fm 榜单接口的情况)，
	// 推送文案据此判断要不要显示"累计时长"这一句，不是当成"今天真的听了 0 秒"。
	TopTracks  []digestTally
	TopArtists []digestTally
	TopAlbums  []digestTally
	// Truncated:逐条翻收听记录翻到上限还没翻完,上面的数字只是最近那一部分。推送里会写明。
	Truncated bool
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
	p.weeklyDigest(now, env)
	p.dailyDigest(now, env)
	p.monthlyDigest(now, env)
	p.yearlyDigest(now, env)
	p.topArtistsDigest(now, env)
}

// resolveDigestSource 判定"这次检查该用哪个数据源"：preference 非空且明确指定就用它；
// 否则按"两个都配了到Last.fm，只配了一个到用那个，都没配到返回空字符串"解析出默认值。
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
	return digestStatsFromCharts(tracks, artists, albums), nil
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
	for i, t := range tracks {
		if i >= digestTopN {
			break
		}
		stats.TopTracks = append(stats.TopTracks, digestTally{Name: t.Name, Sub: t.Artist, Count: t.PlayCount})
	}
	stats.TopArtists = digestTopArtists(artists)
	for _, a := range albums {
		if len(stats.TopAlbums) >= digestTopN {
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
	var out []digestTally
	for i, a := range merged {
		if i >= digestTopN {
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
	DurationMs             int64 // 0 = 这条记录没带时长(比如 iPhone 桥接来的 playing_now 转发)，不计入总时长
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
	url := fmt.Sprintf("%s/1/user/%s/listens?count=100&min_ts=%d&max_ts=%d", root, user, fromUnix, maxTs)
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
	return stats, nil
}

// digestStatsFromListens 是 listenbrainzDigestStats 的聚合部分，纯函数。
func digestStatsFromListens(listens []lbListenEntry) digestStats {
	var stats digestStats
	stats.TotalPlays = len(listens)
	trackIndex, artistIndex, albumIndex := map[string]int{}, map[string]int{}, map[string]int{}
	var trackTallies, artistTallies, albumTallies []digestTally
	for _, l := range listens {
		stats.TotalDurationMs += l.DurationMs
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
	return stats
}

// topTallies 按次数降序(同次数保持首次出现的顺序)取前 digestTopN 条。
func topTallies(tallies []digestTally) []digestTally {
	sort.SliceStable(tallies, func(i, j int) bool { return tallies[i].Count > tallies[j].Count })
	if len(tallies) > digestTopN {
		tallies = tallies[:digestTopN]
	}
	return tallies
}

// digestPush 推送一条听歌报告——各 cadence 各自算好 title、拿到 stats 后调用同一份文案
// 拼装逻辑(digestBody)。推送失败返回错误，调用方不记「已推送」，下次检查重推。
func digestPush(a *alerter, title string, stats digestStats) error {
	return a.push(title, digestBody(stats))
}

// digestBody 拼推送正文。顺序是歌手、专辑、歌曲；某一类只有超过 1 条时才展示(只有一条时
// 排名没有意义)。
func digestBody(stats digestStats) string {
	var b strings.Builder
	if stats.Truncated {
		fmt.Fprintf(&b, "共播放 %d 次以上（记录太多，只统计了最近这些）", stats.TotalPlays)
	} else {
		fmt.Fprintf(&b, "共播放 %d 次", stats.TotalPlays)
	}
	if stats.TotalDurationMs > 0 {
		totalMin := stats.TotalDurationMs / 60000
		if totalMin >= 60 {
			fmt.Fprintf(&b, " · 约 %d 小时 %d 分", totalMin/60, totalMin%60)
		} else {
			fmt.Fprintf(&b, " · 约 %d 分", totalMin)
		}
	}
	b.WriteString("\n")
	if len(stats.TopArtists) > 1 {
		b.WriteString("\nTop 歌手：\n")
		for i, t := range stats.TopArtists {
			fmt.Fprintf(&b, "%d. %s（%d）\n", i+1, t.Name, t.Count)
		}
	}
	if len(stats.TopAlbums) > 1 {
		b.WriteString("\nTop 专辑：\n")
		for i, t := range stats.TopAlbums {
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Sub, t.Name, t.Count)
		}
	}
	if len(stats.TopTracks) > 1 {
		b.WriteString("\nTop 歌曲：\n")
		for i, t := range stats.TopTracks {
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Sub, t.Name, t.Count)
		}
	}
	return strings.TrimRight(b.String(), "\n")
}
