package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

var lyricSourceStatsTestToday = time.Date(2026, 10, 2, 15, 0, 0, 0, time.Local)

func allLyricSourcesOn(string) bool { return true }

// lyricSourceTestDays 按「往前第几天 → 源 → 计数」拼出 days。
func lyricSourceTestDays(spec map[int]map[string]lyricSourceDayCounts) map[string]*lyricSourceStatsDay {
	days := map[string]*lyricSourceStatsDay{}
	for ago, sources := range spec {
		d := &lyricSourceStatsDay{Sources: map[string]*lyricSourceDayCounts{}}
		for src, c := range sources {
			c := c
			d.Sources[src] = &c
		}
		days[lyricSourceStatsTestToday.AddDate(0, 0, -ago).Format(lyricSourceStatsDayLayout)] = d
	}
	return days
}

// lyricSourceTestRange:往前 from..to 天(含两端)每天同一份计数。
func lyricSourceTestRange(spec map[int]map[string]lyricSourceDayCounts, from, to int, src string, c lyricSourceDayCounts) {
	for ago := from; ago <= to; ago++ {
		if spec[ago] == nil {
			spec[ago] = map[string]lyricSourceDayCounts{}
		}
		spec[ago][src] = c
	}
}

func lyricSourceSummaryOf(t *testing.T, out []lyricSourceStatsSummary, src string) lyricSourceStatsSummary {
	t.Helper()
	for _, s := range out {
		if s.Source == src {
			return s
		}
	}
	t.Fatalf("摘要里没有 %s", src)
	return lyricSourceStatsSummary{}
}

func TestAddLyricSourceRoundCountsPeersInSameGroup(t *testing.T) {
	day := &lyricSourceStatsDay{}
	addLyricSourceRound(day, lyricSourceRoundOutcome{
		enabled:   []string{"netease", "qq", "kugou", "kuwo", "migu", "lrclib", "amll"},
		skipped:   map[string]bool{"migu": true},
		responded: map[string]bool{"netease": true, "qq": true, "kugou": true, "lrclib": true, "amll": true},
		usable:    map[string]bool{"netease": true, "qq": true, "lrclib": true},
		winner:    "qq",
	})
	if day.Rounds != 1 {
		t.Fatalf("rounds = %d, want 1", day.Rounds)
	}
	want := map[string]lyricSourceDayCounts{
		"netease": {Asked: 1, Responded: 1, Usable: 1, PeerRounds: 1, PeerHits: 1},
		"qq":      {Asked: 1, Responded: 1, Usable: 1, Won: 1, PeerRounds: 1, PeerHits: 1},
		"kugou":   {Asked: 1, Responded: 1, PeerRounds: 1, PeerHits: 1},
		// 同类三家都给了、它没给:算一次该给没给。
		"kuwo": {Asked: 1, PeerRounds: 1},
		// 被熔断跳过的不算问过,也不进命中率。
		"migu": {Skipped: 1},
		// 英文曲库这一轮只有它自己给了,同类不到两家,不算该给。
		"lrclib": {Asked: 1, Responded: 1, Usable: 1},
		// amll 不进任何一组,只记问没问、给没给。
		"amll": {Asked: 1, Responded: 1},
	}
	if len(day.Sources) != len(want) {
		t.Fatalf("记了 %d 个源,want %d: %v", len(day.Sources), len(want), day.Sources)
	}
	for src, w := range want {
		if got := day.Sources[src]; got == nil || !reflect.DeepEqual(*got, w) {
			t.Errorf("%s = %+v, want %+v", src, got, w)
		}
	}
}

func TestLyricSourceOutcomeFromDecision(t *testing.T) {
	d := &lyricsDecision{
		Path:             lyricsDecisionPathFirstResolve,
		SourcesResponded: []string{"netease", "qq"},
		SourcesSkipped:   []string{"kugou"},
		Candidates: []lyricsDecisionCandidate{
			{Source: "netease", Score: 420},
			{Source: "qq", Score: -1},
			{Source: "lrclib", Score: 0},
		},
		Winner: "netease",
	}
	o := lyricSourceOutcomeFromDecision(d,
		func(s string) bool { return s != "migu" },
		func(s string) bool { return s != "applemusic" })

	for _, s := range []string{"netease", "qq", "lrclib"} {
		if !o.responded[s] {
			t.Errorf("%s 给了候选,该算 responded", s)
		}
	}
	if o.usable["qq"] || !o.usable["netease"] || !o.usable["lrclib"] {
		t.Errorf("usable = %v, want 负分的 qq 不算、0 分的 lrclib 算", o.usable)
	}
	if !o.skipped["kugou"] || len(o.skipped) != 1 {
		t.Errorf("skipped = %v, want 只有 kugou", o.skipped)
	}
	if o.winner != "netease" {
		t.Errorf("winner = %q", o.winner)
	}
	for _, s := range o.enabled {
		if s == "migu" || s == "applemusic" || isPlayerLocalLyricSource(s) {
			t.Errorf("enabled 不该有 %s: %v", s, o.enabled)
		}
	}
	if len(o.enabled) != len(lyricSourceNames)-2 {
		t.Errorf("enabled = %v, want lyricSourceNames 去掉 migu、applemusic", o.enabled)
	}
}

func TestLyricSourceStatsCountsOnlyLiveLookups(t *testing.T) {
	live := map[string]bool{
		lyricsDecisionPathFirstResolve: true,
		lyricsDecisionPathRefill:       true,
		lyricsDecisionPathUpgrade:      true,
	}
	for _, p := range lyricsDecisionPaths() {
		if got := lyricSourceStatsCountsPath(p); got != live[p] {
			t.Errorf("lyricSourceStatsCountsPath(%q) = %v, want %v", p, got, live[p])
		}
	}
}

func TestSummarizeLyricSourceStatsBarely(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	lyricSourceTestRange(spec, 0, 2, "kuwo", lyricSourceDayCounts{Asked: 25, Responded: 1, PeerRounds: 20, PeerHits: 1})
	// 窗口外的一天不进 3 天命中率。
	lyricSourceTestRange(spec, 3, 3, "kuwo", lyricSourceDayCounts{Asked: 100, PeerRounds: 100})
	lyricSourceTestRange(spec, 0, 2, "qq", lyricSourceDayCounts{Asked: 25, Responded: 18, PeerRounds: 20, PeerHits: 15})
	// 样本不够(3 天 45 轮)不判。
	lyricSourceTestRange(spec, 0, 2, "migu", lyricSourceDayCounts{Asked: 20, PeerRounds: 15})

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), lyricSourceStatsTestToday, allLyricSourcesOn)
	kuwo := lyricSourceSummaryOf(t, out, "kuwo")
	if kuwo.Alert != lyricSourceAlertBarely || kuwo.PeerRate != 0.05 || kuwo.PeerRounds != 60 {
		t.Errorf("kuwo = %+v, want barely 0.05/60", kuwo)
	}
	if a := lyricSourceSummaryOf(t, out, "qq").Alert; a != "" {
		t.Errorf("qq alert = %q, want 无", a)
	}
	if a := lyricSourceSummaryOf(t, out, "migu").Alert; a != "" {
		t.Errorf("migu 样本不够,alert = %q, want 无", a)
	}
}

func TestSummarizeLyricSourceStatsBelowUsual(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	// deezer:平时一半,这 3 天只剩四分之一。
	lyricSourceTestRange(spec, 3, 16, "deezer", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 20})
	lyricSourceTestRange(spec, 0, 2, "deezer", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 10})
	// lyricfind:平时就低(基线不到 20%),再低一点也不判「比平时少」。
	lyricSourceTestRange(spec, 3, 16, "lyricfind", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 6})
	lyricSourceTestRange(spec, 0, 2, "lyricfind", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 5})
	// musixmatch:够格的基线天只有 2 天,没有基线可比。
	lyricSourceTestRange(spec, 3, 4, "musixmatch", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 36})
	lyricSourceTestRange(spec, 5, 16, "musixmatch", lyricSourceDayCounts{Asked: 30, PeerRounds: 29, PeerHits: 26})
	lyricSourceTestRange(spec, 0, 2, "musixmatch", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 16})
	// lrclib:3 天只有 90 轮,不到「比平时少」要的 100 轮。
	lyricSourceTestRange(spec, 3, 16, "lrclib", lyricSourceDayCounts{Asked: 50, PeerRounds: 40, PeerHits: 36})
	lyricSourceTestRange(spec, 0, 2, "lrclib", lyricSourceDayCounts{Asked: 40, PeerRounds: 30, PeerHits: 6})

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), lyricSourceStatsTestToday, allLyricSourcesOn)
	deezer := lyricSourceSummaryOf(t, out, "deezer")
	if deezer.Alert != lyricSourceAlertBelowUsual || deezer.PeerRate != 0.25 || deezer.UsualRate != 0.5 || deezer.PeerRounds != 120 {
		t.Errorf("deezer = %+v, want below_usual 0.25 vs 0.5 / 120", deezer)
	}
	for _, src := range []string{"lyricfind", "musixmatch", "lrclib"} {
		if a := lyricSourceSummaryOf(t, out, src).Alert; a != "" {
			t.Errorf("%s alert = %q, want 无", src, a)
		}
	}
}

func TestSummarizeLyricSourceStatsCooling(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	// lyricfind:2 天里四分之三被跳过,跳闸原因是 5xx。命中率同时也够「几乎不给词」,冷却优先。
	lyricSourceTestRange(spec, 0, 1, "lyricfind", lyricSourceDayCounts{Asked: 5, Skipped: 15, PeerRounds: 30})
	lyricSourceTestRange(spec, 2, 2, "lyricfind", lyricSourceDayCounts{Asked: 20, PeerRounds: 20})
	spec[0]["lyricfind"] = lyricSourceDayCounts{Asked: 5, Skipped: 15, PeerRounds: 30, Trips: map[string]int{lyricSourceCooldownReasonServerError: 2}}
	// kugou:跳过四分之一,不算冷却。
	lyricSourceTestRange(spec, 0, 1, "kugou", lyricSourceDayCounts{Asked: 30, Skipped: 10})
	// deezer:2 天只有 12 轮,样本不够。
	lyricSourceTestRange(spec, 0, 1, "deezer", lyricSourceDayCounts{Asked: 1, Skipped: 5})
	// musixmatch:网络原因冷却,但只有它一个,仍然只说冷却。
	lyricSourceTestRange(spec, 0, 1, "musixmatch", lyricSourceDayCounts{Asked: 5, Skipped: 15, Trips: map[string]int{lyricSourceCooldownReasonNetwork: 3}})

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), lyricSourceStatsTestToday, allLyricSourcesOn)
	lf := lyricSourceSummaryOf(t, out, "lyricfind")
	if lf.Alert != lyricSourceAlertCooling || lf.SkipRate != 0.75 || lf.PeerRate != 0 {
		t.Errorf("lyricfind = %+v, want cooling 0.75", lf)
	}
	if mx := lyricSourceSummaryOf(t, out, "musixmatch"); mx.Alert != lyricSourceAlertCooling || len(mx.NetworkPeers) != 0 {
		t.Errorf("musixmatch = %+v, want 只有自己网络冷却时报 cooling", mx)
	}
	for _, src := range []string{"kugou", "deezer"} {
		if a := lyricSourceSummaryOf(t, out, src).Alert; a != "" {
			t.Errorf("%s alert = %q, want 无", src, a)
		}
	}
}

func TestSummarizeLyricSourceStatsNetwork(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	network := map[string]int{lyricSourceCooldownReasonNetwork: 2}
	for _, src := range []string{"musixmatch", "lyricfind", "deezer"} {
		lyricSourceTestRange(spec, 0, 1, src, lyricSourceDayCounts{Asked: 2, Skipped: 20, Trips: network})
	}
	// 被限流冷却的照旧报 cooling,不并进网络那一组。
	lyricSourceTestRange(spec, 0, 1, "kugou", lyricSourceDayCounts{Asked: 2, Skipped: 20, Trips: map[string]int{lyricSourceCooldownReasonRateLimited: 3}})
	// 网络跳闸少于服务端错误:原因记在源自己身上。
	lyricSourceTestRange(spec, 0, 1, "lrclib", lyricSourceDayCounts{Asked: 2, Skipped: 20,
		Trips: map[string]int{lyricSourceCooldownReasonNetwork: 1, lyricSourceCooldownReasonServerError: 2}})

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), lyricSourceStatsTestToday, allLyricSourcesOn)
	mx := lyricSourceSummaryOf(t, out, "musixmatch")
	if mx.Alert != lyricSourceAlertNetwork || !reflect.DeepEqual(mx.NetworkPeers, []string{"lyricfind", "deezer"}) {
		t.Errorf("musixmatch = %+v, want network 并列出 lyricfind/deezer", mx)
	}
	if dz := lyricSourceSummaryOf(t, out, "deezer"); dz.Alert != lyricSourceAlertNetwork || !reflect.DeepEqual(dz.NetworkPeers, []string{"musixmatch", "lyricfind"}) {
		t.Errorf("deezer = %+v", dz)
	}
	for _, src := range []string{"kugou", "lrclib"} {
		if s := lyricSourceSummaryOf(t, out, src); s.Alert != lyricSourceAlertCooling || len(s.NetworkPeers) != 0 {
			t.Errorf("%s = %+v, want cooling", src, s)
		}
	}
}

func TestSummarizeLyricSourceStatsSevenDayTotals(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	lyricSourceTestRange(spec, 0, 6, "netease", lyricSourceDayCounts{Asked: 10, Skipped: 2, Responded: 8, Won: 4})
	lyricSourceTestRange(spec, 7, 7, "netease", lyricSourceDayCounts{Asked: 100, Responded: 100, Won: 100})

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), lyricSourceStatsTestToday, func(s string) bool { return s != "migu" })
	if len(out) != len(lyricSourceNames) {
		t.Fatalf("摘要 %d 条,want 每个源一条(%d)", len(out), len(lyricSourceNames))
	}
	ne := lyricSourceSummaryOf(t, out, "netease")
	if ne.Rounds != 84 || ne.Responded != 56 || ne.Won != 28 || !ne.Enabled {
		t.Errorf("netease = %+v, want 近 7 天 84/56/28", ne)
	}
	if lyricSourceSummaryOf(t, out, "migu").Enabled {
		t.Error("migu 关着,Enabled 该是 false")
	}
}

func TestLyricSourceBaselineMedian(t *testing.T) {
	keys := lyricSourceDayKeys(lyricSourceStatsTestToday, 3, lyricSourceBaselineDays)
	build := func(rates ...int) map[string]*lyricSourceStatsDay {
		spec := map[int]map[string]lyricSourceDayCounts{}
		for i, hits := range rates {
			lyricSourceTestRange(spec, 3+i, 3+i, "qq", lyricSourceDayCounts{PeerRounds: 50, PeerHits: hits})
		}
		// 样本不到 30 轮的那天不算数。
		lyricSourceTestRange(spec, 16, 16, "qq", lyricSourceDayCounts{PeerRounds: 29})
		return lyricSourceTestDays(spec)
	}
	if got, ok := lyricSourceBaseline(build(10, 30, 20), "qq", keys); !ok || got != 0.4 {
		t.Errorf("奇数天中位数 = %v %v, want 0.4", got, ok)
	}
	if got, ok := lyricSourceBaseline(build(10, 30, 20, 40), "qq", keys); !ok || got != 0.5 {
		t.Errorf("偶数天中位数 = %v %v, want 0.5", got, ok)
	}
	if _, ok := lyricSourceBaseline(build(10, 30), "qq", keys); ok {
		t.Error("够格的只有 2 天,不该有基线")
	}
}

func TestPruneLyricSourceStatsKeepsRecentDays(t *testing.T) {
	days := lyricSourceTestDays(map[int]map[string]lyricSourceDayCounts{0: {}, 59: {}, 60: {}, 200: {}})
	pruneLyricSourceStats(days, lyricSourceStatsTestToday, 60)
	keep := map[string]bool{
		lyricSourceStatsTestToday.Format(lyricSourceStatsDayLayout):                    true,
		lyricSourceStatsTestToday.AddDate(0, 0, -59).Format(lyricSourceStatsDayLayout): true,
	}
	if len(days) != len(keep) {
		t.Fatalf("剩 %d 天,want %d", len(days), len(keep))
	}
	for k := range days {
		if !keep[k] {
			t.Errorf("%s 该删", k)
		}
	}
}

func TestLyricSourceStatsRecordsAndPersists(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	prevFeatures := featuresSnapshot.Load()
	t.Cleanup(func() { featuresSnapshot.Store(prevFeatures) })
	setFeatures(featureFlags{})
	t.Cleanup(func() { lyricSourceStatsShared.Store(nil) })

	// 没有常驻进程那一份时(一次性子命令)什么都不记。
	noteLyricSourceDecision(&lyricsDecision{Path: lyricsDecisionPathFirstResolve, Winner: "netease"})
	noteLyricSourceTrip("lyricfind", lyricSourceCooldownReasonServerError)

	now := lyricSourceStatsTestToday
	path := filepath.Join(dir, lyricSourceStatsFileName)
	s := loadLyricSourceStats(path, func() time.Time { return now })
	lyricSourceStatsShared.Store(s)
	noteLyricSourceDecision(&lyricsDecision{
		Path:       lyricsDecisionPathFirstResolve,
		Candidates: []lyricsDecisionCandidate{{Source: "netease", Score: 300}},
		Winner:     "netease",
	})
	noteLyricSourceDecision(&lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "qq"})
	noteLyricSourceDecision(nil)
	noteLyricSourceTrip("lyricfind", lyricSourceCooldownReasonServerError)
	s.save()

	f := readLyricSourceStatsFile()
	if f == nil {
		t.Fatal("没写出统计文件")
	}
	day := f.Days[now.Format(lyricSourceStatsDayLayout)]
	if f.UpdatedAt != now.Unix() || day == nil || day.Rounds != 1 {
		t.Fatalf("updated_at=%d day=%+v, want 只记了现查那一轮", f.UpdatedAt, day)
	}
	if c := day.Sources["netease"]; c == nil || c.Won != 1 || c.Usable != 1 {
		t.Errorf("netease = %+v", c)
	}
	if c := day.Sources["lyricfind"]; c == nil || c.Trips[lyricSourceCooldownReasonServerError] != 1 || c.Asked != 1 {
		t.Errorf("lyricfind = %+v, want 问过一次、记了一次 5xx 跳闸", c)
	}
	if day.Sources["applemusic"] != nil {
		t.Error("没连 Apple Music 账号时不该数它")
	}
	if ne := lyricSourceSummaryOf(t, f.Summary, "netease"); ne.Rounds != 1 || ne.Won != 1 {
		t.Errorf("摘要 netease = %+v", ne)
	}

	// 读回来接着记。
	again := loadLyricSourceStats(path, func() time.Time { return now })
	if again.data.Days[now.Format(lyricSourceStatsDayLayout)].Rounds != 1 {
		t.Error("读回之后丢了当天的计数")
	}
	if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	if broken := loadLyricSourceStats(path, func() time.Time { return now }); broken.data.Days == nil || len(broken.data.Days) != 0 {
		t.Errorf("坏文件该从头记,得到 %+v", broken.data.Days)
	}
}

func TestLyricSourceStatsSaveIfNeeded(t *testing.T) {
	now := lyricSourceStatsTestToday
	path := filepath.Join(t.TempDir(), lyricSourceStatsFileName)
	s := loadLyricSourceStats(path, func() time.Time { return now })
	s.lastSave = now
	s.saveIfNeeded()
	if _, err := os.Stat(path); err == nil {
		t.Fatal("没有新数据、离上次落盘不到一小时,不该写")
	}
	now = now.Add(lyricSourceStatsRefreshAge)
	s.saveIfNeeded()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("满一小时该重写一次(摘要跟着日期滚动): %v", err)
	}
	var f lyricSourceStatsFile
	if json.Unmarshal(b, &f) != nil || f.UpdatedAt != now.Unix() {
		t.Errorf("updated_at = %d, want %d", f.UpdatedAt, now.Unix())
	}
}

func TestLyricSourceStatsHealthItems(t *testing.T) {
	now := lyricSourceStatsTestToday
	if items := lyricSourceStatsHealthItems(nil, now); len(items) != 1 || items[0].Status != healthWarn {
		t.Fatalf("没有统计文件时 = %+v, want 一条 warn", items)
	}
	empty := &lyricSourceStatsFile{UpdatedAt: now.Unix(), Summary: []lyricSourceStatsSummary{{Source: "netease", Enabled: true}}}
	if items := lyricSourceStatsHealthItems(empty, now); len(items) != 1 || items[0].Status != healthOK || !strings.Contains(items[0].Detail, "还没有现查记录") {
		t.Errorf("有文件、近 7 天一次都没问过 = %+v, want 一条 ok 说还没有记录", items)
	}
	f := &lyricSourceStatsFile{
		UpdatedAt: now.Add(-time.Hour).Unix(),
		Summary: []lyricSourceStatsSummary{
			{Source: "netease", Enabled: true, Rounds: 100, Responded: 80, Won: 50},
			{Source: "kuwo", Enabled: true, Rounds: 90, Responded: 4, Alert: lyricSourceAlertBarely, PeerRate: 0.05, PeerRounds: 60},
			{Source: "musixmatch", Enabled: true, Rounds: 40, Responded: 2, Alert: lyricSourceAlertNetwork, SkipRate: 0.9, NetworkPeers: []string{"lyricfind", "deezer"}},
			// 关着的源、没问过的源都不列。
			{Source: "migu", Enabled: false, Rounds: 30, Alert: lyricSourceAlertBarely},
			{Source: "applemusic", Enabled: true},
		},
	}
	items := lyricSourceStatsHealthItems(f, now)
	if len(items) != 3 {
		t.Fatalf("items = %+v, want 一条总览 + kuwo、musixmatch 各一条", items)
	}
	head := items[0]
	if head.Status != healthOK || !strings.Contains(head.Detail, "netease 80%/50%(100)") || strings.Contains(head.Detail, "migu") || strings.Contains(head.Detail, "applemusic") {
		t.Errorf("总览 = %+v", head)
	}
	if items[1].Status != healthWarn || !strings.Contains(items[1].Name, "kuwo") || !strings.Contains(items[1].Detail, "60 次查询里,它只在 5%") {
		t.Errorf("kuwo = %+v", items[1])
	}
	if !strings.Contains(items[2].Detail, "90%") || !strings.Contains(items[2].Detail, "lyricfind/deezer") {
		t.Errorf("musixmatch = %+v", items[2])
	}

	f.UpdatedAt = now.Add(-3 * 24 * time.Hour).Unix()
	if head := lyricSourceStatsHealthItems(f, now)[0]; head.Status != healthWarn || !strings.Contains(head.Detail, "3 天没更新") {
		t.Errorf("统计停了 3 天 = %+v, want warn", head)
	}
	for _, it := range lyricSourceStatsHealthItems(f, now) {
		if it.Status == healthFail {
			t.Errorf("统计只出 warn,不该有 fail: %+v", it)
		}
	}
}
