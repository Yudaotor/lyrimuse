package main

import (
	"context"
	"fmt"
	"image"
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
	savedQQAlbumName, savedCoverImage, savedAppleCover := coverSweepQQAlbumName, coverSweepCoverImage, coverSweepAppleCover
	coverPictureMu.Lock()
	savedPictures := coverPictureMemo
	coverPictureMemo = map[string]coverPicture{}
	coverPictureMu.Unlock()
	enrichMu.Lock()
	savedInflight := enrichInflight
	enrichInflight = map[string]bool{}
	enrichMu.Unlock()
	t.Cleanup(func() {
		coverSweepBackfill, coverSweepNetworkRound, coverSweepWait, coverSweepSave = savedBackfill, savedRound, savedWait, savedSave
		coverSweepQQAlbumName, coverSweepCoverImage, coverSweepAppleCover = savedQQAlbumName, savedCoverImage, savedAppleCover
		coverPictureMu.Lock()
		coverPictureMemo = savedPictures
		coverPictureMu.Unlock()
		enrichMu.Lock()
		enrichInflight = savedInflight
		enrichMu.Unlock()
	})
	var calls []coverSweepCall
	var waits []time.Duration
	coverSweepWait = func(_ context.Context, d time.Duration) { waits = append(waits, d) }
	coverSweepSave = func() {}
	coverSweepQQAlbumName = func(context.Context, string) (string, error) { return "", nil }
	coverSweepCoverImage = func(context.Context, string) image.Image { return nil }
	coverSweepAppleCover = func(context.Context, string, string, string, float64) (string, string, bool) { return "", "", true }
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

// 后台补封面开头那一步:没封面的补上,封面明确是另一张专辑的换成歌词胜出那个源自带、专辑对得上的(主色一起清掉);
// 专辑对得上的、判不出专辑的、候选专辑也对不上的不动。
func TestCoverSweepFillFromDecisionsReplacesAnotherAlbumCover(t *testing.T) {
	decision := func(album string) *lyricsDecision {
		return &lyricsDecision{Winner: "soda", Candidates: []lyricsDecisionCandidate{
			{Source: "soda", Score: 1310, Album: album, CoverURL: "https://s/1.jpg"}}}
	}
	other := enrichEntry{CoverURL: "https://n/1.jpg", CoverSource: "netease", CoverAlbum: "最新热歌慢摇69", AccentColor: "#ad976f"}
	withEnrichCache(t, map[string]enrichEntry{
		"A|empty|Alb":  {LyricsDecision: decision("Alb")},
		"A|other|Alb":  func() enrichEntry { e := other; e.LyricsDecision = decision("Alb"); return e }(),
		"A|fits|Alb":   {CoverURL: "https://n/2.jpg", CoverSource: "netease", CoverAlbum: "Alb", LyricsDecision: decision("Alb")},
		"A|qq|Alb":     {CoverURL: "https://q/1.jpg", CoverSource: "qq", LyricsDecision: decision("Alb")},
		"A|nocand|Alb": func() enrichEntry { e := other; e.LyricsDecision = decision("Else"); return e }(),
	})
	if n := coverSweepFillFromDecisions(); n != 2 {
		t.Fatalf("补上 / 换上 %d 条, 要 2", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|empty|Alb"]; e.CoverURL != "https://s/1.jpg" || e.CoverSource != "soda" || e.CoverAlbum != "Alb" {
		t.Errorf("没封面的要补上: %+v", e)
	}
	if e := enrichCache["A|other|Alb"]; e.CoverURL != "https://s/1.jpg" || e.CoverSource != "soda" || e.CoverAlbum != "Alb" || e.AccentColor != "" {
		t.Errorf("另一张专辑的封面要换掉、主色清空: %+v", e)
	}
	for key, want := range map[string]string{"A|fits|Alb": "https://n/2.jpg", "A|qq|Alb": "https://q/1.jpg", "A|nocand|Alb": "https://n/1.jpg"} {
		if got := enrichCache[key].CoverURL; got != want {
			t.Errorf("%s 不该动: 得到 %q", key, got)
		}
	}
}

// 后台补封面开头:同一张专辑已经有一条归属核实过的设备封面,归属没核实的(没记专辑的 QQ、写着另一张专辑的网易云)换成那张,
// cover_album 记本地专辑、主色清空;已经逐字对上的、播放器自己的、没封面的、同一张图的、正在解析的、别的歌手或专辑的不动;
// 设备封面自己的 cover_album 没对上的不借出去(03 章决策 47)。
func TestCoverSweepBorrowVerifiedSiblings(t *testing.T) {
	const album = "世纪典藏【绝赞版】"
	device := "file:///Users/x/.config/lyrimuse/artwork/essential.jpg"
	withEnrichCache(t, map[string]enrichEntry{
		"Michael Jackson|Smooth Criminal|" + album: {CoverURL: device, CoverSource: "device", CoverAlbum: album},
		"Michael Jackson|Off the Wall|" + album:    {CoverURL: "https://qq/bad.jpg", CoverSource: "qq", AccentColor: "#aa0000"},
		"Michael Jackson|Beat It|" + album:         {CoverURL: "https://n/1.jpg", CoverSource: "netease", CoverAlbum: "Thriller"},
		"Michael Jackson|Bad|" + album:             {CoverURL: "https://apple/e.jpg", CoverSource: "apple", CoverAlbum: album},
		"Michael Jackson|Dirty Diana|" + album:     {CoverURL: "file:///other.jpg", CoverSource: "player", CoverAlbum: album},
		"Michael Jackson|Human Nature|" + album:    {},
		"Michael Jackson|Leave Me Alone|" + album:  {CoverURL: device, CoverSource: "qq", AccentColor: "#111111"},
		"Michael Jackson|P.Y.T.|" + album:          {CoverURL: "https://qq/bad.jpg", CoverSource: "qq"},
		"Prince|Kiss|" + album:                     {CoverURL: "https://qq/p.jpg", CoverSource: "qq"},
		"Michael Jackson|Thriller|Thriller":        {CoverURL: "https://qq/t.jpg", CoverSource: "qq"},
		"别的歌手|甲|别的专辑":                              {CoverURL: "file:///x.jpg", CoverSource: "device"},
		"别的歌手|乙|别的专辑":                              {CoverURL: "https://qq/y.jpg", CoverSource: "qq"},
	})
	enrichMu.Lock()
	savedInflight := enrichInflight
	enrichInflight = map[string]bool{"Michael Jackson|P.Y.T.|" + album: true}
	enrichDirty = false
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichInflight = savedInflight
		enrichMu.Unlock()
	})
	if n := coverSweepBorrowVerifiedSiblings(); n != 2 {
		t.Fatalf("换了 %d 条, 要 2", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, title := range []string{"Off the Wall", "Beat It"} {
		e := enrichCache["Michael Jackson|"+title+"|"+album]
		if e.CoverURL != device || e.CoverSource != "device" || e.CoverAlbum != album || e.AccentColor != "" {
			t.Errorf("%s 该换成同专辑核实过的设备封面: %+v", title, e)
		}
	}
	for key, want := range map[string]string{
		"Michael Jackson|Bad|" + album:            "https://apple/e.jpg",
		"Michael Jackson|Dirty Diana|" + album:    "file:///other.jpg",
		"Michael Jackson|Human Nature|" + album:   "",
		"Michael Jackson|Leave Me Alone|" + album: device,
		"Michael Jackson|P.Y.T.|" + album:         "https://qq/bad.jpg",
		"Prince|Kiss|" + album:                    "https://qq/p.jpg",
		"Michael Jackson|Thriller|Thriller":       "https://qq/t.jpg",
		"别的歌手|乙|别的专辑":                             "https://qq/y.jpg",
	} {
		if got := enrichCache[key].CoverURL; got != want {
			t.Errorf("%s 不该动: 得到 %q", key, got)
		}
	}
	if e := enrichCache["Michael Jackson|Leave Me Alone|"+album]; e.CoverSource != "qq" || e.AccentColor != "#111111" {
		t.Errorf("已经是同一张图的不该改来源、清主色: %+v", e)
	}
	if !enrichDirty {
		t.Error("换了封面要置脏")
	}
}

// 存量 QQ 封面没记专辑的,按封面地址里的专辑 mid 查回专辑名:同一个 mid 只查一次,按 mid 排序查,两次之间隔 coverSweepNameGap;
// 已经记了的、别的来源的、地址认不出 mid 的不查;QQ 答了没名字的留空(03 章决策 47)。
func TestCoverSweepNameQQCoverAlbums(t *testing.T) {
	_, waits := withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	bad, other := qqAlbumCoverURL("0034Gnut4OoYpJ"), qqAlbumCoverURL("003Other")
	withEnrichCache(t, map[string]enrichEntry{
		"Michael Jackson|Off the Wall|世纪典藏":  {CoverURL: bad, CoverSource: "qq"},
		"Michael Jackson|Rock With You|世纪典藏": {CoverURL: bad, CoverSource: "qq"},
		"Michael Jackson|Thriller|世纪典藏":      {CoverURL: other, CoverSource: "qq"},
		"Michael Jackson|Bad|Bad":            {CoverURL: bad, CoverSource: "qq", CoverAlbum: "Bad 25"},
		"Michael Jackson|Beat It|世纪典藏":       {CoverURL: bad, CoverSource: "netease"},
		"Michael Jackson|Human Nature|世纪典藏":  {CoverURL: "https://example.invalid/q.jpg", CoverSource: "qq"},
	})
	var asked []string
	coverSweepQQAlbumName = func(_ context.Context, mid string) (string, error) {
		asked = append(asked, mid)
		if mid == "0034Gnut4OoYpJ" {
			return "Bad", nil
		}
		return "", nil
	}
	if n := coverSweepNameQQCoverAlbums(context.Background()); n != 2 {
		t.Fatalf("记上 %d 条, 要 2", n)
	}
	if !reflect.DeepEqual(asked, []string{"0034Gnut4OoYpJ", "003Other"}) {
		t.Errorf("查了 %v", asked)
	}
	if !reflect.DeepEqual(*waits, []time.Duration{coverSweepNameGap}) {
		t.Errorf("等待 %v", *waits)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for key, want := range map[string]string{
		"Michael Jackson|Off the Wall|世纪典藏":  "Bad",
		"Michael Jackson|Rock With You|世纪典藏": "Bad",
		"Michael Jackson|Thriller|世纪典藏":      "",
		"Michael Jackson|Bad|Bad":            "Bad 25",
		"Michael Jackson|Beat It|世纪典藏":       "",
		"Michael Jackson|Human Nature|世纪典藏":  "",
	} {
		if got := enrichCache[key].CoverAlbum; got != want {
			t.Errorf("%s 的 cover_album = %q, 要 %q", key, got, want)
		}
	}
}

// 连着 coverSweepOfflineLimit 个 mid 都没问成就停,一条都不记。
func TestCoverSweepNameQQCoverAlbumsStopsWhenUnreached(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	cache := map[string]enrichEntry{}
	for i := range coverSweepOfflineLimit + 3 {
		cache[fmt.Sprintf("A|t%d|Alb", i)] = enrichEntry{CoverURL: qqAlbumCoverURL(fmt.Sprintf("00%dMid", i)), CoverSource: "qq"}
	}
	withEnrichCache(t, cache)
	asked := 0
	coverSweepQQAlbumName = func(context.Context, string) (string, error) {
		asked++
		return "", errQQNotReached
	}
	if n := coverSweepNameQQCoverAlbums(context.Background()); n != 0 || asked != coverSweepOfflineLimit {
		t.Errorf("记上 %d 条、问了 %d 次, 要 0 条、%d 次", n, asked, coverSweepOfflineLimit)
	}
}

// 同一遍里先记上 QQ 封面在 QQ 上的专辑,紧接着那步就把另一张专辑的封面换成歌词胜出那个源自带、专辑对得上的。
func TestRunCoverSweepReplacesQQCoverOfAnotherAlbum(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	const key = "Michael Jackson|Off the Wall|世纪典藏"
	withEnrichCache(t, map[string]enrichEntry{
		key: {CoverURL: qqAlbumCoverURL("0034Gnut4OoYpJ"), CoverSource: "qq", Lyrics: coverSweepLyrics,
			LyricsDecision: &lyricsDecision{Winner: "soda", Candidates: []lyricsDecisionCandidate{
				{Source: "soda", Score: 1310, Album: "世纪典藏", CoverURL: "https://s/essential.jpg"}}}},
	})
	coverSweepQQAlbumName = func(context.Context, string) (string, error) { return "Bad", nil }
	runCoverSweep(context.Background())
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache[key]; e.CoverURL != "https://s/essential.jpg" || e.CoverSource != "soda" || e.CoverAlbum != "世纪典藏" {
		t.Errorf("记上专辑之后该换成专辑对得上的候选封面: %+v", e)
	}
}

// 正在提前提交的条目(enrichProvisional)不动。
func TestCoverSweepBorrowVerifiedSiblingsSkipsProvisional(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"A|lender|Alb": {CoverURL: "file:///d.jpg", CoverSource: "device", CoverAlbum: "Alb"},
		"A|early|Alb":  {CoverURL: "https://qq/e.jpg", CoverSource: "qq"},
	})
	enrichMu.Lock()
	savedProvisional := enrichProvisional
	enrichProvisional = map[string]bool{"A|early|Alb": true}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichProvisional = savedProvisional
		enrichMu.Unlock()
	})
	if n := coverSweepBorrowVerifiedSiblings(); n != 0 {
		t.Errorf("换了 %d 条, 正在提前提交的不该动", n)
	}
}

// 同一张专辑有几条能借的设备封面时,取 key 最小的那条:map 的遍历顺序每次不同,不排序的话借到哪张不定。
func TestCoverSweepBorrowVerifiedSiblingsPicksSmallestKey(t *testing.T) {
	for range 20 {
		withEnrichCache(t, map[string]enrichEntry{
			"A|a|Alb": {CoverURL: "file:///a.jpg", CoverSource: "device", CoverAlbum: "Alb"},
			"A|b|Alb": {CoverURL: "file:///b.jpg", CoverSource: "device", CoverAlbum: "Alb"},
			"A|c|Alb": {CoverURL: "https://qq/c.jpg", CoverSource: "qq"},
		})
		coverSweepBorrowVerifiedSiblings()
		if got := enrichCache["A|c|Alb"].CoverURL; got != "file:///a.jpg" {
			t.Fatalf("借到 %q, 要 key 最小那条的 file:///a.jpg", got)
		}
	}
}

// 一遍跑下来,同专辑核实过的设备封面在第一步就借出去了。
func TestRunCoverSweepBorrowsVerifiedSibling(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|lender|Alb": {CoverURL: "file:///d.jpg", CoverSource: "device", CoverAlbum: "Alb", Lyrics: coverSweepLyrics},
		"A|other|Alb":  {CoverURL: "https://qq/o.jpg", CoverSource: "qq", Lyrics: coverSweepLyrics},
	})
	runCoverSweep(context.Background())
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|other|Alb"]; e.CoverURL != "file:///d.jpg" || e.CoverSource != "device" || e.CoverAlbum != "Alb" {
		t.Errorf("该借到同专辑核实过的设备封面: %+v", e)
	}
}

// 只给没记专辑的 QQ 封面查:已经记了专辑的、别的来源挂着 QQ 图床地址的,它们独占的 mid 不查。
func TestCoverSweepNameQQCoverAlbumsAsksOnlyUnnamedQQCovers(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|named|Alb":   {CoverURL: qqAlbumCoverURL("001Named"), CoverSource: "qq", CoverAlbum: "Named"},
		"A|netease|Alb": {CoverURL: qqAlbumCoverURL("002Netease"), CoverSource: "netease"},
		"A|unnamed|Alb": {CoverURL: qqAlbumCoverURL("003Unnamed"), CoverSource: "qq"},
	})
	var asked []string
	coverSweepQQAlbumName = func(_ context.Context, mid string) (string, error) {
		asked = append(asked, mid)
		return "Unnamed", nil
	}
	coverSweepNameQQCoverAlbums(context.Background())
	if !reflect.DeepEqual(asked, []string{"003Unnamed"}) {
		t.Errorf("查了 %v, 只该查 003Unnamed", asked)
	}
}

// 查专辑名那一下,条目的封面被换成了另一个专辑的 QQ 图、或者被别处占去解析:查回来的名字不往它身上记。
func TestCoverSweepNameQQCoverAlbumsSkipsEntriesChangedMeanwhile(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	mid := "0034Gnut4OoYpJ"
	withEnrichCache(t, map[string]enrichEntry{
		"A|kept|Alb":    {CoverURL: qqAlbumCoverURL(mid), CoverSource: "qq"},
		"A|moved|Alb":   {CoverURL: qqAlbumCoverURL(mid), CoverSource: "qq"},
		"A|claimed|Alb": {CoverURL: qqAlbumCoverURL(mid), CoverSource: "qq"},
	})
	coverSweepQQAlbumName = func(context.Context, string) (string, error) {
		enrichMu.Lock()
		e := enrichCache["A|moved|Alb"]
		e.CoverURL = qqAlbumCoverURL("009Other")
		enrichCache["A|moved|Alb"] = e
		enrichInflight["A|claimed|Alb"] = true
		enrichMu.Unlock()
		return "Bad", nil
	}
	if n := coverSweepNameQQCoverAlbums(context.Background()); n != 1 {
		t.Fatalf("记上 %d 条, 要 1", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for key, want := range map[string]string{"A|kept|Alb": "Bad", "A|moved|Alb": "", "A|claimed|Alb": ""} {
		if got := enrichCache[key].CoverAlbum; got != want {
			t.Errorf("%s 的 cover_album = %q, 要 %q", key, got, want)
		}
	}
}

// 没问成的连败计数遇到一次问成就清零:失败、成功、失败交替时一个 mid 都不漏。
func TestCoverSweepNameQQCoverAlbumsResetsTheStreak(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	total := 2*(coverSweepOfflineLimit-1) + 1
	cache := map[string]enrichEntry{}
	for i := range total {
		cache[fmt.Sprintf("A|t%02d|Alb", i)] = enrichEntry{CoverURL: qqAlbumCoverURL(fmt.Sprintf("0%02dMid", i)), CoverSource: "qq"}
	}
	withEnrichCache(t, cache)
	asked := 0
	coverSweepQQAlbumName = func(context.Context, string) (string, error) {
		asked++
		if asked == coverSweepOfflineLimit {
			return "", nil
		}
		return "", errQQNotReached
	}
	coverSweepNameQQCoverAlbums(context.Background())
	if asked != total {
		t.Errorf("问了 %d 个 mid, 要 %d 个", asked, total)
	}
}

// 有别的歌在解析时先等它解析完再查。
func TestCoverSweepNameQQCoverAlbumsYieldsToResolvingEntries(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|q|Alb": {CoverURL: qqAlbumCoverURL("001Mid"), CoverSource: "qq"},
	})
	enrichMu.Lock()
	enrichInflight["B|playing|X"] = true
	enrichMu.Unlock()
	var waits []time.Duration
	coverSweepWait = func(_ context.Context, d time.Duration) {
		waits = append(waits, d)
		enrichMu.Lock()
		delete(enrichInflight, "B|playing|X")
		enrichMu.Unlock()
	}
	coverSweepQQAlbumName = func(context.Context, string) (string, error) {
		enrichMu.Lock()
		busy := len(enrichInflight) > 0
		enrichMu.Unlock()
		if busy {
			t.Error("还有歌在解析就去查了")
		}
		return "Q", nil
	}
	if n := coverSweepNameQQCoverAlbums(context.Background()); n != 1 || !reflect.DeepEqual(waits, []time.Duration{coverSweepYieldPoll}) {
		t.Errorf("记上 %d 条, 等待 %v", n, waits)
	}
}

// 设备条目没有图(cover_url 空)时不当借出方,不能把别的曲目的封面换成空。
func TestCoverSweepBorrowVerifiedSiblingsNeedsALenderWithACover(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"A|blank|Alb": {CoverSource: "device", CoverAlbum: "Alb"},
		"A|q|Alb":     {CoverURL: "https://qq/q.jpg", CoverSource: "qq"},
	})
	if n := coverSweepBorrowVerifiedSiblings(); n != 0 || enrichCache["A|q|Alb"].CoverURL != "https://qq/q.jpg" {
		t.Errorf("换了 %d 条, 封面 %q", n, enrichCache["A|q|Alb"].CoverURL)
	}
}

// 查专辑名那一下,条目换成了别的来源、或者已经被别处记上了专辑:都不再往它身上记。
func TestCoverSweepNameQQCoverAlbumsSkipsEntriesTakenMeanwhile(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	url := qqAlbumCoverURL("0034Gnut4OoYpJ")
	withEnrichCache(t, map[string]enrichEntry{
		"A|kept|Alb":      {CoverURL: url, CoverSource: "qq"},
		"A|resourced|Alb": {CoverURL: url, CoverSource: "qq"},
		"A|filled|Alb":    {CoverURL: url, CoverSource: "qq"},
	})
	coverSweepQQAlbumName = func(context.Context, string) (string, error) {
		enrichMu.Lock()
		e := enrichCache["A|resourced|Alb"]
		e.CoverSource = "device"
		enrichCache["A|resourced|Alb"] = e
		e = enrichCache["A|filled|Alb"]
		e.CoverAlbum = "Other"
		enrichCache["A|filled|Alb"] = e
		enrichMu.Unlock()
		return "Bad", nil
	}
	if n := coverSweepNameQQCoverAlbums(context.Background()); n != 1 {
		t.Fatalf("记上 %d 条, 要 1", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for key, want := range map[string]string{"A|kept|Alb": "Bad", "A|resourced|Alb": "", "A|filled|Alb": "Other"} {
		if got := enrichCache[key].CoverAlbum; got != want {
			t.Errorf("%s 的 cover_album = %q, 要 %q", key, got, want)
		}
	}
}

// 没封面、或封面明确是另一张专辑的条目,记着播放器自带封面的直接换上,记成 player、cover_album 记本地专辑;专辑对得上的、
// 专辑定下的、没记自带封面的不动。见 03 章决策 51。
func TestCoverSweepFillFromPlayerCovers(t *testing.T) {
	const own = "https://m.media-amazon.com/images/I/51y00kgscmL._SX500_.jpg"
	amazon := map[string]string{"com.amazon.music": own}
	other := enrichEntry{CoverURL: "https://d/1.jpg", CoverSource: "deezer", CoverAlbum: "The Only One", AccentColor: "#112233",
		PlayerCovers: amazon, Players: []string{"com.amazon.music"}}
	withEnrichCache(t, map[string]enrichEntry{
		"A|other|Open Fire [Clean]": other,
		"A|empty|Open Fire [Clean]": {PlayerCovers: amazon},
		"A|fits|Open Fire [Clean]": {CoverURL: "https://a/1.jpg", CoverSource: "apple", CoverAlbum: "Open Fire",
			PlayerCovers: amazon},
		"A|settled|Open Fire [Clean]": func() enrichEntry {
			e := other
			e.CoverSettled = e.CoverURL
			return e
		}(),
		"A|noown|Open Fire [Clean]": {CoverURL: "https://d/1.jpg", CoverSource: "deezer", CoverAlbum: "The Only One"},
		"A|already|Open Fire [Clean]": {CoverURL: own, CoverSource: "player", CoverAlbum: "Open Fire [Clean]",
			PlayerCovers: amazon},
	})
	if n := coverSweepFillFromPlayerCovers(); n != 2 {
		t.Fatalf("换上 %d 条, 要 2", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|other|Open Fire [Clean]"]; e.CoverURL != own || e.CoverSource != "player" ||
		e.CoverAlbum != "Open Fire [Clean]" || e.AccentColor != "" {
		t.Errorf("另一张专辑的封面换成自带的、主色清空: %+v", e)
	}
	if e := enrichCache["A|empty|Open Fire [Clean]"]; e.CoverURL != own || e.CoverSource != "player" {
		t.Errorf("没封面的补上自带的: %+v", e)
	}
	for _, k := range []string{"A|fits|Open Fire [Clean]", "A|settled|Open Fire [Clean]", "A|noown|Open Fire [Clean]"} {
		if e := enrichCache[k]; e.CoverSource == "player" {
			t.Errorf("%s 不该换: %+v", k, e)
		}
	}
}

func TestCoverSweepRunsPlayerCoverStepBeforeDecisions(t *testing.T) {
	src := string(mustRead(t, "coversweep.go"))
	own, dec := strings.Index(src, "if n := coverSweepFillFromPlayerCovers(); n > 0 {"), strings.Index(src, "if n := coverSweepFillFromDecisions(); n > 0 {")
	if own < 0 || dec < 0 || own > dec {
		t.Errorf("一遍里先换播放器自带的,再从歌词判决补: %d %d", own, dec)
	}
}

// 没封面、或封面是另一张专辑的条目,借同一张专辑、同一位歌手里封面属于这张专辑的那条;出借的按专辑定下的、设备、播放器自带、
// 其它排;歌手按官方名也认;cover_album 空着的、另一张专辑的不借出;专辑定下的、专辑对得上的不动。见 03 章决策 51。
func TestCoverSweepBorrowAlbumSiblings(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"Khalil Fong|Zz Lady Sue|This Love": {CoverURL: "file:///a/device.jpg", CoverSource: "device", CoverAlbum: "This Love", CanonicalArtist: "方大同"},
		"Khalil Fong|Tou Xiao|This Love":    {CoverURL: "https://a/1.jpg", CoverSource: "apple", CoverAlbum: "This Love", CanonicalArtist: "方大同"},
		"方大同|Love Love Love|This Love":      {CoverURL: "https://a/2.jpg", CoverSource: "apple", CoverAlbum: "Love Unlimited", AccentColor: "#123456"},
		"方大同|Empty|This Love":               {},
		"方大同|Fits|This Love":                {CoverURL: "https://n/1.jpg", CoverSource: "netease", CoverAlbum: "This Love"},
		"别人|Song|This Love":                 {CoverURL: "https://q/2.jpg", CoverSource: "qq", CoverAlbum: "Other"},
		"丁世光|Intro|神經志 (The Journal)":       {CoverURL: "https://q/3.jpg", CoverSource: "qq", CoverAlbum: "Night & Day"},
		"丁世光|E.T.|神经志 (The Journal)":        {CoverURL: "https://n/2.jpg", CoverSource: "netease", CoverAlbum: "神经志"},
		"丁世光|Unknown|神经志 (The Journal)":     {CoverURL: "https://n/3.jpg", CoverSource: "netease"},
		"X|Lonely|Solo Album":               {CoverURL: "https://q/4.jpg", CoverSource: "qq", CoverAlbum: "Other"},
		"Y|Settled|Grp":                     {CoverURL: "https://q/1.jpg", CoverSource: "qq", CoverAlbum: "Other", CoverSettled: "https://q/1.jpg"},
		"Y|Lender|Grp":                      {CoverURL: "https://n/4.jpg", CoverSource: "netease", CoverAlbum: "Grp"},
	})
	if n := coverSweepBorrowAlbumSiblings(); n != 3 {
		t.Fatalf("借了 %d 条, 要 3", n)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, k := range []string{"方大同|Love Love Love|This Love", "方大同|Empty|This Love"} {
		if e := enrichCache[k]; e.CoverURL != "file:///a/device.jpg" || e.CoverSource != "device" || e.CoverAlbum != "This Love" ||
			e.AccentColor != "" {
			t.Errorf("%s 借设备封面那条(官方名「方大同」对上),主色清空: %+v", k, e)
		}
	}
	if e := enrichCache["丁世光|Intro|神經志 (The Journal)"]; e.CoverURL != "https://n/2.jpg" || e.CoverAlbum != "神经志" {
		t.Errorf("专辑繁简不同也算同一张,借 cover_album 对得上的那条: %+v", e)
	}
	for k, want := range map[string]string{
		"方大同|Fits|This Love":  "https://n/1.jpg",
		"Y|Settled|Grp":       "https://q/1.jpg",
		"别人|Song|This Love":   "https://q/2.jpg",
		"X|Lonely|Solo Album": "https://q/4.jpg",
	} {
		if e := enrichCache[k]; e.CoverURL != want {
			t.Errorf("%s 不该换: %+v", k, e)
		}
	}
}

func TestAlbumSiblingLends(t *testing.T) {
	for _, c := range []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"没封面", enrichEntry{}, false},
		{"设备封面", enrichEntry{CoverURL: "f", CoverSource: "device"}, true},
		{"播放器自带", enrichEntry{CoverURL: "f", CoverSource: "player"}, true},
		{"专辑定下的", enrichEntry{CoverURL: "f", CoverSource: "qq", CoverAlbum: "Other", CoverSettled: "f"}, true},
		{"cover_album 对上", enrichEntry{CoverURL: "f", CoverSource: "netease", CoverAlbum: "Album"}, true},
		{"cover_album 空着", enrichEntry{CoverURL: "f", CoverSource: "netease"}, false},
		{"另一张专辑", enrichEntry{CoverURL: "f", CoverSource: "netease", CoverAlbum: "Other"}, false},
	} {
		if got := albumSiblingLends(c.e, "Album"); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
	if albumSiblingLendRank(enrichEntry{CoverURL: "f", CoverSettled: "f", CoverSource: "qq"}) >= albumSiblingLendRank(enrichEntry{CoverURL: "f", CoverSource: "device"}) ||
		albumSiblingLendRank(enrichEntry{CoverSource: "device"}) >= albumSiblingLendRank(enrichEntry{CoverSource: "player"}) ||
		albumSiblingLendRank(enrichEntry{CoverSource: "player"}) >= albumSiblingLendRank(enrichEntry{CoverSource: "netease"}) {
		t.Error("出借先后:专辑定下的、设备、播放器自带、其它")
	}
	if !albumSiblingArtistMatches("方大同", "", "Khalil Fong", "方大同") || !albumSiblingArtistMatches("Khalil Fong", "方大同", "方大同", "") ||
		albumSiblingArtistMatches("别人", "", "Khalil Fong", "方大同") {
		t.Error("歌手按写法或官方名对上")
	}
}

func TestCoverSweepBorrowsAlbumSiblingsAfterDecisions(t *testing.T) {
	src := string(mustRead(t, "coversweep.go"))
	dec, sib := strings.Index(src, "if n := coverSweepFillFromDecisions(); n > 0 {"), strings.Index(src, "if n := coverSweepBorrowAlbumSiblings(); n > 0 {")
	if dec < 0 || sib < 0 || sib < dec {
		t.Errorf("一遍里先从歌词判决补,再借同专辑的: %d %d", dec, sib)
	}
}
