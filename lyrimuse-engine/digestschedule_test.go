package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 推送时间(digestschedule.go)、每类列出几条、按事件选渠道。

func at(day, hour, minute int) time.Time {
	return time.Date(2026, 10, day, hour, minute, 0, 0, time.Local)
}

func pushAtClock(minutes int) featureFlags {
	return featureFlags{DigestPushTime: digestClock{minutes: minutes, set: true}}
}

func TestResolveDigestPushTime(t *testing.T) {
	for _, c := range []struct {
		in   string
		want int
	}{{"", 22 * 60}, {"7:30", 450}, {"08:00", 480}, {"25:00", 22 * 60}, {"22:00 ", 22 * 60}, {"０８:００", 22 * 60}} {
		flags := featureFlags{DigestPushTime: resolveDigestPushTime(c.in)}
		useDigestFeatures(t, flags)
		if got := digestPushMinutes(); got != c.want {
			t.Errorf("%q → %d, want %d", c.in, got, c.want)
		}
	}
}

// 日报推哪一天:最近一个已经到了的推送时刻对应的那一天;推送时间在中午以后推当天(到现在为止),早上推前一天整天;
// 到点那次没推成的,下一个推送时刻之前补的是那一天一整天。
func TestDailyDigestTargetByPushTime(t *testing.T) {
	cases := []struct {
		now        time.Time
		minutes    int
		day, title string
		toNow      bool
	}{
		{at(18, 22, 5), 22 * 60, "2026-10-18", "🎧 今日听歌报告（10-18）", true},
		{at(19, 9, 0), 22 * 60, "2026-10-18", "🎧 昨日听歌报告（10-18）", false},
		{at(19, 21, 59), 22 * 60, "2026-10-18", "🎧 昨日听歌报告（10-18）", false},
		{at(19, 8, 30), 8 * 60, "2026-10-18", "🎧 昨日听歌报告（10-18）", false},
		{at(19, 7, 0), 8 * 60, "2026-10-17", "🎧 听歌报告（10-17）", false},
		{at(19, 12, 0), 12 * 60, "2026-10-19", "🎧 今日听歌报告（10-19）", true},
	}
	for _, c := range cases {
		day, from, to, title := dailyDigestTarget(c.now, c.minutes)
		wantTo := from.AddDate(0, 0, 1)
		if c.toNow {
			wantTo = c.now
		}
		if day != c.day || title != c.title || !to.Equal(wantTo) || from.Format(time.DateOnly) != day {
			t.Errorf("%s @%s: day=%s title=%s from=%s to=%s", c.now.Format("01-02 15:04"), clockText(c.minutes), day, title, from, to)
		}
	}
}

func TestFirstDigestPushAtOrAfter(t *testing.T) {
	sun := at(18, 20, 0) // Last.fm 图表周在北京时间周日 20:00 结束
	if got := firstDigestPushAtOrAfter(sun, 22*60); !got.Equal(at(18, 22, 0)) {
		t.Errorf("周日 20:00 结束、22:00 推: %s", got)
	}
	if got := firstDigestPushAtOrAfter(sun, 8*60); !got.Equal(at(19, 8, 0)) {
		t.Errorf("早上 8 点推的话是周一 8 点: %s", got)
	}
	if got := firstDigestPushAtOrAfter(at(1, 0, 0), 22*60); !got.Equal(at(1, 22, 0)) {
		t.Errorf("月报 1 日 22:00: %s", got)
	}
	if got := firstDigestPushAtOrAfter(at(18, 22, 0), 22*60); !got.Equal(at(18, 22, 0)) {
		t.Errorf("正好在推送时刻结束就当场推: %s", got)
	}
}

// 跨过今天推送时刻的那一次检查不等检查间隔:21:50 查过、22:00 就再查;22:05 查过的照旧等满间隔。
func TestDigestDueCrossesPushTime(t *testing.T) {
	useDigestFeatures(t, pushAtClock(22*60))
	if !digestDue(at(18, 22, 0), at(18, 21, 50), 2*time.Hour) {
		t.Error("跨过推送时刻应立刻查")
	}
	if digestDue(at(18, 23, 0), at(18, 22, 5), 2*time.Hour) {
		t.Error("推送时刻之后查过的,等满间隔")
	}
	if !digestDue(at(18, 1, 0), time.Time{}, 2*time.Hour) {
		t.Error("这个进程还没查过的,算到期")
	}
}

// 周报、月报:周期结束了还要等到推送时间才推,不提前取数。
func TestWeeklyAndMonthlyWaitForPushTime(t *testing.T) {
	flags := pushAtClock(22 * 60)
	flags.WeeklyDigest, flags.WeeklyDigestSource = true, digestSourceLastfm
	useDigestFeatures(t, flags)
	closed := at(18, 20, 0).Unix()
	useFakeLastfmRead(t, weeklyRoutes(closed))
	sink, n, _ := pushSink(t)
	p := &poller{weeklyState: weeklyDigestState{path: filepath.Join(t.TempDir(), "weekly.json")},
		monthlyRun: calendarDigestRun{state: calendarDigestState{path: filepath.Join(t.TempDir(), "monthly.json")}}}
	env := lastfmDigestEnv(sink.URL)

	p.weeklyDigest(at(18, 21, 0), env)
	nov := time.Date(2026, 11, 1, 21, 0, 0, 0, time.Local)
	p.calendarDigest(nov, env, calendarDigestMonthly, &p.monthlyRun, true, digestSourceLastfm)
	if *n != 0 || p.weeklyState.load() != 0 || p.monthlyRun.state.load() != "" {
		t.Fatalf("没到推送时间不推: pushes=%d weekly=%d monthly=%q", *n, p.weeklyState.load(), p.monthlyRun.state.load())
	}
	p.weeklyDigest(at(18, 22, 0), env)
	p.calendarDigest(nov.Add(time.Hour), env, calendarDigestMonthly, &p.monthlyRun, true, digestSourceLastfm)
	if *n != 2 || p.weeklyState.load() != closed || p.monthlyRun.state.load() != "2026-10" {
		t.Fatalf("到了推送时间那一拍就推(不等 2 小时间隔): pushes=%d weekly=%d monthly=%q", *n, p.weeklyState.load(), p.monthlyRun.state.load())
	}
}

// 换了时区:第一次看到的时区只记下;系统时区链接变了才重启一次,之后同一个时区不再重启;读不到链接时不动。
func TestLocalZoneChangedRestartsOnce(t *testing.T) {
	savedLink, savedName, savedRestart := localZoneLink, localZoneName, restartForZoneChange
	t.Cleanup(func() { localZoneLink, localZoneName, restartForZoneChange = savedLink, savedName, savedRestart })
	restarts := 0
	restartForZoneChange = func() { restarts++ }
	localZoneName = ""
	dir := t.TempDir()
	localZoneLink = filepath.Join(dir, "localtime")
	steps := []struct {
		zone    string
		changed bool
	}{{"Asia/Tokyo", false}, {"Asia/Tokyo", false}, {"America/New_York", true}, {"America/New_York", false}}
	for i, st := range steps {
		_ = os.Remove(localZoneLink)
		if err := os.Symlink("/var/db/timezone/zoneinfo/"+st.zone, localZoneLink); err != nil {
			t.Fatal(err)
		}
		if got := localZoneChanged(); got != st.changed {
			t.Errorf("第 %d 步(%s): changed=%v,应为 %v", i, st.zone, got, st.changed)
		}
	}
	localZoneLink = filepath.Join(dir, "missing")
	if localZoneChanged() {
		t.Error("读不到时区链接时不该重启")
	}
	if restarts != 1 {
		t.Errorf("重启了 %d 次,应为 1", restarts)
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
