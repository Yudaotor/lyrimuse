package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestDigestSummaryLineComparesWithPreviousPeriod(t *testing.T) {
	cases := []struct {
		stats digestStats
		want  string
	}{
		{digestStats{TotalPlays: 601, PrevPlays: 883, PrevLabel: "前一周"}, "共播放 601 次（前一周 883，↓32%）"},
		{digestStats{TotalPlays: 412, PrevPlays: 368, PrevLabel: "9 月"}, "共播放 412 次（9 月 368，↑12%）"},
		{digestStats{TotalPlays: 100, PrevPlays: 100, PrevLabel: "2025 年"}, "共播放 100 次（2025 年 100，持平）"},
		{digestStats{TotalPlays: 100}, "共播放 100 次"}, // 不比(日报、取不到)
		{digestStats{TotalPlays: 5000, Truncated: true, PrevPlays: 300, PrevLabel: "前一周"}, "共播放 5000 次以上（记录太多，只统计了最近这些）"},
		{digestStats{TotalPlays: 601, PrevPlays: 883, PrevLabel: "前一周", TotalDurationMs: 2523 * 60000, DurationEstimated: true},
			"共播放 601 次（前一周 883，↓32%） · 约 42 小时 3 分"},
	}
	for _, c := range cases {
		if got := digestSummaryLine(c.stats); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
}

func TestDigestNewArtistsLine(t *testing.T) {
	cases := []struct {
		n     int
		names []string
		want  string
	}{
		{44, []string{"Patti LaBelle", "The Crane", "99 God"}, "新听了 44 位歌手：Patti LaBelle、The Crane、99 God 等"},
		{2, []string{"A", "B"}, "新听了 2 位歌手：A、B"},
		{0, nil, ""},
	}
	for _, c := range cases {
		if got := digestNewArtistsLine(digestStats{NewArtists: c.n, NewArtistNames: c.names}); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	body := digestBody(digestStats{TotalPlays: 3, TopArtists: []digestTally{{Name: "A", Count: 2}, {Name: "B", Count: 1}},
		NewArtists: 1, NewArtistNames: []string{"B"}})
	if !strings.HasSuffix(body, "\n\n新听了 1 位歌手：B") {
		t.Errorf("新听的歌手应在正文最后一段: %q", body)
	}
}

// 快照之后又听了几次的老歌手不能算新的:窗口跟快照同一时刻收尾,快照里的累计次数比窗口里多就是以前听过。
func TestNewArtistsAgainstSnapshot(t *testing.T) {
	period := []lastfmChartEntry{{Name: "Alpha", PlayCount: 5}, {Name: "Beta", PlayCount: 2}, {Name: "周杰倫", PlayCount: 3},
		{Name: "Gamma", PlayCount: 1}, {Name: "Delta", PlayCount: 4}, {Name: "Eps", PlayCount: 6}, {Name: "Zeta", PlayCount: 2}}
	window := []lastfmChartEntry{{Name: "Alpha", PlayCount: 5}, {Name: "Beta", PlayCount: 2}, {Name: "周杰倫", PlayCount: 3},
		{Name: "Gamma", PlayCount: 1}, {Name: "Eps", PlayCount: 1}, {Name: "Zeta", PlayCount: 2}}
	snapshot := map[string]int{
		"Alpha": 5,  // 全部都在这一期里 → 新
		"Beta":  9,  // 以前听过 → 老
		"周杰伦":   40, // 繁简归并成同一个人,以前听过 → 老
		"Gamma": 1,  // 新
		// Delta 不在快照里:快照之后才第一次听 → 新
		"Eps":  1, // 快照前只在这一期里听过 1 次,之后又听了 5 次 → 新
		"Zeta": 2, // 新
	}
	n, names := newArtistsAgainstSnapshot(period, window, snapshot)
	if n != 5 || !reflect.DeepEqual(names, []string{"Eps", "Alpha", "Delta"}) {
		t.Errorf("n=%d names=%v, 要 5 位、按这期次数点名前 3 位", n, names)
	}
	// 快照里的次数比窗口多(这一期之前听过)→ 不算新。
	snapshot["Eps"] = 3
	if n, _ := newArtistsAgainstSnapshot(period, window, snapshot); n != 4 {
		t.Errorf("Eps 以前听过,n=%d", n)
	}
}

func TestLbNewArtistsFrom(t *testing.T) {
	const from, to = 1000, 2000
	listens := []lbListenEntry{ // 新的在前
		{Artist: "B", ListenedAt: 1900}, {Artist: "A", ListenedAt: 1800}, {Artist: "C", ListenedAt: 1500},
		{Artist: "A", ListenedAt: 1200}, {Artist: "B", ListenedAt: 1100},
	}
	t.Run("快照早于这一期:补上中间那段", func(t *testing.T) {
		gap := []lbListenEntry{{Artist: "C", ListenedAt: 950}}
		n, names := lbNewArtistsFrom(listens, gap, map[string]int{"B": 7}, 900, from, to)
		if n != 1 || !reflect.DeepEqual(names, []string{"A"}) {
			t.Errorf("C 在快照和这一期之间听过、B 在快照里,只有 A 是新的: n=%d %v", n, names)
		}
	})
	t.Run("快照落在这一期里:扣掉已经算进去的", func(t *testing.T) {
		// 快照到 1600:含了这一期 1100(B)、1200(A)、1500(C)。B 以前还听过 3 次。
		n, names := lbNewArtistsFrom(listens, nil, map[string]int{"A": 1, "B": 4, "C": 1}, 1600, from, to)
		if n != 2 || !reflect.DeepEqual(names, []string{"A", "C"}) {
			t.Errorf("n=%d %v", n, names)
		}
	})
	t.Run("快照晚于这一期:再扣掉之后那段", func(t *testing.T) {
		gap := []lbListenEntry{{Artist: "A", ListenedAt: 2100}, {Artist: "C", ListenedAt: 2200}}
		n, names := lbNewArtistsFrom(listens, gap, map[string]int{"A": 3, "B": 5, "C": 2}, 2300, from, to)
		if n != 2 || !reflect.DeepEqual(names, []string{"A", "C"}) {
			t.Errorf("B 以前听过 3 次,A、C 是新的: n=%d %v", n, names)
		}
	})
}

func TestLastfmEstimateDuration(t *testing.T) {
	durations := map[string]int{catalogDurationKey("Alpha", "T1"): 240000, catalogDurationKey("beta", "t2"): 180000}
	tracks := []lastfmChartEntry{{Name: "T1", Artist: "Alpha", PlayCount: 5}, {Name: "T2", Artist: "Beta", PlayCount: 5},
		{Name: "T3", Artist: "Gamma", PlayCount: 10}}
	// 查得到的 10 次共 2100 秒,平均 210 秒;总共 20 次 → 4200 秒。大小写不同也认。
	if ms, ok := lastfmEstimateDuration(tracks, 20, durations); !ok || ms != 4200000 {
		t.Errorf("ms=%d ok=%v", ms, ok)
	}
	// 查得到的不到三成就不估。
	tracks[2].PlayCount = 30
	if _, ok := lastfmEstimateDuration(tracks, 40, durations); ok {
		t.Error("查得到的只占 25%,不该估")
	}
}

// 编目缓存里一首歌能被几种写法查到:缓存键、判定后提交的写法、应答里条目自己的写法。
func TestLastfmCatalogDurations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "catalog.json")
	cache := map[string]lastfmCatalogDecision{
		"陶喆\n那个女孩": {Verdict: verdictMatch, Artist: "陶喆", Track: "那個女孩",
			Own: &lastfmCatalogProbe{Found: true}, Chosen: &lastfmCatalogProbe{Found: true, DurationMS: 267000, Artist: "陶喆", Name: "那個女孩"}},
		"Alpha\nT1": {Verdict: verdictKeep, Artist: "Alpha", Track: "T1", Own: &lastfmCatalogProbe{Found: true, DurationMS: 200000}},
		"Beta\nT2":  {Verdict: verdictKeep, Artist: "Beta", Track: "T2", Own: &lastfmCatalogProbe{Found: true}},
	}
	b, _ := json.Marshal(cache)
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	saved := lastfmCatalogPath
	lastfmCatalogPath = path
	t.Cleanup(func() { lastfmCatalogPath = saved })
	got := lastfmCatalogDurations()
	if got[catalogDurationKey("陶喆", "那個女孩")] != 267000 || got[catalogDurationKey("陶喆", "那个女孩")] != 267000 ||
		got[catalogDurationKey("alpha", "t1")] != 200000 {
		t.Errorf("got %v", got)
	}
	if _, ok := got[catalogDurationKey("Beta", "T2")]; ok {
		t.Error("没有时长的不该进来")
	}
}

func TestDigestPeriods(t *testing.T) {
	loc := time.Local
	oct := time.Date(2026, 10, 1, 0, 0, 0, 0, loc)
	p := calendarDigestPeriod(calendarDigestMonthly, oct.AddDate(0, -1, 0), oct, false)
	if p.prevLabel != "8 月" || !p.prevFrom.Equal(time.Date(2026, 8, 1, 0, 0, 0, 0, loc)) || !p.prevTo.Equal(time.Date(2026, 9, 1, 0, 0, 0, 0, loc)) {
		t.Errorf("月报: %+v", p)
	}
	jan := time.Date(2026, 1, 1, 0, 0, 0, 0, loc)
	if p := calendarDigestPeriod(calendarDigestMonthly, jan, jan.AddDate(0, 1, 0), false); p.prevLabel != "2025 年 12 月" {
		t.Errorf("跨年的上一个月要写年份: %q", p.prevLabel)
	}
	if p := calendarDigestPeriod(calendarDigestYearly, jan.AddDate(-1, 0, 0), jan, true); p.prevLabel != "2024 年" || !p.statsAPI || p.lbRange != "year" {
		t.Errorf("年报: %+v", p)
	}
	mon := time.Date(2026, 10, 12, 0, 0, 0, 0, loc)
	w := weeklyDigestPeriod(mon.Unix(), mon.AddDate(0, 0, 7).Unix())
	if w.prevLabel != "前一周" || !w.prevFrom.Equal(mon.AddDate(0, 0, -7)) || !w.prevTo.Equal(mon) {
		t.Errorf("周报: %+v", w)
	}
	if d := dailyDigestPeriod(mon, mon.AddDate(0, 0, 1)); !d.prevFrom.IsZero() || d.prevLabel != "" {
		t.Errorf("日报不比: %+v", d)
	}
}

// Last.fm 源一整套:上一期次数、新听的歌手、封面、链接都补上;快照截止时刻是这一期内的「现在」,窗口取到同一时刻。
func TestLastfmDigestExtras(t *testing.T) {
	routes := chartRoutes()
	routes["user.getTopArtists"] = `{"topartists":{"artist":[{"name":"Alpha","playcount":"5"},{"name":"Beta","playcount":"40"}],"@attr":{"totalPages":"1"}}}`
	routes["album.getInfo"] = `{"album":{"image":[{"#text":"https://lastfm.example/i/u/34s/x.png","size":"small"},{"#text":"https://lastfm.example/i/u/300x300/x.png","size":"extralarge"}]}}`
	f := useFakeLastfmRead(t, routes)
	from := time.Date(2026, 10, 12, 0, 0, 0, 0, time.Local)
	to := from.AddDate(0, 0, 7)
	now := to.Add(90 * time.Minute)
	stats, err := lastfmDigestStats(context.Background(), "some one", "k", from.Unix(), to.Unix())
	if err != nil {
		t.Fatal(err)
	}
	addDigestExtras(lastfmDigestEnv("http://unused"), digestSourceLastfm, weeklyDigestPeriod(from.Unix(), to.Unix()), &stats, now)
	if stats.PrevPlays != 8 || stats.PrevLabel != "前一周" {
		t.Errorf("上一期: %d %q", stats.PrevPlays, stats.PrevLabel)
	}
	if stats.NewArtists != 1 || !reflect.DeepEqual(stats.NewArtistNames, []string{"Alpha"}) {
		t.Errorf("新听的歌手: %d %v", stats.NewArtists, stats.NewArtistNames)
	}
	if stats.CoverURL != "https://lastfm.example/i/u/300x300/x.png" {
		t.Errorf("封面取最大那张: %q", stats.CoverURL)
	}
	if stats.Link != "https://www.last.fm/user/someone/library/artists?from=2026-10-12&to=2026-10-18" || stats.From != "2026-10-12" || stats.To != "2026-10-18" {
		t.Errorf("link=%q from=%q to=%q", stats.Link, stats.From, stats.To)
	}
	var window bool
	for _, q := range f.queries {
		if q.Get("method") == "user.getWeeklyArtistChart" && q.Get("from") == fmt.Sprint(from.Unix()) && q.Get("to") == fmt.Sprint(now.Unix()) {
			window = true
		}
	}
	if !window {
		t.Error("新听的歌手要拿「这一期开头到快照那一刻」的歌手榜比")
	}
}

// 补不上的一样也不耽误推:接口全挂时三样都留空。
func TestLastfmDigestExtrasDegradeQuietly(t *testing.T) {
	useFakeLastfmRead(t, map[string]string{})
	stats := digestStats{TotalPlays: 8, TopAlbums: []digestTally{{Name: "A", Sub: "B", Count: 2}}}
	addDigestExtras(lastfmDigestEnv("http://unused"), digestSourceLastfm, weeklyDigestPeriod(0, 7*86400), &stats, time.Unix(8*86400, 0))
	if stats.PrevPlays != 0 || stats.NewArtists != 0 || stats.CoverURL != "" {
		t.Errorf("%+v", stats)
	}
}

func TestLbActivityPlays(t *testing.T) {
	day := func(y int, m time.Month, d int) int64 { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC).Unix() }
	var items []string
	for d := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC); d.Before(time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)); d = d.AddDate(0, 0, 1) {
		n := 2
		if d.Month() == time.September {
			n = 3
		}
		items = append(items, fmt.Sprintf(`{"from_ts":%d,"listen_count":%d}`, d.Unix(), n))
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.Path, "/listening-activity") || r.URL.Query().Get("range") != "month" {
			t.Errorf("unexpected %s", r.URL)
		}
		fmt.Fprintf(w, `{"payload":{"listening_activity":[%s]}}`, strings.Join(items, ","))
	}))
	t.Cleanup(srv.Close)
	sep := time.Date(2026, 9, 1, 0, 0, 0, 0, time.Local)
	p := calendarDigestPeriod(calendarDigestMonthly, sep, sep.AddDate(0, 1, 0), true)
	if n, err := lbActivityPlays(context.Background(), srv.URL, "u", p); err != nil || n != 62 {
		t.Errorf("8 月 31 天 × 2 = 62: n=%d err=%v", n, err)
	}
	// 统计还没覆盖到上一期开头:不比。
	p.prevFrom = time.Date(2026, 7, 1, 0, 0, 0, 0, time.Local)
	if _, err := lbActivityPlays(context.Background(), srv.URL, "u", p); err == nil {
		t.Errorf("7 月没覆盖到,应报错: %d", day(2026, 7, 1))
	}
}

func TestLbStatsLink(t *testing.T) {
	if got := lbStatsLink("https://api.listenbrainz.org", "a b", weeklyDigestPeriod(0, 1)); got != "https://listenbrainz.org/user/a%20b/stats/?range=week" {
		t.Errorf("got %q", got)
	}
	if got := lbStatsLink("https://api.listenbrainz.org", "u", dailyDigestPeriod(time.Unix(0, 0), time.Unix(1, 0))); got != "https://listenbrainz.org/user/u/" {
		t.Errorf("got %q", got)
	}
	if got := lbStatsLink("https://lb.example.com", "u", weeklyDigestPeriod(0, 1)); got != "" {
		t.Errorf("自建服务器推不出网页地址: %q", got)
	}
}

func TestLbListensCoverFromMapping(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"payload":{"listens":[{"listened_at":150,"track_metadata":{"track_name":"t","artist_name":"A","release_name":"R",`+
			`"mbid_mapping":{"caa_release_mbid":"rel-1","caa_id":42}}}]}}`)
	}))
	t.Cleanup(srv.Close)
	listens, _, err := lbListensInRange(context.Background(), srv.URL, "u", 100, 200)
	if err != nil || len(listens) != 1 || listens[0].CoverURL != "https://coverartarchive.org/release/rel-1/42-500.jpg" {
		t.Fatalf("listens=%+v err=%v", listens, err)
	}
	if got := lbListensAlbumCover(listens, digestTally{Name: "R", Sub: "A"}); got != listens[0].CoverURL {
		t.Errorf("got %q", got)
	}
}
