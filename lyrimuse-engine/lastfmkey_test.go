package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// key 被拒(要 Last.fm Pro)和授权失效分开:归类、写入熔断与状态文件、重发队列不丢、读取路径落同一个状态、熔断后探测恢复。

func resetLastfmKeyState(t *testing.T) {
	t.Helper()
	lastfmStatusOwner.Store(lastfmStatusNone)
	lastfmStaleStatusChecked.Store(false)
	t.Cleanup(func() {
		lastfmStatusOwner.Store(lastfmStatusNone)
		lastfmStaleStatusChecked.Store(false)
	})
}

func fakeLastfmClient(status int, contentType, body string) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		h := http.Header{}
		if contentType != "" {
			h.Set("Content-Type", contentType)
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: h}, nil
	})}
}

func readStatusFile(t *testing.T) (lastfmStatusFile, bool) {
	t.Helper()
	data, err := os.ReadFile(lastfmStatusPath)
	if err != nil {
		return lastfmStatusFile{}, false
	}
	var st lastfmStatusFile
	if err := json.Unmarshal(data, &st); err != nil {
		t.Fatalf("status file unreadable: %v", err)
	}
	return st, true
}

func TestClassifyLastfmError(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		code    int
		message string
		want    lastfmErrClass
	}{
		{"403 + 10:实测假 key 的形态", 403, 10, "Invalid API key - You must be granted a valid key by last.fm", lastfmErrKeyRejected},
		{"403 + 26:key 被停用", 403, 26, "Suspended API key", lastfmErrKeyRejected},
		{"200 + 10 也是 key 被拒", 200, 10, "Invalid API key", lastfmErrKeyRejected},
		{"403 没有码", 403, 0, "Forbidden", lastfmErrKeyRejected},
		{"403 + 认不出的码", 403, 31, "Something new", lastfmErrKeyRejected},
		{"message 提到 Pro,码认得也算被拒", 400, 6, "This API key requires a Last.fm Pro subscription", lastfmErrKeyRejected},
		{"message 提到订阅", 200, 0, "Please subscribe to continue", lastfmErrKeyRejected},
		{"200 + 9:授权失效", 200, 9, "Invalid session key - Please re-authenticate", lastfmErrSessionInvalid},
		{"403 + 9:授权失效,不是 key 被拒", 403, 9, "Invalid session key", lastfmErrSessionInvalid},
		{"4:授权失效(两击规则在 shouldDisable)", 200, 4, "Authentication Failed", lastfmErrSessionInvalid},
		{"403 + 6:认得的码,不算被拒", 403, 6, "Invalid parameters", lastfmErrOther},
		{"processing 里的 pro 不算", 200, 8, "There was an error processing your request", lastfmErrOther},
		{"限流", 200, 29, "Rate Limit Exceeded", lastfmErrOther},
		{"500 没有码", 500, 0, "Internal Server Error", lastfmErrOther},
	}
	for _, c := range cases {
		if got := classifyLastfmError(c.status, c.code, c.message); got != c.want {
			t.Errorf("%s: classify(%d, %d, %q) = %d, want %d", c.name, c.status, c.code, c.message, got, c.want)
		}
	}
}

// 写入路径的应答:403 + 10 / 26、认不出的 403 都成 *lastfmAPIError、带 HTTP 状态、归 key 被拒;200 + 9 归授权失效;
// 认不出的 500 仍是普通错误。
func TestLastfmCallClassifiesResponses(t *testing.T) {
	cases := []struct {
		name        string
		status      int
		contentType string
		body        string
		wantAPI     bool
		wantClass   lastfmErrClass
	}{
		{"403 + error 10", 403, "application/json", `{"message":"Invalid API key - You must be granted a valid key by last.fm","error":10}`, true, lastfmErrKeyRejected},
		{"403 + error 26", 403, "application/json", `{"message":"Suspended API key","error":26}`, true, lastfmErrKeyRejected},
		{"认不出的 403(网页)", 403, "text/html", `<html><head><title>403 Forbidden</title></head></html>`, true, lastfmErrKeyRejected},
		{"200 + error 9", 200, "application/json", `{"message":"Invalid session key - Please re-authenticate","error":9}`, true, lastfmErrSessionInvalid},
		{"500 网页", 500, "text/html", `<html><head><title>500</title></head></html>`, false, lastfmErrOther},
	}
	for _, c := range cases {
		s := newLastfmScrobbler("key", "secret", "sk")
		s.hc = fakeLastfmClient(c.status, c.contentType, c.body)
		err := s.call(context.Background(), "track.scrobble", map[string]string{"artist": "a", "track": "t", "timestamp": "1"})
		var apiErr *lastfmAPIError
		if errors.As(err, &apiErr) != c.wantAPI {
			t.Errorf("%s: err = %v, want lastfmAPIError=%v", c.name, err, c.wantAPI)
			continue
		}
		if !c.wantAPI {
			continue
		}
		if apiErr.Status != c.status || apiErr.class() != c.wantClass {
			t.Errorf("%s: status %d class %d, want %d / %d", c.name, apiErr.Status, apiErr.class(), c.status, c.wantClass)
		}
		if !strings.Contains(apiErr.Error(), "http "+strconv.Itoa(c.status)) && c.status != 200 {
			t.Errorf("%s: error text should carry the HTTP status for the log: %q", c.name, apiErr.Error())
		}
	}
}

// key 被拒一击熔断,状态文件 reason=key_rejected、带 HTTP 状态;同一次被拒再写不换 at(App 按 at 判要不要再弹通知);
// 那一首进了重发队列。
func TestMirrorKeyRejectedDisablesQueuesAndKeepsAt(t *testing.T) {
	useMirrorFiles(t)
	withLfmRetryFile(t)
	resetLastfmKeyState(t)
	s := newLastfmScrobbler("key", "secret", "sk")
	s.user = "u"
	s.hc = fakeLastfmClient(403, "application/json", `{"message":"Invalid API key","error":10}`)
	var fails failRecorder
	ts := time.Now().Add(-time.Minute).Unix()
	mirrorAsync(s, "scrobble", func(ctx context.Context) error {
		return s.scrobble(ctx, "Artist", "Title", "", ts, 200)
	}, func(err error) {
		fails.onFail(err)
		enqueueLastfmRetryIfSafe(err, lfmRetryItem{User: "u", Timestamp: ts, Artist: "Artist", Title: "Title"})
	})
	waitFor(t, "熔断", func() bool { return s.dead.Load() && fails.count() == 1 })
	if !s.deadKeyRejected.Load() {
		t.Fatal("key rejection must be remembered as the reason (only it is probed for recovery)")
	}
	st, ok := readStatusFile(t)
	if !ok || st.Reason != lastfmReasonKeyRejected || st.Status != 403 || st.Error != 10 {
		t.Fatalf("status file = %+v (exists=%v), want reason key_rejected, status 403, error 10", st, ok)
	}
	if items := loadLfmRetryLocked(); len(items) != 1 || items[0].Timestamp != ts {
		t.Fatalf("retry queue = %+v, the rejected listen must stay queued", items)
	}

	// 引擎重启后同一次被拒再写:at 不变。
	old := st.At - 3600
	st.At = old
	data, _ := json.Marshal(st)
	if err := os.WriteFile(lastfmStatusPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	writeLastfmMirrorStatus(&lastfmAPIError{Code: 26, Status: 403, Method: "track.scrobble"})
	if st2, _ := readStatusFile(t); st2.At != old {
		t.Fatalf("at = %d, want the earlier %d kept for the same key rejection", st2.At, old)
	}
	// 授权失效照旧换新的 at、reason=session。
	writeLastfmMirrorStatus(&lastfmAPIError{Code: 9, Status: 200, Method: "track.scrobble"})
	if st3, _ := readStatusFile(t); st3.Reason != lastfmReasonSession || st3.At == old {
		t.Fatalf("session error status = %+v, want reason session with a fresh at", st3)
	}
}

// 重发队列:key 被拒的(403 + 10、200 + 26、认不出的 403、message 提到 Pro)不移出、这一轮停下;授权失效同样留着。
func TestProcessLfmRetryKeepsKeyRejected(t *testing.T) {
	rejections := map[string]error{
		"403+10":     &lastfmAPIError{Code: 10, Status: 403},
		"200+26":     &lastfmAPIError{Code: 26, Status: 200},
		"403 无码":     &lastfmAPIError{Status: 403, Message: "Forbidden"},
		"403 新码":     &lastfmAPIError{Code: 31, Status: 403},
		"Pro 字样":     &lastfmAPIError{Code: 6, Status: 400, Message: "Last.fm Pro required"},
		"200+9 授权失效": &lastfmAPIError{Code: 9, Status: 200},
	}
	now := time.Unix(1_800_000_000, 0)
	for name, rejection := range rejections {
		withLfmRetryFile(t)
		for i, title := range []string{"first", "second"} {
			enqueueLastfmRetryIfSafe(rejection, lfmRetryItem{User: "u", Timestamp: now.Add(-time.Hour).Unix() + int64(i), Artist: "a", Title: title})
		}
		if n := len(loadLfmRetryLocked()); n != 2 {
			t.Fatalf("%s: enqueued %d, want both (key rejection is resend-safe)", name, n)
		}
		calls := 0
		hooks := lfmRetryHooks{
			handled:    func() map[int64]bool { return nil },
			submitted:  func(int64) error { return nil },
			quarantine: func(int64) { t.Errorf("%s: key rejection must not quarantine", name) },
		}
		processLfmRetry(context.Background(), now, "u", func(context.Context, lfmRetryItem) error { calls++; return rejection }, hooks)
		if calls != 1 {
			t.Errorf("%s: %d submits, want 1 (stop the round on a credential error)", name, calls)
		}
		if items := loadLfmRetryLocked(); len(items) != 2 {
			t.Errorf("%s: queue after round = %+v, want both kept", name, items)
		}
	}
}

// 读取路径:403 + error 10 落状态文件(读取路径写的);读取成功撤掉它;写入器熔断写的,读取成功不撤。
func TestLastfmReadKeyRejectedSharesStatus(t *testing.T) {
	useMirrorFiles(t)
	useUnthrottledGuard(t)
	resetLastfmKeyState(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })

	lastfmReadClient = fakeLastfmClient(403, "application/json", `{"message":"Invalid API key","error":10}`)
	var out json.RawMessage
	err := lastfmAPIGet(context.Background(), map[string][]string{"method": {"user.getWeeklyChartList"}, "user": {"u"}, "api_key": {"k"}}, &out)
	var apiErr *lastfmAPIError
	if !errors.As(err, &apiErr) || apiErr.class() != lastfmErrKeyRejected || apiErr.Status != 403 {
		t.Fatalf("read err = %v, want a key-rejected lastfmAPIError with status 403", err)
	}
	if st, ok := readStatusFile(t); !ok || st.Reason != lastfmReasonKeyRejected {
		t.Fatalf("status file = %+v (exists=%v), want key_rejected written by the read path", st, ok)
	}
	if _, ok := lastfmRecent(context.Background(), "u", "k"); ok {
		t.Fatal("lastfmRecent must fail on a rejected key")
	}

	lastfmReadClient = fakeLastfmClient(200, "application/json", `{"recenttracks":{"@attr":{"total":"0"},"track":[]}}`)
	if _, ok := lastfmRecent(context.Background(), "u", "k"); !ok {
		t.Fatal("lastfmRecent should succeed")
	}
	if _, ok := readStatusFile(t); ok {
		t.Fatal("a successful read must clear the key rejection the read path wrote")
	}

	// 写入器熔断写的状态文件:读取成功不撤。
	s := newLastfmScrobbler("key", "secret", "sk")
	s.disable(&lastfmAPIError{Code: 10, Status: 403, Method: "track.scrobble"})
	if _, ok := lastfmRecent(context.Background(), "u", "k"); !ok {
		t.Fatal("lastfmRecent should succeed")
	}
	if _, ok := readStatusFile(t); !ok {
		t.Fatal("a read success must not clear the writer's key rejection; only a write success does")
	}
	noteLastfmWriteOK()
	if _, ok := readStatusFile(t); ok {
		t.Fatal("a write success clears the status file")
	}
}

// 读取路径 200 + 凭据以外的码(6、29)照旧交给调用方自己看,不报错、不落状态文件。
func TestLastfmReadOtherCodesStillDecoded(t *testing.T) {
	useMirrorFiles(t)
	useUnthrottledGuard(t)
	resetLastfmKeyState(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	lastfmReadClient = fakeLastfmClient(200, "application/json", `{"error":6,"message":"not found"}`)
	var out struct {
		Error int `json:"error"`
	}
	if err := lastfmAPIGet(context.Background(), map[string][]string{"method": {"artist.getInfo"}}, &out); err != nil || out.Error != 6 {
		t.Fatalf("err = %v, out.Error = %d; want nil and 6 decoded for the caller", err, out.Error)
	}
	if _, ok := readStatusFile(t); ok {
		t.Fatal("error 6 is not a credential problem")
	}
}

// 熔断后的恢复:只有 key 被拒的熔断会探;两次探测之间隔 lastfmKeyProbeInterval;探到 key 恢复就解除熔断。
func TestReviveIfKeyAccepted(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	probes := 0
	rejecting := func(context.Context, string, string) error {
		probes++
		return &lastfmAPIError{Code: 10, Status: 403}
	}
	accepting := func(context.Context, string, string) error { probes++; return nil }

	session := newLastfmScrobbler("key", "secret", "sk")
	session.dead.Store(true)
	if session.reviveIfKeyAccepted(context.Background(), now, accepting) || probes != 0 {
		t.Fatal("a session-invalid breaker is never probed; only reconnecting fixes it")
	}

	s := newLastfmScrobbler("key", "secret", "sk")
	s.dead.Store(true)
	s.deadKeyRejected.Store(true)
	if s.reviveIfKeyAccepted(context.Background(), now, rejecting) || probes != 1 || !s.dead.Load() {
		t.Fatalf("still rejected: probes=%d dead=%v, want 1 probe and still dead", probes, s.dead.Load())
	}
	if s.reviveIfKeyAccepted(context.Background(), now.Add(lastfmKeyProbeInterval/2), accepting) || probes != 1 {
		t.Fatalf("probed again within the interval (probes=%d)", probes)
	}
	if !s.reviveIfKeyAccepted(context.Background(), now.Add(lastfmKeyProbeInterval), accepting) || s.dead.Load() || s.deadKeyRejected.Load() {
		t.Fatal("an accepted key must lift the breaker")
	}
}

// 判据两边逐条一致:引擎的已知码表和 Pro 字样的正则,跟 App 侧 LastfmErrorClassifier 的字面量一样。
func TestLastfmErrorClassMatchesSwift(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "lyrimuse", "Sources", "LyrimuseCore", "Local", "LastfmErrorClassifier.swift"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`knownCodes: Set<Int> = \[([0-9, ]+)\]`).FindSubmatch(src)
	if m == nil {
		t.Fatal("knownCodes literal not found in LastfmErrorClassifier.swift")
	}
	var swiftCodes []int
	for _, f := range strings.Split(string(m[1]), ",") {
		n, err := strconv.Atoi(strings.TrimSpace(f))
		if err != nil {
			t.Fatal(err)
		}
		swiftCodes = append(swiftCodes, n)
	}
	goCodes := append([]int(nil), lastfmKnownErrorCodes...)
	sort.Ints(swiftCodes)
	sort.Ints(goCodes)
	if len(swiftCodes) != len(goCodes) {
		t.Fatalf("known codes differ: swift %v, go %v", swiftCodes, goCodes)
	}
	for i := range goCodes {
		if goCodes[i] != swiftCodes[i] {
			t.Fatalf("known codes differ: swift %v, go %v", swiftCodes, goCodes)
		}
	}
	p := regexp.MustCompile(`proMessagePattern = #"([^"]*)"#`).FindSubmatch(src)
	if p == nil || string(p[1]) != lastfmProMessagePattern {
		t.Fatalf("pro message pattern differs: swift %q, go %q", p, lastfmProMessagePattern)
	}
}
