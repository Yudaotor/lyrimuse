package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 请求确定没离开本机(dial 失败):同一批隔一会儿再发,发成了照常记回执,不进隔离。
func TestRunBackfillResendsBatchThatNeverLeft(t *testing.T) {
	calls := 0
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		calls++
		if calls == 1 {
			return "", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}
		}
		return acceptAll(ts)
	})
	uts := seedListens(3)

	out := runBackfill(context.Background(), env.s, false)

	if n := len(env.requests()); n != 2 {
		t.Fatalf("应重发一次,共发 %d 次", n)
	}
	if out.Accepted != 3 || out.Quarantined != 0 || out.AbortedReason != "" {
		t.Fatalf("重发成功后应全部补上: %+v", out)
	}
	for _, u := range uts {
		if receiptMarks()[u] != "s" {
			t.Errorf("%d 应记回执 s", u)
		}
	}
}

// 一直发不出去:重发用完就停手,全部留在清单里,一条都不隔离。
func TestRunBackfillStopsResendingWhenItNeverLeaves(t *testing.T) {
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		return "", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}
	})
	seedListens(3)

	out := runBackfill(context.Background(), env.s, false)

	if n, want := len(env.requests()), 1+len(backfillResendDelays); n != want {
		t.Fatalf("应发 %d 次(首发 + 重发),发了 %d 次", want, n)
	}
	if out.AbortedReason == "" || out.Quarantined != 0 {
		t.Errorf("应停手且不隔离: %+v", out)
	}
	if len(receiptMarks()) != 0 || pendingCount() != 3 {
		t.Errorf("应全部留在清单里: marks=%v pending=%d", receiptMarks(), pendingCount())
	}
}

// 读超时之类不确定有没有落库的:不重发,照旧整批隔离。
func TestRunBackfillDoesNotResendWhenItMayHaveLanded(t *testing.T) {
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		return "", &net.OpError{Op: "read", Net: "tcp", Err: errors.New("i/o timeout")}
	})
	seedListens(2)

	out := runBackfill(context.Background(), env.s, false)

	if n := len(env.requests()); n != 1 {
		t.Fatalf("可能已经落库的不该重发,发了 %d 次", n)
	}
	if out.Quarantined != 2 {
		t.Errorf("应整批隔离: %+v", out)
	}
}

// reconcileEnv 在 setUpBackfillRun 之上换一个同时认 GET(user.getRecentTracks)的假 Last.fm:onServer 里的时间戳算已经落库。
func reconcileEnv(t *testing.T, onServer map[int64]bool) (*backfillRunEnv, *[]int64) {
	t.Helper()
	env := setUpBackfillRun(t, acceptAll)
	env.s.user = "me"
	var looked []int64
	post := env.s.hc.Transport
	env.s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet {
			return post.RoundTrip(r)
		}
		q := r.URL.Query()
		if q.Get("method") != "user.getrecenttracks" || q.Get("user") != "me" {
			t.Errorf("核对请求不对: %s", r.URL)
		}
		from, _ := strconv.ParseInt(q.Get("from"), 10, 64)
		to, _ := strconv.ParseInt(q.Get("to"), 10, 64)
		var tracks []string
		for u := from; u <= to; u++ {
			if onServer[u] {
				tracks = append(tracks, fmt.Sprintf(`{"name":"Song","artist":{"#text":"Artist"},"album":{"#text":"Album"},"date":{"uts":"%d"}}`, u))
			}
		}
		looked = append(looked, from+1)
		body := `{"recenttracks":{"@attr":{"total":"` + strconv.Itoa(len(tracks)) + `"},"track":[` + strings.Join(tracks, ",") + `]}}`
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})}
	return env, &looked
}

// quarantineAt 记一条当前测试账号("me")下的隔离。
func quarantineAt(uts int64, at time.Time) {
	quarantineAtAs(uts, at, "me")
}

// quarantineAtAs 记一条指定账号下的隔离;account 为空就是老版本写下的、不记账号的隔离行。
func quarantineAtAs(uts int64, at time.Time, account string) {
	_ = appendListenLogLine(listenLogLine{T: "q", V: listenLogSchemaVersion, UTS: uts, AT: at.Unix(), U: account})
}

// 补交不碰隔离条目:空跑不列、真跑不交,也不去 Last.fm 查(交给常驻进程核对)。
func TestRunBackfillLeavesQuarantinedListensAlone(t *testing.T) {
	env, looked := reconcileEnv(t, map[int64]bool{})
	uts := seedListens(2)
	quarantineAt(uts[0], time.Now().Add(-time.Hour))

	if dry := runBackfill(context.Background(), env.s, true); dry.Eligible != 1 || len(dry.Items) != 1 || dry.Items[0].UTS != uts[1] {
		t.Fatalf("清单里只该有没隔离的那条: %+v", dry)
	}
	out := runBackfill(context.Background(), env.s, false)

	if out.Accepted != 1 || len(*looked) != 0 {
		t.Fatalf("只该交没隔离的那条、不发核对请求: %+v looked=%v", out, *looked)
	}
	if q := quarantinedBackfillListens(time.Now()); len(q) != 1 || q[0].line.UTS != uts[0] {
		t.Errorf("隔离的那条应原样隔离着: %+v", q)
	}
}

// 排在重发队列里的不进补交清单:那边会交。
func TestPendingBackfillSkipsRetryQueue(t *testing.T) {
	setUpBackfillRun(t, acceptAll)
	withLfmRetryFile(t)
	uts := seedListens(2)
	enqueueLastfmRetry(lfmRetryItem{User: "me", Timestamp: uts[0], Artist: "Artist", Title: "Song 0"})

	pending, _ := pendingBackfillListens(time.Now())
	if len(pending) != 1 || pending[0].UTS != uts[1] {
		t.Fatalf("重发队列里的不该算待补: %+v", pending)
	}
}

// 常驻进程核对隔离条目:Last.fm 上已有的补记回执;确认没有的排进重发队列、解除隔离,紧接着那一轮重发交上去;
// 隔离不久的不查(那边可能还没显示出来)。
func TestReconcileQuarantinedQueuesMissingListensForResend(t *testing.T) {
	onServer := map[int64]bool{}
	env, looked := reconcileEnv(t, onServer)
	withLfmRetryFile(t)
	uts := seedListens(3)
	onServer[uts[0]] = true
	old := time.Now().Add(-time.Hour)
	quarantineAt(uts[0], old)
	quarantineAt(uts[1], old)
	quarantineAt(uts[2], time.Now().Add(-time.Minute))

	recovered, released := reconcileQuarantined(context.Background(), env.s, time.Now())

	if recovered != 1 || released != 1 {
		t.Fatalf("应 1 条确认已有、1 条排进重发: recovered=%d released=%d", recovered, released)
	}
	if fmt.Sprint(*looked) != fmt.Sprint(uts[:2]) {
		t.Errorf("只该按时间戳查隔离够久的 %v,实际 %v", uts[:2], *looked)
	}
	if receiptMarks()[uts[0]] != "s" {
		t.Errorf("已在 Last.fm 上的应补记回执")
	}
	queue := loadLfmRetryLocked()
	if len(queue) != 1 || queue[0].Timestamp != uts[1] || queue[0].User != "me" || queue[0].Artist != "Artist" || queue[0].Title != "Song 1" {
		t.Fatalf("确认没有的应按收听日志排进重发队列: %+v", queue)
	}
	if q := quarantinedBackfillListens(time.Now()); len(q) != 1 || q[0].line.UTS != uts[2] {
		t.Errorf("隔离不久的那条应仍隔离着: %+v", q)
	}
	if pendingCount() != 0 {
		t.Errorf("排进重发队列的不该出现在补交清单里")
	}

	var sent []int64
	n := processLfmRetry(context.Background(), time.Now(), "me", func(_ context.Context, it lfmRetryItem) error {
		sent = append(sent, it.Timestamp)
		return nil
	}, defaultLfmRetryHooks("me"))
	if n != 1 || fmt.Sprint(sent) != fmt.Sprint(uts[1:2]) {
		t.Fatalf("解除隔离的那条应在重发里交上去: n=%d sent=%v", n, sent)
	}
	if receiptMarks()[uts[1]] != "s" || len(loadLfmRetryLocked()) != 0 {
		t.Errorf("交上去后应记回执、移出队列")
	}
}

// 隔离行记的账号不是当前账号(换过账号),或者是不记账号的老隔离行:不拿当前账号去查、也不重交,一直隔离着。
// 账号名不分大小写。
func TestReconcileQuarantinedSkipsOtherAccounts(t *testing.T) {
	env, looked := reconcileEnv(t, map[int64]bool{})
	withLfmRetryFile(t)
	uts := seedListens(3)
	old := time.Now().Add(-time.Hour)
	quarantineAtAs(uts[0], old, "someone-else")
	quarantineAtAs(uts[1], old, "")
	quarantineAtAs(uts[2], old, "ME")

	recovered, released := reconcileQuarantined(context.Background(), env.s, time.Now())

	if recovered != 0 || released != 1 {
		t.Fatalf("只该核对当前账号那条: recovered=%d released=%d", recovered, released)
	}
	if fmt.Sprint(*looked) != fmt.Sprint(uts[2:]) {
		t.Errorf("只该查当前账号的 %v,实际 %v", uts[2:], *looked)
	}
	queue := loadLfmRetryLocked()
	if len(queue) != 1 || queue[0].Timestamp != uts[2] || queue[0].User != "me" {
		t.Fatalf("只有当前账号那条该排进重发队列: %+v", queue)
	}
	q := quarantinedBackfillListens(time.Now())
	if len(q) != 2 || q[0].line.UTS != uts[0] || q[1].line.UTS != uts[1] {
		t.Errorf("别的账号和不记账号的应仍隔离着: %+v", q)
	}
	if pendingCount() != 0 {
		t.Errorf("还隔离着的不该出现在补交清单里")
	}

	// 当前账号为空(没配用户名)时一条都不查。
	env.s.user = ""
	quarantineAtAs(uts[2], old, "")
	*looked = nil
	if recovered, released := reconcileQuarantined(context.Background(), env.s, time.Now()); recovered != 0 || released != 0 || len(*looked) != 0 {
		t.Errorf("没有账号时不该核对: recovered=%d released=%d looked=%v", recovered, released, *looked)
	}
}

// 隔离行记下发出那次提交的账号:活路径失败留痕、补交整批隔离、重发隔离三处。
func TestQuarantineLinesRecordAccount(t *testing.T) {
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		return "", &net.OpError{Op: "read", Net: "tcp", Err: errors.New("i/o timeout")}
	})
	withLfmRetryFile(t)
	env.s.user = "me"
	uts := seedListens(1)
	if out := runBackfill(context.Background(), env.s, false); out.Quarantined != 1 {
		t.Fatalf("补交应整批隔离: %+v", out)
	}
	live := time.Now().Add(-2 * time.Hour).Unix()
	recordFailedMirror(fmt.Errorf("post: %w", context.DeadlineExceeded), "live-user", "A", "T", "", live, 200)
	retried := time.Now().Add(-3 * time.Hour).Unix()
	appendListen("A", "R", "", retried, 200)
	enqueueLastfmRetry(lfmRetryItem{User: "retry-user", Timestamp: retried, Artist: "A", Title: "R"})
	processLfmRetry(context.Background(), time.Now(), "retry-user", func(context.Context, lfmRetryItem) error {
		return &net.OpError{Op: "read", Net: "tcp", Err: errors.New("i/o timeout")}
	}, defaultLfmRetryHooks("retry-user"))

	f := foldListenLog(readListenLog())
	want := map[int64]string{uts[0]: "me", live: "live-user", retried: "retry-user"}
	for ts, account := range want {
		if _, q := f.quarantined[ts]; !q || f.quarantinedBy[ts] != account {
			t.Errorf("%d 应隔离在 %q 名下,got quarantined=%v account=%q", ts, account, q, f.quarantinedBy[ts])
		}
	}
}

// 核对时撞上限流:停下,剩下的照旧隔离,不排进重发队列。
func TestReconcileQuarantinedStopsOnLookupError(t *testing.T) {
	env := setUpBackfillRun(t, acceptAll)
	withLfmRetryFile(t)
	env.s.user = "me"
	env.s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"error":29,"message":"Rate limit exceeded"}`)), Header: http.Header{}}, nil
	})}
	uts := seedListens(2)
	quarantineAt(uts[0], time.Now().Add(-time.Hour))
	quarantineAt(uts[1], time.Now().Add(-time.Hour))

	recovered, released := reconcileQuarantined(context.Background(), env.s, time.Now())

	if recovered != 0 || released != 0 {
		t.Fatalf("查询出错不该有任何处置: recovered=%d released=%d", recovered, released)
	}
	if q := quarantinedBackfillListens(time.Now()); len(q) != 2 {
		t.Errorf("没核对成的应仍隔离着: %+v", q)
	}
	if len(loadLfmRetryLocked()) != 0 {
		t.Errorf("没核对成的不该排进重发队列")
	}
}

// 折叠:"r" 只解除它之前的那次隔离;之后再隔离一次又算隔离着。
func TestFoldListenLogReleaseThenQuarantineAgain(t *testing.T) {
	f := foldListenLog([]listenLogLine{
		{T: "l", UTS: 100, TI: "a"}, {T: "q", UTS: 100, AT: 1}, {T: "r", UTS: 100, AT: 2},
		{T: "l", UTS: 200, TI: "b"}, {T: "q", UTS: 200, AT: 1}, {T: "r", UTS: 200, AT: 2}, {T: "q", UTS: 200, AT: 3},
	})
	if _, q := f.quarantined[100]; q {
		t.Error("100 已解除")
	}
	if at, q := f.quarantined[200]; !q || at != 3 {
		t.Errorf("200 应按最后一次隔离算,got %d %v", at, q)
	}
}
