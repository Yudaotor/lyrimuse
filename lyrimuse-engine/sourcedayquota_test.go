package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// resetSourceDayQuotaForTest:每日额度换成空的、不存盘,测完换回去。
func resetSourceDayQuotaForTest(t *testing.T) {
	t.Helper()
	sourceDayQuotaMu.Lock()
	saved, savedPath, savedMtime := sourceDayQuota, sourceDayQuotaPath, sourceDayQuotaMtime
	sourceDayQuota, sourceDayQuotaPath, sourceDayQuotaMtime = map[string]sourceDayQuotaRecord{}, "", time.Time{}
	sourceDayQuotaMu.Unlock()
	t.Cleanup(func() {
		sourceDayQuotaMu.Lock()
		sourceDayQuota, sourceDayQuotaPath, sourceDayQuotaMtime = saved, savedPath, savedMtime
		sourceDayQuotaMu.Unlock()
	})
}

func dayQuotaHeader(kv ...string) http.Header {
	h := http.Header{}
	for i := 0; i+1 < len(kv); i += 2 {
		h.Set(kv[i], kv[i+1])
	}
	return h
}

// 读应答头:剩得多不限;剩到保留数以下只给前台;报剩 0 停到重置时刻;429 只说要等很久也停;短的 Retry-After 不算用完;别的源不记。
func TestSourceDayQuotaFromHeaders(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	now := time.Date(2026, 11, 18, 5, 56, 3, 0, time.UTC)
	noteSourceDayQuota(lyricSourceMegalobiz, 200, dayQuotaHeader("X-RateLimit-Remaining-Day", "374", "X-RateLimit-Reset-Day", "65037"), now)
	if sourceDayQuotaLow(lyricSourceMegalobiz, now) {
		t.Errorf("剩 374 不算少")
	}
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); paused {
		t.Errorf("没用完不停")
	}
	noteSourceDayQuota(lyricSourceMegalobiz, 200, dayQuotaHeader("X-RateLimit-Remaining-Day", strconv.Itoa(megalobizDayQuotaReserve), "X-RateLimit-Reset-Day", "65000"), now)
	if !sourceDayQuotaLow(lyricSourceMegalobiz, now) {
		t.Errorf("剩到保留数只给前台")
	}
	if sourceDayQuotaLow(lyricSourceMegalobiz, now.Add(19*time.Hour)) {
		t.Errorf("过了重置时刻就不算少了")
	}
	noteSourceDayQuota(lyricSourceMegalobiz, 429, dayQuotaHeader("X-RateLimit-Remaining-Day", "0", "X-RateLimit-Reset-Day", "65037", "Retry-After", "65037"), now)
	left, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now)
	if !paused || left != 65037*time.Second {
		t.Fatalf("用完停到重置时刻(UTC 零点): %v %v", left, paused)
	}
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now.Add(65037*time.Second)); paused {
		t.Errorf("到了重置时刻就不停")
	}

	resetSourceDayQuotaForTest(t)
	noteSourceDayQuota(lyricSourceMegalobiz, 429, dayQuotaHeader("Retry-After", "30"), now)
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); paused {
		t.Errorf("短的 Retry-After 是每分钟的限流,归熔断管,不按用完停")
	}
	noteSourceDayQuota(lyricSourceMegalobiz, 429, dayQuotaHeader("Retry-After", "40000"), now)
	if left, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); !paused || left != 40000*time.Second {
		t.Errorf("没报剩几次、只说要等很久:按它说的停,不截到 5 分钟: %v %v", left, paused)
	}
	noteSourceDayQuota(lyricSourceMegalobiz, 429, dayQuotaHeader("Retry-After", "99999999"), now)
	if left, _ := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); left > sourceDayQuotaMaxPause {
		t.Errorf("离谱的头封顶: %v", left)
	}

	resetSourceDayQuotaForTest(t)
	noteSourceDayQuota(lyricSourceMegalobiz, 200, dayQuotaHeader("X-RateLimit-Remaining-Day", "0"), now)
	if left, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); !paused || !now.Add(left).Equal(nextUTCMidnight(now)) {
		t.Errorf("没报重置秒数时停到下一个 UTC 零点: %v", left)
	}
	noteSourceDayQuota("lrclib", 200, dayQuotaHeader("X-RateLimit-Remaining-Day", "0"), now)
	sourceDayQuotaMu.Lock()
	_, recorded := sourceDayQuota["lrclib"]
	sourceDayQuotaMu.Unlock()
	if recorded {
		t.Errorf("别的源不记")
	}
}

// 落盘:重启后还记得停到几点;别的进程(手动搜索的子进程)记下的,这边判之前看到文件变了就读进来。
func TestSourceDayQuotaPersistsAndShared(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	path := filepath.Join(t.TempDir(), sourceDayQuotaFileName)
	now := time.Now()
	useSourceDayQuotaFile(path)
	noteSourceDayQuota(lyricSourceMegalobiz, 429, dayQuotaHeader("X-RateLimit-Remaining-Day", "0", "X-RateLimit-Reset-Day", "3600"), now)

	resetSourceDayQuotaForTest(t)
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); paused {
		t.Fatalf("前提:换成空的")
	}
	useSourceDayQuotaFile(path)
	if left, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); !paused || left < 59*time.Minute {
		t.Errorf("重启后还记得停到几点: %v %v", left, paused)
	}

	resetSourceDayQuotaForTest(t)
	other := filepath.Join(t.TempDir(), sourceDayQuotaFileName)
	useSourceDayQuotaFile(other)
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); paused {
		t.Fatalf("前提:新文件里什么都没有")
	}
	raw := `{"megalobiz":{"remaining":0,"reset_at":` + strconv.FormatInt(now.Add(time.Hour).Unix(), 10) + `,"seen_at":` +
		strconv.FormatInt(now.Unix(), 10) + `,"paused_until":` + strconv.FormatInt(now.Add(time.Hour).Unix(), 10) + `}}`
	time.Sleep(10 * time.Millisecond) // 让修改时刻跟读的那一刻分得开
	if err := os.WriteFile(other, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, now); !paused {
		t.Errorf("别的进程记下的用完,这边也停")
	}
}

// 用完之后:前台也不问(熔断器按冷却跳过,原因 budget,条目的待补搜名单不收它);剩得少时后台不问、前台照问。
func TestSourceDayQuotaGates(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	g, _ := newTestGuard(hostRate{perSec: 1000, burst: 1000})
	const url = "https://api.megalobiz.com/api/public/v1/search?title=x"
	now := time.Now()
	noteSourceDayQuota(lyricSourceMegalobiz, 200, dayQuotaHeader("X-RateLimit-Remaining-Day", "10", "X-RateLimit-Reset-Day", "3600"), now)
	bgCtx, round := withLyricSourceRound(withBackgroundOutbound(withOnDemandLyricRound(context.Background())))
	if err := g.admit(mustReq(t, bgCtx, "GET", url)); !errors.Is(err, errHostGuarded) {
		t.Errorf("剩得少时后台(待播队列)不问: %v", err)
	}
	if got := round.statsSkips()[lyricSourceMegalobiz]; got != lyricSourceSkipReasonBudget {
		t.Errorf("跳过原因 = %q", got)
	}
	fgCtx, _ := withLyricSourceRound(withOnDemandLyricRound(context.Background()))
	if err := g.admit(mustReq(t, fgCtx, "GET", url)); err != nil {
		t.Errorf("剩得少时前台照问: %v", err)
	}

	b := newLyricSourceBreaker(time.Now)
	noteSourceDayQuota(lyricSourceMegalobiz, 429, dayQuotaHeader("X-RateLimit-Remaining-Day", "0", "X-RateLimit-Reset-Day", "3600"), now)
	if plan := b.planRound([]string{lyricSourceMegalobiz, "lrclib"}); plan[lyricSourceMegalobiz] < 59*time.Minute || plan["lrclib"] != 0 {
		t.Errorf("用完了这一轮跳过它,别的源照问: %v", plan)
	}
	if got := b.cooldownReason(lyricSourceMegalobiz); got != lyricSourceSkipReasonBudget {
		t.Errorf("跳过原因 = %q", got)
	}
	savedBreaker := sharedLyricSourceBreaker()
	setSharedLyricSourceBreaker(b)
	t.Cleanup(func() { setSharedLyricSourceBreaker(savedBreaker) })
	if got := lyricSourcesSkippedForRetry([]string{lyricSourceMegalobiz}); len(got) != 0 {
		t.Errorf("停到明天的不进待补搜名单(不然没词的歌每 30 秒全源重搜): %v", got)
	}
	if err := g.admit(mustReq(t, context.Background(), "GET", url)); !errors.Is(err, errHostGuarded) {
		t.Errorf("不在一轮里的前台请求(手动搜索的子进程)也不发: %v", err)
	}
}

// 整条路径:Megalobiz 回 429 且报用完,之后同一个进程里不再发请求,不是每 5 分钟撞一次。
func TestMegalobizStopsAfterDailyQuotaUsedUp(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	resetMegalobizCacheForTest(t)
	var mu sync.Mutex
	hits := 0
	withKugouFakeReq(t, nil)
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 共享传输层把所有主机都导到这里;只数发给 Megalobiz 的,别的源的请求回 404。
		if host, _, _ := strings.Cut(r.Host, ":"); host != "api.megalobiz.com" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		mu.Lock()
		hits++
		mu.Unlock()
		w.Header().Set("X-RateLimit-Remaining-Day", "0")
		w.Header().Set("X-RateLimit-Reset-Day", "40000")
		w.Header().Set("Retry-After", "40000")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":"rate_limited"}`))
	}))
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	setSharedLyricSourceTransport(&http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	})
	megalobizSearch(context.Background(), "Song One", "", 200)
	if _, paused := sourceDayQuotaPausedFor(lyricSourceMegalobiz, time.Now()); !paused {
		t.Fatalf("429 报用完后停到重置")
	}
	for _, title := range []string{"Song Two", "Song Three"} {
		if _, err := megalobizSearch(context.Background(), title, "", 200); !errors.Is(err, errHostGuarded) {
			t.Errorf("停着的时候不发: %v", err)
		}
	}
	if hits != 1 {
		t.Errorf("只撞了一次: %d", hits)
	}
}

// 小时额度:两个进程(常驻引擎和手动搜索的子进程)记在同一份文件里,谁发的都算,写的时候不互相盖掉。
func TestSourceBudgetSharedAcrossProcesses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "budget.json")
	daemon, c := newBudgetGuard(10)
	daemon.useSourceBudgetFile(path)
	child, cc := newBudgetGuard(10)
	child.useSourceBudgetFile(path)
	// 两个进程的时钟各走各的(同一毫秒两边各记一条的情形另算,见 mergeSourceBudgetFile)。
	daemon.noteSourceHit("deezer")
	cc.t = c.t.Add(time.Second)
	time.Sleep(10 * time.Millisecond)
	child.noteSourceHit("deezer")
	child.noteSourceHit("deezer")
	c.t = c.t.Add(2 * time.Second)
	time.Sleep(10 * time.Millisecond)
	daemon.noteSourceHit("deezer")
	restarted, rc := newBudgetGuard(10)
	rc.t = c.t
	restarted.useSourceBudgetFile(path)
	if left, _ := restarted.sourceBudgetLeft("deezer"); left != 6 {
		t.Errorf("文件里四个都在,谁也没盖掉谁: 还剩 %d,期望 6", left)
	}
	time.Sleep(10 * time.Millisecond)
	cc.t = c.t.Add(time.Second)
	child.noteSourceHit("deezer")
	c.t = cc.t
	if left, _ := daemon.sourceBudgetLeft("deezer"); left != 5 {
		t.Errorf("常驻那边看得到子进程发的: 还剩 %d,期望 5", left)
	}
}

// 两个进程记的每日额度并起来:每个源取更晚看到的那份,停的时刻取更晚的(新看到的那份没停时不撤掉别处记下的停)。
func TestMergedSourceDayQuota(t *testing.T) {
	older := sourceDayQuotaRecord{Remaining: 0, ResetAt: 200, SeenAt: 100, PausedUntil: 200}
	newer := sourceDayQuotaRecord{Remaining: 5, ResetAt: 200, SeenAt: 150}
	got := mergedSourceDayQuota(newer, older)
	if got.Remaining != 5 || got.SeenAt != 150 || got.PausedUntil != 200 {
		t.Errorf("取更晚看到的剩余、留着停的时刻: %+v", got)
	}
	if got := mergedSourceDayQuota(older, newer); got.Remaining != 5 || got.PausedUntil != 200 {
		t.Errorf("两个方向一样: %+v", got)
	}
}

// 会问歌词源的子命令跟常驻引擎共用额度记账;search-lyrics 在 main() 读额度文件之前就分派出去了,所以要自己接。
func TestLyricSourceQuotaWiredIntoSubcommands(t *testing.T) {
	for file, fn := range map[string]string{
		"searchcli.go":           "func runSearchLyricsCLI(",
		"testlyricsourcescli.go": "func runTestLyricSourcesCLI(",
		"lyricsfillsweep.go":     "func setLyricsFillPaths(",
	} {
		raw, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		src := string(raw)
		start := strings.Index(src, fn)
		if start < 0 {
			t.Fatalf("%s 里找不到 %s", file, fn)
		}
		body := src[start:]
		if end := strings.Index(body, "\n}\n"); end >= 0 {
			body = body[:end]
		}
		if !containsCode(body, "useSharedLyricSourceQuota()") {
			t.Errorf("%s 的 %s 没接共用的额度记账", file, fn)
		}
	}
}

// 设置页「测试」:常驻引擎记下用完每日额度后,子进程读同一份状态文件,当场报额度用完和恢复时刻,一个请求都不发。
func TestTestLyricSourcesReportsDailyQuotaPause(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	dir := useCLIConfigDir(t, map[string]string{})
	f := withKugouFakeReq(t, func(*http.Request, string) (int, string) { return http.StatusTooManyRequests, "" })
	resumeAt := time.Now().Add(3 * time.Hour).Unix()
	state, _ := json.Marshal(map[string]sourceDayQuotaRecord{lyricSourceMegalobiz: {
		Remaining: 0, ResetAt: resumeAt, SeenAt: time.Now().Add(-time.Minute).Unix(), PausedUntil: resumeAt,
	}})
	if err := os.WriteFile(filepath.Join(dir, sourceDayQuotaFileName), state, 0o600); err != nil {
		t.Fatal(err)
	}

	out := captureStdout(t, func() { runTestLyricSourcesCLI([]string{"-source", lyricSourceMegalobiz}) })

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 1 {
		t.Fatalf("只报 Megalobiz 一行: %q", out)
	}
	var got lyricSourceTestResult
	if err := json.Unmarshal([]byte(lines[0]), &got); err != nil {
		t.Fatalf("不是 JSON: %q", lines[0])
	}
	if got.Source != lyricSourceMegalobiz || got.Status != "warn" ||
		got.ReasonCode != lyricTestReasonDailyQuotaExhausted || got.ResumeAt != resumeAt {
		t.Errorf("额度用完时报额度原因和恢复时刻: %+v", got)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	// 共享传输层把所有主机都导到假服务器;只看发给 Megalobiz 的。
	for target := range f.hits {
		if strings.HasPrefix(target, "https://api.megalobiz.com/") {
			t.Errorf("停着的时候不发请求: %v", f.hits)
		}
	}
}

// 「搜索候选歌词」:额度停着的 Megalobiz 没给出候选时,失败原因是额度用完、带恢复时刻;给过候选或用户关了就不报(09 章决策 387)。
func TestSearchLyricsReportsDailyQuotaPause(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	dir := useCLIConfigDir(t, map[string]string{})
	now := time.Now()
	resumeAt := now.Add(3 * time.Hour).Unix()
	state, _ := json.Marshal(map[string]sourceDayQuotaRecord{lyricSourceMegalobiz: {
		Remaining: 0, ResetAt: resumeAt, SeenAt: now.Add(-time.Minute).Unix(), PausedUntil: resumeAt,
	}})
	if err := os.WriteFile(filepath.Join(dir, sourceDayQuotaFileName), state, 0o600); err != nil {
		t.Fatal(err)
	}
	useSourceDayQuotaFile(filepath.Join(dir, sourceDayQuotaFileName))
	on := func(string) bool { return true }
	got := lyricSourceResumeAts(nil, on, now)
	if got[lyricSourceMegalobiz] != resumeAt {
		t.Errorf("停着的源带恢复时刻: %v", got)
	}
	if r := lyricSourceFailureReasons(nil); r[lyricSourceMegalobiz] != lyricTestReasonDailyQuotaExhausted {
		t.Errorf("原因是额度用完: %v", r)
	}
	answered := []scoredLyricCandidateResult{{Source: lyricSourceMegalobiz, Score: 300}}
	if got := lyricSourceResumeAts(answered, on, now); len(got) != 0 {
		t.Errorf("给过候选的不报: %v", got)
	}
	if got := lyricSourceResumeAts(nil, func(s string) bool { return s != lyricSourceMegalobiz }, now); len(got) != 0 {
		t.Errorf("关掉的源不报: %v", got)
	}
	if got := lyricSourceResumeAts(nil, on, now.Add(4*time.Hour)); len(got) != 0 {
		t.Errorf("过了恢复时刻不报: %v", got)
	}
}
