package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func newBudgetGuard(budget int) (*hostGuard, *guardClock) {
	g, c := newTestGuard(hostRate{perSec: 1000, burst: 1000})
	g.sourceBudget = func(source string) int {
		if source == "musixmatch" {
			return budget
		}
		return 0
	}
	return g, c
}

// 窗口里的请求数、还剩多少;滑出一小时的不算;不限额的源不记、不报。
func TestSourceBudgetLeft(t *testing.T) {
	g, c := newBudgetGuard(3)
	t0 := c.t
	for i := 0; i < 3; i++ {
		g.noteSourceHit("musixmatch")
		c.t = c.t.Add(10 * time.Minute)
	}
	// 现在是 t0+30m,三个请求在 t0、t0+10m、t0+20m。
	if left, ok := g.sourceBudgetLeft("musixmatch"); !ok || left != 0 {
		t.Fatalf("left=%d ok=%v", left, ok)
	}
	c.t = t0.Add(sourceBudgetWindow + time.Second)
	if left, _ := g.sourceBudgetLeft("musixmatch"); left != 1 {
		t.Fatalf("滑出一个之后 left=%d", left)
	}
	g.noteSourceHit("qq")
	if _, ok := g.sourceBudgetLeft("qq"); ok || len(g.sourceHits["qq"]) != 0 {
		t.Fatal("不限额的源不该记、不该报")
	}
}

// 额度用完后,后台请求被拦、记进本轮跳过名单(原因 budget),前台照发;前台发出去的也算进额度。
func TestHostGuardSourceBudgetHoldsBackgroundOnly(t *testing.T) {
	g, _ := newBudgetGuard(2)
	const url = "https://apic-appmobile.musixmatch.com/ws/1.1/track.search?q=x"
	fgCtx, _ := withLyricSourceRound(context.Background())
	if err := g.admit(mustReq(t, fgCtx, "GET", url)); err != nil {
		t.Fatal(err)
	}
	bgCtx, round := withLyricSourceRound(withBackgroundOutbound(context.Background()))
	if err := g.admit(mustReq(t, bgCtx, "GET", url)); err != nil {
		t.Fatalf("还有一个额度,后台该放行: %v", err)
	}
	if err := g.admit(mustReq(t, bgCtx, "GET", url)); !errors.Is(err, errHostGuarded) {
		t.Fatalf("额度用完,后台该被拦: %v", err)
	}
	if got := round.statsSkips()["musixmatch"]; got != lyricSourceSkipReasonBudget {
		t.Fatalf("跳过原因 = %q", got)
	}
	if err := g.admit(mustReq(t, fgCtx, "GET", url)); err != nil {
		t.Fatalf("前台不受额度限制: %v", err)
	}
	if left, _ := g.sourceBudgetLeft("musixmatch"); left != -1 {
		t.Fatalf("前台发出去的也算额度,left = %d", left)
	}
}

// 各源近况统计:用完额度没问到的源,这一轮不算它的。
func TestLyricSourceOutcomeIgnoresBudgetSkips(t *testing.T) {
	all := func(string) bool { return true }
	d := &lyricsDecision{SourcesSkipped: []string{"musixmatch"}, statsSkips: map[string]string{"musixmatch": lyricSourceSkipReasonBudget}}
	o := lyricSourceOutcomeFromDecision(d, all, all, func(string) string { return "" })
	if o.skipped["musixmatch"] {
		t.Error("用完额度不算跳过")
	}
	for _, s := range o.enabled {
		if s == "musixmatch" {
			t.Error("用完额度没问它,这一轮不算它")
		}
	}
}

// 额度跨重启接着算:记下的请求存进文件,新起的闸读回来,滑出窗口的不要;文件不在时从满额算。
func TestSourceBudgetSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "budget.json")
	g, c := newBudgetGuard(5)
	g.useSourceBudgetFile(path)
	g.noteSourceHit("musixmatch")
	c.t = c.t.Add(50 * time.Minute)
	g.noteSourceHit("musixmatch")
	g.noteSourceHit("musixmatch")

	restarted, rc := newBudgetGuard(5)
	rc.t = c.t.Add(20 * time.Minute) // 第一个已经滑出窗口
	restarted.useSourceBudgetFile(path)
	if left, _ := restarted.sourceBudgetLeft("musixmatch"); left != 3 {
		t.Fatalf("重启后应接着算(还剩 3 个),实际 %d", left)
	}

	empty, _ := newBudgetGuard(5)
	empty.useSourceBudgetFile(filepath.Join(t.TempDir(), "missing.json"))
	if left, _ := empty.sourceBudgetLeft("musixmatch"); left != 5 {
		t.Fatalf("文件不在时从满额算,实际 %d", left)
	}
}
