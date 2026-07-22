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
	"strconv"
	"time"
)

// weeklyDigestCheckInterval：不管走 Last.fm 的图表周边界还是自算的 ISO 周边界，一周
// 才翻一次边界，不需要跟 5s 的 poll 循环同频去查，省掉绝大多数没意义的 HTTP 调用。
const weeklyDigestCheckInterval = 2 * time.Hour

// weeklyDigestState 持久化"已推送到哪一周"(该周结束时刻的时间戳)，防重启后重复推送
// 同一周。Last.fm 源和 ListenBrainz 源共用同一份状态——两条路径都只是"上次报告到的
// 周边界时间戳"，语义一致，没必要分成两份状态各自维护(切换数据源时边界附近可能有一次
// 轻微的重复/遗漏，接受这个小瑕疵，不为这个场景单独加逻辑)。
// 只有单个字段、换周才写一次，不用 dedup.go 那套 tmp+rename 原子写。
type weeklyDigestState struct{ path string }

func (s weeklyDigestState) load() int64 {
	if s.path == "" {
		return 0
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return 0
	}
	var v struct {
		LastTo int64 `json:"last_to"`
	}
	json.Unmarshal(b, &v)
	return v.LastTo
}

func (s weeklyDigestState) save(lastTo int64) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastTo int64 `json:"last_to"`
	}{lastTo})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

var weeklyDigestPath string

// lastfmChartWeek 是 user.getWeeklyChartList 里的一个已收官周边界(unix 秒)。周长
// 约 7 天，但具体交界的时刻是按账号首次 scrobble 时间定的，不一定是周一/零点——直接
// 用 Last.fm 自己给的边界，跟网站上看到的"这周"对得上，不用自己按周一算。
type lastfmChartWeek struct{ From, To int64 }

// lastfmChartEntry 是某一周里的一条排行(歌曲或歌手)，只留展示要用的字段。
// Mbid(MusicBrainz ID)只有 topartists.go 的 lastfmTopArtists 会填,weekly.go 这边的
// 两个 lastfmWeeklyTop* 不需要、留空——供 topartists.go 的 mergeAliasedArtists 拿来做
// 除名字之外的第二个"是否同一个人"信号。
type lastfmChartEntry struct {
	Name, Artist string // Artist 对歌手榜自身为空
	PlayCount    int
	Mbid         string
}

func lastfmAPIGet(ctx context.Context, params neturl.Values, out any) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	params.Set("format", "json")
	u := "https://ws.audioscrobbler.com/2.0/?" + params.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lastfm status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// lastfmWeeklyChartList 拉该用户全部已收官的周边界，最旧到最新排列。
func lastfmWeeklyChartList(ctx context.Context, user, apiKey string) ([]lastfmChartWeek, error) {
	var out struct {
		WeeklyChartList struct {
			Chart []struct{ From, To string } `json:"chart"`
		} `json:"weeklychartlist"`
	}
	params := neturl.Values{"method": {"user.getWeeklyChartList"}, "user": {user}, "api_key": {apiKey}}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	weeks := make([]lastfmChartWeek, 0, len(out.WeeklyChartList.Chart))
	for _, c := range out.WeeklyChartList.Chart {
		from, _ := strconv.ParseInt(c.From, 10, 64)
		to, _ := strconv.ParseInt(c.To, 10, 64)
		weeks = append(weeks, lastfmChartWeek{From: from, To: to})
	}
	return weeks, nil
}

// lastfmWeeklyTopTracks/lastfmWeeklyTopArtists 拉指定周边界内的完整排行(该用户单周
// 量级不会触发分页，实测同一账号一周 142 首/14 位歌手，一次请求就是全量)。
func lastfmWeeklyTopTracks(ctx context.Context, user, apiKey string, from, to int64) ([]lastfmChartEntry, error) {
	var out struct {
		WeeklyTrackChart struct {
			Track []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Artist    struct {
					Text string `json:"#text"`
				} `json:"artist"`
			} `json:"track"`
		} `json:"weeklytrackchart"`
	}
	params := neturl.Values{
		"method": {"user.getWeeklyTrackChart"}, "user": {user}, "api_key": {apiKey},
		"from": {strconv.FormatInt(from, 10)}, "to": {strconv.FormatInt(to, 10)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.WeeklyTrackChart.Track))
	for _, t := range out.WeeklyTrackChart.Track {
		pc, _ := strconv.Atoi(t.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: t.Name, Artist: t.Artist.Text, PlayCount: pc})
	}
	return entries, nil
}

func lastfmWeeklyTopArtists(ctx context.Context, user, apiKey string, from, to int64) ([]lastfmChartEntry, error) {
	var out struct {
		WeeklyArtistChart struct {
			Artist []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
			} `json:"artist"`
		} `json:"weeklyartistchart"`
	}
	params := neturl.Values{
		"method": {"user.getWeeklyArtistChart"}, "user": {user}, "api_key": {apiKey},
		"from": {strconv.FormatInt(from, 10)}, "to": {strconv.FormatInt(to, 10)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.WeeklyArtistChart.Artist))
	for _, a := range out.WeeklyArtistChart.Artist {
		pc, _ := strconv.Atoi(a.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: a.Name, PlayCount: pc})
	}
	return entries, nil
}

// mostRecentMonday 返回 t 所在这一周的周一 00:00(本地时间)——ListenBrainz 源的周期
// 边界用这个算，不依赖 Last.fm 账号自己的图表周(那是按首次 scrobble 日期定的、不一定
// 是周一)。Go 的 time.Weekday: Sunday=0,Monday=1,...,Saturday=6，这里把 Sunday 当成 7
// 处理，才能算出"距周一多少天"。
func mostRecentMonday(t time.Time) time.Time {
	wd := int(t.Weekday())
	if wd == 0 {
		wd = 7
	}
	y, m, d := t.Date()
	startOfToday := time.Date(y, m, d, 0, 0, 0, 0, t.Location())
	return startOfToday.AddDate(0, 0, -(wd - 1))
}

// weeklyDigest 检查(至多每 weeklyDigestCheckInterval 一次)是否有一个还没推送过的、
// 已经收官的新周，有就拉统计推一条通知。数据源按 features.WeeklyDigestSource 解析
// (见 digest.go 的 resolveDigestSource)：
//   - Last.fm：周边界用它自己的图表周(lastfmWeeklyChartList，按首次 scrobble 日期定，
//     不一定是周一)——这是原有行为，选这个源时完全不变。
//   - ListenBrainz：没有等价的"图表周"概念，边界改用自算的 ISO 周(周一到下周一，见
//     mostRecentMonday)，取"最近一个已经完整过完的自然周"。
//
// 两条路径共用同一份 weeklyState(见该类型声明处注释)，也共用同一套推送前提检查
// (推送目的地未配置则整体跳过——alerter.push 本身也会在 url 为空时忽略，这里提前
// 判断纯粹省一次网络请求)。
func (p *poller) weeklyDigest(now time.Time) {
	if !features.WeeklyDigest || p.lb.alerter == nil || p.lb.alerter.url == "" {
		return
	}
	if !p.weeklyLastCheckedAt.IsZero() && now.Sub(p.weeklyLastCheckedAt) < weeklyDigestCheckInterval {
		return
	}
	p.weeklyLastCheckedAt = now

	lastfmConfigured := p.cfg.LastfmUser != "" && p.cfg.LastfmAPIKey != ""
	lbConfigured := p.cfg.User != "" && p.cfg.Token != ""
	source := resolveDigestSource(features.WeeklyDigestSource, lastfmConfigured, lbConfigured)
	if source == "" {
		return // 两个账号都没配，跳过
	}

	var from, to int64
	if source == digestSourceLastfm {
		weeks, err := lastfmWeeklyChartList(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey)
		if err != nil || len(weeks) == 0 {
			return
		}
		latest := weeks[len(weeks)-1]
		if latest.To > now.Unix() {
			return // 这周还没收官
		}
		from, to = latest.From, latest.To
	} else {
		thisMonday := mostRecentMonday(now)
		from, to = thisMonday.AddDate(0, 0, -7).Unix(), thisMonday.Unix()
	}
	if to <= p.weeklyState.load() {
		return // 已经推送过了
	}

	var stats digestStats
	var err error
	if source == digestSourceLastfm {
		stats, err = lastfmDigestStats(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey, from, to)
	} else {
		stats, err = listenbrainzDigestStats(p.ctx, p.lb.root, p.cfg.User, from, to)
	}
	if err != nil {
		return
	}
	if stats.TotalPlays == 0 {
		p.weeklyState.save(to) // 这周确实没听，跳过不推送，但仍标记已处理，避免下次重查同一周
		return
	}
	title := fmt.Sprintf("🎵 上周听歌小结（%s~%s）",
		time.Unix(from, 0).Local().Format("01-02"), time.Unix(to, 0).Local().Format("01-02"))
	digestPush(p.lb.alerter, title, stats)
	p.weeklyState.save(to)
}
