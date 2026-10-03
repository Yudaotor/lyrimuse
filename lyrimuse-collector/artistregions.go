package main

// 「歌手来自哪里」的后台汇总,给 App「足迹」段那张卡用。三个时段(近 30 天 / 近一年 / 全部)各取 Last.fm 歌手榜,
// 按歌手榜那套只读缓存的归并(mergeAliasedArtistBuckets)合成一行一人,给每个人找 mbid、查一次 MusicBrainz 登记的
// 所属国家或地区(不是出生地),按播放次数加权汇总,连同每个地区播放最多的几位歌手写进缓存文件。App 只读这份文件、不联网。

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	neturl "net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// artistRegionsCheckInterval:两轮汇总之间至少隔这么久。
	artistRegionsCheckInterval = 6 * time.Hour
	// artistRegionsQuickRetry:一轮把请求额度用完、中间没出错时,隔这么久接着查。首次要查的有一两百位,
	// 一轮 60 个,按 30 分钟排要好几个小时;平均下来每 5 秒 1 个请求,远低于 MusicBrainz 每秒 1 个的要求。
	artistRegionsQuickRetry = 5 * time.Minute
	// artistRegionsPartialRetry:这一轮出过错(没取到榜单、MusicBrainz 超时或限流 503)时,隔这么久再来。
	artistRegionsPartialRetry = 30 * time.Minute
	// artistRegionsRequestBudget:每轮最多发多少个 MusicBrainz 请求(全局 1.1 s 限速)。
	artistRegionsRequestBudget = 60
	// artistRegionsFetchLimit:每个时段从 Last.fm 取多少条原始记录。合并会把几条折成一行,取得比要统计的多。
	artistRegionsFetchLimit = 300
	// artistRegionsTopArtists:每个时段合并后统计前多少位,随汇总写进文件(top_artists),App 卡底那句说明照它写。
	artistRegionsTopArtists = 200
	// artistRegionsRetryAfter:查过但没登记国家的歌手,隔这么久才再查一次。
	artistRegionsRetryAfter = 30 * 24 * time.Hour
	// artistRegionsNamesPerRegion:每个地区列几位歌手。
	artistRegionsNamesPerRegion = 3
	// artistRegionsMaxConsecutiveFailures:MusicBrainz 连着这么多次没问成就停下这一轮。单次超时 6 s,
	// 不停的话它整体挂掉时一轮能占住后台任务好几分钟,同一个 goroutine 里的听歌报告推送跟着往后拖。
	artistRegionsMaxConsecutiveFailures = 3
)

// artistRegionsPeriods:要汇总的时段,跟 App 那张卡的范围切换一致(近 30 天 / 近一年 / 全部)。
var artistRegionsPeriods = []string{"1month", "12month", "overall"}

type artistRegionEntry struct {
	// Country 是 ISO 3166-1 两位代码;空 = 查过、MusicBrainz 没登记。
	Country string `json:"country,omitempty"`
	Checked int64  `json:"checked"`
}

type artistRegionsBucket struct {
	Code    string   `json:"code"`
	Plays   int      `json:"plays"`
	Artists []string `json:"artists"`
}

type artistRegionsPeriod struct {
	// TopArtists:按歌手榜前多少位统计(artistRegionsTopArtists)。App 照它写「按前 N 位歌手统计」,不另存一份。
	TopArtists int `json:"top_artists"`
	// Covered:统计到的这些歌手合计的播放次数(= 各地区合计 + Pending + Unresolved)。
	Covered int `json:"covered"`
	// Pending:有 mbid、还没查到结论的那部分(App「还在查」那一行);查完就归进某个地区或 Unresolved。
	Pending        int      `json:"pending"`
	PendingArtists []string `json:"pending_artists,omitempty"`
	// Unresolved:没有 mbid、或查过但 MusicBrainz 没登记国家的那部分(App「未查到」那一行)。
	Unresolved int `json:"unresolved"`
	// UnresolvedArtists:Unresolved 里播放最多的几位。
	UnresolvedArtists []string              `json:"unresolved_artists,omitempty"`
	Regions           []artistRegionsBucket `json:"regions"`
}

type artistRegionsFile struct {
	// User:汇总属于哪个 Last.fm 账号。换账号时 Periods 立刻作废重算(Artists 是 mbid → 国家,跟账号无关,留着);
	// App 读到账号对不上的文件就当没有。
	User    string                         `json:"user"`
	Updated int64                          `json:"updated"`
	NextAt  int64                          `json:"next_at"`
	Artists map[string]artistRegionEntry   `json:"artists"` // 键:歌手 mbid
	Periods map[string]artistRegionsPeriod `json:"periods"` // 键:Last.fm 时段名
}

var (
	artistRegionsMu    sync.Mutex
	artistRegionsPath  string
	artistRegionsCache = artistRegionsFile{Artists: map[string]artistRegionEntry{}, Periods: map[string]artistRegionsPeriod{}}
)

func loadArtistRegionsCache(path string) {
	artistRegionsPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f artistRegionsFile
	if err := json.Unmarshal(data, &f); err != nil {
		return
	}
	if f.Artists == nil {
		f.Artists = map[string]artistRegionEntry{}
	}
	if f.Periods == nil {
		f.Periods = map[string]artistRegionsPeriod{}
	}
	artistRegionsMu.Lock()
	artistRegionsCache = f
	artistRegionsMu.Unlock()
	noteCacheLoaded(path, fmt.Sprintf("artist regions for %d artists", len(f.Artists)))
}

func saveArtistRegionsCache() {
	artistRegionsMu.Lock()
	if artistRegionsPath == "" {
		artistRegionsMu.Unlock()
		return
	}
	data, err := json.Marshal(artistRegionsCache)
	artistRegionsMu.Unlock()
	if err != nil {
		return
	}
	if err := writeFileAtomic(artistRegionsPath, data); err != nil {
		slog.Error("save artist regions cache", "err", err)
	}
}

// artistRegionsSource 是汇总要用的联网动作与归并,单测换成假的。
type artistRegionsSource struct {
	topArtists func(ctx context.Context, period string) ([]lastfmChartEntry, error)
	// merge 把原始榜单归并成一行一人(按播放次数降序),并给出每条原始记录的身份。
	merge func(entries []lastfmChartEntry) ([]mergedArtist, []mbArtistIdentity)
	// country 查一位歌手登记的国家代码;返回用掉的 MusicBrainz 请求数。err 非空 = 没问成(这次不记结论)。
	country func(ctx context.Context, mbid string) (string, int, error)
}

// artistRegionsDigest 由后台任务(runDigests)调用:没到 next_at 就跳过;没配 Last.fm 也跳过。
func (p *poller) artistRegionsDigest(now time.Time, env digestEnv) {
	user, key := env.cfg.LastfmUser, env.cfg.lastfmBridgeAPIKey()
	if user == "" || key == "" {
		return
	}
	src := artistRegionsSource{
		topArtists: func(ctx context.Context, period string) ([]lastfmChartEntry, error) {
			return lastfmTopArtistsPeriod(ctx, user, key, period, artistRegionsFetchLimit)
		},
		merge: func(entries []lastfmChartEntry) ([]mergedArtist, []mbArtistIdentity) {
			return mergeAliasedArtistBuckets(entries, cacheOnlyArtistIdentity, artistMergeNameKeyCached, artistMergeDisplayNameCached)
		},
		country: mbArtistCountry,
	}
	if warmArtistRegions(env.ctx, now, user, artistRegionsRequestBudget, src) {
		saveArtistRegionsCache()
	}
}

// mergedArtistMbid 取一行的 mbid:成员里身份解析给出的在前,其次是单人条目 Last.fm 自带的。
// 合唱串自带的 mbid 属于整条 credit(理由同 warmArtistIdentityCache),不拿来代表这个人。
func mergedArtistMbid(m mergedArtist, entries []lastfmChartEntry, ids []mbArtistIdentity) string {
	for _, i := range m.members {
		if i < len(ids) && ids[i].Mbid != "" {
			return ids[i].Mbid
		}
	}
	for _, i := range m.members {
		e := entries[i]
		if e.Mbid != "" && strings.EqualFold(strings.TrimSpace(firstCreditedArtist(e.Name)), strings.TrimSpace(e.Name)) {
			return e.Mbid
		}
	}
	return ""
}

// warmArtistRegions 跑一轮:没到 next_at 返回 false。三个时段都取到才重算汇总;有一个没取到就只把 next_at 推到
// artistRegionsPartialRetry 之后(不推的话后台任务每 5 秒一拍,Last.fm 不通期间就每拍重发)。缺国家的歌手按
// 「近期时段在前、播放多的在前」去查,用掉 budget 个请求、或连着 artistRegionsMaxConsecutiveFailures 次没问成就停。
// 还有没查的:这轮出过错 next_at 记成 artistRegionsPartialRetry 之后,只是额度用完记成 artistRegionsQuickRetry 之后。
// 被取消(进程退出)不推进 next_at,已查到的照样留着。
// 返回 true = 缓存有变化,调用方负责落盘。
func warmArtistRegions(ctx context.Context, now time.Time, user string, budget int, src artistRegionsSource) bool {
	artistRegionsMu.Lock()
	if artistRegionsCache.User != user {
		artistRegionsCache.User = user
		artistRegionsCache.Periods = map[string]artistRegionsPeriod{}
		artistRegionsCache.NextAt = 0
	}
	next := artistRegionsCache.NextAt
	artistRegionsMu.Unlock()
	if next > 0 && now.Unix() < next {
		return false
	}

	type periodRows struct {
		entries []lastfmChartEntry
		merged  []mergedArtist
		mbids   []string
	}
	rows := map[string]periodRows{}
	for _, pd := range artistRegionsPeriods {
		entries, err := src.topArtists(ctx, pd)
		if err != nil {
			slog.Info("artist regions: top artists failed", "period", pd, "err", err)
			if ctx.Err() == nil {
				artistRegionsMu.Lock()
				artistRegionsCache.NextAt = now.Add(artistRegionsPartialRetry).Unix()
				artistRegionsMu.Unlock()
			}
			return false
		}
		merged, ids := src.merge(entries)
		if len(merged) > artistRegionsTopArtists {
			merged = merged[:artistRegionsTopArtists]
		}
		mbids := make([]string, len(merged))
		for i, m := range merged {
			mbids[i] = mergedArtistMbid(m, entries, ids)
		}
		rows[pd] = periodRows{entries: entries, merged: merged, mbids: mbids}
	}

	pending := false
	failed := false
	cancelled := false
	failures := 0
	lookedUp := map[string]bool{}
lookup:
	for _, pd := range artistRegionsPeriods {
		for _, mbid := range rows[pd].mbids {
			if mbid == "" || lookedUp[mbid] {
				continue
			}
			lookedUp[mbid] = true
			artistRegionsMu.Lock()
			e, ok := artistRegionsCache.Artists[mbid]
			artistRegionsMu.Unlock()
			if ok && (e.Country != "" || now.Sub(time.Unix(e.Checked, 0)) < artistRegionsRetryAfter) {
				continue
			}
			if budget <= 0 {
				pending = true
				break lookup
			}
			code, used, err := src.country(ctx, mbid)
			budget -= used
			if err != nil && mbDefinitiveMiss(err) {
				// MusicBrainz 上没有这个 mbid(Last.fm 给了一个不存在或已失效的):这是结论,跟「查过、没登记国家」一样记下,
				// 按 artistRegionsRetryAfter 过一阵再查。当成没问成的话,这位歌手永远停在「还在查」,每一轮都算失败、
				// 30 分钟就重拉一次榜单,几个这样的排在前面时还会挡住后面的歌手。
				err, code = nil, ""
			}
			if err != nil {
				if ctx.Err() != nil {
					cancelled = true
					break lookup
				}
				pending, failed = true, true
				if failures++; failures >= artistRegionsMaxConsecutiveFailures {
					break lookup
				}
				continue
			}
			failures = 0
			artistRegionsMu.Lock()
			artistRegionsCache.Artists[mbid] = artistRegionEntry{Country: code, Checked: now.Unix()}
			artistRegionsMu.Unlock()
		}
	}

	artistRegionsMu.Lock()
	for _, pd := range artistRegionsPeriods {
		r := rows[pd]
		artistRegionsCache.Periods[pd] = summarizeArtistRegions(r.merged, r.mbids, artistRegionsCache.Artists)
	}
	artistRegionsCache.Updated = now.Unix()
	if !cancelled {
		wait := artistRegionsCheckInterval
		switch {
		case failed:
			wait = artistRegionsPartialRetry
		case pending:
			wait = artistRegionsQuickRetry
		}
		artistRegionsCache.NextAt = now.Add(wait).Unix()
	}
	artistRegionsMu.Unlock()
	return true
}

// summarizeArtistRegions 按国家代码加权汇总一个时段。地区按次数降序,平手按代码排,输出稳定。纯函数。
func summarizeArtistRegions(merged []mergedArtist, mbids []string, known map[string]artistRegionEntry) artistRegionsPeriod {
	type acc struct {
		plays int
		names []string
	}
	byCode := map[string]*acc{}
	out := artistRegionsPeriod{TopArtists: artistRegionsTopArtists}
	for i, m := range merged {
		out.Covered += m.PlayCount
		e, checked := known[mbids[i]]
		if mbids[i] != "" && !checked {
			out.Pending += m.PlayCount
			if len(out.PendingArtists) < artistRegionsNamesPerRegion {
				out.PendingArtists = append(out.PendingArtists, m.Name)
			}
			continue
		}
		code := e.Country
		if code == "" {
			out.Unresolved += m.PlayCount
			if len(out.UnresolvedArtists) < artistRegionsNamesPerRegion {
				out.UnresolvedArtists = append(out.UnresolvedArtists, m.Name)
			}
			continue
		}
		a := byCode[code]
		if a == nil {
			a = &acc{}
			byCode[code] = a
		}
		a.plays += m.PlayCount
		// merged 按播放次数降序,先到的就是这个地区播放最多的。
		if len(a.names) < artistRegionsNamesPerRegion {
			a.names = append(a.names, m.Name)
		}
	}
	out.Regions = make([]artistRegionsBucket, 0, len(byCode))
	for code, a := range byCode {
		out.Regions = append(out.Regions, artistRegionsBucket{Code: code, Plays: a.plays, Artists: a.names})
	}
	sort.Slice(out.Regions, func(i, j int) bool {
		if out.Regions[i].Plays != out.Regions[j].Plays {
			return out.Regions[i].Plays > out.Regions[j].Plays
		}
		return out.Regions[i].Code < out.Regions[j].Code
	})
	return out
}

// mbArtistCountry 查 MusicBrainz 歌手条目的 country 字段(所属国家或地区的两位代码,可能为空)。
func mbArtistCountry(ctx context.Context, mbid string) (string, int, error) {
	if err := musicbrainzThrottle(ctx); err != nil {
		return "", 0, err
	}
	var a struct {
		Country string `json:"country"`
	}
	u := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(mbid) + "?fmt=json"
	if err := mbGetJSON(ctx, u, &a); err != nil {
		return "", 1, err
	}
	return strings.ToUpper(strings.TrimSpace(a.Country)), 1, nil
}
