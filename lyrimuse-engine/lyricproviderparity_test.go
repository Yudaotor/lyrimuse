package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"slices"
	"sort"
	"sync"
	"testing"
	"time"
)

// 各源接到 LyricProvider 之后的新旧对拍共用的夹具:同一个假服务器、同一张场景表,一边照迁移前收集循环里手写 goroutine 的
// 写法问(handwrittenProviderRound),一边走真的收集循环,比结果全字段、发出的请求、这一轮记下的跳过、进程内缓存和
// 出站闸 / 熔断 / 源自己的状态。见 09 章决策 391。

// providerParitySource:一个源在对拍里要用的东西。
type providerParitySource struct {
	name string
	// handwritten:迁移前收集循环里这个源那个 goroutine 判完跳过之后的部分,原样留着当参照。
	handwritten func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult
	// reset:把这个源的进程内状态(缓存、会话、密钥位置、失败原因……)换成空的,测完换回。
	reset func(t *testing.T)
	// cacheKeys:进程内缓存里现在的键。
	cacheKeys func() []string
	// state:这个源自己的其它状态,一行一项;nil = 没有。
	state func() []string
	// headers:记请求时一并记下的请求头。
	headers []string
	// baseCtx:这个源普通一轮用的 ctx;nil = 前台、不带任何标记。
	baseCtx func(context.Context) context.Context
	// guard:假服务器装好后调一下新换上的出站闸(单测总入口把速率和小时额度都放开了,要按生产的表测的源在这里换回来)。
	guard func(g *hostGuard)
}

// parityRequest:假服务器收到的一个发给被测源的请求。
type parityRequest struct {
	*http.Request
	// target:`协议://主机/路径`。
	target string
	body   string
	// nth:这是发给被测源的第几个请求,从 1 起。
	nth int
}

// parityReply:status 为 0 当 200。
type parityReply struct {
	status int
	header http.Header
	body   string
}

func parityOK(body string) parityReply         { return parityReply{body: body} }
func parityStatus(status int) parityReply      { return parityReply{status: status} }
func parityNotFound(parityRequest) parityReply { return parityReply{status: http.StatusNotFound} }

// parityHang 把这个请求挂到它被取消为止。源并发发两条检索、一条失败就返回时,另一条用它:让那一条在两条路上都是
// 「这一轮结束时被取消」,不然它的应答到得早晚会让这一轮记下的东西(问到了没有、熔断计数)时有时无。
func parityHang(r parityRequest) parityReply {
	<-r.Context().Done()
	return parityReply{status: http.StatusServiceUnavailable}
}

type parityFake struct {
	mu    sync.Mutex
	lines []string
}

// requests:发给被测源的请求,一行一个(方法、地址、排好序的查询参数、请求体、点名要记的请求头),排好序。
func (f *parityFake) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := slices.Clone(f.lines)
	sort.Strings(out)
	return out
}

// withParityFake 把歌词源的出站请求(http 和 https)接到本地假服务器,出站闸和熔断器换成新的,测完复原。只有主机归被测源的
// 请求才记下来、交给 handle;别的主机一律回 404(收集循环里别的源都关着,走到这里的只有被测源借别家接口查的东西)。
func withParityFake(t *testing.T, s providerParitySource, handle func(parityRequest) parityReply) *parityFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	g := newHostGuard(time.Now)
	if s.guard != nil {
		s.guard(g)
	}
	setSharedHostGuard(g)
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
	})
	f := &parityFake{}
	mk := func(scheme string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			host := r.Host
			if h, _, err := net.SplitHostPort(host); err == nil {
				host = h
			}
			if lyricSourceForHost(host) != s.name {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			raw, _ := io.ReadAll(r.Body)
			target := scheme + "://" + host + r.URL.Path
			line := r.Method + " " + target
			if q := r.URL.Query().Encode(); q != "" {
				line += "?" + q
			}
			if len(raw) > 0 {
				line += " body=" + string(raw)
			}
			for _, h := range s.headers {
				if v := r.Header.Get(h); v != "" {
					line += " " + h + "=" + v
				}
			}
			f.mu.Lock()
			f.lines = append(f.lines, line)
			nth := len(f.lines)
			f.mu.Unlock()
			reply := handle(parityRequest{Request: r, target: target, body: string(raw), nth: nth})
			for k, vs := range reply.header {
				for _, v := range vs {
					w.Header().Add(k, v)
				}
			}
			if reply.status != 0 {
				w.WriteHeader(reply.status)
			}
			_, _ = io.WriteString(w, reply.body)
		}
	}
	plain := httptest.NewServer(mk("http"))
	secure := httptest.NewTLSServer(mk("https"))
	t.Cleanup(plain.Close)
	t.Cleanup(secure.Close)
	plainAddr, secureAddr := plain.Listener.Addr().String(), secure.Listener.Addr().String()
	setSharedLyricSourceTransport(&http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			target := plainAddr
			if _, port, _ := net.SplitHostPort(addr); port == "443" {
				target = secureAddr
			}
			return (&net.Dialer{}).DialContext(ctx, network, target)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	})
	return f
}

type providerParityCase struct {
	name string
	// ctx 给这一轮挂上要测的标记(后台、别名轮名单、带编号的歌名……),接在源的 baseCtx 后面;nil = 不加。
	ctx func(context.Context) context.Context
	// bareCtx:不用源的 baseCtx,从不带任何标记的 ctx 起。
	bareCtx bool
	// disabled:设置里关掉这个源;cooling:开搜前它已在熔断冷却。
	disabled, cooling bool
	// alsoEnable:另外开着的源(被测源借它的接口时用)。
	alsoEnable []string
	// rounds:同一首连问几轮(看进程内缓存),0 当 1。
	rounds               int
	artist, title, album string
	durationSecs         float64
	// prepare 在假服务器装好之后、开搜之前跑:预先用掉额度、塞会话之类。
	prepare func(t *testing.T)
	handle  func(r parityRequest) parityReply
	// wantRequests:这个场景该发几个请求。
	wantRequests          int
	wantLyrics, wantSkips bool
	check                 func(t *testing.T, o providerParityOutcome)
}

type providerParityOutcome struct {
	result   lyricSourceResult
	requests []string
	// round:这一轮记下的东西(跳过名单、近况统计用的跳过原因、问到了没有、开着的源)。
	round  []string
	skips  map[string]string
	cached []string
	state  []string
}

// handwrittenProviderRound 照收集循环里手写 goroutine 的写法问一个源一轮:lyricSourceSkippedThisRound 判跳过,没跳过的
// 走 s.handwritten。跟收集循环一样,返回时取消这一轮的 ctx:源里并发发出去、还没回来的请求在两条路上都跟着断。
func handwrittenProviderRound(ctx context.Context, s providerParitySource, artist, title, album string, durationSecs float64) lyricSourceResult {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	srcTitle := lyricSourceTitleFor(ctx, title)
	breakerPlan := sharedLyricSourceBreaker().planRound(lyricSourceNames)
	if lyricSourceSkippedThisRound(ctx, s.name, lyricSourceOnlyFrom(ctx), breakerPlan, lyricSourceRoundFrom(ctx)) {
		return lyricSourceResult{source: s.name}
	}
	return s.handwritten(ctx, artist, title, srcTitle, album, durationSecs)
}

// lyricProviderNamed:登记表里这个源的实现。
func lyricProviderNamed(t *testing.T, name string) LyricProvider {
	t.Helper()
	for _, p := range lyricProviders().providers {
		if p.Descriptor().Name == name {
			return p
		}
	}
	t.Fatalf("%s 没有登记实现", name)
	return nil
}

func (s providerParitySource) roundCtx(c providerParityCase) context.Context {
	ctx := context.Background()
	if s.baseCtx != nil && !c.bareCtx {
		ctx = s.baseCtx(ctx)
	}
	if c.ctx != nil {
		ctx = c.ctx(ctx)
	}
	return ctx
}

// providerParityGuardState:出站闸和熔断器里跟这个源有关的状态。还剩多久按真实时钟算(每日额度的重置时刻还只记到整秒),
// 取整到 10 秒、每日额度取整到分钟再比。
func providerParityGuardState(name string) []string {
	b, g := sharedLyricSourceBreaker(), sharedHostGuard()
	left, cooling := b.coolingDown(name)
	out := []string{fmt.Sprintf("breaker cooling=%v left=%s reason=%q", cooling, left.Round(10*time.Second), b.cooldownReason(name))}
	g.mu.Lock()
	var hosts []string
	for host := range g.bgPause {
		if lyricSourceForHost(host) == name {
			hosts = append(hosts, host)
		}
	}
	g.mu.Unlock()
	sort.Strings(hosts)
	for _, host := range hosts {
		if until, paused := g.backgroundPausedUntil(host); paused {
			out = append(out, fmt.Sprintf("background paused %s for %s", host, time.Until(until).Round(10*time.Second)))
		}
	}
	if left, limited := g.sourceBudgetLeft(name); limited {
		out = append(out, fmt.Sprintf("hourly budget left=%d", left))
	}
	now := time.Now()
	if pause, paused := sourceDayQuotaPausedFor(name, now); paused || sourceDayQuotaLow(name, now) {
		out = append(out, fmt.Sprintf("day quota low=%v paused=%v for %s", sourceDayQuotaLow(name, now), paused, pause.Round(time.Minute)))
	}
	return out
}

func runProviderParityRound(t *testing.T, s providerParitySource, c providerParityCase, viaScheduler bool) providerParityOutcome {
	t.Helper()
	s.reset(t)
	fake := withParityFake(t, s, c.handle)
	enabled := slices.Clone(c.alsoEnable)
	if !c.disabled {
		enabled = append(enabled, s.name)
	}
	enableOnlyLyricSources(t, enabled...)
	if c.prepare != nil {
		c.prepare(t)
	}
	if c.cooling {
		coolingBreakerFor(t, lyricProviders().descriptor(s.name), true)
	}
	ctx, round := withLyricSourceRound(s.roundCtx(c))
	var result lyricSourceResult
	for range max(c.rounds, 1) {
		if !viaScheduler {
			result = withoutPlayerIdentity(ctx, handwrittenProviderRound(ctx, s, c.artist, c.title, c.album, c.durationSecs))
			result.forPlayingTrack = playerSignalApplies(ctx)
			continue
		}
		var got *lyricSourceResult
		saved := lyricSourceResultTap
		lyricSourceResultTap = func(r lyricSourceResult) {
			if r.source == s.name {
				got = &r
			}
		}
		fetchScoredLyricCandidatesStreaming(ctx, c.artist, c.title, c.album, c.durationSecs, nil)
		lyricSourceResultTap = saved
		if got == nil {
			t.Fatalf("%s:收集循环没收到 %s 的结果", c.name, s.name)
		}
		result = *got
	}
	o := providerParityOutcome{result: result, requests: fake.requests(), skips: round.statsSkips(), cached: s.cacheKeys()}
	sort.Strings(o.cached)
	o.round = []string{
		fmt.Sprintf("skipped=%v", round.skippedSources()),
		fmt.Sprintf("reached=%v", round.reachedSource(s.name)),
		fmt.Sprintf("enabled=%v", round.enabledSources()),
	}
	o.state = providerParityGuardState(s.name)
	if s.state != nil {
		o.state = append(o.state, s.state()...)
	}
	return o
}

// runProviderParity 逐个场景比两条路,再核对场景本身是它标题说的那种情形。
func runProviderParity(t *testing.T, s providerParitySource, cases []providerParityCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			old := runProviderParityRound(t, s, c, false)
			got := runProviderParityRound(t, s, c, true)
			if !reflect.DeepEqual(got.result, old.result) {
				t.Errorf("结果不一样\n经调度 %+v\n手写的 %+v", got.result, old.result)
			}
			if !slices.Equal(got.requests, old.requests) {
				t.Errorf("发出的请求不一样\n经调度 %v\n手写的 %v", got.requests, old.requests)
			}
			if !slices.Equal(got.round, old.round) || !reflect.DeepEqual(got.skips, old.skips) {
				t.Errorf("这一轮记下的不一样\n经调度 %v %v\n手写的 %v %v", got.round, got.skips, old.round, old.skips)
			}
			if !slices.Equal(got.cached, old.cached) {
				t.Errorf("进程内缓存不一样:经调度 %v,手写的 %v", got.cached, old.cached)
			}
			if !slices.Equal(got.state, old.state) {
				t.Errorf("出站闸 / 熔断 / 源自己的状态不一样\n经调度 %v\n手写的 %v", got.state, old.state)
			}
			if len(got.requests) != c.wantRequests {
				t.Errorf("发了 %d 个请求,这个场景应是 %d 个:%v", len(got.requests), c.wantRequests, got.requests)
			}
			if (got.result.lyr != "") != c.wantLyrics {
				t.Errorf("有没有拿到歌词(%v)跟场景不符:%+v", got.result.lyr != "", got.result)
			}
			if got.result.source != s.name {
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

// 三个跟源无关的跳过场景:设置里关掉、别名轮名单外、熔断冷却中。
func providerParitySkipCases(artist, title string, durationSecs float64) []providerParityCase {
	return []providerParityCase{
		{name: "设置里关掉", disabled: true, artist: artist, title: title, durationSecs: durationSecs, handle: parityNotFound},
		{
			name: "别名轮名单外",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceOnly(ctx, []string{"provider-test-other"})
			},
			artist: artist, title: title, durationSecs: durationSecs, handle: parityNotFound,
		},
		{name: "熔断冷却中", cooling: true, artist: artist, title: title, durationSecs: durationSecs, handle: parityNotFound, wantSkips: true},
	}
}

// runProviderCancelledMidRequest:这一轮被取消(用户停止搜索,或循环到截止返回时的 cancel)时,这个源还在飞的请求跟着断,
// 不等它自己超时。假服务器把发给它的请求全挂住。
func runProviderCancelledMidRequest(t *testing.T, s providerParitySource, artist, title string, durationSecs float64) {
	t.Helper()
	arrived := make(chan struct{})
	aborted := make(chan struct{})
	var arriveOnce, abortOnce sync.Once
	s.reset(t)
	withParityFake(t, s, func(r parityRequest) parityReply {
		arriveOnce.Do(func() { close(arrived) })
		<-r.Context().Done()
		abortOnce.Do(func() { close(aborted) })
		return parityStatus(http.StatusNotFound)
	})
	enableOnlyLyricSources(t, s.name)
	base, _ := withLyricSourceRound(s.roundCtx(providerParityCase{}))
	ctx, cancel := context.WithCancel(base)
	defer cancel()
	returned := make(chan struct{})
	go func() {
		defer close(returned)
		fetchScoredLyricCandidatesStreaming(ctx, artist, title, "", durationSecs, nil)
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
		// 上限要明显短于各源请求自己的超时(最短 6 秒):等到它自己超时才断的不算跟着这一轮断。
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

// runProviderCancelledBeforeRound:开搜前这一轮已经取消,两条路都问不出东西、不发请求、不留缓存。
func runProviderCancelledBeforeRound(t *testing.T, s providerParitySource, artist, title string, durationSecs float64, hit func(parityRequest) parityReply) {
	t.Helper()
	run := func(viaScheduler bool) (lyricSourceResult, []string, []string) {
		s.reset(t)
		fake := withParityFake(t, s, hit)
		enableOnlyLyricSources(t, s.name)
		base, _ := withLyricSourceRound(s.roundCtx(providerParityCase{}))
		ctx, cancel := context.WithCancel(base)
		cancel()
		var r lyricSourceResult
		if viaScheduler {
			plan := newLyricRoundPlan(ctx, sharedLyricSourceBreaker().planRound(lyricSourceNames))
			q := ProviderQuery{Artist: artist, Title: title, SourceTitle: lyricSourceTitleFor(ctx, title), DurationSecs: durationSecs}
			r = runLyricProvider(ctx, lyricProviderNamed(t, s.name), q, RoundEnv{}, plan)
		} else {
			r = handwrittenProviderRound(ctx, s, artist, title, "", durationSecs)
		}
		return r, fake.requests(), s.cacheKeys()
	}
	old, oldReqs, oldCached := run(false)
	got, gotReqs, gotCached := run(true)
	if !reflect.DeepEqual(got, old) || got.lyr != "" || got.source != s.name {
		t.Errorf("结果:经调度 %+v,手写的 %+v", got, old)
	}
	if len(gotReqs) != 0 || len(oldReqs) != 0 {
		t.Errorf("已取消的一轮不该发请求:经调度 %v,手写的 %v", gotReqs, oldReqs)
	}
	if len(gotCached) != 0 || len(oldCached) != 0 {
		t.Errorf("进程内缓存:经调度 %v,手写的 %v,都应为空", gotCached, oldCached)
	}
}

// 已经接到 LyricProvider 上的源:登记表里各有一份实现,收集循环里没有它们的手写 goroutine,入口函数从查询里取的歌名是
// SourceTitle(带编号的那份)。
func TestMigratedLyricSourcesAreWiredThroughProviders(t *testing.T) {
	enrichRaw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	enrich := string(enrichRaw)
	implemented := map[string]bool{}
	for _, p := range lyricProviders().providers {
		implemented[p.Descriptor().Name] = true
	}
	for _, m := range migratedLyricSources {
		if !implemented[m.name] {
			t.Errorf("%s 应登记一份实现", m.name)
		}
		if containsCode(enrich, m.entry+"(ctx, artist, srcTitle,") {
			t.Errorf("enrich.go 的收集循环里还留着 %s 的手写调用", m.name)
		}
		raw, err := os.ReadFile(m.file)
		if err != nil {
			t.Fatal(err)
		}
		if !containsCode(string(raw), m.call) {
			t.Errorf("%s 缺 %q", m.file, m.call)
		}
	}
	if len(implemented) != len(migratedLyricSources)+1 {
		t.Errorf("登记了实现的源 %d 个,这张表加 lrclib 是 %d 个:迁了新的源要补进表里", len(implemented), len(migratedLyricSources)+1)
	}
}

// migratedLyricSources:LRCLIB 之后迁到 LyricProvider 上的源,和各自 Resolve 里调入口函数的那一行。
var migratedLyricSources = []struct{ name, file, entry, call string }{
	{lyricSourceMegalobiz, "megalobiz.go", "megalobizLyric", "megalobizLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
	{lyricSourceVibe, "vibe.go", "vibeLyric", "vibeLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
	{lyricSourceGenie, "genie.go", "genieLyric", "genieLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
	{lyricSourcePetitLyrics, "petitlyrics.go", "petitLyric", "petitLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
	{lyricSourceZing, "zing.go", "zingLyric", "zingLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
	{lyricSourceMigu, "migu.go", "miguLyric", "miguLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
	{lyricSourceDeezer, "deezer.go", "deezerLyric", "deezerLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs, lyricSourceISRC(ctx, q.Artist, q.Title, q.Album))"},
	{lyricSourceLyricFind, "ytmusic.go", "ytmusicLyric", "ytmusicLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)"},
}
