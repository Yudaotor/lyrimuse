package main

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"
)

func stubHealthProbeSearch(t *testing.T, fn func(ctx context.Context, p healthProbeTrack) []scoredLyricCandidateResult) {
	t.Helper()
	saved := healthProbeSearch
	healthProbeSearch = fn
	t.Cleanup(func() { healthProbeSearch = saved })
}

func probeCandidates(sources ...string) []scoredLyricCandidateResult {
	out := make([]scoredLyricCandidateResult, len(sources))
	for i, s := range sources {
		out[i] = scoredLyricCandidateResult{Source: s, Score: 100}
	}
	return out
}

var testHealthProbes = []healthProbeTrack{{"中文歌手", "中文歌", ""}, {"English Artist", "English Song", ""}}

// 两首都按时回来:不算截断,每个源按给出过候选的首数计,同一首里重复出现只算一次。
func TestHealthProbeCountsSourcesPerProbe(t *testing.T) {
	stubHealthProbeSearch(t, func(_ context.Context, p healthProbeTrack) []scoredLyricCandidateResult {
		if p.title == "中文歌" {
			return probeCandidates("qq", "netease", "qq")
		}
		return probeCandidates("qq", "lrclib")
	})
	o := probeLyricSourcesWithin(testHealthProbes, time.Second, time.Second)
	if o.truncated {
		t.Fatal("都按时回来了,不该算截断")
	}
	if o.answered["qq"] != 2 || o.answered["netease"] != 1 || o.answered["lrclib"] != 1 {
		t.Errorf("answered = %v", o.answered)
	}
}

// 有一首到点还没跑完:主动取消(Canceled,不是 DeadlineExceeded),截断之前已经回来的源照算。
func TestHealthProbeCancelsAtBudget(t *testing.T) {
	ctxErr := make(chan error, 1)
	stubHealthProbeSearch(t, func(ctx context.Context, p healthProbeTrack) []scoredLyricCandidateResult {
		if p.title == "中文歌" {
			return probeCandidates("qq")
		}
		<-ctx.Done()
		ctxErr <- ctx.Err()
		return probeCandidates("lrclib")
	})
	start := time.Now()
	o := probeLyricSourcesWithin(testHealthProbes, 50*time.Millisecond, time.Second)
	if !o.truncated {
		t.Fatal("到点没跑完要标成截断")
	}
	if err := <-ctxErr; err != context.Canceled {
		t.Errorf("到点要主动取消,ctx.Err() = %v", err)
	}
	if o.answered["qq"] != 1 || o.answered["lrclib"] != 1 {
		t.Errorf("answered = %v", o.answered)
	}
	if el := time.Since(start); el > 500*time.Millisecond {
		t.Errorf("取消之后搜索一返回就该收工,用了 %s", el)
	}
}

// 搜索不理会取消、一直不回:等完收尾时限就不等了,已经回来的那首照算。
func TestHealthProbeGivesUpAfterGrace(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	stubHealthProbeSearch(t, func(_ context.Context, p healthProbeTrack) []scoredLyricCandidateResult {
		if p.title == "中文歌" {
			return probeCandidates("qq")
		}
		<-release
		return nil
	})
	start := time.Now()
	o := probeLyricSourcesWithin(testHealthProbes, 30*time.Millisecond, 30*time.Millisecond)
	if !o.truncated || o.answered["qq"] != 1 {
		t.Errorf("truncated = %v, answered = %v", o.truncated, o.answered)
	}
	if el := time.Since(start); el > 500*time.Millisecond {
		t.Errorf("时限 + 收尾一共 60ms,用了 %s", el)
	}
}

func healthItemsByName(items []healthCheckItem) map[string]healthCheckItem {
	m := make(map[string]healthCheckItem, len(items))
	for _, it := range items {
		m[it.Name] = it
	}
	return m
}

// 截断时没给出候选的源只报「这段时间里没回」,全部没回也不报 fail;没截断时照旧报「可能不可用」和 fail。
func TestHealthProbeItemsWhenTruncated(t *testing.T) {
	enabled := []string{"lrclib", "netease", "qq"}
	budget := 10 * time.Second

	got := healthItemsByName(healthProbeItems(enabled, 2,
		healthProbeOutcome{answered: map[string]int{"qq": 2, "netease": 1}, truncated: true}, budget, false))
	if it := got["网络"]; it.Status != healthWarn || !strings.Contains(it.Detail, "截断") {
		t.Errorf("网络 = %+v", it)
	}
	if it := got["源 lrclib"]; it.Status != healthWarn || !strings.Contains(it.Detail, "不一定坏了") {
		t.Errorf("源 lrclib = %+v", it)
	}
	if it := got["源 netease"]; it.Status != healthOK || !strings.Contains(it.Detail, "截断") {
		t.Errorf("源 netease = %+v", it)
	}
	if it := got["源 qq"]; it.Status != healthOK {
		t.Errorf("源 qq = %+v", it)
	}
	if it := got["歌词源整体"]; it.Status != healthOK || !strings.Contains(it.Detail, "2/3 个源在 10s 内给出了候选") {
		t.Errorf("截断时只说多少个源在时限内给出了候选: %+v", it)
	}

	none := map[string]int{}
	if it := healthItemsByName(healthProbeItems(enabled, 2,
		healthProbeOutcome{answered: none, truncated: true}, budget, false))["歌词源整体"]; it.Status != healthWarn {
		t.Errorf("截断时全部没回不该报 fail: %+v", it)
	}
	full := healthItemsByName(healthProbeItems(enabled, 2, healthProbeOutcome{answered: none}, budget, false))
	if it := full["歌词源整体"]; it.Status != healthFail {
		t.Errorf("跑完了还全部没有候选要报 fail: %+v", it)
	}
	if it := full["源 qq"]; it.Status != healthWarn || !strings.Contains(it.Detail, "可能不可用") {
		t.Errorf("源 qq = %+v", it)
	}
	if it := healthItemsByName(healthProbeItems(enabled, 2,
		healthProbeOutcome{answered: none, truncated: true}, budget, true))["网络"]; it.Status != healthFail {
		t.Errorf("请求全部发不出去时网络照旧报 fail: %+v", it)
	}
}

func stubOwnLyricSourceProbes(t *testing.T, m map[string]func(ctx context.Context) bool) {
	t.Helper()
	saved := ownLyricSourceProbe
	ownLyricSourceProbe = func(source string) func(context.Context) bool { return m[source] }
	t.Cleanup(func() { ownLyricSourceProbe = saved })
}

// 专用探测曲:只给启用了、配了它的源起跑;问出来的记下;到点没回的被取消、算没答;都回来了立刻返回;不理取消的不等过 grace。
func TestOwnLyricSourceProbes(t *testing.T) {
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	stubOwnLyricSourceProbes(t, map[string]func(context.Context) bool{
		"zing":     func(context.Context) bool { return true },
		"bad":      func(context.Context) bool { return false },
		"slow":     func(ctx context.Context) bool { <-ctx.Done(); return false },
		"disabled": func(context.Context) bool { t.Error("没启用的源不该起跑"); return true },
	})
	begin := time.Now()
	got := startOwnLyricSourceProbes([]string{"zing", "bad", "slow", "qq"}, 30*time.Millisecond)(5 * time.Second)
	if !got["zing"] || got["bad"] || got["slow"] || len(got) != 1 {
		t.Errorf("got %v", got)
	}
	if d := time.Since(begin); d > 2*time.Second {
		t.Errorf("都回来了还等了 %s", d)
	}

	stubOwnLyricSourceProbes(t, map[string]func(context.Context) bool{
		"stuck":  func(context.Context) bool { <-block; return true },
		"stuck2": func(context.Context) bool { <-block; return true },
	})
	done := make(chan map[string]bool, 1)
	go func() {
		done <- startOwnLyricSourceProbes([]string{"stuck", "stuck2"}, 10*time.Millisecond)(50 * time.Millisecond)
	}()
	select {
	case got := <-done:
		if len(got) != 0 {
			t.Errorf("没回来的算没答: %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Error("过了 grace 还在等")
	}
}

// 专用探测曲问出来的源报 ok、不算哑掉;两首共用探测曲都答了的照旧按首数报。
func TestHealthProbeItemsOwnProbe(t *testing.T) {
	enabled := []string{"qq", "zing"}
	got := healthItemsByName(healthProbeItems(enabled, 2,
		healthProbeOutcome{answered: map[string]int{"qq": 2}, ownAnswered: map[string]bool{"zing": true}}, 10*time.Second, false))
	if it := got["源 zing"]; it.Status != healthOK || !strings.Contains(it.Detail, "专用探测曲") {
		t.Errorf("源 zing = %+v", it)
	}
	if it := got["源 qq"]; it.Status != healthOK || !strings.Contains(it.Detail, "2/2") {
		t.Errorf("源 qq = %+v", it)
	}
	if it, ok := got["歌词源整体"]; ok {
		t.Errorf("没有哑掉的源时不出整体项: %+v", it)
	}
	none := healthItemsByName(healthProbeItems(enabled, 2,
		healthProbeOutcome{answered: map[string]int{"qq": 2}}, 10*time.Second, false))
	if it := none["源 zing"]; it.Status != healthWarn {
		t.Errorf("专用探测曲也没答时照旧报 warn: %+v", it)
	}
}

// 配了专用探测曲的源都得在已登记的源里。
func TestLyricSourceOwnProbesAreRegisteredSources(t *testing.T) {
	probed := 0
	for _, d := range registryDescriptors() {
		if ownLyricSourceProbe(d.Name) == nil {
			continue
		}
		probed++
		if !slices.Contains(allLyricSourceConstants(), d.Name) {
			t.Errorf("%s 不是登记过的源", d.Name)
		}
	}
	if probed != len(lyricSourceOwnProbeTracks) {
		t.Errorf("配了专用探测曲的源有 %d 个,期望表里 %d 个", probed, len(lyricSourceOwnProbeTracks))
	}
}

// Zing 的专用探测曲:搜得到、取得到词就算答了;搜不到不算。问的是描述符里登记的那一首。
func TestZingOwnProbeAsksItsProbeTrack(t *testing.T) {
	resetZingState(t)
	const fileURL = "https://static-zmp3.zmdcdn.me/lyrics/probe.lrc"
	found := true
	var asked []string
	zingSimpleFake(t, func(r *http.Request, target string) (int, string) {
		switch target {
		case "https://zingmp3.vn" + zingSearchPath:
			asked = append(asked, r.URL.Query().Get("q"))
			if !found {
				return http.StatusOK, zingTestEmptySearch
			}
			return http.StatusOK, `{"err":0,"data":{"items":[{"encodeId":"ZPROBE","title":"Lạc Trôi","artistsNames":"Sơn Tùng M-TP","duration":233,"hasLyric":true}]}}`
		case "https://zingmp3.vn" + zingLyricPath:
			return http.StatusOK, zingTestLyric(fileURL)
		case fileURL:
			return http.StatusOK, zingTestLRC
		}
		return http.StatusNotFound, ""
	})
	if !ownLyricSourceProbe(lyricSourceZing)(qqRoundCtx()) {
		t.Error("搜到《Lạc Trôi》并取到词,该算答了")
	}
	if len(asked) == 0 || !strings.Contains(asked[0], "Lạc Trôi") {
		t.Errorf("探测问的不是登记的那一首: %q", asked)
	}
	resetZingState(t)
	found = false
	if ownLyricSourceProbe(lyricSourceZing)(qqRoundCtx()) {
		t.Error("搜不到,不该算答了")
	}
}

// 汽水的专用探测曲走搜索那条路:整页搜索被拒时从联想问到《十年》、取得到词就算答了;联想里没有就不算。
func TestSodaOwnProbeUsesSearchPath(t *testing.T) {
	sug := `{"status_info":{},"sugs":[{"suggestion":"十年 陈奕迅","content_type":"track","entity":{"track":{"id":"91"}}}]}`
	sodaSuggestFake(t, http.StatusOK, "", sug, map[string]sodaSeoTrackResponse{
		"91": sodaTestSeoFor("91", "十年", "陈奕迅", 205000, sodaTestLyricContent),
	})
	if !ownLyricSourceProbe(lyricSourceSoda)(qqRoundCtx()) {
		t.Error("联想问到《十年》并取到词,该算答了")
	}
	sodaSuggestFake(t, http.StatusOK, "", `{"status_info":{}}`, nil)
	if ownLyricSourceProbe(lyricSourceSoda)(qqRoundCtx()) {
		t.Error("联想里没有,不该算答了")
	}
}
