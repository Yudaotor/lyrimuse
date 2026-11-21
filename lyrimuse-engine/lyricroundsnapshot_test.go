package main

import (
	"bytes"
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"runtime"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// 一轮搜索开搜时取一次登记表、用到这一轮结束:派谁、结果通道的缓冲、进度、到齐、候选怎么装、同分谁赢都出自那一份,
// 中途当前生效的登记表换了也不跟着变。

const snapshotStubLRC = "[00:10.00]First line of the song\n[00:20.00]Second line follows it\n[00:30.00]Third line ends the verse\n" +
	"[00:40.00]Fourth line starts again\n[00:50.00]Fifth line of the song\n[01:00.00]Sixth line closes it\n"

// snapshotStub:一个假的联网源,名次都是 rank,交一份带时间轴的正文;gate 非 nil 时等它关了才交。
func snapshotStub(name string, rank int, gate chan struct{}) *stubLyricProvider {
	p := &stubLyricProvider{desc: &ProviderDescriptor{
		Name: name, Order: rank, TieRank: rank, DefaultPriorityRank: rank, Assembly: &CandidateAssembly{},
	}}
	p.resolve = func() SourceResult {
		if gate != nil {
			<-gate
		}
		return SourceResult{lyr: snapshotStubLRC, matchTitle: "Snapshot Song", matchArtist: "Snapshot Artist"}
	}
	return p
}

// snapshotRoundUpdate:一次进度回调里的候选来源(按排好的先后)和进度。
type snapshotRoundUpdate struct {
	sources     []string
	done, total int
}

// startSnapshotRound 在后台跑一轮,进度回调和最终结果各走一个通道。
func startSnapshotRound(ctx context.Context) (updates chan snapshotRoundUpdate, finished chan []string) {
	updates, finished = make(chan snapshotRoundUpdate, 16), make(chan []string, 1)
	go func() {
		_, scored := fetchScoredLyricCandidatesStreaming(ctx, "Snapshot Artist", "Snapshot Song", "", 70,
			func(_ neteaseInfo, scored []scoredLyricCandidateResult, done, total int) {
				updates <- snapshotRoundUpdate{scoredSources(scored), done, total}
			})
		finished <- scoredSources(scored)
	}()
	return updates, finished
}

func recvWithin[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(5 * time.Second):
		t.Fatalf("5 秒里没等到%s", what)
		panic("unreachable")
	}
}

// waitNoGoroutineIn 等到没有 goroutine 的调用栈里带 frame。
func waitNoGoroutineIn(t *testing.T, frame string) {
	t.Helper()
	buf := make([]byte, 8<<20)
	for deadline := time.Now().Add(3 * time.Second); ; time.Sleep(time.Millisecond) {
		stuck := 0
		for _, g := range bytes.Split(buf[:runtime.Stack(buf, true)], []byte("\n\n")) {
			if bytes.Contains(g, []byte(frame)) {
				stuck++
			}
		}
		if stuck == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("3 秒后还有 %d 个 goroutine 停在 %s 里", stuck, frame)
		}
	}
}

// 一轮进行中当前生效的登记表换了(一个源撤掉、一个源加进来):这一轮照开搜时那一份跑完。撤掉的那个源晚到的结果照收、
// 照那一份的描述符装成候选、同分时照那一份的决胜序排;新加的源这一轮不问;进度的分母不变、数得到头。下一轮才用新的。
func TestRoundKeepsItsRegistrySnapshot(t *testing.T) {
	useFreshOutboundState(t)
	enableOnlyLyricSources(t, "snap-a", "snap-b", "snap-c")
	gate := make(chan struct{})
	a, b, c := snapshotStub("snap-a", 2, nil), snapshotStub("snap-b", 1, gate), snapshotStub("snap-c", 3, nil)
	first := newLyricProviderRegistry([]LyricProvider{a, b})
	next := newLyricProviderRegistry([]LyricProvider{a, c})
	useLyricRegistry(t, first)

	updates, finished := startSnapshotRound(context.Background())
	if u := recvWithin(t, updates, "第一份结果"); !slices.Equal(u.sources, []string{"snap-a"}) || u.done != 1 || u.total != 2 {
		t.Fatalf("snap-a 到达时:%+v,期望候选 [snap-a]、进度 1/2", u)
	}
	lyricRegistryCurrent.Store(next)
	close(gate)
	if u := recvWithin(t, updates, "第二份结果"); !slices.Equal(u.sources, []string{"snap-b", "snap-a"}) || u.done != 2 || u.total != 2 {
		t.Errorf("换登记表之后 snap-b 到达:%+v,期望候选 [snap-b snap-a](同分按开搜时那份的决胜序)、进度 2/2", u)
	}
	if got := recvWithin(t, finished, "这一轮结束"); !slices.Equal(got, []string{"snap-b", "snap-a"}) {
		t.Errorf("这一轮的结果 %v,期望 [snap-b snap-a]", got)
	}
	if a.calls.Load() != 1 || b.calls.Load() != 1 || c.calls.Load() != 0 {
		t.Errorf("这一轮问了 a=%d b=%d c=%d 次,期望 1、1、0:中途加进来的源这一轮不问", a.calls.Load(), b.calls.Load(), c.calls.Load())
	}
	select {
	case u := <-updates:
		t.Errorf("这一轮多出一次回调 %+v", u)
	default:
	}

	updates, finished = startSnapshotRound(context.Background())
	if got := recvWithin(t, finished, "下一轮结束"); !slices.Equal(got, []string{"snap-a", "snap-c"}) {
		t.Errorf("下一轮的结果 %v,期望 [snap-a snap-c]", got)
	}
	var last snapshotRoundUpdate
	for len(updates) > 0 {
		last = <-updates
	}
	if last.done != 2 || last.total != 2 {
		t.Errorf("下一轮最后一次回调的进度 %d/%d,期望 2/2", last.done, last.total)
	}
	if a.calls.Load() != 2 || b.calls.Load() != 1 || c.calls.Load() != 1 {
		t.Errorf("两轮合计问了 a=%d b=%d c=%d 次,期望 2、1、1:撤掉的源下一轮不问、新加的源下一轮问", a.calls.Load(), b.calls.Load(), c.calls.Load())
	}
}

// 结果通道放得下这一轮每个联网源各一份:循环被取消、不再收了,晚到的源照样送得进去,不留挂着的 goroutine;中途登记表
// 换成源更少的一份也一样。
func TestRoundResultBufferHoldsEverySnapshotSource(t *testing.T) {
	useFreshOutboundState(t)
	enableOnlyLyricSources(t, "snap-a", "snap-b", "snap-c")
	gate := make(chan struct{})
	a, b, c := snapshotStub("snap-a", 1, gate), snapshotStub("snap-b", 2, gate), snapshotStub("snap-c", 3, gate)
	useLyricRegistry(t, newLyricProviderRegistry([]LyricProvider{a, b, c}))
	ctx, cancel := context.WithCancel(context.Background())
	_, finished := startSnapshotRound(ctx)
	waitGoroutineParkedIn(t, "snapshotStub")
	lyricRegistryCurrent.Store(newLyricProviderRegistry([]LyricProvider{a}))
	cancel()
	if got := recvWithin(t, finished, "被取消的这一轮返回"); len(got) != 0 {
		t.Errorf("被取消时一个源都没回来,结果应为空:%v", got)
	}
	close(gate)
	waitNoGoroutineIn(t, "startLyricProviders")
	if a.calls.Load() != 1 || b.calls.Load() != 1 || c.calls.Load() != 1 {
		t.Errorf("三个源各问一次:a=%d b=%d c=%d", a.calls.Load(), b.calls.Load(), c.calls.Load())
	}
}

// 排序只读传给它的那份登记表:哪些来源出候选、怎么摊平、同分谁赢、纯音乐标记记在谁头上、「有歌没词」标记的先后、
// 拆不拆括号背景人声,都跟当前生效的那份没有关系。
func TestRankReadsOnlyTheGivenRegistry(t *testing.T) {
	lrc := []string{"[00:01.00]Kills me slowly (slowly)", "[00:05.00]No parens here", "[00:09.00]Another line to sing", "[00:13.00]And the last one"}
	yrc := []string{yrcLine(1000, "Kills me slowly (slowly)"), yrcLine(5000, "No parens here"), yrcLine(9000, "Another line to sing"), yrcLine(13000, "And the last one")}
	body, words := strings.Join(lrc, "\n"), strings.Join(yrc, "\n")
	stub := func(d *ProviderDescriptor) LyricProvider { return &stubLyricProvider{desc: d} }
	reg := newLyricProviderRegistry([]LyricProvider{
		stub(&ProviderDescriptor{Name: "rank-plain", Order: 1, TieRank: 2, Assembly: &CandidateAssembly{}}),
		stub(&ProviderDescriptor{Name: "rank-first", Order: 2, TieRank: 1, Assembly: &CandidateAssembly{}}),
		stub(&ProviderDescriptor{Name: "rank-paren", Order: 3, TieRank: 3, ParenBackground: true,
			Assembly: &CandidateAssembly{Reads: fieldWordTiming}}),
		stub(&ProviderDescriptor{Name: "rank-unpack", Order: 4, TieRank: 4, Assembly: &CandidateAssembly{
			Unpack: func(r lyricSourceResult) lyricSourceResult {
				r.lyr, r.matchTitle, r.matchArtist = r.untimed, "Slowly", "Somebody"
				return r
			}}}),
		stub(&ProviderDescriptor{Name: "rank-inst-late", Order: 5, TieRank: 5, InstrumentalRank: 2,
			Assembly: &CandidateAssembly{Instrumental: instrumentalDeclared}}),
		stub(&ProviderDescriptor{Name: "rank-inst-early", Order: 6, TieRank: 6, InstrumentalRank: 1,
			Assembly: &CandidateAssembly{Instrumental: instrumentalDeclared}}),
		stub(&ProviderDescriptor{Name: "rank-nolyrics-b", Order: 8, TieRank: 8, Assembly: &CandidateAssembly{}}),
		stub(&ProviderDescriptor{Name: "rank-nolyrics-a", Order: 7, TieRank: 7, Assembly: &CandidateAssembly{}}),
	})
	plain := lyricSourceResult{lyr: snapshotStubLRC, matchTitle: "Slowly", matchArtist: "Somebody"}
	raw := map[string]lyricSourceResult{
		"rank-plain": plain, "rank-first": plain,
		"rank-paren":      {lyr: body, yrc: words, matchTitle: "Slowly", matchArtist: "Somebody"},
		"rank-unpack":     {untimed: snapshotStubLRC},
		"rank-inst-late":  {instrumental: true},
		"rank-inst-early": {instrumental: true},
		"rank-nolyrics-a": {trackFoundNoLyrics: true, matchTitle: "Slowly"},
		"rank-nolyrics-b": {trackFoundNoLyrics: true, matchTitle: "Slowly"},
		// 同样的内容挂在内置源的名字上:reg 里没有它们,不出候选。
		lyricSourceKugou: {lyr: body, yrc: words, matchTitle: "Slowly", matchArtist: "Somebody"},
	}
	for name, r := range raw {
		r.source = name
		raw[name] = r
	}
	if cur := lyricProviders(); cur.descriptor("rank-plain") != nil || cur.descriptor(lyricSourceKugou) == nil {
		t.Fatal("这条用例要在当前生效的登记表是内置那一份时跑")
	}
	scored := rankLyricSourceResultsWith(reg, "Somebody", "Slowly", "", 70, raw)
	by := map[string]scoredLyricCandidateResult{}
	var candidates, noLyrics []string
	instrumental := ""
	for _, r := range scored {
		switch {
		case r.Instrumental:
			instrumental = r.Source
		case r.TrackFoundNoLyrics:
			noLyrics = append(noLyrics, r.Source)
		default:
			candidates = append(candidates, r.Source)
			by[r.Source] = r
		}
	}
	sorted := slices.Clone(candidates)
	sort.Strings(sorted)
	if want := []string{"rank-first", "rank-paren", "rank-plain", "rank-unpack"}; !slices.Equal(sorted, want) {
		t.Fatalf("出候选的来源 %v,期望 %v:只有传进来的那份登记表里的来源", sorted, want)
	}
	if by["rank-first"].Score != by["rank-plain"].Score || slices.Index(candidates, "rank-first") > slices.Index(candidates, "rank-plain") {
		t.Errorf("rank-first 和 rank-plain 同分(%d / %d),先后 %v:应按传进来的那份的决胜序,rank-first 在前",
			by["rank-first"].Score, by["rank-plain"].Score, candidates)
	}
	if by["rank-unpack"].Lyrics == "" || by["rank-unpack"].Title != "Slowly" {
		t.Errorf("rank-unpack 的内容该由它描述符的 Unpack 摊到公共栏:%+v", by["rank-unpack"])
	}
	if p := by["rank-paren"]; p.LyricsBG == "" || strings.Contains(p.Lyrics, "(slowly)") {
		t.Errorf("rank-paren 登记了拆括号背景人声:正文 %q,背景人声轨 %q", p.Lyrics, p.LyricsBG)
	}
	if instrumental != "rank-inst-early" {
		t.Errorf("纯音乐标记记在 %q 头上,期望名次靠前的 rank-inst-early", instrumental)
	}
	if want := []string{"rank-nolyrics-a", "rank-nolyrics-b"}; !slices.Equal(noLyrics, want) {
		t.Errorf("「有歌没词」标记 %v,期望按传进来的那份的联网源名单 %v", noLyrics, want)
	}

	// 同一份输入按当前生效的(内置的)那份排:只有内置源那一条,括号照内置的规矩拆。
	current := rankLyricSourceResults("Somebody", "Slowly", "", 70, raw)
	if got := scoredSources(current); !slices.Equal(got, []string{lyricSourceKugou}) {
		t.Errorf("按当前生效的登记表排,结果 %v,期望只有 kugou", got)
	}
}

// 按源名查的那几条规矩读传进来的登记表:信源家族、时间轴是不是手打的、是不是播放器本机的来源。
func TestScoringTraitsReadTheGivenRegistry(t *testing.T) {
	stub := func(d *ProviderDescriptor) LyricProvider { return &stubLyricProvider{desc: d} }
	reg := newLyricProviderRegistry([]LyricProvider{
		stub(&ProviderDescriptor{Name: "trait-hand", HandTypedTimeline: true}),
		stub(&ProviderDescriptor{Name: "trait-kin-a", ConsensusFamily: "trait-kin"}),
		stub(&ProviderDescriptor{Name: "trait-kin-b", ConsensusFamily: "trait-kin"}),
		stub(&ProviderDescriptor{Name: "trait-local", Kind: providerKindPlayerLocal}),
	})
	cur := lyricProviders()
	base := megalobizShiftedLRC(20, 10000, 8000, 0)
	shifted := megalobizShiftedLRC(20, 10000, 8000, 3000)
	batch := func() []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{
			{Source: "trait-hand", Lyrics: shifted, Score: 500, ConsensusPeers: []string{"trait-kin-a"}},
			{Source: "trait-kin-b", Lyrics: base, Score: 500},
		}
	}
	given, other := batch(), batch()
	applyHandTypedTimelinePenalty(reg, given)
	applyHandTypedTimelinePenalty(cur, other)
	if scoreTermPoints(given[0].ScoreTerms, scoreTermTimelineOffset) != -timelineOffsetPenalty {
		t.Errorf("传进来的登记表里 trait-hand 是手打时间轴、共识名单里的 trait-kin-a 跟在场的 trait-kin-b 同一家:该扣,%v", given[0].ScoreTerms)
	}
	if len(other[0].ScoreTerms) != 0 {
		t.Errorf("当前生效的登记表里没有这几个源,不该扣:%v", other[0].ScoreTerms)
	}

	cands := func() []lyricCandidate {
		return []lyricCandidate{
			{source: "trait-kin-a", lyrics: snapshotStubLRC, title: "song", artist: "someone"},
			{source: "trait-kin-b", lyrics: snapshotStubLRC, title: "song", artist: "someone"},
		}
	}
	if peers, _ := contentConsensusPeers(reg, "someone", "song", cands(), 0); len(peers["trait-kin-a"]) != 0 {
		t.Errorf("传进来的登记表里这两个源同一家,互不印证:%v", peers)
	}
	if peers, _ := contentConsensusPeers(cur, "someone", "song", cands(), 0); len(peers["trait-kin-a"]) != 1 {
		t.Errorf("当前生效的登记表里这两个源各自成家,互相印证:%v", peers)
	}

	local := nearMissCand("trait-local", 1400, 261)
	if sourceDurationNearMissApplies(reg, local, 280.7) || !sourceDurationNearMissApplies(cur, local, 280.7) {
		t.Error("自报曲长差出收紧档:传进来的登记表里 trait-local 是播放器本机的来源、不算;当前生效的那份不认得它、算")
	}
	if !reg.sourceKindIs("trait-local", providerKindPlayerLocal) || reg.sourceKindIs(kkboxLocalLyricsSource, providerKindPlayerLocal) {
		t.Error("sourceKindIs 只认这份登记表里登记的")
	}
	if reg.sourceFamily("trait-kin-a") != "trait-kin" || reg.sourceFamily(lyricSourceDeezer) != lyricSourceDeezer {
		t.Error("sourceFamily 只认这份登记表里登记的家族")
	}
}

// roundRegistryReaders:读当前生效的登记表的包级函数。一轮搜索的收集循环、调度里不许直接调它们。
var roundRegistryReaders = []string{
	"lyricProviders", "networkLyricSourceNames", "enabledLyricSourceCount", "enabledNetworkLyricSources", "enabledLyricSourceNames",
	"lyricSourceEnabled", "isNetworkLyricSource", "lyricSourceKindIs", "lyricSourceSplitsParenBackground", "lyricSourceCarriesKana",
	"lyricSourcePlainTextOrder", "lyricSourcePeerGroup", "onDemandOnlyLyricSource", "rankLyricSourceResults", "priorityTiers",
}

// engineCallGraph:生产代码里每个函数直接调了谁。键是包级函数名,方法是「.方法名」(同名的方法并在一个键下:按名字认,
// 宁可多连几条边)。只认调用(f(...)、x.m(...)),当值传的函数不算。
func engineCallGraph(t *testing.T) map[string]map[string]int {
	t.Helper()
	pkgs, err := parser.ParseDir(token.NewFileSet(), ".", func(fi fs.FileInfo) bool { return !strings.HasSuffix(fi.Name(), "_test.go") }, 0)
	if err != nil {
		t.Fatal(err)
	}
	calls := map[string]map[string]int{}
	for _, pkg := range pkgs {
		for _, f := range pkg.Files {
			for _, decl := range f.Decls {
				fd, ok := decl.(*ast.FuncDecl)
				if !ok || fd.Body == nil {
					continue
				}
				key := fd.Name.Name
				if fd.Recv != nil {
					key = "." + key
				}
				if calls[key] == nil {
					calls[key] = map[string]int{}
				}
				ast.Inspect(fd.Body, func(n ast.Node) bool {
					if call, ok := n.(*ast.CallExpr); ok {
						switch fun := call.Fun.(type) {
						case *ast.Ident:
							calls[key][fun.Name]++
						case *ast.SelectorExpr:
							calls[key]["."+fun.Sel.Name]++
						}
					}
					return true
				})
			}
		}
	}
	return calls
}

// 一轮搜索只在开搜时读一次当前生效的登记表:
//   - 收集循环里恰好一处 lyricProviders(),别的读当前登记表的包级函数一个都不调;
//   - 调度那几个函数自己不读;
//   - 排序(rankLyricSourceResultsWith)从头到尾、连它调到的每一层都读不到当前生效的登记表。设置(features、
//     currentLyricSources)是另一回事,不往里追。
func TestRoundReadsCurrentRegistryOnlyOnce(t *testing.T) {
	calls := engineCallGraph(t)
	collect := calls["fetchScoredLyricCandidatesStreaming"]
	if collect == nil {
		t.Fatal("找不到 fetchScoredLyricCandidatesStreaming")
	}
	if n := collect["lyricProviders"]; n != 1 {
		t.Errorf("收集循环里 lyricProviders() 出现 %d 次,应恰好一次(开搜时取这一轮的那份)", n)
	}
	for _, name := range roundRegistryReaders[1:] {
		if collect[name] > 0 {
			t.Errorf("收集循环里调了 %s():它读的是当前生效的登记表,这一轮要读开搜时取的那一份", name)
		}
	}
	for _, fn := range []string{"startLyricProviders", "runLocalLyricProviders", "runLyricProviderInRound", "runLyricProvider",
		"sealProviderResult", "offlineLegResult", ".decide", ".grantedTo", "newRoundTrackIDs", "playerNoVocalsHintBeforeSearch"} {
		if calls[fn] == nil {
			t.Errorf("找不到调度的函数 %s", fn)
			continue
		}
		for _, name := range roundRegistryReaders {
			if calls[fn][name] > 0 {
				t.Errorf("调度的 %s 里调了 %s():这一轮的来源由收集循环传进来,调度不自己读当前生效的登记表", fn, name)
			}
		}
	}

	stop := map[string]bool{"features": true, "featuresRef": true, "currentLyricSources": true}
	parent := map[string]string{"rankLyricSourceResultsWith": ""}
	queue := []string{"rankLyricSourceResultsWith"}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		if calls[cur]["lyricProviders"] > 0 {
			var path []string
			for x := cur; x != ""; x = parent[x] {
				path = append([]string{x}, path...)
			}
			t.Errorf("排序里读得到当前生效的登记表:%s —— 这一步要读传进来的那份(reg)", strings.Join(path, " > "))
			continue
		}
		next := make([]string, 0, len(calls[cur]))
		for callee := range calls[cur] {
			next = append(next, callee)
		}
		sort.Strings(next)
		for _, callee := range next {
			if _, seen := parent[callee]; seen || stop[callee] || calls[callee] == nil {
				continue
			}
			parent[callee] = cur
			queue = append(queue, callee)
		}
	}
	for _, step := range []string{"unpackSourceResults", "assembleSourceCandidate", ".inTieOrder", "splitCandidateParenBackground",
		"contentConsensusPeers", "applyTimelineOffsetPenalty", "applyHandTypedTimelinePenalty", "applyTimelineIntrusionPenalty",
		"applySourceDurationNearMissPenalty", "applyNativeSourceWordYield", "playerInstrumentalSource", "noLyricsMarkers",
		"scoreLyricCandidateDetailed"} {
		if _, reached := parent[step]; !reached {
			t.Errorf("从 rankLyricSourceResultsWith 没追到 %s:调用图没建对,上面那条守卫是空的", step)
		}
	}
}
