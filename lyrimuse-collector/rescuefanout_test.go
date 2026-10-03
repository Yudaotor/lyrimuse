package main

import (
	"context"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAliasFanoutWindowAndOrder(t *testing.T) {
	var running, peak int32
	var mu sync.Mutex
	started := map[int]bool{}
	run := func(ctx context.Context, i int) (neteaseInfo, []scoredLyricCandidateResult) {
		mu.Lock()
		started[i] = true
		mu.Unlock()
		n := atomic.AddInt32(&running, 1)
		for {
			p := atomic.LoadInt32(&peak)
			if n <= p || atomic.CompareAndSwapInt32(&peak, p, n) {
				break
			}
		}
		// 后面的支线先跑完:采用顺序不能跟着完成顺序走。
		time.Sleep(time.Duration(40-i*10) * time.Millisecond)
		atomic.AddInt32(&running, -1)
		return neteaseInfo{}, []scoredLyricCandidateResult{{Source: "kugou", Score: 100 + i}}
	}
	f := newAliasFanout(context.Background())
	defer f.stop()
	const n = 5
	for i := 0; i < n; i++ {
		f.ensure(i, n, run)
		_, res, ok := f.take(i)
		if !ok || len(res) != 1 || res[0].Score != 100+i {
			t.Fatalf("第 %d 位取到的结果不对: ok=%v %+v", i, ok, res)
		}
	}
	if p := atomic.LoadInt32(&peak); p > lyricRescueParallel {
		t.Fatalf("同时在跑的支线 %d 支,超过 %d", p, lyricRescueParallel)
	}
	if _, _, ok := f.take(0); ok {
		t.Fatal("取用过的支线不该再取到")
	}

	// 只起了窗口里的那几支,没 ensure 过的位置不起。
	g := newAliasFanout(context.Background())
	defer g.stop()
	mu.Lock()
	started = map[int]bool{}
	mu.Unlock()
	g.ensure(0, 10, run)
	g.take(0)
	mu.Lock()
	got := len(started)
	mu.Unlock()
	if got != lyricRescueParallel {
		t.Fatalf("窗口应起 %d 支,起了 %d 支", lyricRescueParallel, got)
	}
	if _, _, ok := g.take(7); ok {
		t.Fatal("没起过的位置应返回 ok=false")
	}
}

func TestAliasFanoutStopCancelsBranches(t *testing.T) {
	cancelled := make(chan struct{}, lyricRescueParallel)
	run := func(ctx context.Context, i int) (neteaseInfo, []scoredLyricCandidateResult) {
		select {
		case <-ctx.Done():
			cancelled <- struct{}{}
		case <-time.After(5 * time.Second):
		}
		return neteaseInfo{}, nil
	}
	f := newAliasFanout(context.Background())
	f.ensure(0, 3, run)
	f.stop()
	for i := 0; i < 3; i++ {
		select {
		case <-cancelled:
		case <-time.After(time.Second):
			t.Fatal("stop 之后还在跑的支线应当收到取消")
		}
	}
}

func TestKeepLyricSources(t *testing.T) {
	got := keepLyricSources([]scoredLyricCandidateResult{{Source: "qq"}, {Source: "kuwo"}, {Source: "lrclib"}, {Source: "kuwo"}}, []string{"kuwo", "deezer"})
	if len(got) != 2 || got[0].Source != "kuwo" || got[1].Source != "kuwo" {
		t.Fatalf("got %+v", got)
	}
}

// 接线守卫:救急时别名轮走并发支线,采用仍在主循环里按顺序;循环结束取消剩下的支线。
func TestRescueFanoutIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, n := range []string{
		"fan := newAliasFanout(ctx)",
		"case rescue:\n\t\t\t\tfan.ensure(i, len(altIdentities), rescueBranch)",
		// 手动搜索时补缺席源的别名轮也并发,只起到 lyricAliasMissingMaxTries 为止;补罗马音那一轮不开、也不采用预开的支线。
		"case missingParallel && !romaRetry:\n\t\t\t\tfan.ensure(i, min(len(altIdentities), lyricAliasMissingMaxTries), missingBranch(only))",
		"missingParallel := manualLyricSearch(ctx)",
		"if bNe, bRes, ok := fan.take(i); ok && (rescue || !romaRetry) {",
		"altResults = keepLyricSources(altResults, only)",
		"notifyProvisionalLyrics(ctx, bNe, mergeLyricCandidateRounds(artist, title, album, durationSecs, rescueBase, bRes))",
		"\t\tfan.stop()\n\t}",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}

// 手动搜索的标记只由 search-lyrics 挂上;播放时的解析没有它,补缺席源的别名轮照旧串行。
func TestManualLyricSearchMark(t *testing.T) {
	if manualLyricSearch(context.Background()) || !manualLyricSearch(withLyricQueryReason(withManualLyricSearch(context.Background()), lyricQueryReasonAliasMissing)) {
		t.Fatal("标记要能穿过别的 ctx 包装读出来,没挂的读成 false")
	}
	data, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "searchCtx := withManualLyricSearch(context.Background())") {
		t.Error("search-lyrics 没挂手动搜索的标记")
	}
	for _, f := range []string{"enrich.go", "upcoming.go", "albumprefetch.go", "lyricsfillsweep.go", "lyricsfullscan.go"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "withManualLyricSearch(") {
			t.Errorf("%s 不该挂手动搜索的标记:播放和批量路径的补缺别名轮要串行", f)
		}
	}
}
