package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 静默时段、每类列出几条、按事件选渠道:第二期推送提醒的引擎部分。

func quietHours(start, end string) notifyQuietHours {
	on := true
	return resolveNotifyQuietHours(&notifyQuietHoursFile{Enabled: &on, Start: start, End: end})
}

func at(day, hour, minute int) time.Time {
	return time.Date(2026, 10, day, hour, minute, 0, 0, time.Local)
}

// 跨午夜(23:00–08:00)按「开始之后或结束之前」算;不跨的按区间;左闭右开;关着、首尾相同都当没有静默。
func TestNotifyQuietHoursActive(t *testing.T) {
	night := quietHours("23:00", "08:00")
	for _, c := range []struct {
		q    notifyQuietHours
		h, m int
		want bool
	}{
		{night, 22, 59, false}, {night, 23, 0, true}, {night, 0, 0, true}, {night, 3, 30, true},
		{night, 7, 59, true}, {night, 8, 0, false}, {night, 12, 0, false},
		{quietHours("13:00", "15:30"), 12, 59, false}, {quietHours("13:00", "15:30"), 13, 0, true},
		{quietHours("13:00", "15:30"), 15, 29, true}, {quietHours("13:00", "15:30"), 15, 30, false},
		{quietHours("09:00", "09:00"), 9, 0, false},
		{notifyQuietHours{Start: 0, End: 23 * 60}, 12, 0, false},
	} {
		if got := c.q.active(at(18, c.h, c.m)); got != c.want {
			t.Errorf("%+v at %02d:%02d active=%v, want %v", c.q, c.h, c.m, got, c.want)
		}
	}
	if end := night.endAfter(at(18, 23, 30)); !end.Equal(at(19, 8, 0)) {
		t.Errorf("23:30 那段静默应在次日 08:00 结束, got %s", end)
	}
	if end := night.endAfter(at(19, 3, 0)); !end.Equal(at(19, 8, 0)) {
		t.Errorf("03:00 那段静默应在当天 08:00 结束, got %s", end)
	}
}

// 段缺失 = 关、23:00–08:00;时刻写坏了按默认时刻;features.json 里的那一段解析得出来。
func TestResolveNotifyQuietHours(t *testing.T) {
	if q := resolveNotifyQuietHours(nil); q.Enabled || q.Start != 23*60 || q.End != 8*60 {
		t.Errorf("缺失 = 关、默认 23:00–08:00, got %+v", q)
	}
	if q := quietHours("24:00", "8:5x"); q.Start != notifyQuietDefaultStart || q.End != notifyQuietDefaultEnd {
		t.Errorf("越界、带多余字的按默认, got %+v", q)
	}
	if q := quietHours("7:30", "21:05"); q.Start != 7*60+30 || q.End != 21*60+5 {
		t.Errorf("一位小时也认, got %+v", q)
	}
	if q := quietHours("abc", ""); q.Start != notifyQuietDefaultStart || q.End != notifyQuietDefaultEnd || !q.Enabled {
		t.Errorf("写坏了按默认时刻, got %+v", q)
	}
	var f featureFlagsFile
	if err := json.Unmarshal([]byte(`{"notification_quiet_hours":{"enabled":true,"start":"22:30","end":"07:15"},"digest_top_n":20}`), &f); err != nil {
		t.Fatal(err)
	}
	ff := buildFeatureFlags(f)
	if q := ff.NotificationQuietHours; !q.Enabled || q.Start != 22*60+30 || q.End != 7*60+15 {
		t.Errorf("features.json 的静默时段, got %+v", q)
	}
	if ff.DigestTopN != maxDigestTopN {
		t.Errorf("digest_top_n 越界夹回 %d, got %d", maxDigestTopN, ff.DigestTopN)
	}
}

func useQuietDigestFeatures(t *testing.T, f featureFlags, start, end string) {
	t.Helper()
	f.NotificationQuietHours = quietHours(start, end)
	useDigestFeatures(t, f)
}

// 静默时段里到期的日报检查:不取数、不推、不记检查时刻;静默结束那一拍就推(补推头天那期),推送记录标「延后」。
// 静默前一刻刚压过一次检查,结束时也不用再等 30 分钟间隔。当晚 22 点那期照常推,不算延后。
func TestDailyDigestHeldByQuietHours(t *testing.T) {
	logPath := withNotifyLogForTest(t)
	useQuietDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm}, "23:00", "08:00")
	f := useFakeLastfmRead(t, chartRoutes())
	sink, n, last := pushSink(t)
	p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
	p.dailyState.save("2026-10-16")
	env := lastfmDigestEnv(sink.URL)

	for _, tick := range []time.Time{at(17, 23, 5), at(18, 3, 0), at(18, 7, 59)} {
		p.dailyDigest(tick, env)
	}
	if *n != 0 || f.count() != 0 || !p.dailyLastCheckedAt.IsZero() {
		t.Fatalf("静默里不取数、不推、不记检查时刻: pushes=%d requests=%d checked=%s", *n, f.count(), p.dailyLastCheckedAt)
	}
	p.dailyDigest(at(18, 8, 0), env)
	if *n != 1 || !strings.Contains(*last, "昨日听歌报告（10-17）") || p.dailyState.load() != "2026-10-17" {
		t.Fatalf("静默结束那一拍补推头天那期: pushes=%d state=%q body=%s", *n, p.dailyState.load(), *last)
	}
	entries := readNotifyLog(logPath).Entries
	if len(entries) != 1 || !entries[0].Deferred {
		t.Fatalf("静默压过的那条记「延后」: %+v", entries)
	}
	p.dailyDigest(at(18, 22, 10), env)
	entries = readNotifyLog(logPath).Entries
	if *n != 2 || len(entries) != 2 || entries[1].Deferred {
		t.Errorf("当晚那期照推、不算延后: pushes=%d entries=%+v", *n, entries)
	}
}

// 静默压着的时候检查时刻不往前推:就算静默前一分钟还压过一次,结束那一拍照样到期(周报 2 小时间隔、月报同理)。
func TestWeeklyAndMonthlyDigestPushRightAfterQuietHours(t *testing.T) {
	logPath := withNotifyLogForTest(t)
	useQuietDigestFeatures(t, featureFlags{WeeklyDigest: true, WeeklyDigestSource: digestSourceLastfm}, "23:00", "08:00")
	closed := at(19, 2, 0).Unix()
	f := useFakeLastfmRead(t, weeklyRoutes(closed))
	sink, n, _ := pushSink(t)
	p := &poller{weeklyState: weeklyDigestState{path: filepath.Join(t.TempDir(), "weekly.json")},
		monthlyRun: calendarDigestRun{state: calendarDigestState{path: filepath.Join(t.TempDir(), "monthly.json")}}}
	env := lastfmDigestEnv(sink.URL)

	p.weeklyDigest(at(19, 7, 59), env)
	p.calendarDigest(at(19, 7, 59), env, calendarDigestMonthly, &p.monthlyRun, true, digestSourceLastfm)
	if *n != 0 || f.count() != 0 {
		t.Fatalf("静默里不取数: pushes=%d requests=%d", *n, f.count())
	}
	p.weeklyDigest(at(19, 8, 0), env)
	p.calendarDigest(at(19, 8, 0), env, calendarDigestMonthly, &p.monthlyRun, true, digestSourceLastfm)
	if *n != 2 || p.weeklyState.load() != closed || p.monthlyRun.state.load() != "2026-09" {
		t.Fatalf("静默结束那一拍周报、月报都推: pushes=%d weekly=%d monthly=%q", *n, p.weeklyState.load(), p.monthlyRun.state.load())
	}
	for _, e := range readNotifyLog(logPath).Entries {
		if !e.Deferred {
			t.Errorf("静默压过的都记「延后」: %+v", e)
		}
	}
}

// 补推截止 12 点落在静默时段里时顺延到静默结束后一个检查间隔:10:00–14:00 静默,14:00 那一拍还补得上;
// 没被静默压过、14:31 才头一次检查的不补。截止不在静默里时照旧 12 点。
func TestDailyDigestCatchUpDeadlineMovesPastQuietHours(t *testing.T) {
	midnight := at(18, 0, 0)
	for _, c := range []struct {
		q    notifyQuietHours
		want time.Time
	}{
		{notifyQuietHours{}, at(18, 12, 0)},
		{quietHours("23:00", "08:00"), at(18, 12, 0)},
		{quietHours("10:00", "14:00"), at(18, 14, 30)},
		{quietHours("11:00", "01:00"), at(19, 1, 30)},
	} {
		if got := dailyDigestCatchUpDeadline(midnight, c.q); !got.Equal(c.want) {
			t.Errorf("%+v: 截止 %s, want %s", c.q, got, c.want)
		}
	}

	useQuietDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm}, "10:00", "14:00")
	useFakeLastfmRead(t, chartRoutes())
	sink, n, last := pushSink(t)
	p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
	p.dailyState.save("2026-10-16")
	p.dailyDigest(at(18, 11, 0), lastfmDigestEnv(sink.URL))
	p.dailyDigest(at(18, 14, 0), lastfmDigestEnv(sink.URL))
	if *n != 1 || !strings.Contains(*last, "昨日听歌报告（10-17）") {
		t.Fatalf("静默跨过 12 点,结束那一拍还补推: pushes=%d body=%s", *n, *last)
	}
	late := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
	late.dailyState.save("2026-10-16")
	late.dailyDigest(at(18, 14, 31), lastfmDigestEnv(sink.URL))
	if *n != 1 {
		t.Errorf("过了顺延的截止不补, got %d", *n)
	}
}

// 「测一下」是用户当场点的,静默时段里照推。
func TestNotifyTestIgnoresQuietHours(t *testing.T) {
	withNotifyLogForTest(t)
	prevResult := notifyTestResultPath
	notifyTestResultPath = filepath.Join(t.TempDir(), "result.json")
	t.Cleanup(func() { notifyTestResultPath = prevResult })
	now := time.Now()
	m := now.Hour()*60 + now.Minute()
	clock := func(v int) string { v = (v + 24*60) % (24 * 60); return fmt.Sprintf("%02d:%02d", v/60, v%60) }
	useQuietDigestFeatures(t, featureFlags{}, clock(m-60), clock(m+60))
	if !features().NotificationQuietHours.active(now) {
		t.Fatal("前提:此刻在静默时段里")
	}
	got := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got++
		io.WriteString(w, `{"code":200}`)
	}))
	defer srv.Close()
	runNotifyTest(notifyTestRequest{ID: "q1", Channel: notifyChannel{ID: "c", Platform: platformBark, URL: srv.URL + "/k", Enabled: true}})
	if got != 1 {
		t.Errorf("静默时段里「测一下」照推, got %d", got)
	}
}

// 每类列几条读 features.json 的 digest_top_n:缺失 3 条,越界夹回 1～10;Last.fm 榜单、ListenBrainz 收听记录、
// ListenBrainz 统计接口三条取数路径都按它截。
func TestDigestTopNFromFeatures(t *testing.T) {
	for _, c := range []struct {
		in   *int
		want int
	}{{nil, 3}, {ptr(0), 1}, {ptr(-4), 1}, {ptr(7), 7}, {ptr(11), 10}} {
		if got := resolveDigestTopN(c.in); got != c.want {
			t.Errorf("resolveDigestTopN(%v) = %d, want %d", c.in, got, c.want)
		}
	}
	useDigestFeatures(t, featureFlags{DigestTopN: 5})
	var tracks, artists, albums []lastfmChartEntry
	var listens []lbListenEntry
	for i := 0; i < 12; i++ {
		name := fmt.Sprintf("Zq TopN Probe %02d", i)
		tracks = append(tracks, lastfmChartEntry{Name: "t" + name, Artist: name, PlayCount: 50 - i})
		artists = append(artists, lastfmChartEntry{Name: name, PlayCount: 50 - i})
		albums = append(albums, lastfmChartEntry{Name: "a" + name, Artist: name, PlayCount: 50 - i})
		for j := 0; j < 12-i; j++ {
			listens = append(listens, lbListenEntry{Title: "t" + name, Artist: name, Release: "a" + name})
		}
	}
	s := digestStatsFromCharts(tracks, artists, albums)
	if len(s.TopTracks) != 5 || len(s.TopArtists) != 5 || len(s.TopAlbums) != 5 {
		t.Errorf("Last.fm 榜单各取 5 条, got %d/%d/%d", len(s.TopTracks), len(s.TopArtists), len(s.TopAlbums))
	}
	l := digestStatsFromListens(listens)
	if len(l.TopTracks) != 5 || len(l.TopArtists) != 5 || len(l.TopAlbums) != 5 {
		t.Errorf("ListenBrainz 收听记录各取 5 条, got %d/%d/%d", len(l.TopTracks), len(l.TopArtists), len(l.TopAlbums))
	}
	if body := digestBody(s); strings.Count(body, "\n5. ") != 3 || strings.Contains(body, "\n6. ") {
		t.Errorf("正文每类 5 行:\n%s", body)
	}

	useDigestFeatures(t, featureFlags{DigestTopN: 1})
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC).Unix()
	lbSrv := lbStatsServer(t, &aug)
	stats, ready, err := lbStatsDigest(t.Context(), lbSrv.URL, "u", calendarDigestMonthly, "2026-08")
	if err != nil || !ready || len(stats.TopArtists) != 1 || len(stats.TopAlbums) != 1 || len(stats.TopTracks) != 1 {
		t.Errorf("ListenBrainz 统计接口各取 1 条: %+v ready=%v err=%v", stats, ready, err)
	}
	useDigestFeatures(t, featureFlags{})
	if got := len(digestStatsFromCharts(tracks, artists, albums).TopTracks); got != defaultDigestTopN {
		t.Errorf("没设过按缺省 %d 条, got %d", defaultDigestTopN, got)
	}
}

func ptr(v int) *int { return &v }

// 路由只指向已删除 / 停用的渠道:这一档不推(不退回「全部渠道」),也不取数、不记水位,渠道恢复后照常补推最近一期。
func TestDigestRoutedOnlyToGoneChannels(t *testing.T) {
	useDigestFeatures(t, featureFlags{DailyDigest: true, DailyDigestSource: digestSourceLastfm})
	f := useFakeLastfmRead(t, chartRoutes())
	sink, n, _ := pushSink(t)
	cfg := &config{LastfmUser: "someone", LastfmAPIKey: "read-key", NotificationChannels: []notifyChannel{
		{ID: "on", Platform: platformBark, URL: sink.URL + "/k", Enabled: true},
		{ID: "off", Platform: platformBark, URL: sink.URL + "/k2", Enabled: false},
	}, NotificationRoutes: map[string][]string{notifyEventDaily: {"off", "deleted"}}}
	env := digestEnv{ctx: t.Context(), cfg: cfg, alerter: alerterFromConfig(cfg)}
	p := &poller{dailyState: dailyDigestState{path: filepath.Join(t.TempDir(), "daily.json")}}
	p.dailyDigest(at(18, 22, 30), env)
	if *n != 0 || f.count() != 0 || p.dailyState.load() != "" {
		t.Fatalf("只指向停用 / 已删除的渠道:不推、不取数、不记, pushes=%d requests=%d state=%q", *n, f.count(), p.dailyState.load())
	}
	if routedNotifyChannels(env.alerter.channels, cfg.NotificationRoutes, notifyEventWeekly)[0].ID != "on" {
		t.Error("别的事件没选过渠道,照旧推到启用的那个")
	}
	cfg.NotificationRoutes[notifyEventDaily] = []string{"on", "deleted"}
	env.alerter = alerterFromConfig(cfg)
	p.dailyLastCheckedAt = time.Time{}
	p.dailyDigest(at(18, 22, 40), env)
	if *n != 1 || p.dailyState.load() != "2026-10-18" {
		t.Errorf("路由里还有启用的渠道就推它, pushes=%d state=%q", *n, p.dailyState.load())
	}
}
