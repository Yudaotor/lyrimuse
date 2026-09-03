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
	"sync"
	"testing"
	"time"
)

// 「智能」档判定的回归测试。这套逻辑改动的是**写进 Last.fm 的内容**,而 Last.fm 的纠错/重定向
// 库目前是冻结的(官方 FAQ:"New corrections CANNOT be added to the database")——错了全局
// 补不回来。所以每一条"什么情况下不折叠"都要单独钉死,而不是只测 happy path;每一条"结论
// 不再变"也要钉死 —— 2026-08-31 删掉上一版的理由正是"同一首歌两次运行发出不同的名字"。

// probeResp 是假 Last.fm 对某个 artist 参数的固定应答。
type probeResp struct {
	status int
	body   string
}

// catalogServer 起一个按 artist 参数分发应答的假 Last.fm,并记下每个 artist 被查了几次。
type catalogServer struct {
	srv   *httptest.Server
	mu    sync.Mutex
	calls map[string]int
	raw   []string // 每次请求的 RawQuery,给编码断言用
}

func newCatalogServer(t *testing.T, responses map[string]probeResp) (*lastfmArtistCollapser, *catalogServer) {
	t.Helper()
	cs := &catalogServer{calls: map[string]int{}}
	cs.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		artist := r.URL.Query().Get("artist")
		cs.mu.Lock()
		cs.calls[artist]++
		cs.raw = append(cs.raw, r.URL.RawQuery)
		cs.mu.Unlock()
		resp, ok := responses[artist]
		if !ok {
			t.Errorf("假 Last.fm 收到没预设应答的 artist=%q", artist)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if resp.status != 0 {
			w.WriteHeader(resp.status)
		}
		fmt.Fprint(w, resp.body)
	}))
	t.Cleanup(cs.srv.Close)
	return &lastfmArtistCollapser{
		apiKey:  "k",
		baseURL: cs.srv.URL,
		hc:      cs.srv.Client(),
		cache:   map[string]lastfmCollapseDecision{},
	}, cs
}

func (cs *catalogServer) count(artist string) int {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.calls[artist]
}

func (cs *catalogServer) total() int {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	n := 0
	for _, c := range cs.calls {
		n += c
	}
	return n
}

func trackJSON(mbid string, listeners, durationMS int) string {
	return fmt.Sprintf(`{"track":{"name":"t","mbid":%q,"listeners":"%d","duration":"%d"}}`, mbid, listeners, durationMS)
}

const (
	notFoundJSON = `{"error":6,"message":"Track not found"}`
	// 影子条目的典型形态:没 mbid、一个听众、时长 0。
	shadowJSON = `{"track":{"name":"t","mbid":"","listeners":"1","duration":"0"}}`
)

func TestCollapseDecisionMatrix(t *testing.T) {
	const joint, primary = "汪苏泷 & 荷莉", "汪苏泷"
	cases := []struct {
		name        string
		jointResp   probeResp
		primaryResp probeResp
		want        string
		wantVerdict collapseVerdict // "" = 不该写缓存
		wantPrimary bool            // 是否该查第二步
	}{
		{
			name: "合唱串有 mbid:正规合体署名,一个字节都不动,也不查第二步",
			// 《Scream》是 MJ 和 Janet 共同署名的单曲,Last.fm 编目里就有这个条目。
			jointResp: probeResp{body: trackJSON("f1e2d3", 24707, 278000)},
			want:      joint, wantVerdict: verdictKeep,
		},
		{
			name:      "合唱串无 mbid 但听众够多:仍然不动",
			jointResp: probeResp{body: trackJSON("", lastfmCatalogListenersMin, 0)},
			want:      joint, wantVerdict: verdictKeep,
		},
		{
			name:      "合唱串无 mbid、听众少、但有时长:编目有元数据,不是影子,不动",
			jointResp: probeResp{body: trackJSON("", 12, 213000)},
			want:      joint, wantVerdict: verdictKeep,
		},
		{
			name:        "合唱串是影子条目 + 第一位名下这首歌已收录:折叠",
			jointResp:   probeResp{body: shadowJSON},
			primaryResp: probeResp{body: trackJSON("", 1200, 166000)},
			want:        primary, wantVerdict: verdictCollapse, wantPrimary: true,
		},
		{
			name:        "合唱串下压根没有这首歌(error 6) + 目标已收录:折叠",
			jointResp:   probeResp{body: notFoundJSON},
			primaryResp: probeResp{body: trackJSON("mb-9", 3, 0)},
			want:        primary, wantVerdict: verdictCollapse, wantPrimary: true,
		},
		{
			name:        "差一个听众到阈值、其余为零:算影子;目标收录:折叠",
			jointResp:   probeResp{body: trackJSON("", lastfmCatalogListenersMin-1, 0)},
			primaryResp: probeResp{body: trackJSON("", lastfmCatalogListenersMin, 0)},
			want:        primary, wantVerdict: verdictCollapse, wantPrimary: true,
		},
		{
			name:        "合唱串没收录、目标也没收录(两边都查不到):维持原样,记 defer",
			jointResp:   probeResp{body: notFoundJSON},
			primaryResp: probeResp{body: notFoundJSON},
			want:        joint, wantVerdict: verdictDefer, wantPrimary: true,
		},
		{
			name:        "合唱串是影子、目标也是影子:维持原样,记 defer(不把影子从合体页挪到单人页)",
			jointResp:   probeResp{body: shadowJSON},
			primaryResp: probeResp{body: shadowJSON},
			want:        joint, wantVerdict: verdictDefer, wantPrimary: true,
		},
		{
			name:      "第一步被限流(429):判不出就维持原样,不缓存,不查第二步",
			jointResp: probeResp{status: http.StatusTooManyRequests, body: `{}`},
			want:      joint,
		},
		{
			name:      "第一步 API 限流(error 29):同上",
			jointResp: probeResp{body: `{"error":29,"message":"Rate limit exceeded"}`},
			want:      joint,
		},
		{
			name:      "第一步响应是坏 JSON:维持原样,不缓存",
			jointResp: probeResp{body: `not json`},
			want:      joint,
		},
		{
			name:      "error 6 但不是 not found(参数问题):不是'没收录',当没查成",
			jointResp: probeResp{body: `{"error":6,"message":"Invalid parameters - Your request is missing a required parameter"}`},
			want:      joint,
		},
		{
			name:      "听众数字段不是数字:信号不可信,当没查成、不缓存",
			jointResp: probeResp{body: `{"track":{"mbid":"","listeners":"n/a","duration":"0"}}`},
			want:      joint,
		},
		{
			name:        "第二步失败(5xx):第一步已知没收录,但目标查不动 → 维持原样、不缓存",
			jointResp:   probeResp{body: notFoundJSON},
			primaryResp: probeResp{status: http.StatusBadGateway, body: ``},
			want:        joint, wantPrimary: true,
		},
		{
			name:        "4xx 状态码带 not found 正文:仍是确定答案",
			jointResp:   probeResp{status: http.StatusBadRequest, body: notFoundJSON},
			primaryResp: probeResp{body: trackJSON("mb-1", 0, 0)},
			want:        primary, wantVerdict: verdictCollapse, wantPrimary: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			col, cs := newCatalogServer(t, map[string]probeResp{joint: c.jointResp, primary: c.primaryResp})
			got := col.resolve(context.Background(), joint, "吵架歌")
			if got != c.want {
				t.Errorf("resolve = %q, want %q", got, c.want)
			}
			if n := cs.count(joint); n != 1 {
				t.Errorf("合唱串查了 %d 次,应为 1", n)
			}
			if made := cs.count(primary) > 0; made != c.wantPrimary {
				t.Errorf("查了第二步 = %v, want %v", made, c.wantPrimary)
			}
			d, cached := col.cache[joint+"\n吵架歌"]
			if c.wantVerdict == "" {
				if cached {
					t.Errorf("没查成的结果不该进缓存,却写了 %+v", d)
				}
				return
			}
			if !cached {
				t.Fatalf("应该写缓存(verdict %s),却没有", c.wantVerdict)
			}
			if d.Verdict != c.wantVerdict || d.Artist != c.want {
				t.Errorf("缓存 = %s/%q, want %s/%q", d.Verdict, d.Artist, c.wantVerdict, c.want)
			}
			if d.Joint == nil {
				t.Error("缓存里应留下第一步的判据")
			}
			if c.wantPrimary && d.Primary == nil {
				t.Error("缓存里应留下第二步的判据")
			}
		})
	}
}

// 不是合唱串的输入根本不该打网络 —— 包括切不开的 `/` 名字(K/DA 那次事故的另一道防线)。
func TestCollapseSkipsNonJointCredits(t *testing.T) {
	for _, artist := range []string{"Michael Jackson", "周杰伦、", "K/DA", "AC/DC", "", "   "} {
		col, cs := newCatalogServer(t, map[string]probeResp{})
		if got := col.resolve(context.Background(), artist, "某首歌"); got != artist {
			t.Errorf("%q 应原样返回,got %q", artist, got)
		}
		if n := cs.total(); n != 0 {
			t.Errorf("%q 不该打网络,却打了 %d 次", artist, n)
		}
	}
	// 歌名为空也不查:track.getInfo 没有歌名就是无效请求。
	col, cs := newCatalogServer(t, map[string]probeResp{})
	if got := col.resolve(context.Background(), "A & B", ""); got != "A & B" {
		t.Errorf("空歌名应原样返回,got %q", got)
	}
	if cs.total() != 0 {
		t.Error("空歌名不该打网络")
	}
}

// 结论要缓存:同一首歌反复播放(now-playing + scrobble 各一次,再下次播放)只打一轮 API,
// 而且**每次都是同一个名字** —— 这就是 now-playing 与 scrobble 一致性的来源。
func TestCollapseCachesDecisionAndStaysConsistent(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		"汪苏泷 & 荷莉": {body: shadowJSON},
		"汪苏泷":      {body: trackJSON("", 1200, 166000)},
	})
	for i := 0; i < 4; i++ {
		if got := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷" {
			t.Fatalf("第 %d 次 resolve = %q", i, got)
		}
	}
	if n := cs.total(); n != 2 {
		t.Errorf("打了 %d 次 API,应该只有第一轮的 2 次", n)
	}
}

// 已有结论**永不翻面**:哪怕 Last.fm 那边后来变了(合唱串被收录了 / 听众涨过阈值了),
// 已经折过的继续折、已经保留的继续保留 —— 否则用户自己的历史会被劈成两半。
func TestCollapseKeepAndCollapseArePermanent(t *testing.T) {
	// 服务器现在说合唱串是正规条目;但缓存里两年前就判了 collapse。
	col, cs := newCatalogServer(t, map[string]probeResp{
		"A & B": {body: trackJSON("mb-now", 99999, 200000)},
		"A":     {body: trackJSON("mb-a", 99999, 200000)},
	})
	twoYearsAgo := time.Now().Add(-2 * 365 * 24 * time.Hour).Unix()
	col.cache["A & B\n某首歌"] = lastfmCollapseDecision{Verdict: verdictCollapse, Artist: "A", TS: twoYearsAgo}
	col.cache["C & D\n某首歌"] = lastfmCollapseDecision{Verdict: verdictKeep, Artist: "C & D", TS: twoYearsAgo}
	if got := col.resolve(context.Background(), "A & B", "某首歌"); got != "A" {
		t.Errorf("collapse 结论应永久沿用,got %q", got)
	}
	if got := col.resolve(context.Background(), "C & D", "某首歌"); got != "C & D" {
		t.Errorf("keep 结论应永久沿用,got %q", got)
	}
	if n := cs.total(); n != 0 {
		t.Errorf("永久结论不该重查,却打了 %d 次", n)
	}
}

// defer(两边都没收录)不是结论:到期要重查,目标条目这时候被收录了就该折;没到期不查。
func TestCollapseDeferRechecksAfterWindow(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		"A & B": {body: notFoundJSON},
		"A":     {body: trackJSON("mb-a", 3, 0)}, // 现在已收录
	})
	fresh := time.Now().Add(-lastfmCollapseDeferRecheck + time.Hour).Unix()
	col.cache["A & B\n某首歌"] = lastfmCollapseDecision{Verdict: verdictDefer, Artist: "A & B", TS: fresh}
	if got := col.resolve(context.Background(), "A & B", "某首歌"); got != "A & B" {
		t.Errorf("未到期的 defer 应维持原样,got %q", got)
	}
	if n := cs.total(); n != 0 {
		t.Fatalf("未到期不该重查,却打了 %d 次", n)
	}

	stale := time.Now().Add(-lastfmCollapseDeferRecheck - time.Hour).Unix()
	col.cache["A & B\n某首歌"] = lastfmCollapseDecision{Verdict: verdictDefer, Artist: "A & B", TS: stale}
	if got := col.resolve(context.Background(), "A & B", "某首歌"); got != "A" {
		t.Errorf("到期重查、目标已收录 → 应折叠,got %q", got)
	}
	if d := col.cache["A & B\n某首歌"]; d.Verdict != verdictCollapse {
		t.Errorf("重查后应升格为 collapse,got %s", d.Verdict)
	}
	if n := cs.total(); n != 2 {
		t.Errorf("到期重查应打 2 次,实际 %d", n)
	}
}

// 查询失败**不能**被缓存 —— 否则一次偶发限流会把这条记录钉死;下一次要重查、且两步都重来。
func TestCollapseDoesNotCacheFailures(t *testing.T) {
	var jointCalls int
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Query().Get("artist") {
		case "汪苏泷 & 荷莉":
			mu.Lock()
			jointCalls++
			n := jointCalls
			mu.Unlock()
			if n == 1 {
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			fmt.Fprint(w, shadowJSON)
		case "汪苏泷":
			fmt.Fprint(w, trackJSON("", 1200, 166000))
		}
	}))
	t.Cleanup(srv.Close)
	col := &lastfmArtistCollapser{apiKey: "k", baseURL: srv.URL, hc: srv.Client(), cache: map[string]lastfmCollapseDecision{}}
	if got := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷 & 荷莉" {
		t.Fatalf("限流时应维持原样,got %q", got)
	}
	if _, cached := col.cache["汪苏泷 & 荷莉\n吵架歌"]; cached {
		t.Fatal("失败不该进缓存")
	}
	if got := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷" {
		t.Fatalf("下一次应该重查并折叠,got %q", got)
	}
}

// 同一个合唱串在不同歌上可能一个是正规条目、一个是影子条目 —— 缓存键必须带歌名。
func TestCollapseCacheKeyIncludesTrack(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		switch {
		case q.Get("artist") == "A & B" && q.Get("track") == "正规歌":
			fmt.Fprint(w, trackJSON("mb-1", 90000, 0))
		case q.Get("artist") == "A & B":
			fmt.Fprint(w, shadowJSON)
		case q.Get("artist") == "A":
			fmt.Fprint(w, trackJSON("mb-a", 5000, 0))
		}
	}))
	t.Cleanup(srv.Close)
	col := &lastfmArtistCollapser{apiKey: "k", baseURL: srv.URL, hc: srv.Client(), cache: map[string]lastfmCollapseDecision{}}
	if got := col.resolve(context.Background(), "A & B", "正规歌"); got != "A & B" {
		t.Errorf("正规条目应保留,got %q", got)
	}
	if got := col.resolve(context.Background(), "A & B", "冷门歌"); got != "A" {
		t.Errorf("影子条目应折叠,got %q", got)
	}
}

// 请求形态:method/autocorrect 固定;第二步查的是 firstCreditedArtist 切出来的第一位;
// 含 `+`/`%` 的歌名要按 lastfmGetQuery 双重编码(2026-08-22 真实事故:标准编码让含加号的
// 歌名一律 error 6,而 error 6 在这里意味着"可能折叠")。
func TestCollapseRequestShape(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		"陶喆、卢广仲": {body: notFoundJSON},
		"陶喆":     {body: trackJSON("mb-t", 8000, 0)},
	})
	if got := col.resolve(context.Background(), "陶喆、卢广仲", "夜曲+窃爱 (Live) 100%"); got != "陶喆" {
		t.Fatalf("resolve = %q", got)
	}
	cs.mu.Lock()
	raws := append([]string(nil), cs.raw...)
	cs.mu.Unlock()
	if len(raws) != 2 {
		t.Fatalf("应有 2 个请求,实际 %d", len(raws))
	}
	for i, raw := range raws {
		for _, want := range []string{"method=track.getInfo", "autocorrect=1", "format=json", "api_key=k"} {
			if !strings.Contains(raw, want) {
				t.Errorf("请求 %d 缺 %q: %s", i, want, raw)
			}
		}
		// `+` → %252B、`%` → %2525(双重编码);绝不能出现裸的 %2B。
		if !strings.Contains(raw, "%252B") || !strings.Contains(raw, "%2525") {
			t.Errorf("请求 %d 的歌名没有按 Last.fm GET 口径双重编码: %s", i, raw)
		}
		if strings.Contains(raw, "track=%E5%A4%9C%E6%9B%B2%2B") {
			t.Errorf("请求 %d 出现了单层编码的 %%2B: %s", i, raw)
		}
	}
}

// nil 判定器(没配只读 api_key)必须整体退化成"按原样提交",不能 panic。
func TestCollapseNilIsPassthrough(t *testing.T) {
	var col *lastfmArtistCollapser
	if got := col.resolve(context.Background(), "A & B", "某首歌"); got != "A & B" {
		t.Errorf("nil 判定器应原样返回,got %q", got)
	}
	if newLastfmArtistCollapser("") != nil {
		t.Error("空 api_key 应返回 nil")
	}
}

// 落盘往返:结论带 verdict/判据写进文件;重新构造能读回;2026-08 老格式(没有 verdict、
// 只做了第一步)的条目要被丢掉重判,不能直接升格成永久结论。
func TestCollapseCachePersistence(t *testing.T) {
	saved := lastfmCollapsePath
	t.Cleanup(func() { lastfmCollapsePath = saved })
	lastfmCollapsePath = filepath.Join(t.TempDir(), "collapse.json")

	// 先写一份混合内容:一条老格式 + 一条新格式。
	seed := map[string]any{
		"Old & Format\n某首歌": map[string]any{"artist": "Old", "ts": time.Now().Unix()},
		"C & D\n某首歌":        lastfmCollapseDecision{Verdict: verdictKeep, Artist: "C & D", TS: time.Now().Unix()},
	}
	data, _ := json.Marshal(seed)
	if err := os.WriteFile(lastfmCollapsePath, data, 0o644); err != nil {
		t.Fatal(err)
	}

	col := newLastfmArtistCollapser("k")
	if col == nil {
		t.Fatal("有 api_key 应构造成功")
	}
	if _, ok := col.cache["Old & Format\n某首歌"]; ok {
		t.Error("老格式条目应被丢掉")
	}
	if d, ok := col.cache["C & D\n某首歌"]; !ok || d.Verdict != verdictKeep {
		t.Errorf("新格式条目应读回,got %+v ok=%v", d, ok)
	}

	// 写一条新结论,文件里应能看到 verdict 和判据。
	col.store("A & B\n某首歌", lastfmCollapseDecision{
		Verdict: verdictCollapse, Artist: "A",
		Joint:   &lastfmCatalogProbe{Found: false},
		Primary: &lastfmCatalogProbe{Found: true, MBID: "mb-a", Listeners: 3},
	})
	raw, err := os.ReadFile(lastfmCollapsePath)
	if err != nil {
		t.Fatal(err)
	}
	var onDisk map[string]lastfmCollapseDecision
	if err := json.Unmarshal(raw, &onDisk); err != nil {
		t.Fatalf("落盘不是合法 JSON: %v", err)
	}
	d := onDisk["A & B\n某首歌"]
	if d.Verdict != verdictCollapse || d.Artist != "A" || d.TS == 0 || d.Joint == nil || d.Primary == nil || d.Primary.MBID != "mb-a" {
		t.Errorf("落盘内容不对: %+v", d)
	}
	if _, ok := onDisk["C & D\n某首歌"]; !ok {
		t.Error("原有条目应一起保留")
	}
	// 没有残留的临时文件。
	if leftovers, _ := filepath.Glob(lastfmCollapsePath + ".tmp.*"); len(leftovers) != 0 {
		t.Errorf("残留临时文件: %v", leftovers)
	}
}

// 端到端:resolveScrobbleArtist 在智能档下确实走判定器;first 档不打网络;all 档也不打。
func TestResolveScrobbleArtistSmartMode(t *testing.T) {
	saved := features.LastfmScrobbleArtistMode
	defer func() { features.LastfmScrobbleArtistMode = saved }()
	col, cs := newCatalogServer(t, map[string]probeResp{
		"汪苏泷 & 荷莉": {body: shadowJSON},
		"汪苏泷":      {body: trackJSON("", 1200, 166000)},
	})
	features.LastfmScrobbleArtistMode = scrobbleArtistSmart
	if got := resolveScrobbleArtist(context.Background(), col, "汪苏泷 & 荷莉", "吵架歌"); got != "汪苏泷" {
		t.Errorf("smart: got %q", got)
	}
	if cs.total() != 2 {
		t.Errorf("smart 档应打 2 次,实际 %d", cs.total())
	}
	features.LastfmScrobbleArtistMode = scrobbleArtistFirst
	if got := resolveScrobbleArtist(context.Background(), col, "A & B", "另一首"); got != "A" {
		t.Errorf("first: got %q", got)
	}
	features.LastfmScrobbleArtistMode = scrobbleArtistAll
	if got := resolveScrobbleArtist(context.Background(), col, "A & B", "另一首"); got != "A & B" {
		t.Errorf("all: got %q", got)
	}
	if cs.total() != 2 {
		t.Errorf("first/all 档不该再打网络,实际总数 %d", cs.total())
	}
}
