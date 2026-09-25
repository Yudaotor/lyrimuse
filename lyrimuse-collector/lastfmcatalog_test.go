package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// 「智能」档编目匹配的回归测试。这套逻辑决定的是**写进 Last.fm 的内容**,而 Last.fm 的
// 纠错/重定向库目前是冻结的(官方 FAQ:"New corrections CANNOT be added to the database")
// —— 错了全局补不回来。所以每一条"什么情况下不改写"都要单独钉死,而不是只测 happy path;
// 每一条"结论不再变"也要钉死 —— 判定一旦不稳,同一首歌两次运行会发出不同的写法。

// probeResp 是假 Last.fm 对某个请求的固定应答。
type probeResp struct {
	status int
	body   string
}

// catalogServer 起一个假 Last.fm,并记下每个请求。应答按键分发:
// track.getInfo 用 "artist\ntrack",artist.getTopTracks 用 "top:artist",track.search 用 "search:track"。
type catalogServer struct {
	srv   *httptest.Server
	mu    sync.Mutex
	calls map[string]int
	raw   []string // 每次请求的 RawQuery,给编码断言用
}

func topKey(artist string) string         { return "top:" + artist }
func searchKey(track string) string       { return "search:" + track }
func infoKey(artist, track string) string { return artist + "\n" + track }

// lastfmEndpointDecode 复刻 Last.fm GET 端点对 query value 的**第二遍**解码
// (form-urlencoded:`+` 当空格、再解一次 %XX)。解不动就原样返回 —— 真实端点对
// 不合法的转义也不会报错。
func lastfmEndpointDecode(s string) string {
	if decoded, err := neturl.QueryUnescape(s); err == nil {
		return decoded
	}
	return s
}

func newCatalogServer(t *testing.T, responses map[string]probeResp) (*lastfmCatalogMatcher, *catalogServer) {
	t.Helper()
	cs := &catalogServer{calls: map[string]int{}}
	cs.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		// 照着真实端点**多解一次码**:Last.fm 的 GET 端点先做标准 percent-decode
		// (这一遍就是 r.URL.Query()),再对结果做一遍 form-urlencoded 解码。假服务器不模拟
		// 第二遍的话,少编一层的 bug 在这里反而"测得过"——而那正是含 `+`/`%` 的歌名
		// 一律 error 6 的真实事故(见 lastfmGetQuery)。
		key := infoKey(lastfmEndpointDecode(q.Get("artist")), lastfmEndpointDecode(q.Get("track")))
		switch q.Get("method") {
		case "artist.getTopTracks":
			key = topKey(lastfmEndpointDecode(q.Get("artist")))
		case "track.search":
			key = searchKey(lastfmEndpointDecode(q.Get("track")))
		}
		cs.mu.Lock()
		cs.calls[key]++
		cs.raw = append(cs.raw, r.URL.RawQuery)
		cs.mu.Unlock()
		resp, ok := responses[key]
		if !ok {
			// 没预设曲目表就当这个歌手编目里没有 —— 大多数用例只关心 track.getInfo 那几步。
			if strings.HasPrefix(key, "top:") {
				fmt.Fprint(w, emptyTopTracksJSON)
				return
			}
			if strings.HasPrefix(key, "search:") {
				fmt.Fprint(w, emptySearchJSON)
				return
			}
			t.Errorf("假 Last.fm 收到没预设应答的请求 %q", key)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if resp.status != 0 {
			w.WriteHeader(resp.status)
		}
		fmt.Fprint(w, resp.body)
	}))
	t.Cleanup(cs.srv.Close)
	// 单测绝不连 MusicBrainz:别名来源默认是「查成了、没有别名」,要别名的用例自己换 stubAliases。
	stubAliases(t, nil)
	return &lastfmCatalogMatcher{
		apiKey:  "k",
		baseURL: cs.srv.URL,
		hc:      cs.srv.Client(),
		cache:   map[string]lastfmCatalogDecision{},
		tops:    map[string][]lastfmTopTrack{},
	}, cs
}

func (cs *catalogServer) count(key string) int {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.calls[key]
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

// topTracksJSON 拼一份 artist.getTopTracks 应答。入参按"名字, 听众"成对给。
func topTracksJSON(artist string, nameListeners ...any) string {
	var rows []string
	for i := 0; i+1 < len(nameListeners); i += 2 {
		rows = append(rows, fmt.Sprintf(`{"name":%q,"mbid":"","listeners":"%d","artist":{"name":%q}}`,
			nameListeners[i], nameListeners[i+1], artist))
	}
	return `{"toptracks":{"track":[` + strings.Join(rows, ",") + `]}}`
}

// 绝大多数用例考察的是「找不找得到、选哪条」,不是作用域限制 —— 统一用「歌手和曲名都可改」
// (即「智能」档)。作用域本身的行为另有专门的用例。
var scopeAll = matchScope{artist: true, track: true}

const (
	notFoundJSON       = `{"error":6,"message":"Track not found"}`
	emptyTopTracksJSON = `{"toptracks":{"track":[]}}`
	emptySearchJSON    = `{"results":{"trackmatches":{"track":[]}}}`
	// 影子条目的典型形态:没 mbid、一个听众、时长 0。
	shadowJSON = `{"track":{"name":"t","mbid":"","listeners":"1","duration":"0"}}`
)

// 本坑的原型:播放器报「陶喆, 卢广仲 / 那个女孩」(简体),编目里那条是「陶喆 / 那個女孩」
// (繁体,889 听众、编目时长 267 s)。曲名和歌手一起被改写。
func TestCatalogMatchesTraditionalTitle(t *testing.T) {
	const joint, track = "陶喆, 卢广仲", "那个女孩"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(joint, track): {body: notFoundJSON},
		infoKey("陶喆", track):  {body: trackJSON("", 126, 0)}, // 简体那侧只有影子
		topKey("陶喆"): {body: topTracksJSON("陶喆",
			"那個女孩", 889, "那個女孩 (feat. 盧廣仲)", 654, "普通朋友", 5000)},
		infoKey("陶喆", "那個女孩"): {body: trackJSON("", 889, 267000)},
	})
	gotArtist, gotTrack, _ := col.resolve(context.Background(), joint, track, 267.333, scopeAll)
	if gotArtist != "陶喆" || gotTrack != "那個女孩" {
		t.Fatalf("resolve = %q / %q, want 陶喆 / 那個女孩", gotArtist, gotTrack)
	}
	d := col.cache[infoKey(joint, track)]
	if d.Verdict != verdictMatch || d.Artist != "陶喆" || d.Track != "那個女孩" {
		t.Errorf("缓存 = %+v", d)
	}
	// 曲目表里同一首歌的另一个写法听众更少(654),不该被选中。
	if n := cs.count(infoKey("陶喆", "那個女孩 (feat. 盧廣仲)")); n != 0 {
		t.Errorf("听众更少的写法不该被复核,却查了 %d 次", n)
	}
}

func TestCatalogDecisionMatrix(t *testing.T) {
	const joint, primary, track = "汪苏泷 & 荷莉", "汪苏泷", "吵架歌"
	cases := []struct {
		name        string
		ownResp     probeResp
		primaryResp probeResp
		tops        string
		topConfirm  map[string]probeResp
		// durationSecs 默认 0 = 播放器没报曲长,时长闸放行 —— 让每条用例只考察它要考察的
		// 那件事。专门测时长闸的用例才给非零值。
		durationSecs float64
		wantArtist   string
		wantTrack    string
		wantVerdict  catalogVerdict // "" = 不该写缓存
	}{
		{
			name: "原样有 mbid:正规合体署名,一个字节都不动,后面几步都不查",
			// 《Scream》是 MJ 和 Janet 共同署名的单曲,Last.fm 编目里就有这个条目。
			ownResp:    probeResp{body: trackJSON("f1e2d3", 24707, 278000)},
			wantArtist: joint, wantTrack: track, wantVerdict: verdictKeep,
		},
		{
			name:        "原样无 mbid 但听众最多:仍然原样,记 keep",
			ownResp:     probeResp{body: trackJSON("", 9000, 0)},
			primaryResp: probeResp{body: trackJSON("", 12, 0)},
			wantArtist:  joint, wantTrack: track, wantVerdict: verdictKeep,
		},
		{
			name:        "原样是影子 + 第一位歌手名下这首歌听众更多:换歌手",
			ownResp:     probeResp{body: shadowJSON},
			primaryResp: probeResp{body: trackJSON("", 1200, 166000)},
			wantArtist:  primary, wantTrack: track, wantVerdict: verdictMatch,
		},
		{
			name:        "原样查无此条(error 6) + 目标已收录:换歌手",
			ownResp:     probeResp{body: notFoundJSON},
			primaryResp: probeResp{body: trackJSON("mb-9", 3, 0)},
			wantArtist:  primary, wantTrack: track, wantVerdict: verdictMatch,
		},
		{
			name:        "差一个听众到阈值、其余为零:算影子;目标收录:换歌手",
			ownResp:     probeResp{body: trackJSON("", lastfmCatalogListenersMin-1, 0)},
			primaryResp: probeResp{body: trackJSON("", lastfmCatalogListenersMin, 0)},
			wantArtist:  primary, wantTrack: track, wantVerdict: verdictMatch,
		},
		{
			name:        "谁都没被收录:维持原样,记 defer",
			ownResp:     probeResp{body: notFoundJSON},
			primaryResp: probeResp{body: notFoundJSON},
			wantArtist:  joint, wantTrack: track, wantVerdict: verdictDefer,
		},
		{
			name:        "原样是影子、第一位也是影子:维持原样,记 defer(不把影子从合体页挪到单人页)",
			ownResp:     probeResp{body: shadowJSON},
			primaryResp: probeResp{body: shadowJSON},
			wantArtist:  joint, wantTrack: track, wantVerdict: verdictDefer,
		},
		{
			name:        "曲目表里有听众更多的写法:换写法",
			ownResp:     probeResp{body: trackJSON("", 600, 0)},
			primaryResp: probeResp{body: notFoundJSON},
			tops:        topTracksJSON(primary, "吵架歌 (Remastered)", 8000),
			topConfirm:  map[string]probeResp{infoKey(primary, "吵架歌 (Remastered)"): {body: trackJSON("", 8000, 0)}},
			wantArtist:  primary, wantTrack: "吵架歌 (Remastered)", wantVerdict: verdictMatch,
		},
		{
			name:         "曲目表候选时长对不上:不认,退回次优",
			ownResp:      probeResp{body: trackJSON("", 600, 200000)},
			primaryResp:  probeResp{body: notFoundJSON},
			tops:         topTracksJSON(primary, "吵架歌", 8000),
			topConfirm:   map[string]probeResp{infoKey(primary, "吵架歌"): {body: trackJSON("", 8000, 400000)}},
			durationSecs: 200,
			wantArtist:   joint, wantTrack: track, wantVerdict: verdictKeep,
		},
		{
			name:       "第一步被限流(429):判不出就维持原样,不缓存",
			ownResp:    probeResp{status: http.StatusTooManyRequests, body: `{}`},
			wantArtist: joint, wantTrack: track,
		},
		{
			name:       "第一步 API 限流(error 29):同上",
			ownResp:    probeResp{body: `{"error":29,"message":"Rate limit exceeded"}`},
			wantArtist: joint, wantTrack: track,
		},
		{
			name:       "第一步响应是坏 JSON:维持原样,不缓存",
			ownResp:    probeResp{body: `not json`},
			wantArtist: joint, wantTrack: track,
		},
		{
			name:       "error 6 但不是 not found(参数问题):不是'没收录',当没查成",
			ownResp:    probeResp{body: `{"error":6,"message":"Invalid parameters - Your request is missing a required parameter"}`},
			wantArtist: joint, wantTrack: track,
		},
		{
			name:       "听众数字段不是数字:信号不可信,当没查成、不缓存",
			ownResp:    probeResp{body: `{"track":{"mbid":"","listeners":"n/a","duration":"0"}}`},
			wantArtist: joint, wantTrack: track,
		},
		{
			name:        "第二步失败(5xx):查不动 → 维持原样、不缓存",
			ownResp:     probeResp{body: notFoundJSON},
			primaryResp: probeResp{status: http.StatusBadGateway, body: ``},
			wantArtist:  joint, wantTrack: track,
		},
		{
			name:        "4xx 状态码带 not found 正文:仍是确定答案",
			ownResp:     probeResp{status: http.StatusBadRequest, body: notFoundJSON},
			primaryResp: probeResp{body: trackJSON("mb-1", 0, 0)},
			wantArtist:  primary, wantTrack: track, wantVerdict: verdictMatch,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			responses := map[string]probeResp{
				infoKey(joint, track):   c.ownResp,
				infoKey(primary, track): c.primaryResp,
				// 基础判定判不了时,扩展搜索还会查合唱的第二位;这张矩阵只考察基础判定。
				infoKey("荷莉", track): {body: notFoundJSON},
			}
			if c.tops != "" {
				responses[topKey(primary)] = probeResp{body: c.tops}
			}
			for k, v := range c.topConfirm {
				responses[k] = v
			}
			col, cs := newCatalogServer(t, responses)
			gotArtist, gotTrack, _ := col.resolve(context.Background(), joint, track, c.durationSecs, scopeAll)
			if gotArtist != c.wantArtist || gotTrack != c.wantTrack {
				t.Errorf("resolve = %q / %q, want %q / %q", gotArtist, gotTrack, c.wantArtist, c.wantTrack)
			}
			if n := cs.count(infoKey(joint, track)); n != 1 {
				t.Errorf("原样写法查了 %d 次,应为 1", n)
			}
			d, cached := col.cache[infoKey(joint, track)]
			if c.wantVerdict == "" {
				if cached {
					t.Errorf("没查成的结果不该进缓存,却写了 %+v", d)
				}
				return
			}
			if !cached {
				t.Fatalf("应该写缓存(verdict %s),却没有", c.wantVerdict)
			}
			if d.Verdict != c.wantVerdict || d.Artist != c.wantArtist {
				t.Errorf("缓存 = %s/%q, want %s/%q", d.Verdict, d.Artist, c.wantVerdict, c.wantArtist)
			}
			if d.Own == nil {
				t.Error("缓存里应留下原样写法的判据")
			}
			if d.Verdict == verdictMatch && d.Chosen == nil {
				t.Error("改写时缓存里应留下被选中那条的判据")
			}
		})
	}
}

// 原样有 mbid 时后面几步一个都不查 —— 既是正确性(正规条目不动),也是预算。
func TestCatalogStopsAtOwnMBID(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("Hall & Oates", "Maneater"): {body: trackJSON("mb-ho", 800000, 272000)},
	})
	a, tr, _ := col.resolve(context.Background(), "Hall & Oates", "Maneater", 272, scopeAll)
	if a != "Hall & Oates" || tr != "Maneater" {
		t.Errorf("resolve = %q / %q, 正规合体署名应原样", a, tr)
	}
	if n := cs.total(); n != 1 {
		t.Errorf("应只打 1 次,实际 %d", n)
	}
}

// 空歌手/空曲名不查:track.getInfo 少任一个都是无效请求。
func TestCatalogSkipsEmptyTags(t *testing.T) {
	for _, c := range []struct{ artist, track string }{
		{"", "某首歌"}, {"   ", "某首歌"}, {"A & B", ""}, {"A & B", "   "},
	} {
		col, cs := newCatalogServer(t, map[string]probeResp{})
		a, tr, _ := col.resolve(context.Background(), c.artist, c.track, 0, scopeAll)
		if a != c.artist || tr != c.track {
			t.Errorf("%q/%q 应原样返回,got %q/%q", c.artist, c.track, a, tr)
		}
		if n := cs.total(); n != 0 {
			t.Errorf("%q/%q 不该打网络,却打了 %d 次", c.artist, c.track, n)
		}
	}
}

// 切不开的 `/` 名字不能被当成合唱串切头(K/DA 那次真实事故的防线):不产生第一位歌手
// 这一路候选,曲目表也按整串查。
func TestCatalogDoesNotSplitUnsplittableNames(t *testing.T) {
	for _, artist := range []string{"K/DA", "AC/DC", "周杰伦、"} {
		col, cs := newCatalogServer(t, map[string]probeResp{
			infoKey(artist, "某首歌"): {body: notFoundJSON},
		})
		col.resolve(context.Background(), artist, "某首歌", 0, scopeAll)
		// 只该有:原样 getInfo + 整串的曲目表 + 扩展搜索的一次 track.search。任何对切出来的
		// 头部的查询都是 bug。
		if n := cs.count(infoKey(artist, "某首歌")); n != 1 {
			t.Errorf("%q: 原样应查 1 次,实际 %d", artist, n)
		}
		if n := cs.count(topKey(artist)); n != 1 {
			t.Errorf("%q: 曲目表应按整串查 1 次,实际 %d", artist, n)
		}
		if n := cs.count(searchKey("某首歌")); n != 1 {
			t.Errorf("%q: 扩展搜索应按曲名搜 1 次,实际 %d", artist, n)
		}
		if n := cs.total(); n != 3 {
			t.Errorf("%q: 多打了请求,总数 %d(说明名字被切开了)", artist, n)
		}
	}
}

// 结论要缓存:同一首歌反复播放(now-playing + scrobble 各一次,再下次播放)只打一轮 API,
// 而且**每次都是同一个写法** —— 这就是 now-playing 与 scrobble 一致性的来源。
func TestCatalogCachesDecisionAndStaysConsistent(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("汪苏泷 & 荷莉", "吵架歌"): {body: shadowJSON},
		infoKey("汪苏泷", "吵架歌"):      {body: trackJSON("", 1200, 166000)},
	})
	for i := 0; i < 4; i++ {
		a, tr, _ := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌", 166, scopeAll)
		if a != "汪苏泷" || tr != "吵架歌" {
			t.Fatalf("第 %d 次 resolve = %q / %q", i, a, tr)
		}
	}
	if n := cs.total(); n != 3 {
		t.Errorf("打了 %d 次 API,应该只有第一轮的 3 次(原样 + 第一位 + 曲目表)", n)
	}
}

// 已有结论**永不翻面**:哪怕 Last.fm 那边后来变了,已经改写的继续按那个写法发、
// 已经保留的继续保留 —— 否则用户自己的历史会被劈成两半。
func TestCatalogKeepAndMatchArePermanent(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{})
	twoYearsAgo := time.Now().Add(-2 * 365 * 24 * time.Hour).Unix()
	col.cache["A & B\n某首歌"] = lastfmCatalogDecision{
		Verdict: verdictMatch, Artist: "A", Track: "某首歌(繁)", TS: twoYearsAgo,
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id()}
	col.cache["C & D\n某首歌"] = lastfmCatalogDecision{
		Verdict: verdictKeep, Artist: "C & D", Track: "某首歌", TS: twoYearsAgo,
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id()}
	if a, tr, _ := col.resolve(context.Background(), "A & B", "某首歌", 0, scopeAll); a != "A" || tr != "某首歌(繁)" {
		t.Errorf("match 结论应永久沿用,got %q / %q", a, tr)
	}
	if a, _, _ := col.resolve(context.Background(), "C & D", "某首歌", 0, scopeAll); a != "C & D" {
		t.Errorf("keep 结论应永久沿用,got %q", a)
	}
	if n := cs.total(); n != 0 {
		t.Errorf("永久结论不该重查,却打了 %d 次", n)
	}
}

// 旧口径的结论必须丢掉重判:老结论是按「只看歌手、只查播放器报的那个曲名」判出来的,
// 而 keep/match 永不重查 —— 沿用就等于新口径对这些歌永远不生效。
func TestCatalogDiscardsStaleDecisionVersion(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("A & B", "某首歌"): {body: trackJSON("mb-ab", 90000, 0)},
	})
	col.cache["A & B\n某首歌"] = lastfmCatalogDecision{
		Verdict: verdictMatch, Artist: "A", TS: time.Now().Unix(),
		V: lastfmCatalogDecisionVersion - 1, Scope: scopeAll.id()}
	if a, _, _ := col.resolve(context.Background(), "A & B", "某首歌", 0, scopeAll); a != "A & B" {
		t.Errorf("旧口径结论应被丢弃重判,got %q", a)
	}
	if n := cs.total(); n == 0 {
		t.Error("旧口径结论应触发重查")
	}
}

// defer 不是结论:到期要重查,那条条目这时候被收录了就该改写;没到期不查。
func TestCatalogDeferRechecksAfterWindow(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("A & B", "某首歌"): {body: notFoundJSON},
		infoKey("A", "某首歌"):     {body: trackJSON("mb-a", 3, 0)}, // 现在已收录
	})
	fresh := time.Now().Add(-lastfmCatalogDeferRecheck + time.Hour).Unix()
	col.cache["A & B\n某首歌"] = lastfmCatalogDecision{
		Verdict: verdictDefer, Artist: "A & B", TS: fresh,
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id(), Ext: lastfmCatalogExtVersion}
	if a, _, _ := col.resolve(context.Background(), "A & B", "某首歌", 0, scopeAll); a != "A & B" {
		t.Errorf("未到期的 defer 应维持原样,got %q", a)
	}
	if n := cs.total(); n != 0 {
		t.Fatalf("未到期不该重查,却打了 %d 次", n)
	}

	stale := time.Now().Add(-lastfmCatalogDeferRecheck - time.Hour).Unix()
	col.cache["A & B\n某首歌"] = lastfmCatalogDecision{
		Verdict: verdictDefer, Artist: "A & B", TS: stale,
		V: lastfmCatalogDecisionVersion, Scope: scopeAll.id(), Ext: lastfmCatalogExtVersion}
	if a, _, _ := col.resolve(context.Background(), "A & B", "某首歌", 0, scopeAll); a != "A" {
		t.Errorf("到期重查、目标已收录 → 应改写,got %q", a)
	}
	if d := col.cache["A & B\n某首歌"]; d.Verdict != verdictMatch {
		t.Errorf("重查后应升格为 match,got %s", d.Verdict)
	}
}

// 查询失败**不能**被缓存 —— 否则一次偶发限流会把这条记录钉死;下一次要整套重来。
func TestCatalogDoesNotCacheFailures(t *testing.T) {
	var ownCalls int
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("method") == "artist.getTopTracks" {
			fmt.Fprint(w, emptyTopTracksJSON)
			return
		}
		switch q.Get("artist") {
		case "汪苏泷 & 荷莉":
			mu.Lock()
			ownCalls++
			n := ownCalls
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
	col := &lastfmCatalogMatcher{apiKey: "k", baseURL: srv.URL, hc: srv.Client(),
		cache: map[string]lastfmCatalogDecision{}, tops: map[string][]lastfmTopTrack{}}
	if a, _, _ := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌", 166, scopeAll); a != "汪苏泷 & 荷莉" {
		t.Fatalf("限流时应维持原样,got %q", a)
	}
	if _, cached := col.cache["汪苏泷 & 荷莉\n吵架歌"]; cached {
		t.Fatal("失败不该进缓存")
	}
	if a, _, _ := col.resolve(context.Background(), "汪苏泷 & 荷莉", "吵架歌", 166, scopeAll); a != "汪苏泷" {
		t.Fatalf("下一次应该重查并改写,got %q", a)
	}
}

// 曲目表查不动也算「没查成」:维持原样、不缓存 —— 它是候选来源之一,缺了就可能漏掉
// 真正该匹配上的那条,不能拿一个残缺的候选集下永久结论。
func TestCatalogDoesNotCacheTopTracksFailure(t *testing.T) {
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey("A", "某首歌"): {body: shadowJSON},
		topKey("A"):         {status: http.StatusBadGateway, body: ``},
	})
	if a, _, _ := col.resolve(context.Background(), "A", "某首歌", 0, scopeAll); a != "A" {
		t.Errorf("曲目表失败应维持原样,got %q", a)
	}
	if _, cached := col.cache["A\n某首歌"]; cached {
		t.Error("曲目表失败不该进缓存")
	}
}

// 同一个歌手串在不同歌上可能一个是正规条目、一个是影子条目 —— 缓存键必须带歌名。
func TestCatalogCacheKeyIncludesTrack(t *testing.T) {
	col, _ := newCatalogServer(t, map[string]probeResp{
		infoKey("A & B", "正规歌"): {body: trackJSON("mb-1", 90000, 0)},
		infoKey("A & B", "冷门歌"): {body: shadowJSON},
		infoKey("A", "冷门歌"):     {body: trackJSON("mb-a", 5000, 0)},
	})
	if a, _, _ := col.resolve(context.Background(), "A & B", "正规歌", 0, scopeAll); a != "A & B" {
		t.Errorf("正规条目应保留,got %q", a)
	}
	if a, _, _ := col.resolve(context.Background(), "A & B", "冷门歌", 0, scopeAll); a != "A" {
		t.Errorf("影子条目应改写,got %q", a)
	}
}

// 曲目表按歌手在进程内复用:同一个歌手连播几首只拉一次。
func TestCatalogReusesTopTracksPerArtist(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("陶喆", "歌一"): {body: shadowJSON},
		infoKey("陶喆", "歌二"): {body: shadowJSON},
		topKey("陶喆"):        {body: topTracksJSON("陶喆", "别的歌", 9000)},
	})
	col.resolve(context.Background(), "陶喆", "歌一", 0, scopeAll)
	col.resolve(context.Background(), "陶喆", "歌二", 0, scopeAll)
	if n := cs.count(topKey("陶喆")); n != 1 {
		t.Errorf("曲目表应只拉 1 次,实际 %d", n)
	}
}

// 请求形态:method/autocorrect 固定;含 `+`/`%` 的歌名要按 lastfmGetQuery 双重编码
// (真实事故:标准编码让含加号的歌名一律 error 6,而 error 6 在这里意味着"可以改写")。
func TestCatalogRequestShape(t *testing.T) {
	const track = "夜曲+窃爱 (Live) 100%"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("陶喆、卢广仲", track): {body: notFoundJSON},
		infoKey("陶喆", track):     {body: trackJSON("mb-t", 8000, 0)},
	})
	if a, _, _ := col.resolve(context.Background(), "陶喆、卢广仲", track, 0, scopeAll); a != "陶喆" {
		t.Fatalf("resolve = %q", a)
	}
	cs.mu.Lock()
	raws := append([]string(nil), cs.raw...)
	cs.mu.Unlock()
	var infoReqs int
	for i, raw := range raws {
		if strings.Contains(raw, "method=artist.getTopTracks") {
			if !strings.Contains(raw, "autocorrect=1") || !strings.Contains(raw, "limit="+lastfmTopTracksLimit) {
				t.Errorf("曲目表请求形态不对: %s", raw)
			}
			continue
		}
		infoReqs++
		for _, want := range []string{"method=track.getInfo", "autocorrect=1", "format=json", "api_key=k"} {
			if !strings.Contains(raw, want) {
				t.Errorf("请求 %d 缺 %q: %s", i, want, raw)
			}
		}
		// `+` 到 %252B、`%` 到 %2525(双重编码);绝不能出现裸的 %2B。
		if !strings.Contains(raw, "%252B") || !strings.Contains(raw, "%2525") {
			t.Errorf("请求 %d 的歌名没有按 Last.fm GET 口径双重编码: %s", i, raw)
		}
		if strings.Contains(raw, "track=%E5%A4%9C%E6%9B%B2%2B") {
			t.Errorf("请求 %d 出现了单层编码的 %%2B: %s", i, raw)
		}
	}
	if infoReqs != 2 {
		t.Errorf("应有 2 个 track.getInfo,实际 %d", infoReqs)
	}
}

// nil 匹配器(没配只读 api_key)必须整体退化成"按原样提交",不能 panic。
func TestCatalogNilIsPassthrough(t *testing.T) {
	var col *lastfmCatalogMatcher
	if a, tr, _ := col.resolve(context.Background(), "A & B", "某首歌", 0, scopeAll); a != "A & B" || tr != "某首歌" {
		t.Errorf("nil 匹配器应原样返回,got %q / %q", a, tr)
	}
	if newLastfmCatalogMatcher("") != nil {
		t.Error("空 api_key 应返回 nil")
	}
}

// 落盘往返:结论带 verdict/口径版本/判据写进文件;重新构造能读回;旧口径与老格式的
// 条目要被丢掉重判,不能直接升格成永久结论。
func TestCatalogCachePersistence(t *testing.T) {
	saved := lastfmCatalogPath
	t.Cleanup(func() { lastfmCatalogPath = saved })
	lastfmCatalogPath = filepath.Join(t.TempDir(), "catalog.json")

	seed := map[string]any{
		"Old & Format\n某首歌": map[string]any{"artist": "Old", "ts": time.Now().Unix()},
		"Stale & Version\n某首歌": lastfmCatalogDecision{
			Verdict: verdictKeep, Artist: "Stale & Version", TS: time.Now().Unix(),
			V: lastfmCatalogDecisionVersion - 1, Scope: scopeAll.id()},
		"C & D\n某首歌": lastfmCatalogDecision{
			Verdict: verdictKeep, Artist: "C & D", TS: time.Now().Unix(),
			V: lastfmCatalogDecisionVersion, Scope: scopeAll.id()},
	}
	data, _ := json.Marshal(seed)
	if err := os.WriteFile(lastfmCatalogPath, data, 0o644); err != nil {
		t.Fatal(err)
	}

	col := newLastfmCatalogMatcher("k")
	if col == nil {
		t.Fatal("有 api_key 应构造成功")
	}
	if _, ok := col.cache["Old & Format\n某首歌"]; ok {
		t.Error("老格式条目应被丢掉")
	}
	if _, ok := col.cache["Stale & Version\n某首歌"]; ok {
		t.Error("旧口径条目应被丢掉")
	}
	if d, ok := col.cache["C & D\n某首歌"]; !ok || d.Verdict != verdictKeep {
		t.Errorf("当前口径的条目应读回,got %+v ok=%v", d, ok)
	}

	col.store("A & B\n某首歌", lastfmCatalogDecision{
		Verdict: verdictMatch, Artist: "A", Track: "某首歌(繁)",
		Own:    &lastfmCatalogProbe{Found: false},
		Chosen: &lastfmCatalogProbe{Found: true, MBID: "mb-a", Listeners: 3},
	})
	raw, err := os.ReadFile(lastfmCatalogPath)
	if err != nil {
		t.Fatal(err)
	}
	var onDisk map[string]lastfmCatalogDecision
	if err := json.Unmarshal(raw, &onDisk); err != nil {
		t.Fatalf("落盘不是合法 JSON: %v", err)
	}
	d := onDisk["A & B\n某首歌"]
	if d.Verdict != verdictMatch || d.Artist != "A" || d.Track != "某首歌(繁)" || d.TS == 0 ||
		d.V != lastfmCatalogDecisionVersion || d.Own == nil || d.Chosen == nil || d.Chosen.MBID != "mb-a" {
		t.Errorf("落盘内容不对: %+v", d)
	}
	if _, ok := onDisk["C & D\n某首歌"]; !ok {
		t.Error("原有条目应一起保留")
	}
	if leftovers, _ := filepath.Glob(lastfmCatalogPath + ".tmp.*"); len(leftovers) != 0 {
		t.Errorf("残留临时文件: %v", leftovers)
	}
}

// setMatch 临时改上送匹配设置,测完还原。
func setMatch(t *testing.T, mode string, artist, track, firstOnly bool) {
	t.Helper()
	savedMode, savedA, savedT, savedF := features().LastfmMatchMode, features().LastfmMatchArtist,
		features().LastfmMatchTrack, features().LastfmMatchFirstArtistOnly
	t.Cleanup(func() {
		featuresRef().LastfmMatchMode, featuresRef().LastfmMatchArtist = savedMode, savedA
		featuresRef().LastfmMatchTrack, featuresRef().LastfmMatchFirstArtistOnly = savedT, savedF
	})
	featuresRef().LastfmMatchMode, featuresRef().LastfmMatchArtist = mode, artist
	featuresRef().LastfmMatchTrack, featuresRef().LastfmMatchFirstArtistOnly = track, firstOnly
}

// 端到端:智能档走匹配器;原始档一个请求都不打。
func TestResolveScrobbleTagsModes(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("汪苏泷 & 荷莉", "吵架歌"): {body: shadowJSON},
		infoKey("汪苏泷", "吵架歌"):      {body: trackJSON("", 1200, 166000)},
	})
	setMatch(t, lastfmMatchSmart, true, true, false)
	if a, tr := resolveScrobbleTags(context.Background(), col, "汪苏泷 & 荷莉", "吵架歌", 166); a != "汪苏泷" || tr != "吵架歌" {
		t.Errorf("智能: got %q / %q", a, tr)
	}
	before := cs.total()
	if before == 0 {
		t.Fatal("智能档应打网络")
	}
	setMatch(t, lastfmMatchRaw, false, false, false)
	if a, tr := resolveScrobbleTags(context.Background(), col, "A & B", "另一首", 0); a != "A & B" || tr != "另一首" {
		t.Errorf("原始: got %q / %q", a, tr)
	}
	if cs.total() != before {
		t.Errorf("原始档不该打网络,总数从 %d 变成 %d", before, cs.total())
	}
}

// 「只开截断、不开匹配」必须跟旧的 first 档**逐字等价**:纯字符串取第一位、一个请求都不打。
// 老用户的 first 偏好就是这么迁移过来的,这条断言是那次迁移的保票。
func TestCustomFirstOnlyNeverHitsNetwork(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{})
	setMatch(t, lastfmMatchCustom, false, false, true)
	if a, tr := resolveScrobbleTags(context.Background(), col, "Khalil Fong & Fiona Sit", "Love Song", 200); a != "Khalil Fong" || tr != "Love Song" {
		t.Errorf("got %q / %q", a, tr)
	}
	if n := cs.total(); n != 0 {
		t.Errorf("不该打网络,却打了 %d 次", n)
	}
}

// 截断只在**没匹配到**时应用。匹配到的写法已经是编目认的那条,再截一刀就把它变成一个
// 不存在的条目(Hall & Oates / Maneater 是 80 万听众的正规条目,截成 Hall 就毁了)。
func TestFirstOnlyDoesNotTruncateAMatchedEntry(t *testing.T) {
	col, _ := newCatalogServer(t, map[string]probeResp{
		// 播放器报的是小写写法(影子),编目里那条署名仍是合体名、9 万听众 —— 匹配得到它,
		// 就不该再截断成 "a"。
		infoKey("a & b", "某首歌"): {body: shadowJSON},
		infoKey("a", "某首歌"):     {body: notFoundJSON},
		topKey("a"):             {body: topTracksJSON("A & B", "某首歌", 90000)},
		infoKey("A & B", "某首歌"): {body: trackJSON("", 90000, 0)},
	})
	setMatch(t, lastfmMatchCustom, true, true, true)
	if a, _ := resolveScrobbleTags(context.Background(), col, "a & b", "某首歌", 0); a != "A & B" {
		t.Errorf("匹配到的合体署名不该被截断,got %q", a)
	}
}

// 作用域:不许改的那个字段必须跟原样一致,否则拼出来的是编目里不存在的组合。
func TestMatchScopeRejectsCandidatesThatChangeALockedField(t *testing.T) {
	responses := map[string]probeResp{
		infoKey("陶喆, 卢广仲", "那个女孩"): {body: notFoundJSON},
		infoKey("陶喆", "那个女孩"):      {body: trackJSON("", 126, 0)},
		topKey("陶喆"):               {body: topTracksJSON("陶喆", "那個女孩", 889)},
		infoKey("陶喆", "那個女孩"):      {body: trackJSON("", 889, 267000)},
	}
	// 只许改曲名:候选 `陶喆 / 那個女孩` 的歌手跟原样(`陶喆, 卢广仲`)对不上,不采纳 ——
	// 否则会发出 `陶喆, 卢广仲 / 那個女孩`,那在编目里根本不存在。
	col, _ := newCatalogServer(t, responses)
	setMatch(t, lastfmMatchCustom, false, true, false)
	a, tr := resolveScrobbleTags(context.Background(), col, "陶喆, 卢广仲", "那个女孩", 267.333)
	if a != "陶喆, 卢广仲" || tr != "那个女孩" {
		t.Errorf("只许改曲名时不该采纳换了歌手的候选,got %q / %q", a, tr)
	}
	// 两个都许改:同一条候选就该被采纳。
	col2, _ := newCatalogServer(t, responses)
	setMatch(t, lastfmMatchCustom, true, true, false)
	if a, tr := resolveScrobbleTags(context.Background(), col2, "陶喆, 卢广仲", "那个女孩", 267.333); a != "陶喆" || tr != "那個女孩" {
		t.Errorf("两个都许改时应采纳,got %q / %q", a, tr)
	}
}

// 换了设置作用域就变了,旧结论对不上必须重判 —— 否则「自定义只改曲名」会沿用「智能」时
// 算出的结论,发出一个用户已经关掉的改写。
func TestMatchScopeChangeInvalidatesCachedDecision(t *testing.T) {
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey("A & B", "某首歌"): {body: trackJSON("mb-ab", 90000, 0)},
	})
	col.cache["A & B\n某首歌"] = lastfmCatalogDecision{
		Verdict: verdictMatch, Artist: "A", TS: time.Now().Unix(),
		V: lastfmCatalogDecisionVersion, Scope: "at",
	}
	if a, _, _ := col.resolve(context.Background(), "A & B", "某首歌", 0, matchScope{artist: true}); a != "A & B" {
		t.Errorf("换了作用域应重判,got %q", a)
	}
	if cs.total() == 0 {
		t.Error("换了作用域应触发重查")
	}
}

// 响应体里的 error 29 让 Last.fm 读接口进出站闸的限流窗口,别接着一首一首地撞。
func TestLastfmCatalogErrorRateLimitedBlocksEndpoint(t *testing.T) {
	saved := hostGuardShared
	hostGuardShared = newHostGuard(time.Now)
	t.Cleanup(func() { hostGuardShared = saved })

	const artist, track = "陶喆", "那个女孩"
	col, cs := newCatalogServer(t, map[string]probeResp{
		infoKey(artist, track): {body: `{"error":29,"message":"Rate limit exceeded"}`},
	})
	col.resolve(context.Background(), artist, track, 0, scopeAll)
	u, err := neturl.Parse(cs.srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if _, blocked := hostGuardShared.endpointBlockedUntil(guardEndpointKey(u)); !blocked {
		t.Fatal("error 29 该让这个端点进限流窗口")
	}
}
