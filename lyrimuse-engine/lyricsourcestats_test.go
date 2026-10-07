package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
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

// lyricSourceTestClassDays:同 lyricSourceTestDays,但每天都带 classes 标记(分两类记的日子);unsplit 里列的
// 那几天(往前第几天)除外。
func lyricSourceTestClassDays(spec map[int]map[string]lyricSourceDayCounts, unsplit ...int) map[string]*lyricSourceStatsDay {
	days := lyricSourceTestDays(spec)
	for ago := range spec {
		days[lyricSourceStatsTestToday.AddDate(0, 0, -ago).Format(lyricSourceStatsDayLayout)].Classes = !slices.Contains(unsplit, ago)
	}
	return days
}

// lyricSourceTestPeers:一天的同类条件计数,西文类 other 轮里给了 otherHits 次,中日韩类 cjk 轮里给了 cjkHits 次。
func lyricSourceTestPeers(other, otherHits, cjk, cjkHits int) lyricSourceDayCounts {
	return lyricSourceDayCounts{
		Asked: other + cjk, PeerRounds: other + cjk, PeerHits: otherHits + cjkHits,
		PeerRoundsCJK: cjk, PeerHitsCJK: cjkHits,
	}
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

// 中日韩文字的歌另记一份同类计数;被反爬拦下而跳过的另记一份。
func TestAddLyricSourceRoundSplitsClassesAndBlockedSkips(t *testing.T) {
	day := &lyricSourceStatsDay{}
	round := lyricSourceRoundOutcome{
		enabled:    []string{"lrclib", "musixmatch", "lyricfind", "deezer", "applemusic"},
		skipped:    map[string]bool{"musixmatch": true, "applemusic": true},
		skipReason: map[string]string{"musixmatch": lyricSourceCooldownReasonBlocked, "applemusic": lyricSourceCooldownReasonNetwork},
		responded:  map[string]bool{"lrclib": true, "deezer": true, "lyricfind": true},
		cjk:        true,
	}
	addLyricSourceRound(day, round)
	round.cjk = false
	round.responded = map[string]bool{"lrclib": true, "deezer": true}
	addLyricSourceRound(day, round)
	want := map[string]lyricSourceDayCounts{
		"lrclib":    {Asked: 2, Responded: 2, PeerRounds: 1, PeerHits: 1, PeerRoundsCJK: 1, PeerHitsCJK: 1},
		"deezer":    {Asked: 2, Responded: 2, PeerRounds: 1, PeerHits: 1, PeerRoundsCJK: 1, PeerHitsCJK: 1},
		"lyricfind": {Asked: 2, Responded: 1, PeerRounds: 2, PeerHits: 1, PeerRoundsCJK: 1, PeerHitsCJK: 1},
		// 被拦下跳过的另记一份;别的原因跳过的不记。
		"musixmatch": {Skipped: 2, SkippedBlocked: 2},
		"applemusic": {Skipped: 2},
	}
	for src, w := range want {
		if got := day.Sources[src]; got == nil || !reflect.DeepEqual(*got, w) {
			t.Errorf("%s = %+v, want %+v", src, got, w)
		}
	}
	if r, h := day.Sources["lyricfind"].classPeers(lyricSourceClassOther); r != 1 || h != 0 {
		t.Errorf("lyricfind 西文类 = %d/%d, want 1/0", r, h)
	}
}

func TestLyricSourceOutcomeFromDecision(t *testing.T) {
	d := &lyricsDecision{
		Path:             lyricsDecisionPathFirstResolve,
		QueryArtist:      "周杰伦",
		QueryTitle:       "Mojito",
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
		func(s string) bool { return s != "applemusic" },
		func(s string) string { return lyricSourceCooldownReasonBlocked })
	if !o.cjk || o.artist != lyricSourceArtistHash("周杰伦") {
		t.Errorf("cjk=%v artist=%d, want 歌手名带汉字就算中日韩那类、带上歌手名的哈希", o.cjk, o.artist)
	}
	if o.skipReason["kugou"] != lyricSourceCooldownReasonBlocked || len(o.skipReason) != 1 {
		t.Errorf("skipReason = %v, want 只问被跳过的 kugou", o.skipReason)
	}
	if o2 := lyricSourceOutcomeFromDecision(&lyricsDecision{QueryArtist: "Coldplay", QueryTitle: "Yellow"},
		allLyricSourcesOn, allLyricSourcesOn, nil); o2.cjk {
		t.Error("全是拉丁字母的歌不该算中日韩那类")
	}

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

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), nil, lyricSourceStatsTestToday, allLyricSourcesOn)
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
	// deezer:只听西文歌,平时一半,这 3 天只剩四分之一 —— 同一类里真的少了。
	lyricSourceTestRange(spec, 3, 16, "deezer", lyricSourceTestPeers(40, 20, 0, 0))
	lyricSourceTestRange(spec, 0, 2, "deezer", lyricSourceTestPeers(40, 10, 0, 0))
	// lyricfind(决策 202 那次误报的形状):西文歌六成、中文歌两成,两类都没变,只是平时西文歌多、这 3 天中文歌多。
	// 不分类的话 3 天 24% 对基线 49%,会报;按这几天的语言比例,平时就该是 24%。
	lyricSourceTestRange(spec, 3, 16, "lyricfind", lyricSourceTestPeers(50, 30, 20, 4))
	lyricSourceTestRange(spec, 0, 2, "lyricfind", lyricSourceTestPeers(5, 3, 45, 9))
	// lrclib:西文歌真的少了(六成 → 两成);中文歌每天不到 20 轮、没有基线,只拿西文那一类比,照样报。
	lyricSourceTestRange(spec, 3, 16, "lrclib", lyricSourceTestPeers(50, 30, 10, 9))
	lyricSourceTestRange(spec, 0, 2, "lrclib", lyricSourceTestPeers(40, 8, 30, 0))
	// musixmatch:够格的基线天只有 6 天,不到 7 天没有基线可比。
	lyricSourceTestRange(spec, 3, 8, "musixmatch", lyricSourceTestPeers(40, 36, 0, 0))
	lyricSourceTestRange(spec, 0, 2, "musixmatch", lyricSourceTestPeers(40, 5, 0, 0))
	// applemusic:3 天只有 90 轮,不到「比平时少」要的 100 轮。
	lyricSourceTestRange(spec, 3, 16, "applemusic", lyricSourceTestPeers(40, 36, 0, 0))
	lyricSourceTestRange(spec, 0, 2, "applemusic", lyricSourceTestPeers(30, 6, 0, 0))
	// kuwo:平时就低(基线不到 20%),再低一点也不判「比平时少」。
	lyricSourceTestRange(spec, 3, 16, "kuwo", lyricSourceTestPeers(0, 0, 40, 6))
	lyricSourceTestRange(spec, 0, 2, "kuwo", lyricSourceTestPeers(0, 0, 40, 5))

	out := summarizeLyricSourceStats(lyricSourceTestClassDays(spec), nil, lyricSourceStatsTestToday, allLyricSourcesOn)
	deezer := lyricSourceSummaryOf(t, out, "deezer")
	if deezer.Alert != lyricSourceAlertBelowUsual || deezer.PeerRate != 0.25 || deezer.UsualRate != 0.5 || deezer.PeerRounds != 120 {
		t.Errorf("deezer = %+v, want below_usual 0.25 vs 0.5 / 120", deezer)
	}
	lrclib := lyricSourceSummaryOf(t, out, "lrclib")
	if lrclib.Alert != lyricSourceAlertBelowUsual || lrclib.PeerRate != 0.2 || lrclib.UsualRate != 0.6 || lrclib.PeerRounds != 120 {
		t.Errorf("lrclib = %+v, want below_usual 0.2 vs 0.6 / 120(没有基线的中文那类不算)", lrclib)
	}
	for _, src := range []string{"lyricfind", "musixmatch", "applemusic", "kuwo"} {
		if a := lyricSourceSummaryOf(t, out, src).Alert; a != "" {
			t.Errorf("%s alert = %q, want 无", src, a)
		}
	}

	// 窗口那几天是升级当天那种半路才分类的日子:按两类没法算,不判。
	out = summarizeLyricSourceStats(lyricSourceTestClassDays(spec, 0, 1, 2), nil, lyricSourceStatsTestToday, allLyricSourcesOn)
	if a := lyricSourceSummaryOf(t, out, "deezer").Alert; a != "" {
		t.Errorf("窗口没分类时 deezer alert = %q, want 无", a)
	}
	// 基线那几天没分类(升级之前的老数据):没有基线,不判。
	var old []int
	for ago := 3; ago <= 16; ago++ {
		old = append(old, ago)
	}
	out = summarizeLyricSourceStats(lyricSourceTestClassDays(spec, old...), nil, lyricSourceStatsTestToday, allLyricSourcesOn)
	if a := lyricSourceSummaryOf(t, out, "deezer").Alert; a != "" {
		t.Errorf("基线没分类时 deezer alert = %q, want 无", a)
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

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), nil, lyricSourceStatsTestToday, allLyricSourcesOn)
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

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), nil, lyricSourceStatsTestToday, allLyricSourcesOn)
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

	out := summarizeLyricSourceStats(lyricSourceTestDays(spec), nil, lyricSourceStatsTestToday, func(s string) bool { return s != "migu" })
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

func TestLyricSourceClassBaselineMedian(t *testing.T) {
	keys := lyricSourceDayKeys(lyricSourceStatsTestToday, 3, lyricSourceBaselineDays)
	build := func(otherHits ...int) map[string]*lyricSourceStatsDay {
		spec := map[int]map[string]lyricSourceDayCounts{}
		for i, hits := range otherHits {
			// 中文那类每天 20 轮给 5 次,够格;西文那类按参数给。
			lyricSourceTestRange(spec, 3+i, 3+i, "qq", lyricSourceTestPeers(50, hits, 20, 5))
		}
		// 一类样本不到 20 轮的那天,那一类不算数。
		lyricSourceTestRange(spec, 16, 16, "qq", lyricSourceTestPeers(19, 0, 19, 0))
		return lyricSourceTestClassDays(spec)
	}
	usual, have := lyricSourceClassBaseline(build(10, 30, 20, 40, 15, 25, 35), "qq", keys)
	if !have[lyricSourceClassOther] || usual[lyricSourceClassOther] != 0.5 {
		t.Errorf("奇数天中位数 = %v %v, want 0.5", usual, have)
	}
	if !have[lyricSourceClassCJK] || usual[lyricSourceClassCJK] != 0.25 {
		t.Errorf("中文那类 = %v %v, want 0.25", usual, have)
	}
	if usual, have := lyricSourceClassBaseline(build(10, 30, 20, 40, 15, 25, 35, 45), "qq", keys); !have[lyricSourceClassOther] || usual[lyricSourceClassOther] != 0.55 {
		t.Errorf("偶数天中位数 = %v %v, want 0.55", usual, have)
	}
	if _, have := lyricSourceClassBaseline(build(10, 30, 20, 40, 15, 25), "qq", keys); have[lyricSourceClassOther] || have[lyricSourceClassCJK] {
		t.Error("够格的只有 6 天,不该有基线")
	}
	// 没分类的日子(升级之前的老数据)不算数。
	days := build(10, 30, 20, 40, 15, 25, 35)
	for _, d := range days {
		d.Classes = false
	}
	if _, have := lyricSourceClassBaseline(days, "qq", keys); have[lyricSourceClassOther] {
		t.Error("没分类的日子不该进基线")
	}
}

// 逐轮记录:只记同类条件成立的轮和它给了的轮;被跳过的带上原因;每个源只留最近 lyricSourceRecentKeep 条。
func TestAddLyricSourceRecent(t *testing.T) {
	recent := map[string][]lyricSourceRecentRound{}
	at := lyricSourceStatsTestToday
	addLyricSourceRecent(recent, lyricSourceRoundOutcome{
		enabled:    []string{"netease", "qq", "kugou", "lrclib", "musixmatch", "lyricfind", "deezer", "amll"},
		skipped:    map[string]bool{"lyricfind": true, "deezer": true},
		skipReason: map[string]string{"lyricfind": lyricSourceCooldownReasonBlocked},
		responded:  map[string]bool{"netease": true, "lrclib": true, "musixmatch": true, "amll": true},
		cjk:        true,
		artist:     7,
	}, at)
	want := map[string]lyricSourceRecentRound{
		// 同类只有它自己给了,也记:说明它还活着。
		"netease": {At: at.Unix(), Hit: true, CJK: true, Artist: 7},
		"lrclib":  {At: at.Unix(), Hit: true, CJK: true, Artist: 7},
		// 同类两家给了、它没给。
		"lyricfind": {At: at.Unix(), Skip: lyricSourceCooldownReasonBlocked, CJK: true, Artist: 7},
		// 被跳过却说不出原因(冷却刚好到期)。
		"deezer":     {At: at.Unix(), Skip: lyricSourceSkipReasonUnknown, CJK: true, Artist: 7},
		"musixmatch": {At: at.Unix(), Hit: true, CJK: true, Artist: 7},
	}
	if len(recent) != len(want) {
		t.Fatalf("记了 %d 个源,want %d(qq、kugou 同类不到两家又没给,amll 不进组): %v", len(recent), len(want), recent)
	}
	for src, w := range want {
		if got := recent[src]; len(got) != 1 || got[0] != w {
			t.Errorf("%s = %+v, want %+v", src, got, w)
		}
	}

	for i := range lyricSourceRecentKeep + 5 {
		addLyricSourceRecent(recent, lyricSourceRoundOutcome{
			enabled:   []string{"lrclib"},
			responded: map[string]bool{"lrclib": true},
		}, at.Add(time.Duration(i+1)*time.Minute))
	}
	if got := recent["lrclib"]; len(got) != lyricSourceRecentKeep || got[len(got)-1].At != at.Add(time.Duration(lyricSourceRecentKeep+5)*time.Minute).Unix() {
		t.Errorf("lrclib 留了 %d 条,want 最近 %d 条", len(got), lyricSourceRecentKeep)
	}
}

// 连续一段:从最新往回数到它上一次给出为止;每位歌手只算一次;被拦下的单独数;没有基线的那一类不加。
func TestLyricSourceStreakOf(t *testing.T) {
	recent := []lyricSourceRecentRound{
		{Artist: 9},            // 再往前的不看
		{Hit: true, Artist: 1}, // 上一次给出
		{Artist: 2, CJK: true}, // 中文那类
		{Artist: 2, CJK: true}, // 同一位歌手,不再加
		{Skip: lyricSourceCooldownReasonBlocked, Artist: 3},
		{Skip: lyricSourceCooldownReasonNetwork, Artist: 4},
		{Artist: 5}, // 西文那类
	}
	var usual [lyricSourceClassCount]float64
	var have [lyricSourceClassCount]bool
	usual[lyricSourceClassOther], have[lyricSourceClassOther] = 0.5, true
	usual[lyricSourceClassCJK], have[lyricSourceClassCJK] = 0.25, true
	if st := lyricSourceStreakOf(recent, usual, have); st.rounds != 5 || st.blocked != 1 || st.expected != 0.75 {
		t.Errorf("streak = %+v, want 5 轮、拦下 1 轮、本该 0.75 次", st)
	}
	have[lyricSourceClassCJK] = false
	if st := lyricSourceStreakOf(recent, usual, have); st.expected != 0.5 {
		t.Errorf("中文那类没有基线时 expected = %v, want 只加西文那位 0.5", st.expected)
	}
	if st := lyricSourceStreakOf(append(recent, lyricSourceRecentRound{Hit: true}), usual, have); st.rounds != 0 {
		t.Errorf("最新一轮给了,streak = %+v, want 空", st)
	}
}

// lyricSourceTestStreak:先给出一次,再接 n 轮没给(每轮一位不同的歌手,从 firstArtist 起编号)。
func lyricSourceTestStreak(n int, cjk bool, firstArtist uint32, skip string) []lyricSourceRecentRound {
	out := []lyricSourceRecentRound{{Hit: true}}
	for i := range n {
		out = append(out, lyricSourceRecentRound{CJK: cjk, Artist: firstArtist + uint32(i), Skip: skip})
	}
	return out
}

func TestSummarizeLyricSourceStatsStopped(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	for _, src := range []string{"musixmatch", "lyricfind", "deezer", "applemusic"} {
		// 西文歌平时九成(lyricfind 六成)、中文歌平时两成。
		hits := 36
		if src == "lyricfind" {
			hits = 24
		}
		lyricSourceTestRange(spec, 3, 16, src, lyricSourceTestPeers(40, hits, 20, 4))
	}
	// musixmatch 这 3 天同时也够「几乎不给词」,「突然不给了」排在前面。
	lyricSourceTestRange(spec, 0, 2, "musixmatch", lyricSourceTestPeers(20, 1, 0, 0))
	// qq:2 天里大半被熔断跳过(5xx),冷却排在「突然不给了」前面。
	lyricSourceTestRange(spec, 0, 1, "qq", lyricSourceDayCounts{Asked: 5, Skipped: 15, Trips: map[string]int{lyricSourceCooldownReasonServerError: 2}})
	days := lyricSourceTestClassDays(spec)
	recent := map[string][]lyricSourceRecentRound{
		// 20 位不同的歌手、平时九成:本该给 18 次,一次都没给。
		"musixmatch": lyricSourceTestStreak(20, false, 100, ""),
		// 中文歌 30 位、平时两成:本该给 6 次,不到 12 次,说明不了什么。
		"lyricfind": lyricSourceTestStreak(30, true, 100, ""),
		// 40 轮,但都是同 3 位歌手(整张专辑预取):本该给 2.7 次。
		"deezer": func() []lyricSourceRecentRound {
			out := []lyricSourceRecentRound{{Hit: true}}
			for i := range 40 {
				out = append(out, lyricSourceRecentRound{Artist: uint32(100 + i%3)})
			}
			return out
		}(),
		// 19 轮,不到 20 轮。
		"applemusic": lyricSourceTestStreak(19, false, 100, ""),
		// lrclib 没有基线(没有统计天):本该给 0 次。
		"lrclib": lyricSourceTestStreak(40, false, 100, ""),
		"qq":     lyricSourceTestStreak(40, true, 100, ""),
	}
	out := summarizeLyricSourceStats(days, recent, lyricSourceStatsTestToday, allLyricSourcesOn)
	mx := lyricSourceSummaryOf(t, out, "musixmatch")
	if mx.Alert != lyricSourceAlertStopped || mx.Streak != 20 || mx.ExpectedHits != 18 {
		t.Errorf("musixmatch = %+v, want stopped 20 轮、本该 18 次", mx)
	}
	if qq := lyricSourceSummaryOf(t, out, "qq"); qq.Alert != lyricSourceAlertCooling {
		t.Errorf("qq = %+v, want cooling 排在前面", qq)
	}
	for _, src := range []string{"lyricfind", "deezer", "applemusic", "lrclib"} {
		if a := lyricSourceSummaryOf(t, out, src).Alert; a != "" {
			t.Errorf("%s alert = %q, want 无", src, a)
		}
	}
}

func TestSummarizeLyricSourceStatsBlocked(t *testing.T) {
	spec := map[int]map[string]lyricSourceDayCounts{}
	// lyricfind:2 天里大半被跳过,其中大半是被反爬拦下。
	lyricSourceTestRange(spec, 0, 1, "lyricfind", lyricSourceDayCounts{Asked: 5, Skipped: 15, SkippedBlocked: 12, Trips: map[string]int{lyricSourceCooldownReasonBlocked: 1}})
	// kugou:2 天里大半被跳过,拦下的不到一半:照旧报冷却。
	lyricSourceTestRange(spec, 0, 1, "kugou", lyricSourceDayCounts{Asked: 5, Skipped: 15, SkippedBlocked: 5})
	days := lyricSourceTestClassDays(spec)
	mixed := lyricSourceTestStreak(5, false, 100, "")
	mixed = append(mixed, lyricSourceTestStreak(20, false, 200, lyricSourceCooldownReasonBlocked)[1:]...)
	recent := map[string][]lyricSourceRecentRound{
		// 按天还看不出来(今天才开始被拦),最近 25 轮里 20 轮是被拦下跳过的。
		"musixmatch": mixed,
		// 最近 25 轮里 20 轮因为连不上被跳过:不是被拦,也没有基线说它本该给多少,不报。
		"deezer": append(lyricSourceTestStreak(5, false, 100, ""), lyricSourceTestStreak(20, false, 200, lyricSourceCooldownReasonNetwork)[1:]...),
	}
	out := summarizeLyricSourceStats(days, recent, lyricSourceStatsTestToday, allLyricSourcesOn)
	if mx := lyricSourceSummaryOf(t, out, "musixmatch"); mx.Alert != lyricSourceAlertBlocked || mx.Streak != 25 || mx.BlockedRounds != 20 {
		t.Errorf("musixmatch = %+v, want blocked 25 轮里 20 轮被拦", mx)
	}
	if lf := lyricSourceSummaryOf(t, out, "lyricfind"); lf.Alert != lyricSourceAlertBlocked || lf.BlockedRounds != 24 || lf.SkipRate != 0.75 {
		t.Errorf("lyricfind = %+v, want blocked(按 2 天)24 轮", lf)
	}
	if kg := lyricSourceSummaryOf(t, out, "kugou"); kg.Alert != lyricSourceAlertCooling {
		t.Errorf("kugou = %+v, want cooling", kg)
	}
	if a := lyricSourceSummaryOf(t, out, "deezer").Alert; a != "" {
		t.Errorf("deezer alert = %q, want 无", a)
	}

	// lyricfind 已经恢复(最近记下的那一轮给了):2 天窗口里的跳过还没滚出去,也不再报「已暂停」。
	recent["lyricfind"] = []lyricSourceRecentRound{{Skip: lyricSourceCooldownReasonBlocked}, {Hit: true}}
	// kugou 不是被拦的,照旧按 2 天报冷却(这条规则只管被拦)。
	recent["kugou"] = []lyricSourceRecentRound{{Hit: true}}
	out = summarizeLyricSourceStats(days, recent, lyricSourceStatsTestToday, allLyricSourcesOn)
	if a := lyricSourceSummaryOf(t, out, "lyricfind").Alert; a != "" {
		t.Errorf("恢复之后 lyricfind alert = %q, want 无", a)
	}
	if a := lyricSourceSummaryOf(t, out, "kugou").Alert; a != lyricSourceAlertCooling {
		t.Errorf("kugou alert = %q, want cooling", a)
	}
}

func TestPruneLyricSourceRecent(t *testing.T) {
	now := lyricSourceStatsTestToday
	old, fresh := now.Add(-8*24*time.Hour).Unix(), now.Add(-time.Hour).Unix()
	recent := map[string][]lyricSourceRecentRound{
		"lrclib":  {{At: old}, {At: fresh, Hit: true}},
		"deezer":  {{At: old}},
		"netease": {{At: fresh}},
	}
	pruneLyricSourceRecent(recent, now, lyricSourceRecentMaxAge)
	if got := recent["lrclib"]; len(got) != 1 || got[0].At != fresh {
		t.Errorf("lrclib = %+v, want 只留一小时前那条", got)
	}
	if _, ok := recent["deezer"]; ok {
		t.Error("deezer 全过期了,整个删掉")
	}
	if len(recent["netease"]) != 1 {
		t.Error("netease 没过期,不动")
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
	if !day.Classes {
		t.Error("新开的一天该从第一轮起就分两类记")
	}
	if got := f.Recent["netease"]; len(got) != 1 || !got[0].Hit || got[0].At != now.Unix() {
		t.Errorf("逐轮记录 netease = %+v, want 记下它给了的那一轮", got)
	}

	// 读回来接着记。
	again := loadLyricSourceStats(path, func() time.Time { return now })
	if again.data.Days[now.Format(lyricSourceStatsDayLayout)].Rounds != 1 || len(again.data.Recent["netease"]) != 1 {
		t.Error("读回之后丢了当天的计数或逐轮记录")
	}

	// 升级那天:旧版本开的这一天没分类,接着记也不补标记(当天前半段没分过)。
	legacy := `{"updated_at":1,"days":{"` + now.Format(lyricSourceStatsDayLayout) + `":{"rounds":5,"sources":{}}}}`
	if err := os.WriteFile(path, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}
	upgraded := loadLyricSourceStats(path, func() time.Time { return now })
	lyricSourceStatsShared.Store(upgraded)
	noteLyricSourceDecision(&lyricsDecision{Path: lyricsDecisionPathFirstResolve, Winner: "netease"})
	if d := upgraded.data.Days[now.Format(lyricSourceStatsDayLayout)]; d.Rounds != 6 || d.Classes {
		t.Errorf("升级那天 = %+v, want 接着记、不带分类标记", d)
	}
	if err := os.WriteFile(path, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	if broken := loadLyricSourceStats(path, func() time.Time { return now }); broken.data.Days == nil || len(broken.data.Days) != 0 {
		t.Errorf("坏文件该从头记,得到 %+v", broken.data.Days)
	}
}

// 常驻进程的起停:启动时清掉上一个进程写到一半留下的临时文件(只清这份统计的、一分钟以前的),退出前等
// 定时落盘停下再写最后一次 —— 原来最后一次没人等,main 退出时写到一半的临时文件就留在配置目录里。
func TestStartStopLyricSourceStatsFlushesAndSweepsTemps(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	prevFeatures := featuresSnapshot.Load()
	t.Cleanup(func() { featuresSnapshot.Store(prevFeatures) })
	setFeatures(featureFlags{})
	t.Cleanup(func() { lyricSourceStatsShared.Store(nil) })

	path := filepath.Join(dir, lyricSourceStatsFileName)
	stale, fresh := path+".tmp.111", path+".tmp.222"
	other := filepath.Join(dir, "lyrimuse-enrich-cache.json.tmp.333")
	for _, p := range []string{stale, fresh, other} {
		if err := os.WriteFile(p, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-2 * time.Minute)
	for _, p := range []string{stale, other} {
		if err := os.Chtimes(p, past, past); err != nil {
			t.Fatal(err)
		}
	}

	startLyricSourceStats(context.Background())
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("一分钟以前的统计临时文件该清掉")
	}
	for _, p := range []string{fresh, other} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s 不该动: %v", filepath.Base(p), err)
		}
	}

	noteLyricSourceDecision(&lyricsDecision{
		Path:       lyricsDecisionPathFirstResolve,
		Candidates: []lyricsDecisionCandidate{{Source: "netease", Score: 300}},
		Winner:     "netease",
	})
	stopLyricSourceStats()
	f := readLyricSourceStatsFile()
	if f == nil {
		t.Fatal("没写出统计文件")
	}
	if day := f.Days[time.Now().Format(lyricSourceStatsDayLayout)]; day == nil || day.Rounds != 1 {
		t.Errorf("今天 = %+v, want 退出前写下刚记的那一轮", day)
	}
	if left, _ := filepath.Glob(path + ".tmp.*"); len(left) != 1 || left[0] != fresh {
		t.Errorf("剩下的临时文件 = %v, want 只有刚才那份新的", left)
	}
	// 没在常驻进程里(没起过)时是空操作。
	lyricSourceStatsShared.Store(nil)
	stopLyricSourceStats()
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
	details := map[string]lyricSourceStatsSummary{
		"按这几天的语种构成平时约 49%": {Alert: lyricSourceAlertBelowUsual, PeerRounds: 446, PeerRate: 0.345, UsualRate: 0.49},
		"最近 20 次查询因此没问它":   {Alert: lyricSourceAlertBlocked, BlockedRounds: 20},
		"最近连续 25 次":        {Alert: lyricSourceAlertStopped, Streak: 25, ExpectedHits: 18},
		"按平时本该给约 18 次":     {Alert: lyricSourceAlertStopped, Streak: 25, ExpectedHits: 18},
	}
	for want, s := range details {
		if got := lyricSourceAlertDetail(s); !strings.Contains(got, want) {
			t.Errorf("%s 的说明 = %q, want 含 %q", s.Alert, got, want)
		}
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
