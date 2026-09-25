package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// runBackfill 真正提交的那条路径。每个用例对应一种回执形状,断言的是本地日志最后留下什么:
// "s" = 已提交不再补,"q" = 隔离永不自动重试,什么都不留 = 下次还会补。判错的两个方向都不可逆
// (永久重复 / 永久漏补),所以断言落在日志上,不只看返回的计数。

// backfillRunEnv 是一次回填测试的隔离环境:临时收听日志、临时 feed 信号文件、原始档写法
// (不联网判定),以及一个记录每次请求表单的假 Last.fm。
type backfillRunEnv struct {
	s     *lastfmScrobbler
	mu    sync.Mutex
	forms []url.Values
}

// setUpBackfillRun 里 reply 拿到这次请求按下标顺序排好的 timestamp,返回响应体或传输层错误。
func setUpBackfillRun(t *testing.T, reply func(ts []string) (string, error)) *backfillRunEnv {
	t.Helper()
	savedLog, savedNudge := listenLogPath, lastfmFeedNudgePath
	t.Cleanup(func() { listenLogPath, lastfmFeedNudgePath = savedLog, savedNudge })
	dir := t.TempDir()
	listenLogPath = filepath.Join(dir, "listens.jsonl")
	lastfmFeedNudgePath = filepath.Join(dir, "feed-nudge")
	setMatch(t, lastfmMatchRaw, false, false, false)

	env := &backfillRunEnv{s: newLastfmScrobbler("key", "secret", "sk")}
	env.s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		env.mu.Lock()
		env.forms = append(env.forms, form)
		env.mu.Unlock()
		var ts []string
		for i := 0; form.Has("timestamp[" + strconv.Itoa(i) + "]"); i++ {
			ts = append(ts, form.Get("timestamp["+strconv.Itoa(i)+"]"))
		}
		resp, err := reply(ts)
		if err != nil {
			return nil, err
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(resp)), Header: http.Header{}}, nil
	})}
	return env
}

func (e *backfillRunEnv) requests() []url.Values {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]url.Values(nil), e.forms...)
}

// receipt 是回执里的一条 <scrobble>;code 为 "0" 表示接受。
func receipt(ts, code string) string {
	return fmt.Sprintf(`{"timestamp":"%s","ignoredMessage":{"code":"%s","#text":"reason %s"}}`, ts, code, code)
}

// scrobblesBody 按 Last.fm 的真实形状拼响应:一条时 scrobble 是对象,多条时是数组。
func scrobblesBody(entries ...string) string {
	scrobble := "[" + strings.Join(entries, ",") + "]"
	if len(entries) == 1 {
		scrobble = entries[0]
	}
	return `{"scrobbles":{"@attr":{"accepted":"0","ignored":"0"},"scrobble":` + scrobble + `}}`
}

func acceptAll(ts []string) (string, error) {
	var entries []string
	for _, x := range ts {
		entries = append(entries, receipt(x, "0"))
	}
	return scrobblesBody(entries...), nil
}

// seedListens 写 n 条回溯窗口内的收听,uts 升序且互不相同,返回这些 uts。
func seedListens(n int) []int64 {
	base := time.Now().Add(-6 * time.Hour).Unix()
	out := make([]int64, n)
	for i := range out {
		out[i] = base + int64(i)*60
		appendListen("Artist", "Song "+strconv.Itoa(i), "Album", out[i], 200)
	}
	return out
}

// receiptMarks 读回日志里每个 uts 的回执标记("s" / "q")。
func receiptMarks() map[int64]string {
	marks := map[int64]string{}
	for _, l := range readListenLog() {
		if l.T == "s" || l.T == "q" {
			marks[l.UTS] = l.T
		}
	}
	return marks
}

func pendingCount() int {
	pending, _ := pendingBackfillListens(time.Now())
	return len(pending)
}

func nudgeTouched() bool {
	_, err := os.Stat(lastfmFeedNudgePath)
	return err == nil
}

// 同一批里三种回执各走各的:接受记 s、明确拒收也记 s(重发同样被拒)但单独计数、
// 回执里找不到的进隔离。未知的 ignored 码不能算接受。
func TestRunBackfillSortsEachReceipt(t *testing.T) {
	var uts []int64
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		return scrobblesBody(receipt(ts[0], "0"), receipt(ts[1], "99")), nil
	})
	uts = seedListens(3)

	out := runBackfill(context.Background(), env.s, false)

	if out.Eligible != 3 || out.Accepted != 1 || out.Ignored != 1 || out.Quarantined != 1 || out.AbortedReason != "" {
		t.Fatalf("计数不对: %+v", out)
	}
	marks := receiptMarks()
	if marks[uts[0]] != "s" || marks[uts[1]] != "s" || marks[uts[2]] != "q" {
		t.Errorf("接受/拒收应记 s、没有回执应记 q,got %v", marks)
	}
	if n := pendingCount(); n != 0 {
		t.Errorf("三条都表过态,不该再留在待补清单里,剩 %d", n)
	}
	if !nudgeTouched() {
		t.Error("补进了东西应通知常驻 collector 重拉 feed")
	}
}

// 提交顺序必须最旧的先发(官方要求缓存的 scrobble 按顺序发),时间戳原样带上。
func TestRunBackfillSubmitsOldestFirst(t *testing.T) {
	env := setUpBackfillRun(t, acceptAll)
	uts := seedListens(3)

	runBackfill(context.Background(), env.s, false)

	reqs := env.requests()
	if len(reqs) != 1 {
		t.Fatalf("3 条应一批发完,发了 %d 次", len(reqs))
	}
	for i, want := range uts {
		if got := reqs[0].Get("timestamp[" + strconv.Itoa(i) + "]"); got != strconv.FormatInt(want, 10) {
			t.Errorf("timestamp[%d] = %s, want %d", i, got, want)
		}
	}
	if reqs[0].Get("method") != "track.scrobble" || reqs[0].Get("api_sig") == "" {
		t.Errorf("批量提交应是签过名的 track.scrobble: %v", reqs[0])
	}
}

// 服务端明确表过态、确定没落库(限流 29、凭据失效 9):停手,但整批留在清单里等下次,
// 一条都不能进隔离 —— 隔离是永久的,用错了就是把没提交过的收听彻底踢出清单。
func TestRunBackfillKeepsBatchPendingWhenServerRefused(t *testing.T) {
	for _, code := range []int{29, 9} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			env := setUpBackfillRun(t, func([]string) (string, error) {
				return fmt.Sprintf(`{"error":%d,"message":"refused"}`, code), nil
			})
			seedListens(3)

			out := runBackfill(context.Background(), env.s, false)

			if out.AbortedReason == "" || out.Quarantined != 0 || out.Accepted != 0 {
				t.Fatalf("应中止且不隔离: %+v", out)
			}
			if marks := receiptMarks(); len(marks) != 0 {
				t.Errorf("确定没落库的不该留任何回执标记,got %v", marks)
			}
			if n := pendingCount(); n != 3 {
				t.Errorf("整批应留在待补清单里,剩 %d", n)
			}
			if nudgeTouched() {
				t.Error("什么都没补进去,不该通知重拉 feed")
			}
		})
	}
}

// 状态未知(服务暂时不可用 11/16、网络错误、回执畸形):可能已经落库,整批进隔离,永不自动重发。
func TestRunBackfillQuarantinesBatchWhenOutcomeUnknown(t *testing.T) {
	cases := []struct {
		name  string
		reply func([]string) (string, error)
	}{
		{"error 11", func([]string) (string, error) { return `{"error":11,"message":"offline"}`, nil }},
		{"error 16", func([]string) (string, error) { return `{"error":16,"message":"try later"}`, nil }},
		{"network", func([]string) (string, error) { return "", errors.New("connection reset by peer") }},
		{"no scrobbles element", func([]string) (string, error) { return `{}`, nil }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := setUpBackfillRun(t, c.reply)
			uts := seedListens(3)

			out := runBackfill(context.Background(), env.s, false)

			if out.AbortedReason == "" || out.Quarantined != 3 || out.Accepted != 0 {
				t.Fatalf("应中止并整批隔离: %+v", out)
			}
			marks := receiptMarks()
			for _, u := range uts {
				if marks[u] != "q" {
					t.Errorf("uts %d 应进隔离,got %q", u, marks[u])
				}
			}
			if n := pendingCount(); n != 0 {
				t.Errorf("隔离后不能再被自动挑走,剩 %d", n)
			}
		})
	}
}

// 超过 50 条分批:前一批的回执已经落盘,后一批失败只影响它自己;最后一批只有一条时
// 回执是对象形式,也要认得出来。
func TestRunBackfillBatchesAndIsolatesLaterFailure(t *testing.T) {
	calls := 0
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		calls++
		if calls == 1 {
			return acceptAll(ts)
		}
		return `{"error":16,"message":"try later"}`, nil
	})
	uts := seedListens(backfillBatchSize + 1)

	out := runBackfill(context.Background(), env.s, false)

	reqs := env.requests()
	if len(reqs) != 2 {
		t.Fatalf("51 条应分两批,发了 %d 次", len(reqs))
	}
	if reqs[1].Get("timestamp[0]") != strconv.FormatInt(uts[backfillBatchSize], 10) || reqs[1].Has("timestamp[1]") {
		t.Errorf("第二批应只含最新那一条: %v", reqs[1])
	}
	if out.Accepted != backfillBatchSize || out.Quarantined != 1 {
		t.Fatalf("计数不对: %+v", out)
	}
	marks := receiptMarks()
	if marks[uts[0]] != "s" || marks[uts[backfillBatchSize-1]] != "s" || marks[uts[backfillBatchSize]] != "q" {
		t.Errorf("第一批应全记 s、第二批那条记 q")
	}
}

// 一条的批次:回执是对象不是数组,接受要认得出来,不能掉进"没有回执 → 隔离"。
func TestRunBackfillSingleItemReceiptIsObject(t *testing.T) {
	env := setUpBackfillRun(t, acceptAll)
	uts := seedListens(1)

	out := runBackfill(context.Background(), env.s, false)

	if out.Accepted != 1 || out.Quarantined != 0 {
		t.Fatalf("单条回执应判为接受: %+v", out)
	}
	if receiptMarks()[uts[0]] != "s" {
		t.Error("单条接受应记 s")
	}
}

// 批间等待时取消:已完成那批照常记账,没发的那批原样留在清单里。
func TestRunBackfillCancelledBetweenBatches(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	env := setUpBackfillRun(t, func(ts []string) (string, error) {
		cancel()
		return acceptAll(ts)
	})
	seedListens(backfillBatchSize + 1)

	out := runBackfill(ctx, env.s, false)

	if out.AbortedReason != "cancelled" || out.Accepted != backfillBatchSize {
		t.Fatalf("应在批间停下: %+v", out)
	}
	if n := len(env.requests()); n != 1 {
		t.Errorf("取消后不该再发第二批,发了 %d 次", n)
	}
	if n := pendingCount(); n != 1 {
		t.Errorf("没发的那条应留在清单里,剩 %d", n)
	}
}

// 没连账号时真跑:直接报原因,日志一行不写、请求一个不发。
func TestRunBackfillWithoutScrobbler(t *testing.T) {
	env := setUpBackfillRun(t, acceptAll)
	seedListens(2)

	out := runBackfill(context.Background(), nil, false)

	if out.AbortedReason != "last.fm not configured" || out.Eligible != 2 {
		t.Fatalf("got %+v", out)
	}
	if len(env.requests()) != 0 || len(receiptMarks()) != 0 {
		t.Error("没连账号不该发请求、不该写回执")
	}
}

// 没有待补的:不发请求。
func TestRunBackfillNothingPending(t *testing.T) {
	env := setUpBackfillRun(t, acceptAll)

	out := runBackfill(context.Background(), env.s, false)

	if out.Eligible != 0 || out.AbortedReason != "" || len(env.requests()) != 0 {
		t.Fatalf("没有待补就不该发请求: %+v, %d 次", out, len(env.requests()))
	}
	if nudgeTouched() {
		t.Error("什么都没补,不该通知重拉 feed")
	}
}
