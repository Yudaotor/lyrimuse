package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ---- 出站读请求的本地闸:接口熔断、按主机限速、429 窗口、歌词源冷却 ----
//
// doHTTPTracked 真正发请求之前先过 hostGuardShared.admit,依次四道:
//
//  0. 接口熔断:同一个端点(键同下)连续 endpointTripAfter 次回 5xx,或调用方从响应体认出拒绝
//     (reportEndpointRejected),就停用 endpointCooldownSchedule 一档;到期放请求试探,再失败升
//     一档,拿到一次 5xx 以外的响应全部清零。所有主机都管,一轮歌词搜索之内也管。
//     sourcebreaker.go 按**源**计数,同源另一个端点成功一次就清零,一个端点单独挂掉(其余端点
//     正常)时它永远跳不了闸,这一道补的就是这个。只数 5xx 和响应体拒绝,不数传输层失败:
//     连不上是网络或整个源的事,归 sourcebreaker 和 roundLooksNetworkDown。被这一道拦下时**不**
//     记进 lyricSourceRound.skipped —— 源的其它端点照常在查,各源自己有备用端点的退路。
//  1. 端点限流窗口:非歌词源主机的某个端点(主机 + 归一化路径,同审计汇总的分组键)回了 429,
//     或调用方从响应体认出限流(reportEndpointRateLimited),在 Retry-After 窗口内不再发往这个
//     端点(没给默认 1 分钟、封顶 5 分钟,同 parseLyricSourceRetryAfter)。拿到 2xx/3xx/404 当场
//     解除。歌词源主机的 429 由 sourcebreaker.go 按源管,这里不重复记。
//  2. 歌词源冷却:ctx 里**没有** lyricSourceRound(不在一轮歌词搜索里)时,访问正在冷却的歌词源
//     主机直接不发。一轮之内由 planRound 决定 —— 那边有「启用的源全部冷却时照常跑」的护栏,
//     这里不能越过它。
//  3. 按主机限速:每个主机一个令牌桶(hostRateFor)。桶空了排队;要等的时间超过 hostGuardMaxWait
//     或请求自己的截止时间,就不发。批量路径(补空、全量扫库、专辑 / 待播预取)的 ctx 带
//     withBackgroundOutbound 标记:后台请求只在桶里还剩超过 reserve 个令牌时才取,不预支、不排进
//     前台的队列,所以正在播的那首永远不会排在批量请求后面;后台最多等 hostGuardBackgroundMaxWait。
//
// 只管 GET / HEAD,外加 guardReadOnlyPOST 认出的只读 POST(QQ 客户端网关)。上送类请求
// (scrobble、ListenBrainz、中继、推送、Google 翻译的 POST 表单)各自有退避,而且本地拦下一条
// 上送,调用方分不清「没发出去」和「发出去没回执」,有的会因此把这条收听记成永不自动重试。
//
// 本地拦下的请求返回 errHostGuarded:不计入 networkAttemptCount、不喂熔断、不进审计汇总 —— 它
// 没发出去,既不是网络状态也不是对方的状态。一轮歌词搜索里被拦下的源记进 lyricSourceRound 的
// skipped,跟熔断跳过走同一套后续(补空间隔缩短、rescoreDecidable 不降级)。
// 回环地址(单测的 httptest 服务器)不经过这里。

var errHostGuarded = errors.New("held back by local outbound guard")

// hostRate 是一个主机的令牌桶参数:每秒补充 perSec 个,最多攒 burst 个。
type hostRate struct {
	perSec float64
	burst  float64
	// reserve:给前台留的令牌数,后台请求取完之后桶里至少还剩这么多。
	reserve float64
}

// 默认档要高于正常播放时各主机的请求速率,只削全量扫库 / 批量补全的尖峰。
// 数字的依据见 docs/features/15「对外请求的本地出站闸」。
var hostRateDefault = hostRate{perSec: 3, burst: 10, reserve: 3}

// hostRateFor 按主机给令牌桶参数。改数字之前先按日志里的 api call summary 重新量一遍
// (docs/features/15 有分档统计的做法)。iTunes 的 search 和 lookup 共用一个主机的额度;
// Last.fm 与 App 侧 LastfmRateLimiter(4 次/秒)共用出口 IP,两边加起来别超过它按 IP 的限速。
func hostRateFor(host string) hostRate {
	switch host {
	case "itunes.apple.com":
		return hostRate{perSec: 40.0 / 60, burst: 10, reserve: 3}
	case "ws.audioscrobbler.com":
		return hostRate{perSec: 1, burst: 5, reserve: 2}
	}
	return hostRateDefault
}

// hostGuardMaxWait:排队最多等这么久,再久就不发。请求自己的截止时间更早时按截止时间。
const hostGuardMaxWait = 10 * time.Second

// hostGuardBackgroundMaxWait:后台请求最多等这么久。没人在等它,可以比前台耐心,但仍受请求自己的
// 截止时间约束(一轮歌词搜索 20 秒)。
const hostGuardBackgroundMaxWait = 30 * time.Second

type backgroundOutboundKey struct{}

// withBackgroundOutbound 把 ctx 标成批量后台请求,见文件头第 3 道。
func withBackgroundOutbound(ctx context.Context) context.Context {
	return context.WithValue(ctx, backgroundOutboundKey{}, true)
}

func isBackgroundOutbound(ctx context.Context) bool {
	v, _ := ctx.Value(backgroundOutboundKey{}).(bool)
	return v
}

// hostGuardHeldLogEvery:同一个主机被拦下时多久最多记一行日志。
const hostGuardHeldLogEvery = time.Minute

type hostBucket struct {
	tokens float64
	last   time.Time
}

type hostGuard struct {
	mu      sync.Mutex
	now     func() time.Time
	rateFor func(host string) hostRate
	maxWait time.Duration
	// backgroundMaxWait:后台请求的等待上限,见 hostGuardBackgroundMaxWait。
	backgroundMaxWait time.Duration
	buckets           map[string]*hostBucket
	// blocked:端点键 到 窗口截止时刻。
	blocked map[string]time.Time
	// heldLogged:主机 到 上一次记「被拦下」日志的时刻。
	heldLogged map[string]time.Time
	// health:端点键 到 接口熔断状态。
	health map[string]*endpointHealth
}

// endpointHealth 是一个端点的熔断状态。两种失败分开计:fails 数 5xx,被这个端点的任何非 5xx
// 响应清零;rejects 数响应体拒绝,只被调用方的 reportEndpointAccepted 清零 —— 拒绝码是装在 200
// 里回来的,出站闸看到 200 那一刻还不知道响应体是拒绝,要是也清 rejects,它永远攒不满。
// 两个计数在跳闸后都不清零:到期后放进来的第一个请求再失败就直接升一档。
type endpointHealth struct {
	fails   int
	rejects int
	trips   int
	until   time.Time
}

const endpointTripAfter = 5

// endpointCooldownSchedule:第 N 次跳闸停用多久,超出表长按最后一档。
var endpointCooldownSchedule = []time.Duration{time.Minute, 5 * time.Minute, 15 * time.Minute, 30 * time.Minute}

func newHostGuard(now func() time.Time) *hostGuard {
	return &hostGuard{
		now:               now,
		rateFor:           hostRateFor,
		maxWait:           hostGuardMaxWait,
		backgroundMaxWait: hostGuardBackgroundMaxWait,
		buckets:           map[string]*hostBucket{},
		blocked:           map[string]time.Time{},
		heldLogged:        map[string]time.Time{},
		health:            map[string]*endpointHealth{},
	}
}

var hostGuardShared = newHostGuard(time.Now)

// guardHost 取请求的主机名(小写、去端口)。
func guardHost(u *url.URL) string {
	return strings.ToLower(u.Hostname())
}

// guardEndpointKey 是限流窗口的键:主机 + 归一化路径。同一主机上不同端点分开记 —— iTunes 的
// /search 被限流时 /lookup 常常还是好的。
func guardEndpointKey(u *url.URL) string {
	return guardHost(u) + normalizeAuditPath(u.Path)
}

func guardIsLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func guardApplies(req *http.Request) bool {
	if req.Method != http.MethodGet && req.Method != http.MethodHead && !guardReadOnlyPOST(req) {
		return false
	}
	return !guardIsLoopback(guardHost(req.URL))
}

// guardReadOnlyPOST:用 POST 发的只读查询。QQ 客户端网关(musicu.fcg)的搜索 / 详情 / 歌词全是
// POST,它挂着的主机要能被接口熔断跳过(qqfallback.go 的备用链靠这个不白打)。
func guardReadOnlyPOST(req *http.Request) bool {
	return req.Method == http.MethodPost &&
		req.URL.Path == "/cgi-bin/musicu.fcg" &&
		strings.HasSuffix(guardHost(req.URL), ".y.qq.com")
}

// admit 决定这个请求现在能不能发;不能发返回 errHostGuarded(或排队时 ctx 的错误)。
func (g *hostGuard) admit(req *http.Request) error {
	if !guardApplies(req) {
		return nil
	}
	ctx := req.Context()
	host := guardHost(req.URL)
	source := lyricSourceForHost(host)
	round := lyricSourceRoundFrom(ctx)
	key := guardEndpointKey(req.URL)

	if until, open := g.endpointOpenUntil(key); open {
		g.logHeld(host, "endpoint "+key+" failing, circuit open until "+until.Format("15:04:05"))
		return errHostGuarded
	}
	if sharedCooldownHosts[host] {
		if until := sharedCooldownUntil(key, time.Now()); !until.IsZero() {
			g.logHeld(host, "shared cooldown for "+key+" until "+until.Format("15:04:05"))
			return errHostGuarded
		}
	}
	if source == "" {
		if until, ok := g.endpointBlockedUntil(key); ok {
			g.logHeld(host, "rate-limited by the server until "+until.Format("15:04:05"))
			return errHostGuarded
		}
	} else if round == nil {
		if left, cooling := lyricSourceBreakerShared.coolingDown(source); cooling {
			g.logHeld(host, "lyric source "+source+" cooling down for another "+left.Round(time.Second).String())
			return errHostGuarded
		}
	}

	if err := g.acquire(ctx, host); err != nil {
		if errors.Is(err, errHostGuarded) {
			g.logHeld(host, "local rate limit queue is full")
			if source != "" && round != nil {
				round.markSkipped(source)
			}
		}
		return err
	}
	return nil
}

func (g *hostGuard) endpointBlockedUntil(key string) (time.Time, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	until, ok := g.blocked[key]
	if !ok {
		return time.Time{}, false
	}
	if !g.now().Before(until) {
		delete(g.blocked, key)
		return time.Time{}, false
	}
	return until, true
}

// reserve 从主机的桶里预订一个令牌,返回要等多久。等待会超过 maxWait 或 deadline 时不预订、
// ok=false。桶可以透支成负数:那表示前面已经排了几个在等。
// bucketLocked 取主机的桶并按流逝时间补令牌。调用方持有 g.mu。
func (g *hostGuard) bucketLocked(host string, now time.Time) (*hostBucket, hostRate) {
	rate := g.rateFor(host)
	b := g.buckets[host]
	if b == nil {
		b = &hostBucket{tokens: rate.burst, last: now}
		g.buckets[host] = b
	}
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens += elapsed * rate.perSec
		if b.tokens > rate.burst {
			b.tokens = rate.burst
		}
	}
	b.last = now
	return b, rate
}

// tryTakeBackground 给后台请求取一个令牌,取完桶里至少还剩 reserve 个;取不到返回还要等多久
// (等的是桶涨回 reserve+1,期间前台照样可以取)。
func (g *hostGuard) tryTakeBackground(host string) (time.Duration, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	b, rate := g.bucketLocked(host, g.now())
	need := rate.reserve + 1
	if b.tokens >= need {
		b.tokens--
		return 0, true
	}
	return time.Duration((need - b.tokens) / rate.perSec * float64(time.Second)), false
}

func (g *hostGuard) acquireBackground(ctx context.Context, host string) error {
	limitAt := time.Now().Add(g.backgroundMaxWait)
	if deadline, ok := ctx.Deadline(); ok && deadline.Before(limitAt) {
		limitAt = deadline
	}
	for {
		wait, ok := g.tryTakeBackground(host)
		if ok {
			return nil
		}
		if time.Now().Add(wait).After(limitAt) {
			return errHostGuarded
		}
		t := time.NewTimer(wait)
		select {
		case <-t.C:
		case <-ctx.Done():
			t.Stop()
			return ctx.Err()
		}
	}
}

func (g *hostGuard) reserve(host string, deadline time.Time) (wait time.Duration, ok bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	b, rate := g.bucketLocked(host, now)
	if b.tokens >= 1 {
		b.tokens--
		return 0, true
	}
	wait = time.Duration((1 - b.tokens) / rate.perSec * float64(time.Second))
	limit := g.maxWait
	if !deadline.IsZero() {
		if left := deadline.Sub(now); left < limit {
			limit = left
		}
	}
	if wait > limit {
		return wait, false
	}
	b.tokens--
	return wait, true
}

// release 退还一个预订了却没用上的令牌(排队期间 ctx 被取消)。
func (g *hostGuard) release(host string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if b := g.buckets[host]; b != nil {
		b.tokens++
		if burst := g.rateFor(host).burst; b.tokens > burst {
			b.tokens = burst
		}
	}
}

func (g *hostGuard) acquire(ctx context.Context, host string) error {
	if isBackgroundOutbound(ctx) {
		return g.acquireBackground(ctx, host)
	}
	deadline, _ := ctx.Deadline()
	wait, ok := g.reserve(host, deadline)
	if !ok {
		return errHostGuarded
	}
	if wait <= 0 {
		return nil
	}
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		g.release(host)
		return ctx.Err()
	}
}

// observe 按一次真实响应更新端点限流窗口。歌词源主机不在这里记(sourcebreaker.go 管)。
func (g *hostGuard) observe(req *http.Request, status int, retryAfter string) {
	if !guardApplies(req) {
		return
	}
	if status >= 500 {
		g.noteEndpointFailure(guardEndpointKey(req.URL))
	} else {
		g.noteEndpointHealthy(guardEndpointKey(req.URL))
	}
	if lyricSourceForHost(guardHost(req.URL)) != "" {
		return
	}
	switch {
	case status == http.StatusTooManyRequests:
		g.block(guardHost(req.URL), guardEndpointKey(req.URL), parseLyricSourceRetryAfter(retryAfter))
	case status < 400 || status == http.StatusNotFound:
		g.mu.Lock()
		delete(g.blocked, guardEndpointKey(req.URL))
		g.mu.Unlock()
	}
}

// block 把端点窗口延到 now+d;已经在更晚的窗口里就不缩短。共享名单里的主机顺带写进
// App 也读的共享文件(sharedcooldown.go)。
func (g *hostGuard) block(host, key string, d time.Duration) {
	g.mu.Lock()
	until := g.now().Add(d)
	if cur, ok := g.blocked[key]; ok && !until.After(cur) {
		g.mu.Unlock()
		return
	}
	g.blocked[key] = until
	g.mu.Unlock()
	publishSharedCooldown(host, key, until)
}

func (g *hostGuard) logHeld(host, why string) {
	g.mu.Lock()
	now := g.now()
	last, ok := g.heldLogged[host]
	if ok && now.Sub(last) < hostGuardHeldLogEvery {
		g.mu.Unlock()
		return
	}
	g.heldLogged[host] = now
	g.mu.Unlock()
	log.Printf("outbound guard: holding back requests to %s (%s)", host, why)
}

func (g *hostGuard) endpointOpenUntil(key string) (time.Time, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	h := g.health[key]
	if h == nil || !g.now().Before(h.until) {
		return time.Time{}, false
	}
	return h.until, true
}

func (g *hostGuard) noteEndpointFailure(key string) { g.noteEndpointBad(key, false) }

func (g *hostGuard) noteEndpointBad(key string, rejected bool) {
	g.mu.Lock()
	now := g.now()
	h := g.health[key]
	if h == nil {
		h = &endpointHealth{}
		g.health[key] = h
	}
	if rejected {
		h.rejects++
	} else {
		h.fails++
	}
	consecutive := max(h.fails, h.rejects)
	if consecutive < endpointTripAfter || now.Before(h.until) {
		g.mu.Unlock()
		return
	}
	idx := h.trips
	if idx >= len(endpointCooldownSchedule) {
		idx = len(endpointCooldownSchedule) - 1
	}
	h.trips++
	h.until = now.Add(endpointCooldownSchedule[idx])
	trips, d := h.trips, endpointCooldownSchedule[idx]
	g.mu.Unlock()
	log.Printf("outbound guard: endpoint %s tripped (trip %d, %d consecutive failures), holding for %s", key, trips, consecutive, d)
}

// noteEndpointHealthy:这个端点回了非 5xx(rejected=false)或调用方确认响应体正常(true)。
// 两个计数都归零才算恢复、清掉整个状态。
func (g *hostGuard) noteEndpointHealthy(key string) { g.noteEndpointGood(key, false) }

func (g *hostGuard) noteEndpointGood(key string, bodyAccepted bool) {
	g.mu.Lock()
	h := g.health[key]
	if h == nil {
		g.mu.Unlock()
		return
	}
	if bodyAccepted {
		h.rejects = 0
	} else {
		h.fails = 0
	}
	if h.fails > 0 || h.rejects > 0 {
		g.mu.Unlock()
		return
	}
	delete(g.health, key)
	trips := h.trips
	g.mu.Unlock()
	if trips > 0 {
		log.Printf("outbound guard: endpoint %s recovered after %d trips", key, trips)
	}
}

// reportEndpointRejected:调用方从 200 的响应体里认出了拒绝(风控 / 限流 / 业务错误码),按一次
// 失败记进接口熔断。只在确认过「查无结果时仍回成功码」的接口上调用,别拿它报「没查到」。
func reportEndpointRejected(u *url.URL) {
	if u == nil {
		return
	}
	hostGuardShared.noteEndpointBad(guardEndpointKey(u), true)
}

// reportEndpointAccepted:调用方确认响应体不是拒绝(包括正常的查无结果),清掉拒绝计数。
// 调 reportEndpointRejected 的接口必须在成功路径上配一次这个,否则一次偶发拒绝会一直记着、
// 跟之后隔了很久的拒绝凑成「连续」。
func reportEndpointAccepted(u *url.URL) {
	if u == nil {
		return
	}
	hostGuardShared.noteEndpointGood(guardEndpointKey(u), true)
}

// reportEndpointRateLimited:调用方从响应体里认出了限流(比如 Last.fm 的 200 + error 29),
// 让这个端点按 retryAfter(可空)进入窗口。只对非歌词源主机生效,同 observe。回环地址也照记,
// 反正 admit 不查它们。
func reportEndpointRateLimited(u *url.URL, retryAfter string) {
	if u == nil || lyricSourceForHost(guardHost(u)) != "" {
		return
	}
	hostGuardShared.block(guardHost(u), guardEndpointKey(u), parseLyricSourceRetryAfter(retryAfter))
}
