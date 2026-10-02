package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// amllFake:假的 amll 镜像。handle 拿到请求和 "scheme://host/path",自己写响应(要带响应头的用例用得着)。
type amllFake struct {
	mu   sync.Mutex
	hits map[string]int
	// inm:每个地址最近一次请求带的 If-None-Match。
	inm map[string]string
}

func (f *amllFake) count(target string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[target]
}

func (f *amllFake) total() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.hits {
		n += c
	}
	return n
}

func (f *amllFake) ifNoneMatch(target string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.inm[target]
}

func withAMLLFake(t *testing.T, handle func(w http.ResponseWriter, r *http.Request, target string)) *amllFake {
	t.Helper()
	savedGuard, savedBreaker, savedTransport := sharedHostGuard(), sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	t.Cleanup(func() {
		setSharedHostGuard(savedGuard)
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
	})
	f := &amllFake{hits: map[string]int{}, inm: map[string]string{}}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		target := "https://" + host + r.URL.Path
		f.mu.Lock()
		f.hits[target]++
		f.inm[target] = r.Header.Get("If-None-Match")
		f.mu.Unlock()
		handle(w, r, target)
	}))
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	setSharedLyricSourceTransport(&http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	})
	return f
}

const (
	amllRawIndexURL      = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl"
	amllJsDelivrIndexURL = "https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main/metadata/raw-lyrics-index.jsonl"
	amllRawBaseForTest   = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"
	amllJsDelivrBase     = "https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main"
)

// amllIndexRow 按索引原样的形状写一行。
func amllIndexRow(t *testing.T, meta [][2]any) string {
	t.Helper()
	var md [][]any
	for _, kv := range meta {
		md = append(md, []any{kv[0], kv[1]})
	}
	b, err := json.Marshal(map[string]any{"metadata": md, "rawLyricFile": "x.ttml"})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// amllFillerEntries:凑够 amllIndexMinEntries 的占位条目。
func amllFillerEntries() []amllIndexEntry {
	out := make([]amllIndexEntry, amllIndexMinEntries)
	for i := range out {
		out[i] = amllIndexEntry{Titles: []string{fmt.Sprintf("占位 %d", i)}, NCM: []string{fmt.Sprintf("f%d", i)}}
	}
	return out
}

// amllFillerJSONL:凑够条数的占位行,后面接上 extra。
func amllFillerJSONL(t *testing.T, extra ...string) string {
	var b strings.Builder
	for i := 0; i < amllIndexMinEntries; i++ {
		b.WriteString(amllIndexRow(t, [][2]any{{"musicName", []string{fmt.Sprintf("占位 %d", i)}}, {"ncmMusicId", []string{fmt.Sprintf("f%d", i)}}}))
		b.WriteByte('\n')
	}
	for _, e := range extra {
		b.WriteString(e + "\n")
	}
	return b.String()
}

// amllTestStore:索引落在临时目录里的一份,checkedAt 由调用方定。
func amllTestStore(t *testing.T, entries []amllIndexEntry, checkedAt time.Time, now func() time.Time) *amllIndexStore {
	t.Helper()
	path := filepath.Join(t.TempDir(), "amll-index.json")
	if entries != nil {
		if err := writeAMLLIndexFile(path, newAMLLIndex(entries, "e1", amllRawBaseForTest, checkedAt)); err != nil {
			t.Fatal(err)
		}
	}
	s := newAMLLIndexStore(path, now)
	saved := sharedAMLLIndexStore()
	setSharedAMLLIndexStore(s)
	t.Cleanup(func() {
		s.wg.Wait()
		setSharedAMLLIndexStore(saved)
	})
	return s
}

// 索引一行一份歌词:只留用得到的几个键,值去掉空白、ISRC 归一;一个平台 ID 都没有的行、解不开的行跳过。
func TestParseAMLLIndex(t *testing.T) {
	raw := amllIndexRow(t, [][2]any{
		{"musicName", []string{"夜に駆ける", "Yoru ni Kakeru"}},
		{"artists", []string{"YOASOBI"}},
		{"album", []string{"THE BOOK"}},
		{"isrc", []string{" jp-x52-19-00001 "}},
		{"ncmMusicId", []string{"1409311773", " "}},
		{"appleMusicId", []string{"1"}},
		{"Composer", []string{"Ayase"}},
	}) + "\n" +
		amllIndexRow(t, [][2]any{{"musicName", []string{"没有 ID"}}, {"artists", []string{"某人"}}}) + "\n" +
		"不是 JSON\n" +
		amllIndexRow(t, [][2]any{{"musicName", []any{1, 2}}, {"qqMusicId", []string{"mid"}}}) + "\n"
	got := parseAMLLIndex([]byte(raw))
	if len(got) != 2 {
		t.Fatalf("该解出 2 条,实际 %d: %+v", len(got), got)
	}
	e := got[0]
	if strings.Join(e.Titles, "|") != "夜に駆ける|Yoru ni Kakeru" || e.Albums[0] != "THE BOOK" || e.Artists[0] != "YOASOBI" {
		t.Errorf("歌名 / 专辑 / 歌手不对: %+v", e)
	}
	if len(e.ISRCs) != 1 || e.ISRCs[0] != "JPX521900001" {
		t.Errorf("ISRC 该归一成 JPX521900001: %v", e.ISRCs)
	}
	if len(e.NCM) != 1 || e.NCM[0] != "1409311773" || len(e.Apple) != 1 {
		t.Errorf("空白 ID 该丢掉: %+v", e)
	}
	if got[1].Titles != nil || len(got[1].QQ) != 1 {
		t.Errorf("取值不是字符串的键跳过,同一行别的键照收: %+v", got[1])
	}
}

// 按 ISRC 找要歌名也对得上;按歌名找要歌手对得上、专辑到包含档、版本限定词不冲突,专辑分高的排前面;本地没有专辑
// 或者不知道时长时不按歌名找。
func TestAMLLIndexLookup(t *testing.T) {
	x := newAMLLIndex([]amllIndexEntry{
		{Titles: []string{"当群星交汇（Feat.耀嘉音）"}, Artists: []string{"三Z-STUDIO", "HOYO-MiX"}, Albums: []string{"绝区零-Stars Align 当群星交汇"}, ISRCs: []string{"FR2X42551676"}, NCM: []string{"10"}},
		{Titles: []string{"Stars Align"}, Artists: []string{"Sān-Z"}, Albums: []string{"Stars Align"}, ISRCs: []string{"FR2X42551676"}, Apple: []string{"20"}},
		{Titles: []string{"Black Or White"}, Artists: []string{"张杰", "Michael Jackson"}, Albums: []string{"我是歌手第二季 第5期"}, NCM: []string{"28427750"}},
		{Titles: []string{"Black or White"}, Artists: []string{"Michael Jackson"}, Albums: []string{"Dangerous (Special Edition)"}, QQ: []string{"mid5"}},
		{Titles: []string{"Black or White (Live)"}, Artists: []string{"Michael Jackson"}, Albums: []string{"Dangerous"}, NCM: []string{"4"}},
		{Titles: []string{"Black or White"}, Artists: []string{"Michael Jackson"}, Albums: []string{"Bad", "Dangerous"}, QQ: []string{"mid3"}, Spotify: []string{"sp3"}},
		{Titles: []string{"Black or White"}, Artists: []string{"Someone Else"}, Albums: []string{"Dangerous"}, NCM: []string{"6"}},
	}, "", "", time.Now())
	entries := func(ms []amllIndexMatch) []int {
		var out []int
		for _, m := range ms {
			out = append(out, m.entry)
		}
		return out
	}

	got := x.lookup(amllQuery{isrc: "fr2x-4255-1676", title: "Stars Align", artist: "Sān-Z", album: "Stars Align", durationSecs: 200})
	if len(got) != 1 || got[0].entry != 1 || !got[0].byISRC || got[0].title != "Stars Align" || got[0].album != "Stars Align" {
		t.Fatalf("同一个 ISRC 只认歌名对得上的那条: %+v", got)
	}

	got = x.lookup(amllQuery{title: "Black or White", artist: "Michael Jackson", album: "Dangerous", durationSecs: 256})
	if fmt.Sprint(entries(got)) != "[5 3]" {
		t.Fatalf("按歌名该找到 5(专辑相等)、3(专辑包含),实际 %v", entries(got))
	}
	if got[0].byISRC || got[0].album != "Dangerous" || got[0].artist != "Michael Jackson" {
		t.Errorf("报给打分的专辑取分最高的那个: %+v", got[0])
	}
	if dir, id := x.fetchTarget(5); dir != "spotify-lyrics" || id != "sp3" {
		t.Errorf("取词按 am → spotify → ncm → qq 的顺序挑 ID: %s/%s", dir, id)
	}

	if got := x.lookup(amllQuery{title: "Black or White", artist: "Michael Jackson", durationSecs: 256}); len(got) != 0 {
		t.Errorf("本地没有专辑不按歌名找: %v", entries(got))
	}
	if got := x.lookup(amllQuery{title: "Black or White", artist: "Michael Jackson", album: "Dangerous"}); len(got) != 0 {
		t.Errorf("不知道时长不按歌名找: %v", entries(got))
	}

	tv := newAMLLIndex([]amllIndexEntry{
		{Titles: []string{"Wildest Dreams"}, Artists: []string{"Taylor Swift"}, Albums: []string{"1989"}, NCM: []string{"w1"}},
		{Titles: []string{"Wildest Dreams (Taylor’s Version)"}, Artists: []string{"Taylor Swift"}, Albums: []string{"1989 (Taylor’s Version)"}, NCM: []string{"w2"}},
	}, "", "", time.Now())
	if got := tv.lookup(amllQuery{title: "Wildest Dreams (Taylor's Version)", artist: "Taylor Swift", album: "1989 (Taylor's Version)", durationSecs: 220}); fmt.Sprint(entries(got)) != "[1]" {
		t.Errorf("重录版只认重录版: %v", entries(got))
	}
	if got := tv.lookup(amllQuery{title: "Wildest Dreams", artist: "Taylor Swift", album: "1989", durationSecs: 220}); fmt.Sprint(entries(got)) != "[0]" {
		t.Errorf("原版只认原版: %v", entries(got))
	}
	if got := tv.lookup(amllQuery{title: "Wildest Dreams (Taylor's Version)", artist: "Taylor Swift", album: "1989 (Taylor's Version)"}); len(got) != 0 {
		t.Errorf("时长未知不按歌名找: %v", entries(got))
	}

	var many []amllIndexEntry
	for i := 0; i < 5; i++ {
		many = append(many, amllIndexEntry{Titles: []string{"晴天"}, Artists: []string{"周杰伦"}, Albums: []string{"叶惠美"}, NCM: []string{fmt.Sprint(i)}})
	}
	if got := newAMLLIndex(many, "", "", time.Now()).lookup(amllQuery{title: "晴天", artist: "周杰伦", album: "叶惠美", durationSecs: 269}); len(got) != amllIndexLookupMaxFetches {
		t.Errorf("一轮最多取 %d 份,实际 %d", amllIndexLookupMaxFetches, len(got))
	}
}

// 找到的那份要核对歌词长度:按歌名找到的要求本地时长已知,按 ISRC 找到的本地时长未知时不核对。
func TestAMLLLookupFits(t *testing.T) {
	r := amllResult{lrc: "[00:10.00]a\n[03:20.00]b\n"}
	for _, c := range []struct {
		name   string
		byISRC bool
		dur    float64
		want   bool
	}{
		{"按歌名找到、时长对得上", false, 210, true},
		{"按歌名找到、时长未知", false, 0, false},
		{"按 ISRC 找到、时长未知", true, 0, true},
		{"按 ISRC 找到、歌词比歌长", true, 150, false},
		{"按歌名找到、歌词太短", false, 400, false},
	} {
		if got := amllLookupFits(amllIndexMatch{byISRC: c.byISRC}, r, c.dur); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

const amllTestTTML = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><head><metadata/></head>` +
	`<body><div><p begin="00:10.000" end="00:12.000"><span begin="00:10.000" end="00:12.000">第一句</span></p>` +
	`<p begin="03:20.000" end="03:22.000"><span begin="03:20.000" end="03:22.000">最后一句</span></p></div></body></tt>`

// 取词:镜像答了 404 就是库里没有,不再问官方接口;三个镜像都没问成时问官方接口(按平台换查询参数、从 JSON 里取 TTML),
// 官方接口回 404 同样是库里没有。
func TestAmllFetchFallsBackToAPI(t *testing.T) {
	const api = "https://api.amll.dev/v1/lyrics/get"
	f := withAMLLFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		switch {
		case target == api:
			if r.URL.Query().Get("qqMusicId") == "mid1" {
				_, _ = io.WriteString(w, `{"status":200,"data":{"id":1,"lyrics":"<tt/>","format":"ttml"}}`)
				return
			}
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"status":404,"error":"Not Found"}`)
		case strings.HasSuffix(target, "/qq-lyrics/mid3.ttml"):
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusBadGateway)
		}
	})
	if _, ok := amllFetch(qqRoundCtx(), "qq-lyrics", "mid3"); ok || f.count(api) != 0 {
		t.Fatalf("原始仓库回 404 是答了,不该再问官方接口(问了 %d 次)", f.count(api))
	}
	if body, ok := amllFetch(qqRoundCtx(), "qq-lyrics", "mid1"); !ok || body != "<tt/>" {
		t.Fatalf("三个镜像都没问成时该从官方接口拿到: %q %v", body, ok)
	}
	if _, ok := amllFetch(qqRoundCtx(), "qq-lyrics", "mid2"); ok {
		t.Error("官方接口回 404 是库里没有")
	}
	if f.count(api) != 2 {
		t.Errorf("官方接口该问 2 次,实际 %d", f.count(api))
	}
}

// 索引在手、够新时,不在索引里的 ID 不发请求;索引太旧时照旧按 ID 直取。
func TestAMLLLyricIndexGatesIDs(t *testing.T) {
	f := withAMLLFake(t, func(w http.ResponseWriter, _ *http.Request, target string) {
		switch {
		case strings.HasSuffix(target, "/qq-lyrics/mid1.ttml"):
			_, _ = io.WriteString(w, amllTestTTML)
		case strings.HasSuffix(target, "/raw-lyrics-index.jsonl"):
			w.WriteHeader(http.StatusInternalServerError)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	entries := append(amllFillerEntries(), amllIndexEntry{Titles: []string{"晴天"}, QQ: []string{"mid1"}})
	q := amllQuery{neteaseID: "999", qqID: "mid1"}

	amllTestStore(t, entries, time.Now(), time.Now)
	r := amllLyric(qqRoundCtx(), q)
	if r.empty() || r.platform != "qq-lyrics" {
		t.Fatalf("该按 QQ 的 ID 取到: %+v", r)
	}
	if n := f.count(amllRawBaseForTest + "/ncm-lyrics/999.ttml"); n != 0 {
		t.Errorf("不在索引里的 ID 不该发请求,发了 %d 次", n)
	}

	s := amllTestStore(t, entries, time.Now().Add(-amllIndexMaxAge-time.Hour), time.Now)
	if r := amllLyric(qqRoundCtx(), q); r.platform != "qq-lyrics" {
		t.Fatalf("索引太旧时照样取得到: %+v", r)
	}
	if n := f.count(amllRawBaseForTest + "/ncm-lyrics/999.ttml"); n != 1 {
		t.Errorf("索引太旧时不在索引里的 ID 照旧直取,实际 %d 次", n)
	}
	s.wg.Wait()
	if f.count(amllRawIndexURL) == 0 {
		t.Error("索引太旧时该在后台核对一次")
	}
}

// ID 都不在库里时按歌名在索引里找:找到的那份不借封面、报索引里的元数据;歌词长度对不上的不要;按 ID 已经取过的那一条
// 不再取。
func TestAMLLLyricLooksUpIndex(t *testing.T) {
	f := withAMLLFake(t, func(w http.ResponseWriter, _ *http.Request, target string) {
		switch {
		case strings.HasSuffix(target, "/am-lyrics/a1.ttml"), strings.HasSuffix(target, "/ncm-lyrics/n2.ttml"):
			_, _ = io.WriteString(w, amllTestTTML)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	entries := append(amllFillerEntries(),
		amllIndexEntry{Titles: []string{"晴天"}, Artists: []string{"周杰伦"}, Albums: []string{"叶惠美"}, Apple: []string{"a1"}, NCM: []string{"n1"}},
		amllIndexEntry{Titles: []string{"晴天"}, Artists: []string{"周杰伦"}, Albums: []string{"叶惠美 (Deluxe)"}, NCM: []string{"n2"}},
	)
	amllTestStore(t, entries, time.Now(), time.Now)
	q := amllQuery{artist: "周杰伦", title: "晴天", album: "叶惠美", durationSecs: 210}

	r := amllLyric(qqRoundCtx(), q)
	if r.empty() || r.platform != "" || r.matchTitle != "晴天" || r.matchArtist != "周杰伦" || r.matchAlbum != "叶惠美" {
		t.Fatalf("按歌名找到的报索引里的元数据、不带平台: %+v", r)
	}

	q.durationSecs = 400
	if r := amllLyric(qqRoundCtx(), q); !r.empty() {
		t.Errorf("歌词长度对不上的不要: %+v", r)
	}

	before := f.count(amllRawBaseForTest + "/am-lyrics/a1.ttml")
	q.durationSecs, q.neteaseID = 210, "n1"
	r = amllLyric(qqRoundCtx(), q)
	if f.count(amllRawBaseForTest+"/am-lyrics/a1.ttml") != before {
		t.Error("按 ID 取过的那一条(n1 跟 a1 是同一条)不该再按歌名取一次")
	}
	if r.matchAlbum != "叶惠美 (Deluxe)" {
		t.Errorf("该轮到下一条: %+v", r)
	}
}

// 接线:enrich 的 amll 那一路把 ISRC、歌名歌手专辑、时长交给 amllLyric —— 网易云 / QQ 关掉、手上一个 ID 都没有时,
// 照样按索引找得到。
func TestAMLLPipelineLooksUpIndex(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"amll": true}
	withAMLLFake(t, func(w http.ResponseWriter, _ *http.Request, target string) {
		if strings.HasSuffix(target, "/am-lyrics/a1.ttml") || strings.HasSuffix(target, "/am-lyrics/a2.ttml") {
			_, _ = io.WriteString(w, amllTestTTML)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	amllTestStore(t, append(amllFillerEntries(),
		amllIndexEntry{Titles: []string{"晴天"}, Artists: []string{"周杰伦"}, Albums: []string{"叶惠美"}, Apple: []string{"a1"}},
		amllIndexEntry{Titles: []string{"Stars Align"}, Artists: []string{"Sān-Z"}, Albums: []string{"别的专辑"}, ISRCs: []string{"FR2X42551676"}, Apple: []string{"a2"}},
	), time.Now(), time.Now)
	amllOf := func(rs []scoredLyricCandidateResult) scoredLyricCandidateResult {
		for _, r := range rs {
			if r.Source == "amll" {
				return r
			}
		}
		return scoredLyricCandidateResult{}
	}

	_, got := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "周杰伦", "晴天", "叶惠美", 210, nil)
	if r := amllOf(got); r.Title != "晴天" || r.Album != "叶惠美" {
		t.Errorf("按歌名该找到: %+v", r)
	}
	_, got = fetchScoredLyricCandidatesStreaming(withRecordingISRC(qqRoundCtx(), "FR2X42551676"), "Sān-Z", "Stars Align", "Stars Align", 210, nil)
	if r := amllOf(got); r.Title != "Stars Align" || r.Album != "别的专辑" {
		t.Errorf("按 ISRC 该找到(专辑对不上也行): %+v", r)
	}
}

// ISRC 补取:amll 没给出可用候选、索引里又有 applemusic 候选报的那个 ISRC 时一并问;索引里没有、amll 已经有可用候选、
// 没有索引时都不问。
func TestISRCRetryPlanAddsAMLL(t *testing.T) {
	saved, savedBreaker := features(), sharedLyricSourceBreaker()
	t.Cleanup(func() { setFeatures(saved); setSharedLyricSourceBreaker(savedBreaker) })
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	featuresRef().LyricsSources = map[string]bool{"applemusic": true, "amll": true}
	apple := scoredLyricCandidateResult{Source: "applemusic", Score: 1169, ISRC: "JPU902104759", SourceReportedDurationSecs: 257, Lyrics: "[00:01.00]a"}

	savedStore := sharedAMLLIndexStore()
	t.Cleanup(func() { setSharedAMLLIndexStore(savedStore) })
	setSharedAMLLIndexStore(newAMLLIndexStore("", time.Now))
	if isrc, _ := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{apple}, 258); isrc != "" {
		t.Errorf("没有索引时不问 amll: %q", isrc)
	}

	amllTestStore(t, append(amllFillerEntries(), amllIndexEntry{Titles: []string{"君に夢中"}, ISRCs: []string{"JPU902104759"}, Apple: []string{"1"}}), time.Now(), time.Now)
	if isrc, s := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{apple}, 258); isrc != "JPU902104759" || strings.Join(s, ",") != "amll" {
		t.Fatalf("索引里有这个 ISRC 时该问 amll: %q %v", isrc, s)
	}
	other := apple
	other.ISRC = "USUG12601721"
	if isrc, _ := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{other}, 258); isrc != "" {
		t.Errorf("索引里没有这个 ISRC 时不问 amll: %q", isrc)
	}
	usable := scoredLyricCandidateResult{Source: "amll", Score: 900, Lyrics: "[00:01.00]a"}
	if isrc, _ := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{apple, usable}, 258); isrc != "" {
		t.Errorf("amll 已有可用候选时不问: %q", isrc)
	}
}

// 没有索引、四个 ID 也都为空时才记"一个请求都没发";索引在手时照样按 ISRC / 歌名找过,不算。
func TestAMLLLyricSkipFlag(t *testing.T) {
	saved := amllSkippedForMissingIDs.Load()
	t.Cleanup(func() { amllSkippedForMissingIDs.Store(saved) })
	withAMLLFake(t, func(w http.ResponseWriter, _ *http.Request, _ string) { w.WriteHeader(http.StatusNotFound) })

	savedStore := sharedAMLLIndexStore()
	t.Cleanup(func() { setSharedAMLLIndexStore(savedStore) })
	setSharedAMLLIndexStore(newAMLLIndexStore("", time.Now))

	amllSkippedForMissingIDs.Store(false)
	amllLyric(qqRoundCtx(), amllQuery{title: "晴天"})
	if !amllSkippedForMissingIDs.Load() {
		t.Error("没有索引、没有 ID:该记下跳过")
	}

	amllSkippedForMissingIDs.Store(false)
	amllLyric(qqRoundCtx(), amllQuery{spotifyTrackID: "sp"})
	if amllSkippedForMissingIDs.Load() {
		t.Error("还有一个 ID 就不算跳过")
	}

	amllSkippedForMissingIDs.Store(false)
	amllTestStore(t, amllFillerEntries(), time.Now(), time.Now)
	amllLyric(qqRoundCtx(), amllQuery{title: "晴天"})
	if amllSkippedForMissingIDs.Load() {
		t.Error("索引在手时不算跳过")
	}
}

// 后台下载:没有落盘的索引时这一轮不挡请求、在后台下载并落盘;到了核对时间带 ETag 去问,304 只更新核对时间;核对失败
// 保留手上那份,冷却期内不再问。
func TestAMLLIndexStoreDownloadsAndRevalidates(t *testing.T) {
	var mu sync.Mutex
	status, etag := http.StatusOK, `"v1"`
	f := withAMLLFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		mu.Lock()
		st, tag := status, etag
		mu.Unlock()
		if target != amllRawIndexURL {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if st == http.StatusOK && r.Header.Get("If-None-Match") == tag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		if st != http.StatusOK {
			w.WriteHeader(st)
			return
		}
		w.Header().Set("ETag", tag)
		_, _ = io.WriteString(w, amllFillerJSONL(t, amllIndexRow(t, [][2]any{{"musicName", []string{"晴天"}}, {"qqMusicId", []string{"mid1"}}})))
	})
	var clockMu sync.Mutex
	clock := time.Now()
	now := func() time.Time {
		clockMu.Lock()
		defer clockMu.Unlock()
		return clock
	}
	advance := func(d time.Duration) {
		clockMu.Lock()
		clock = clock.Add(d)
		clockMu.Unlock()
	}
	s := amllTestStore(t, nil, time.Time{}, now)

	if s.current() != nil {
		t.Fatal("还没有索引")
	}
	s.wg.Wait()
	x := s.current()
	if x == nil || x.etag != `"v1"` || x.base != amllRawBaseForTest {
		t.Fatalf("后台下载完该换上新索引: %+v", x)
	}
	if _, ok := x.entryFor("qq-lyrics", "mid1"); !ok {
		t.Error("新索引里该有 mid1")
	}
	if disk := readAMLLIndexFile(s.path); disk == nil || disk.etag != `"v1"` {
		t.Fatal("下载完该落盘")
	}

	advance(amllIndexRefreshInterval + time.Minute)
	s.current()
	s.wg.Wait()
	if got := f.ifNoneMatch(amllRawIndexURL); got != `"v1"` {
		t.Errorf("核对该带上 ETag: %q", got)
	}
	y := s.current()
	if y == nil || !y.checkedAt.Equal(now()) {
		t.Fatalf("304 该把核对时间更新到现在: %+v vs %v", y, now())
	}
	if len(y.entries) != len(x.entries) {
		t.Error("304 沿用原来的内容")
	}

	mu.Lock()
	status = http.StatusBadGateway
	mu.Unlock()
	advance(amllIndexRefreshInterval + time.Minute)
	requests := f.total()
	s.current()
	s.wg.Wait()
	if s.current() != y {
		t.Error("核对失败该保留手上那份")
	}
	afterFail := f.total()
	if afterFail == requests {
		t.Fatal("到了核对时间该去问")
	}
	advance(amllIndexRetryCooldown / 2)
	s.current()
	s.wg.Wait()
	if f.total() != afterFail {
		t.Error("冷却期内不该再问")
	}
	// 上面那几次 5xx 可能让本地出站闸停用了端点;这里只看冷却过后有没有再问。
	setSharedHostGuard(newHostGuard(time.Now))
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	advance(amllIndexRetryCooldown)
	s.current()
	s.wg.Wait()
	if f.total() == afterFail {
		t.Error("冷却过了该再问")
	}
}

// ETag 只对同一个镜像带;原始仓库回的内容解不出够数的条目时换镜像;别的进程刚核对过时直接用磁盘上那份,不发请求。
func TestAMLLIndexStoreMirrorsAndDisk(t *testing.T) {
	var mu sync.Mutex
	rawBody := "坏的\n"
	f := withAMLLFake(t, func(w http.ResponseWriter, _ *http.Request, target string) {
		mu.Lock()
		body := rawBody
		mu.Unlock()
		switch target {
		case amllRawIndexURL:
			_, _ = io.WriteString(w, body)
		case amllJsDelivrIndexURL:
			w.Header().Set("ETag", `W/"j2"`)
			_, _ = io.WriteString(w, amllFillerJSONL(t))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	path := filepath.Join(t.TempDir(), "amll-index.json")
	if err := writeAMLLIndexFile(path, newAMLLIndex(amllFillerEntries(), `W/"j1"`, amllJsDelivrBase, time.Now().Add(-amllIndexRefreshInterval-time.Hour))); err != nil {
		t.Fatal(err)
	}
	s := newAMLLIndexStore(path, time.Now)
	saved := sharedAMLLIndexStore()
	setSharedAMLLIndexStore(s)
	t.Cleanup(func() { s.wg.Wait(); setSharedAMLLIndexStore(saved) })

	s.current()
	s.wg.Wait()
	if got := f.ifNoneMatch(amllRawIndexURL); got != "" {
		t.Errorf("原始仓库不该收到 jsDelivr 给的 ETag: %q", got)
	}
	if got := f.ifNoneMatch(amllJsDelivrIndexURL); got != `W/"j1"` {
		t.Errorf("jsDelivr 该收到它自己给的 ETag: %q", got)
	}
	x := s.current()
	if x == nil || x.etag != `W/"j2"` || x.base != amllJsDelivrBase {
		t.Fatalf("原始仓库的内容是坏的,该换 jsDelivr 的: %+v", x)
	}

	other := newAMLLIndex(amllFillerEntries(), `"o1"`, amllRawBaseForTest, time.Now())
	if err := writeAMLLIndexFile(path, other); err != nil {
		t.Fatal(err)
	}
	s2 := newAMLLIndexStore(path, time.Now)
	s2.loaded, s2.idx = true, newAMLLIndex(amllFillerEntries(), `"old"`, amllRawBaseForTest, time.Now().Add(-amllIndexRefreshInterval-time.Hour))
	requests := f.total()
	s2.current()
	s2.wg.Wait()
	if f.total() != requests {
		t.Error("磁盘上那份刚核对过,不该发请求")
	}
	if got := s2.current(); got == nil || got.etag != `"o1"` {
		t.Errorf("该换上磁盘上那份: %+v", got)
	}
}

// 该不该核对:没有索引、到了间隔、核对时间在将来(改过系统时间)都要核对;挡不挡请求只看离上次核对多久。
func TestAMLLIndexDueAndGates(t *testing.T) {
	now := time.Now()
	var none *amllIndex
	if !none.dueForCheck(now) {
		t.Error("没有索引该核对")
	}
	for _, c := range []struct {
		age        time.Duration
		due, gates bool
	}{
		{time.Hour, false, true},
		{amllIndexRefreshInterval + time.Minute, true, true},
		{-time.Hour, true, true},
		{amllIndexMaxAge + time.Hour, true, false},
	} {
		x := newAMLLIndex(nil, "", "", now.Add(-c.age))
		if x.dueForCheck(now) != c.due || x.gates(now) != c.gates {
			t.Errorf("距上次核对 %s: due=%v gates=%v", c.age, x.dueForCheck(now), x.gates(now))
		}
	}
}

// 落盘格式:版本不对、条目不够数的当作没有。
func TestReadAMLLIndexFileRejects(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, f amllIndexFile) string {
		b, err := json.Marshal(f)
		if err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	if readAMLLIndexFile(write("v0.json", amllIndexFile{Version: amllIndexFileVersion + 1, Entries: amllFillerEntries()})) != nil {
		t.Error("版本不对的不该读进来")
	}
	if readAMLLIndexFile(write("few.json", amllIndexFile{Version: amllIndexFileVersion, Entries: amllFillerEntries()[:3]})) != nil {
		t.Error("条目不够数的不该读进来")
	}
	if readAMLLIndexFile(write("ok.json", amllIndexFile{Version: amllIndexFileVersion, CheckedAt: 100, Entries: amllFillerEntries()})) == nil {
		t.Error("正常的该读进来")
	}
}
