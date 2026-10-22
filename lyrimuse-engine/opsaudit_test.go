package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 15 章运维与后台审计:出站闸按墙钟、额度存盘与读回、合并按档位、监听停了退回、报告去重认同一期、推送不跟改 GET 的
// 重定向、月报各榜同一期、时长按比例补、预览缓存清理。

// 出站闸的时刻不带单调读数:macOS 上单调时钟睡眠时不走,带着的话合盖前用光的额度醒来还要再等满一小时。
func TestHostGuardClockIsWallClock(t *testing.T) {
	g := newHostGuard(time.Now)
	if now := g.now(); strings.Contains(now.String(), "m=") {
		t.Fatalf("出站闸的时刻应去掉单调读数: %s", now)
	}
}

// 读回的额度记录:比此刻还晚的丢掉,剩下的排好序。
func TestSourceBudgetFileDropsFutureAndSorts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "budget.json")
	now := time.Unix(1_800_000_000, 0)
	saved := map[string][]int64{"musixmatch": {
		now.Add(-10 * time.Minute).UnixMilli(), now.Add(-50 * time.Minute).UnixMilli(), now.Add(time.Hour).UnixMilli(),
	}}
	data, _ := json.Marshal(saved)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	g := newHostGuard(func() time.Time { return now })
	g.useSourceBudgetFile(path)
	hits := g.sourceHits["musixmatch"]
	if len(hits) != 2 || !hits[0].Before(hits[1]) {
		t.Fatalf("应丢掉将来的那条、按先后排: %v", hits)
	}
	src, err := os.ReadFile("sourcebudget.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "g.budgetSaveMu.Lock()\n defer g.budgetSaveMu.Unlock()\n g.mu.Lock()\n now := g.now()") {
		t.Error("取快照和写文件要在同一把存盘锁里")
	}
}

// 同一个地址,前台和后台两档不合并:前台不跟着后台那一个排出站闸的队。
func TestHTTPCoalesceKeySeparatesLanes(t *testing.T) {
	saved := httpCoalesceHostOK
	httpCoalesceHostOK = func(string) bool { return true }
	t.Cleanup(func() { httpCoalesceHostOK = saved })
	fg, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://example.test/lyrics?id=1", nil)
	bg, _ := http.NewRequestWithContext(withBackgroundOutbound(context.Background()), http.MethodGet, "https://example.test/lyrics?id=1", nil)
	kf, ok1 := httpCoalesceKey(fg)
	kb, ok2 := httpCoalesceKey(bg)
	if !ok1 || !ok2 || kf == kb {
		t.Fatalf("两档应各自一个合并键: %q / %q", kf, kb)
	}
	fg2, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://example.test/lyrics?id=1", nil)
	if k, _ := httpCoalesceKey(fg2); k != kf {
		t.Fatal("同一档同一个地址照旧合并")
	}
}

// 请求目录的监听停了(目录删掉):定时器退回按 poll 的节拍,不停在 10 秒兜底。
func TestRequestWakeupsFallsBackWhenWatchStops(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "requests")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_, ticker := requestWakeups(ctx, dir, 20*time.Millisecond)
	defer ticker.Stop()
	if err := os.Remove(dir); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ticker.C:
	case <-time.After(3 * time.Second):
		t.Fatal("监听停了之后应按 poll 叫醒")
	}
	src, err := os.ReadFile("companionlaunch.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "case <-watchStopped:") {
		t.Error("伴随启动的循环也要在监听停了时退回常规节拍")
	}
}

// 共享冷却文件解不开时记一行,不无声。
func TestSharedCooldownDecodeFailureIsLogged(t *testing.T) {
	src, err := os.ReadFile("sharedcooldown.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "if err := json.Unmarshal(data, &f); err != nil {\n noteFileErr(\"decode\", path, err)") {
		t.Error("readSharedCooldownFile 解码失败要 noteFileErr")
	}
}

// 日报过了零点标题从「今日」变「昨日」:还认得是同一期,补推和重发不再推第二份。
func TestNotifyDeliveredSinceMatchesSameDigestAcrossMidnight(t *testing.T) {
	saved := notifyLogPath
	notifyLogPath = filepath.Join(t.TempDir(), "log.json")
	t.Cleanup(func() { notifyLogPath = saved })
	ch := notifyChannel{ID: "c1", Platform: platformBark}
	recordNotifyDelivery(ch, notifyMessage{Event: "daily_digest", Title: "🎧 今日听歌报告（10-22）"}, notifyResult{OK: true, Kind: notifyKindOK})
	since := time.Now().Add(-time.Hour).Unix()
	if !notifyDeliveredSince("c1", "daily_digest", "🎧 昨日听歌报告（10-22）", since) {
		t.Error("同一天的「昨日」应认作已推")
	}
	if !notifyDeliveredSince("c1", "daily_digest", "🎧 听歌报告（10-22）", since) {
		t.Error("不带前缀的同一天也认作已推")
	}
	if notifyDeliveredSince("c1", "daily_digest", "🎧 今日听歌报告（10-23）", since) {
		t.Error("另一天不算")
	}
}

// 推送的 client 不跟 301 / 302 / 303(会把 POST 改成 GET),307 / 308 照跟。
func TestNotifyHTTPClientRedirects(t *testing.T) {
	var methods []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/moved":
			http.Redirect(w, r, "/final", http.StatusMovedPermanently)
		case "/temp":
			http.Redirect(w, r, "/final", http.StatusTemporaryRedirect)
		case "/final":
			methods = append(methods, r.Method)
			fmt.Fprint(w, `{"code":0}`)
		}
	}))
	t.Cleanup(srv.Close)
	resp, err := notifyHTTPClient.Post(srv.URL+"/moved", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMovedPermanently || len(methods) != 0 {
		t.Fatalf("301 不跟: status=%d methods=%v", resp.StatusCode, methods)
	}
	resp, err = notifyHTTPClient.Post(srv.URL+"/temp", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || len(methods) != 1 || methods[0] != http.MethodPost {
		t.Fatalf("307 照跟、方法不变: status=%d methods=%v", resp.StatusCode, methods)
	}
}

// ListenBrainz 月报:专辑榜、歌曲榜还停在上一期时这一期算没出。
func TestLBStatsDigestWaitsForEveryChart(t *testing.T) {
	aug := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC).Unix()
	jul := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC).Unix()
	for _, entity := range []string{"releases", "recordings"} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			from := aug
			if strings.HasSuffix(r.URL.Path, "/"+entity) {
				from = jul
			}
			switch {
			case strings.HasSuffix(r.URL.Path, "/artists"):
				fmt.Fprintf(w, `{"payload":{"from_ts":%d,"total_artist_count":1,"artists":[{"artist_name":"X","listen_count":3}]}}`, from)
			case strings.HasSuffix(r.URL.Path, "/releases"):
				fmt.Fprintf(w, `{"payload":{"from_ts":%d,"releases":[{"release_name":"R","artist_name":"X","listen_count":3}]}}`, from)
			case strings.HasSuffix(r.URL.Path, "/recordings"):
				fmt.Fprintf(w, `{"payload":{"from_ts":%d,"recordings":[{"track_name":"t","artist_name":"X","listen_count":3}]}}`, from)
			}
		}))
		_, ready, err := lbStatsDigest(t.Context(), srv.URL, "u", calendarDigestMonthly, "2026-08")
		srv.Close()
		if err != nil || ready {
			t.Errorf("%s 还是上一期时不该算出了: ready=%v err=%v", entity, ready, err)
		}
	}
}

// ListenBrainz 日报 / 周报的时长:没带时长的按带了的平均补;带时长的不到三成就不写。
func TestDigestStatsFromListensEstimatesDuration(t *testing.T) {
	mk := func(withDur, without int) []lbListenEntry {
		var out []lbListenEntry
		for range withDur {
			out = append(out, lbListenEntry{Title: "t", Artist: "a", DurationMs: 200000})
		}
		for range without {
			out = append(out, lbListenEntry{Title: "t", Artist: "a"})
		}
		return out
	}
	s := digestStatsFromListens(mk(4, 6))
	if s.TotalDurationMs != 10*200000 || !s.DurationEstimated {
		t.Errorf("4 条带时长、6 条没带:按平均补到 10 条, got %d estimated=%v", s.TotalDurationMs, s.DurationEstimated)
	}
	if s := digestStatsFromListens(mk(5, 0)); s.TotalDurationMs != 5*200000 || s.DurationEstimated {
		t.Errorf("都带了就是实数, got %d estimated=%v", s.TotalDurationMs, s.DurationEstimated)
	}
	if s := digestStatsFromListens(mk(2, 8)); s.TotalDurationMs != 0 {
		t.Errorf("不到三成不写, got %d", s.TotalDurationMs)
	}
}

// 预览缓存:写进去的不带原始收听,过期的顺手删掉。
func TestDigestPreviewCacheKeepsOnlyShownFields(t *testing.T) {
	src, err := os.ReadFile("digestpreview.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "kept.listens, kept.chartTracks, kept.chartArtists = nil, nil, nil") ||
		!containsCode(string(src), "if now.Sub(time.Unix(v.At, 0)) >= digestPreviewTTL {\n delete(digestPreviewCache, k)") {
		t.Error("预览缓存要去掉原始数据、删掉过期条目")
	}
}
