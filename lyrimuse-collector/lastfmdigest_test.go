package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// Last.fm 只读接口(周榜 / 歌手榜 / recenttracks)的取数,以及挂在它们上面的日报 / 周报 / 月报 /
// Top 歌手推送流程。流程测试断言的是「推了几次、状态记到哪」:判错的代价是重复推送或永久漏推。

// fakeLastfmRead 把 lastfmReadClient 换成按 method 应答的假服务器。routes 里没有的 method 回 500。
type fakeLastfmRead struct {
	mu      sync.Mutex
	routes  map[string]string
	queries []url.Values
}

// useUnthrottledGuard 换一个不限速的出站闸:真实的那个给 Last.fm 每秒 1 个,一组测试要多等几十秒。
func useUnthrottledGuard(t *testing.T) {
	t.Helper()
	saved := hostGuardShared
	t.Cleanup(func() { hostGuardShared = saved })
	hostGuardShared = newHostGuard(time.Now)
	hostGuardShared.rateFor = func(string) hostRate { return hostRate{perSec: 1000, burst: 1000} }
}

func useFakeLastfmRead(t *testing.T, routes map[string]string) *fakeLastfmRead {
	t.Helper()
	useUnthrottledGuard(t)
	f := &fakeLastfmRead{routes: routes}
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	lastfmReadClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		f.mu.Lock()
		f.queries = append(f.queries, q)
		body, ok := f.routes[q.Get("method")]
		f.mu.Unlock()
		if body == "network" {
			return nil, errors.New("connection reset by peer")
		}
		status := 200
		if !ok {
			status, body = 500, `{"error":8,"message":"backend"}`
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})}
	return f
}

func (f *fakeLastfmRead) query(method string) (url.Values, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, q := range f.queries {
		if q.Get("method") == method {
			return q, true
		}
	}
	return nil, false
}

func (f *fakeLastfmRead) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.queries)
}

const (
	sampleTrackChart  = `{"weeklytrackchart":{"track":[{"name":"T1","playcount":"5","artist":{"#text":"Alpha"}},{"name":"T2","playcount":"3","artist":{"#text":"Beta"}}]}}`
	sampleArtistChart = `{"weeklyartistchart":{"artist":[{"name":"Alpha","playcount":"5"},{"name":"Beta","playcount":"3"}]}}`
	sampleAlbumChart  = `{"weeklyalbumchart":{"album":[{"name":"Album A","playcount":"4","artist":{"#text":"Alpha"}}]}}`
	emptyTrackChart   = `{"weeklytrackchart":{"track":[]}}`
	emptyArtistChart  = `{"weeklyartistchart":{"artist":[]}}`
	emptyAlbumChart   = `{"weeklyalbumchart":{"album":[]}}`
)

func chartRoutes() map[string]string {
	return map[string]string{
		"user.getWeeklyTrackChart":  sampleTrackChart,
		"user.getWeeklyArtistChart": sampleArtistChart,
		"user.getWeeklyAlbumChart":  sampleAlbumChart,
	}
}

func lastfmDigestEnv(pushURL string) digestEnv {
	return digestEnv{
		ctx:     context.Background(),
		cfg:     &config{LastfmUser: "someone", LastfmAPIKey: "read-key"},
		alerter: newAlerter(platformBark, pushURL, "", "", ""),
	}
}

// rejectingSink 收到推送一律回 500,记次数。
func rejectingSink(t *testing.T) (*httptest.Server, *int) {
	t.Helper()
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	return srv, &n
}

func useDigestFeatures(t *testing.T, f featureFlags) {
	t.Helper()
	resetFeaturesForTest(t)
	setFeaturesPath("")
	setFeatures(f)
}

// ---- 取数 ----

func TestLastfmAPIGetSendsFormatAndDecodes(t *testing.T) {
	f := useFakeLastfmRead(t, map[string]string{"user.getWeeklyChartList": `{"weeklychartlist":{"chart":[{"from":"100","to":"200"},{"from":"200","to":"300"}]}}`})
	weeks, err := lastfmWeeklyChartList(context.Background(), "someone", "read-key")
	if err != nil || len(weeks) != 2 || weeks[1] != (lastfmChartWeek{From: 200, To: 300}) {
		t.Fatalf("周边界解析不对: %+v err=%v", weeks, err)
	}
	q, _ := f.query("user.getWeeklyChartList")
	if q.Get("format") != "json" || q.Get("user") != "someone" || q.Get("api_key") != "read-key" {
		t.Errorf("请求参数不对: %v", q)
	}
}

func TestLastfmAPIGetFailures(t *testing.T) {
	useFakeLastfmRead(t, map[string]string{"user.getWeeklyChartList": `not json`, "user.getTopArtists": "network"})
	if _, err := lastfmWeeklyChartList(context.Background(), "u", "k"); err == nil {
		t.Error("响应不是 JSON 应报错")
	}
	if _, err := lastfmWeeklyTopTracks(context.Background(), "u", "k", 1, 2); err == nil {
		t.Error("HTTP 500 应报错")
	}
	if _, err := lastfmTopArtists(context.Background(), "u", "k", 10); err == nil {
		t.Error("网络错误应报错")
	}
}

// 三份榜单:次数是字符串要转数字,曲目 / 专辑带署名歌手,歌手榜自身不带;区间原样传给接口。
func TestLastfmWeeklyChartsParse(t *testing.T) {
	f := useFakeLastfmRead(t, chartRoutes())
	ctx := context.Background()
	tracks, err1 := lastfmWeeklyTopTracks(ctx, "u", "k", 1000, 2000)
	artists, err2 := lastfmWeeklyTopArtists(ctx, "u", "k", 1000, 2000)
	albums, err3 := lastfmWeeklyTopAlbums(ctx, "u", "k", 1000, 2000)
	if err1 != nil || err2 != nil || err3 != nil {
		t.Fatalf("errs: %v %v %v", err1, err2, err3)
	}
	if tracks[0] != (lastfmChartEntry{Name: "T1", Artist: "Alpha", PlayCount: 5}) || len(tracks) != 2 {
		t.Errorf("曲目榜: %+v", tracks)
	}
	if artists[1] != (lastfmChartEntry{Name: "Beta", PlayCount: 3}) {
		t.Errorf("歌手榜: %+v", artists)
	}
	if albums[0] != (lastfmChartEntry{Name: "Album A", Artist: "Alpha", PlayCount: 4}) {
		t.Errorf("专辑榜: %+v", albums)
	}
	for _, m := range []string{"user.getWeeklyTrackChart", "user.getWeeklyArtistChart", "user.getWeeklyAlbumChart"} {
		q, _ := f.query(m)
		if q.Get("from") != "1000" || q.Get("to") != "2000" {
			t.Errorf("%s 区间参数不对: %v", m, q)
		}
	}
}

// 三份里任何一份取不到,整份统计作废(不能拿残缺的数推送)。
func TestLastfmDigestStatsFailsIfAnyChartFails(t *testing.T) {
	for _, missing := range []string{"user.getWeeklyTrackChart", "user.getWeeklyArtistChart", "user.getWeeklyAlbumChart"} {
		routes := chartRoutes()
		delete(routes, missing)
		useFakeLastfmRead(t, routes)
		if _, err := lastfmDigestStats(context.Background(), "u", "k", 1, 2); err == nil {
			t.Errorf("缺 %s 时应报错", missing)
		}
	}
	useFakeLastfmRead(t, chartRoutes())
	stats, err := lastfmDigestStats(context.Background(), "u", "k", 1, 2)
	if err != nil || stats.TotalPlays != 8 || len(stats.TopAlbums) != 1 {
		t.Errorf("三份都在时应拼出统计: %+v err=%v", stats, err)
	}
}

func TestLastfmTopArtistsPeriodParse(t *testing.T) {
	f := useFakeLastfmRead(t, map[string]string{"user.getTopArtists": `{"topartists":{"artist":[{"name":"Alpha","playcount":"50","mbid":"m-1"}]}}`})
	got, err := lastfmTopArtistsPeriod(context.Background(), "u", "k", "7day", 30)
	if err != nil || len(got) != 1 || got[0] != (lastfmChartEntry{Name: "Alpha", PlayCount: 50, Mbid: "m-1"}) {
		t.Fatalf("got %+v err=%v", got, err)
	}
	q, _ := f.query("user.getTopArtists")
	if q.Get("period") != "7day" || q.Get("limit") != "30" {
		t.Errorf("时段 / 条数参数不对: %v", q)
	}
	if _, err := lastfmTopArtists(context.Background(), "u", "k", 10); err != nil {
		t.Fatal(err)
	}
	if q := f.queries[len(f.queries)-1]; q.Get("period") != "overall" {
		t.Errorf("lastfmTopArtists 应固定 overall,got %v", q)
	}
}

func TestLastfmRecentFetch(t *testing.T) {
	useFakeLastfmRead(t, map[string]string{"user.getrecenttracks": `{"recenttracks":{"@attr":{"total":"42"},"track":[` +
		`{"name":"Now","artist":{"#text":"A"},"@attr":{"nowplaying":"true"}},` +
		`{"name":"Done","artist":{"#text":"A"},"album":{"#text":"AL"},"date":{"uts":"1700000000"}}]}}`})
	page, ok := lastfmRecent(context.Background(), "u", "k")
	if !ok || page.Total != 42 || page.NowPlaying == nil || page.NowPlaying.Title != "Now" ||
		len(page.Done) != 1 || page.Done[0].UTS != 1700000000 {
		t.Fatalf("got ok=%v %+v", ok, page)
	}
	useFakeLastfmRead(t, map[string]string{})
	if _, ok := lastfmRecent(context.Background(), "u", "k"); ok {
		t.Error("HTTP 500 应返回 ok=false")
	}
	useFakeLastfmRead(t, map[string]string{"user.getrecenttracks": "not json"})
	if _, ok := lastfmRecent(context.Background(), "u", "k"); ok {
		t.Error("响应解不开应返回 ok=false")
	}
}

// ---- 周报 ----

func weeklyRoutes(latestTo int64) map[string]string {
	routes := chartRoutes()
	routes["user.getWeeklyChartList"] = fmt.Sprintf(`{"weeklychartlist":{"chart":[{"from":"%d","to":"%d"},{"from":"%d","to":"%d"}]}}`,
		latestTo-14*86400, latestTo-7*86400, latestTo-7*86400, latestTo)
	return routes
}

// 最近一个已收官的图表周推一次、记下它的结束时刻;同一周不再推。区间用 Last.fm 自己的周边界。
func TestWeeklyDigestLastfmPushesOncePerWeek(t *testing.T) {
	useDigestFeatures(t, featureFlags{WeeklyDigest: true, WeeklyDigestSource: digestSourceLastfm})
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local)
	to := now.Add(-time.Hour).Unix()
	f := useFakeLastfmRead(t, weeklyRoutes(to))
	sink, n, last := pushSink(t)
	p := &poller{weeklyState: weeklyDigestState{path: filepath.Join(t.TempDir(), "weekly.json")}}

	p.weeklyDigest(now, lastfmDigestEnv(sink.URL))
	if *n != 1 || !strings.Contains(*last, "上周听歌小结") || !strings.Contains(*last, "共播放 8 次") {
		t.Fatalf("应推一次上周小结, n=%d body=%s", *n, *last)
	}
	if p.weeklyState.load() != to {
		t.Errorf("state = %d, want %d", p.weeklyState.load(), to)
	}
	q, _ := f.query("user.getWeeklyTrackChart")
	if q.Get("from") != strconv.FormatInt(to-7*86400, 10) || q.Get("to") != strconv.FormatInt(to, 10) {
		t.Errorf("区间应是最近一个图表周: %v", q)
	}

	p.weeklyLastCheckedAt = time.Time{}
	p.weeklyDigest(now.Add(3*time.Hour), lastfmDigestEnv(sink.URL))
	if *n != 1 {
		t.Errorf("同一周不该再推, got %d", *n)
	}
}

// 两小时内不重查:连接口都不打。
func TestWeeklyDigestThrottlesChecks(t *testing.T) {
	useDigestFeatures(t, featureFlags{WeeklyDigest: true, WeeklyDigestSource: digestSourceLastfm})
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local)
	f := useFakeLastfmRead(t, weeklyRoutes(now.Add(time.Hour).Unix()))
	sink, _, _ := pushSink(t)
	p := &poller{weeklyState: weeklyDigestState{path: filepath.Join(t.TempDir(), "weekly.json")}}
	p.weeklyDigest(now, lastfmDigestEnv(sink.URL))
	before := f.count()
	p.weeklyDigest(now.Add(time.Hour), lastfmDigestEnv(sink.URL))
	if f.count() != before {
		t.Errorf("两小时内不该重查,多打了 %d 次", f.count()-before)
	}
}

func TestWeeklyDigestSkips(t *testing.T) {
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local)
	closed := now.Add(-time.Hour).Unix()
	cases := []struct {
		name      string
		flags     featureFlags
		routes    map[string]string
		pushURL   string
		wantState int64
	}{
		{"开关关着", featureFlags{WeeklyDigest: false}, weeklyRoutes(closed), "sink", 0},
		{"没配推送地址", featureFlags{WeeklyDigest: true}, weeklyRoutes(closed), "", 0},
		{"这周还没收官", featureFlags{WeeklyDigest: true}, weeklyRoutes(now.Add(time.Hour).Unix()), "sink", 0},
		{"取周边界失败", featureFlags{WeeklyDigest: true}, chartRoutes(), "sink", 0},
		{"取榜失败:不记,下次再试", featureFlags{WeeklyDigest: true}, func() map[string]string {
			r := weeklyRoutes(closed)
			delete(r, "user.getWeeklyArtistChart")
			return r
		}(), "sink", 0},
		{"这周没听:不推但记下", featureFlags{WeeklyDigest: true}, func() map[string]string {
			r := weeklyRoutes(closed)
			r["user.getWeeklyTrackChart"], r["user.getWeeklyArtistChart"], r["user.getWeeklyAlbumChart"] = emptyTrackChart, emptyArtistChart, emptyAlbumChart
			return r
		}(), "sink", closed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			c.flags.WeeklyDigestSource = digestSourceLastfm
			useDigestFeatures(t, c.flags)
			useFakeLastfmRead(t, c.routes)
			sink, n, _ := pushSink(t)
			pushURL := c.pushURL
			if pushURL == "sink" {
				pushURL = sink.URL
			}
			p := &poller{weeklyState: weeklyDigestState{path: filepath.Join(t.TempDir(), "weekly.json")}}
			p.weeklyDigest(now, lastfmDigestEnv(pushURL))
			if *n != 0 || p.weeklyState.load() != c.wantState {
				t.Errorf("pushes=%d state=%d, want 0 / %d", *n, p.weeklyState.load(), c.wantState)
			}
		})
	}
}

// 推送被平台拒收:不记已推送,下一轮还会再推。
func TestWeeklyDigestRejectedPushIsRetried(t *testing.T) {
	useDigestFeatures(t, featureFlags{WeeklyDigest: true, WeeklyDigestSource: digestSourceLastfm})
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local)
	useFakeLastfmRead(t, weeklyRoutes(now.Add(-time.Hour).Unix()))
	sink, n := rejectingSink(t)
	p := &poller{weeklyState: weeklyDigestState{path: filepath.Join(t.TempDir(), "weekly.json")}}
	p.weeklyDigest(now, lastfmDigestEnv(sink.URL))
	p.weeklyLastCheckedAt = time.Time{}
	p.weeklyDigest(now.Add(3*time.Hour), lastfmDigestEnv(sink.URL))
	if *n != 2 || p.weeklyState.load() != 0 {
		t.Errorf("被拒收应不记状态、下一轮重推: pushes=%d state=%d", *n, p.weeklyState.load())
	}
}

// ---- 日报 ----

func TestDailyDigestLastfm(t *testing.T) {
	night := time.Date(2026, 9, 25, 22, 30, 0, 0, time.Local)
	midnight := time.Date(2026, 9, 25, 0, 0, 0, 0, time.Local)

	t.Run("22 点前不推也不取数", func(t *testing.T) {
		useDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm})
		f := useFakeLastfmRead(t, chartRoutes())
		sink, n, _ := pushSink(t)
		p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
		p.dailyDigest(night.Add(-time.Hour), lastfmDigestEnv(sink.URL))
		if *n != 0 || f.count() != 0 || p.dailyState.load() != "" {
			t.Errorf("pushes=%d requests=%d state=%q", *n, f.count(), p.dailyState.load())
		}
	})
	t.Run("到点推一次,区间是今天零点到此刻,当天不再推", func(t *testing.T) {
		useDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm})
		f := useFakeLastfmRead(t, chartRoutes())
		sink, n, last := pushSink(t)
		p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
		p.dailyDigest(night, lastfmDigestEnv(sink.URL))
		if *n != 1 || !strings.Contains(*last, "今日听歌报告") || p.dailyState.load() != "2026-09-25" {
			t.Fatalf("pushes=%d state=%q body=%s", *n, p.dailyState.load(), *last)
		}
		q, _ := f.query("user.getWeeklyTrackChart")
		if q.Get("from") != strconv.FormatInt(midnight.Unix(), 10) || q.Get("to") != strconv.FormatInt(night.Unix(), 10) {
			t.Errorf("区间不对: %v", q)
		}
		p.dailyLastCheckedAt = time.Time{}
		p.dailyDigest(night.Add(time.Hour), lastfmDigestEnv(sink.URL))
		if *n != 1 {
			t.Errorf("当天不该再推, got %d", *n)
		}
	})
	t.Run("取数失败不记,推送被拒不记", func(t *testing.T) {
		useDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm})
		useFakeLastfmRead(t, map[string]string{})
		sink, _, _ := pushSink(t)
		p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
		p.dailyDigest(night, lastfmDigestEnv(sink.URL))
		if p.dailyState.load() != "" {
			t.Error("取数失败不该记已推送")
		}
		useFakeLastfmRead(t, chartRoutes())
		rej, n := rejectingSink(t)
		p.dailyLastCheckedAt = time.Time{}
		p.dailyDigest(night, lastfmDigestEnv(rej.URL))
		if *n != 1 || p.dailyState.load() != "" {
			t.Errorf("推送被拒不该记已推送: pushes=%d state=%q", *n, p.dailyState.load())
		}
	})
	t.Run("今天没听:不推但记下", func(t *testing.T) {
		useDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm})
		useFakeLastfmRead(t, map[string]string{"user.getWeeklyTrackChart": emptyTrackChart,
			"user.getWeeklyArtistChart": emptyArtistChart, "user.getWeeklyAlbumChart": emptyAlbumChart})
		sink, n, _ := pushSink(t)
		p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
		p.dailyDigest(night, lastfmDigestEnv(sink.URL))
		if *n != 0 || p.dailyState.load() != "2026-09-25" {
			t.Errorf("pushes=%d state=%q", *n, p.dailyState.load())
		}
	})
}

// ---- 月报(Last.fm 源) ----

// 月报走 Last.fm 时区间是上个自然月的本地边界(ListenBrainz 源另有测试)。
func TestCalendarDigestLastfmUsesLocalMonthBounds(t *testing.T) {
	f := useFakeLastfmRead(t, chartRoutes())
	sink, n, last := pushSink(t)
	p := &poller{monthlyRun: calendarDigestRun{state: calendarDigestState{path: filepath.Join(t.TempDir(), "monthly.json")}}}
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, time.Local)

	p.calendarDigest(now, lastfmDigestEnv(sink.URL), calendarDigestMonthly, &p.monthlyRun, true, digestSourceLastfm)

	if *n != 1 || !strings.Contains(*last, "8 月听歌小结") || p.monthlyRun.state.load() != "2026-08" {
		t.Fatalf("pushes=%d state=%q body=%s", *n, p.monthlyRun.state.load(), *last)
	}
	q, _ := f.query("user.getWeeklyAlbumChart")
	from := time.Date(2026, 8, 1, 0, 0, 0, 0, time.Local).Unix()
	to := time.Date(2026, 9, 1, 0, 0, 0, 0, time.Local).Unix()
	if q.Get("from") != strconv.FormatInt(from, 10) || q.Get("to") != strconv.FormatInt(to, 10) {
		t.Errorf("区间应是 8 月的本地边界: %v", q)
	}
}

// ---- Top 歌手推送 ----

type relaySink struct {
	mu     sync.Mutex
	status int
	paths  []string
	tokens []string
	bodies []string
}

func newRelaySink(t *testing.T, status int) (*httptest.Server, *relaySink) {
	t.Helper()
	s := &relaySink{status: status}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.paths = append(s.paths, r.URL.Path)
		s.tokens = append(s.tokens, r.Header.Get("x-token"))
		s.bodies = append(s.bodies, string(b))
		s.mu.Unlock()
		w.WriteHeader(s.status)
	}))
	t.Cleanup(srv.Close)
	return srv, s
}

// useTopArtistSeams 换掉取头像与后台预热两步(真实实现会打 QQ 音乐 / Deezer / MusicBrainz)。
func useTopArtistSeams(t *testing.T) chan int {
	t.Helper()
	savedAvatar, savedWarm := topArtistAvatar, warmTopArtistIdentities
	t.Cleanup(func() { topArtistAvatar, warmTopArtistIdentities = savedAvatar, savedWarm })
	topArtistAvatar = func(_ context.Context, name string) (string, bool) { return "https://img.test/" + name, true }
	warmed := make(chan int, 1)
	warmTopArtistIdentities = func(entries []lastfmChartEntry, budget int) { warmed <- len(entries) }
	return warmed
}

func topArtistsRoute(n int) map[string]string {
	var items []string
	for i := 0; i < n; i++ {
		items = append(items, fmt.Sprintf(`{"name":"Artist%02d","playcount":"%d","mbid":""}`, i, 100-i))
	}
	return map[string]string{"user.getTopArtists": `{"topartists":{"artist":[` + strings.Join(items, ",") + `]}}`}
}

func topArtistsEnv(relayURL string) digestEnv {
	return digestEnv{ctx: context.Background(), cfg: &config{
		LastfmUser: "someone", LastfmAPIKey: "read-key", StateRelayURL: relayURL, StateRelayToken: "relay-token",
	}}
}

// 取 30 条池子、预热缓存、按名次推前 10 条(带头像)给中继,成功后记下时间。
func TestTopArtistsDigestPushesTopTenInOrder(t *testing.T) {
	warmed := useTopArtistSeams(t)
	f := useFakeLastfmRead(t, topArtistsRoute(12))
	relay, sink := newRelaySink(t, http.StatusOK)
	p := &poller{topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local)

	p.topArtistsDigest(now, topArtistsEnv(relay.URL))

	q, _ := f.query("user.getTopArtists")
	if q.Get("period") != "overall" || q.Get("limit") != strconv.Itoa(topArtistsFetchPool) {
		t.Errorf("应按 overall 取 %d 条池子: %v", topArtistsFetchPool, q)
	}
	select {
	case got := <-warmed:
		if got != 12 {
			t.Errorf("预热应拿到整池 12 条, got %d", got)
		}
	case <-time.After(3 * time.Second):
		t.Error("应起后台预热")
	}
	if len(sink.bodies) != 1 || sink.paths[0] != "/top-artists" || sink.tokens[0] != "relay-token" {
		t.Fatalf("应推一次 /top-artists 且带 token: %v %v", sink.paths, sink.tokens)
	}
	var payload struct {
		Artists   []topArtistEntry `json:"artists"`
		UpdatedAt int64            `json:"updatedAt"`
	}
	if err := json.Unmarshal([]byte(sink.bodies[0]), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Artists) != topArtistsN || payload.UpdatedAt != now.Unix() {
		t.Fatalf("应推 %d 条: %+v", topArtistsN, payload)
	}
	for i, a := range payload.Artists {
		want := fmt.Sprintf("Artist%02d", i)
		if a.Name != want || a.PlayCount != 100-i || a.Avatar != "https://img.test/"+want {
			t.Errorf("第 %d 名不对: %+v", i, a)
		}
	}
	if p.topArtistsState.load() != now.Unix() {
		t.Error("推成功应记下时间")
	}
}

func TestTopArtistsDigestSkips(t *testing.T) {
	now := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local)

	t.Run("没配中继", func(t *testing.T) {
		useTopArtistSeams(t)
		f := useFakeLastfmRead(t, topArtistsRoute(3))
		p := &poller{}
		p.topArtistsDigest(now, topArtistsEnv(""))
		if f.count() != 0 {
			t.Error("没配中继不该取数")
		}
	})
	t.Run("磁盘上一天内推过", func(t *testing.T) {
		useTopArtistSeams(t)
		f := useFakeLastfmRead(t, topArtistsRoute(3))
		relay, _ := newRelaySink(t, http.StatusOK)
		p := &poller{topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
		p.topArtistsState.save(now.Add(-2 * time.Hour).Unix())
		p.topArtistsDigest(now, topArtistsEnv(relay.URL))
		if f.count() != 0 {
			t.Error("重启后一天内不该重算")
		}
	})
	t.Run("中继拒收不记时间", func(t *testing.T) {
		useTopArtistSeams(t)
		useFakeLastfmRead(t, topArtistsRoute(3))
		relay, sink := newRelaySink(t, http.StatusInternalServerError)
		p := &poller{topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
		p.topArtistsDigest(now, topArtistsEnv(relay.URL))
		if len(sink.bodies) != 1 || p.topArtistsState.load() != 0 {
			t.Errorf("推失败不该记时间: pushes=%d state=%d", len(sink.bodies), p.topArtistsState.load())
		}
	})
	t.Run("取榜失败不推", func(t *testing.T) {
		useTopArtistSeams(t)
		useFakeLastfmRead(t, map[string]string{})
		relay, sink := newRelaySink(t, http.StatusOK)
		p := &poller{topArtistsState: topArtistsState{path: filepath.Join(t.TempDir(), "top.json")}}
		p.topArtistsDigest(now, topArtistsEnv(relay.URL))
		if len(sink.bodies) != 0 {
			t.Error("取榜失败不该推")
		}
	})
}

// ---- 头像 ----

// definitive 决定空结果能不能负缓存:两条腿都正常应答说没有才算,任一条暂时故障就不算。
func TestResolveArtistAvatarDefinitive(t *testing.T) {
	leg := func(pic string, def bool) func(string) (string, bool) {
		return func(string) (string, bool) { return pic, def }
	}
	dz := func(pic string, def bool) func(context.Context, string) (string, bool) {
		return func(context.Context, string) (string, bool) { return pic, def }
	}
	cases := []struct {
		name    string
		qq      func(string) (string, bool)
		deezer  func(context.Context, string) (string, bool)
		wantPic string
		wantDef bool
	}{
		{"QQ 有就用 QQ", leg("qq.jpg", true), dz("dz.jpg", true), "qq.jpg", true},
		{"QQ 没有退 Deezer", leg("", true), dz("dz.jpg", true), "dz.jpg", true},
		{"QQ 故障、Deezer 有", leg("", false), dz("dz.jpg", true), "dz.jpg", true},
		{"两边都说没有", leg("", true), dz("", true), "", true},
		{"QQ 故障、Deezer 说没有", leg("", false), dz("", true), "", false},
		{"QQ 说没有、Deezer 故障", leg("", true), dz("", false), "", false},
	}
	for _, c := range cases {
		pic, def := resolveArtistAvatarVia(context.Background(), "X", c.qq, c.deezer)
		if pic != c.wantPic || def != c.wantDef {
			t.Errorf("%s: got (%q,%v), want (%q,%v)", c.name, pic, def, c.wantPic, c.wantDef)
		}
	}
}

func TestDeezerArtistAvatar(t *testing.T) {
	var gotQuery url.Values
	body, status := "", 200
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.Query()
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	saved := deezerArtistSearchURL
	t.Cleanup(func() { deezerArtistSearchURL = saved })
	deezerArtistSearchURL = srv.URL + "/search/artist"

	cases := []struct {
		name, body string
		status     int
		wantPic    string
		wantDef    bool
	}{
		{"找到", `{"data":[{"picture_medium":"https://dz/p.jpg"}]}`, 200, "https://dz/p.jpg", true},
		{"查无此人", `{"data":[]}`, 200, "", true},
		{"服务端出错", `{}`, 500, "", false},
		{"响应解不开", `garbage`, 200, "", false},
	}
	for _, c := range cases {
		body, status = c.body, c.status
		pic, def := deezerArtistAvatar(context.Background(), "周杰倫")
		if pic != c.wantPic || def != c.wantDef {
			t.Errorf("%s: got (%q,%v)", c.name, pic, def)
		}
	}
	if gotQuery.Get("q") != "周杰倫" || gotQuery.Get("limit") != "1" {
		t.Errorf("查询参数不对: %v", gotQuery)
	}
}

// ---- 命令行入口:stdout 那一行 JSON 是 App 解码的契约 ----

// captureStdout 跑 fn,返回它写进 stdout 的内容。
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stdout
	os.Stdout = w
	done := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()
	fn()
	os.Stdout = saved
	w.Close()
	return <-done
}

// useCLIConfigDir 建一个临时配置目录并指过去,还原 CLI 会改写的包级路径与特性开关。
func useCLIConfigDir(t *testing.T, cfg map[string]string) string {
	t.Helper()
	resetFeaturesForTest(t)
	savedLog, savedCatalog, savedNudge := listenLogPath, lastfmCatalogPath, lastfmFeedNudgePath
	t.Cleanup(func() { listenLogPath, lastfmCatalogPath, lastfmFeedNudgePath = savedLog, savedCatalog, savedNudge })
	dir := t.TempDir()
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	return dir
}

func TestBackfillCLIDryRunListsPendingWithoutAccount(t *testing.T) {
	dir := useCLIConfigDir(t, map[string]string{})
	listenLogPath = filepath.Join(dir, clientName+"-listens.jsonl")
	appendListen("Alpha", "Song", "Album", time.Now().Add(-time.Hour).Unix(), 200)

	out := captureStdout(t, func() { runBackfillLastfmCLI([]string{"-dry-run"}) })

	if strings.Count(strings.TrimSpace(out), "\n") != 0 {
		t.Errorf("stdout 只该有一行 JSON: %q", out)
	}
	var got backfillOutcome
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("stdout 不是 JSON: %q", out)
	}
	if got.Eligible != 1 || len(got.Items) != 1 || got.Items[0].Title != "Song" || got.AbortedReason != "" {
		t.Errorf("未连账号的空跑应列出本地待补: %+v", got)
	}
	if lastfmFeedNudgePath != filepath.Join(dir, clientName+"-lastfm-feed-nudge") {
		t.Errorf("feed 信号文件路径应跟常驻进程一致, got %q", lastfmFeedNudgePath)
	}
}

func TestBackfillCLIRealRunNeedsAccount(t *testing.T) {
	useCLIConfigDir(t, map[string]string{})
	out := captureStdout(t, func() { runBackfillLastfmCLI(nil) })
	var got backfillOutcome
	if err := json.Unmarshal([]byte(out), &got); err != nil || got.AbortedReason != "last.fm not connected" {
		t.Errorf("没连账号真跑应报原因: %q err=%v", out, err)
	}
}

// -all-periods:一个时段失败不拖垮其余三个,缺的那档不出现在输出里。
func TestTopArtistsCLIAllPeriodsToleratesOneFailure(t *testing.T) {
	useCLIConfigDir(t, map[string]string{"lastfm_user": "someone", "lastfm_api_key": "read-key"})
	// CLI 会把三份歌手缓存的落盘路径指进临时配置目录(目录里没有缓存文件,缓存内容本身不被替换)。
	savedCacheOnly, savedIdentity, savedAlias, savedQQ := artistCanonicalCacheOnly, artistIdentityPath, artistAliasPath, qqArtistNamePath
	t.Cleanup(func() {
		artistCanonicalCacheOnly, artistIdentityPath, artistAliasPath, qqArtistNamePath = savedCacheOnly, savedIdentity, savedAlias, savedQQ
	})
	route := topArtistsRoute(3)["user.getTopArtists"]
	useUnthrottledGuard(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	lastfmReadClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Query().Get("period") == "1month" {
			return &http.Response{StatusCode: 500, Body: io.NopCloser(strings.NewReader(`{}`)), Header: http.Header{}}, nil
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(route)), Header: http.Header{}}, nil
	})}

	out := captureStdout(t, func() { runTopArtistsCLI([]string{"-all-periods", "-limit", "2"}) })

	var got map[string][]topArtistEntry
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("stdout 不是 JSON: %q", out)
	}
	if _, ok := got["1month"]; ok || len(got) != 3 {
		t.Errorf("失败的那档不该出现、其余三档都在: %v", got)
	}
	if rows := got["7day"]; len(rows) != 2 || rows[0].Name != "Artist00" || rows[0].PlayCount != 100 {
		t.Errorf("每档按 -limit 截断且保持名次: %+v", rows)
	}
}
