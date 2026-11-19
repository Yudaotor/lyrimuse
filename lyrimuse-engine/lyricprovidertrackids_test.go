package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"reflect"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 网易云、QQ、amll 三个源之间递曲目编号的联合对拍:同一个假服务器、同一张场景表,一边照迁移前收集循环里那三个手写
// goroutine 的写法问(两条带缓冲的通道递编号),一边走真的收集循环,比三份结果、结果到达的先后、amll 拿到的编号(看它
// 按哪个编号去取词)、发出的请求、这一轮记下的跳过、进程内缓存和各源的状态。见 09 章决策 393。

// trackIDSources:联合对拍里的三个源。
var trackIDSources = []string{lyricSourceNetease, lyricSourceQQ, lyricSourceAMLL}

// trackIDParitySource 只给 withParityFake 用:三个源的主机都记下来、交给 handle。
var trackIDParitySource = providerParitySource{
	name: lyricSourceNetease,
	extraHosts: []string{
		"c.y.qq.com", "shc.y.qq.com", "i.y.qq.com", "u.y.qq.com", "u6.y.qq.com", "shu.y.qq.com",
		"raw.githubusercontent.com", "cdn.jsdelivr.net", "fastly.jsdelivr.net", "api.amll.dev",
	},
}

// handwrittenAMLLRound:迁移前收集循环里 amll 那个 goroutine 等到两个编号之后的部分(判跳过、读播放侧记下的编号、取词),
// 原样留着当参照。
func handwrittenAMLLRound(ctx context.Context, neteaseID, qqID, artist, title, srcTitle, album string, durationSecs float64, skipSource func(string) bool) lyricSourceResult {
	if skipSource("amll") {
		return lyricSourceResult{source: "amll"}
	}
	idArtist, idTitle, idAlbum := lyricIdentityFields(ctx, artist, title, album)
	appleCatalogID, spotifyTrackID := playbackTrackIDsForRound(ctx, idArtist, idTitle, idAlbum)
	return lyricSourceResult{source: "amll", amll: amllLyric(ctx, amllQuery{
		neteaseID: neteaseID, qqID: qqID, appleCatalogID: appleCatalogID, spotifyTrackID: spotifyTrackID,
		isrc: lyricSourceISRC(ctx, artist, title, album), artist: artist, title: srcTitle, album: album,
		durationSecs: durationSecs, translationLang: features().LyricsTranslationLanguage,
	})}
}

// handwrittenTrackIDRound 照迁移前收集循环的写法问三个源一轮:三个 goroutine 无条件起,网易云、QQ 各往一条带缓冲的通道里
// 递曲目编号(被跳过也递空串),amll 先等两个编号、再判自己跳不跳。每到一份结果调一次 arrive;这一轮被取消就不再等。
func handwrittenTrackIDRound(ctx context.Context, artist, title, album string, durationSecs float64, arrive func(lyricSourceResult)) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	srcTitle := lyricSourceTitleFor(ctx, title)
	resultsCh := make(chan lyricSourceResult, len(trackIDSources))
	forPlaying := playerSignalApplies(ctx)
	breakerPlan := sharedLyricSourceBreaker().planRound(lyricSourceNames)
	round := lyricSourceRoundFrom(ctx)
	only := lyricSourceOnlyFrom(ctx)
	skipSource := func(source string) bool {
		return lyricSourceSkippedThisRound(ctx, source, only, breakerPlan, round)
	}
	neteaseIDCh := make(chan string, 1)
	qqIDCh := make(chan string, 1)
	go func() {
		if skipSource("netease") {
			neteaseIDCh <- ""
			resultsCh <- lyricSourceResult{source: "netease"}
			return
		}
		info := neteaseLookup(ctx, artist, srcTitle, album, durationSecs)
		if info.SongID > 0 {
			neteaseIDCh <- strconv.FormatInt(info.SongID, 10)
		} else {
			neteaseIDCh <- ""
		}
		resultsCh <- lyricSourceResult{source: "netease", ne: info}
	}()
	go func() {
		resultsCh <- handwrittenQQRound(ctx, artist, srcTitle, album, durationSecs, only, breakerPlan, round, qqIDCh)
	}()
	go func() {
		neteaseID, qqID := <-neteaseIDCh, <-qqIDCh
		resultsCh <- handwrittenAMLLRound(ctx, neteaseID, qqID, artist, title, srcTitle, album, durationSecs, skipSource)
	}()
	for range trackIDSources {
		select {
		case r := <-resultsCh:
			r = withoutPlayerIdentity(ctx, r)
			r.forPlayingTrack = forPlaying
			arrive(r)
		case <-ctx.Done():
			return
		}
	}
}

// trackIDRound 记一轮里三个源的结果到达的先后,并让假服务器按它挂住请求:after 把一个请求挂到某个源的结果到了才放行,
// 场景靠它把到达的先后定死(源之间本来是并发的)。
type trackIDRound struct {
	mu      sync.Mutex
	order   []string
	results map[string]lyricSourceResult
	arrived map[string]chan struct{}
}

func newTrackIDRound() *trackIDRound {
	g := &trackIDRound{results: map[string]lyricSourceResult{}, arrived: map[string]chan struct{}{}}
	for _, s := range trackIDSources {
		g.arrived[s] = make(chan struct{})
	}
	return g
}

func (g *trackIDRound) note(r lyricSourceResult) {
	g.mu.Lock()
	defer g.mu.Unlock()
	ch, ok := g.arrived[r.source]
	if !ok {
		return
	}
	if _, dup := g.results[r.source]; dup {
		return
	}
	g.results[r.source] = r
	g.order = append(g.order, r.source)
	close(ch)
}

func (g *trackIDRound) snapshot() ([]string, map[string]lyricSourceResult) {
	g.mu.Lock()
	defer g.mu.Unlock()
	results := map[string]lyricSourceResult{}
	for k, v := range g.results {
		results[k] = v
	}
	return slices.Clone(g.order), results
}

// after:等 source 的结果先到。等不到(3 秒,或请求自己被取消)返回 false,假服务器这时回一个错误状态让用例红掉。
func (g *trackIDRound) after(r parityRequest, source string) bool {
	select {
	case <-g.arrived[source]:
		return true
	case <-r.Context().Done():
		return false
	case <-time.After(3 * time.Second):
		return false
	}
}

// trackIDGateTimedOut:要等的那份结果一直没到时假服务器回的应答。
var trackIDGateTimedOut = parityReply{status: 599, body: "track id gate: the awaited result never arrived"}

// trackIDFake:三个源的假接口。gate 给一个请求指定「先等谁的结果到」(空串不等);amll 为 nil 时库里什么都没有。
type trackIDFake struct {
	ne   neParityFake
	qq   qqParityFake
	amll func(r parityRequest) parityReply
	gate func(r parityRequest) string
}

func (f trackIDFake) handler() func(g *trackIDRound, r parityRequest) parityReply {
	ne, qq := f.ne.handler(), f.qq.handler()
	return func(g *trackIDRound, r parityRequest) parityReply {
		if f.gate != nil {
			if dep := f.gate(r); dep != "" && !g.after(r, dep) {
				return trackIDGateTimedOut
			}
		}
		switch lyricSourceForHost(r.Host) {
		case lyricSourceNetease:
			return ne(r)
		case lyricSourceQQ:
			return qq(r)
		case lyricSourceAMLL:
			if f.amll != nil {
				return f.amll(r)
			}
		}
		return parityStatus(http.StatusNotFound)
	}
}

// trackIDGate:按请求发给哪个源定它先等谁的结果,deps 是「源 → 先等的那个源」。
func trackIDGate(deps map[string]string) func(parityRequest) string {
	return func(r parityRequest) string { return deps[lyricSourceForHost(r.Host)] }
}

type trackIDParityCase struct {
	name string
	ctx  func(context.Context) context.Context
	// enabled:三个源里设置中开着的;cooling:开搜前已在熔断冷却的。
	enabled, cooling     []string
	artist, title, album string
	durationSecs         float64
	prepare              func(t *testing.T)
	fake                 trackIDFake
	// wantOrder:结果到达的先后,一组一组来;同一组里的几个先后不定(它们之间没有先后关系)。
	wantOrder [][]string
	// wantNeteaseID / wantQQID:amll 按这两个编号去取词(看它发的请求);空串是它没按这个平台的编号问。
	wantNeteaseID, wantQQID string
	wantSkips               []string
	check                   func(t *testing.T, o trackIDParityOutcome)
}

type trackIDParityOutcome struct {
	results  map[string]lyricSourceResult
	order    []string
	requests []string
	round    []string
	skips    map[string]string
	cached   []string
	state    []string
}

// resetAMLLParityState:amll 这一路的进程内状态(解析漂移计数、「没有编号也没有索引」的标记)换成空的,测完换回。
// 索引照单测总入口的默认(没有索引),要它的场景在 prepare 里换。
func resetAMLLParityState(t *testing.T) {
	t.Helper()
	parserDriftMu.Lock()
	savedDrift := parserDrift
	parserDrift = map[string]*parserDriftEntry{}
	parserDriftMu.Unlock()
	savedSkipped := amllSkippedForMissingIDs.Load()
	amllSkippedForMissingIDs.Store(false)
	t.Cleanup(func() {
		parserDriftMu.Lock()
		parserDrift = savedDrift
		parserDriftMu.Unlock()
		amllSkippedForMissingIDs.Store(savedSkipped)
	})
}

// amllParityState:amll 这一路的状态,一行一项。
func amllParityState() []string {
	out := []string{fmt.Sprintf("amll skipped for missing ids=%v", amllSkippedForMissingIDsNow())}
	parserDriftMu.Lock()
	if e := parserDrift[amllLayoutParserName]; e != nil {
		out = append(out, fmt.Sprintf("parser drift %s streak=%d detail=%q", amllLayoutParserName, e.Streak, e.Detail))
	}
	parserDriftMu.Unlock()
	return append(out, parityEndpointHealth(lyricSourceAMLL)...)
}

// coolingBreakerForSources 造一个熔断器,names 里的源正在冷却,装成共享的那份。
func coolingBreakerForSources(t *testing.T, names ...string) {
	t.Helper()
	b := newLyricSourceBreaker(time.Now)
	for _, name := range names {
		d := lyricProviders().descriptor(name)
		host := d.Hosts[0].Host
		if d.Hosts[0].Scope == hostSubdomainsOnly {
			host = "x." + host
		}
		b.observe(host, errProbeDial, 0, "")
		b.observe(host, errProbeDial, 0, "")
	}
	setSharedLyricSourceBreaker(b)
	plan := b.planRound(lyricSourceNames)
	for _, name := range names {
		if _, cooling := plan[name]; !cooling {
			t.Fatalf("%s 应在冷却", name)
		}
	}
}

// amllAskedTrackIDs:amll 按网易云、QQ 的哪个编号去取过词(从发出的请求里认 `ncm-lyrics/<编号>.ttml`、`qq-lyrics/<编号>.ttml`)。
func amllAskedTrackIDs(requests []string) (neteaseID, qqID string) {
	for _, line := range requests {
		if m := regexp.MustCompile(`/ncm-lyrics/([^/.]+)\.ttml`).FindStringSubmatch(line); m != nil {
			neteaseID = m[1]
		}
		if m := regexp.MustCompile(`/qq-lyrics/([^/.]+)\.ttml`).FindStringSubmatch(line); m != nil {
			qqID = m[1]
		}
	}
	return neteaseID, qqID
}

func runTrackIDParityRound(t *testing.T, c trackIDParityCase, viaScheduler bool) trackIDParityOutcome {
	t.Helper()
	neteaseParitySource.reset(t)
	resetQQParityState(t)
	resetAMLLParityState(t)
	g := newTrackIDRound()
	handle := c.fake.handler()
	fake := withParityFake(t, trackIDParitySource, func(r parityRequest) parityReply { return handle(g, r) })
	enableOnlyLyricSources(t, c.enabled...)
	if c.prepare != nil {
		c.prepare(t)
	}
	if len(c.cooling) > 0 {
		coolingBreakerForSources(t, c.cooling...)
	}
	base := context.Background()
	if c.ctx != nil {
		base = c.ctx(base)
	}
	ctx, round := withLyricSourceRound(base)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		if !viaScheduler {
			handwrittenTrackIDRound(ctx, c.artist, c.title, c.album, c.durationSecs, g.note)
			return
		}
		saved := lyricSourceResultTap
		lyricSourceResultTap = g.note
		defer func() { lyricSourceResultTap = saved }()
		fetchScoredLyricCandidatesStreaming(ctx, c.artist, c.title, c.album, c.durationSecs, nil)
	}()
	// 上限远短于收集循环自己的 20 秒截止:有源一直不交结果(等的编号没人递)时尽快红掉。
	select {
	case <-done:
	case <-time.After(8 * time.Second):
		cancel()
		<-done
		order, _ := g.snapshot()
		t.Errorf("%s:8 秒没收齐三个源的结果,只到了 %v", c.name, order)
	}
	o := trackIDParityOutcome{requests: fake.requests(), skips: round.statsSkips()}
	o.order, o.results = g.snapshot()
	o.round = []string{fmt.Sprintf("skipped=%v", round.skippedSources()), fmt.Sprintf("enabled=%v", round.enabledSources())}
	for _, s := range trackIDSources {
		o.round = append(o.round, fmt.Sprintf("reached %s=%v", s, round.reachedSource(s)))
		o.state = append(o.state, providerParityGuardState(s)...)
	}
	for _, k := range neteaseParitySource.cacheKeys() {
		o.cached = append(o.cached, "netease "+k)
	}
	for _, k := range qqParitySource.cacheKeys() {
		o.cached = append(o.cached, "qq "+k)
	}
	sort.Strings(o.cached)
	o.state = append(o.state, neteaseParitySource.state()...)
	o.state = append(o.state, qqParityState()...)
	o.state = append(o.state, amllParityState()...)
	return o
}

// waitLyricRoundGoroutinesGone 等上一轮各源的 goroutine 都退出。被取消的一轮里收集循环先返回,等编号的源要到递编号的源
// 请求断掉、编号递出来之后才走完;不等它,它会在下一个用例换配置、换假服务器的时候才去读配置、记状态。
func waitLyricRoundGoroutinesGone(t *testing.T) {
	t.Helper()
	buf := make([]byte, 8<<20)
	for deadline := time.Now().Add(4 * time.Second); ; time.Sleep(2 * time.Millisecond) {
		stacks := buf[:runtime.Stack(buf, true)]
		if !bytes.Contains(stacks, []byte("lyrimuse-engine.runLyricProvider")) && !bytes.Contains(stacks, []byte("lyrimuse-engine.fetchScoredLyricCandidatesStreaming")) &&
			!bytes.Contains(stacks, []byte("lyrimuse-engine.handwrittenTrackIDRound")) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("这一轮返回 4 秒后还有源的 goroutine 没退出")
		}
	}
}

// trackIDOrderMatches:order 是不是照 want 一组一组到的(同一组里先后不定)。
func trackIDOrderMatches(order []string, want [][]string) bool {
	i := 0
	for _, group := range want {
		if i+len(group) > len(order) {
			return false
		}
		got := slices.Clone(order[i : i+len(group)])
		sort.Strings(got)
		g := slices.Clone(group)
		sort.Strings(g)
		if !slices.Equal(got, g) {
			return false
		}
		i += len(group)
	}
	return i == len(order)
}

func runTrackIDParity(t *testing.T, cases []trackIDParityCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			old := runTrackIDParityRound(t, c, false)
			got := runTrackIDParityRound(t, c, true)
			for _, s := range trackIDSources {
				if !reflect.DeepEqual(got.results[s], old.results[s]) {
					t.Errorf("%s 的结果不一样\n经调度 %+v\n手写的 %+v", s, got.results[s], old.results[s])
				}
				if got.results[s].source != s {
					t.Errorf("没收到 %s 的结果", s)
				}
			}
			if !slices.Equal(got.requests, old.requests) {
				t.Errorf("发出的请求不一样\n经调度 %v\n手写的 %v", got.requests, old.requests)
			}
			if !slices.Equal(got.round, old.round) || !reflect.DeepEqual(got.skips, old.skips) {
				t.Errorf("这一轮记下的不一样\n经调度 %v %v\n手写的 %v %v", got.round, got.skips, old.round, old.skips)
			}
			if !slices.Equal(got.cached, old.cached) {
				t.Errorf("进程内缓存不一样:经调度 %v,手写的 %v", got.cached, old.cached)
			}
			if !slices.Equal(got.state, old.state) {
				t.Errorf("出站闸 / 熔断 / 源自己的状态不一样\n经调度 %v\n手写的 %v", got.state, old.state)
			}
			for label, o := range map[string]trackIDParityOutcome{"经调度": got, "手写的": old} {
				if !trackIDOrderMatches(o.order, c.wantOrder) {
					t.Errorf("%s:结果到达的先后 %v,这个场景应是 %v", label, o.order, c.wantOrder)
				}
				if ne, qq := amllAskedTrackIDs(o.requests); ne != c.wantNeteaseID || qq != c.wantQQID {
					t.Errorf("%s:amll 按网易云编号 %q、QQ 编号 %q 取词,这个场景应是 %q、%q", label, ne, qq, c.wantNeteaseID, c.wantQQID)
				}
			}
			var skipped []string
			for s := range got.skips {
				skipped = append(skipped, s)
			}
			sort.Strings(skipped)
			if want := slices.Sorted(slices.Values(c.wantSkips)); !slices.Equal(skipped, want) {
				t.Errorf("记下跳过的源 %v,这个场景应是 %v", skipped, want)
			}
			if c.check != nil {
				c.check(t, got)
			}
		})
	}
}

func TestTrackIDsBetweenProvidersMatchHandwrittenRound(t *testing.T) {
	const artist, title, album = "五月天", "突然好想你", "后青春期的诗"
	const secs = 265.4
	const neID = "386538"
	all := trackIDSources
	neFound := neParitySong{id: 386538, name: "突然好想你", artist: "五月天", album: "后青春期的诗", albumID: 38285, ms: 265400, picID: neParityPicID}
	neSearch := func(songs ...neParitySong) func(parityRequest, string, string) parityReply {
		return func(_ parityRequest, path, _ string) parityReply {
			if path == "search/get" {
				return neParitySearch(songs...)
			}
			return parityStatus(http.StatusNotFound)
		}
	}
	neHit := neParityFake{
		search: neSearch(neFound),
		lyric: func(_ parityRequest, path string) parityReply {
			if path == "song/lyric/v1" {
				return neParityLyric(neV1Lyric, neParityTrans, "", "", false)
			}
			return parityStatus(http.StatusNotFound)
		},
	}
	neMiss := neParityFake{
		search: neSearch(),
		albums: func(parityRequest, string, string) parityReply {
			return parityOK(`{"code":200,"result":{"albums":[]}}`)
		},
	}
	qrc := `{"lyric":"` + qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCContent)) + `","qrc_t":1,"lrc_t":0,"trans":"","roma":""}`
	qqHit := qqParityFake{
		search: func(parityRequest, string) parityReply {
			return qqParitySearch(qqParityHit{qqParityMid, "突然好想你", "五月天", "后青春期的诗", 265})
		},
		detail:    func(parityRequest, string) parityReply { return qqParityDetail(97773, 265, 0) },
		lineLyric: func(parityRequest, string) parityReply { return qqParityLine(qqTestLRC) },
		musicu: func(_ parityRequest, method string, param map[string]any) parityReply {
			switch {
			case method == "GetSession":
				return parityOK(musicuOK(qqParitySession))
			case method == "GetPlayLyricInfo" && param["songID"] != nil:
				return parityOK(musicuOK(qrc))
			}
			return parityStatus(http.StatusNotFound)
		},
	}
	qqMiss := qqParityFake{
		search:   func(parityRequest, string) parityReply { return parityOK(qqParityNoSongs) },
		smartbox: func(parityRequest, string) parityReply { return parityOK(qqParityNoBox) },
	}
	// amllHas:库里只有这一份(平台目录/编号)。
	amllHas := func(file string) func(parityRequest) parityReply {
		return func(r parityRequest) parityReply {
			if strings.HasSuffix(r.URL.Path, "/"+file+".ttml") {
				return parityOK(amllTestTTML)
			}
			return parityStatus(http.StatusNotFound)
		}
	}
	// qqFetchingLyrics:QQ 认出这首之后取词、取详情的那几个请求(搜索不算)。
	qqFetchingLyrics := func(r parityRequest) bool {
		return lyricSourceForHost(r.Host) == lyricSourceQQ && r.URL.Path != "/soso/fcgi-bin/client_search_cp" && r.URL.Path != "/splcloud/fcgi-bin/smartbox_new.fcg"
	}
	amllResult := func(platform string) func(t *testing.T, o trackIDParityOutcome) {
		return func(t *testing.T, o trackIDParityOutcome) {
			t.Helper()
			if r := o.results[lyricSourceAMLL].amll; r.platform != platform || (platform != "") == r.empty() {
				t.Errorf("amll 的结果应取自 %q:%+v", platform, r)
			}
		}
	}
	neLocal := neParityLocal(neteaseTestTrack("5257138", "突然好想你", "五月天", "后青春期的诗", 265400))
	qqLocal := func(t *testing.T) {
		resetQQLocalIndex(t, writeTestQQDB(t, []qqLocalRow{{Mid: "003LoCaLmid001", Name: "突然好想你", Singer: "五月天", Album: "后青春期的诗", MS: 265400}}))
	}
	cases := []trackIDParityCase{
		{
			name: "两个编号都有:amll 先按网易云的编号取,取到就不再问 QQ 的", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("ncm-lyrics/" + neID),
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantNeteaseID: neID,
			check: amllResult("ncm-lyrics"),
		},
		{
			name: "两个编号都有、库里没有网易云那份:接着按 QQ 的 songmid 取", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid),
				gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceQQ, lyricSourceAMLL: lyricSourceNetease})},
			wantOrder: [][]string{{lyricSourceQQ}, {lyricSourceNetease}, {lyricSourceAMLL}}, wantNeteaseID: neID, wantQQID: qqParityMid,
			check: amllResult("qq-lyrics"),
		},
		{
			name: "QQ 取词很慢:songmid 一到手就递,amll 不等它取词", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid),
				gate: func(r parityRequest) string {
					switch {
					case qqFetchingLyrics(r):
						return lyricSourceAMLL
					case lyricSourceForHost(r.Host) == lyricSourceAMLL:
						return lyricSourceNetease
					}
					return ""
				}},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceAMLL}, {lyricSourceQQ}}, wantNeteaseID: neID, wantQQID: qqParityMid,
			check: func(t *testing.T, o trackIDParityOutcome) {
				amllResult("qq-lyrics")(t, o)
				if o.results[lyricSourceQQ].lyr != qqTestLRC {
					t.Errorf("QQ 自己的词照样取到:%+v", o.results[lyricSourceQQ])
				}
			},
		},
		{
			name: "QQ 没搜到:amll 只拿到网易云的编号", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqMiss,
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantNeteaseID: neID,
			check: amllResult(""),
		},
		{
			name: "网易云没搜到:amll 只拿到 QQ 的 songmid", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neMiss, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid),
				gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceQQ, lyricSourceAMLL: lyricSourceNetease})},
			wantOrder: [][]string{{lyricSourceQQ}, {lyricSourceNetease}, {lyricSourceAMLL}}, wantQQID: qqParityMid,
			check: amllResult("qq-lyrics"),
		},
		{
			name: "两个都没搜到:amll 手上没有编号也没有索引,不发请求", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			fake:      trackIDFake{ne: neMiss, qq: qqMiss, gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ, lyricSourceAMLL}},
			check: func(t *testing.T, o trackIDParityOutcome) {
				amllResult("")(t, o)
				if !strings.Contains(strings.Join(o.state, "\n"), "amll skipped for missing ids=true") {
					t.Errorf("应记下 amll 这一轮没法查:%v", o.state)
				}
			},
		},
		{
			name: "网易云认的是客户端曲库里那条:递的是本机给的编号", enabled: all, prepare: neLocal, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqMiss, amll: amllHas("ncm-lyrics/5257138"),
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantNeteaseID: "5257138",
			check: amllResult("ncm-lyrics"),
		},
		{
			name: "网易云身份挑不出、只给歌词:曲目 id 照递", enabled: all, artist: artist, title: title, album: "另一张专辑", durationSecs: secs,
			fake: trackIDFake{
				ne: func() neParityFake {
					f := neHit
					second := neFound
					second.id, second.album, second.ms = 386539, "精选集", 250000
					first := neFound
					first.album = "第二人生"
					f.search = neSearch(first, second)
					f.albums = neMiss.albums
					return f
				}(),
				qq:   qqMiss,
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ}),
			},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantNeteaseID: neID,
			check: func(t *testing.T, o trackIDParityOutcome) {
				if ne := o.results[lyricSourceNetease].ne; ne.SongURL != "" || ne.Lyrics == "" || ne.SongID != 386538 {
					t.Errorf("网易云应只给歌词和曲目 id:%+v", ne)
				}
			},
		},
		{
			name: "曲库里只剩仿冒号的歌手:身份扣下,曲目 id 照递", enabled: all, artist: "周杰伦", title: "晴天", album: "叶惠美", durationSecs: 269,
			fake: trackIDFake{
				ne: func() neParityFake {
					f := neHit
					f.search = neSearch(neParitySong{id: 186016, name: "晴天", artist: "周杰伦", album: "叶惠美", albumID: 18905, ms: 269000, picID: neParityPicID})
					return f
				}(),
				qq:   qqMiss,
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ}),
			},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantNeteaseID: "186016",
		},
		{
			name: "QQ 认的是客户端曲库里那条:递的是本机给的 songmid", enabled: all, prepare: qqLocal, artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neMiss, qq: qqHit, amll: amllHas("qq-lyrics/003LoCaLmid001"),
				gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceQQ, lyricSourceAMLL: lyricSourceNetease})},
			wantOrder: [][]string{{lyricSourceQQ}, {lyricSourceNetease}, {lyricSourceAMLL}}, wantQQID: "003LoCaLmid001",
			check: amllResult("qq-lyrics"),
		},
		{
			name: "网易云在设置里关掉:它的空编号有人代递,amll 不干等、只拿到 QQ 的", enabled: []string{lyricSourceQQ, lyricSourceAMLL},
			artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid),
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantQQID: qqParityMid,
			check: amllResult("qq-lyrics"),
		},
		{
			name: "QQ 在别名轮名单外:amll 只拿到网易云的", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceOnly(ctx, []string{lyricSourceNetease, lyricSourceAMLL})
			},
			fake: trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("ncm-lyrics/" + neID),
				gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceQQ, lyricSourceAMLL: lyricSourceNetease})},
			wantOrder: [][]string{{lyricSourceQQ}, {lyricSourceNetease}, {lyricSourceAMLL}}, wantNeteaseID: neID,
			check: amllResult("ncm-lyrics"),
		},
		{
			name: "网易云在熔断冷却:记它被跳过,amll 只拿到 QQ 的", enabled: all, cooling: []string{lyricSourceNetease},
			artist: artist, title: title, album: album, durationSecs: secs,
			fake: trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid),
				gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease, lyricSourceAMLL: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ}, {lyricSourceAMLL}}, wantQQID: qqParityMid,
			wantSkips: []string{lyricSourceNetease}, check: amllResult("qq-lyrics"),
		},
		{
			name: "网易云关掉、QQ 在熔断冷却:amll 立即按没有编号走", enabled: []string{lyricSourceQQ, lyricSourceAMLL}, cooling: []string{lyricSourceQQ},
			artist: artist, title: title, album: album, durationSecs: secs,
			fake:      trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid)},
			wantOrder: [][]string{{lyricSourceNetease, lyricSourceQQ, lyricSourceAMLL}}, wantSkips: []string{lyricSourceQQ},
			check: func(t *testing.T, o trackIDParityOutcome) {
				amllResult("")(t, o)
				if len(o.requests) != 0 {
					t.Errorf("三个源都不该发请求:%v", o.requests)
				}
			},
		},
		{
			name: "网易云、QQ 都关掉:amll 立即按没有编号走", enabled: []string{lyricSourceAMLL}, artist: artist, title: title, album: album, durationSecs: secs,
			fake:      trackIDFake{ne: neHit, qq: qqHit, amll: amllHas("qq-lyrics/" + qqParityMid)},
			wantOrder: [][]string{{lyricSourceNetease, lyricSourceQQ, lyricSourceAMLL}},
			check:     amllResult(""),
		},
		{
			name: "amll 在设置里关掉:它的空结果等两个编号都递出来才到", enabled: []string{lyricSourceNetease, lyricSourceQQ},
			artist: artist, title: title, album: album, durationSecs: secs,
			fake:      trackIDFake{ne: neHit, qq: qqHit, gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceQQ}, {lyricSourceNetease, lyricSourceAMLL}},
			check:     amllResult(""),
		},
		{
			name: "amll 在熔断冷却:等两个编号都递出来才记它被跳过、交空结果", enabled: all, cooling: []string{lyricSourceAMLL},
			artist: artist, title: title, album: album, durationSecs: secs,
			fake:      trackIDFake{ne: neHit, qq: qqHit, gate: trackIDGate(map[string]string{lyricSourceQQ: lyricSourceNetease})},
			wantOrder: [][]string{{lyricSourceNetease}, {lyricSourceQQ, lyricSourceAMLL}}, wantSkips: []string{lyricSourceAMLL},
			check: amllResult(""),
		},
		{
			name: "amll 在别名轮名单外:它的空结果同样等两个编号", enabled: all, artist: artist, title: title, album: album, durationSecs: secs,
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceOnly(ctx, []string{lyricSourceNetease, lyricSourceQQ})
			},
			fake:      trackIDFake{ne: neHit, qq: qqHit, gate: trackIDGate(map[string]string{lyricSourceNetease: lyricSourceQQ})},
			wantOrder: [][]string{{lyricSourceQQ}, {lyricSourceNetease, lyricSourceAMLL}},
			check:     amllResult(""),
		},
	}
	runTrackIDParity(t, cases)
}

// 这一轮被取消(用户停止搜索,或收集循环到截止返回):等编号的 amll 不挂着,三个源还在飞的请求都跟着断,两条路发出的请求一样。
func TestTrackIDsBetweenProvidersWhenRoundCancelled(t *testing.T) {
	const artist, title, album = "五月天", "突然好想你", "后青春期的诗"
	run := func(viaScheduler bool) (order []string, requests []string) {
		neteaseParitySource.reset(t)
		resetQQParityState(t)
		resetAMLLParityState(t)
		g := newTrackIDRound()
		var inflight atomic.Int32
		neteaseAsked := make(chan struct{})
		var askedOnce sync.Once
		fake := withParityFake(t, trackIDParitySource, func(r parityRequest) parityReply {
			inflight.Add(1)
			defer inflight.Add(-1)
			switch lyricSourceForHost(r.Host) {
			case lyricSourceNetease:
				askedOnce.Do(func() { close(neteaseAsked) })
				return parityHang(r)
			case lyricSourceQQ:
				return parityOK(qqParityNoSongs)
			}
			return parityStatus(http.StatusNotFound)
		})
		enableOnlyLyricSources(t, trackIDSources...)
		base, _ := withLyricSourceRound(context.Background())
		ctx, cancel := context.WithCancel(base)
		defer cancel()
		done := make(chan struct{})
		go func() {
			defer close(done)
			if !viaScheduler {
				handwrittenTrackIDRound(ctx, artist, title, album, 265.4, g.note)
				return
			}
			saved := lyricSourceResultTap
			lyricSourceResultTap = g.note
			defer func() { lyricSourceResultTap = saved }()
			fetchScoredLyricCandidatesStreaming(ctx, artist, title, album, 265.4, nil)
		}()
		for _, step := range []struct {
			ch   <-chan struct{}
			what string
			then func()
		}{
			{neteaseAsked, "网易云的请求没发到服务端", nil},
			{g.arrived[lyricSourceQQ], "QQ 的结果没到", cancel},
			{done, "取消后这一轮没返回", nil},
		} {
			select {
			case <-step.ch:
			case <-time.After(4 * time.Second):
				t.Fatal(step.what)
			}
			if step.then != nil {
				step.then()
			}
		}
		for deadline := time.Now().Add(4 * time.Second); inflight.Load() != 0; time.Sleep(2 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatal("这一轮返回后服务端还有请求挂着")
			}
		}
		waitLyricRoundGoroutinesGone(t)
		order, _ = g.snapshot()
		return order, fake.requests()
	}
	oldOrder, oldRequests := run(false)
	gotOrder, gotRequests := run(true)
	if !slices.Equal(gotOrder, []string{lyricSourceQQ}) || !slices.Equal(oldOrder, gotOrder) {
		t.Errorf("取消前只该到 QQ 一份:经调度 %v,手写的 %v", gotOrder, oldOrder)
	}
	if !slices.Equal(gotRequests, oldRequests) {
		t.Errorf("发出的请求不一样\n经调度 %v\n手写的 %v", gotRequests, oldRequests)
	}
	if ne, qq := amllAskedTrackIDs(gotRequests); ne != "" || qq != "" {
		t.Errorf("被取消的一轮里 amll 不该取词:%q %q", ne, qq)
	}
}
