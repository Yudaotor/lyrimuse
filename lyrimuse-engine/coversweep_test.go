package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// coverSweepCall 是假的 backfillPeripheralFields 收到的一次调用。
type coverSweepCall struct {
	key, artist, title, album string
	dur                       float64
	background, deferredSave  bool
}

// withCoverSweepFakes 换掉补一条、观察请求和等待:每补一条先调 onBackfill(可以改缓存),再按 rounds 依次报这一条的
// (请求数, 失败数),报完了沿用最后一个。返回记下的调用与等待时长。
func withCoverSweepFakes(t *testing.T, rounds [][2]int32, onBackfill func(key string)) (*[]coverSweepCall, *[]time.Duration) {
	t.Helper()
	savedBackfill, savedRound, savedWait, savedSave := coverSweepBackfill, coverSweepNetworkRound, coverSweepWait, coverSweepSave
	enrichMu.Lock()
	savedInflight := enrichInflight
	enrichInflight = map[string]bool{}
	enrichMu.Unlock()
	t.Cleanup(func() {
		coverSweepBackfill, coverSweepNetworkRound, coverSweepWait, coverSweepSave = savedBackfill, savedRound, savedWait, savedSave
		enrichMu.Lock()
		enrichInflight = savedInflight
		enrichMu.Unlock()
	})
	var calls []coverSweepCall
	var waits []time.Duration
	coverSweepWait = func(_ context.Context, d time.Duration) { waits = append(waits, d) }
	coverSweepSave = func() {}
	coverSweepBackfill = func(ctx context.Context, key, artist, title, album string, dur float64) {
		calls = append(calls, coverSweepCall{key, artist, title, album, dur, isBackgroundOutbound(ctx), coverSweepSaveDeferred(ctx)})
		if onBackfill != nil {
			onBackfill(key)
		}
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}
	coverSweepNetworkRound = func(ctx context.Context) (context.Context, func() (int32, int32)) {
		r := rounds[min(len(calls), len(rounds)-1)]
		return ctx, func() (int32, int32) { return r[0], r[1] }
	}
	return &calls, &waits
}

func coverSweepSetCover(key string) {
	enrichMu.Lock()
	e := enrichCache[key]
	e.CoverURL = "https://example.invalid/" + key
	enrichCache[key] = e
	enrichMu.Unlock()
}

const coverSweepLyrics = "[00:01.00]line"

func TestCoverSweepCandidates(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"B|t1|Album": {Lyrics: coverSweepLyrics},
		"A|t2|Z":     {Lyrics: coverSweepLyrics},
		"A|t1|Y":     {Instrumental: true},
		"A|t3|Y":     {ManualLyrics: true, Lyrics: coverSweepLyrics},
		"A|has|Y":    {Lyrics: coverSweepLyrics, CoverURL: "https://c"},
		"A|tried|Y":  {Lyrics: coverSweepLyrics, PeripheralRetryCount: 1, CoverMissingRetryRules: coverMissingRetryRules},
		"A|old|Y":    {Lyrics: coverSweepLyrics, PeripheralRetryCount: peripheralBackfillMaxAttempts},
		"A|recent|Y": {Lyrics: coverSweepLyrics, PeripheralRetryCount: 1, PeripheralTS: time.Now().Unix()},
		"A|nolyr|Y":  {},
		"|t|Y":       {Lyrics: coverSweepLyrics},
		"A|fresh|Y":  {Lyrics: coverSweepLyrics, TS: time.Now().Unix()},
		"A|busy|Y":   {Lyrics: coverSweepLyrics},
	})
	withCoverSweepFakes(t, [][2]int32{{1, 0}}, nil)
	enrichMu.Lock()
	enrichInflight["A|busy|Y"] = true
	got := coverSweepCandidatesLocked()
	enrichMu.Unlock()
	want := []string{"A|old|Y", "A|t1|Y", "A|t3|Y", "A|t2|Z", "B|t1|Album"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("候选 = %v, 要 %v(有封面、按这一版补过、没词、没歌手、刚解析过、刚补过、正在解析的都不挑;"+
			"按旧版补过的不管次数再挑一次;同歌手按专辑排)", got, want)
	}
}

func TestCoverSweepTitle(t *testing.T) {
	for in, want := range map[string]string{
		"Song~dur2": "Song", "Song~dur12": "Song", "Song": "Song", "Song~dur": "Song~dur",
		"Song~durX": "Song~durX", "Song~dur1": "Song~dur1", "~dur2": "~dur2",
	} {
		if got := coverSweepTitle(in); got != want {
			t.Errorf("coverSweepTitle(%q) = %q, 要 %q", in, got, want)
		}
	}
}

// 补上的、没补上的、轮到时已经不用补的各记一次;查的时候走后台档、标题去掉时长后缀、带上存着的时长;
// 两首之间等 coverSweepGap,轮到时不用补的那条之后不等。
func TestCoverSweepRunsEachCandidateOnce(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"A|Gone|Al":      {Lyrics: coverSweepLyrics, DurationSecs: 180},
		"A|Other|Al":     {Lyrics: coverSweepLyrics},
		"A|Song~dur2|Al": {Lyrics: coverSweepLyrics, ResolvedDurationSecs: 200, DurationSecs: 190},
	})
	calls, waits := withCoverSweepFakes(t, [][2]int32{{4, 1}}, func(key string) {
		switch key {
		case "A|Gone|Al":
			coverSweepSetCover("A|Other|Al")
		case "A|Song~dur2|Al":
			coverSweepSetCover(key)
		}
	})
	pass := runCoverSweep(context.Background())
	wantCalls := []coverSweepCall{
		{"A|Gone|Al", "A", "Gone", "Al", 180, true, true},
		{"A|Song~dur2|Al", "A", "Song", "Al", 200, true, true},
	}
	if !reflect.DeepEqual(*calls, wantCalls) {
		t.Fatalf("调用 = %+v, 要 %+v", *calls, wantCalls)
	}
	if want := (coverSweepPass{candidates: 3, filled: 1, missed: 1, skipped: 1}); pass != want {
		t.Errorf("结果 = %+v, 要 %+v", pass, want)
	}
	if want := []time.Duration{coverSweepGap}; !reflect.DeepEqual(*waits, want) {
		t.Errorf("等待 = %v, 要 %v", *waits, want)
	}
}

// 补一条不当场存盘(交给 backfillPeripheralFields 的 ctx 带着标记),每补完 coverSweepSaveEvery 条存一次,收尾再存剩下的;
// 轮到时不用补的不算。
func TestCoverSweepBatchesSaves(t *testing.T) {
	entries := map[string]enrichEntry{}
	for i := 0; i < 2*coverSweepSaveEvery+3; i++ {
		entries[fmt.Sprintf("A|%02d|X", i)] = enrichEntry{Lyrics: coverSweepLyrics}
	}
	entries["A|01a|X"] = enrichEntry{Lyrics: coverSweepLyrics}
	withEnrichCache(t, entries)
	var savesAt []int
	calls, _ := withCoverSweepFakes(t, [][2]int32{{3, 0}}, func(key string) {
		if key == "A|00|X" {
			coverSweepSetCover("A|01a|X")
		}
	})
	coverSweepSave = func() { savesAt = append(savesAt, len(*calls)) }
	pass := runCoverSweep(context.Background())
	if pass.skipped != 1 || len(*calls) != 2*coverSweepSaveEvery+3 {
		t.Fatalf("补了 %d 条, %+v", len(*calls), pass)
	}
	if want := []int{coverSweepSaveEvery, 2 * coverSweepSaveEvery, 2*coverSweepSaveEvery + 3}; !reflect.DeepEqual(savesAt, want) {
		t.Errorf("存盘时机(当时补到第几条) = %v, 要 %v", savesAt, want)
	}
	for _, c := range *calls {
		if !c.deferredSave {
			t.Fatalf("%s 没带上「先别存」的标记", c.key)
		}
	}
}

// 一个请求都没成功(全失败,或者一个都没发出去)的连着 coverSweepOfflineLimit 条,这一遍停下;中间成了一条就重新数。
func TestCoverSweepStopsAfterOfflineStreak(t *testing.T) {
	entries := map[string]enrichEntry{}
	for _, k := range []string{"A|1|X", "A|2|X", "A|3|X", "A|4|X", "A|5|X", "A|6|X", "A|7|X"} {
		entries[k] = enrichEntry{Lyrics: coverSweepLyrics}
	}
	withEnrichCache(t, entries)
	calls, waits := withCoverSweepFakes(t, [][2]int32{{3, 3}, {0, 0}, {5, 5}, {2, 2}, {4, 4}}, nil)
	pass := runCoverSweep(context.Background())
	if len(*calls) != coverSweepOfflineLimit || !pass.offline || pass.offlineItems != coverSweepOfflineLimit {
		t.Fatalf("补了 %d 条、offline=%v、没问成的 %d 条,要补 %d 条后停下", len(*calls), pass.offline, pass.offlineItems,
			coverSweepOfflineLimit)
	}
	want := []time.Duration{coverSweepOfflineWait, coverSweepOfflineWait, coverSweepOfflineWait, coverSweepOfflineWait}
	if !reflect.DeepEqual(*waits, want) {
		t.Errorf("等待 = %v, 要 %v", *waits, want)
	}

	withEnrichCache(t, entries)
	calls, _ = withCoverSweepFakes(t, [][2]int32{{3, 3}, {3, 3}, {3, 3}, {3, 3}, {3, 1}, {3, 3}, {3, 3}}, nil)
	if pass := runCoverSweep(context.Background()); pass.offline || len(*calls) != len(entries) || pass.missed != 1 {
		t.Errorf("中间成了一条就该重新数: 补了 %d 条, %+v", len(*calls), pass)
	}
}

// 一条补完成没成只数它自己发的请求:自己的全失败、同一时刻别处(中继推送)成功了一个,这一条照样算没问成,不记补法版本。
func TestCoverSweepCountsOnlyItsOwnRequests(t *testing.T) {
	productionRound := coverSweepNetworkRound // 下面的假实现会换掉它,先留一份正式那个
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer ok.Close()
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := dead.URL
	dead.Close()
	get := func(ctx context.Context, url string) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			t.Fatal(err)
		}
		if resp, err := doHTTPTracked(http.DefaultClient, req); err == nil {
			resp.Body.Close()
		}
	}
	for _, c := range []struct {
		name, own string
		want      coverSweepOutcome
	}{
		{"自己的全失败", deadURL, coverSweepOffline},
		{"自己的有成功", ok.URL, coverSweepMissed},
	} {
		withEnrichCache(t, map[string]enrichEntry{"A|1|X": {Lyrics: coverSweepLyrics}})
		withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
		coverSweepNetworkRound = productionRound
		coverSweepBackfill = func(ctx context.Context, key, _, _, _ string, _ float64) {
			get(ctx, c.own+"/cover")
			get(context.Background(), ok.URL+"/relay") // 别处的请求
			enrichMu.Lock()
			delete(enrichInflight, key)
			enrichMu.Unlock()
		}
		if got := coverSweepOne(context.Background(), "A|1|X"); got != c.want {
			t.Errorf("%s: 结果 %d,要 %d", c.name, got, c.want)
		}
	}
}

// 补过一次(补上了、没补上)记下这一版补法;一个请求都没成功的不记,下一遍还挑它。
func TestCoverSweepRecordsRetryRules(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"A|Hit|X":  {Lyrics: coverSweepLyrics},
		"A|Miss|X": {Lyrics: coverSweepLyrics},
		"A|Off|X":  {Lyrics: coverSweepLyrics},
	})
	withCoverSweepFakes(t, [][2]int32{{2, 0}, {2, 0}, {2, 2}}, func(key string) {
		if key == "A|Hit|X" {
			coverSweepSetCover(key)
		}
	})
	runCoverSweep(context.Background())
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for key, want := range map[string]int{"A|Hit|X": coverMissingRetryRules, "A|Miss|X": coverMissingRetryRules, "A|Off|X": 0} {
		if got := enrichCache[key].CoverMissingRetryRules; got != want {
			t.Errorf("%s:记的补法版本 %d,要 %d", key, got, want)
		}
	}
}

// 有别的歌在解析时先等它;一直不完也只等 coverSweepYieldMax。
func TestCoverSweepYieldsToResolvingEntries(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{"A|1|X": {Lyrics: coverSweepLyrics}})
	calls, waits := withCoverSweepFakes(t, [][2]int32{{1, 0}}, nil)
	enrichMu.Lock()
	enrichInflight["Z|playing|Y"] = true
	enrichMu.Unlock()
	polls := 0
	coverSweepWait = func(_ context.Context, d time.Duration) {
		*waits = append(*waits, d)
		if polls++; polls == 3 {
			enrichMu.Lock()
			delete(enrichInflight, "Z|playing|Y")
			enrichMu.Unlock()
		}
	}
	runCoverSweep(context.Background())
	if len(*calls) != 1 || len(*waits) != 3 || (*waits)[0] != coverSweepYieldPoll {
		t.Fatalf("要等三次再补: 调用 %d, 等待 %v", len(*calls), *waits)
	}

	withEnrichCache(t, map[string]enrichEntry{"A|1|X": {Lyrics: coverSweepLyrics}})
	calls, waits = withCoverSweepFakes(t, [][2]int32{{1, 0}}, nil)
	enrichMu.Lock()
	enrichInflight["Z|stuck|Y"] = true
	enrichMu.Unlock()
	runCoverSweep(context.Background())
	if want := int(coverSweepYieldMax / coverSweepYieldPoll); len(*calls) != 1 || len(*waits) != want {
		t.Errorf("一直有别的在解析时等满 %d 次照样补: 调用 %d, 等待 %d 次", want, len(*calls), len(*waits))
	}
}

// 外围补全一个请求都没成功的这一轮不记次数,后台补封面靠它不在断网时把次数耗光。
func TestBackfillPeripheralFieldsCountsOnlyReachedRounds(t *testing.T) {
	src := string(mustRead(t, "enrich.go"))
	start := strings.Index(src, "func backfillPeripheralFields(ctx context.Context,")
	if start < 0 {
		t.Fatal("找不到 backfillPeripheralFields(ctx context.Context, …)")
	}
	body := src[start:]
	if end := strings.Index(body, "\n}\n"); end >= 0 {
		body = body[:end]
	}
	begin := strings.Index(body, "ctx, networkRound := withNetworkRound(ctx)")
	resolve := strings.Index(body, "resolveTrackEnrichment(")
	if begin < 0 || resolve < 0 || begin > resolve {
		t.Error("要在发请求之前开始观察这一轮,而且只数这一轮自己的请求(ctx, networkRound := withNetworkRound(ctx))")
	}
	if !strings.Contains(body, "if attempts, failures := networkRound(); lyricsRoundConfirmsNoResult(attempts, failures) {\n\t\te.PeripheralRetryCount++") {
		t.Error("PeripheralRetryCount 只在这一轮有请求成功时才加")
	}
	if strings.Count(body, "e.PeripheralRetryCount++") != 1 {
		t.Error("PeripheralRetryCount 只该在那一处加")
	}
	if !strings.Contains(body, "!coverSweepSaveDeferred(ctx) || (cur != nil && *cur == key) {\n\t\t// 后台补封面那一遍攒着存") {
		t.Error("后台补封面带着「先别存」标记时不当场存盘,正在播的那首除外")
	}
}

func TestCoverSweeperStartedByRun(t *testing.T) {
	src, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "go startCoverSweeper(ctx)") {
		t.Error("run() 里要起 startCoverSweeper")
	}
}
