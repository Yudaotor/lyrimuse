package main

import "context"

// 救急别名轮并发:首轮一个可用候选都没有时,别名轮原来一位一位地串行全源重查,每位 3 秒上下,查不到歌词的歌要
// 十几二十秒才落定「暂无歌词」。这里让接下来的 lyricRescueParallel 位别名同时开查(一个滑动窗口),
// 而**采用**仍按原来的顺序一位一位来:主循环取第 i 位的结果、合并、判断要不要继续,跟串行时逐字一样;
// 并发只提前了「什么时候查」,不改「按什么顺序信」。哪一支先查到可用歌词,当场交给首轮先上屏
// (notifyProvisionalLyrics,见 provisionallyrics.go)。循环停下后,还没被取用的支线一律取消。
//
// 被取用时已经不在救急(前面某位别名救回来了、进入「补缺席的源」)的那一支,只留缺席那几个源的候选
// (keepLyricSources),跟串行时那一位只问缺席的源等价。
//
// 并发支线不往「搜索候选歌词」弹窗推流式进度:几支同时跑,完成数交错回跳,弹窗的轮次推导(searchcli.go
// 按「完成数变小 = 新一轮」)会乱;取用时把这一支的完整结果推一次。
//
// 请求量:只有首轮全空的歌(约 4%)会并发,出站由 hostguard.go 的令牌桶与在途上限管着(见那边的补查档)。
// 见 09 章决策 102 第七批。

// lyricRescueParallel:救急时同时在跑的别名支线最多几支。手动搜索补缺席的源时用同一个窗口。
const lyricRescueParallel = 3

// 手动搜索(「搜索候选歌词」弹窗,searchcli.go)的标记。只为补缺席的源跑的别名轮(首轮已有可用候选)在播放时
// 串行、一位位来;手动搜索时用户对着弹窗等,这几轮也按上面的窗口并发开查,采用顺序不变。出站同样受
// hostguard.go 的令牌桶(补查档给首轮留余量)、lyricsourceinflight.go 的在途上限、sourcebreaker.go 的冷却管着,
// 支线只问还缺着的源。见 09 章决策 125。
type manualLyricSearchKey struct{}

func withManualLyricSearch(ctx context.Context) context.Context {
	return context.WithValue(ctx, manualLyricSearchKey{}, true)
}

func manualLyricSearch(ctx context.Context) bool {
	v, _ := ctx.Value(manualLyricSearchKey{}).(bool)
	return v
}

type aliasBranch struct {
	done    chan struct{}
	ne      neteaseInfo
	results []scoredLyricCandidateResult
}

type aliasFanout struct {
	ctx     context.Context
	cancel  context.CancelFunc
	started map[int]*aliasBranch
}

func newAliasFanout(ctx context.Context) *aliasFanout {
	c, cancel := context.WithCancel(ctx)
	return &aliasFanout{ctx: c, cancel: cancel, started: map[int]*aliasBranch{}}
}

// ensure:第 from 位起的 lyricRescueParallel 位(不超过 n)都已经在跑;没起的现在起。只在主循环里调用。
func (f *aliasFanout) ensure(from, n int, run func(ctx context.Context, i int) (neteaseInfo, []scoredLyricCandidateResult)) {
	for i := from; i < from+lyricRescueParallel && i < n; i++ {
		if _, ok := f.started[i]; ok {
			continue
		}
		b := &aliasBranch{done: make(chan struct{})}
		f.started[i] = b
		go func(i int) {
			defer close(b.done)
			b.ne, b.results = run(f.ctx, i)
		}(i)
	}
}

// take:第 i 位别名那一支的结果,等它跑完;没起过这一支返回 ok=false(由调用方自己串行查)。
func (f *aliasFanout) take(i int) (neteaseInfo, []scoredLyricCandidateResult, bool) {
	b, ok := f.started[i]
	if !ok {
		return neteaseInfo{}, nil, false
	}
	delete(f.started, i)
	<-b.done
	return b.ne, b.results, true
}

// stop:取消还没被取用的支线。
func (f *aliasFanout) stop() { f.cancel() }

// keepLyricSources:只留 sources 里那几个源的候选。
func keepLyricSources(results []scoredLyricCandidateResult, sources []string) []scoredLyricCandidateResult {
	keep := make(map[string]bool, len(sources))
	for _, s := range sources {
		keep[s] = true
	}
	var out []scoredLyricCandidateResult
	for _, r := range results {
		if keep[r.Source] {
			out = append(out, r)
		}
	}
	return out
}
