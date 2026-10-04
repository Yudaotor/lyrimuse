package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func TestOutboundLaneOf(t *testing.T) {
	bg := withBackgroundOutbound(context.Background())
	alias := withLyricQueryReason(context.Background(), lyricQueryReasonAliasRescue)
	for name, c := range map[string]struct {
		ctx  context.Context
		want outboundLane
	}{
		"首轮 / 非检索请求": {context.Background(), laneForeground},
		"首轮显式":       {withLyricQueryReason(context.Background(), lyricQueryReasonPrimary), laneForeground},
		"别名救急":       {alias, laneSecondary},
		"标题拆分":       {withLyricQueryReason(context.Background(), lyricQueryReasonTitleSplit), laneSecondary},
		"后台":         {bg, laneBackground},
		"后台里的补查轮":    {withLyricQueryReason(bg, lyricQueryReasonAliasRescue), laneBackground},
	} {
		if got := outboundLaneOf(c.ctx); got != c.want {
			t.Errorf("%s: got %d want %d", name, got, c.want)
		}
	}
}

// 补查档取完要给首轮留 secondaryReserve 个;排不上就不发,首轮照样能取。
func TestHostGuardSecondaryLeavesReserveForPrimary(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 0.01, burst: 5, reserve: 3})
	g.now = time.Now
	g.maxWait = 50 * time.Millisecond
	rescue := withLyricQueryReason(context.Background(), lyricQueryReasonAliasRescue)
	if got := secondaryReserve(hostRate{reserve: 3}); got != 2 {
		t.Fatalf("secondaryReserve = %v", got)
	}
	for i := 0; i < 3; i++ {
		if err := g.acquire(rescue, "a.example"); err != nil {
			t.Fatalf("第 %d 个补查请求桶里够,该取到: %v", i+1, err)
		}
	}
	if err := g.acquire(rescue, "a.example"); !errors.Is(err, errHostGuarded) {
		t.Fatalf("只剩 2 个(留给首轮),补查不该再取: %v", err)
	}
	for i := 0; i < 2; i++ {
		if err := g.acquire(context.Background(), "a.example"); err != nil {
			t.Fatalf("留给首轮的第 %d 个该直接放行: %v", i+1, err)
		}
	}
}

// 补查档排不上队拦住源,不连累同一个源的首轮。
func TestHostGuardSourceHoldPerLane(t *testing.T) {
	g, _ := newTestGuard(hostRate{perSec: 1, burst: 5, reserve: 3})
	g.holdSource("qq", laneSecondary)
	if !g.sourceHeldNow("qq", laneSecondary) {
		t.Fatal("补查档该被拦住")
	}
	if g.sourceHeldNow("qq", laneForeground) || g.sourceHeldNow("qq", laneBackground) {
		t.Fatal("补查档被拦不该连累首轮 / 后台")
	}
}

func TestLyricSourceInflightCap(t *testing.T) {
	const host = "lrclib.net"
	if lyricSourceForHost(host) != "lrclib" {
		t.Skip("主机归属变了,改用别的歌词源主机")
	}
	cap := lyricSourceInflightCaps["lrclib"]
	var releases []func()
	for i := 0; i < cap; i++ {
		r, err := acquireLyricSourceSlot(context.Background(), host)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, r)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := acquireLyricSourceSlot(ctx, host); err == nil {
		t.Fatal("名额占满时应排队,请求取消后返回错误")
	}
	got := make(chan error, 1)
	go func() {
		r, err := acquireLyricSourceSlot(context.Background(), host)
		if err == nil {
			r()
		}
		got <- err
	}()
	time.Sleep(20 * time.Millisecond)
	releases[0]()
	releases[0]() // 重复归还是空操作
	select {
	case err := <-got:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("归还一个名额后排队的请求应当拿到")
	}
	for _, r := range releases[1:] {
		r()
	}
	if r, err := acquireLyricSourceSlot(context.Background(), "example.invalid"); err != nil {
		t.Fatal(err)
	} else {
		r()
	}
}

// 接线守卫:请求出口里占名额、拿到响应立刻还;对外入口包着同 URL 合并。
func TestOutboundSchedulingIsWired(t *testing.T) {
	data, err := os.ReadFile("networkobs.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, n := range []string{
		"releaseSlot, slotErr := acquireLyricSourceSlot(req.Context(), guardHost(req.URL))",
		"resp, err := cli.Do(req)\n\treleaseSlot()",
		"func doHTTPTrackedOnce(cli *http.Client, req *http.Request)",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("networkobs.go 缺 %q", n)
		}
	}
	data, _ = os.ReadFile("hostguard.go")
	if !strings.Contains(string(data), "case laneSecondary:\n\t\treturn g.acquireSecondary(ctx, host)") {
		t.Error("hostguard.go 的 acquire 没接补查档")
	}
}
