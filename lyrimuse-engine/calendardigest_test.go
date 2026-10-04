package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPreviousCalendarPeriod(t *testing.T) {
	loc := time.FixedZone("CST", 8*3600)
	cases := []struct {
		name     string
		now      time.Time
		kind     calendarDigestKind
		from, to time.Time
		key      string
	}{
		{"月中取上个月", time.Date(2026, 9, 24, 21, 0, 0, 0, loc), calendarDigestMonthly,
			time.Date(2026, 8, 1, 0, 0, 0, 0, loc), time.Date(2026, 9, 1, 0, 0, 0, 0, loc), "2026-08"},
		{"一月跨年取去年十二月", time.Date(2026, 1, 3, 9, 0, 0, 0, loc), calendarDigestMonthly,
			time.Date(2025, 12, 1, 0, 0, 0, 0, loc), time.Date(2026, 1, 1, 0, 0, 0, 0, loc), "2025-12"},
		{"月初零点整算新月", time.Date(2026, 10, 1, 0, 0, 0, 0, loc), calendarDigestMonthly,
			time.Date(2026, 9, 1, 0, 0, 0, 0, loc), time.Date(2026, 10, 1, 0, 0, 0, 0, loc), "2026-09"},
		{"年度取上一个自然年", time.Date(2026, 9, 24, 21, 0, 0, 0, loc), calendarDigestYearly,
			time.Date(2025, 1, 1, 0, 0, 0, 0, loc), time.Date(2026, 1, 1, 0, 0, 0, 0, loc), "2025"},
	}
	for _, c := range cases {
		from, to, key := previousCalendarPeriod(c.now, c.kind)
		if !from.Equal(c.from) || !to.Equal(c.to) || key != c.key {
			t.Errorf("%s: got [%v, %v) %q, want [%v, %v) %q", c.name, from, to, key, c.from, c.to, c.key)
		}
	}
}

func TestCalendarDigestTitleNamesThePeriod(t *testing.T) {
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.Local)
	if got := calendarDigestTitle(calendarDigestMonthly, aug); got != "📅 2026 年 8 月听歌小结" {
		t.Errorf("月报标题 = %q", got)
	}
	if got := calendarDigestTitle(calendarDigestYearly, time.Date(2025, 1, 1, 0, 0, 0, 0, time.Local)); got != "🏆 2025 年度听歌小结" {
		t.Errorf("年报标题 = %q", got)
	}
}

// ListenBrainz 统计按 UTC 切周期；返回的 from_ts 换算出的周期键跟我们要的不一样，就是它还没算到。
func TestLBStatsPeriodKeyUsesUTC(t *testing.T) {
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC).Unix()
	if got := lbStatsPeriodKey(aug, calendarDigestMonthly); got != "2026-08" {
		t.Errorf("月 = %q", got)
	}
	if got := lbStatsPeriodKey(aug, calendarDigestYearly); got != "2026" {
		t.Errorf("年 = %q", got)
	}
	if lbStatsRange(calendarDigestMonthly) != "month" || lbStatsRange(calendarDigestYearly) != "year" {
		t.Error("range 参数：月报用 month、年报用 year")
	}
}

func TestCalendarDigestStateRoundTrip(t *testing.T) {
	s := calendarDigestState{path: t.TempDir() + "/state.json"}
	if got := s.load(); got != "" {
		t.Fatalf("没有文件时应为空, got %q", got)
	}
	s.save("2026-08")
	if got := s.load(); got != "2026-08" {
		t.Errorf("got %q", got)
	}
}

// 曲目榜被截断时，总播放次数要用歌手榜合计，不能只加曲目榜。
func TestDigestStatsFromChartsTotalUsesLargerSum(t *testing.T) {
	tracks := []lastfmChartEntry{{Name: "a", Artist: "X", PlayCount: 5}, {Name: "b", Artist: "Y", PlayCount: 3}}
	artists := []lastfmChartEntry{{Name: "X", PlayCount: 9}, {Name: "Y", PlayCount: 4}}
	if got := digestStatsFromCharts(tracks, artists, nil).TotalPlays; got != 13 {
		t.Errorf("曲目榜 8、歌手榜 13，应取 13, got %d", got)
	}
	if got := digestStatsFromCharts(tracks, artists[:1], nil).TotalPlays; got != 9 {
		t.Errorf("歌手榜 9、曲目榜 8，应取 9, got %d", got)
	}
}

func TestDigestStatsFromChartsAlbums(t *testing.T) {
	albums := []lastfmChartEntry{
		{Name: "", Artist: "X", PlayCount: 20},
		{Name: "A1", Artist: "X", PlayCount: 10},
		{Name: "A2", Artist: "Y", PlayCount: 8},
		{Name: "A3", Artist: "Z", PlayCount: 6},
		{Name: "A4", Artist: "W", PlayCount: 4},
	}
	got := digestStatsFromCharts(nil, nil, albums).TopAlbums
	want := []digestTally{{Name: "A1", Sub: "X", Count: 10}, {Name: "A2", Sub: "Y", Count: 8}, {Name: "A3", Sub: "Z", Count: 6}}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("#%d got %v want %v", i, got[i], want[i])
		}
	}
}

func TestDigestStatsFromListensCountsAlbums(t *testing.T) {
	// 歌手名别用单个字母：展示名会查本机别名缓存，「X」这类短名可能撞上真实歌手的罗马字艺名。
	listens := []lbListenEntry{
		{Title: "t1", Artist: "Test Band Alpha", Release: "R1"},
		{Title: "t2", Artist: "Test Band Alpha", Release: "R1"},
		{Title: "t3", Artist: "Test Band Beta", Release: "R2"},
		{Title: "t4", Artist: "Test Band Beta", Release: ""},
	}
	got := digestStatsFromListens(listens)
	if got.TotalPlays != 4 {
		t.Errorf("TotalPlays = %d", got.TotalPlays)
	}
	if len(got.TopAlbums) != 2 || got.TopAlbums[0] != (digestTally{Name: "R1", Sub: "Test Band Alpha", Count: 2}) || got.TopAlbums[1].Name != "R2" {
		t.Errorf("TopAlbums = %v（没有专辑名的那条不计入）", got.TopAlbums)
	}
}

func TestDigestBodyOrderAndAlbumSection(t *testing.T) {
	stats := digestStats{
		TotalPlays: 42,
		TopArtists: []digestTally{{Name: "X", Count: 20}, {Name: "Y", Count: 10}},
		TopAlbums:  []digestTally{{Name: "R1", Sub: "X", Count: 12}, {Name: "R2", Sub: "Y", Count: 8}},
		TopTracks:  []digestTally{{Name: "t1", Sub: "X", Count: 5}, {Name: "t2", Sub: "Y", Count: 3}},
	}
	body := digestBody(stats)
	want := "共播放 42 次\n\nTop 歌手：\n1. X（20）\n2. Y（10）\n\nTop 专辑：\n1. X - R1（12）\n2. Y - R2（8）\n\nTop 歌曲：\n1. X - t1（5）\n2. Y - t2（3）"
	if body != want {
		t.Errorf("body =\n%s\nwant\n%s", body, want)
	}
	stats.TopAlbums = stats.TopAlbums[:1]
	if strings.Contains(digestBody(stats), "Top 专辑") {
		t.Error("只有一张专辑时不展示专辑榜")
	}
}

// lbStatsServer 模拟 ListenBrainz 统计接口：fromTS 为 0 时一律回 204。
func lbStatsServer(t *testing.T, fromTS *int64) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if *fromTS == 0 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		switch {
		case strings.HasSuffix(r.URL.Path, "/artists"):
			fmt.Fprintf(w, `{"payload":{"from_ts":%d,"total_artist_count":2,"artists":[{"artist_name":"X","listen_count":30},{"artist_name":"Y","listen_count":12}]}}`, *fromTS)
		case strings.HasSuffix(r.URL.Path, "/releases"):
			fmt.Fprint(w, `{"payload":{"releases":[{"release_name":"R1","artist_name":"X","listen_count":20},{"release_name":"R2","artist_name":"Y","listen_count":9}]}}`)
		case strings.HasSuffix(r.URL.Path, "/recordings"):
			fmt.Fprint(w, `{"payload":{"recordings":[{"track_name":"t1","artist_name":"X","listen_count":8},{"track_name":"t2","artist_name":"Y","listen_count":5}]}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// pushSink 收下推送，记次数和最后一条正文。
func pushSink(t *testing.T) (*httptest.Server, *int, *string) {
	t.Helper()
	n, last := 0, ""
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		n++
		last = string(b)
	}))
	t.Cleanup(srv.Close)
	return srv, &n, &last
}

func lbOnlyPoller(lbRoot, pushURL, statePath string) *poller {
	return &poller{
		ctx:        context.Background(),
		cfg:        &config{User: "u", Token: "tok"},
		lb:         &lbClient{root: lbRoot, alerter: newAlerter(platformBark, pushURL, "", "", "")},
		monthlyRun: calendarDigestRun{state: calendarDigestState{path: statePath}},
	}
}

// 端到端(ListenBrainz 源)：推一次、记下周期；同一周期不再推。
func TestCalendarDigestPushesOncePerPeriod(t *testing.T) {
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC).Unix()
	lbSrv := lbStatsServer(t, &aug)
	sink, n, last := pushSink(t)
	p := lbOnlyPoller(lbSrv.URL, sink.URL, t.TempDir()+"/monthly.json")
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, time.Local)

	p.calendarDigest(now, p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, true, digestSourceListenBrainz)
	if *n != 1 {
		t.Fatalf("应推送 1 次, got %d", *n)
	}
	if !strings.Contains(*last, "8 月听歌小结") || !strings.Contains(*last, "Top 专辑") {
		t.Errorf("推送内容不对: %s", *last)
	}
	if got := p.monthlyRun.state.load(); got != "2026-08" {
		t.Errorf("state = %q", got)
	}
	p.calendarDigest(now.Add(3*time.Hour), p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, true, digestSourceListenBrainz)
	if *n != 1 {
		t.Errorf("同一周期不该再推, got %d 次", *n)
	}
}

// ListenBrainz 统计还没算到这个月：不推、不记；过了宽限期仍没有，才记为已处理。
func TestCalendarDigestWaitsForLBStats(t *testing.T) {
	for _, tc := range []struct {
		name   string
		fromTS int64
	}{
		{"还停在上上个月", time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC).Unix()},
		{"204 无数据", 0},
	} {
		fromTS := tc.fromTS
		lbSrv := lbStatsServer(t, &fromTS)
		sink, n, _ := pushSink(t)
		p := lbOnlyPoller(lbSrv.URL, sink.URL, t.TempDir()+"/monthly.json")

		p.calendarDigest(time.Date(2026, 9, 2, 10, 0, 0, 0, time.Local), p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, true, digestSourceListenBrainz)
		if *n != 0 || p.monthlyRun.state.load() != "" {
			t.Errorf("%s: 宽限期内应既不推也不记, pushes=%d state=%q", tc.name, *n, p.monthlyRun.state.load())
		}
		p.monthlyRun.lastCheckedAt = time.Time{}
		p.calendarDigest(time.Date(2026, 9, 24, 10, 0, 0, 0, time.Local), p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, true, digestSourceListenBrainz)
		if *n != 0 || p.monthlyRun.state.load() != "2026-08" {
			t.Errorf("%s: 过了宽限期应记为已处理且不推, pushes=%d state=%q", tc.name, *n, p.monthlyRun.state.load())
		}
	}
}

func TestCalendarDigestDisabledDoesNothing(t *testing.T) {
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC).Unix()
	lbSrv := lbStatsServer(t, &aug)
	sink, n, _ := pushSink(t)
	p := lbOnlyPoller(lbSrv.URL, sink.URL, t.TempDir()+"/monthly.json")
	p.calendarDigest(time.Date(2026, 9, 2, 10, 0, 0, 0, time.Local), p.digestEnvSnapshot(), calendarDigestMonthly, &p.monthlyRun, false, digestSourceListenBrainz)
	if *n != 0 {
		t.Errorf("开关关着不该推, got %d", *n)
	}
}

// 听歌报告的歌手归并一个请求都不发：联网那条路查完会把结果(哪怕是空值)写进别名缓存，
// 只读缓存这条路一个字都不写。名字都是缓存里不可能有的罗马字写法。
func TestDigestArtistMergeNeverGoesOnline(t *testing.T) {
	var artists []lastfmChartEntry
	var listens []lbListenEntry
	for i := 0; i < 5; i++ {
		name := fmt.Sprintf("Zq Offline Probe Artist %d", i)
		artists = append(artists, lastfmChartEntry{Name: name, PlayCount: 10 - i})
		listens = append(listens, lbListenEntry{Title: "t", Artist: name, Release: "r"})
	}
	start := time.Now()
	digestTopArtists(artists)
	digestStatsFromListens(listens)
	for _, e := range artists {
		artistAliasMu.Lock()
		_, mb := artistAliasCache[e.Name]
		artistAliasMu.Unlock()
		qqArtistNameMu.Lock()
		_, qq := qqArtistNameCache[e.Name]
		qqArtistNameMu.Unlock()
		if mb || qq {
			t.Errorf("%q 被写进了别名缓存(MusicBrainz=%v QQ=%v)，说明归并联网查过", e.Name, mb, qq)
		}
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("5 个未缓存歌手归并用了 %v，像是在联网", d)
	}
}
