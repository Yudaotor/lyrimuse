package main

import (
	"context"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// megalobizParitySource:Megalobiz 的对拍。普通一轮带 withOnDemandLyricRound(正在放的那首),不带的轮次它不问;出站闸用
// 生产的速率表和小时额度(这个源三种额度都有:令牌桶、后台小时额度、每日额度)。
var megalobizParitySource = providerParitySource{
	name: lyricSourceMegalobiz,
	handwritten: func(ctx context.Context, artist, title, srcTitle, album string, durationSecs float64) lyricSourceResult {
		r := megalobizLyric(ctx, artist, srcTitle, album, durationSecs)
		return lyricSourceResult{source: "megalobiz", lyr: r.lyrics, matchTitle: r.title, matchArtist: r.artist, srcDur: r.durationSecs, sourceURL: r.url}
	},
	reset: func(t *testing.T) {
		resetMegalobizCacheForTest(t)
		resetSourceDayQuotaForTest(t)
	},
	cacheKeys: func() []string {
		megalobizMu.Lock()
		defer megalobizMu.Unlock()
		var keys []string
		for k := range megalobizCache {
			keys = append(keys, k)
		}
		return keys
	},
	state: func() []string {
		megalobizMu.Lock()
		defer megalobizMu.Unlock()
		var out []string
		for u, a := range megalobizAnswers {
			out = append(out, "answered "+u+" err="+strconv.FormatBool(a.err != nil))
		}
		sort.Strings(out)
		return out
	},
	headers: []string{"User-Agent", "Accept"},
	baseCtx: withOnDemandLyricRound,
	guard: func(g *hostGuard) {
		g.rateFor, g.sourceBudget = hostRateFor, lyricSourceBudgetPerHour
	},
}

func megalobizQueueRound(ctx context.Context) context.Context {
	return withBackgroundOutbound(withPlayerQueueTrack(ctx))
}

const megalobizParityLRCPath = "https://api.megalobiz.com/api/public/v1/lrc/"

// megalobizParityHit:带歌手的那条搜索就有、第一名取得到。
func megalobizParityHit(r parityRequest) parityReply {
	switch {
	case strings.HasSuffix(r.target, "/search"):
		return parityOK(megalobizTestSearch)
	case r.target == megalobizParityLRCPath+"323234":
		return parityOK(megalobizTestLRC)
	}
	return parityStatus(http.StatusNotFound)
}

func megalobizParityThreeHits() string {
	return `{"results":[{"id":11,"title":"Song","artist":"Artist","duration":200,"url":"https://megalobiz.com/lrc/11/song"},
{"id":12,"title":"Song","artist":"Artist","duration":203,"url":"https://megalobiz.com/lrc/12/song"},
{"id":13,"title":"Song","artist":"Artist","duration":204,"url":"https://megalobiz.com/lrc/13/song"}]}`
}

func megalobizParitySheet(id string) string {
	return `{"id":` + id + `,"url":"https://megalobiz.com/lrc/` + id + `/song","lines":[{"time_ms":1000,"text":"a"},{"time_ms":2000,"text":"b"},{"time_ms":3000,"text":"c"}]}`
}

// megalobizUseUpHourlyBudget:这一小时的后台额度用完。
func megalobizUseUpHourlyBudget(t *testing.T) {
	t.Helper()
	g := sharedHostGuard()
	for range megalobizHourlyBudget {
		g.noteSourceHit(lyricSourceMegalobiz)
	}
	if left, limited := g.sourceBudgetLeft(lyricSourceMegalobiz); !limited || left != 0 {
		t.Fatalf("想把小时额度用完,还剩 %d(limited=%v)", left, limited)
	}
}

func megalobizDayQuotaLeft(remaining int) func(t *testing.T) {
	return func(t *testing.T) {
		t.Helper()
		status := http.StatusOK
		if remaining == 0 {
			status = http.StatusTooManyRequests
		}
		noteSourceDayQuota(lyricSourceMegalobiz, status, dayQuotaHeader("X-RateLimit-Remaining-Day", strconv.Itoa(remaining), "X-RateLimit-Reset-Day", "3600"), time.Now())
	}
}

// megalobizDrainTokenBucket:本地令牌桶放空、排队上限调成 0,下一个请求排不上。
func megalobizDrainTokenBucket(t *testing.T) {
	t.Helper()
	g := sharedHostGuard()
	g.maxWait, g.backgroundMaxWait = 0, 0
	for i := 0; i < int(hostRateFor("api.megalobiz.com").burst); i++ {
		if err := g.acquire(context.Background(), "api.megalobiz.com"); err != nil {
			t.Fatalf("放空令牌桶时第 %d 个就拿不到:%v", i+1, err)
		}
	}
}

func TestMegalobizProviderMatchesHandwrittenRound(t *testing.T) {
	const artist, title = "Tiakola", "Mode de vie"
	empty := parityOK(`{"count":0,"results":[]}`)
	cases := []providerParityCase{
		{
			name: "「歌名 + 歌手」那条就命中", artist: artist, title: title, durationSecs: 190,
			handle: megalobizParityHit, wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				r := o.result
				if r.matchTitle != "Mode de vie" || r.matchArtist != "Tiakola" || r.srcDur != 190.69 || r.sourceURL != "https://megalobiz.com/lrc/323234/mode-de-vie" {
					t.Errorf("歌名、歌手、时长、来源页都该带上:%+v", r)
				}
				for _, line := range o.requests {
					if !strings.Contains(line, "User-Agent="+clientName+"/") {
						t.Errorf("请求该带写明 App 名的 User-Agent:%s", line)
					}
				}
			},
		},
		{
			name: "带歌手的一条都没有,只按歌名的命中", artist: artist, title: title, durationSecs: 190,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/search") && r.URL.Query().Get("artist") != "" {
					return empty
				}
				return megalobizParityHit(r)
			},
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "哪一条都没搜到", artist: artist, title: title, durationSecs: 190,
			handle: func(parityRequest) parityReply { return empty }, wantRequests: 2,
		},
		{
			name: "搜索回 404 算答了没有,接着问下一条", artist: artist, title: title, durationSecs: 190,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/search") && r.URL.Query().Get("artist") != "" {
					return parityStatus(http.StatusNotFound)
				}
				return megalobizParityHit(r)
			},
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "第一名取词 404,退到第二名", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r parityRequest) parityReply {
				switch {
				case strings.HasSuffix(r.target, "/search"):
					return parityOK(megalobizParityThreeHits())
				case r.target == megalobizParityLRCPath+"11":
					return parityStatus(http.StatusNotFound)
				}
				return parityOK(megalobizParitySheet(r.target[strings.LastIndex(r.target, "/")+1:]))
			},
			wantRequests: 3, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.sourceURL != "https://megalobiz.com/lrc/12/song" || o.result.srcDur != 203 {
					t.Errorf("应是第二名那份:%+v", o.result)
				}
			},
		},
		{
			name: "第一名取词 502:不往下取、不进缓存", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/search") {
					return parityOK(megalobizParityThreeHits())
				}
				return parityStatus(http.StatusBadGateway)
			},
			wantRequests: 2,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 0 {
					t.Errorf("没问成的不进进程内缓存:%v", o.cached)
				}
			},
		},
		{
			name: "前两名都取不到,第三名不取", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/search") {
					return parityOK(megalobizParityThreeHits())
				}
				return parityStatus(http.StatusNotFound)
			},
			wantRequests: 3,
		},
		{
			name: "第一名的谱满是和弦标记,用第二名", artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r parityRequest) parityReply {
				switch {
				case strings.HasSuffix(r.target, "/search"):
					return parityOK(megalobizParityThreeHits())
				case r.target == megalobizParityLRCPath+"11":
					return parityOK(`{"url":"https://megalobiz.com/lrc/11/song","lines":[{"time_ms":1000,"text":"{00:01.00,A]a"},{"time_ms":2000,"text":"{00:02.00,A]b"},{"time_ms":3000,"text":"{00:03.00,E]c"}]}`)
				}
				return parityOK(megalobizParitySheet("12"))
			},
			wantRequests: 3, wantLyrics: true,
		},
		{
			name: "同一首连问两轮:第二轮读进程内缓存", rounds: 2, artist: artist, title: title, album: "Mélo", durationSecs: 190,
			handle: megalobizParityHit, wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if len(o.cached) != 1 || o.cached[0] != "Tiakola|Mode de vie|Mélo|190" {
					t.Errorf("进程内缓存的键应带歌手、歌名、专辑和取整的时长:%v", o.cached)
				}
			},
		},
		{
			name: "歌名带编号:拿带编号的那份去问",
			ctx: func(ctx context.Context) context.Context {
				return withLyricSourceTitle(ctx, "Song (#6)", "Artist", "Song", "")
			},
			artist: "Artist", title: "Song", durationSecs: 200,
			handle: func(r parityRequest) parityReply {
				if strings.HasSuffix(r.target, "/search") {
					if r.URL.Query().Get("title") == "Song (#6)" {
						return parityOK(`{"results":[{"id":21,"title":"Song (#6)","artist":"Artist","duration":200,"url":"https://megalobiz.com/lrc/21/song"}]}`)
					}
					return empty
				}
				return parityOK(megalobizParitySheet("21"))
			},
			wantRequests: 4, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.result.matchTitle != "Song (#6)" {
					t.Errorf("应挑中带编号的那条:%+v", o.result)
				}
			},
		},
		{
			name: "前台吃到 429:这个源进冷却", artist: artist, title: title, durationSecs: 190,
			handle: func(parityRequest) parityReply {
				return parityReply{status: http.StatusTooManyRequests, header: http.Header{"Retry-After": {"30"}}, body: `{"error":"rate_limited"}`}
			},
			wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(o.state[0], "cooling=true") {
					t.Errorf("前台 429 后这个源应进冷却:%v", o.state)
				}
			},
		},
		{
			name: "待播队列的预解析吃到 429:后台请求暂停", ctx: megalobizQueueRound, artist: artist, title: title, durationSecs: 190,
			handle:       func(parityRequest) parityReply { return parityStatus(http.StatusTooManyRequests) },
			wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "background paused api.megalobiz.com") {
					t.Errorf("后台档 429 后后台请求应暂停:%v", o.state)
				}
			},
		},
		{
			name: "小时额度用完:待播队列的预解析不问,记成跳过", ctx: megalobizQueueRound, prepare: megalobizUseUpHourlyBudget,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.skips[lyricSourceMegalobiz] != lyricSourceSkipReasonBudget {
					t.Errorf("跳过原因应是额度:%v", o.skips)
				}
			},
		},
		{
			name: "小时额度用完:正在放的那首照问,也算进额度", prepare: megalobizUseUpHourlyBudget,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantRequests: 2, wantLyrics: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "hourly budget left=-2") {
					t.Errorf("前台发的两个请求也该记进小时额度:%v", o.state)
				}
			},
		},
		{
			name: "每日额度剩得少:待播队列的预解析不问,记成跳过", ctx: megalobizQueueRound, prepare: megalobizDayQuotaLeft(10),
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.skips[lyricSourceMegalobiz] != lyricSourceSkipReasonBudget {
					t.Errorf("跳过原因应是额度:%v", o.skips)
				}
			},
		},
		{
			name: "每日额度剩得少:正在放的那首照问", prepare: megalobizDayQuotaLeft(10),
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantRequests: 2, wantLyrics: true,
		},
		{
			name: "应答头报每日额度用完:停到重置时刻", artist: artist, title: title, durationSecs: 190,
			handle: func(parityRequest) parityReply {
				return parityReply{status: http.StatusTooManyRequests, body: `{"error":"rate_limited"}`, header: http.Header{
					"X-Ratelimit-Remaining-Day": {"0"}, "X-Ratelimit-Reset-Day": {"40000"}, "Retry-After": {"40000"},
				}}
			},
			wantRequests: 1,
			check: func(t *testing.T, o providerParityOutcome) {
				if !strings.Contains(strings.Join(o.state, "\n"), "paused=true for 11h7m0s") {
					t.Errorf("应记下停到重置时刻:%v", o.state)
				}
			},
		},
		{
			name: "每日额度已经用完:这一轮直接跳过", prepare: megalobizDayQuotaLeft(0),
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.skips[lyricSourceMegalobiz] != lyricSourceSkipReasonBudget {
					t.Errorf("跳过原因应是额度:%v", o.skips)
				}
			},
		},
		{
			name: "本地令牌桶排不上:不发请求,记成跳过", prepare: megalobizDrainTokenBucket,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantSkips: true,
			check: func(t *testing.T, o providerParityOutcome) {
				if o.skips[lyricSourceMegalobiz] != lyricSourceSkipReasonQueued {
					t.Errorf("跳过原因应是排队:%v", o.skips)
				}
			},
		},
		{
			name: "手动搜索:问", bareCtx: true, ctx: withManualLyricSearch,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantRequests: 2, wantLyrics: true,
		},
		{
			name: "待播队列的预解析:问", ctx: megalobizQueueRound, bareCtx: true,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit, wantRequests: 2, wantLyrics: true,
		},
		{
			name: "补空扫描 / 全量扫库:不问,也不记跳过", bareCtx: true,
			ctx:    func(ctx context.Context) context.Context { return withBackgroundOutbound(withOtherTrackRound(ctx)) },
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit,
		},
		{
			name: "专辑预取 / 导入清单:不问,也不记跳过", bareCtx: true, ctx: withBackgroundOutbound,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit,
		},
		{
			name: "没标记的前台入口(开发命令行):不问,也不记跳过", bareCtx: true,
			artist: artist, title: title, durationSecs: 190, handle: megalobizParityHit,
		},
	}
	cases = append(cases, providerParitySkipCases(artist, title, 190)...)
	runProviderParity(t, megalobizParitySource, cases)
}

func TestMegalobizProviderRequestCancelledWithRound(t *testing.T) {
	runProviderCancelledMidRequest(t, megalobizParitySource, "Tiakola", "Mode de vie", 190)
}

func TestMegalobizProviderWithCancelledRoundMatchesHandwritten(t *testing.T) {
	runProviderCancelledBeforeRound(t, megalobizParitySource, "Tiakola", "Mode de vie", 190, megalobizParityHit)
}

// 调度拿描述符的 Rounds 判 Megalobiz 这一轮问不问:只带 withOnDemandLyricRound 这一类标记的轮次问,别的轮次不问、不发请求、
// 不记跳过。这是 Rounds 在生产路径上第一次生效,单独钉一条不靠对拍的。
func TestMegalobizProviderOnlyAskedInOnDemandRounds(t *testing.T) {
	s := megalobizParitySource
	for _, c := range []struct {
		name string
		ctx  func(context.Context) context.Context
		want bool
	}{
		{"正在放的那首", withOnDemandLyricRound, true},
		{"手动搜索 / 重新匹配", withManualLyricSearch, true},
		{"待播队列的预解析", megalobizQueueRound, true},
		{"补空扫描 / 全量扫库", func(ctx context.Context) context.Context { return withBackgroundOutbound(withOtherTrackRound(ctx)) }, false},
		{"专辑预取 / 导入清单", withBackgroundOutbound, false},
		{"没标记的前台入口", func(ctx context.Context) context.Context { return ctx }, false},
	} {
		s.reset(t)
		fake := withParityFake(t, s, megalobizParityHit)
		enableOnlyLyricSources(t, s.name)
		ctx, round := withLyricSourceRound(c.ctx(context.Background()))
		plan := newLyricRoundPlan(ctx, sharedLyricSourceBreaker().planRound(lyricSourceNames))
		q := ProviderQuery{Artist: "Tiakola", Title: "Mode de vie", SourceTitle: "Mode de vie", DurationSecs: 190}
		r := runLyricProvider(ctx, lyricProviderNamed(t, s.name), q, RoundEnv{}, plan)
		if asked := len(fake.requests()) > 0; asked != c.want || (r.lyr != "") != c.want {
			t.Errorf("%s:问了 = %v、拿到歌词 = %v,期望 %v", c.name, asked, r.lyr != "", c.want)
		}
		if r.source != lyricSourceMegalobiz {
			t.Errorf("%s:源名 %q", c.name, r.source)
		}
		if got := round.skippedSources(); len(got) != 0 {
			t.Errorf("%s:这种轮次不问它是规矩、不是跳过,不记:%v", c.name, got)
		}
	}
}
