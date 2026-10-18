package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// withLBStatusFiles:状态文件和未送出留档都指到临时目录,测试结束还原。
func withLBStatusFiles(t *testing.T) (status, unsent string) {
	t.Helper()
	dir := t.TempDir()
	savedUnsent := lbUnsentPath
	lbStatusMu.Lock()
	savedStatus := lbStatusPath
	lbStatusMu.Unlock()
	status, unsent = filepath.Join(dir, "lb-status.json"), filepath.Join(dir, "lb-unsent.jsonl")
	setLBStatusPath(status)
	lbUnsentPath = unsent
	t.Cleanup(func() {
		setLBStatusPath("")
		lbStatusMu.Lock()
		lbStatusPath = savedStatus
		lbStatusMu.Unlock()
		lbUnsentPath = savedUnsent
	})
	return status, unsent
}

// 令牌被拒写状态文件(第一次的时刻,之后不改),提交成功一次就删;引擎启动时也删掉上一次留下的。
func TestLBStatusFileOnAuthRejected(t *testing.T) {
	resetLiveConfigForTest(t)
	status, _ := withLBStatusFiles(t)
	good := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if good {
			w.Write([]byte(`{"status":"ok"}`))
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	c := &lbClient{root: srv.URL, token: "bad", hc: srv.Client()}
	meta := lbTrackMeta{ArtistName: "A", TrackName: "T", AdditionalInfo: map[string]any{}}

	_ = c.submit(context.Background(), "single", 1790000000, meta)
	var f lbStatusFile
	if b, err := os.ReadFile(status); err != nil || json.Unmarshal(b, &f) != nil || f.Kind != "auth" || f.Status != 401 || f.Since == 0 {
		t.Fatalf("令牌被拒要写状态文件: %+v err=%v", f, err)
	}
	c.mu.Lock()
	c.token, good = "good", true
	c.mu.Unlock()
	if err := c.submit(context.Background(), "single", 1790000001, meta); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(status); !os.IsNotExist(err) {
		t.Errorf("提交成功一次就删状态文件: %v", err)
	}

	if err := os.WriteFile(status, []byte(`{"schema":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	setLBStatusPath(status)
	if _, err := os.Stat(status); !os.IsNotExist(err) {
		t.Errorf("启动时删掉上一次留下的: %v", err)
	}
}

// 状态文件的形状跟 App 共用样例一致(Swift 侧 ListenBrainzSubmitStatus 读同一份)。
func TestLBStatusMatchesSharedSample(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "shared", "testdata", "lb-status", "auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(lbStatusFile{Schema: lbStatusSchema, Kind: "auth", Status: 401, Since: 1_800_000_000})
	var want, have any
	if json.Unmarshal(raw, &want) != nil || json.Unmarshal(got, &have) != nil || !reflect.DeepEqual(want, have) {
		t.Errorf("样例 %s,引擎写出 %s", raw, got)
	}
}

// 不会再自动发的收听留档,不静默丢:LB 拒收的(会话结束的、待重发队列里的)、待重发队列装不下被挤出去的。
func TestUnsentLBListensAreKept(t *testing.T) {
	withLBRetryFile(t)
	_, unsent := withLBStatusFiles(t)
	p := &poller{ctx: context.Background(), cfg: &config{}}
	sess := &playSession{key: "k", meta: snapshot{Artist: "歌手", Title: "被拒"}, submitting: true, ended: true, lastfmExcluded: true}
	p.applySubmitOutcome(submitOutcome{sess: sess, meta: sess.meta, artistName: "歌手", startedAt: 100,
		lm: lbTrackMeta{ArtistName: "歌手", TrackName: "被拒"}, err: fmt.Errorf("post single: %w", errListenRejected)})

	enqueueLBRetry(200, lbTrackMeta{ArtistName: "A", TrackName: "队列里被拒"})
	processLBRetry(context.Background(), func(context.Context, int64, lbTrackMeta) error {
		return fmt.Errorf("post single: %w", errListenRejected)
	})

	// 一次写满,再进一条把最老的挤出去(一条条入队每次都重写整份文件,一千次要一秒多)。
	full := make([]lbRetryItem, lbRetryMaxItems)
	for i := range full {
		full[i] = lbRetryItem{ListenedAt: int64(1000 + i), Meta: lbTrackMeta{ArtistName: "A", TrackName: fmt.Sprint(i)}}
	}
	lbRetryMu.Lock()
	saveLBRetryLocked(full)
	lbRetryMu.Unlock()
	enqueueLBRetry(int64(1000+lbRetryMaxItems), lbTrackMeta{ArtistName: "A", TrackName: "最新"})

	file, err := os.Open(unsent)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var got []lbUnsentListen
	sc := bufio.NewScanner(file)
	for sc.Scan() {
		var l lbUnsentListen
		if err := json.Unmarshal(sc.Bytes(), &l); err != nil {
			t.Fatalf("留档每行一条 JSON: %q", sc.Text())
		}
		got = append(got, l)
	}
	if len(got) != 3 {
		t.Fatalf("留 3 条(会话结束被拒、队列里被拒、挤出去的最老一条),got %+v", got)
	}
	want := []struct {
		at     int64
		track  string
		reason string
	}{{100, "被拒", "rejected"}, {200, "队列里被拒", "rejected"}, {1000, "0", "queue_full"}}
	for i, w := range want {
		if got[i].ListenedAt != w.at || got[i].Meta.TrackName != w.track || got[i].Reason != w.reason {
			t.Errorf("第 %d 条: %+v,want %+v", i, got[i], w)
		}
	}
}

// 待重发队列空着时,留档里队列装不下的挪回队列(一次至多 max 条),LB 拒收的留在留档里;队列不空不动。
func TestRefillLBRetryFromUnsent(t *testing.T) {
	withLBRetryFile(t)
	_, unsent := withLBStatusFiles(t)
	keepUnsentLBListen(100, lbTrackMeta{ArtistName: "A", TrackName: "一"}, "queue_full")
	keepUnsentLBListen(200, lbTrackMeta{ArtistName: "A", TrackName: "二"}, "rejected")
	keepUnsentLBListen(300, lbTrackMeta{ArtistName: "A", TrackName: "三"}, "queue_full")
	keepUnsentLBListen(400, lbTrackMeta{ArtistName: "A", TrackName: "四"}, "queue_full")

	if n := refillLBRetryFromUnsent(2); n != 2 {
		t.Fatalf("挪回 2 条,got %d", n)
	}
	lbRetryMu.Lock()
	items := loadLBRetryLocked()
	lbRetryMu.Unlock()
	if len(items) != 2 || items[0].ListenedAt != 100 || items[1].ListenedAt != 300 {
		t.Fatalf("按留档顺序挪回最早的两条: %+v", items)
	}
	if n := refillLBRetryFromUnsent(200); n != 0 {
		t.Errorf("队列不空不动,got %d", n)
	}
	b, err := os.ReadFile(unsent)
	if err != nil {
		t.Fatal(err)
	}
	if s := string(b); strings.Count(s, "\n") != 2 || !strings.Contains(s, `"rejected"`) || !strings.Contains(s, `"listened_at":400`) {
		t.Errorf("留档剩拒收那条和没挪的那条: %q", s)
	}
}
