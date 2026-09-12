package main

import (
	"context"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// 2026-09-06 别名轮改口径(用户定的:「这个源没有候选就去跑别名(如果有的话)」)。
// 纯函数部分在这里钉住;整条 scoredLyricCandidatesStreaming 要联网,不在单测里跑。

func TestLyricSourcesWorthAliasRetry(t *testing.T) {
	savedFeatures := features
	savedBreaker := lyricSourceBreakerShared
	savedYT, savedMM := ytmusicLastFailureReasonNow(), musixmatchLastFailureReasonNow()
	t.Cleanup(func() {
		features = savedFeatures
		lyricSourceBreakerShared = savedBreaker
		ytmusicSetLastFailureReason(savedYT)
		musixmatchSetLastFailureReason(savedMM)
	})
	features.LyricsSources = map[string]bool{}
	for _, s := range lyricSourceNames {
		features.LyricsSources[s] = true
	}
	features.LyricsSources["migu"] = false // 关掉的不算
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	// 酷我:传输层连不上 —— 换名字也没用
	dns := &url.Error{Op: "Get", Err: &net.OpError{Op: "dial", Err: &net.DNSError{Err: "no such host", IsNotFound: true}}}
	lyricSourceBreakerShared.observe("search.kuwo.cn", dns, 0, "")
	// lyricfind 地区限制、musixmatch 直连被堵 —— 同理
	ytmusicSetLastFailureReason(lyricFailureReasonLyricFindRegionRestricted)
	musixmatchSetLastFailureReason(lyricFailureReasonMusixmatchDirectBlocked)

	results := []scoredLyricCandidateResult{
		{Source: "netease", Score: 579},               // 可用 → 不缺
		{Source: "lrclib", Score: -1},                 // 给了但被判废 → 仍算缺
		{Source: "qq", Score: -1, Instrumental: true}, // 纯音乐标记不是候选 → 仍算缺
	}
	got := lyricSourcesWorthAliasRetry(results)
	want := []string{"qq", "kugou", "lrclib", "amll"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v want %v", got, want)
	}

	// 都齐了 → 空
	full := []scoredLyricCandidateResult{}
	for _, s := range lyricSourceNames {
		full = append(full, scoredLyricCandidateResult{Source: s, Score: 100})
	}
	if got := lyricSourcesWorthAliasRetry(full); len(got) != 0 {
		t.Fatalf("全部可用时应为空,得到 %v", got)
	}
	// 具体原因清掉后 lyricfind / musixmatch 重新算缺
	ytmusicSetLastFailureReason("")
	musixmatchSetLastFailureReason("")
	got = lyricSourcesWorthAliasRetry(results)
	if !containsString(got, "lyricfind") || !containsString(got, "musixmatch") {
		t.Fatalf("没有具体失败原因时 lyricfind / musixmatch 应算缺,得到 %v", got)
	}
}

func TestWithLyricSourceOnly(t *testing.T) {
	base := context.Background()
	if lyricSourceOnlyFrom(base) != nil {
		t.Fatal("没挂名单应返回 nil")
	}
	if withLyricSourceOnly(base, nil) != base || withLyricSourceOnly(base, []string{}) != base {
		t.Fatal("空名单应原样返回 ctx(不限制)")
	}
	ctx := withLyricSourceOnly(base, []string{"qq", "musixmatch"})
	set := lyricSourceOnlyFrom(ctx)
	if !set["qq"] || !set["musixmatch"] || set["netease"] || len(set) != 2 {
		t.Fatalf("名单不对:%v", set)
	}
	if lyricSourceOnlyFrom(nil) != nil {
		t.Fatal("nil ctx 应返回 nil")
	}
	// 跟 lyricSourceRound 共存:两个 ctx 值互不干扰
	ctx2, round := withLyricSourceRound(ctx)
	if lyricSourceOnlyFrom(ctx2)["qq"] != true || lyricSourceRoundFrom(ctx2) != round {
		t.Fatal("两个 ctx 值应共存")
	}
}

// 源码级守卫:skipSource 必须消费 lyricSourceOnlyFrom,别名轮必须用 withLyricSourceOnly 包 ctx ——
// 少一头,"只查缺的源"就是空话(要么全查,要么名单没人读)。
func TestAliasRoundTargetingIsWired(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	for _, needle := range []string{
		"only := lyricSourceOnlyFrom(ctx)",
		"if only != nil && !only[source] {",
		// 守的是"定向重查这道接线还在",不是那一行长什么样 —— 2026-09-12 起外面还包了
		// 一层 withLyricQueryReason(借鉴清单 V1 的查询词留痕),所以只钉内层这一段。
		"withLyricSourceOnly(ctx, only)",
		"fetchScoredLyricCandidatesStreaming(altCtx, alt, title, album, durationSecs, aliasUpdate)",
		"missing := lyricSourcesWorthAliasRetry(results)",
		// 别名轮的三个触发理由必须各自标注到查询留痕里,否则存档只知道"换了个名字查",
		// 分不出这一轮是救急、缺罗马音、还是只补缺席的那几个源(处置完全不同)。
		"aliasReason := lyricQueryReasonAliasMissing",
		"altCtx := withLyricQueryReason(withLyricSourceOnly(ctx, only), aliasReason)",
	} {
		if !strings.Contains(s, needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
	// 老的触发条件不许悄悄回来。
	if strings.Contains(s, "if !hasUsableLyricCandidate(results) || needsRomanizationRetry(results) {") {
		t.Error("别名轮又退回'一个能用的都没有才跑'的老条件")
	}
}
