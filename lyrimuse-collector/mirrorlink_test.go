package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 当场 scrobble 这条链路串起来的行为:mirrorAsync 的熔断 / 留痕回调 / 成功收尾,
// mirrorScrobbleTracked 与退出用的 mirrorScrobbleSync 的「先标记后发」和失败留痕。
// 各个判定函数(shouldDisable / recordFailedMirror / provablyNeverSent)单独的规格在
// mirrorfailure_test.go,这里只验它们被接对了。

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("等不到: %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// mirrorStatusPathOnce:lastfmStatusPath 整个测试进程只设这一次、之后不再改写。mirrorAsync 的
// goroutine 在成功收尾时读它,跟测试没有同步点;每个用例各设一次再还原,竞态检测会报。
var mirrorStatusPathOnce sync.Once

// useMirrorFiles 把收听日志指到临时目录、清掉共用的 Last.fm 状态文件,返回状态文件路径。
func useMirrorFiles(t *testing.T) string {
	t.Helper()
	mirrorStatusPathOnce.Do(func() {
		dir, err := os.MkdirTemp("", "lyrimuse-mirror-status-")
		if err != nil {
			t.Fatal(err)
		}
		lastfmStatusPath = filepath.Join(dir, "lastfm-status.json")
	})
	_ = os.Remove(lastfmStatusPath)
	savedLog, savedNudge := listenLogPath, lastfmFeedNudgeAt.Load()
	t.Cleanup(func() {
		listenLogPath = savedLog
		lastfmFeedNudgeAt.Store(savedNudge)
	})
	listenLogPath = filepath.Join(t.TempDir(), "listens.jsonl")
	setMatch(t, lastfmMatchRaw, false, false, false)
	return lastfmStatusPath
}

// logKinds 按写入顺序返回某个 uts 在收听日志里的行类型,比如 "lq"。
func logKinds(uts int64) string {
	var b strings.Builder
	for _, l := range readListenLog() {
		if l.UTS == uts {
			b.WriteString(l.T)
		}
	}
	return b.String()
}

func listenLine(uts int64) (listenLogLine, bool) {
	for _, l := range readListenLog() {
		if l.UTS == uts && l.T == "l" {
			return l, true
		}
	}
	return listenLogLine{}, false
}

// failRecorder 记下 onFail 收到的错误,可从 mirrorAsync 的 goroutine 里调用。
type failRecorder struct {
	mu   sync.Mutex
	errs []error
}

func (f *failRecorder) onFail(err error) {
	f.mu.Lock()
	f.errs = append(f.errs, err)
	f.mu.Unlock()
}

func (f *failRecorder) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.errs)
}

func (f *failRecorder) last() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.errs) == 0 {
		return nil
	}
	return f.errs[len(f.errs)-1]
}

func apiCode(err error) int {
	var apiErr *lastfmAPIError
	if errors.As(err, &apiErr) {
		return apiErr.Code
	}
	return 0
}

func TestMirrorAsyncWithoutScrobblerDoesNothing(t *testing.T) {
	useMirrorFiles(t)
	var called atomic.Bool
	var fails failRecorder
	mirrorAsync(nil, "scrobble", func(context.Context) error { called.Store(true); return nil }, fails.onFail)
	if called.Load() || fails.count() != 0 {
		t.Fatal("没配凭据时不该发请求,也不算失败")
	}
}

// 已熔断:不再发请求,但这一条照样交给 onFail 留痕。
func TestMirrorAsyncDeadShortCircuitsButReportsFailure(t *testing.T) {
	useMirrorFiles(t)
	s := newLastfmScrobbler("k", "s", "sk")
	s.dead.Store(true)
	var called atomic.Bool
	var fails failRecorder
	mirrorAsync(s, "scrobble", func(context.Context) error { called.Store(true); return nil }, fails.onFail)
	if called.Load() {
		t.Error("熔断后不该再发请求")
	}
	if fails.count() != 1 || apiCode(fails.last()) != 9 {
		t.Errorf("熔断短路应同步报一次 error 9 给 onFail,got %v", fails.errs)
	}
}

// 成功一次:洗清 error 4 嫌疑、删掉上次留下的「授权失效」状态文件,不报失败。
func TestMirrorAsyncSuccessClearsSuspicionAndStatusFile(t *testing.T) {
	status := useMirrorFiles(t)
	if err := os.WriteFile(status, []byte(`{"error":9}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newLastfmScrobbler("k", "s", "sk")
	s.suspect4.Store(time.Now().UnixNano())
	var fails failRecorder
	mirrorAsync(s, "scrobble", func(context.Context) error { return nil }, fails.onFail)

	waitFor(t, "状态文件被删、嫌疑清零", func() bool {
		_, err := os.Stat(status)
		return os.IsNotExist(err) && s.suspect4.Load() == 0
	})
	if fails.count() != 0 || s.dead.Load() {
		t.Error("成功不该报失败、不该熔断")
	}
}

// 触发熔断的这一次:置 dead、落状态文件给 App 显示红标,并且这一条同样交给 onFail ——
// 它确定没写进去,不留痕就是重新授权后回填也补不回来的一条。
func TestMirrorAsyncFatalErrorDisablesAndStillReportsFailure(t *testing.T) {
	status := useMirrorFiles(t)
	s := newLastfmScrobbler("k", "s", "sk")
	var fails failRecorder
	mirrorAsync(s, "scrobble", func(context.Context) error {
		return &lastfmAPIError{Code: 9, Message: "Invalid session key", Method: "track.scrobble"}
	}, fails.onFail)

	waitFor(t, "onFail 被调用", func() bool { return fails.count() == 1 })
	if !s.dead.Load() {
		t.Error("error 9 应一击熔断")
	}
	data, err := os.ReadFile(status)
	var got struct {
		Error  int    `json:"error"`
		Method string `json:"method"`
	}
	if err != nil || json.Unmarshal(data, &got) != nil || got.Error != 9 || got.Method != "track.scrobble" {
		t.Errorf("应落状态文件 error=9 method=track.scrobble,got %s err=%v", data, err)
	}
	if apiCode(fails.last()) != 9 {
		t.Errorf("onFail 应拿到原始的 error 9,got %v", fails.last())
	}
}

// 单发 error 4:只记嫌疑、不熔断、不落状态文件,这一条照样留痕。
func TestMirrorAsyncSingleError4OnlyRaisesSuspicion(t *testing.T) {
	status := useMirrorFiles(t)
	s := newLastfmScrobbler("k", "s", "sk")
	var fails failRecorder
	mirrorAsync(s, "scrobble", func(context.Context) error {
		return &lastfmAPIError{Code: 4, Message: "Authentication Failed", Method: "track.scrobble"}
	}, fails.onFail)

	waitFor(t, "onFail 被调用", func() bool { return fails.count() == 1 })
	if s.dead.Load() || s.suspect4.Load() == 0 {
		t.Errorf("单发 error 4 应只记嫌疑: dead=%v suspect4=%d", s.dead.Load(), s.suspect4.Load())
	}
	if _, err := os.Stat(status); !os.IsNotExist(err) {
		t.Error("没熔断就不该落「授权失效」状态文件")
	}
}

// 嫌疑窗口内的第二发 error 4 坐实熔断,同样留痕。
func TestMirrorAsyncSecondError4Disables(t *testing.T) {
	useMirrorFiles(t)
	s := newLastfmScrobbler("k", "s", "sk")
	s.suspect4.Store(time.Now().Add(-time.Minute).UnixNano())
	var fails failRecorder
	mirrorAsync(s, "scrobble", func(context.Context) error {
		return &lastfmAPIError{Code: 4, Message: "Authentication Failed", Method: "track.scrobble"}
	}, fails.onFail)

	waitFor(t, "onFail 被调用", func() bool { return fails.count() == 1 })
	if !s.dead.Load() {
		t.Error("1 分钟前有过嫌疑,这一发应坐实熔断")
	}
}

func TestMirrorAsyncNetworkErrorReportsFailure(t *testing.T) {
	useMirrorFiles(t)
	s := newLastfmScrobbler("k", "s", "sk")
	var fails failRecorder
	mirrorAsync(s, "scrobble", func(context.Context) error { return errors.New("connection reset by peer") }, fails.onFail)

	waitFor(t, "onFail 被调用", func() bool { return fails.count() == 1 })
	if s.dead.Load() {
		t.Error("网络错误不该熔断")
	}
}

// mirrorPollerEnv 是一个只带 Last.fm 镜像字段的 poller,外加记录请求的假 Last.fm。
type mirrorPollerEnv struct {
	p        *poller
	requests atomic.Int32
	// markedBeforeSend:每次请求到达时,落盘的 lfmMirrored 里是否已经有这次的时间戳。
	markedBeforeSend atomic.Bool
}

func newMirrorPoller(t *testing.T, reply func() (string, error)) *mirrorPollerEnv {
	t.Helper()
	useMirrorFiles(t)
	env := &mirrorPollerEnv{}
	s := newLastfmScrobbler("key", "secret", "sk")
	set := persistedTTLSet{path: filepath.Join(t.TempDir(), "mirrored.json"), ttl: lfmMirroredTTL}
	s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		env.requests.Add(1)
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		persisted, _ := set.load()
		if ts, err := strconv.ParseInt(form.Get("timestamp"), 10, 64); err == nil {
			env.markedBeforeSend.Store(persisted[ts])
		}
		resp, err := reply()
		if err != nil {
			return nil, err
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(resp)), Header: http.Header{}}, nil
	})}
	env.p = &poller{lfm: s, lfmMirrored: map[int64]bool{}, lfmMirroredSet: set}
	return env
}

const acceptedOne = `{"scrobbles":{"@attr":{"accepted":"1","ignored":"0"},"scrobble":{"timestamp":"0","ignoredMessage":{"code":"0","#text":""}}}}`

// 成功:请求发出前时间戳已经落盘(防 bridge 抢跑),本地日志不写,约好几秒后重拉 feed;
// 同一个时间戳再来一次不会重发。
func TestMirrorScrobbleTrackedMarksBeforeSendingAndIsIdempotent(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
	lastfmFeedNudgeAt.Store(0)
	// 成功收尾的最后一步是删状态文件:等它删掉,goroutine 就不会在清理函数还原全局路径之后再读。
	if err := os.WriteFile(lastfmStatusPath, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	uts := time.Now().Add(-3 * time.Minute).Unix()

	env.p.mirrorScrobbleTracked("Artist", "Song", "Album", uts, "Artist", 200, false)
	waitFor(t, "成功收尾跑完", func() bool {
		_, err := os.Stat(lastfmStatusPath)
		return lastfmFeedNudgeAt.Load() != 0 && os.IsNotExist(err)
	})
	env.p.mirrorScrobbleTracked("Artist", "Song", "Album", uts, "Artist", 200, false)
	// 守卫失效时第二次提交在 goroutine 里发出,给它时间到达假服务器。
	time.Sleep(200 * time.Millisecond)

	if !env.markedBeforeSend.Load() {
		t.Error("请求到达时时间戳应已写进 lfmMirrored 落盘文件")
	}
	if n := env.requests.Load(); n != 1 {
		t.Errorf("同一个时间戳只该提交一次,发了 %d 次", n)
	}
	if k := logKinds(uts); k != "" {
		t.Errorf("镜像成功不该写本地收听日志,got %q", k)
	}
}

// 连接中途断开(不确定发没发到):记 "l" + "q",用播放器报的原始艺人名和时长。
func TestMirrorScrobbleTrackedUncertainFailureIsLoggedAndQuarantined(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return "", errors.New("connection reset by peer") })
	uts := time.Now().Add(-3 * time.Minute).Unix()

	env.p.mirrorScrobbleTracked("Folded", "Song", "Album", uts, "Raw A & B", 215, false)

	waitFor(t, "留痕写进日志", func() bool { return logKinds(uts) == "lq" })
	l, _ := listenLine(uts)
	if l.AR != "Raw A & B" || l.DUR != 215 {
		t.Errorf("日志里应是原始艺人名和时长,got AR=%q DUR=%v", l.AR, l.DUR)
	}
	if !env.p.lfmMirrored[uts] {
		t.Error("失败也不撤销标记:活路径永不再发这条")
	}
}

// 触发熔断的那一次也要留痕,且确定没落库 → 只写 "l",回填能补。
func TestMirrorScrobbleTrackedFatalErrorIsLoggedForBackfill(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return `{"error":9,"message":"Invalid session key"}`, nil })
	uts := time.Now().Add(-3 * time.Minute).Unix()

	env.p.mirrorScrobbleTracked("Artist", "Song", "Album", uts, "Artist", 200, false)

	waitFor(t, "留痕写进日志", func() bool { return logKinds(uts) != "" })
	if k := logKinds(uts); k != "l" {
		t.Errorf("凭据判死 = 确定没落库,应只写 l 不隔离,got %q", k)
	}
	if !env.p.lfm.dead.Load() {
		t.Error("error 9 应熔断")
	}
	pending, _ := pendingBackfillListens(time.Now())
	if len(pending) != 1 || pending[0].UTS != uts {
		t.Errorf("这一条应出现在待补清单里,got %+v", pending)
	}
}

func TestMirrorScrobbleTrackedSkipsWithoutScrobblerOrTimestamp(t *testing.T) {
	env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
	env.p.mirrorScrobbleTracked("A", "S", "", 0, "A", 200, false)
	lfm := env.p.lfm
	env.p.lfm = nil
	env.p.mirrorScrobbleTracked("A", "S", "", 1790000000, "A", 200, false)
	env.p.lfm = lfm
	if env.requests.Load() != 0 || len(env.p.lfmMirrored) != 0 {
		t.Error("没有时间戳或没连账号时不该标记、不该发请求")
	}
}

// 退出前的同步变体:返回时一切都已落定,不靠 goroutine。
func TestMirrorScrobbleSync(t *testing.T) {
	uts := time.Now().Add(-3 * time.Minute).Unix()
	ctx := context.Background()

	t.Run("成功:标记、不写日志", func(t *testing.T) {
		env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
		env.p.mirrorScrobbleSync(ctx, "A", "S", "", uts, "A", 200)
		if env.requests.Load() != 1 || !env.p.lfmMirrored[uts] || !env.markedBeforeSend.Load() {
			t.Errorf("应先标记再同步发一次: requests=%d", env.requests.Load())
		}
		if k := logKinds(uts); k != "" {
			t.Errorf("成功不写日志,got %q", k)
		}
	})
	t.Run("已标记过:不重发", func(t *testing.T) {
		env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
		env.p.lfmMirrored[uts] = true
		env.p.mirrorScrobbleSync(ctx, "A", "S", "", uts, "A", 200)
		if env.requests.Load() != 0 {
			t.Error("已镜像过的时间戳不该再发")
		}
	})
	t.Run("网络中断:l + q", func(t *testing.T) {
		env := newMirrorPoller(t, func() (string, error) { return "", errors.New("connection reset by peer") })
		env.p.mirrorScrobbleSync(ctx, "A", "S", "", uts, "Raw", 200)
		if k := logKinds(uts); k != "lq" {
			t.Errorf("不确定发没发到应记 lq,got %q", k)
		}
	})
	t.Run("凭据失效:只写 l", func(t *testing.T) {
		env := newMirrorPoller(t, func() (string, error) { return `{"error":9,"message":"Invalid session key"}`, nil })
		env.p.mirrorScrobbleSync(ctx, "A", "S", "", uts, "Raw", 200)
		if k := logKinds(uts); k != "l" {
			t.Errorf("确定没落库应只写 l,got %q", k)
		}
	})
	t.Run("已熔断:不发、不标记、只写 l", func(t *testing.T) {
		env := newMirrorPoller(t, func() (string, error) { return acceptedOne, nil })
		env.p.lfm.dead.Store(true)
		env.p.mirrorScrobbleSync(ctx, "A", "S", "", uts, "Raw", 200)
		if env.requests.Load() != 0 || env.p.lfmMirrored[uts] {
			t.Error("已熔断不该发请求、不该标记")
		}
		if k := logKinds(uts); k != "l" {
			t.Errorf("已熔断这一条确定没写进去,应只写 l,got %q", k)
		}
	})
}
