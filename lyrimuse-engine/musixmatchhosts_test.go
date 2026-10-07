package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// mxmHost 是一台假的 Musixmatch 主机:reply 决定这一次怎么答,calls 记它被问了几次。
type mxmHost struct {
	base  string
	calls atomic.Int32
	reply atomic.Value // func(w http.ResponseWriter)
}

func (h *mxmHost) answer(f func(w http.ResponseWriter)) { h.reply.Store(f) }

func mxmReplyStatus(code int) func(w http.ResponseWriter) {
	return func(w http.ResponseWriter) { w.WriteHeader(code) }
}

func mxmReplyEnvelope(status int, hint string) func(w http.ResponseWriter) {
	return func(w http.ResponseWriter) {
		fmt.Fprintf(w, `{"message":{"header":{"status_code":%d,"hint":%q},"body":{}}}`, status, hint)
	}
}

// withMxmHosts 把 musixmatchBases 换成两台本地假主机(主用在前),主机选择状态清零,时钟换成可拨的。
func withMxmHosts(t *testing.T) (primary, backup *mxmHost, advance func(time.Duration)) {
	t.Helper()
	resetMusixmatchTokenStateForTest(t)
	musixmatchDoFetchToken = func(context.Context) string { return "" }
	musixmatchTokenMu.Lock()
	musixmatchToken, musixmatchTokenExpiry = "test-token", time.Now().Add(time.Hour)
	musixmatchTokenMu.Unlock()
	newHost := func() *mxmHost {
		h := &mxmHost{}
		h.answer(mxmReplyEnvelope(200, ""))
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h.calls.Add(1)
			h.reply.Load().(func(http.ResponseWriter))(w)
		}))
		t.Cleanup(srv.Close)
		h.base = srv.URL + "/ws/1.1/"
		return h
	}
	primary, backup = newHost(), newHost()
	savedBases, savedNow := musixmatchBases, musixmatchHostNow
	now := time.Now()
	musixmatchBases = []string{primary.base, backup.base}
	musixmatchHostNow = func() time.Time { return now }
	resetHosts := func() {
		musixmatchHostMu.Lock()
		musixmatchPreferBase, musixmatchPreferUntil, musixmatchSwitchHeldUntil = "", time.Time{}, time.Time{}
		musixmatchHostMu.Unlock()
	}
	resetHosts()
	// 熔断器也换一份:答 captcha 会让它暂停整个源(sourcebreaker.go「反爬拦截」),别带进后面的测试。
	savedBreaker := sharedLyricSourceBreaker()
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	t.Cleanup(func() {
		musixmatchBases, musixmatchHostNow = savedBases, savedNow
		resetHosts()
		setSharedLyricSourceBreaker(savedBreaker)
	})
	return primary, backup, func(d time.Duration) { now = now.Add(d) }
}

func mxmCallCounts(t *testing.T, primary, backup *mxmHost, wantPrimary, wantBackup int32, step string) {
	t.Helper()
	if p, b := primary.calls.Load(), backup.calls.Load(); p != wantPrimary || b != wantBackup {
		t.Fatalf("%s: 主用被问 %d 次、备用 %d 次,期望 %d / %d", step, p, b, wantPrimary, wantBackup)
	}
}

// 主用答 503:换到备用拿结果;之后先问备用,到期再从主用试起。
func TestMusixmatchSwitchesToBackupHost(t *testing.T) {
	primary, backup, advance := withMxmHosts(t)
	primary.answer(mxmReplyStatus(http.StatusServiceUnavailable))

	if _, err := musixmatchDo(context.Background(), "track.get", neturl.Values{}); err != nil {
		t.Fatalf("备用答上来了,不该报错: %v", err)
	}
	mxmCallCounts(t, primary, backup, 1, 1, "第一次")

	if _, err := musixmatchDo(context.Background(), "track.get", neturl.Values{}); err != nil {
		t.Fatal(err)
	}
	mxmCallCounts(t, primary, backup, 1, 2, "换过之后")

	advance(musixmatchPreferBackupFor + time.Second)
	if _, err := musixmatchDo(context.Background(), "track.get", neturl.Values{}); err != nil {
		t.Fatal(err)
	}
	mxmCallCounts(t, primary, backup, 2, 3, "先问备用的窗口到期")
}

// 主用答了(查无、captcha、token 失效都算答了):不换主机。
func TestMusixmatchAnsweredRequestDoesNotSwitchHost(t *testing.T) {
	primary, backup, _ := withMxmHosts(t)
	for i, reply := range []func(http.ResponseWriter){
		mxmReplyEnvelope(404, ""),
		mxmReplyEnvelope(401, "captcha"),
		mxmReplyEnvelope(401, "renew"),
		mxmReplyEnvelope(503, ""),
	} {
		primary.answer(reply)
		_, _ = musixmatchDo(context.Background(), "track.get", neturl.Values{})
		mxmCallCounts(t, primary, backup, int32(i+1), 0, fmt.Sprintf("第 %d 种应答", i+1))
		// captcha 另外会暂停整个源(见 musixmatchblock_test.go);这里只看换不换主机,撤掉接着问。
		if _, blocked := sharedLyricSourceBreaker().blockedFor("musixmatch"); blocked != (i == 1) {
			t.Fatalf("第 %d 种应答之后 blocked = %v", i+1, blocked)
		}
		sharedLyricSourceBreaker().clearBlocked("musixmatch")
	}
}

// HTTP 200 但不是 Musixmatch 的应答格式(维护页、网关错误页):这台没答上来,换下一台。
func TestMusixmatchNonEnvelopeSwitchesHost(t *testing.T) {
	primary, backup, _ := withMxmHosts(t)
	primary.answer(func(w http.ResponseWriter) { fmt.Fprint(w, "<html>maintenance</html>") })
	body, err := musixmatchDo(context.Background(), "track.get", neturl.Values{})
	if err != nil || musixmatchHeaderStatus(body) != 200 {
		t.Fatalf("应拿到备用的应答: body=%q err=%v", body, err)
	}
	mxmCallCounts(t, primary, backup, 1, 1, "维护页")
}

// 两台都没问成:报错;之后一段时间只问排第一的那台,到期再两台都试。
func TestMusixmatchAllHostsFailedHoldsSwitching(t *testing.T) {
	primary, backup, advance := withMxmHosts(t)
	primary.answer(mxmReplyStatus(http.StatusBadGateway))
	backup.answer(mxmReplyStatus(http.StatusBadGateway))

	if _, err := musixmatchDo(context.Background(), "track.get", neturl.Values{}); err == nil {
		t.Fatal("两台都没问成应当报错")
	}
	mxmCallCounts(t, primary, backup, 1, 1, "第一次")

	_, _ = musixmatchDo(context.Background(), "track.get", neturl.Values{})
	mxmCallCounts(t, primary, backup, 2, 1, "停换期间")

	advance(musixmatchSwitchHoldFor + time.Second)
	_, _ = musixmatchDo(context.Background(), "track.get", neturl.Values{})
	mxmCallCounts(t, primary, backup, 3, 2, "停换到期")
}

// 正在先问备用、备用没问成而主用答上来了:回到主用优先。
func TestMusixmatchReturnsToPrimaryWhenBackupFails(t *testing.T) {
	primary, backup, _ := withMxmHosts(t)
	primary.answer(mxmReplyStatus(http.StatusServiceUnavailable))
	_, _ = musixmatchDo(context.Background(), "track.get", neturl.Values{})
	if got := musixmatchHostOrder()[0]; got != backup.base {
		t.Fatalf("主用没问成之后应先问备用,实际先问 %s", got)
	}
	primary.answer(mxmReplyEnvelope(200, ""))
	backup.answer(mxmReplyStatus(http.StatusServiceUnavailable))
	if _, err := musixmatchDo(context.Background(), "track.get", neturl.Values{}); err != nil {
		t.Fatal(err)
	}
	if got := musixmatchHostOrder()[0]; got != primary.base {
		t.Fatalf("主用答上来之后应回到主用优先,实际先问 %s", got)
	}
}

// 调用方取消 / 到期、被本地出站闸拦下:不换主机。
func TestMusixmatchHostFailedSkipsCallerAndLocalGuard(t *testing.T) {
	live := context.Background()
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	expired, cancelExpired := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancelExpired()
	for _, tc := range []struct {
		name string
		ctx  context.Context
		err  error
		want bool
	}{
		{"连不上", live, errors.New("dial tcp: connection refused"), true},
		{"单次尝试超时", live, context.DeadlineExceeded, true},
		{"调用方取消", canceled, context.Canceled, false},
		{"调用方到期", expired, context.DeadlineExceeded, false},
		{"本地出站闸", live, errHostGuarded, false},
		{"本地限速排不上", live, fmt.Errorf("track.get: %w", errHostRateLimited), false},
	} {
		if got := musixmatchHostFailed(tc.ctx, tc.err); got != tc.want {
			t.Errorf("%s: musixmatchHostFailed = %v, 期望 %v", tc.name, got, tc.want)
		}
	}
}

// 换主机的日志不带请求 URL:*url.Error 的 Error() 会拼进完整 URL,里面有 usertoken。
func TestMusixmatchLogCauseDropsURL(t *testing.T) {
	ue := &neturl.Error{Op: "Get", URL: "https://apic-appmobile.musixmatch.com/ws/1.1/track.get?usertoken=SECRET", Err: errors.New("connection reset")}
	for _, err := range []error{ue, fmt.Errorf("track.get: %w", ue)} {
		got := musixmatchLogCause(err).Error()
		if strings.Contains(got, "SECRET") || strings.Contains(got, "usertoken") {
			t.Fatalf("日志原因带出了 URL: %q", got)
		}
		if got != "connection reset" {
			t.Fatalf("应只留下层错误,实际 %q", got)
		}
	}
	if got := musixmatchLogCause(errors.New("status 503")).Error(); got != "status 503" {
		t.Fatalf("不是 *url.Error 的原样保留,实际 %q", got)
	}
}
