package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 一轮歌词搜索不问 iTunes:候选只用自己那个源给的封面,不再有一路按本地歌名搜 Apple 封面给它们兜底
// (那张图不是候选的出处,而那一路在出站闸排队时曾拖着整轮撞 20 秒截止)。首轮、重试轮都一样。
func TestLyricSearchDoesNotQueryITunesForCandidateCovers(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	// 一个真实源名都不开:每个源立刻各回一份空结果,剩下的请求只可能来自封面兜底。
	featuresRef().LyricsSources = map[string]bool{"none": true}
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 只数本测试自己的请求(歌名里带 "NoCover"),别的测试在后台的请求不算。
		if strings.Contains(r.URL.RawQuery, "NoCover") {
			hits.Add(1)
		}
		w.Write([]byte(`{"resultCount":0,"results":[]}`))
	}))
	t.Cleanup(srv.Close)
	prev := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() { itunesSearchBaseURL = prev })

	for _, ctx := range []context.Context{
		context.Background(),
		withLyricQueryReason(context.Background(), lyricQueryReasonAliasMissing),
	} {
		title := fmt.Sprintf("NoCover Song %d", time.Now().UnixNano())
		start := time.Now()
		fetchScoredLyricCandidatesStreaming(ctx, "NoCover Artist", title, "NoCover Album", 200, nil)
		if d := time.Since(start); d > 1500*time.Millisecond {
			t.Fatalf("源都立刻回来了,这一轮却用了 %v", d)
		}
	}
	time.Sleep(200 * time.Millisecond)
	if n := hits.Load(); n != 0 {
		t.Fatalf("歌词搜索不该问 iTunes 要候选封面, 收到 %d 次", n)
	}
}

// 别名轮名单里没有网易云 / QQ 时剔掉 amll(它按曲目 ID 直取,那一轮拿不到新 ID);有其中之一就留着。
func TestDropAMLLWithoutIDSource(t *testing.T) {
	cases := []struct {
		in, want []string
	}{
		{[]string{"amll", "kuwo"}, []string{"kuwo"}},
		{[]string{"amll"}, []string{}},
		{[]string{"netease", "amll"}, []string{"netease", "amll"}},
		{[]string{"qq", "amll", "kuwo"}, []string{"qq", "amll", "kuwo"}},
		{[]string{"lrclib", "deezer"}, []string{"lrclib", "deezer"}},
	}
	for _, c := range cases {
		got := dropAMLLWithoutIDSource(append([]string(nil), c.in...))
		if len(got) != len(c.want) {
			t.Errorf("%v -> %v, want %v", c.in, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%v -> %v, want %v", c.in, got, c.want)
				break
			}
		}
	}
}

// 网易云、QQ 都已经给出可用候选时,别名轮名单里不该有 amll —— 那一轮不重查它俩,amll 拿不到新 ID。
func TestAliasRetryListDropsAMLLWhenIDSourcesAnswered(t *testing.T) {
	savedFeatures := features()
	savedBreaker := lyricSourceBreakerShared
	savedYT, savedMM := ytmusicLastFailureReasonNow(), musixmatchLastFailureReasonNow()
	savedDZ, savedAM := deezerLastFailureReasonNow(), applemusicLastFailureReasonNow()
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		lyricSourceBreakerShared = savedBreaker
		ytmusicSetLastFailureReason(savedYT)
		musixmatchSetLastFailureReason(savedMM)
		deezerSetLastFailureReason(savedDZ)
		applemusicSetLastFailureReason(savedAM)
	})
	featuresRef().LyricsSources = map[string]bool{}
	for _, s := range lyricSourceNames {
		featuresRef().LyricsSources[s] = true
	}
	lyricSourceBreakerShared = newLyricSourceBreaker(time.Now)
	ytmusicSetLastFailureReason("")
	musixmatchSetLastFailureReason("")
	deezerSetLastFailureReason("")
	applemusicSetLastFailureReason("")

	got := lyricSourcesWorthAliasRetry([]scoredLyricCandidateResult{
		{Source: "netease", Score: 600}, {Source: "qq", Score: 580},
	})
	for _, s := range got {
		if s == "amll" {
			t.Fatalf("网易云 / QQ 都答了还留着 amll: %v", got)
		}
	}
	if len(got) == 0 {
		t.Fatal("前置:别的缺着的源应该在名单里")
	}
}

// 调用方不要中间结果(onUpdate 为 nil)时,追加轮的包装也是 nil,收集循环据此跳过每个源到达时的整份重打分;
// 要中间结果时照常把本轮结果与前几轮合并后上报。
func TestMergedRoundUpdate(t *testing.T) {
	if f := mergedRoundUpdate(nil, "A", "T", "", 200, nil); f != nil {
		t.Fatal("onUpdate 为 nil 时包装也该是 nil")
	}
	base := []scoredLyricCandidateResult{{Source: "lrclib"}}
	var got []scoredLyricCandidateResult
	var gotDone, gotTotal int
	f := mergedRoundUpdate(func(_ neteaseInfo, res []scoredLyricCandidateResult, done, total int) {
		got, gotDone, gotTotal = res, done, total
	}, "A", "T", "", 200, base)
	f(neteaseInfo{}, []scoredLyricCandidateResult{{Source: "kugou"}}, 3, 11)
	if gotDone != 3 || gotTotal != 11 {
		t.Fatalf("进度该原样透传: %d/%d", gotDone, gotTotal)
	}
	seen := map[string]bool{}
	for _, r := range got {
		seen[r.Source] = true
	}
	if !seen["lrclib"] || !seen["kugou"] {
		t.Fatalf("该带上前几轮已有结果: %v", seen)
	}
}
