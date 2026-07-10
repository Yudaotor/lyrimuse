// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// weeklyDigestCheckInterval：Last.fm 的图表周边界一周才翻一次，不需要跟 5s 的 poll
// 循环同频去查，省掉绝大多数没意义的 HTTP 调用。
const weeklyDigestCheckInterval = 2 * time.Hour

// weeklyTopN 是推送里各展示几条——Bark 通知要能在锁屏预览里读完，不铺开全量。
const weeklyTopN = 3

// weeklyDigestState 持久化"已推送到哪一周"(该周 to 时间戳)，防重启后重复推送同一周。
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
type lastfmChartEntry struct {
	Name, Artist string // Artist 对歌手榜自身为空
	PlayCount    int
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

// weeklyDigestPush 拼标题/正文并推 Bark。total 是本周全部 scrobble 数(= 各歌曲
// playcount 之和，图表接口一次请求已是全量、不受 top-N 截断影响)。
func weeklyDigestPush(a *alerter, from, to int64, tracks, artists []lastfmChartEntry) {
	total := 0
	for _, t := range tracks {
		total += t.PlayCount
	}
	title := fmt.Sprintf("🎵 上周听歌小结（%s~%s）",
		time.Unix(from, 0).Local().Format("01-02"), time.Unix(to, 0).Local().Format("01-02"))

	var b strings.Builder
	fmt.Fprintf(&b, "共播放 %d 次\n", total)
	if len(artists) > 0 {
		b.WriteString("\nTop 歌手：\n")
		for i, a := range artists {
			if i >= weeklyTopN {
				break
			}
			fmt.Fprintf(&b, "%d. %s（%d）\n", i+1, a.Name, a.PlayCount)
		}
	}
	if len(tracks) > 0 {
		b.WriteString("\nTop 歌曲：\n")
		for i, t := range tracks {
			if i >= weeklyTopN {
				break
			}
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Artist, t.Name, t.PlayCount)
		}
	}
	a.push(title, strings.TrimRight(b.String(), "\n"))
}

// weeklyDigest 检查(至多每 weeklyDigestCheckInterval 一次)Last.fm 有没有收官一个还
// 没推送过的新周，有就拉排行推一条 Bark。复用桥接(bridge)已有的 lastfm_user/
// lastfm_api_key——同一个 Last.fm 账号，没必要为这个功能再加一套凭证；bark_url 未配
// 则整体跳过(alerter.push 本身也会在 url 为空时忽略,这里提前判断纯粹省一次网络请求)。
func (p *poller) weeklyDigest(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.LastfmAPIKey == "" || p.lb.alerter == nil || p.lb.alerter.url == "" {
		return
	}
	if !p.weeklyLastCheckedAt.IsZero() && now.Sub(p.weeklyLastCheckedAt) < weeklyDigestCheckInterval {
		return
	}
	p.weeklyLastCheckedAt = now

	weeks, err := lastfmWeeklyChartList(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey)
	if err != nil || len(weeks) == 0 {
		return
	}
	latest := weeks[len(weeks)-1]
	if latest.To > now.Unix() || latest.To <= p.weeklyState.load() {
		return // 这周还没收官，或者已经推送过了
	}

	tracks, err := lastfmWeeklyTopTracks(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey, latest.From, latest.To)
	if err != nil {
		return
	}
	artists, err := lastfmWeeklyTopArtists(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey, latest.From, latest.To)
	if err != nil {
		return
	}
	if len(tracks) == 0 {
		p.weeklyState.save(latest.To) // 这周确实没听，跳过不推送，但仍标记已处理，避免下次重查同一周
		return
	}
	weeklyDigestPush(p.lb.alerter, latest.From, latest.To, tracks, artists)
	p.weeklyState.save(latest.To)
}
