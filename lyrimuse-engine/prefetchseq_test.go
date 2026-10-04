package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestWaitPrefetchResolved(t *testing.T) {
	const key = "预取顺序测试|一首歌|专辑"
	savedMax := prefetchResolveMaxWait
	t.Cleanup(func() {
		prefetchResolveMaxWait = savedMax
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	})

	start := time.Now()
	waitPrefetchResolved(key)
	if d := time.Since(start); d > prefetchResolvePoll {
		t.Fatalf("不在解析中应当立刻返回,等了 %s", d)
	}

	enrichMu.Lock()
	enrichInflight[key] = true
	enrichMu.Unlock()
	go func() {
		time.Sleep(600 * time.Millisecond)
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	start = time.Now()
	waitPrefetchResolved(key)
	if d := time.Since(start); d < 500*time.Millisecond || d > 2*time.Second {
		t.Fatalf("应当等到上一首解析结束才返回,等了 %s", d)
	}

	prefetchResolveMaxWait = 400 * time.Millisecond
	enrichMu.Lock()
	enrichInflight[key] = true
	enrichMu.Unlock()
	start = time.Now()
	waitPrefetchResolved(key)
	if d := time.Since(start); d < 400*time.Millisecond || d > 1500*time.Millisecond {
		t.Fatalf("上一首卡住时到上限就该返回,等了 %s", d)
	}
}

// 接线守卫:两条预取路径起下一首之前都等上一首跑完,不再按固定间隔叠着起。
func TestPrefetchPathsRunOneAtATime(t *testing.T) {
	for _, f := range []string{"albumprefetch.go", "upcoming.go"} {
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(data)
		wait := strings.Index(src, "waitPrefetchResolved(prevKey)")
		mark := strings.Index(src, "prevKey = key")
		launch := strings.Index(src, "go resolveEnrichAsync(")
		if wait < 0 || mark < 0 || launch < 0 || !(wait < mark && mark < launch) {
			t.Errorf("%s:起下一首解析之前要先 waitPrefetchResolved(prevKey),再记下 prevKey = key", f)
		}
		if strings.Contains(src, "time.Sleep(albumPrefetchStagger)") {
			t.Errorf("%s 还在按固定间隔错峰", f)
		}
	}
}
