package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// stubLyricProvider 是只给调度的单测用的源:记被问了几次、拿到了什么。
type stubLyricProvider struct {
	desc    *ProviderDescriptor
	calls   atomic.Int32
	gotCtx  context.Context
	gotQ    ProviderQuery
	gotEnv  RoundEnv
	resolve func() SourceResult
}

func (p *stubLyricProvider) Descriptor() *ProviderDescriptor { return p.desc }

func (p *stubLyricProvider) Resolve(ctx context.Context, q ProviderQuery, env RoundEnv) SourceResult {
	p.calls.Add(1)
	p.gotCtx, p.gotQ, p.gotEnv = ctx, q, env
	if p.resolve != nil {
		return p.resolve()
	}
	return SourceResult{}
}

// enableOnlyLyricSources:设置里只开这几个联网源,其余全关。
func enableOnlyLyricSources(t *testing.T, names ...string) {
	t.Helper()
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	on := map[string]bool{"provider-test-none": true}
	for _, n := range names {
		on[n] = true
	}
	featuresRef().LyricsSources = on
}

// coolingBreakerFor 造一个熔断器,cooling 为真时 d 这个源正在冷却;装成共享的那份,返回这一轮的冷却名单。
func coolingBreakerFor(t *testing.T, d *ProviderDescriptor, cooling bool) lyricSourceRoundPlan {
	t.Helper()
	b := newLyricSourceBreaker(time.Now)
	if cooling {
		host := d.Hosts[0].Host
		if d.Hosts[0].Scope == hostSubdomainsOnly {
			host = "x." + host
		}
		b.observe(host, errProbeDial, 0, "")
		b.observe(host, errProbeDial, 0, "")
	}
	setSharedLyricSourceBreaker(b)
	plan := b.planRound(lyricSourceNames)
	if _, got := plan[d.Name]; got != cooling {
		t.Fatalf("%s:想造的冷却状态是 %v,熔断器给的是 %v", d.Name, cooling, got)
	}
	return plan
}

// 调度的跳过判断(lyricRoundPlan.decide)跟手写 goroutine 用的 lyricSourceSkippedThisRound 逐个源、逐种情形对着比:
// 问不问、记不记跳过、记的原因都要一样。
func TestLyricRoundPlanDecisionMatchesHandwrittenSkip(t *testing.T) {
	savedFeatures, savedBreaker := features(), sharedLyricSourceBreaker()
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		setSharedLyricSourceBreaker(savedBreaker)
	})
	asked, silent, cooled := 0, 0, 0
	for i, name := range lyricSourceNames {
		d := lyricProviders().descriptor(name)
		other := lyricSourceNames[(i+1)%len(lyricSourceNames)]
		for _, only := range [][]string{nil, {name, other}, {other}} {
			for _, onDemand := range []bool{false, true} {
				for _, enabled := range []bool{true, false} {
					for _, cooling := range []bool{false, true} {
						label := fmt.Sprintf("%s only=%v onDemand=%v enabled=%v cooling=%v", name, only, onDemand, enabled, cooling)
						featuresRef().LyricsSources = map[string]bool{"provider-test-none": true, name: enabled}
						breakerPlan := coolingBreakerFor(t, d, cooling)
						newRound := func() (context.Context, *lyricSourceRound) {
							ctx := context.Background()
							if onDemand {
								ctx = withOnDemandLyricRound(ctx)
							}
							return withLyricSourceRound(withLyricSourceOnly(ctx, only))
						}

						oldCtx, oldRound := newRound()
						skipped := lyricSourceSkippedThisRound(oldCtx, name, lyricSourceOnlyFrom(oldCtx), breakerPlan, oldRound)

						newCtx, round := newRound()
						stub := &stubLyricProvider{desc: d}
						got := runLyricProvider(newCtx, stub, ProviderQuery{}, RoundEnv{}, newLyricRoundPlan(newCtx, breakerPlan))

						if queried := stub.calls.Load() == 1; queried == skipped {
							t.Errorf("%s:手写的跳过=%v,调度问了=%v", label, skipped, queried)
						}
						if !skipped && got.source != name {
							t.Errorf("%s:结果的源名 %q", label, got.source)
						}
						if skipped && !reflect.DeepEqual(got, SourceResult{source: name}) {
							t.Errorf("%s:跳过时应交只带源名的空结果,得到 %+v", label, got)
						}
						if a, b := oldRound.statsSkips(), round.statsSkips(); !reflect.DeepEqual(a, b) {
							t.Errorf("%s:记下的跳过和原因,手写 %v,调度 %v", label, a, b)
						}
						switch {
						case !skipped:
							asked++
						case len(round.skippedSources()) > 0:
							cooled++
							if round.statsSkips()[name] == "" {
								t.Errorf("%s:冷却跳过应带原因", label)
							}
						default:
							silent++
						}
					}
				}
			}
		}
	}
	if asked == 0 || silent == 0 || cooled == 0 {
		t.Fatalf("三种处置都该出现:问 %d、静默跳过 %d、冷却跳过 %d", asked, silent, cooled)
	}
}

// 问的时候:ctx、查询、环境原样交给 Resolve,结果原样交回、源名换成描述符里的。
func TestRunLyricProviderPassesRoundThrough(t *testing.T) {
	enableOnlyLyricSources(t, "stub")
	type ctxKey struct{}
	ctx := context.WithValue(context.Background(), ctxKey{}, "this round")
	stub := &stubLyricProvider{desc: &ProviderDescriptor{Name: "stub"}, resolve: func() SourceResult {
		return SourceResult{source: "something else", lyr: "[00:01.00]a", srcDur: 200, instrumental: true}
	}}
	q := ProviderQuery{Artist: "A", Title: "T", Album: "Al", SourceTitle: "T (1)", DurationSecs: 200}
	env := RoundEnv{ForPlayingTrack: true}
	got := runLyricProvider(ctx, stub, q, env, newLyricRoundPlan(ctx, nil))
	want := SourceResult{source: "stub", lyr: "[00:01.00]a", srcDur: 200, instrumental: true}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("结果 %+v,期望 %+v", got, want)
	}
	if stub.calls.Load() != 1 || stub.gotCtx != ctx || stub.gotQ != q || stub.gotEnv != env {
		t.Errorf("Resolve 应被问一次、拿到原样的 ctx / 查询 / 环境:calls=%d q=%+v env=%+v sameCtx=%v",
			stub.calls.Load(), stub.gotQ, stub.gotEnv, stub.gotCtx == ctx)
	}
}

// 调度给每个源恰好送一份结果,被跳过的也送。
func TestStartLyricProvidersSendsOneResultEach(t *testing.T) {
	enableOnlyLyricSources(t, "stub-a", "stub-b", "stub-ondemand")
	stubs := []*stubLyricProvider{
		{desc: &ProviderDescriptor{Name: "stub-a"}},
		{desc: &ProviderDescriptor{Name: "stub-b"}},
		{desc: &ProviderDescriptor{Name: "stub-disabled"}},
		{desc: &ProviderDescriptor{Name: "stub-ondemand", Rounds: roundsOnDemand}},
	}
	providers := make([]LyricProvider, 0, len(stubs))
	for _, s := range stubs {
		providers = append(providers, s)
	}
	ctx := context.Background()
	out := make(chan SourceResult, len(providers))
	startLyricProviders(ctx, providers, ProviderQuery{}, RoundEnv{}, newLyricRoundPlan(ctx, nil), out)
	var names []string
	for range providers {
		select {
		case r := <-out:
			names = append(names, r.source)
		case <-time.After(5 * time.Second):
			t.Fatalf("只收到 %v,有源没交结果", names)
		}
	}
	sort.Strings(names)
	if want := []string{"stub-a", "stub-b", "stub-disabled", "stub-ondemand"}; !slices.Equal(names, want) {
		t.Errorf("收到 %v,期望每个源各一份 %v", names, want)
	}
	for _, s := range stubs {
		want := int32(0)
		if s.desc.Name == "stub-a" || s.desc.Name == "stub-b" {
			want = 1
		}
		if got := s.calls.Load(); got != want {
			t.Errorf("%s 被问了 %d 次,期望 %d 次", s.desc.Name, got, want)
		}
	}
	select {
	case r := <-out:
		t.Errorf("多收到一份 %+v", r)
	default:
	}
}

// 一个联网源只走一条路:登记了实现的由调度起,没登记的在收集循环里有且只有一个手写的 goroutine。
func TestEveryNetworkSourceHasExactlyOneCollector(t *testing.T) {
	raw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	if n := countCode(src, "startLyricProviders(ctx, lyricProviders().providers, providerQuery, providerEnv, providerPlan, resultsCh)"); n != 1 {
		t.Fatalf("收集循环里应恰好起一次调度,找到 %d 处", n)
	}
	implemented := map[string]int{}
	for _, p := range lyricProviders().providers {
		d := p.Descriptor()
		if d == nil || lyricProviders().descriptor(d.Name) != d || d.Kind != providerKindNetwork {
			t.Fatalf("登记的实现交的描述符不是登记表里那份联网源的:%+v", d)
		}
		implemented[d.Name]++
	}
	if implemented[lyricSourceLRCLIB] != 1 {
		t.Errorf("lrclib 应登记一份实现,得到 %d", implemented[lyricSourceLRCLIB])
	}
	for _, name := range lyricSourceNames {
		handwritten := countCode(src, fmt.Sprintf("if skipSource(%q) {", name)) +
			countCode(src, fmt.Sprintf("switch lyricSourceSkipFor(%q, lyricSourceEnabled, breakerPlan) {", name))
		if implemented[name]+handwritten != 1 {
			t.Errorf("%s:登记的实现 %d 份、手写的 goroutine %d 个,应合计恰好一个", name, implemented[name], handwritten)
		}
	}
}

// ---- LRCLIB:经调度问出来的,跟照手写 goroutine 的写法问出来的对拍 ----

// handwrittenLRCLIBRound 照收集循环里手写 goroutine 的写法问 LRCLIB 一轮(lyricSourceSkippedThisRound 判跳过、调 lrclibLyric、
// 逐字段摊成结果),是对拍的参照。
func handwrittenLRCLIBRound(ctx context.Context, artist, title, album string, durationSecs float64) lyricSourceResult {
	srcTitle := lyricSourceTitleFor(ctx, title)
	breakerPlan := sharedLyricSourceBreaker().planRound(lyricSourceNames)
	if lyricSourceSkippedThisRound(ctx, "lrclib", lyricSourceOnlyFrom(ctx), breakerPlan, lyricSourceRoundFrom(ctx)) {
		return lyricSourceResult{source: "lrclib"}
	}
	r := lrclibLyric(ctx, artist, srcTitle, album, durationSecs)
	return lyricSourceResult{source: "lrclib", lyr: r.lyrics, yrc: r.yrc, roma: r.roma, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, srcDur: r.durationSecs, instrumental: r.instrumental, plainOnly: r.plainOnly}
}

type lrclibParityCase struct {
	name string
	// ctx 给这一轮挂上要测的标记(后台、别名轮名单、原样写法、带编号的歌名);nil = 前台的普通一轮。
	ctx func(context.Context) context.Context
	// disabled:设置里关掉 LRCLIB;cooling:开搜前它已在熔断冷却。
	disabled, cooling bool
	// rounds:同一首连问几轮(看进程内缓存),0 当 1。
	rounds                int
	artist, title, album  string
	durationSecs          float64
	handle                func(r *http.Request, nth int) (int, http.Header, string)
	wantRequests          int
	wantWaits             int
	wantLyrics, wantSkips bool
	check                 func(t *testing.T, o lrclibRoundOutcome)
}

type lrclibRoundOutcome struct {
	result   lyricSourceResult
	requests []string
	waits    []time.Duration
	skips    map[string]string
	cached   []string
}

func runLRCLIBParityRound(t *testing.T, c lrclibParityCase, viaScheduler bool) lrclibRoundOutcome {
	t.Helper()
	waits := withLRCLIBInstantPause(t)
	var nth atomic.Int32
	fake := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		return c.handle(r, int(nth.Add(1)))
	})
	if c.disabled {
		enableOnlyLyricSources(t)
	} else {
		enableOnlyLyricSources(t, lyricSourceLRCLIB)
	}
	if c.cooling {
		coolingBreakerFor(t, lyricProviders().descriptor(lyricSourceLRCLIB), true)
	}
	base := context.Background()
	if c.ctx != nil {
		base = c.ctx(base)
	}
	ctx, round := withLyricSourceRound(base)
	var result lyricSourceResult
	for range max(c.rounds, 1) {
		if !viaScheduler {
			result = withoutPlayerIdentity(ctx, handwrittenLRCLIBRound(ctx, c.artist, c.title, c.album, c.durationSecs))
			result.forPlayingTrack = playerSignalApplies(ctx)
			continue
		}
		var got *lyricSourceResult
		saved := lyricSourceResultTap
		lyricSourceResultTap = func(r lyricSourceResult) {
			if r.source == lyricSourceLRCLIB {
				got = &r
			}
		}
		fetchScoredLyricCandidatesStreaming(ctx, c.artist, c.title, c.album, c.durationSecs, nil)
		lyricSourceResultTap = saved
		if got == nil {
			t.Fatalf("%s:收集循环没收到 lrclib 的结果", c.name)
		}
		result = *got
	}
	o := lrclibRoundOutcome{result: result, skips: round.statsSkips()}
	// 后台重发的等待是「本地暂停还剩多久」,按真实时钟算,两次跑差几微秒:取整到 0.1 秒再比。
	for _, w := range *waits {
		o.waits = append(o.waits, w.Round(100*time.Millisecond))
	}
	for _, u := range fake.requests() {
		o.requests = append(o.requests, u.Path+"?"+u.Query().Encode())
	}
	sort.Strings(o.requests)
	lrclibMu.Lock()
	for k := range lrclibCache {
		o.cached = append(o.cached, k)
	}
	lrclibMu.Unlock()
	sort.Strings(o.cached)
	return o
}

func lrclibGetBody(track, artist string, extra string) string {
	return `{"trackName":"` + track + `","artistName":"` + artist + `","duration":200` + extra + `}`
}

func TestLRCLIBProviderMatchesHandwrittenRound(t *testing.T) {
	synced := `,"syncedLyrics":"` + lrclibSyncedFixture + `"`
	notFound := func(*http.Request, int) (int, http.Header, string) { return http.StatusNotFound, nil, `{}` }
	cases := []lrclibParityCase{
		{
			name: "按签名直取命中", artist: "Artist", title: "Song", album: "Album", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				return http.StatusOK, nil, lrclibGetBody("Song", "Artist", synced+`,"albumName":"Album"`)
			},
			wantRequests: 1, wantLyrics: true,
		},
		{
			name: "直取 404、搜索命中", artist: "Artist", title: "Song", album: "Album", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				if r.URL.Path == "/api/search" {
					return http.StatusOK, nil, `[` + lrclibGetBody("Other", "Artist", synced) + `,` + lrclibGetBody("Song", "Artist", synced) + `]`
				}
				return http.StatusNotFound, nil, `{}`
			},
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "哪一级都没收录", artist: "Artist", title: "Song", album: "Album", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				if r.URL.Path == "/api/search" {
					return http.StatusOK, nil, `[]`
				}
				return http.StatusNotFound, nil, `{}`
			},
			wantRequests: 3,
		},
		{
			name: "503 带 Retry-After:前台等一下重发", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r *http.Request, nth int) (int, http.Header, string) {
				if nth == 1 {
					return http.StatusServiceUnavailable, lrclibOverloaded, `{"statusCode":503,"name":"ServerOverloaded"}`
				}
				return http.StatusOK, nil, lrclibGetBody("Song", "Artist", synced)
			},
			wantRequests: 2, wantWaits: 1, wantLyrics: true,
		},
		{
			// 后台那次要等本地的后台暂停结束才重发;这里的等待不真等,重发时暂停还在,被出站闸拦下、这一轮记成跳过。
			name: "503 带 Retry-After:后台的重发被本地暂停拦下", ctx: withBackgroundOutbound, artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r *http.Request, nth int) (int, http.Header, string) {
				if nth == 1 {
					return http.StatusServiceUnavailable, lrclibOverloaded, `{"statusCode":503,"name":"ServerOverloaded"}`
				}
				return http.StatusOK, nil, lrclibGetBody("Song", "Artist", synced)
			},
			wantRequests: 1, wantWaits: 1, wantSkips: true,
		},
		{
			name: "503 的 Retry-After 太长:不重发", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				return http.StatusServiceUnavailable, http.Header{"Retry-After": {"30"}}, `{}`
			},
			wantRequests: 2,
		},
		{
			name: "只有纯文本", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				if r.URL.Path == "/api/search" {
					return http.StatusOK, nil, `[]`
				}
				return http.StatusOK, nil, lrclibGetBody("Song", "Artist", `,"plainLyrics":"a\nb"`)
			},
			wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o lrclibRoundOutcome) {
				if !o.result.plainOnly {
					t.Errorf("应交成 plainOnly:%+v", o.result)
				}
			},
		},
		{
			name: "标了纯音乐", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				return http.StatusOK, nil, `{"instrumental":true}`
			},
			wantRequests: 1,
			check: func(t *testing.T, o lrclibRoundOutcome) {
				if !o.result.instrumental {
					t.Errorf("应带纯音乐标记:%+v", o.result)
				}
			},
		},
		{
			name: "条目带逐字", artist: "Adele", title: "Hello", durationSecs: 295,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				return http.StatusOK, nil, `{"trackName":"Hello","artistName":"Adele","duration":295,"syncedLyrics":"[00:06.22]Hello, it's me\n[00:11.84]\n[00:12.00]a\n[00:13.00]b",` +
					`"hasWordSync":true,"lyricsfile":` + jsonString(lyricsfileSerdeStyle) + `}`
			},
			wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o lrclibRoundOutcome) {
				if o.result.yrc == "" {
					t.Errorf("应带上逐字:%+v", o.result)
				}
			},
		},
		{
			name: "条目带罗马音和假名标注", artist: "菅原圭", title: "back shot", durationSecs: 12,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				return http.StatusOK, nil, `{"trackName":"back shot","artistName":"菅原圭","duration":12,"syncedLyrics":` + jsonString(lyricsfileTranslitSynced) +
					`,"hasWordSync":true,"lyricsfile":` + jsonString(lyricsfileTranslitDoc) + `}`
			},
			wantRequests: 1, wantLyrics: true,
			check: func(t *testing.T, o lrclibRoundOutcome) {
				if o.result.roma == "" || !strings.HasPrefix(o.result.lyr, "[kana:") {
					t.Errorf("应带上罗马音、正文前拼假名标注行:%+v", o.result)
				}
			},
		},
		{
			name: "繁体原样写法没有、归一写法有",
			ctx: func(ctx context.Context) context.Context {
				return withSearchQueryOriginal(ctx, "蘇打綠", "無與倫比的美麗", "小宇宙")
			},
			artist: "苏打绿", title: "无与伦比的美丽", album: "小宇宙", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				if r.URL.Path == "/api/get" && r.URL.Query().Get("artist_name") == "苏打绿" {
					return http.StatusOK, nil, lrclibGetBody("无与伦比的美丽", "苏打绿", synced)
				}
				if r.URL.Path == "/api/search" {
					return http.StatusOK, nil, `[]`
				}
				return http.StatusNotFound, nil, `{}`
			},
			wantRequests: 4, wantLyrics: true,
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Song (#6)", "Artist", "Song", "Album")
			},
			artist: "Artist", title: "Song", album: "Album", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				if r.URL.Query().Get("track_name") == "Song (#6)" {
					return http.StatusOK, nil, lrclibGetBody("Song (#6)", "Artist", synced)
				}
				return http.StatusNotFound, nil, `{}`
			},
			wantRequests: 1, wantLyrics: true,
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r *http.Request, _ int) (int, http.Header, string) {
				return http.StatusOK, nil, lrclibGetBody("Song", "Artist", synced)
			},
			wantRequests: 1, wantLyrics: true,
		},
		{name: "设置里关掉", disabled: true, artist: "Artist", title: "Song", durationSecs: 200, handle: notFound},
		{
			name:   "别名轮名单外",
			ctx:    func(ctx context.Context) context.Context { return withLyricSourceOnly(ctx, []string{"qq"}) },
			artist: "Artist", title: "Song", durationSecs: 200, handle: notFound,
		},
		{name: "熔断冷却中", cooling: true, artist: "Artist", title: "Song", durationSecs: 200, handle: notFound, wantSkips: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			old := runLRCLIBParityRound(t, c, false)
			got := runLRCLIBParityRound(t, c, true)
			if !reflect.DeepEqual(got.result, old.result) {
				t.Errorf("结果不一样\n经调度 %+v\n手写的 %+v", got.result, old.result)
			}
			if !slices.Equal(got.requests, old.requests) {
				t.Errorf("发出的请求不一样\n经调度 %v\n手写的 %v", got.requests, old.requests)
			}
			if !slices.Equal(got.waits, old.waits) {
				t.Errorf("重发前的等待不一样:经调度 %v,手写的 %v", got.waits, old.waits)
			}
			if !reflect.DeepEqual(got.skips, old.skips) {
				t.Errorf("记下的跳过不一样:经调度 %v,手写的 %v", got.skips, old.skips)
			}
			if !slices.Equal(got.cached, old.cached) {
				t.Errorf("进程内缓存不一样:经调度 %v,手写的 %v", got.cached, old.cached)
			}
			// 两条路一样之外,场景本身得是它标题说的那种情形。
			if len(got.requests) != c.wantRequests || len(got.waits) != c.wantWaits {
				t.Errorf("发了 %d 个请求、等了 %d 次,这个场景应是 %d 个、%d 次:%v", len(got.requests), len(got.waits), c.wantRequests, c.wantWaits, got.requests)
			}
			if (got.result.lyr != "") != c.wantLyrics {
				t.Errorf("有没有拿到歌词(%v)跟场景不符:%+v", got.result.lyr != "", got.result)
			}
			if got.result.source != lyricSourceLRCLIB {
				t.Errorf("源名 %q", got.result.source)
			}
			if (len(got.skips) > 0) != c.wantSkips {
				t.Errorf("记没记跳过(%v)跟场景不符", got.skips)
			}
			if c.check != nil {
				c.check(t, got)
			}
		})
	}
}

// 这一轮被取消(用户停止搜索,或循环到截止返回时的 cancel):还在飞的 LRCLIB 请求跟着断,不等它自己超时。
func TestLRCLIBProviderRequestCancelledWithRound(t *testing.T) {
	arrived := make(chan struct{})
	aborted := make(chan struct{})
	var arriveOnce, abortOnce sync.Once
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		arriveOnce.Do(func() { close(arrived) })
		<-r.Context().Done()
		abortOnce.Do(func() { close(aborted) })
		return http.StatusNotFound, nil, `{}`
	})
	enableOnlyLyricSources(t, lyricSourceLRCLIB)
	ctx, cancel := context.WithCancel(qqRoundCtx())
	defer cancel()
	returned := make(chan struct{})
	go func() {
		defer close(returned)
		fetchScoredLyricCandidatesStreaming(ctx, "Artist", "Song", "", 200, nil)
	}()
	for _, step := range []struct {
		ch   chan struct{}
		what string
		then func()
	}{
		{arrived, "请求没发到服务端", cancel},
		{returned, "取消后收集循环没返回", nil},
		{aborted, "循环返回后服务端那个请求还挂着", nil},
	} {
		// 上限要明显短于 LRCLIB 请求自己的超时(第一级 8 秒):等到它自己超时才断的不算跟着这一轮断。
		select {
		case <-step.ch:
		case <-time.After(4 * time.Second):
			t.Fatal(step.what)
		}
		if step.then != nil {
			step.then()
		}
	}
}

// 开搜前这一轮已经取消:两条路都问不出东西,也都不留缓存。
func TestLRCLIBProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	run := func(viaScheduler bool) (lyricSourceResult, int) {
		withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
			return http.StatusOK, nil, lrclibGetBody("Song", "Artist", `,"syncedLyrics":"`+lrclibSyncedFixture+`"`)
		})
		enableOnlyLyricSources(t, lyricSourceLRCLIB)
		ctx, cancel := context.WithCancel(qqRoundCtx())
		cancel()
		var r lyricSourceResult
		if viaScheduler {
			plan := newLyricRoundPlan(ctx, sharedLyricSourceBreaker().planRound(lyricSourceNames))
			q := ProviderQuery{Artist: "Artist", Title: "Song", SourceTitle: lyricSourceTitleFor(ctx, "Song"), DurationSecs: 200}
			r = runLyricProvider(ctx, lyricProviderNamed(t, lyricSourceLRCLIB), q, RoundEnv{}, plan)
		} else {
			r = handwrittenLRCLIBRound(ctx, "Artist", "Song", "", 200)
		}
		lrclibMu.Lock()
		defer lrclibMu.Unlock()
		return r, len(lrclibCache)
	}
	old, oldCached := run(false)
	got, gotCached := run(true)
	if !reflect.DeepEqual(got, old) || got.lyr != "" || got.source != lyricSourceLRCLIB {
		t.Errorf("结果:经调度 %+v,手写的 %+v", got, old)
	}
	if gotCached != oldCached || gotCached != 0 {
		t.Errorf("进程内缓存:经调度 %d 条,手写的 %d 条,都应为 0", gotCached, oldCached)
	}
}
