package main

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSodaPreviewMatches(t *testing.T) {
	// 真机:《一分之二》整首 282.801s,试听段 240.000 起、长 30.001;播放器报 30。
	p := sodaPreview{StartSecs: 240, DurSecs: 30.001, FullSecs: 282.801}
	cases := []struct {
		name string
		mr   float64
		want bool
	}{
		{"播放器报的是试听段长度", 30, true},
		{"报的是整首(会员 / 限免)", 282.801, false},
		{"差出两秒,不是这段", 32.5, false},
	}
	for _, c := range cases {
		if got := sodaPreviewMatches(c.mr, p); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
	short := sodaPreview{StartSecs: 0, DurSecs: 30, FullSecs: 32}
	if sodaPreviewMatches(30, short) {
		t.Errorf("整首只比试听段长 2s:不算试听,不换")
	}
}

func TestSodaArtistCandidates(t *testing.T) {
	got := sodaArtistCandidates("HUSH, 孙盛希")
	want := []string{"HUSH, 孙盛希", "HUSH", "孙盛希"}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
	if len(sodaArtistCandidates("王力宏")) != 1 {
		t.Errorf("单人署名只查它自己")
	}
}

func TestSodaPickPreview(t *testing.T) {
	// 真机搜索结果:《花田错》整首 228.023s,试听 120.960 起、长 60.001;播放器报 60。
	items := []sodaSearchItem{
		{ID: "1", Name: "花田错", Artist: "王力宏", Album: "盖世英雄", Duration: 228.023, PreviewStartMs: 120960, PreviewDurationMs: 60001},
		{ID: "2", Name: "花田错", Artist: "别的歌手", Album: "x", Duration: 200, PreviewStartMs: 10000, PreviewDurationMs: 60000},
		{ID: "3", Name: "花田错 (Live)", Artist: "王力宏", Album: "Live", Duration: 260, PreviewStartMs: 50000, PreviewDurationMs: 60000},
	}
	p, ok := sodaPickPreview(items, "王力宏", "花田错", "盖世英雄", 60)
	if !ok || p.StartSecs != 120.96 || math.Abs(p.FullSecs-228.023) > 1e-9 {
		t.Fatalf("应挑中原版那条: %+v %v", p, ok)
	}
	if _, ok := sodaPickPreview(items[:1], "王力宏", "花田错", "盖世英雄", 228.023); ok {
		t.Errorf("播放器报整首时不是试听")
	}
	if _, ok := sodaPickPreview(items[1:2], "王力宏", "花田错", "盖世英雄", 60); ok {
		t.Errorf("歌手对不上的不收")
	}
}

// 本地队列里有这首(推荐流里的歌):同步命中,交回试听段起点与整首时长,并发布给 App(按原始标签)。
func TestLiveAppSodaPreviewFromLocalQueue(t *testing.T) {
	tr := sodaTestTrack("一分之二", "HUSH|孙盛希", "出没地带", 282801, 1, 0)
	tr["preview"] = map[string]any{"start": 240000, "duration": 30001}
	path := writeTestSodaQueue(t, []map[string]any{tr})
	resetSodaLocalIndex(t, path)
	fix := filepath.Join(t.TempDir(), "preview.json")
	setPlayerPreviewFixPath(fix)
	t.Cleanup(func() { setPlayerPreviewFixPath("") })

	start, full, known, _ := liveAppSodaPreview(sodaMusicBundleID, "一分之二", "HUSH, 孙盛希", "出没地带", 30)
	if !known || start != 240 || full != 282.801 {
		t.Fatalf("本地队列里有这首的试听段: start %v full %v known %v", start, full, known)
	}
	data, err := os.ReadFile(fix)
	if err != nil {
		t.Fatalf("应该发布给 App: %v", err)
	}
	var st playerPreviewFixState
	if err := json.Unmarshal(data, &st); err != nil || st.PreviewStart != 240 || st.Title != "一分之二" || st.Artist != "HUSH, 孙盛希" {
		t.Fatalf("发布内容不对: %s", data)
	}

	if _, _, known, _ := liveAppSodaPreview("com.netease.163music", "一分之二", "HUSH, 孙盛希", "", 30); known {
		t.Errorf("别的播放器不查")
	}
	// 会话开在还没查到的那一拍(记的是试听段 30s),这一拍已是整首:补成整首,否则试听 30 秒就算收听。
	if !sodaPreviewSessionBackfill(sodaMusicBundleID, "HUSH, 孙盛希", "一分之二", 30, 282.801) {
		t.Errorf("会话时长应补成整首")
	}
	if sodaPreviewSessionBackfill(sodaMusicBundleID, "HUSH, 孙盛希", "一分之二", 200, 282.801) {
		t.Errorf("会话时长不是试听段长度的不碰(换曲预载窗口里的脏时长)")
	}
	if sodaPreviewSessionBackfill(sodaMusicBundleID, "别人", "别的歌", 30, 282.801) {
		t.Errorf("不是刚查到试听段的那一首不碰")
	}
}

// 本地没有:先在后台搜,这一拍报「还在搜」;搜到那一刻就发布、记下(App 可能先于下一拍换成整首),之后交回换算参数。
func TestLiveAppSodaPreviewViaSearch(t *testing.T) {
	path := writeTestSodaQueue(t, nil)
	resetSodaLocalIndex(t, path)
	calls := 0
	old := sodaPreviewSearchFn
	t.Cleanup(func() {
		sodaPreviewSearchFn = old
		sodaPreviewMu.Lock()
		sodaPreviewCache = map[string]sodaPreviewCacheEntry{}
		sodaPreviewInflight = map[string]bool{}
		sodaPreviewMu.Unlock()
	})
	fix := filepath.Join(t.TempDir(), "preview.json")
	setPlayerPreviewFixPath(fix)
	t.Cleanup(func() { setPlayerPreviewFixPath("") })
	release := make(chan struct{})
	sodaPreviewSearchFn = func(ctx context.Context, artist, title, album string, mr float64) (sodaPreview, bool) {
		calls++
		<-release
		return sodaPreview{StartSecs: 120.96, DurSecs: 60.001, FullSecs: 228.023}, true
	}
	if _, _, known, pending := liveAppSodaPreview(sodaMusicBundleID, "花田错", "王力宏", "盖世英雄", 60); known || !pending {
		t.Fatalf("第一拍还没搜到:不换算,但要报「还在搜」(先别解析歌词), known=%v pending=%v", known, pending)
	}
	close(release)
	deadline := time.Now().Add(2 * time.Second)
	for {
		sodaPreviewMu.Lock()
		_, done := sodaPreviewCache[normLoose("王力宏")+"|"+normLoose("花田错")]
		sodaPreviewMu.Unlock()
		if done || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	// 搜到的那一刻就该已经发布给 App,不等这一拍。
	data, err := os.ReadFile(fix)
	if err != nil {
		t.Fatalf("搜到之后应立刻发布: %v", err)
	}
	var st playerPreviewFixState
	if err := json.Unmarshal(data, &st); err != nil || st.PreviewStart != 120.96 || st.Title != "花田错" {
		t.Fatalf("发布内容不对: %s", data)
	}
	// App 抢在下一拍之前套上纠正、直接报整首:会话时长照样补得上。
	if !sodaPreviewSessionBackfill(sodaMusicBundleID, "王力宏", "花田错", 60.001, 228.023) {
		t.Error("搜到即记下,App 先换成整首时会话时长也要补")
	}
	start, full, known, _ := liveAppSodaPreview(sodaMusicBundleID, "花田错", "王力宏", "盖世英雄", 60)
	if !known || math.Abs(start-120.96) > 1e-9 || full != 228.023 {
		t.Fatalf("搜到之后交回换算参数: start %v full %v known %v", start, full, known)
	}
	if calls != 1 {
		t.Errorf("同一首只搜一次,实际 %d 次", calls)
	}
}
