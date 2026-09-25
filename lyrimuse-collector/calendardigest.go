// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
	"time"
)

// 每月 / 年度听歌小结：按自然月、自然年推送上一个周期的统计。取数、聚合、拼文案跟日报 / 周报
// 共用 digest.go；这里只管周期边界、该不该推，以及 ListenBrainz 这一路改走统计接口。

// calendarDigestKind 区分每月 / 年度两种周期。
type calendarDigestKind int

const (
	calendarDigestMonthly calendarDigestKind = iota
	calendarDigestYearly
)

// calendarDigestCheckInterval：周期一个月才翻一次，跟周报一样两小时查一次足够。
const calendarDigestCheckInterval = 2 * time.Hour

// calendarDigestLBGrace：ListenBrainz 的统计每天才重算一次，周期刚结束时它可能还是空的
// 或者还停在更早的周期。过了这么久还是空，才当成「这个周期确实没听」记为已处理，否则下次再查。
const calendarDigestLBGrace = 7 * 24 * time.Hour

// previousCalendarPeriod 返回 now 所在自然月 / 自然年的上一个周期(本地时间)：[from, to) 与
// 周期键("2006-01" / "2006")。
func previousCalendarPeriod(now time.Time, kind calendarDigestKind) (from, to time.Time, key string) {
	if kind == calendarDigestYearly {
		to = time.Date(now.Year(), time.January, 1, 0, 0, 0, 0, now.Location())
		from = to.AddDate(-1, 0, 0)
		return from, to, from.Format("2006")
	}
	to = time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
	from = to.AddDate(0, -1, 0)
	return from, to, from.Format("2006-01")
}

// calendarDigestTitle 推送标题。写明是哪一个月 / 哪一年，不用「上月」「去年」：collector 停过
// 一阵再启动时，推出来的可能不是紧挨着的上一个周期。
func calendarDigestTitle(kind calendarDigestKind, from time.Time) string {
	if kind == calendarDigestYearly {
		return fmt.Sprintf("🏆 %d 年度听歌小结", from.Year())
	}
	return fmt.Sprintf("📅 %d 年 %d 月听歌小结", from.Year(), int(from.Month()))
}

// calendarDigestState 持久化「已推送到哪个周期」(周期键)，防重启后重推。每月、年度各一份文件。
type calendarDigestState struct{ path string }

func (s calendarDigestState) load() string {
	if s.path == "" {
		return ""
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return ""
	}
	var v struct {
		LastPeriod string `json:"last_period"`
	}
	json.Unmarshal(b, &v)
	return v.LastPeriod
}

func (s calendarDigestState) save(period string) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastPeriod string `json:"last_period"`
	}{period})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

// calendarDigestRun 是一种周期在 poller 里的运行状态。
type calendarDigestRun struct {
	state         calendarDigestState
	lastCheckedAt time.Time
}

var monthlyDigestPath, yearlyDigestPath string

func (p *poller) monthlyDigest(now time.Time, env digestEnv) {
	p.calendarDigest(now, env, calendarDigestMonthly, &p.monthlyRun, features().MonthlyDigest, features().MonthlyDigestSource)
}

func (p *poller) yearlyDigest(now time.Time, env digestEnv) {
	p.calendarDigest(now, env, calendarDigestYearly, &p.yearlyRun, features().YearlyDigest, features().YearlyDigestSource)
}

// calendarDigest 检查(至多每 calendarDigestCheckInterval 一次)上一个自然月 / 自然年推过没有，
// 没推过就拉统计推一条。数据源按 resolveDigestSource 解析，跟日报 / 周报同一套规则：
//   - Last.fm：周榜接口接受任意 from/to，直接传这个周期的本地时间边界。
//   - ListenBrainz：逐条翻收听记录翻不完一个月、一年，改用它的统计接口(lbStatsDigest)。
//     统计接口按 UTC 自然月 / 年切，跟本地边界差几个小时，接受。
func (p *poller) calendarDigest(now time.Time, env digestEnv, kind calendarDigestKind, run *calendarDigestRun, enabled bool, preference string) {
	if !enabled || env.alerter == nil || env.alerter.url == "" {
		return
	}
	if !run.lastCheckedAt.IsZero() && now.Sub(run.lastCheckedAt) < calendarDigestCheckInterval {
		return
	}
	run.lastCheckedAt = now

	from, to, key := previousCalendarPeriod(now, kind)
	if key <= run.state.load() {
		return // 已经推送过了
	}

	lastfmConfigured := env.cfg.LastfmUser != "" && env.cfg.lastfmBridgeAPIKey() != ""
	lbConfigured := env.cfg.User != "" && env.cfg.Token != ""
	source := resolveDigestSource(preference, lastfmConfigured, lbConfigured)
	if source == "" {
		return
	}

	var stats digestStats
	if source == digestSourceLastfm {
		var err error
		stats, err = lastfmDigestStats(env.ctx, env.cfg.LastfmUser, env.cfg.lastfmBridgeAPIKey(), from.Unix(), to.Unix())
		if err != nil {
			return
		}
	} else {
		var ready bool
		var err error
		stats, ready, err = lbStatsDigest(env.ctx, env.lbRoot, env.cfg.User, kind, key)
		if err != nil {
			return
		}
		if !ready {
			if now.Sub(to) > calendarDigestLBGrace {
				run.state.save(key)
			}
			return
		}
	}
	if stats.TotalPlays == 0 {
		run.state.save(key) // 这个周期确实没听，不推送，但标记已处理
		return
	}
	if digestPush(env.alerter, calendarDigestTitle(kind, from), stats) != nil {
		return
	}
	run.state.save(key)
}

// lbStatsRange 是 ListenBrainz 统计接口的 range 参数：month = 上一个自然月，year = 上一个自然年。
func lbStatsRange(kind calendarDigestKind) string {
	if kind == calendarDigestYearly {
		return "year"
	}
	return "month"
}

// lbStatsPeriodKey 把统计接口返回的 from_ts 换成周期键(按 UTC)，用来核对它算的是不是我们要的那个周期。
func lbStatsPeriodKey(fromTS int64, kind calendarDigestKind) string {
	t := time.Unix(fromTS, 0).UTC()
	if kind == calendarDigestYearly {
		return t.Format("2006")
	}
	return t.Format("2006-01")
}

// lbStatsMaxArtistPages：总播放次数靠把歌手榜翻全再相加，一页 100 位；这是保险丝，不是预期用量。
const lbStatsMaxArtistPages = 30

// lbStatsDigest 用 ListenBrainz 的统计接口取上一个自然月 / 年的统计。ready=false 表示统计还没
// 算到这个周期(204 无数据，或 from_ts 对不上 wantKey)，调用方不记为已处理、下次再查。
// 统计接口不给时长，TotalDurationMs 留 0；总播放次数 = 歌手榜全量之和。
func lbStatsDigest(ctx context.Context, root, user string, kind calendarDigestKind, wantKey string) (stats digestStats, ready bool, err error) {
	rng := lbStatsRange(kind)

	type lbArtist struct {
		ArtistName  string `json:"artist_name"`
		ArtistMbid  string `json:"artist_mbid"`
		ListenCount int    `json:"listen_count"`
	}
	var artists []lastfmChartEntry
	for page := 0; page < lbStatsMaxArtistPages; page++ {
		var out struct {
			Payload struct {
				Artists          []lbArtist `json:"artists"`
				FromTS           int64      `json:"from_ts"`
				TotalArtistCount int        `json:"total_artist_count"`
			} `json:"payload"`
		}
		found, err := lbStatsGet(ctx, root, user, "artists", rng, page*100, &out)
		if err != nil {
			return digestStats{}, false, err
		}
		if !found {
			return digestStats{}, false, nil
		}
		if page == 0 && lbStatsPeriodKey(out.Payload.FromTS, kind) != wantKey {
			return digestStats{}, false, nil
		}
		for _, a := range out.Payload.Artists {
			artists = append(artists, lastfmChartEntry{Name: a.ArtistName, PlayCount: a.ListenCount, Mbid: a.ArtistMbid})
			stats.TotalPlays += a.ListenCount
		}
		if len(out.Payload.Artists) == 0 || (page+1)*100 >= out.Payload.TotalArtistCount {
			break
		}
	}
	stats.TopArtists = digestTopArtists(artists)

	var releases struct {
		Payload struct {
			Releases []struct {
				ReleaseName string `json:"release_name"`
				ArtistName  string `json:"artist_name"`
				ListenCount int    `json:"listen_count"`
			} `json:"releases"`
		} `json:"payload"`
	}
	if _, err := lbStatsGet(ctx, root, user, "releases", rng, 0, &releases); err != nil {
		return digestStats{}, false, err
	}
	for _, r := range releases.Payload.Releases {
		if len(stats.TopAlbums) >= digestTopN {
			break
		}
		if strings.TrimSpace(r.ReleaseName) == "" {
			continue
		}
		stats.TopAlbums = append(stats.TopAlbums, digestTally{Name: r.ReleaseName, Sub: r.ArtistName, Count: r.ListenCount})
	}

	var recordings struct {
		Payload struct {
			Recordings []struct {
				TrackName   string `json:"track_name"`
				ArtistName  string `json:"artist_name"`
				ListenCount int    `json:"listen_count"`
			} `json:"recordings"`
		} `json:"payload"`
	}
	if _, err := lbStatsGet(ctx, root, user, "recordings", rng, 0, &recordings); err != nil {
		return digestStats{}, false, err
	}
	for i, r := range recordings.Payload.Recordings {
		if i >= digestTopN {
			break
		}
		stats.TopTracks = append(stats.TopTracks, digestTally{Name: r.TrackName, Sub: r.ArtistName, Count: r.ListenCount})
	}
	return stats, true, nil
}

// lbStatsGet 取一页 ListenBrainz 用户统计。found=false 表示 204(这个范围还没有统计)。
// 统计是公开数据，不带 token。
func lbStatsGet(ctx context.Context, root, user, entity, rng string, offset int, out any) (found bool, err error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	u := fmt.Sprintf("%s/1/stats/user/%s/%s?range=%s&count=100&offset=%d", root, neturl.PathEscape(user), entity, rng, offset)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return false, err
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return false, nil
	}
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("listenbrainz stats status %d", resp.StatusCode)
	}
	return true, json.NewDecoder(resp.Body).Decode(out)
}
