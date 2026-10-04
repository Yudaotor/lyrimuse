package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

// lbListensServer 模拟 ListenBrainz 收听记录接口:从 max_ts 往前每秒一条,每页满 100 条,一共 total 条。
func lbListensServer(t *testing.T, total int) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var pages atomic.Int32
	const newest = 1_000_000
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pages.Add(1)
		maxTS, _ := strconv.Atoi(r.URL.Query().Get("max_ts"))
		var items []string
		for ts := maxTS - 1; ts > newest-total && len(items) < 100; ts-- {
			items = append(items, fmt.Sprintf(`{"listened_at":%d,"track_metadata":{"track_name":"t","artist_name":"Test Band Alpha"}}`, ts))
		}
		fmt.Fprintf(w, `{"payload":{"listens":[%s]}}`, strings.Join(items, ","))
	}))
	t.Cleanup(srv.Close)
	return srv, &pages
}

// 一周一千多条要翻得完,不能停在 10 页。
func TestListenBrainzDigestCountsPastOneThousand(t *testing.T) {
	srv, _ := lbListensServer(t, 1500)
	stats, err := listenbrainzDigestStats(context.Background(), srv.URL, "u", 0, 1_000_001)
	if err != nil {
		t.Fatal(err)
	}
	if stats.TotalPlays != 1500 || stats.Truncated {
		t.Fatalf("应数全 1500 条且不算截断: total=%d truncated=%v", stats.TotalPlays, stats.Truncated)
	}
	if strings.Contains(digestBody(stats), "以上") {
		t.Error("没截断时不该写「以上」")
	}
}

// 翻到上限还没翻完:标成截断,推送里写明只是一部分。
func TestListenBrainzDigestMarksTruncation(t *testing.T) {
	srv, pages := lbListensServer(t, lbListensMaxPages*100+500)
	stats, err := listenbrainzDigestStats(context.Background(), srv.URL, "u", 0, 1_000_001)
	if err != nil {
		t.Fatal(err)
	}
	if int(pages.Load()) != lbListensMaxPages || !stats.Truncated {
		t.Fatalf("应在 %d 页处停下并标截断: pages=%d truncated=%v", lbListensMaxPages, pages.Load(), stats.Truncated)
	}
	if !strings.Contains(digestBody(stats), fmt.Sprintf("共播放 %d 次以上", lbListensMaxPages*100)) {
		t.Errorf("推送里要写明不完整: %q", digestBody(stats))
	}
}
