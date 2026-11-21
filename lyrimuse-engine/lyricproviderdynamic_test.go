package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 运行时登记的歌词来源(lyricproviderdynamic.go):登记之后下一轮起它跟内置来源一样被问、算进进度和到齐、出候选;
// 一轮进行中登记、注销不影响这一轮;注销之后不留痕迹;登记校验的每一条。

// newDynamicStub:一个要在运行时登记的假来源,描述符只有名字和空的 Assembly;gate 非 nil 时等它关了才交结果。
func newDynamicStub(name string, gate chan struct{}) *stubLyricProvider {
	p := &stubLyricProvider{desc: &ProviderDescriptor{Name: name, Assembly: &CandidateAssembly{}}}
	p.resolve = func() SourceResult {
		if gate != nil {
			<-gate
		}
		return SourceResult{lyr: snapshotStubLRC, matchTitle: "Snapshot Song", matchArtist: "Snapshot Artist"}
	}
	return p
}

// countingDynamicSource:只数被问了几次的假来源,好几轮同时问它也不争用。
type countingDynamicSource struct {
	desc  *ProviderDescriptor
	calls atomic.Int32
}

func newCountingDynamicSource(name string) *countingDynamicSource {
	return &countingDynamicSource{desc: &ProviderDescriptor{Name: name, Assembly: &CandidateAssembly{}}}
}

func (p *countingDynamicSource) Descriptor() *ProviderDescriptor { return p.desc }

func (p *countingDynamicSource) Resolve(context.Context, ProviderQuery, RoundEnv) SourceResult {
	p.calls.Add(1)
	return SourceResult{lyr: snapshotStubLRC, matchTitle: "Snapshot Song", matchArtist: "Snapshot Artist"}
}

// useDynamicLyricProviders:运行时登记的来源换成这一组,测完清空。
func useDynamicLyricProviders(t *testing.T, providers ...LyricProvider) {
	t.Helper()
	if err := setDynamicLyricProviders(providers); err != nil {
		t.Fatalf("登记被拒:%v", err)
	}
	t.Cleanup(func() {
		if err := setDynamicLyricProviders(nil); err != nil {
			t.Errorf("清空运行时登记的来源:%v", err)
		}
	})
}

// builtinSourcesOff:设置里把内置联网源全关掉(它们各交一份空结果、不发请求),这一轮只剩运行时登记的来源真的被问。
func builtinSourcesOff(t *testing.T) {
	t.Helper()
	useFreshOutboundState(t)
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	enableOnlyLyricSources(t)
}

// tapSourceResults:收集循环每收到一份结果,把源名送进返回的通道。
func tapSourceResults(t *testing.T) <-chan string {
	t.Helper()
	arrived := make(chan string, 256)
	saved := lyricSourceResultTap
	lyricSourceResultTap = func(r lyricSourceResult) { arrived <- r.source }
	t.Cleanup(func() { lyricSourceResultTap = saved })
	return arrived
}

// waitCollectLoopWaiting 等到收集循环停在 select 上等结果。
func waitCollectLoopWaiting(t *testing.T) {
	t.Helper()
	buf := make([]byte, 8<<20)
	for deadline := time.Now().Add(4 * time.Second); ; time.Sleep(time.Millisecond) {
		for _, g := range bytes.Split(buf[:runtime.Stack(buf, true)], []byte("\n\n")) {
			header, _, _ := bytes.Cut(g, []byte("\n"))
			if bytes.Contains(header, []byte("[select")) && bytes.Contains(g, []byte("fetchScoredLyricCandidatesStreaming")) {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("4 秒里收集循环没有停在等结果上")
		}
	}
}

func lastUpdate(updates chan snapshotRoundUpdate) (last snapshotRoundUpdate) {
	for len(updates) > 0 {
		last = <-updates
	}
	return last
}

// 没有运行时登记的来源时,当前生效的就是只有内置来源的那一份(同一个指针):读当前登记表的守卫看到的就是内置名单。
func TestNoDynamicSourcesMeansBuiltinRegistry(t *testing.T) {
	if lyricProviders() != builtinLyricRegistry() {
		t.Fatal("没有运行时登记的来源时,lyricProviders() 应就是 builtinLyricRegistry()")
	}
	if len(lyricProviders().dynamicPriorityNames) != 0 {
		t.Errorf("内置那一份里不该有运行时登记的来源:%v", lyricProviders().dynamicPriorityNames)
	}
	for _, d := range builtinLyricRegistry().descriptors {
		if d.Origin != originBuiltin {
			t.Errorf("%s 是编在核心里的,Origin 应是 originBuiltin", d.Name)
		}
	}
}

// 登记一个假来源之后的下一轮:它被问到(设置里没有它的开关,登记着就是开着)、算进进度的分母、收集循环等它到齐、
// 它的候选进排序。
func TestDynamicSourceJoinsTheNextRound(t *testing.T) {
	builtinSourcesOff(t)
	arrived := tapSourceResults(t)
	gate := make(chan struct{})
	dyn := newDynamicStub("dyn:late", gate)
	useDynamicLyricProviders(t, dyn)

	updates, finished := startSnapshotRound(context.Background())
	// 内置的十六个联网源都关着,各自的空结果先到齐;这时循环还差运行时登记的那一个,停着等。
	back := map[string]bool{}
	for len(back) < len(lyricSourceNames) {
		back[recvWithin(t, arrived, "内置联网源的空结果")] = true
	}
	if back["dyn:late"] {
		t.Fatal("dyn:late 还没放行就交了结果")
	}
	waitCollectLoopWaiting(t)
	select {
	case got := <-finished:
		t.Fatalf("运行时登记的来源还没回来,这一轮就结束了:%v", got)
	default:
	}
	if u := lastUpdate(updates); u.done != 0 || u.total != 1 {
		t.Errorf("只差 dyn:late 时的进度 %d/%d,期望 0/1:分母数开着的联网源,内置的都关了、运行时登记的算一个", u.done, u.total)
	}
	close(gate)
	if got := recvWithin(t, finished, "这一轮结束"); !slices.Equal(got, []string{"dyn:late"}) {
		t.Errorf("这一轮的结果 %v,期望只有 dyn:late 的候选", got)
	}
	if u := lastUpdate(updates); u.done != 1 || u.total != 1 || !slices.Equal(u.sources, []string{"dyn:late"}) {
		t.Errorf("dyn:late 到达时 %+v,期望候选 [dyn:late]、进度 1/1", u)
	}
	if dyn.calls.Load() != 1 {
		t.Errorf("dyn:late 被问了 %d 次,期望 1 次", dyn.calls.Load())
	}
	if dyn.gotEnv.granted != 0 {
		t.Errorf("交给运行时登记的来源的环境不该带特权位:%b", dyn.gotEnv.granted)
	}
	if a, ti, al := dyn.gotEnv.IdentityFields(); a+ti+al != "" || dyn.gotEnv.PlayingPlayer() != "" {
		t.Error("运行时登记的来源读不到播放器原样标签、在放的播放器")
	}
}

// 一轮进行中注销一个来源、登记另一个:这一轮照开搜时那份跑完,注销掉的那个晚到的结果照收、照算进度(它在设置里没有
// 开关,当前生效的登记表里也没有它了,进度按这一轮那份登记表认它开着);新登记的这一轮不问。下一轮反过来。
func TestRegisteringMidRoundTakesEffectNextRound(t *testing.T) {
	builtinSourcesOff(t)
	gate := make(chan struct{})
	leaving, joining := newDynamicStub("dyn:leaving", gate), newDynamicStub("dyn:joining", nil)
	useDynamicLyricProviders(t, leaving)

	updates, finished := startSnapshotRound(context.Background())
	waitGoroutineParkedIn(t, "newDynamicStub")
	if err := setDynamicLyricProviders([]LyricProvider{joining}); err != nil {
		t.Fatal(err)
	}
	if lyricProviders().descriptor("dyn:leaving") != nil || lyricProviders().descriptor("dyn:joining") == nil {
		t.Fatal("换完之后当前生效的登记表里应只有 dyn:joining")
	}
	close(gate)
	if got := recvWithin(t, finished, "这一轮结束"); !slices.Equal(got, []string{"dyn:leaving"}) {
		t.Errorf("这一轮的结果 %v,期望 [dyn:leaving]:开搜时登记着的来源,中途注销也照收", got)
	}
	if u := lastUpdate(updates); u.done != 1 || u.total != 1 {
		t.Errorf("这一轮最后的进度 %d/%d,期望 1/1", u.done, u.total)
	}
	if leaving.calls.Load() != 1 || joining.calls.Load() != 0 {
		t.Errorf("这一轮问了 leaving=%d joining=%d 次,期望 1、0", leaving.calls.Load(), joining.calls.Load())
	}

	updates, finished = startSnapshotRound(context.Background())
	if got := recvWithin(t, finished, "下一轮结束"); !slices.Equal(got, []string{"dyn:joining"}) {
		t.Errorf("下一轮的结果 %v,期望 [dyn:joining]", got)
	}
	if u := lastUpdate(updates); u.done != 1 || u.total != 1 {
		t.Errorf("下一轮最后的进度 %d/%d,期望 1/1", u.done, u.total)
	}
	if leaving.calls.Load() != 1 || joining.calls.Load() != 1 {
		t.Errorf("两轮合计问了 leaving=%d joining=%d 次,期望 1、1", leaving.calls.Load(), joining.calls.Load())
	}
}

// 好几轮搜索同时在跑、另一头不停地登记注销:每一轮都跑得完,进度数得到头,问到的来源跟出候选的来源对得上。
func TestRoundsSurviveConcurrentRegistration(t *testing.T) {
	builtinSourcesOff(t)
	a, b := newCountingDynamicSource("dyn:a"), newCountingDynamicSource("dyn:b")
	useDynamicLyricProviders(t, a)
	sets := [][]LyricProvider{{a}, {a, b}, {b}, nil}
	stop := make(chan struct{})
	var flips atomic.Int32
	var flipper sync.WaitGroup
	flipper.Add(1)
	go func() {
		defer flipper.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			if err := setDynamicLyricProviders(sets[i%len(sets)]); err != nil {
				t.Errorf("登记被拒:%v", err)
				return
			}
			flips.Add(1)
			runtime.Gosched()
		}
	}()
	var rounds sync.WaitGroup
	for w := 0; w < 4; w++ {
		rounds.Add(1)
		go func() {
			defer rounds.Done()
			for i := 0; i < 6; i++ {
				var last snapshotRoundUpdate
				_, scored := fetchScoredLyricCandidatesStreaming(context.Background(), "Snapshot Artist", "Snapshot Song", "", 70,
					func(_ neteaseInfo, s []scoredLyricCandidateResult, done, total int) {
						last = snapshotRoundUpdate{scoredSources(s), done, total}
					})
				got := scoredSources(scored)
				if last.done != last.total || last.total != len(got) || last.total > 2 {
					t.Errorf("一轮结束时进度 %d/%d、候选 %v:分母、到齐、出候选的来源该是同一组", last.done, last.total, got)
				}
			}
		}()
	}
	done := make(chan struct{})
	go func() { rounds.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("30 秒里那几轮没跑完")
	}
	close(stop)
	flipper.Wait()
	if flips.Load() == 0 || a.calls.Load()+b.calls.Load() == 0 {
		t.Errorf("登记注销换了 %d 次、两个来源合计被问 %d 次:这条用例没测到东西", flips.Load(), a.calls.Load()+b.calls.Load())
	}
}

// 登记着的时候:各份名单是内置的那一份后面接上运行时登记的,内置之间的先后一项不动;登记时自报的名次不算数。
// 注销之后:当前生效的又是内置那一份,它不再被问。
func TestDynamicSourcesRankAfterBuiltinAndLeaveNoTrace(t *testing.T) {
	builtinSourcesOff(t)
	builtin := builtinLyricRegistry()
	frozen := renderRegistryLists(builtin)
	first := newDynamicStub("dyn:first", nil)
	first.desc.Order, first.desc.TieRank, first.desc.DefaultPriorityRank = 1, 1, 1
	first.desc.InstrumentalRank, first.desc.SongwritersRank = 1, 1
	first.desc.Assembly.Instrumental = instrumentalDeclared
	second := newDynamicStub("dyn:second", nil)
	second.desc.SongwritersRank = -5
	useDynamicLyricProviders(t, first, second)

	cur := lyricProviders()
	both := []string{"dyn:first", "dyn:second"}
	for label, pair := range map[string][2][]string{
		"networkNames":             {cur.networkNames, append(slices.Clone(builtin.networkNames), both...)},
		"tieOrder":                 {cur.tieOrder, append(slices.Clone(builtin.tieOrder), both...)},
		"defaultPriorityOrder":     {cur.defaultPriorityOrder, append(slices.Clone(builtin.defaultPriorityOrder), both...)},
		"instrumentalOrder":        {cur.instrumentalOrder, append(slices.Clone(builtin.instrumentalOrder), "dyn:first")},
		"songwritersOrder":         {cur.songwritersOrder, append(slices.Clone(builtin.songwritersOrder), both...)},
		"dynamicPriorityNames":     {cur.dynamicPriorityNames, both},
		"priorityPlayerLocalNames": {cur.priorityPlayerLocalNames, builtin.priorityPlayerLocalNames},
		"priorityFileNames":        {cur.priorityFileNames, builtin.priorityFileNames},
		"playerNoVocalsNames":      {cur.playerNoVocalsNames, builtin.playerNoVocalsNames},
	} {
		if !slices.Equal(pair[0], pair[1]) {
			t.Errorf("%s = %v\n期望 %v", label, pair[0], pair[1])
		}
	}
	if len(cur.peerGroups) != len(builtin.peerGroups) || len(cur.hostRates) != len(builtin.hostRates) ||
		len(cur.hostOwners) != len(builtin.hostOwners) || len(cur.domainOwners) != len(builtin.domainOwners) {
		t.Error("同类组、主机令牌桶参数、主机归源表应跟内置那一份一样:运行时登记的来源不进这几张表")
	}
	for g, names := range builtin.peerGroups {
		if !slices.Equal(cur.peerGroups[g], names) {
			t.Errorf("同类组 %s = %v,期望 %v", g, cur.peerGroups[g], names)
		}
	}
	for i, d := range builtin.descriptors {
		if cur.descriptors[i] != d || cur.providers[i] != builtin.providers[i] {
			t.Fatalf("新的那份里第 %d 个来源应还是内置的 %s(同一份描述符、同一个实现)", i, d.Name)
		}
	}
	d := cur.descriptor("dyn:first")
	if d == first.desc || d.Origin != originDynamic || cur.provider("dyn:first").Descriptor() != d {
		t.Error("登记表里存的是描述符的副本,标着 originDynamic,实现交的也是这一份")
	}
	if frozenNow := renderRegistryLists(builtin); frozenNow != frozen {
		t.Error("登记运行时来源改到了内置那一份登记表")
	}

	// 同分时排在内置来源之后:同一份正文挂在一个内置源和它名下。
	same := lyricSourceResult{lyr: snapshotStubLRC, matchTitle: "Snapshot Song", matchArtist: "Snapshot Artist"}
	raw := map[string]lyricSourceResult{}
	for _, name := range []string{"dyn:first", lyricSourceGenie, "dyn:second"} {
		r := same
		r.source = name
		raw[name] = r
	}
	scored := rankLyricSourceResultsWith(cur, "Snapshot Artist", "Snapshot Song", "", 70, raw)
	if got := scoredSources(scored); !slices.Equal(got, []string{lyricSourceGenie, "dyn:first", "dyn:second"}) ||
		scored[0].Score != scored[1].Score || scored[1].Score != scored[2].Score {
		t.Errorf("三份同样的正文排出来 %v(分数 %d / %d / %d),期望同分、内置的 genie 在前、运行时登记的按登记先后",
			got, scored[0].Score, scored[1].Score, scored[2].Score)
	}

	// 顺序优先:排在用户顺序表的各名次之后,各占一个名次。
	tiers := priorityTiers()
	if n := len(tiers); n < 2 || !slices.Equal(tiers[n-2], []string{"dyn:first"}) || !slices.Equal(tiers[n-1], []string{"dyn:second"}) {
		t.Errorf("顺序优先的名次末尾应是运行时登记的两个来源:%v", tiers)
	}

	if err := setDynamicLyricProviders(nil); err != nil {
		t.Fatal(err)
	}
	if lyricProviders() != builtin || renderRegistryLists(lyricProviders()) != frozen {
		t.Error("注销之后当前生效的应就是内置那一份,名单逐项相同")
	}
	if tiersAfter := priorityTiers(); len(tiersAfter) != len(tiers)-2 {
		t.Errorf("注销之后顺序优先的名次 %v", tiersAfter)
	}
	_, finished := startSnapshotRound(context.Background())
	if got := recvWithin(t, finished, "注销之后的一轮"); len(got) != 0 {
		t.Errorf("注销之后的一轮不该有候选:%v", got)
	}
	if first.calls.Load() != 0 || second.calls.Load() != 0 {
		t.Errorf("注销之后还问了它们:first=%d second=%d", first.calls.Load(), second.calls.Load())
	}
}

// 设置里的源开关、顺序表只认内置来源;运行时登记的来源登记着就是开着,调度照联网源的规矩判它的名单、轮次、冷却。
func TestDynamicSourceIsEnabledByRegistration(t *testing.T) {
	builtinSourcesOff(t)
	dyn := newDynamicStub("dyn:switchless", nil)
	onDemand := newDynamicStub("dyn:ondemand", nil)
	onDemand.desc.Rounds = roundsOnDemand
	if lyricSourceEnabled("dyn:switchless") {
		t.Fatal("登记之前,设置里没列它就是没开")
	}
	useDynamicLyricProviders(t, dyn, onDemand)
	if !lyricSourceEnabled("dyn:switchless") || enabledLyricSourceCount() != 2 ||
		!slices.Equal(enabledNetworkLyricSources(), []string{"dyn:switchless", "dyn:ondemand"}) {
		t.Errorf("登记着就是开着:enabled=%v count=%d sources=%v", lyricSourceEnabled("dyn:switchless"), enabledLyricSourceCount(), enabledNetworkLyricSources())
	}
	if got := resolveLyricsSources([]string{"dyn:switchless"}); len(got) != len(lyricSourceNames) || got["dyn:switchless"] {
		t.Errorf("启用列表里只有运行时登记的来源的名字时,按全部内置联网源兜底、不含它:%v", sortedKeys(got))
	}
	if got := resolveLyricsSourceOrder([]string{"dyn:switchless", lyricSourceQQ}); slices.Contains(got, "dyn:switchless") ||
		got[0] != lyricSourceQQ || len(got) != len(lyricSourceNames)+1 {
		t.Errorf("顺序表不收运行时登记的来源:%v", got)
	}
	cur := lyricProviders()
	d, od := cur.descriptor("dyn:switchless"), cur.descriptor("dyn:ondemand")
	cooling := lyricSourceRoundPlan{"dyn:switchless": time.Minute}
	off := func(string) bool { return false }
	for _, c := range []struct {
		name string
		plan lyricRoundPlan
		d    *ProviderDescriptor
		want providerRoundDecision
	}{
		{"设置里关着也问", lyricRoundPlan{primary: true, enabled: off}, d, providerRoundQuery},
		{"别名轮名单外不问", lyricRoundPlan{enabled: off, only: map[string]bool{lyricSourceQQ: true}}, d, providerRoundSkipSilent},
		{"别名轮名单里问", lyricRoundPlan{enabled: off, only: map[string]bool{"dyn:switchless": true}}, d, providerRoundQuery},
		{"冷却中记跳过", lyricRoundPlan{enabled: off, cooling: cooling}, d, providerRoundSkipCooling},
		{"只在播放那一侧问的、批量轮次不问", lyricRoundPlan{enabled: off}, od, providerRoundSkipSilent},
		{"只在播放那一侧问的、播放时问", lyricRoundPlan{enabled: off, onDemand: true}, od, providerRoundQuery},
	} {
		if got := c.plan.decide(c.d); got != c.want {
			t.Errorf("%s:处置 %d,期望 %d", c.name, got, c.want)
		}
	}
	builtinD := cur.descriptor(lyricSourceQQ)
	if got := (lyricRoundPlan{primary: true, enabled: off}).decide(builtinD); got != providerRoundSkipSilent {
		t.Errorf("内置源照旧看设置里的开关:处置 %d", got)
	}
}

// privilegedDynamicStub:登记进来的实现自己实现了带特权的可选接口,也实现了两个失败原因接口。
type privilegedDynamicStub struct {
	stubLyricProvider
	offlineCalls, hintCalls, isrcCalls atomic.Int32
}

func (p *privilegedDynamicStub) ResolveOffline(ProviderQuery) (SourceResult, bool) {
	p.offlineCalls.Add(1)
	return SourceResult{lyr: snapshotStubLRC}, true
}
func (p *privilegedDynamicStub) HintsNoVocals(ProviderQuery) bool { p.hintCalls.Add(1); return true }
func (p *privilegedDynamicStub) HasISRC(string) bool              { p.isrcCalls.Add(1); return true }
func (p *privilegedDynamicStub) QueryIndependentFailure() string  { return "dyn_auth" }
func (p *privilegedDynamicStub) DiagnosedFailure() string         { return "dyn_diag" }
func (p *privilegedDynamicStub) ProbeOwnTrack(context.Context) bool {
	return true
}

// 登记表里的运行时来源是包过一层的:带特权的可选接口问不到,结果里特权才能填的那几块不收,登记之后外面改描述符
// 改不到登记表里那一份。
func TestDynamicSourceGetsNoPrivilegedSurface(t *testing.T) {
	builtinSourcesOff(t)
	inner := &privilegedDynamicStub{}
	inner.desc = &ProviderDescriptor{Name: "dyn:greedy", Assembly: &CandidateAssembly{Reads: fieldCover},
		Probe: &ProbeTrack{Artist: "A", Title: "T"}}
	inner.resolve = func() SourceResult {
		return SourceResult{
			source: lyricSourceNetease, lyr: snapshotStubLRC, matchTitle: "Snapshot Song", matchArtist: "Snapshot Artist", matchCover: "https://own.example/c.jpg",
			identityFromLocalClient: true, forPlayingTrack: true, trackIDs: []string{"123"},
			ne:   neteaseInfo{Cover: "https://ne.example/c.jpg", SongURL: "https://ne.example/s", Artist: "X", FromLocalClient: true, Lyrics: "[00:01.00]ne"},
			amll: amllResult{lrc: "[00:01.00]amll"},
		}
	}
	useDynamicLyricProviders(t, inner)
	cur := lyricProviders()
	p, d := cur.provider("dyn:greedy"), cur.descriptor("dyn:greedy")
	if _, ok := p.(OfflineResolver); ok {
		t.Error("登记表里的运行时来源不该实现 OfflineResolver")
	}
	if _, ok := p.(PreSearchNoVocalsHinter); ok {
		t.Error("登记表里的运行时来源不该实现 PreSearchNoVocalsHinter")
	}
	if _, ok := p.(ISRCIndexProvider); ok {
		t.Error("登记表里的运行时来源不该实现 ISRCIndexProvider")
	}
	if f, ok := p.(QueryIndependentFailer); !ok || f.QueryIndependentFailure() != "dyn_auth" {
		t.Error("跟检索词无关的失败原因要转给登记进来的实现")
	}
	if f, ok := p.(FailureDiagnoser); !ok || f.DiagnosedFailure() != "dyn_diag" {
		t.Error("失败诊断要转给登记进来的实现")
	}
	if probe := ownLyricSourceProbe("dyn:greedy"); probe == nil || !probe(context.Background()) {
		t.Error("带探测曲的运行时来源,探测转给登记进来的实现")
	}
	if playerNoVocalsHintBeforeSearch(cur, ProviderQuery{}) || lyricSourceTakesISRC("dyn:greedy", "USRC17607839") ||
		inner.hintCalls.Load() != 0 || inner.isrcCalls.Load() != 0 {
		t.Error("开搜前的无人声提示、按 ISRC 补取都不问运行时登记的来源")
	}

	// 冷却的那一轮不读本机那条腿;照常问的那一轮,结果封口。
	cooling := lyricRoundPlan{primary: true, enabled: lyricSourceEnabled, cooling: lyricSourceRoundPlan{"dyn:greedy": time.Minute}}
	if r := runLyricProvider(context.Background(), p, ProviderQuery{}, RoundEnv{}, cooling); r.lyr != "" || inner.offlineCalls.Load() != 0 {
		t.Errorf("冷却时不该读运行时登记的来源的本机那条腿:%+v", r)
	}
	r := runLyricProvider(context.Background(), p, ProviderQuery{}, RoundEnv{ForPlayingTrack: true}, lyricRoundPlan{primary: true, enabled: lyricSourceEnabled})
	want := SourceResult{source: "dyn:greedy", lyr: snapshotStubLRC, matchTitle: "Snapshot Song", matchArtist: "Snapshot Artist", matchCover: "https://own.example/c.jpg"}
	if !slices.Equal(r.trackIDs, want.trackIDs) || r.source != want.source || r.lyr != want.lyr || r.matchCover != want.matchCover ||
		r.identityFromLocalClient || r.forPlayingTrack || r.ne != (neteaseInfo{}) || r.amll.lrc != "" {
		t.Errorf("封口之后只该剩公共栏:%+v", r)
	}

	// 登记之后改外面那份描述符:登记表里的那一份不变,调度按登记表里那一份放行。
	inner.desc.Privileges = privLocalClientIdentity | privPlaybackTrackIDs
	inner.desc.Name = "dyn:renamed"
	inner.desc.Assembly.Reads |= fieldLocalIdentity
	inner.desc.Probe.Title = "changed"
	if d.Privileges != 0 || d.Name != "dyn:greedy" || d.Assembly.Reads != fieldCover || d.Probe.Title != "T" || cur.descriptor("dyn:renamed") != nil {
		t.Errorf("登记之后外面改描述符,登记表里那一份跟着变了:%+v", d)
	}
	runLyricProvider(context.Background(), p, ProviderQuery{}, RoundEnv{identityArtist: "tag artist"}, lyricRoundPlan{primary: true, enabled: lyricSourceEnabled})
	if a, _, _ := inner.gotEnv.IdentityFields(); a != "" || inner.gotEnv.granted != 0 {
		t.Errorf("调度交给它的环境带了特权:%+v", inner.gotEnv)
	}
}

// 登记校验:每一条各拿一个只犯这一条的描述符去登记,都被拒、报对应的规则,当前生效的登记表原样不动;一组里有一个被拒,
// 整组都不登记。
func TestDynamicSourceRegistrationRules(t *testing.T) {
	before := lyricProviders()
	probing := func(mutate func(d *ProviderDescriptor)) LyricProvider {
		p := &privilegedDynamicStub{}
		p.desc = &ProviderDescriptor{Name: "dyn:candidate", Assembly: &CandidateAssembly{}}
		mutate(p.desc)
		return p
	}
	plain := func(mutate func(d *ProviderDescriptor)) LyricProvider {
		p := newDynamicStub("dyn:candidate", nil)
		mutate(p.desc)
		return p
	}
	cases := []struct {
		rule string
		p    LyricProvider
	}{
		{dynamicSourceRuleProvider, nil},
		{dynamicSourceRuleProvider, &stubLyricProvider{}},
		{dynamicSourceRuleName, plain(func(d *ProviderDescriptor) { d.Name = "" })},
		{dynamicSourceRuleName, plain(func(d *ProviderDescriptor) { d.Name = "dyn candidate" })},
		{dynamicSourceRuleName, plain(func(d *ProviderDescriptor) { d.Name = "dyn\ncandidate" })},
		{dynamicSourceRuleName, plain(func(d *ProviderDescriptor) { d.Name = "dyn\u3000candidate" })},
		{dynamicSourceRuleNameBuiltin, plain(func(d *ProviderDescriptor) { d.Name = lyricSourceNetease })},
		{dynamicSourceRuleNameBuiltin, plain(func(d *ProviderDescriptor) { d.Name = importLyricsSource })},
		{dynamicSourceRuleNameReserved, plain(func(d *ProviderDescriptor) { d.Name = retiredLyricSources[0] })},
		{dynamicSourceRuleNameReserved, plain(func(d *ProviderDescriptor) { d.Name = lyricsPriorityPlayerLocal })},
		{dynamicSourceRuleKind, plain(func(d *ProviderDescriptor) { d.Kind = providerKindPlayerLocal })},
		{dynamicSourceRuleKind, plain(func(d *ProviderDescriptor) { d.Kind = providerKindUserLibrary })},
		{dynamicSourceRulePrivileges, plain(func(d *ProviderDescriptor) { d.Privileges = privLocalClientIdentity })},
		{dynamicSourceRulePrivileges, plain(func(d *ProviderDescriptor) { d.Privileges = privBreakerControl })},
		{dynamicSourceRuleDependsOnIDs, plain(func(d *ProviderDescriptor) { d.DependsOnIDsFrom = []string{lyricSourceNetease} })},
		{dynamicSourceRuleRounds, plain(func(d *ProviderDescriptor) { d.Rounds = roundsPrimaryOnly })},
		{dynamicSourceRulePriorityPlacement, plain(func(d *ProviderDescriptor) { d.PriorityPlacement = priorityAboveAll })},
		{dynamicSourceRulePriorityPlacement, plain(func(d *ProviderDescriptor) { d.PriorityPlacement = priorityFileLyrics })},
		{dynamicSourceRuleAssembly, plain(func(d *ProviderDescriptor) { d.Assembly = nil })},
		{dynamicSourceRuleBorrowFromPeers, plain(func(d *ProviderDescriptor) {
			d.Assembly.BorrowFromPeers = func(lyricSourceResult, map[string]lyricSourceResult) peerBorrow { return peerBorrow{} }
		})},
		{dynamicSourceRuleUnpack, plain(func(d *ProviderDescriptor) {
			d.Assembly.Unpack = func(r lyricSourceResult) lyricSourceResult { return r }
		})},
		{dynamicSourceRuleAcceptTranslation, plain(func(d *ProviderDescriptor) {
			d.Assembly.AcceptTranslation = func(string, string, string, string, string) bool { return true }
		})},
		{dynamicSourceRuleLocalIdentity, plain(func(d *ProviderDescriptor) { d.Assembly.Reads = fieldCover | fieldLocalIdentity })},
		{dynamicSourceRuleTranslation, plain(func(d *ProviderDescriptor) { d.Assembly.Translation = translationFixed })},
		{dynamicSourceRuleTranslation, plain(func(d *ProviderDescriptor) {
			d.Assembly.Translation, d.Assembly.TranslationLang = translationTarget, "zh"
		})},
		{dynamicSourceRuleBaked, plain(func(d *ProviderDescriptor) { d.Baked = bakedCustom })},
		{dynamicSourceRuleBaked, plain(func(d *ProviderDescriptor) {
			d.BakedSplit = func(string, bool) (string, string, int) { return "", "", 0 }
		})},
		{dynamicSourceRulePageURL, plain(func(d *ProviderDescriptor) { d.PageURL = func(raw string) string { return raw } })},
		{dynamicSourceRulePlainText, plain(func(d *ProviderDescriptor) { d.PlainText = plainTextFirst })},
		{dynamicSourceRuleConsensusFamily, plain(func(d *ProviderDescriptor) { d.ConsensusFamily = lyricSourceLyricFind })},
		{dynamicSourceRuleISRC, plain(func(d *ProviderDescriptor) { d.ISRCLookup = isrcLookupDirect })},
		{dynamicSourceRuleISRC, plain(func(d *ProviderDescriptor) { d.ISRCLookup = isrcLookupIndexed })},
		{dynamicSourceRuleISRC, plain(func(d *ProviderDescriptor) { d.ISRCAuthority = true })},
		{dynamicSourceRulePeerGroup, plain(func(d *ProviderDescriptor) { d.PeerGroup = peerGroupGlobal })},
		{dynamicSourceRuleHosts, plain(func(d *ProviderDescriptor) { d.Hosts = []HostRule{{"dyn.example", hostExact}} })},
		{dynamicSourceRuleHosts, plain(func(d *ProviderDescriptor) {
			d.HostRates = map[string]hostRate{"lrclib.net": {perSec: 100, burst: 100}}
		})},
		{dynamicSourceRuleLimits, plain(func(d *ProviderDescriptor) { d.MaxInflight = -1 })},
		{dynamicSourceRuleLimits, plain(func(d *ProviderDescriptor) { d.HourlyBudget = -1 })},
		{dynamicSourceRuleLimits, plain(func(d *ProviderDescriptor) { d.DayQuotaReserve = -1 })},
		{dynamicSourceRuleProbe, plain(func(d *ProviderDescriptor) { d.Probe = &ProbeTrack{Artist: "A", Title: "T"} })},
		{dynamicSourceRuleProbe, probing(func(d *ProviderDescriptor) { d.Probe = &ProbeTrack{Artist: "A"} })},
		{dynamicSourceRuleProbe, probing(func(d *ProviderDescriptor) { d.Probe = &ProbeTrack{Title: "T"} })},
	}
	seenRules := map[string]bool{}
	for i, c := range cases {
		good := newDynamicStub("dyn:good", nil)
		for _, set := range [][]LyricProvider{{c.p}, {good, c.p}, {c.p, good}} {
			err := setDynamicLyricProviders(set)
			var rejected *dynamicSourceError
			if !errors.As(err, &rejected) {
				t.Errorf("第 %d 条(%s):应被拒,得到 %v", i, c.rule, err)
				_ = setDynamicLyricProviders(nil)
				continue
			}
			if rejected.Rule != c.rule {
				t.Errorf("第 %d 条:报的规则 %q(%v),期望 %q", i, rejected.Rule, err, c.rule)
			}
			if lyricProviders() != before {
				t.Fatalf("第 %d 条(%s):被拒之后当前生效的登记表变了", i, c.rule)
			}
		}
		seenRules[c.rule] = true
	}
	if err := setDynamicLyricProviders([]LyricProvider{newDynamicStub("dyn:twice", nil), newDynamicStub("dyn:twice", nil)}); err == nil ||
		err.(*dynamicSourceError).Rule != dynamicSourceRuleNameDuplicate || lyricProviders() != before {
		t.Errorf("一组里重名应被拒:%v", err)
	}
	seenRules[dynamicSourceRuleNameDuplicate] = true
	// 规则代码一条不落:lyricproviderdynamic.go 里声明的每一条都在上面试过。
	src := string(mustRead(t, "lyricproviderdynamic.go"))
	declared := 0
	for _, line := range strings.Split(src, "\n") {
		name, rest, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok || !strings.HasPrefix(name, "dynamicSourceRule") {
			continue
		}
		declared++
		code := strings.Trim(strings.TrimSpace(strings.SplitN(rest, "//", 2)[0]), `"`)
		if !seenRules[code] {
			t.Errorf("规则 %s(%q)没有被拒的用例", strings.TrimSpace(name), code)
		}
	}
	if declared != len(seenRules) || declared < 20 {
		t.Errorf("声明了 %d 条规则,试过 %d 条", declared, len(seenRules))
	}

	// 都合规的一组登记得上;合规的字段原样留在登记表里那一份上。
	ok := newDynamicStub("plugin:ok", nil)
	ok.desc.Rounds, ok.desc.MaxInflight, ok.desc.HourlyBudget, ok.desc.DayQuotaReserve = roundsOnDemand, 2, 120, 5
	ok.desc.ProxyFallback, ok.desc.ParenBackground, ok.desc.CarriesKana, ok.desc.HandTypedTimeline = true, true, true, true
	ok.desc.Baked, ok.desc.PlainText, ok.desc.SongwritersSkipCJK = bakedStripOnly, plainTextLast, true
	ok.desc.Assembly = &CandidateAssembly{Reads: fieldWordTiming | fieldRomanization | fieldCover | fieldPlainText,
		Translation: translationFixed, TranslationLang: "zh", Instrumental: instrumentalDeclared}
	useDynamicLyricProviders(t, ok)
	got := *lyricProviders().descriptor("plugin:ok")
	want := *ok.desc
	want.Origin, want.Order, want.TieRank, want.DefaultPriorityRank = originDynamic, len(lyricSourceNames)+1, len(lyricCandidateTieOrder)+1, len(lyricSourceNames)+1
	gotAssembly, wantAssembly := *got.Assembly, *ok.desc.Assembly
	got.Assembly, want.Assembly = nil, nil
	if !reflect.DeepEqual(got, want) || !reflect.DeepEqual(gotAssembly, wantAssembly) {
		t.Errorf("登记表里那一份 %+v(Assembly %+v)\n期望 %+v(Assembly %+v)", got, gotAssembly, want, wantAssembly)
	}
	if lyricSourceMaxInflight("plugin:ok") != 2 || lyricSourceBudgetPerHour("plugin:ok") != 120 || lyricSourceDayReserve("plugin:ok") != 5 ||
		!lyricSourceUsesProxyFallback("plugin:ok") || !onDemandOnlyLyricSource("plugin:ok") || !lyricSourceSplitsParenBackground("plugin:ok") ||
		!lyricSourceCarriesKana("plugin:ok") || lyricSourcePlainTextOrder("plugin:ok") != plainTextLast || lyricSourceOwningHost("plugin.example") != "" {
		t.Error("按源名读的那几项应读得到运行时登记的来源的值")
	}
}

// 好几处同时换运行时登记的来源:每次换上的都是完整的一份(内置的加某一组),不会换出半份。
func TestConcurrentDynamicRegistrationStaysWhole(t *testing.T) {
	builtin := builtinLyricRegistry()
	t.Cleanup(func() { _ = setDynamicLyricProviders(nil) })
	var wg sync.WaitGroup
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				var set []LyricProvider
				for k := 0; k < (w+i)%3; k++ {
					set = append(set, newDynamicStub(fmt.Sprintf("dyn:w%d-%d", w, k), nil))
				}
				if err := setDynamicLyricProviders(set); err != nil {
					t.Errorf("登记被拒:%v", err)
					return
				}
				cur := lyricProviders()
				if n := len(cur.descriptors) - len(builtin.descriptors); n < 0 || n > 2 || len(cur.dynamicPriorityNames) != n ||
					len(cur.networkNames) != len(builtin.networkNames)+n || len(cur.tieOrder) != len(builtin.tieOrder)+n ||
					!slices.Equal(cur.tieOrder[:len(builtin.tieOrder)], builtin.tieOrder) {
					t.Errorf("读到的登记表不完整:%d 个来源、运行时登记的 %v", len(cur.descriptors), cur.dynamicPriorityNames)
					return
				}
			}
		}()
	}
	wg.Wait()
}
