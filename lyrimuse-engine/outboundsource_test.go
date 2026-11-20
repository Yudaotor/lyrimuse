package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	neturl "net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// withOutboundSourceTag:把 ctx 标成 source 这个源发的请求。生产代码里只有读标签的一侧(outboundsource.go),内置源和调度都
// 不打标签;这里照以后带标签的调用方的写法造这个 ctx 值。
func withOutboundSourceTag(ctx context.Context, source string) context.Context {
	return context.WithValue(ctx, outboundOriginKey{}, &outboundOrigin{source: source, tagged: true})
}

// fakeTaggedSource:没登记的源名,带着它的标签去打内置源的主机。
const fakeTaggedSource = "tagged:fake"

// useFreshLyricSourceSlots:在途名额换成空的,测完换回去。
func useFreshLyricSourceSlots(t *testing.T) {
	t.Helper()
	lyricSourceSlotsMu.Lock()
	saved := lyricSourceSlots
	lyricSourceSlots = map[string]chan struct{}{}
	lyricSourceSlotsMu.Unlock()
	t.Cleanup(func() {
		lyricSourceSlotsMu.Lock()
		lyricSourceSlots = saved
		lyricSourceSlotsMu.Unlock()
	})
}

// useFreshOutboundState:共享的出站闸、熔断器换成新的(令牌给足),测完换回去。
func useFreshOutboundState(t *testing.T) (*hostGuard, *guardClock) {
	t.Helper()
	savedGuard, savedBreaker := sharedHostGuard(), sharedLyricSourceBreaker()
	g, c := newTestGuard(hostRate{perSec: 1000, burst: 1000})
	setSharedHostGuard(g)
	setSharedLyricSourceBreaker(newLyricSourceBreaker(c.now))
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
	})
	return g, c
}

func statusClient(status int, header http.Header) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: status, Header: header.Clone(), Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}
}

// 归源等价:不带标签时,入口算出来的归源、各处读到的归源,跟按主机反查的旧函数(期望表里的 lyricSourceForHost)对每个样本相等。
func TestOutboundSourceMatchesHostAttributionWhenUntagged(t *testing.T) {
	bases, probes := hostAttributionSamples(t)
	compared, owned := 0, map[string]bool{}
	for _, probe := range probes {
		// 多于一个冒号的主机写不进请求地址(拨不出去),不在这条用例里比。
		if strings.Count(probe, ":") > 1 {
			continue
		}
		want := lyricSourceForHost(probe)
		u := &neturl.URL{Scheme: "https", Host: strings.TrimSpace(probe), Path: "/x"}
		req := (&http.Request{Method: http.MethodGet, URL: u}).WithContext(context.Background())
		host := guardHost(u)
		if got := outboundSourceFor(req.Context(), host); got != want {
			t.Errorf("%q:没挂结果的 ctx 上读到 %q,旧函数 %q", probe, got, want)
		}
		attributed := withOutboundSource(req)
		o := outboundOriginFrom(attributed.Context())
		if o == nil || o.tagged || o.host != host || o.source != want {
			t.Errorf("%q:入口挂的结果 %+v,期望主机 %q、源 %q、不是标签", probe, o, host, want)
		}
		if got := outboundSourceFor(attributed.Context(), host); got != want {
			t.Errorf("%q:入口算过之后读到 %q,旧函数 %q", probe, got, want)
		}
		if again := withOutboundSource(attributed); again != attributed {
			t.Errorf("%q:已经算过的请求又挂了一份", probe)
		}
		compared++
		if want != "" {
			owned[want] = true
		}
	}
	if len(owned) != len(lyricSourceNames) {
		t.Errorf("样本只归到 %d 个源,联网源有 %d 个", len(owned), len(lyricSourceNames))
	}
	t.Logf("归源等价:%d 个主机、%d 个样本,统一归源 == 按主机反查的旧函数;归到 %d 个源", len(bases), compared, len(owned))
}

// 归源规则:有标签用标签(发往哪个主机都一样);没有标签按主机归;为别的主机算的结果不算数。
func TestOutboundSourceTagWinsOverHost(t *testing.T) {
	bg := context.Background()
	tagged := withOutboundSourceTag(bg, fakeTaggedSource)
	for _, host := range []string{"lrclib.net", "c.y.qq.com", "api.megalobiz.com", "example.org", ""} {
		if got := outboundSourceFor(tagged, host); got != fakeTaggedSource {
			t.Errorf("带标签打 %q 归到 %q,该归标签", host, got)
		}
	}
	req := mustReq(t, tagged, http.MethodGet, "https://lrclib.net/api/get")
	if again := withOutboundSource(req); again != req {
		t.Error("带标签的请求入口不该再挂一份按主机归的结果")
	}

	// 标签盖过外层已经按主机算好的结果。
	byHost := withOutboundSource(mustReq(t, bg, http.MethodGet, "https://lrclib.net/api/get"))
	if got := outboundSourceFor(byHost.Context(), "lrclib.net"); got != "lrclib" {
		t.Fatalf("前提:不带标签按主机归,得到 %q", got)
	}
	if got := outboundSourceFor(withOutboundSourceTag(byHost.Context(), fakeTaggedSource), "lrclib.net"); got != fakeTaggedSource {
		t.Errorf("后打的标签该盖过按主机归的结果,得到 %q", got)
	}

	// 为 lrclib.net 算的结果,对别的主机不算数:那个主机按它自己归。
	for host, want := range map[string]string{"music.163.com": "netease", "example.org": "", "api.deezer.com": "deezer"} {
		if got := outboundSourceFor(byHost.Context(), host); got != want {
			t.Errorf("ctx 上挂着 lrclib.net 的结果,问 %q 得到 %q,期望 %q", host, got, want)
		}
	}
	moved := byHost.Clone(byHost.Context())
	moved.URL, _ = neturl.Parse("https://music.163.com/api/x")
	if o := outboundOriginFrom(withOutboundSource(moved).Context()); o == nil || o.host != "music.163.com" || o.source != "netease" {
		t.Errorf("换了主机的请求该重新算一份,得到 %+v", o)
	}
}

// doHTTPTracked 入口算一次归源:合并之前就挂上,传输层那一头读到的就是这一份。
func TestDoHTTPTrackedAttributesAtEntry(t *testing.T) {
	useFreshOutboundState(t)
	useFreshLyricSourceSlots(t)
	var seen []*outboundOrigin
	cli := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		seen = append(seen, outboundOriginFrom(r.Context()))
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}
	for _, raw := range []string{"https://LRCLIB.net:443/api/get", "https://api.example.org/x"} {
		resp, err := doHTTPTracked(cli, mustReq(t, context.Background(), http.MethodGet, raw))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
	}
	if len(seen) != 2 || seen[0] == nil || seen[1] == nil {
		t.Fatalf("传输层没读到入口挂的归源: %v", seen)
	}
	if *seen[0] != (outboundOrigin{source: "lrclib", host: "lrclib.net"}) || *seen[1] != (outboundOrigin{host: "api.example.org"}) {
		t.Errorf("入口挂的归源 %+v、%+v", *seen[0], *seen[1])
	}
	src := string(mustRead(t, "httpcoalesce.go"))
	if !containsCode(src, "func doHTTPTracked(cli *http.Client, req *http.Request) (*http.Response, error) {\n\treq = withOutboundSource(req)\n\tkey, ok := httpCoalesceKey(req)") {
		t.Error("doHTTPTracked 没在进来的第一步算归源(要先于请求合并)")
	}
	if n := countCode(src, "withOutboundSource(") + countCode(string(mustRead(t, "networkobs.go")), "withOutboundSource("); n != 1 {
		t.Errorf("归源该只在 doHTTPTracked 入口算一次,出站两个文件里调了 %d 处", n)
	}
}

// 在途名额占谁的:按归到的源占,同一个源的几个主机共用;带标签的请求占标签那个源的,不占主机主人的。
func TestInflightSlotBelongsToAttributedSource(t *testing.T) {
	useFreshLyricSourceSlots(t)
	held := func(source string) int { return len(lyricSourceSlotsFor(source)) }
	bg := context.Background()
	var releases []func()
	acquire := func(ctx context.Context, host string) {
		t.Helper()
		release, err := acquireLyricSourceSlot(ctx, host)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	acquire(bg, "c.y.qq.com")
	acquire(bg, "u.y.qq.com")
	acquire(bg, "lrclib.net")
	if held("qq") != 2 || held("lrclib") != 1 {
		t.Fatalf("同一个源的几个主机共用名额: qq %d、lrclib %d", held("qq"), held("lrclib"))
	}
	tagged := withOutboundSourceTag(bg, fakeTaggedSource)
	acquire(tagged, "lrclib.net")
	acquire(tagged, "example.org")
	if held(fakeTaggedSource) != 2 || held("lrclib") != 1 {
		t.Errorf("带标签的请求占自己的名额、不占主机主人的: 自己 %d、lrclib %d", held(fakeTaggedSource), held("lrclib"))
	}
	if cap(lyricSourceSlotsFor(fakeTaggedSource)) != lyricSourceInflightDefault {
		t.Errorf("没登记的源用默认上限,得到 %d", cap(lyricSourceSlotsFor(fakeTaggedSource)))
	}
	// 入口按主机算好的结果:占的是那个源的。
	byHost := withOutboundSource(mustReq(t, bg, http.MethodGet, "https://api.deezer.com/search"))
	acquire(byHost.Context(), guardHost(byHost.URL))
	if held("deezer") != 1 {
		t.Errorf("入口算过的请求该占 deezer 的名额,得到 %d", held("deezer"))
	}
	acquire(bg, "example.org")
	lyricSourceSlotsMu.Lock()
	_, anonymous := lyricSourceSlots[""]
	lyricSourceSlotsMu.Unlock()
	if anonymous {
		t.Error("不归任何歌词源的请求不该占名额")
	}
	for _, release := range releases {
		release()
	}
	if held("qq") != 0 || held("lrclib") != 0 || held(fakeTaggedSource) != 0 || held("deezer") != 0 {
		t.Error("名额没还干净")
	}
}

// 冷却记在谁头上、令牌桶算谁的:排不上队之后拦的是归到的那个源(带标签的只拦自己),按主机的令牌桶两边共用。
func TestQueueHoldBelongsToAttributedSourceAndBucketToHost(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 0.01, burst: 2})
	g.maxWait = time.Second
	roundCtx, round := withLyricSourceRound(context.Background())
	tagged := withOutboundSourceTag(roundCtx, fakeTaggedSource)
	const lrclibGet = "https://lrclib.net/api/get"
	if err := g.admit(mustReq(t, tagged, http.MethodGet, lrclibGet)); err != nil {
		t.Fatal(err)
	}
	if err := g.admit(mustReq(t, roundCtx, http.MethodGet, lrclibGet)); err != nil {
		t.Fatalf("桶里还有一个: %v", err)
	}
	// 两个令牌一个给了带标签的、一个给了不带的:按主机共用,第三个排不上。
	if err := g.admit(mustReq(t, tagged, http.MethodGet, lrclibGet)); !errors.Is(err, errHostRateLimited) {
		t.Fatalf("带标签的请求跟主机主人共用这个主机的令牌桶,该排不上: %v", err)
	}
	if !g.sourceHeldNow(fakeTaggedSource, laneForeground) || g.sourceHeldNow("lrclib", laneForeground) {
		t.Errorf("排不上队拦的是带标签的那个源自己,不是主机的主人: 自己 %v、lrclib %v",
			g.sourceHeldNow(fakeTaggedSource, laneForeground), g.sourceHeldNow("lrclib", laneForeground))
	}
	if got := round.skippedSources(); len(got) != 1 || got[0] != fakeTaggedSource {
		t.Errorf("这一轮该记带标签的那个源被跳过: %v", got)
	}
	// 被拦期间它换别的主机也拦;主机主人换一个主机(另一只桶)照发。
	if err := g.admit(mustReq(t, tagged, http.MethodGet, "https://api.example.org/x")); !errors.Is(err, errHostRateLimited) {
		t.Errorf("带标签的源在被拦期间换主机也该拦下: %v", err)
	}
	if err := g.admit(mustReq(t, roundCtx, http.MethodGet, "https://mirror.lrclib.net/api/get")); err != nil {
		t.Errorf("主机的主人没被拦: %v", err)
	}
	// 不带标签时,拦的是主机的主人。
	if err := g.admit(mustReq(t, roundCtx, http.MethodGet, lrclibGet)); !errors.Is(err, errHostRateLimited) {
		t.Fatalf("lrclib.net 的桶空了: %v", err)
	}
	if !g.sourceHeldNow("lrclib", laneForeground) {
		t.Error("不带标签的请求排不上队,该拦主机的主人")
	}
}

// 小时额度扣谁的:记在归到的源头上。带标签的请求打有额度的主机,不动主机主人的额度。
func TestHourlyBudgetChargedToAttributedSource(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 1000, burst: 1000})
	g.sourceBudget = func(source string) int {
		switch source {
		case lyricSourceMegalobiz:
			return 5
		case fakeTaggedSource:
			return 1
		}
		return 0
	}
	const url = "https://api.megalobiz.com/api/public/v1/search?title=x"
	bgCtx, round := withLyricSourceRound(withBackgroundOutbound(context.Background()))
	tagged := withOutboundSourceTag(bgCtx, fakeTaggedSource)
	if err := g.admit(mustReq(t, tagged, http.MethodGet, url)); err != nil {
		t.Fatal(err)
	}
	if left, _ := g.sourceBudgetLeft(lyricSourceMegalobiz); left != 5 {
		t.Errorf("带标签的请求不该扣主机主人的小时额度,还剩 %d", left)
	}
	if left, _ := g.sourceBudgetLeft(fakeTaggedSource); left != 0 {
		t.Errorf("带标签的请求扣自己的小时额度,还剩 %d", left)
	}
	if err := g.admit(mustReq(t, tagged, http.MethodGet, url)); !errors.Is(err, errHostGuarded) {
		t.Errorf("自己的额度用完,后台该被拦: %v", err)
	}
	if got := round.statsSkips(); got[fakeTaggedSource] != lyricSourceSkipReasonBudget || len(got) != 1 {
		t.Errorf("跳过记在带标签的那个源头上: %v", got)
	}
	if err := g.admit(mustReq(t, bgCtx, http.MethodGet, url)); err != nil {
		t.Fatalf("主机主人的额度没动,后台照发: %v", err)
	}
	if left, _ := g.sourceBudgetLeft(lyricSourceMegalobiz); left != 4 {
		t.Errorf("不带标签的请求扣主机主人的额度,还剩 %d", left)
	}
}

// 每日额度扣谁的:剩得少时拦的是归到这个源的后台请求。带标签的请求打同一个主机不受它管,也不动它的记录。
func TestDayQuotaGatesAttributedSource(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	g, c := newTestGuard(hostRate{perSec: 1000, burst: 1000})
	const url = "https://api.megalobiz.com/api/public/v1/search?title=x"
	noteSourceDayQuota(lyricSourceMegalobiz, 200, dayQuotaHeader("X-RateLimit-Remaining-Day", "10", "X-RateLimit-Reset-Day", "3600"), c.now())
	before := sourceDayQuota[lyricSourceMegalobiz]
	bgCtx, round := withLyricSourceRound(withBackgroundOutbound(context.Background()))
	if err := g.admit(mustReq(t, bgCtx, http.MethodGet, url)); !errors.Is(err, errHostGuarded) {
		t.Fatalf("前提:剩得少时归到 megalobiz 的后台请求不发: %v", err)
	}
	if got := round.statsSkips()[lyricSourceMegalobiz]; got != lyricSourceSkipReasonBudget {
		t.Errorf("跳过原因 = %q", got)
	}
	tagged := withOutboundSourceTag(bgCtx, fakeTaggedSource)
	if err := g.admit(mustReq(t, tagged, http.MethodGet, url)); err != nil {
		t.Errorf("带标签的请求不归 megalobiz,不受它的每日额度管: %v", err)
	}
	if _, skipped := round.statsSkips()[fakeTaggedSource]; skipped {
		t.Error("带标签的那个源不该被记成跳过")
	}
	if _, recorded := sourceDayQuota[fakeTaggedSource]; recorded || sourceDayQuota[lyricSourceMegalobiz] != before {
		t.Errorf("带标签的请求不该动每日额度的记录: %v", sourceDayQuota)
	}
	// 反过来:带着 megalobiz 标签打别的主机,照它的每日额度拦。
	asMegalobiz := withOutboundSourceTag(bgCtx, lyricSourceMegalobiz)
	if err := g.admit(mustReq(t, asMegalobiz, http.MethodGet, "https://api.example.org/x")); !errors.Is(err, errHostGuarded) {
		t.Errorf("归到 megalobiz 的后台请求,打哪个主机都照它的每日额度拦: %v", err)
	}
}

// 熔断按哪个主机记:失败记在实际请求的主机的主人头上,不看标签;出站闸在一轮之外查的冷却,查的是归到的那个源。
func TestBreakerRecordsByHostNotByTag(t *testing.T) {
	g, _ := useFreshOutboundState(t)
	useFreshLyricSourceSlots(t)
	breaker := sharedLyricSourceBreaker()
	boom := errors.New("connection refused")
	failing := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, boom })}
	tagged := withOutboundSourceTag(context.Background(), fakeTaggedSource)
	const lrclibGet = "https://lrclib.net/api/get"
	for range lyricSourceBreakerTripAfter {
		if _, err := doHTTPTracked(failing, mustReq(t, tagged, http.MethodGet, lrclibGet)); !errors.Is(err, boom) {
			t.Fatalf("带标签的请求该发出去并失败: %v", err)
		}
	}
	if _, cooling := breaker.coolingDown("lrclib"); !cooling {
		t.Error("打 lrclib.net 的失败记在 lrclib 头上(熔断按实际主机记),它该进冷却")
	}
	if _, cooling := breaker.coolingDown(fakeTaggedSource); cooling {
		t.Error("熔断器不按标签记")
	}
	if codes := breaker.transportFailureCodes(); codes["lrclib"] == "" || codes[fakeTaggedSource] != "" {
		t.Errorf("传输层失败记在主机的主人头上: %v", codes)
	}
	// 一轮之外:归到 lrclib 的请求被它的冷却拦下;带标签的请求查的是标签那个源的冷却。
	if err := g.admit(mustReq(t, context.Background(), http.MethodGet, lrclibGet)); !errors.Is(err, errHostGuarded) {
		t.Errorf("lrclib 冷却中,归到它的请求该拦下: %v", err)
	}
	if err := g.admit(mustReq(t, tagged, http.MethodGet, lrclibGet)); err != nil {
		t.Errorf("带标签的请求不归 lrclib,出站闸不拿 lrclib 的冷却拦它: %v", err)
	}
	asLrclib := withOutboundSourceTag(context.Background(), "lrclib")
	if err := g.admit(mustReq(t, asLrclib, http.MethodGet, "https://api.example.org/x")); !errors.Is(err, errHostGuarded) {
		t.Errorf("归到 lrclib 的请求,打哪个主机都被它的冷却拦下: %v", err)
	}
	// 后台 429 同样按主机记「这个源答了」。
	breaker.observeBackgroundRateLimited("api.deezer.com")
	if _, cooling := breaker.coolingDown("deezer"); cooling {
		t.Error("后台 429 不让源进冷却")
	}
}

// 后台暂停按实际主机记;认不认它是歌词源的请求、这一轮的跳过和连上记在谁头上,读归到的源。
func TestBackgroundPauseKeyedByHostMarksAttributedSource(t *testing.T) {
	g, _ := useFreshOutboundState(t)
	useFreshLyricSourceSlots(t)
	bgCtx, round := withLyricSourceRound(withBackgroundOutbound(context.Background()))
	tagged := withOutboundSourceTag(bgCtx, fakeTaggedSource)
	get := func(cli *http.Client, ctx context.Context, raw string) error {
		t.Helper()
		resp, err := doHTTPTracked(cli, mustReq(t, ctx, http.MethodGet, raw))
		if err == nil {
			resp.Body.Close()
		}
		return err
	}
	ok := statusClient(http.StatusOK, nil)
	if err := get(ok, tagged, "https://lrclib.net/api/get"); err != nil {
		t.Fatal(err)
	}
	if !round.reachedSource(fakeTaggedSource) || round.reachedSource("lrclib") {
		t.Errorf("这一轮连上的是带标签的那个源,不是主机的主人: 自己 %v、lrclib %v", round.reachedSource(fakeTaggedSource), round.reachedSource("lrclib"))
	}
	if err := get(ok, bgCtx, "https://api.deezer.com/search"); err != nil || !round.reachedSource("deezer") {
		t.Errorf("不带标签的请求连上的记在主机的主人头上: err=%v deezer=%v", err, round.reachedSource("deezer"))
	}

	busy := statusClient(http.StatusServiceUnavailable, nil)
	if err := get(busy, tagged, "https://lrclib.net/api/get"); err != nil {
		t.Fatal(err)
	}
	if _, paused := g.backgroundPausedUntil("lrclib.net"); !paused {
		t.Fatal("带标签的请求在 lrclib.net 上吃到 503,该暂停这个主机的后台请求")
	}
	if err := get(ok, tagged, "https://lrclib.net/api/get"); !errors.Is(err, errHostGuarded) {
		t.Errorf("主机的后台暂停期里,带标签的后台请求也不发: %v", err)
	}
	if err := get(ok, bgCtx, "https://lrclib.net/api/get"); !errors.Is(err, errHostGuarded) {
		t.Errorf("主机的后台暂停期里,主机主人的后台请求不发: %v", err)
	}
	skipped := map[string]bool{}
	for _, s := range round.skippedSources() {
		skipped[s] = true
	}
	if !skipped[fakeTaggedSource] || !skipped["lrclib"] || len(skipped) != 2 {
		t.Errorf("各自被拦下的记在各自归到的源头上: %v", round.skippedSources())
	}

	// 带标签打不属于任何源的主机:照歌词源的请求处理(429 暂停这个主机的后台,不进端点限流窗口);不带标签的进端点限流窗口。
	limited := statusClient(http.StatusTooManyRequests, http.Header{"Retry-After": {"60"}})
	const unowned = "https://api.example.org/v1/thing"
	if err := get(limited, tagged, unowned); err != nil {
		t.Fatal(err)
	}
	key := guardEndpointKey(mustReq(t, tagged, http.MethodGet, unowned).URL)
	if _, blocked := g.endpointBlockedUntil(key); blocked {
		t.Error("带标签的请求吃到 429 不进端点限流窗口")
	}
	if _, paused := g.backgroundPausedUntil("api.example.org"); !paused {
		t.Error("带标签的请求吃到 429 该暂停这个主机的后台请求")
	}
	if !rateLimitAnswerPaused(withOutboundSource(mustReq(t, tagged, http.MethodGet, unowned)), http.StatusTooManyRequests) ||
		rateLimitAnswerPaused(withOutboundSource(mustReq(t, context.Background(), http.MethodGet, unowned)), http.StatusTooManyRequests) {
		t.Error("限速应答算不算「收到的一方会停手」:带标签的算,不属于任何源的不算")
	}
	const other = "https://api.example.net/v1/thing"
	if err := get(limited, context.Background(), other); err != nil {
		t.Fatal(err)
	}
	if _, blocked := g.endpointBlockedUntil(guardEndpointKey(mustReq(t, bgCtx, http.MethodGet, other).URL)); !blocked {
		t.Error("不属于任何源的主机吃到 429 该进端点限流窗口")
	}
	if _, paused := g.backgroundPausedUntil("api.example.net"); paused {
		t.Error("不属于任何源的主机不走歌词源的后台暂停")
	}
}

// 等到别人那次合并结果的请求,「这一轮连上过」同样记在它归到的源头上;5xx、429 不算连上。
func TestCoalescedFollowerReachMarksAttributedSource(t *testing.T) {
	roundCtx, round := withLyricSourceRound(context.Background())
	const lrclibGet = "https://lrclib.net/api/get"
	noteCoalescedReached(mustReq(t, withOutboundSourceTag(roundCtx, fakeTaggedSource), http.MethodGet, lrclibGet), http.StatusServiceUnavailable)
	noteCoalescedReached(mustReq(t, roundCtx, http.MethodGet, lrclibGet), http.StatusTooManyRequests)
	if round.reachedAny() {
		t.Fatal("5xx、429 不算连上")
	}
	noteCoalescedReached(mustReq(t, withOutboundSourceTag(roundCtx, fakeTaggedSource), http.MethodGet, lrclibGet), http.StatusOK)
	if !round.reachedSource(fakeTaggedSource) || round.reachedSource("lrclib") {
		t.Errorf("带标签的记在标签那个源头上: 自己 %v、lrclib %v", round.reachedSource(fakeTaggedSource), round.reachedSource("lrclib"))
	}
	noteCoalescedReached(withOutboundSource(mustReq(t, roundCtx, http.MethodGet, "https://API.Deezer.com:443/search")), http.StatusNotFound)
	if !round.reachedSource("deezer") {
		t.Error("不带标签的记在主机的主人头上(404 也是连上了)")
	}
	noteCoalescedReached(mustReq(t, roundCtx, http.MethodGet, "https://api.example.org/x"), http.StatusOK)
	if round.reachedSource("") {
		t.Error("不归任何歌词源的请求不记")
	}
}

// 请求合并的条件:归到某个歌词源的 GET 才合并;归到不同源的同一个请求不并成一个。
func TestHTTPCoalesceKeyFollowsAttributedSource(t *testing.T) {
	if httpCoalesceHostOK != nil {
		t.Fatal("前提:没有用例留下按主机判的替身")
	}
	bg := context.Background()
	key := func(ctx context.Context, method, raw string) (string, bool) {
		t.Helper()
		return httpCoalesceKey(withOutboundSource(mustReq(t, ctx, method, raw)))
	}
	const lrclibGet, unowned = "https://lrclib.net/api/get?id=1", "https://api.example.org/x"
	plain, ok := key(bg, http.MethodGet, lrclibGet)
	if !ok {
		t.Fatal("发往歌词源主机的 GET 该进合并")
	}
	if _, ok := key(bg, http.MethodGet, unowned); ok {
		t.Error("不归任何歌词源的请求不合并")
	}
	if _, ok := key(bg, http.MethodPost, lrclibGet); ok {
		t.Error("只合并 GET")
	}
	if again, _ := key(bg, http.MethodGet, lrclibGet); again != plain {
		t.Error("同一个源的同一个请求该是同一个键")
	}
	tagged := withOutboundSourceTag(bg, fakeTaggedSource)
	mine, ok := key(tagged, http.MethodGet, lrclibGet)
	if !ok || mine == plain {
		t.Errorf("带标签的同一个请求该进合并、但不跟主机主人的并成一个: ok=%v 同键=%v", ok, mine == plain)
	}
	if other, _ := key(withOutboundSourceTag(bg, "tagged:other"), http.MethodGet, lrclibGet); other == mine {
		t.Error("两个源各自带标签的同一个请求不并成一个")
	}
	if again, _ := key(tagged, http.MethodGet, lrclibGet); again != mine {
		t.Error("同一个标签的同一个请求该是同一个键")
	}
	if _, ok := key(tagged, http.MethodGet, unowned); !ok {
		t.Error("带标签的请求打不属于任何源的主机,也进合并")
	}
	// 没经入口的请求(ctx 上没挂结果)按主机现归,键跟入口算过的一样。
	if direct, ok := httpCoalesceKey(mustReq(t, bg, http.MethodGet, lrclibGet)); !ok || direct != plain {
		t.Error("没挂结果的请求按主机现归,键该跟入口算过的相同")
	}
}

// 代理回退谁能走:归到的源登记了 ProxyFallback 才走。带标签的看标签那个源;跟随重定向跳到别的主机、又没标签的那一跳按它
// 自己的主机归。
func TestProxyFallbackFollowsAttributedSource(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	proxySrv, hits, lastHost := fakeForwardProxy(t)
	proxyURL, _ := neturl.Parse(proxySrv.URL)
	savedProxy := fallbackProxyURL
	fallbackProxyURL = func() *neturl.URL { return proxyURL }
	savedTransport := sharedLyricSourceTransport()
	var directDials atomic.Int32
	setSharedLyricSourceTransport(&http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
		directDials.Add(1)
		return nil, errors.New("connect: connection refused")
	}})
	clearFallbacks := func() {
		lyricSourceFallbacks.Range(func(k, _ any) bool { lyricSourceFallbacks.Delete(k); return true })
	}
	clearFallbacks()
	t.Cleanup(func() {
		fallbackProxyURL = savedProxy
		setSharedLyricSourceTransport(savedTransport)
		clearFallbacks()
	})
	get := func(ctx context.Context, rawURL string) (string, error) {
		t.Helper()
		resp, err := lyricHTTPClient(2 * time.Second).Do(mustReq(t, ctx, http.MethodGet, rawURL))
		if err != nil {
			return "", err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return string(b), nil
	}
	bg := context.Background()
	expectDirectOnly := func(what string, ctx context.Context, rawURL string) {
		t.Helper()
		before, dials := hits.Load(), directDials.Load()
		if _, err := get(ctx, rawURL); err == nil {
			t.Errorf("%s:直连不通该失败", what)
		}
		if hits.Load() != before || directDials.Load() == dials {
			t.Errorf("%s:只该直连、不走代理(代理 %d → %d,直连 %d → %d)", what, before, hits.Load(), dials, directDials.Load())
		}
	}
	expectViaProxy := func(what string, ctx context.Context, rawURL, host string) {
		t.Helper()
		before := hits.Load()
		if body, err := get(ctx, rawURL); err != nil || body != "via-proxy" {
			t.Errorf("%s:直连不通该改走代理, body=%q err=%v", what, body, err)
		}
		if hits.Load() != before+1 || lastHost.Load() != host {
			t.Errorf("%s:代理 %d → %d 次,主机 %v", what, before, hits.Load(), lastHost.Load())
		}
	}
	tagged := withOutboundSourceTag(bg, fakeTaggedSource)
	expectDirectOnly("带着没登记代理回退的源的标签打 lrclib.net", tagged, "http://lrclib.net/api/get?id=1")
	expectDirectOnly("带着国内源的标签打 lrclib.net", withOutboundSourceTag(bg, "netease"), "http://lrclib.net/api/get?id=2")
	expectViaProxy("不带标签打 lrclib.net", bg, "http://lrclib.net/api/get?id=3", "lrclib.net")
	expectViaProxy("带着登记了代理回退的源的标签打不认识的主机", withOutboundSourceTag(bg, "deezer"), "http://plugin-host.example/x", "plugin-host.example")
	expectDirectOnly("不带标签打不认识的主机", bg, "http://unknown-host.example/x")

	// 入口为 api.deezer.com 算好了归源的请求,跟随重定向跳到别的主机:那一跳按它自己的主机归。
	entry := withOutboundSource(mustReq(t, bg, http.MethodGet, "http://api.deezer.com/search"))
	if got := outboundSourceFor(entry.Context(), "api.deezer.com"); got != "deezer" {
		t.Fatalf("前提:入口归到 deezer,得到 %q", got)
	}
	expectDirectOnly("入口归到 deezer、跳到不认识的主机的那一跳", entry.Context(), "http://redirect-target.example/x")
	expectDirectOnly("入口归到 deezer、跳到国内源主机的那一跳", entry.Context(), "http://music.163.com/api/x")
	expectViaProxy("入口归到 deezer、跳到另一个海外源主机的那一跳", entry.Context(), "http://apis.naver.com/vibeWeb/x", "apis.naver.com")
}
