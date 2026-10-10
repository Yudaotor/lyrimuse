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

func quarantineAt(uts int64, at time.Time) {
	_ = appendListenLogLine(listenLogLine{T: "q", V: listenLogSchemaVersion, UTS: uts, AT: at.Unix()})
}

// 补交开头核对隔离条目:Last.fm 上已有的补记回执、不再交;确认没有且隔离够久的解除隔离、这一趟跟着补交;
// 隔离不久的不动(那边可能还没显示出来)。
func TestRunBackfillReconcilesQuarantinedListens(t *testing.T) {
	onServer := map[int64]bool{}
	env, looked := reconcileEnv(t, onServer)
	uts := seedListens(3)
	onServer[uts[0]] = true
	old := time.Now().Add(-time.Hour)
	quarantineAt(uts[0], old)
	quarantineAt(uts[1], old)
	quarantineAt(uts[2], time.Now().Add(-time.Minute))

	if dry := runBackfill(context.Background(), env.s, true); dry.Unverified != 3 || dry.Eligible != 0 {
		t.Fatalf("空跑应报 3 条待核对、0 条待补: %+v", dry)
	}
	if len(*looked) != 0 {
		t.Fatalf("空跑不该发核对请求")
	}

	out := runBackfill(context.Background(), env.s, false)

	if out.Recovered != 1 || out.Released != 1 || out.Accepted != 1 || out.Eligible != 1 {
		t.Fatalf("应 1 条确认已有、1 条解除后补上: %+v", out)
	}
	if fmt.Sprint(*looked) != fmt.Sprint(uts) {
		t.Errorf("应逐条按时间戳核对 %v,实际 %v", uts, *looked)
	}
	var sent []string
	for _, f := range env.requests() {
		sent = append(sent, f.Get("timestamp[0]"))
	}
	if fmt.Sprint(sent) != fmt.Sprint([]string{strconv.FormatInt(uts[1], 10)}) {
		t.Errorf("只该补交解除隔离的那一条,实际发了 %v", sent)
	}
	if q := quarantinedBackfillListens(time.Now()); len(q) != 1 || q[0].line.UTS != uts[2] {
		t.Errorf("隔离不久的那条应仍隔离着: %+v", q)
	}
	if pendingCount() != 0 {
		t.Errorf("不该再有待补的")
	}
}

// 核对时撞上限流:停下,剩下的照旧隔离,不影响后面的补交。
func TestReconcileQuarantinedStopsOnLookupError(t *testing.T) {
	env := setUpBackfillRun(t, acceptAll)
	env.s.user = "me"
	post := env.s.hc.Transport
	env.s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet {
			return post.RoundTrip(r)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"error":29,"message":"Rate limit exceeded"}`)), Header: http.Header{}}, nil
	})}
	uts := seedListens(2)
	quarantineAt(uts[0], time.Now().Add(-time.Hour))

	out := runBackfill(context.Background(), env.s, false)

	if out.Recovered != 0 || out.Released != 0 || out.Accepted != 1 {
		t.Fatalf("核对停下后照常补交没隔离的那条: %+v", out)
	}
	if q := quarantinedBackfillListens(time.Now()); len(q) != 1 {
		t.Errorf("没核对成的应仍隔离着: %+v", q)
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
