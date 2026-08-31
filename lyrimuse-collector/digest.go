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

// 每周/每日听歌报告可以自选用哪个账号的数据(Last.fm 或 ListenBrainz)：默认取已经
// 配置好的那个，两个都配了就用 Last.fm，都没配就提示需要先配置。这个文件是两个
// cadence(周/日)共用的部分：统一的统计结果形状、按数据源分派的两条取数路径、统一的
// 推送文案拼装、以及默认数据源的判定逻辑。weekly.go/daily.go 各自只保留"什么时候算
// 一个新周期已经收官、该不该检查"这部分跟周期长度强相关、没法共用的逻辑。

const (
	digestSourceLastfm       = "lastfm"
	digestSourceListenBrainz = "listenbrainz"
)

// digestTopN：推送里 Top 歌曲/歌手最多展示几条，Bark 锁屏预览要能读完，不铺开全量。
const digestTopN = 3

// digestTally 是某首歌/某个歌手在统计区间内被听了几次。
type digestTally struct {
	Name, Sub string // 歌曲:Name=歌名,Sub=歌手；歌手:Name=歌手名,Sub 留空
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

// lastfmDigestStats 用 Last.fm 的周榜接口(weekly.go 里已有的 lastfmWeeklyTopTracks/
// lastfmWeeklyTopArtists)取 [from,to) 区间的统计——这两个函数名字叫"weekly"，但参数
// 本来就是任意 from/to，喂一天的范围一样能用，不是专属周报的函数。没有时长数据
// (TotalDurationMs 留 0)，播放次数 = 各歌曲 playcount 之和(chart 接口本来就是全量，
// 不受这里只取 Top N 展示的影响)。
func lastfmDigestStats(ctx context.Context, user, apiKey string, from, to int64) (digestStats, error) {
	tracks, err := lastfmWeeklyTopTracks(ctx, user, apiKey, from, to)
	if err != nil {
		return digestStats{}, err
	}
	artists, err := lastfmWeeklyTopArtists(ctx, user, apiKey, from, to)
	if err != nil {
		return digestStats{}, err
	}
	var stats digestStats
	for _, t := range tracks {
		stats.TotalPlays += t.PlayCount
	}
	for i, t := range tracks {
		if i >= digestTopN {
			break
		}
		stats.TopTracks = append(stats.TopTracks, digestTally{Name: t.Name, Sub: t.Artist, Count: t.PlayCount})
	}
	stats.TopArtists = digestTopArtists(artists)
	return stats, nil
}

// digestTopArtists 把 Last.fm 歌手榜条目**先归并、再取 Top N**。
//
// 抽成独立的纯函数而不是内联在 lastfmDigestStats 里,是为了让"这条路径确实做了归并"
// 这件事可测 —— lastfmDigestStats 自己要打网络,测不了;内联的话把归并那一行删掉,
// 单测(只测 mergeAliasedArtists 本身)照样全绿,等于没守住。
//
// 归并跟歌手榜(topartists.go)走**同一套**,别自己再造一份 —— 2026-08-30 通盘梳理时
// 发现 digest 原来完全不归并,于是同一个二进制里同一个人在推送里是两个、在榜单里是
// 一个(实测这台机器 389 个歌手写法里有 1 例:"张震岳"/"张震嶽")。
//
// 用 mergeAliasedArtists 这个已有入口而不是自己按名字键 group:它内部除了名字键还看
// mbid(并查集,允许链式传递),口径跟榜单逐字一致;而且它走的是 cacheOnlyArtistIdentity
// —— **只读本地缓存、一个网络请求都不发**,不会给后台推送这条路径加延迟或限速压力。
//
// ⚠️ 顺序依赖:取前 N 之前必须已经按次数降序排好。mergeAliasedArtists 结尾有
// sort.SliceStable 保证了这一点(合并会让次数相加、名次变动,不重排就会取错)。
//
// 已知取舍(2026-08-30 用户拍板):合并之后名次和次数会跟**历史推送**对不上。接受 ——
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
	Title, Artist string
	ListenedAt    int64
	DurationMs    int64 // 0 = 这条记录没带时长(比如 iPhone 桥接来的 playing_now 转发)，不计入总时长
}

// lbListensInRange 拉该用户 [fromUnix,toUnix) 区间内的收听记录，按 max_ts 游标翻页
// (ListenBrainz 一页最多 100 条，一周的量级可能不止一页，日报一般用不到翻页但同一份
// 实现两边共用，不用维护两份"翻不翻页"的取数逻辑)。翻页上限 10 页(最多 1000 条)，
// 纯粹是给一个"极端情况下别无限翻下去"的保险丝，正常用量不会碰到这个上限。
func lbListensInRange(ctx context.Context, root, user string, fromUnix, toUnix int64) ([]lbListenEntry, error) {
	var all []lbListenEntry
	cursor := toUnix
	for page := 0; page < 10; page++ {
		entries, oldestInPage, err := lbListensBefore(ctx, root, user, fromUnix, cursor)
		if err != nil {
			return nil, err
		}
		all = append(all, entries...)
		if len(entries) < 100 || oldestInPage <= fromUnix {
			break // 这一页不满 100 条(已经翻到底)，或者已经翻到区间起点之前，没有更早的了
		}
		cursor = oldestInPage // 下一页从"这一页最早一条"往更早继续翻
	}
	return all, nil
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
			Title: l.TrackMetadata.TrackName, Artist: l.TrackMetadata.ArtistName,
			ListenedAt: l.ListenedAt, DurationMs: l.TrackMetadata.AdditionalInfo.DurationMs,
		})
		if oldest == 0 || l.ListenedAt < oldest {
			oldest = l.ListenedAt
		}
	}
	return entries, oldest, nil
}

// listenbrainzDigestStats 取 [fromUnix,toUnix) 区间的 ListenBrainz 收听记录并在本地
// 聚合——不像 Last.fm 那边有现成的服务端聚合接口，这里自己按(歌名,歌手)/歌手分别计数、
// 按次数排序取 Top N，同时能顺带算出总时长(Last.fm 那条路径给不出这个)。
func listenbrainzDigestStats(ctx context.Context, root, user string, from, to int64) (digestStats, error) {
	listens, err := lbListensInRange(ctx, root, user, from, to)
	if err != nil {
		return digestStats{}, err
	}
	var stats digestStats
	stats.TotalPlays = len(listens)
	trackIndex, artistIndex := map[string]int{}, map[string]int{}
	var trackTallies, artistTallies []digestTally
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
		// (2026-08-30 一并统一,否则用户换个数据源"同一个人被算成两个"这个坑还在)。
		// 这里只能用 artistMergeNameKey 这个纯函数版本,不能套 mergeAliasedArtists:
		// 那个吃的是 lastfmChartEntry(带 mbid),而 LB 的收听记录里没有 mbid,并查集
		// 的第二个信号本来就用不上,按名字键分桶已经是这条路径能做到的全部。
		ak := artistMergeNameKey(l.Artist)
		if idx, ok := artistIndex[ak]; ok {
			artistTallies[idx].Count++
		} else {
			artistIndex[ak] = len(artistTallies)
			// 展示名用 artistMergeDisplayName:只把已知罗马字艺名换成中文本名,**不**做
			// 繁简/大小写折叠 —— 那两步只是判同一个人时内部用的,不该篡改用户库里原本
			// 的书写(理由见 artistMergeDisplayName 的注释)。
			artistTallies = append(artistTallies, digestTally{Name: artistMergeDisplayName(l.Artist), Count: 1})
		}
	}
	sort.SliceStable(trackTallies, func(i, j int) bool { return trackTallies[i].Count > trackTallies[j].Count })
	sort.SliceStable(artistTallies, func(i, j int) bool { return artistTallies[i].Count > artistTallies[j].Count })
	if len(trackTallies) > digestTopN {
		trackTallies = trackTallies[:digestTopN]
	}
	if len(artistTallies) > digestTopN {
		artistTallies = artistTallies[:digestTopN]
	}
	stats.TopTracks, stats.TopArtists = trackTallies, artistTallies
	return stats, nil
}

// digestPush 拼标题/正文并推送——weekly.go/daily.go 各自算好 title、拿到 stats 后调用
// 同一份文案拼装逻辑，不用两边各写一遍几乎相同的 strings.Builder 拼接。只有超过 1 首
// 不同的歌/1 个不同的歌手时才展示对应的 Top 榜单(只有一首歌时排名没有意义)。
func digestPush(a *alerter, title string, stats digestStats) {
	var b strings.Builder
	fmt.Fprintf(&b, "共播放 %d 次", stats.TotalPlays)
	if stats.TotalDurationMs > 0 {
		totalMin := stats.TotalDurationMs / 60000
		if totalMin >= 60 {
			fmt.Fprintf(&b, " · 约 %d 小时 %d 分", totalMin/60, totalMin%60)
		} else {
			fmt.Fprintf(&b, " · 约 %d 分", totalMin)
		}
	}
	if len(stats.TopArtists) > 1 {
		b.WriteString("\n\nTop 歌手：\n")
		for i, t := range stats.TopArtists {
			fmt.Fprintf(&b, "%d. %s（%d）\n", i+1, t.Name, t.Count)
		}
	}
	if len(stats.TopTracks) > 1 {
		b.WriteString("\nTop 歌曲：\n")
		for i, t := range stats.TopTracks {
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Sub, t.Name, t.Count)
		}
	}
	a.push(title, strings.TrimRight(b.String(), "\n"))
}
