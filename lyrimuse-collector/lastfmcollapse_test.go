package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// 折叠判定的回归测试。这套逻辑改动的是**写进 Last.fm 的内容**,而 Last.fm 的纠错/重定向
// 库目前是冻结的(官方 FAQ:"New corrections CANNOT be added to the database")——错了
// 全局补不回来。所以每一条"什么情况下不折叠"都要单独钉死,而不是只测 happy path。
func newTestCollapser(t *testing.T, handler http.HandlerFunc) (*lastfmArtistCollapser, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return &lastfmArtistCollapser{
		apiKey:  "k",
		baseURL: srv.URL,
		hc:      srv.Client(),
		cache:   map[string]lastfmCollapseDecision{},
	}, srv
}

func trackJSON(mbid string, listeners int) string {
	return fmt.Sprintf(`{"track":{"name":"t","mbid":%q,"listeners":"%d"}}`, mbid, listeners)
}

func TestCollapseDecisions(t *testing.T) {
	cases := []struct {
		name     string
		artist   string
		body     string
		status   int
		want     string
		wantCall bool
	}{
		{
			name: "有 mbid 的正规合体署名:一个字节都不动",
			// 《Scream》是 MJ 和 Janet 共同署名的单曲,Last.fm 编目里就有这个条目。
			artist: "Michael Jackson & Janet Jackson", body: trackJSON("f1e2d3", 24707),
			want: "Michael Jackson & Janet Jackson", wantCall: true,
		},
		{
			name:   "无 mbid 但听众够多:仍然不动(两个信号都要满足才折叠)",
			artist: "Hall & Oates", body: trackJSON("", lastfmShadowListenersMax),
			want: "Hall & Oates", wantCall: true,
		},
		{
			name:   "无 mbid 且听众极少:影子条目,折叠成第一位",
			artist: "汪苏泷 & 荷莉", body: trackJSON("", 1),
			want: "汪苏泷", wantCall: true,
		},
		{
			name:   "差一个听众到阈值:仍然折叠",
			artist: "汪苏泷 & 荷莉", body: trackJSON("", lastfmShadowListenersMax-1),
			want: "汪苏泷", wantCall: true,
		},
		{
			name:   "这个艺人串下压根没有这首歌(error 6):折叠",
			artist: "汪苏泷 & By2", body: `{"error":6,"message":"Track not found"}`,
			want: "汪苏泷", wantCall: true,
		},
		{
			name:   "被限流(429):判不出就维持原样,绝不猜",
			artist: "汪苏泷 & 荷莉", body: `{}`, status: http.StatusTooManyRequests,
			want: "汪苏泷 & 荷莉", wantCall: true,
		},
		{
			name:   "响应是坏 JSON:同样维持原样",
			artist: "汪苏泷 & 荷莉", body: `not json`,
			want: "汪苏泷 & 荷莉", wantCall: true,
		},
		{
			name:   "听众数字段不是数字:按'有'处理,不折叠",
			artist: "汪苏泷 & 荷莉", body: `{"track":{"mbid":"","listeners":"n/a"}}`,
			want: "汪苏泷 & 荷莉", wantCall: true,
		},
		{
			name:   "单一艺人:根本不该打网络",
			artist: "Michael Jackson", body: trackJSON("", 1),
			want: "Michael Jackson", wantCall: false,
		},
		{
			name: "结尾带分隔符的单人名:切完只剩一段,不算合唱,也不打网络",
			// 网易云出现过艺人字段就是"周杰伦、"的仿冒条目,见 artistCreditParts 的注释。
			artist: "周杰伦、", body: trackJSON("", 1),
			want: "周杰伦、", wantCall: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var calls int32
			col, _ := newTestCollapser(t, func(w http.ResponseWriter, r *http.Request) {
				atomic.AddInt32(&calls, 1)
				if c.status != 0 {
					w.WriteHeader(c.status)
				}
				fmt.Fprint(w, c.body)
			})
			got := col.resolve(context.Background(), c.artist, "某首歌")
			if got != c.want {
				t.Errorf("resolve = %q, want %q", got, c.want)
			}
			if made := atomic.LoadInt32(&calls) > 0; made != c.wantCall {
				t.Errorf("发起网络请求 = %v, want %v", made, c.wantCall)
			}
		})
	}
}

// 判定结果要缓存:同一首歌反复播放不能每次都打一次 API(Last.fm 的速率限制是按 key 算的)。
func TestCollapseCachesDecision(t *testing.T) {
	var calls int32
	col, _ := newTestCollapser(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		fmt.Fprint(w, trackJSON("", 1))
	})
	for i := 0; i < 3; i++ {
		if got := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷" {
			t.Fatalf("第 %d 次 resolve = %q", i, got)
		}
	}
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Errorf("打了 %d 次 API,应该只有 1 次", n)
	}
}

// 查询失败**不能**被缓存 —— 否则一次偶发限流会把这条记录钉死一个月。
func TestCollapseDoesNotCacheFailures(t *testing.T) {
	var calls int32
	col, _ := newTestCollapser(t, func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		fmt.Fprint(w, trackJSON("", 1))
	})
	if got := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷 & 荷莉" {
		t.Fatalf("限流时应维持原样,got %q", got)
	}
	if got := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷" {
		t.Fatalf("下一次应该重查并折叠,got %q", got)
	}
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Errorf("应该重查一次,实际打了 %d 次", n)
	}
}

// 同一个合唱串在不同歌上可能一个是正规条目、一个是影子条目 —— 缓存键必须带歌名。
func TestCollapseCacheKeyIncludesTrack(t *testing.T) {
	col, _ := newTestCollapser(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("track") == "正规歌" {
			fmt.Fprint(w, trackJSON("mb-1", 90000))
			return
		}
		fmt.Fprint(w, trackJSON("", 2))
	})
	if got := col.resolve(context.Background(), "A & B", "正规歌"); got != "A & B" {
		t.Errorf("正规条目应保留,got %q", got)
	}
	if got := col.resolve(context.Background(), "A & B", "冷门歌"); got != "A" {
		t.Errorf("影子条目应折叠,got %q", got)
	}
}

// nil collapser(没配只读 api_key)必须整体退化成"按原样提交",不能 panic。
func TestCollapseNilIsPassthrough(t *testing.T) {
	var col *lastfmArtistCollapser
	if got := col.resolve(context.Background(), "A & B", "某首歌"); got != "A & B" {
		t.Errorf("nil collapser 应原样返回,got %q", got)
	}
	if newLastfmArtistCollapser("") != nil {
		t.Error("空 api_key 应返回 nil")
	}
}

// 过期的缓存条目要重查,不能一直用一年前的判定。
func TestCollapseCacheExpires(t *testing.T) {
	var calls int32
	col, _ := newTestCollapser(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		fmt.Fprint(w, trackJSON("", 1))
	})
	col.cache["A & B\n某首歌"] = lastfmCollapseDecision{
		Artist: "A & B",
		TS:     time.Now().Add(-lastfmCollapseTTL - time.Hour).Unix(),
	}
	if got := col.resolve(context.Background(), "A & B", "某首歌"); got != "A" {
		t.Errorf("过期后应重查并折叠,got %q", got)
	}
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Errorf("应该重查一次,实际 %d 次", n)
	}
}
