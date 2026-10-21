package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	neturl "net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 听歌报告在三份榜单之外多写的几样:跟上一期比、新听的歌手、听了多久(Last.fm 源估算),以及按平台排版要用的头号专辑
// 封面和「点开看完整榜单」的地址。都是锦上添花:哪一样取不到(接口出错、数据不全)就不写那一句,报告照推。
// 见 15 章决策 75。

// digestPeriod 是一期报告的时间范围 [from, to) 和拿来比的上一期 [prevFrom, prevTo)(零值 = 不比,日报就不比)。
// prevLabel 是正文里怎么叫上一期。statsAPI:ListenBrainz 这一期走的是统计接口(月报、年报),手上没有逐条收听记录。
type digestPeriod struct {
	from, to         time.Time
	prevFrom, prevTo time.Time
	prevLabel        string
	statsAPI         bool
	lbRange          string // ListenBrainz 统计接口的 range(week / month / year),拼链接、取上一期用
}

// dailyDigestPeriod:日报不跟前一天比 —— 每天波动太大,天天看到「↓50%」没意义。
func dailyDigestPeriod(from, to time.Time) digestPeriod {
	return digestPeriod{from: from, to: to}
}

// weeklyDigestPeriod:跟前一周比。报告本身叫「上周听歌小结」,拿来比的那周叫「前一周」,不叫「上周」。
func weeklyDigestPeriod(from, to int64) digestPeriod {
	f, t := time.Unix(from, 0), time.Unix(to, 0)
	return digestPeriod{from: f, to: t, prevFrom: f.Add(-t.Sub(f)), prevTo: f, prevLabel: "前一周", lbRange: "week"}
}

// calendarDigestPeriod:月报跟再上一个月比(写「9 月」,跨年写「2025 年 12 月」),年报跟再上一年比(「2025 年」)。
// 写具体月份、年份而不写「上月」,理由同 calendarDigestTitle。
func calendarDigestPeriod(kind calendarDigestKind, from, to time.Time, lbStats bool) digestPeriod {
	p := digestPeriod{from: from, to: to, prevTo: from, statsAPI: lbStats, lbRange: lbStatsRange(kind)}
	if kind == calendarDigestYearly {
		p.prevFrom = from.AddDate(-1, 0, 0)
		p.prevLabel = fmt.Sprintf("%d 年", p.prevFrom.Year())
		return p
	}
	p.prevFrom = from.AddDate(0, -1, 0)
	p.prevLabel = fmt.Sprintf("%d 月", int(p.prevFrom.Month()))
	if p.prevFrom.Year() != from.Year() {
		p.prevLabel = fmt.Sprintf("%d 年 %d 月", p.prevFrom.Year(), int(p.prevFrom.Month()))
	}
	return p
}

// addDigestExtras 给已经取好三份榜单的 stats 补上面那几样。只在要推的时候调(TotalPlays > 0)。
func addDigestExtras(env digestEnv, source string, p digestPeriod, stats *digestStats, now time.Time) {
	stats.Source = source
	stats.From = p.from.Format(time.DateOnly)
	stats.To = p.to.Add(-time.Second).Format(time.DateOnly)
	switch source {
	case digestSourceLastfm:
		lastfmDigestExtras(env.ctx, env.cfg.LastfmUser, env.cfg.lastfmBridgeAPIKey(), p, stats, now)
	case digestSourceListenBrainz:
		lbDigestExtras(env.ctx, env.lbRoot, env.cfg.User, p, stats, now)
	}
}

// newArtistNamesMax:「新听了 N 位歌手」后面点名几位。一周新听几十位很常见(随机播放带出来的居多),只点这期听得最多的几位。
const newArtistNamesMax = 3

func lastfmDigestExtras(ctx context.Context, user, apiKey string, p digestPeriod, stats *digestStats, now time.Time) {
	if !p.prevFrom.IsZero() {
		if prev, err := lastfmWeeklyTopArtists(ctx, user, apiKey, p.prevFrom.Unix(), p.prevTo.Unix()); err != nil {
			slog.Info("digest extras: previous period unavailable", "source", "lastfm", "err", err)
		} else if n := chartPlays(prev); n > 0 {
			stats.PrevPlays, stats.PrevLabel = n, p.prevLabel
		}
	}
	if snap, err := lastfmArtistTotals(ctx, user, apiKey, p.from, now); err != nil {
		slog.Info("digest extras: artist totals unavailable", "source", "lastfm", "err", err)
	} else if window, err := lastfmWeeklyTopArtists(ctx, user, apiKey, p.from.Unix(), snap.At); err != nil {
		slog.Info("digest extras: artist window unavailable", "source", "lastfm", "err", err)
	} else {
		stats.NewArtists, stats.NewArtistNames = newArtistsAgainstSnapshot(stats.chartArtists, window, snap.Counts)
	}
	if stats.TotalDurationMs == 0 {
		if ms, ok := lastfmEstimateDuration(stats.chartTracks, stats.TotalPlays, lastfmCatalogDurations()); ok {
			stats.TotalDurationMs, stats.DurationEstimated = ms, true
		}
	}
	if len(stats.TopAlbums) > 0 {
		if cover, err := lastfmAlbumCover(ctx, apiKey, stats.TopAlbums[0].Sub, stats.TopAlbums[0].Name); err != nil {
			slog.Info("digest extras: album cover unavailable", "source", "lastfm", "err", err)
		} else {
			stats.CoverURL = cover
		}
	}
	stats.Link = fmt.Sprintf("https://www.last.fm/user/%s/library/artists?from=%s&to=%s", neturl.PathEscape(user), stats.From, stats.To)
}

func chartPlays(entries []lastfmChartEntry) int {
	n := 0
	for _, e := range entries {
		n += e.PlayCount
	}
	return n
}

// newArtistsAgainstSnapshot 判这一期哪些歌手是新听的。snapshot 是某一刻(snap.At)这个账号每位歌手的累计次数,
// window 是这一期开头到那一刻之间每位歌手的次数:累计次数不超过窗口里的次数,就是说这一期之前一次都没听过。
// 窗口必须跟快照同一时刻收尾,不能用「到现在」—— 快照之后又听了几次的老歌手会被当成新的。
// 同一个人的不同写法先按歌手榜那套键归并(artistMergeNameKeyCached),不会把「Eric Chou」当成新人。
func newArtistsAgainstSnapshot(period, window []lastfmChartEntry, snapshot map[string]int) (int, []string) {
	windowByKey := map[string]int{}
	for _, e := range window {
		windowByKey[artistMergeNameKeyCached(e.Name)] += e.PlayCount
	}
	totalByKey := map[string]int{}
	for name, n := range snapshot {
		totalByKey[artistMergeNameKeyCached(name)] += n
	}
	type cand struct {
		name  string
		plays int
	}
	var order []string
	byKey := map[string]*cand{}
	for _, e := range period {
		k := artistMergeNameKeyCached(e.Name)
		if c, ok := byKey[k]; ok {
			c.plays += e.PlayCount
			continue
		}
		byKey[k] = &cand{name: artistMergeDisplayNameCached(e.Name), plays: e.PlayCount}
		order = append(order, k)
	}
	var fresh []cand
	for _, k := range order {
		if totalByKey[k] <= windowByKey[k] {
			fresh = append(fresh, *byKey[k])
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool { return fresh[i].plays > fresh[j].plays })
	var names []string
	for i := 0; i < len(fresh) && i < newArtistNamesMax; i++ {
		names = append(names, fresh[i].name)
	}
	return len(fresh), names
}

// lastfmEstimateDurationMinShare:查得到时长的播放至少占这么多才估,不然一个平均数撑起整个总时长,偏差太大。
const lastfmEstimateDurationMinShare = 0.3

// lastfmEstimateDuration 估 Last.fm 源这一期听了多久:榜单里查得到编目时长的曲目按真实时长 × 次数加,查不到的按这期查得到的
// 平均每次时长补到 totalPlays。Last.fm 的榜单接口不给时长,逐首调 track.getInfo 一首要两秒多(一周几百首),不现实;
// 时长取本机 Last.fm 编目缓存里已有的(上送前判写法时查过的那些,lastfmCatalogDurations),一个请求都不发。
func lastfmEstimateDuration(tracks []lastfmChartEntry, totalPlays int, durations map[string]int) (int64, bool) {
	var knownMs, knownPlays, chartPlays int64
	for _, t := range tracks {
		chartPlays += int64(t.PlayCount)
		if d := durations[catalogDurationKey(t.Artist, t.Name)]; d > 0 {
			knownMs += int64(d) * int64(t.PlayCount)
			knownPlays += int64(t.PlayCount)
		}
	}
	if knownPlays == 0 || float64(knownPlays) < float64(chartPlays)*lastfmEstimateDurationMinShare {
		return 0, false
	}
	return knownMs * int64(totalPlays) / knownPlays, true
}

func catalogDurationKey(artist, track string) string {
	return strings.ToLower(strings.TrimSpace(artist)) + "\n" + strings.ToLower(strings.TrimSpace(track))
}

// lastfmCatalogDurations 读本机 Last.fm 编目缓存(lastfmCatalogPath),按「歌手\n曲名」(小写)给出编目时长(毫秒)。
// 一首歌能被几种写法查到:缓存键(播放器报的)、判定后提交的写法、应答里条目自己的写法 —— 榜单里出现的是提交上去的那种。
// 只读文件,不碰匹配器在内存里的那份(那份在主循环上用,这里在报告的 goroutine 里)。
func lastfmCatalogDurations() map[string]int {
	out := map[string]int{}
	if lastfmCatalogPath == "" {
		return out
	}
	b, err := os.ReadFile(lastfmCatalogPath)
	if err != nil {
		noteFileErr("read", lastfmCatalogPath, err)
		return out
	}
	var cache map[string]lastfmCatalogDecision
	if json.Unmarshal(b, &cache) != nil {
		return out
	}
	for key, d := range cache {
		probe := d.Own
		if d.Chosen != nil && d.Chosen.DurationMS > 0 {
			probe = d.Chosen
		}
		if probe == nil || probe.DurationMS <= 0 {
			continue
		}
		add := func(artist, track string) {
			if artist != "" && track != "" {
				out[catalogDurationKey(artist, track)] = probe.DurationMS
			}
		}
		if a, t, ok := strings.Cut(key, "\n"); ok {
			add(a, t)
		}
		add(d.Artist, d.Track)
		add(probe.Artist, probe.Name)
	}
	return out
}

// lastfmPlaceholderImage:Last.fm 没有图时给的那张灰色星星占位图(文件名固定)。
const lastfmPlaceholderImage = "2a96cbd8b46e442fc41c2b86b821562f"

// lastfmAlbumCover 取一张专辑在 Last.fm 上的封面(最大的那个尺寸),地址在 Last.fm 的公网图床上,推送平台能直接拉。
// 歌手图不用:Last.fm 从 2019 年起歌手图全是占位图。
func lastfmAlbumCover(ctx context.Context, apiKey, artist, album string) (string, error) {
	var out struct {
		Album struct {
			Image []struct {
				URL string `json:"#text"`
			} `json:"image"`
		} `json:"album"`
	}
	params := neturl.Values{"method": {"album.getInfo"}, "api_key": {apiKey}, "artist": {artist}, "album": {album}, "autocorrect": {"1"}}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return "", err
	}
	for i := len(out.Album.Image) - 1; i >= 0; i-- {
		if u := out.Album.Image[i].URL; strings.HasPrefix(u, "https://") && !strings.Contains(u, lastfmPlaceholderImage) {
			return u, nil
		}
	}
	return "", nil
}

// caaCoverURL:ListenBrainz 匹配到的专辑在 Cover Art Archive 上的封面(500 像素那一档)。没匹配上返回空。
func caaCoverURL(releaseMBID string, caaID int64) string {
	if releaseMBID == "" || caaID == 0 {
		return ""
	}
	return fmt.Sprintf("https://coverartarchive.org/release/%s/%d-500.jpg", releaseMBID, caaID)
}

// ---- 账号的歌手累计次数快照(判新听的歌手用) ----

// artistTotalsSnapshot:某一刻一个账号每位歌手的累计播放次数(歌手写法 → 次数,原样存,归并在用的时候做)。
// At 是这份数截止的时刻:Last.fm 是取的那一刻,ListenBrainz 是它统计算到的 to_ts(统计每天才重算,常落后一两天)。
type artistTotalsSnapshot struct {
	User    string         `json:"user"`
	At      int64          `json:"at"`
	Fetched int64          `json:"fetched"`
	Counts  map[string]int `json:"counts"`
}

// artistTotalsMaxAge:ListenBrainz 快照多久重取一次。它自己一天才重算,取得再勤也是同一份。
const artistTotalsMaxAge = 20 * time.Hour

var (
	artistTotalsPath string // setDigestExtrasPaths 设;空 = 不落盘(单测)
	artistTotalsMu   sync.Mutex
)

func setDigestExtrasPaths() {
	artistTotalsPath = configFilePath(clientName + "-digest-artist-totals.json")
}

func loadArtistTotals(source string) (artistTotalsSnapshot, bool) {
	if artistTotalsPath == "" {
		return artistTotalsSnapshot{}, false
	}
	b, err := os.ReadFile(artistTotalsPath)
	if err != nil {
		noteFileErr("read", artistTotalsPath, err)
		return artistTotalsSnapshot{}, false
	}
	var all map[string]artistTotalsSnapshot
	if json.Unmarshal(b, &all) != nil {
		return artistTotalsSnapshot{}, false
	}
	s, ok := all[source]
	return s, ok
}

func saveArtistTotals(source string, snap artistTotalsSnapshot) {
	if artistTotalsPath == "" {
		return
	}
	all := map[string]artistTotalsSnapshot{}
	if b, err := os.ReadFile(artistTotalsPath); err == nil {
		_ = json.Unmarshal(b, &all)
	} else {
		noteFileErr("read", artistTotalsPath, err)
	}
	all[source] = snap
	if b, err := json.Marshal(all); err == nil {
		_ = writeFileAtomic(artistTotalsPath, b)
	}
}

// lastfmArtistTotalsMaxPages:user.getTopArtists 一页 1000 位,翻这么多页还没翻完就不判了(判不全会把老歌手当成新的)。
const lastfmArtistTotalsMaxPages = 20

// lastfmArtistTotals:Last.fm 账号全部歌手的累计次数。快照截止时刻必须不早于这一期的开头(from),否则这一期开头之前、
// 快照之后才第一次听的歌手分不清,所以每天的日报基本都会重取一次(1,500 位左右是 2 页、10 秒上下),周报、月报跟着用。
func lastfmArtistTotals(ctx context.Context, user, apiKey string, from, now time.Time) (artistTotalsSnapshot, error) {
	artistTotalsMu.Lock()
	defer artistTotalsMu.Unlock()
	if s, ok := loadArtistTotals(digestSourceLastfm); ok && s.User == user && s.At >= from.Unix() && s.At <= now.Unix() {
		return s, nil
	}
	snap := artistTotalsSnapshot{User: user, At: now.Unix(), Fetched: now.Unix(), Counts: map[string]int{}}
	for page := 1; ; page++ {
		if page > lastfmArtistTotalsMaxPages {
			return artistTotalsSnapshot{}, fmt.Errorf("more than %d pages of artists", lastfmArtistTotalsMaxPages)
		}
		var out struct {
			TopArtists struct {
				Artist []struct {
					Name      string `json:"name"`
					PlayCount string `json:"playcount"`
				} `json:"artist"`
				Attr struct {
					TotalPages string `json:"totalPages"`
				} `json:"@attr"`
			} `json:"topartists"`
		}
		params := neturl.Values{"method": {"user.getTopArtists"}, "user": {user}, "api_key": {apiKey},
			"period": {"overall"}, "limit": {"1000"}, "page": {strconv.Itoa(page)}}
		if err := lastfmAPIGetTimeout(ctx, params, &out, 20*time.Second); err != nil {
			return artistTotalsSnapshot{}, err
		}
		for _, a := range out.TopArtists.Artist {
			pc, _ := strconv.Atoi(a.PlayCount)
			snap.Counts[a.Name] += pc
		}
		total, _ := strconv.Atoi(out.TopArtists.Attr.TotalPages)
		if page >= total || len(out.TopArtists.Artist) == 0 {
			break
		}
	}
	saveArtistTotals(digestSourceLastfm, snap)
	return snap, nil
}

// lbArtistTotalsMaxPages:统计接口一页 100 位。
const lbArtistTotalsMaxPages = 100

// lbArtistTotals:ListenBrainz 账号全部歌手的累计次数(统计接口 all_time),At 是统计算到的 to_ts。
func lbArtistTotals(ctx context.Context, root, user string, now time.Time) (artistTotalsSnapshot, error) {
	artistTotalsMu.Lock()
	defer artistTotalsMu.Unlock()
	if s, ok := loadArtistTotals(digestSourceListenBrainz); ok && s.User == user && now.Sub(time.Unix(s.Fetched, 0)) < artistTotalsMaxAge {
		return s, nil
	}
	snap := artistTotalsSnapshot{User: user, Fetched: now.Unix(), Counts: map[string]int{}}
	for page := 0; ; page++ {
		if page >= lbArtistTotalsMaxPages {
			return artistTotalsSnapshot{}, fmt.Errorf("more than %d pages of artists", lbArtistTotalsMaxPages)
		}
		var out struct {
			Payload struct {
				Artists []struct {
					ArtistName  string `json:"artist_name"`
					ListenCount int    `json:"listen_count"`
				} `json:"artists"`
				ToTS             int64 `json:"to_ts"`
				TotalArtistCount int   `json:"total_artist_count"`
			} `json:"payload"`
		}
		found, err := lbStatsGet(ctx, root, user, "artists", "all_time", page*100, &out)
		if err != nil {
			return artistTotalsSnapshot{}, err
		}
		if !found {
			return artistTotalsSnapshot{}, fmt.Errorf("no all-time artist stats yet")
		}
		if page == 0 {
			snap.At = out.Payload.ToTS
		}
		for _, a := range out.Payload.Artists {
			snap.Counts[a.ArtistName] += a.ListenCount
		}
		if len(out.Payload.Artists) == 0 || (page+1)*100 >= out.Payload.TotalArtistCount {
			break
		}
	}
	saveArtistTotals(digestSourceListenBrainz, snap)
	return snap, nil
}

// ---- ListenBrainz ----

func lbDigestExtras(ctx context.Context, root, user string, p digestPeriod, stats *digestStats, now time.Time) {
	if !p.prevFrom.IsZero() {
		if p.statsAPI {
			if n, err := lbActivityPlays(ctx, root, user, p); err != nil {
				slog.Info("digest extras: previous period unavailable", "source", "listenbrainz", "err", err)
			} else if n > 0 {
				stats.PrevPlays, stats.PrevLabel = n, p.prevLabel
			}
		} else if prev, truncated, err := lbListensInRange(ctx, root, user, p.prevFrom.Unix(), p.prevTo.Unix()); err != nil {
			slog.Info("digest extras: previous period unavailable", "source", "listenbrainz", "err", err)
		} else if !truncated && len(prev) > 0 {
			stats.PrevPlays, stats.PrevLabel = len(prev), p.prevLabel
		}
	}
	// 月报、年报手上没有逐条记录,判不了哪些是这一期才第一次听的,不写这一句。
	if !p.statsAPI && !stats.Truncated {
		if n, names, err := lbNewArtists(ctx, root, user, p, stats.listens, now); err != nil {
			slog.Info("digest extras: new artists unavailable", "source", "listenbrainz", "err", err)
		} else {
			stats.NewArtists, stats.NewArtistNames = n, names
		}
	}
	if stats.CoverURL == "" && len(stats.TopAlbums) > 0 {
		stats.CoverURL = lbListensAlbumCover(stats.listens, stats.TopAlbums[0])
	}
	stats.Link = lbStatsLink(root, user, p)
}

// lbNewArtists:拿 all_time 统计当快照。统计常落后一两天,快照截止时刻(At)跟这一期开头之间差的那段收听记录另外补:
//   - At 早于这一期开头:补取 [At, from) 的记录,快照 + 这段里都没有的才是新的;
//   - At 落在这一期里:快照里已经含了这一期 At 之前那部分,扣掉以后不剩的是新的;
//   - At 晚于这一期结束:再补取 [to, At),扣掉这一期和这段以后不剩的是新的。
func lbNewArtists(ctx context.Context, root, user string, p digestPeriod, listens []lbListenEntry, now time.Time) (int, []string, error) {
	snap, err := lbArtistTotals(ctx, root, user, now)
	if err != nil {
		return 0, nil, err
	}
	from, to := p.from.Unix(), p.to.Unix()
	var gap []lbListenEntry
	switch {
	case snap.At < from:
		gap, err = lbListensGap(ctx, root, user, snap.At, from)
	case snap.At > to:
		gap, err = lbListensGap(ctx, root, user, to, snap.At)
	}
	if err != nil {
		return 0, nil, err
	}
	n, names := lbNewArtistsFrom(listens, gap, snap.Counts, snap.At, from, to)
	return n, names, nil
}

func lbListensGap(ctx context.Context, root, user string, from, to int64) ([]lbListenEntry, error) {
	gap, truncated, err := lbListensInRange(ctx, root, user, from, to)
	if err != nil {
		return nil, err
	}
	if truncated {
		return nil, fmt.Errorf("too many listens between %d and %d", from, to)
	}
	return gap, nil
}

// lbNewArtistsFrom 是 lbNewArtists 的判定部分,纯函数。gap 是快照截止时刻跟这一期之间补取的那段(见 lbNewArtists)。
func lbNewArtistsFrom(listens, gap []lbListenEntry, snapshot map[string]int, at, from, to int64) (int, []string) {
	old := map[string]int{}
	for name, n := range snapshot {
		old[artistMergeNameKeyCached(name)] += n
	}
	switch {
	case at < from:
		for _, l := range gap {
			old[artistMergeNameKeyCached(l.Artist)]++
		}
	case at > to:
		for _, l := range gap {
			old[artistMergeNameKeyCached(l.Artist)]--
		}
		for _, l := range listens {
			old[artistMergeNameKeyCached(l.Artist)]--
		}
	default:
		for _, l := range listens {
			if l.ListenedAt <= at {
				old[artistMergeNameKeyCached(l.Artist)]--
			}
		}
	}
	// 按这期次数排,同次数按第一次出现的先后。
	var order []string
	plays, display := map[string]int{}, map[string]string{}
	for i := len(listens) - 1; i >= 0; i-- { // 收听记录是新的在前,倒着走才是先后顺序
		k := artistMergeNameKeyCached(listens[i].Artist)
		if _, seen := plays[k]; !seen {
			order = append(order, k)
			display[k] = artistMergeDisplayNameCached(listens[i].Artist)
		}
		plays[k]++
	}
	var fresh []string
	for _, k := range order {
		if old[k] <= 0 {
			fresh = append(fresh, k)
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool { return plays[fresh[i]] > plays[fresh[j]] })
	var names []string
	for i := 0; i < len(fresh) && i < newArtistNamesMax; i++ {
		names = append(names, display[fresh[i]])
	}
	return len(fresh), names
}

// lbListensAlbumCover:头号专辑那几条收听记录里第一条带封面的。
func lbListensAlbumCover(listens []lbListenEntry, top digestTally) string {
	for _, l := range listens {
		if l.CoverURL != "" && strings.TrimSpace(l.Release) == top.Name && artistMergeDisplayNameCached(l.Artist) == top.Sub {
			return l.CoverURL
		}
	}
	return ""
}

// lbActivityPlays:月报、年报的上一期次数,取统计接口的 listening-activity(month 给上两个月的逐日数、year 给上两年的逐月数),
// 把落在上一期里的加起来。统计按 UTC 切,跟本地边界差几个小时,同 lbStatsDigest。上一期没有被完整覆盖就不比。
func lbActivityPlays(ctx context.Context, root, user string, p digestPeriod) (int, error) {
	var out struct {
		Payload struct {
			Activity []struct {
				FromTS      int64 `json:"from_ts"`
				ListenCount int   `json:"listen_count"`
			} `json:"listening_activity"`
		} `json:"payload"`
	}
	found, err := lbStatsGet(ctx, root, user, "listening-activity", p.lbRange, 0, &out)
	if err != nil {
		return 0, err
	}
	if !found {
		return 0, fmt.Errorf("no listening activity yet")
	}
	pf := time.Date(p.prevFrom.Year(), p.prevFrom.Month(), p.prevFrom.Day(), 0, 0, 0, 0, time.UTC).Unix()
	pt := time.Date(p.prevTo.Year(), p.prevTo.Month(), p.prevTo.Day(), 0, 0, 0, 0, time.UTC).Unix()
	n, covered := 0, false
	for _, a := range out.Payload.Activity {
		if a.FromTS <= pf {
			covered = covered || a.FromTS == pf
		}
		if a.FromTS >= pf && a.FromTS < pt {
			n += a.ListenCount
		}
	}
	if !covered {
		return 0, fmt.Errorf("listening activity does not cover the previous period")
	}
	return n, nil
}

// lbStatsLink:点开去 ListenBrainz 网页上看。日报去收听记录页,周、月、年报去对应的统计页(它的 week / month / year 就是
// 上一个整周 / 月 / 年,跟报告是同一期)。只认官方服务器:自建的 API 地址推不出网页地址。
func lbStatsLink(root, user string, p digestPeriod) string {
	u, err := neturl.Parse(root)
	if err != nil || u.Host != "api.listenbrainz.org" {
		return ""
	}
	base := "https://listenbrainz.org/user/" + neturl.PathEscape(user) + "/"
	if p.lbRange == "" {
		return base
	}
	return base + "stats/?range=" + p.lbRange
}
